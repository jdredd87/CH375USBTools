program mouprobe;
{ MOUPROBE -- is there a serial mouse on the USB-to-serial adapter, and
  which protocol does it speak?
  CH375Mouse, StevenC.  Public domain (the Unlicense).

    MOUPROBE [/P=260] [/C=n] [/S=secs] [/W] [/M] [/X] [/Q]

      /P=hex   I/O base, default 260
      /C=dec   configuration INDEX to use.  Default: try each until one
               yields a serial adapter this project can drive
      /S=dec   seconds to watch for movement, default 12
      /W       force Microsoft framing (1200 7N1) and skip the probe
      /M       force Mouse Systems framing (1200 8N1)
      /X       hex-dump every byte as well as decoding it
      /Q       do not beep

  WHY A SERIAL MOUSE IS A GOOD FIRST TARGET FOR THIS

  It is the one device this collection has met whose data rate the CH375
  cannot possibly limit.  1200 baud, three bytes a report, forty reports a
  second: 120 bytes/second, against a chip that sustains about 19,000.
  Every other project here -- video, audio, Ethernet, the terminal -- ran
  into the same packet-rate ceiling.  This one cannot.

  So what is being tested here is LATENCY and CORRECTNESS, not bandwidth,
  which makes it a genuinely different experiment rather than another
  instance of the last one.

  THE MOUSE IS POWERED BY ITS OWN CONTROL LINES.

  A serial mouse draws its power from RTS and DTR.  That is why this
  matters more than it looks: an adapter that does not raise them leaves
  the mouse dead, and a dead mouse is indistinguishable from a broken
  driver, wrong baud rate, bad cable or unsupported adapter.  dser raises
  both in SerOpen and drops both in SerClose, so a close/open pair is a
  POWER CYCLE -- which is exactly what makes a mouse announce itself, and
  it needs no adapter-specific code to do it.

  Exit codes: 0 a mouse was identified and moved, 1 no chip,
              2 chip too old, 3 nothing attached, 5 device stopped
              answering, 6 not a serial adapter this project drives,
              7 the port opened but the mouse never said anything,
              8 bytes arrived but no protocol fits them,
              9 a mouse was identified but the framing used was wrong }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, dser, dmouse;

const
  VER = '0.1.0';
  MOUSE_BAUD = 1200;

var
  Big     : TBigCfg;
  BigLen  : Word;
  Why     : ShortString;
  Dev     : TSerDev;
  WantCfg : Integer;
  Secs    : Integer;
  ForceW  : Boolean;
  ForceM  : Boolean;
  ShowHex : Boolean;
  Quiet   : Boolean;
  VID, PID: Word;
  Rc      : Integer;
  Proto   : TMouseProto;

{ ---------------------------------------------------------------------
  A beep, straight at the timer and the speaker port.

  Not Crt.Sound: uses Crt replaces the standard output driver with one
  that writes to video memory, and every WriteLn after it stops being
  captured by the bridge -- so a program that beeps through Crt comes back
  with no output at all and reads as a program that never ran.
  --------------------------------------------------------------------- }
procedure Tone(Freq, Ticks5: Word);
var
  Div_ : Word;
  T0   : LongInt;
  B    : Byte;
begin
  if Freq = 0 then Exit;
  Div_ := Word(1193182 div LongInt(Freq));
  Port[$43] := $B6;
  Port[$42] := Byte(Div_ and $FF);
  Port[$42] := Byte(Div_ shr 8);
  B := Port[$61];
  Port[$61] := B or $03;
  T0 := Ticks;
  while (Ticks - T0) < LongInt(Ticks5) do
    if Ticks < T0 then T0 := Ticks;        { midnight, and it does wrap }
  B := Port[$61];
  Port[$61] := B and $FC;
end;

{ Long enough and odd enough to pull somebody back to the machine, which
  is the whole job: a single short blip from the next room is indistin-
  guishable from the machine's own POST. }
procedure Alert;
var I: Integer;
begin
  if Quiet then Exit;
  for I := 1 to 3 do
  begin
    Tone(1760, 3);
    Tone(1175, 3);
  end;
end;

procedure Usage;
begin
  WriteLn('MOUPROBE ', VER, ' -- find a serial mouse on a USB serial adapter');
  WriteLn;
  WriteLn('  MOUPROBE [/P=260] [/C=n] [/S=secs] [/W] [/M] [/X] [/Q]');
  WriteLn;
  WriteLn('    /P=hex  I/O base, default 260');
  WriteLn('    /C=dec  configuration INDEX; default tries each in turn');
  WriteLn('    /S=dec  seconds to watch for movement, default 12');
  WriteLn('    /W      force Microsoft framing (1200 7N1)');
  WriteLn('    /M      force Mouse Systems framing (1200 8N1)');
  WriteLn('    /X      hex-dump the bytes as well as decoding them');
  WriteLn('    /Q      do not beep when it wants the mouse moved');
  WriteLn;
  WriteLn('A serial mouse is powered from RTS and DTR, so an adapter that');
  WriteLn('cannot raise them leaves the mouse dead -- which looks exactly');
  WriteLn('like a wrong baud rate or an unsupported adapter.  This checks');
  WriteLn('that first, by power-cycling the lines and listening for the');
  WriteLn('identification byte a mouse sends when it wakes up.');
  HelpTail;
end;

function NumArg(const A: ShortString; From: Integer): LongInt;
var V: LongInt; I: Integer;
begin
  V := 0; I := From;
  while (I <= Length(A)) and (A[I] >= '0') and (A[I] <= '9') do
  begin
    V := V * 10 + (Ord(A[I]) - 48);
    Inc(I);
  end;
  NumArg := V;
end;

function HexArg(const A: ShortString; From: Integer): Word;
var V, I: Integer; C: Char;
begin
  V := 0;
  for I := From to Length(A) do
  begin
    C := UpCase(A[I]);
    if (C >= '0') and (C <= '9') then V := V * 16 + (Ord(C) - 48)
    else if (C >= 'A') and (C <= 'F') then V := V * 16 + (Ord(C) - 55)
    else Break;
  end;
  HexArg := V;
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S);
  Dec1 := S;
end;

{ Read whatever has arrived, for at most Limit ticks.  Returns the count.
  Bytes go into Buf up to Max; everything is counted either way. }
function Listen(var Buf; Max: Word; Limit: LongInt; Echo: Boolean): Word;
var
  Tmp   : array[0..63] of Byte;
  P     : PByte;
  Got   : Byte;
  N     : Word;
  T0    : LongInt;
  I     : Integer;
begin
  P := @Buf;
  N := 0;
  T0 := Ticks;
  while True do
  begin
    if Ticks < T0 then T0 := Ticks;
    if (Ticks - T0) >= Limit then Break;
    if KeyWaiting then begin EatKey; Break; end;
    if SerRecv(Dev, Tmp, SizeOf(Tmp), Got) then
      if Got > 0 then
        for I := 0 to Integer(Got) - 1 do
        begin
          if N < Max then
          begin
            P[N] := Tmp[I];
            Inc(N);
          end;
          if Echo then Write(StdErr, Hex2(Tmp[I]), ' ');
        end;
  end;
  Listen := N;
end;

procedure DumpBytes(const Buf; Len: Word);
var
  P : PByte;
  I : Word;
  S : ShortString;
begin
  P := @Buf;
  S := '';
  for I := 0 to Len - 1 do
  begin
    Write('  ', Hex2(P[I]));
    if (P[I] >= 32) and (P[I] < 127) then S := S + Chr(P[I]) else S := S + '.';
    if ((I + 1) mod 16) = 0 then
    begin
      WriteLn('   ', S);
      S := '';
    end;
  end;
  if S <> '' then
  begin
    for I := (Len mod 16) to 15 do Write('    ');
    WriteLn('   ', S);
  end;
end;

{ Open the port for a protocol, power-cycling the lines on the way in so a
  mouse that announces itself gets the chance.  RxBatch is 1 because a
  mouse report is three bytes and must not sit in the adapter waiting for
  a fourth: SerBatchFor would say 8 here, which is right for a terminal
  and wrong for a pointing device. }
function OpenFor(P: TMouseProto): Boolean;
begin
  { ONE OPEN.  This used to open, close and open again, to force a power
    cycle so a Microsoft mouse would announce itself with 'M'.

    Two reasons that is gone.  The announcement is no longer relied on --
    the protocol is read out of the stream, which works for a mouse that
    says nothing and for one that is being moved while it speaks.  And the
    close/open pair was actively harmful on a PL2303: it left the adapter
    delivering nothing at all, intermittently, which presents as an
    unpowered mouse and sent this tool chasing RTS and DTR.

    SerOpen raises RTS and DTR, so a mouse that was unpowered gets its
    power-on here anyway. }
  OpenFor := SerOpen(Dev, MOUSE_BAUD, ProtoBits(P), 0, 1, 1);
  if OpenFor then DelayMs(300);
end;

{ Try one framing: wake the mouse, capture whatever it says, then ask for
  movement.  Returns the protocol if it is convinced, mpUnknown if not. }
function TryFraming(P: TMouseProto; var Moved: Boolean;
                    var Diag: TMouseProto; var DiagBits: Boolean): TMouseProto;
var
  IdBuf  : array[0..63] of Byte;
  Stream : array[0..1023] of Byte;
  IdLen  : Word;
  SLen   : Word;
  Saw      : TMouseProto;
  Use      : TMouseProto;
  WrongBits: Boolean;
  Dec_   : TMouseDec;
  Ev     : TMouseEvent;
  I      : Word;
  TotX, TotY : LongInt;
  Btns   : Byte;
begin
  TryFraming := mpUnknown;
  Moved := False;
  Diag := mpUnknown;
  DiagBits := False;

  WriteLn;
  WriteLn('TRYING ', ProtoName(P));
  WriteLn('----------------------------------------------------------------');
  Stage('open');
  if not OpenFor(P) then
  begin
    WriteLn('  the port would not open at ', MOUSE_BAUD, ' ',
            ProtoBits(P), 'N1');
    Exit;
  end;

  Stage('wake');
  IdLen := Listen(IdBuf, SizeOf(IdBuf), 27, False);   { about 1.5 s }
  if IdLen > 0 then
  begin
    WriteLn('  the mouse said ', IdLen, ' byte(s) when its power came up:');
    DumpBytes(IdBuf, IdLen);
    Saw := IdentifyId(IdBuf, IdLen);
    if Saw <> mpUnknown then
      WriteLn('  that identifies it as ', ProtoName(Saw));
  end
  else
  begin
    { NOT a failure on its own.  Mouse Systems mice announce nothing at
      all, so silence here is expected for one of the two protocols and
      says nothing about the other. }
    WriteLn('  nothing on power-up.  Expected for Mouse Systems, and a bad');
    WriteLn('  sign for Microsoft -- carrying on to the movement test,');
    WriteLn('  which is the one that settles it.');
  end;

  WriteLn;
  WriteLn('  *** MOVE THE MOUSE AND CLICK ITS BUTTONS, for ', Secs, 's ***');
  Flush(Output);
  WriteLn(StdErr, '');
  WriteLn(StdErr, '  MOVE THE MOUSE NOW -- ', Secs, ' seconds');
  Alert;

  Stage('moving');
  SLen := Listen(Stream, SizeOf(Stream), LongInt(Secs) * 18, ShowHex);
  WriteLn(StdErr, '');

  WriteLn;
  WriteLn('  ', SLen, ' byte(s) arrived while you were moving it.');
  if SLen = 0 then
  begin
    WriteLn('  Nothing at all.  Check these IN ORDER, cheapest first:');
    WriteLn('    1. IS THE MOUSE ACTUALLY MOVING?  A serial mouse sends');
    WriteLn('       nothing at all when it is still, so a hand that missed');
    WriteLn('       the window, or a jiggler that has stopped or drifted,');
    WriteLn('       looks EXACTLY like dead hardware from here.');
    WriteLn('    2. Is the mouse plugged into the adapter?');
    WriteLn('    3. Only then doubt the framing, or whether this adapter');
    WriteLn('       really asserts RTS and DTR -- which is what powers it.');
    SerClose(Dev);
    Exit;
  end;
  if SLen <= 64 then DumpBytes(Stream, SLen)
  else
  begin
    WriteLn('  first 64:');
    DumpBytes(Stream, 64);
  end;

  Saw := IdentifyStreamEx(Stream, SLen, WrongBits);
  Diag := Saw;
  DiagBits := WrongBits;
  WriteLn;
  if WrongBits then
  begin
    WriteLn('  THE FRAMING IS WRONG AND THE MOUSE IS FINE.');
    WriteLn;
    WriteLn('  These bytes are a Mouse Systems stream read through SEVEN');
    WriteLn('  data bits: 87h headers arriving as 07h, every fifth byte,');
    WriteLn('  and negative movement as 7Fh/7Eh/7Ch instead of FFh/FEh/FCh.');
    WriteLn('  Bit 7 is being stripped by the line settings, not by the');
    WriteLn('  mouse.  Re-run with /M, or let the automatic path do it.');
  end
  else if Saw = mpUnknown then
    WriteLn('  The byte pattern does not fit either protocol cleanly.')
  else
    WriteLn('  The byte pattern fits ', ProtoName(Saw), '.');

  { DECODE WITH THE PROTOCOL THE STREAM SAID, not the one we came in with.

    This used to decode with P -- the framing being tried -- which made
    sense when the framing and the protocol were the same choice, because
    one needed seven data bits and the other eight.  They are not the same
    choice any more: the port is opened at 8N1 either way and the stream
    decides.  Decoding a Microsoft stream with Mouse Systems rules then
    produced 96 reports against 138 resyncs and a third button that does
    not exist on the mouse, directly under a line correctly identifying it
    as Microsoft. }
  Use := P;
  if Saw <> mpUnknown then Use := Saw;
  MouseInit(Dec_, Use);
  TotX := 0; TotY := 0; Btns := 0;
  for I := 0 to SLen - 1 do
    if MouseFeed(Dec_, Stream[I], Ev) then
    begin
      TotX := TotX + Ev.DX;
      TotY := TotY + Ev.DY;
      Btns := Btns or Ev.Buttons;
    end;

  WriteLn;
  WriteLn('  decoded as         : ', ProtoName(Use));
  WriteLn('  reports decoded    : ', Dec_.Reports);
  WriteLn('  bytes resynced past: ', Dec_.Resyncs);
  WriteLn('  net movement       : X ', TotX, '  Y ', TotY);
  Write  ('  buttons seen       : ');
  if Btns = 0 then Write('none')
  else
  begin
    if (Btns and $01) <> 0 then Write('left ');
    if (Btns and $02) <> 0 then Write('right ');
    if (Btns and $04) <> 0 then Write('middle ');
  end;
  WriteLn;

  SerClose(Dev);

  if Dec_.Reports = 0 then Exit;
  Moved := (TotX <> 0) or (TotY <> 0) or (Btns <> 0);
  { Convinced only if the reports decode AND the resync count is not
    telling us we are reading noise: a wrong framing produces plenty of
    "reports" and a resync count of the same order. }
  if Dec_.Resyncs < Dec_.Reports then TryFraming := Use;
end;

var
  Moved   : Boolean;
  Diag    : TMouseProto;
  DiagBits: Boolean;
  CfgIdx  : Integer;
  Found   : Boolean;
  I       : Integer;
  S       : ShortString;

begin
  Banner('MOUPROBE', VER, 'serial mouse over a USB-to-serial adapter');
  if HelpWanted then begin Usage; Halt(0); end;

  WantCfg := -1; Secs := 12;
  ForceW := False; ForceM := False; ShowHex := False; Quiet := False;

  { ---- arguments ---- }
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base    := HexArg(S, 4);
      'C': WantCfg := NumArg(S, 4);
      'S': Secs    := NumArg(S, 4);
      'W': ForceW  := True;
      'M': ForceM  := True;
      'X': ShowHex := True;
      'Q': Quiet   := True;
    end;
  end;
  if Secs < 2 then Secs := 2;
  if Secs > 120 then Secs := 120;

  WriteLn('I/O base ', Hex4(Base), 'h');
  ExitProc := @Quieten;

  { ---- bring up, and find a configuration that is a serial adapter ----

    Trying each configuration in turn rather than taking the first is what
    keeps this adapter-agnostic.  The Keyspan on this bench declares TWO,
    and only the second carries a bulk pair -- its first has interrupt
    endpoints where the data should be.  A tool that assumed index 0 would
    conclude "not a serial adapter" about a serial adapter. }
  Found := False;
  CfgIdx := 0;
  if WantCfg >= 0 then CfgIdx := WantCfg;
  while CfgIdx <= 3 do
  begin
    Stage('config ' + Dec1(CfgIdx));
    Rc := BringUpCfg(Byte(CfgIdx), Big, BigLen, Why);
    if Rc <> BU_OK then
    begin
      if (WantCfg >= 0) or (CfgIdx > 0) then
      begin
        WriteLn(BusUpReason(Rc));
        if Why <> '' then WriteLn('  ', Why);
        if Rc >= BU_NOTHING then WhyNoAnswer;
        Halt(Rc);
      end;
    end
    else
    begin
      VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
      PID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
      if SerDetect(Big, BigLen, VID, PID, Dev) then
        if SerSupported(Dev.Family) and (Dev.EpIn <> 0) and (Dev.EpOut <> 0) then
        begin
          Found := True;
          Break;
        end;
    end;
    if WantCfg >= 0 then Break;
    Inc(CfgIdx);
  end;

  if not Found then
  begin
    WriteLn;
    WriteLn('No configuration on this device looks like a serial adapter');
    WriteLn('this project can drive.  SERPROBE prints every configuration');
    WriteLn('and every endpoint, which is the tool for working out why.');
    Halt(6);
  end;

  WriteLn('  device              : ', Hex4(VID), ':', Hex4(PID));
  WriteLn('  family              : ', SerFamilyName(Dev.Family));
  WriteLn('  configuration index : ', CfgIdx);
  WriteLn('  bulk IN / OUT       : ', Hex2(Dev.EpIn or $80), ' / ',
          Hex2(Dev.EpOut));

  { ---- try the framings ---- }
  Proto := mpUnknown;
  Moved := False;

  if ForceM then
    Proto := TryFraming(mpMouseSys, Moved, Diag, DiagBits)
  else if ForceW then
    Proto := TryFraming(mpMicrosoft, Moved, Diag, DiagBits)
  else
  begin
    { ONE WINDOW, because one framing now reads both protocols.

      This used to ask for movement twice -- once at 7N1 for Microsoft and
      once at 8N1 for Mouse Systems -- because the framing had to be chosen
      before the port could be opened.  At 8N1 the two occupy header ranges
      that do not overlap, so the stream says which it is and the second
      request for somebody to wave a mouse is gone. }
    Proto := TryFraming(mpMouseSys, Moved, Diag, DiagBits);
    if (Diag <> mpUnknown) and (Diag <> Proto) then Proto := Diag;
  end;

  WriteLn;
  WriteLn('RESULT');
  WriteLn('----------------------------------------------------------------');
  Stage('done');
  if (Proto <> mpUnknown) and Moved then
  begin
    WriteLn('  A serial mouse is working on this adapter.');
    WriteLn('  Protocol: ', ProtoName(Proto));
    WriteLn;
    WriteLn('  That proves the whole chain: the CH375, the USB adapter, the');
    WriteLn('  control lines powering the mouse, the framing, and the');
    WriteLn('  decode.  Nothing above is specific to this adapter -- the');
    WriteLn('  mouse half lives in dmouse.pas and never sees a USB device.');
    Halt(0);
  end;
  if Proto <> mpUnknown then
  begin
    WriteLn('  Reports decoded, but nothing moved.  If the mouse was not');
    WriteLn('  touched, run it again and move it.');
    Halt(8);
  end;

  { A tool that prints "the framing is wrong and the mouse is fine" and
    then signs off with "no protocol fitted" has contradicted itself, and
    the reader has no way to know which half to believe.  The diagnosis
    from the stream outranks the failure of the framing it was told to
    use, because the diagnosis is the more specific fact. }
  if Diag <> mpUnknown then
  begin
    WriteLn('  A mouse IS attached and talking: ', ProtoName(Diag));
    if DiagBits then
    begin
      WriteLn;
      WriteLn('  It was read with the wrong number of data bits, so the');
      WriteLn('  decode above is meaningless while the identification is');
      WriteLn('  not.  Run it again with the right framing:');
      WriteLn;
      if Diag = mpMouseSys then WriteLn('      MOUPROBE /M')
                           else WriteLn('      MOUPROBE /W');
    end;
    Halt(9);
  end;

  WriteLn('  No protocol fitted.  The port opened and the lines were');
  WriteLn('  raised, so the adapter did its part.');
  WriteLn;
  WriteLn('  Doubt the boring things first.  A serial mouse is silent');
  WriteLn('  unless it MOVES, so "no bytes" is what a still mouse looks');
  WriteLn('  like, and it is indistinguishable from dead hardware here.');
  WriteLn('  Confirm it moved during the window, and that it is plugged');
  WriteLn('  into the adapter, BEFORE doubting RTS and DTR.  That order');
  WriteLn('  is written down because an evening went the other way: this');
  WriteLn('  message named RTS and DTR first, and the real cause was a');
  WriteLn('  close/open sequence wedging a PL2303.');
  Halt(7);
end.
