program daiso;
{ DAISO -- try to push audio at a USB speaker's isochronous endpoint from a
  CH375, and measure exactly how it fails.
  CH375Audio, StevenC & Claude.  Public domain (the Unlicense).

    DAISO [/P=260] [/N=n] [/GO] [/T]

      /P=hex   I/O base, default 260
      /N=dec   packets to attempt in the rate test, default 200
      /GO      actually send. Without it, nothing is transmitted and the
               tool only reports what it WOULD have to do
      /T       trace every control-transfer stage

  WHY A TOOL FOR SOMETHING THAT CANNOT WORK

  Because "it cannot work" is a claim, and this collection's habit is to
  measure claims.  CH375Video spent a night discovering that an FL2000
  display adapter was architecturally impossible; the note that saved the
  NEXT person was the one that said what was tried and what the numbers
  were.  This is that note for audio, in runnable form.

  It is also insurance against being wrong.  If a future chip revision, a
  different speaker with a 64-byte alternate setting, or a cleverer idea
  turns up, this tool is where it gets tested -- and it will say so rather
  than being talked out of it by a comment.

  WHAT IT DOES

    1. SET_INTERFACE on the streaming interface to its non-zero alternate
       setting.  That is what arms an audio endpoint: alt 0 has no
       endpoints at all, which is the class's way of idling.  This part
       genuinely works -- it is a standard control transfer.

    2. Look at what the endpoint then demands, and compare it with what
       the chip can express.  This is where it ends, and the comparison is
       printed rather than asserted.

    3. With /GO, actually issue OUT tokens at the endpoint and time them.
       The chip will report something; whatever it reports is printed.

  WHAT "SUCCESS" WOULD EVEN LOOK LIKE, since that is worth being precise
  about before running anything: a 48 kHz 16-bit stereo stream needs one
  192-byte packet every single millisecond, forever, with no gaps.  A
  packet that is late is not a delayed packet, it is a click.  So the bar
  is not "some bytes moved" -- it is "192 bytes moved, 1000 times a
  second, without missing one".  Nothing here comes close, and the gap is
  large enough that it is not a tuning problem.

  IT PUTS THE INTERFACE BACK.  Leaving a streaming interface armed means
  the device is expecting a packet every millisecond from a host that has
  stopped talking, which on some hardware is a wedge that outlives the
  program.  Alt 0 on the way out, on every path. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, daudio;

const
  VER = '1.0.2';
  RT_SET_IF = $01;              { host->device, standard, interface }

var
  Big     : TBigCfg;
  BigLen  : Word;
  Why     : ShortString;
  StreamIf: Integer;            { interface with an isochronous OUT }
  StreamAlt: Integer;
  IsoEp   : Byte;
  IsoMax  : Word;
  Armed   : Boolean;
  Packets : Integer;
  Go      : Boolean;
  Hammer  : Integer;
  Zero    : Boolean;
  Fast    : Boolean;
  PktLen  : Byte;
  Spins   : LongInt;
  Elapsed2: LongInt;
  I       : Integer;
  S       : ShortString;
  Rc      : Integer;

function Dec1(V: LongInt): ShortString;
var T: ShortString;
begin
  Str(V, T);
  Dec1 := T;
end;

procedure Fld(const N, V: ShortString);
var T: ShortString;
begin
  T := '  ' + N;
  while Length(T) < 22 do T := T + ' ';
  WriteLn(T, ': ', V);
end;

procedure Narrate(const Line: ShortString);
begin
  WriteLn(Line);
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

{ Find a streaming interface whose non-zero alternate setting carries an
  isochronous OUT endpoint. }
procedure FindIso;
var
  P    : Word;
  L, T : Byte;
  CurIf, CurAlt: Integer;
  Cls, Sub: Byte;
begin
  StreamIf := -1; StreamAlt := 0; IsoEp := 0; IsoMax := 0;
  P := 0; CurIf := -1; CurAlt := 0; Cls := 0; Sub := 0;
  while P + 2 <= BigLen do
  begin
    L := Big[P];
    T := Big[P + 1];
    if (L = 0) or (P + L > BigLen) then Break;
    if T = $04 then
    begin
      CurIf := Big[P + 2];
      CurAlt := Big[P + 3];
      Cls := Big[P + 5];
      Sub := Big[P + 6];
    end
    else if (T = $05) and (Cls = CLASS_AUDIO) and (Sub = AS_SUBCLASS) then
    begin
      if ((Big[P + 3] and $03) = 1)            { isochronous }
         and ((Big[P + 2] and $80) = 0)        { OUT }
         and (StreamIf < 0) then
      begin
        StreamIf := CurIf;
        StreamAlt := CurAlt;
        IsoEp := Big[P + 2] and $0F;
        IsoMax := Big[P + 4] or (Word(Big[P + 5]) shl 8);
      end;
    end;
    Inc(P, L);
  end;
end;

{ Issue an OUT token and DO NOT wait for the handshake.

  EpOut waits (WaitInt) for an acknowledgement that an isochronous endpoint
  never sends, so every packet costs a full timeout and the measured rate --
  131 packets a second -- is the cost of waiting, not the cost of sending.
  The endpoint needs 1000 a second. This is the honest ceiling test: shove
  the bytes at the chip, issue the token, and move on.

  It is deliberately NOT in ch375.pas. Every other transfer in this
  collection wants its status, and a fire-and-forget send that silently
  loses errors is the wrong default for a bulk or control transfer. Here it
  is the only thing that matches the semantics of the endpoint. }
procedure FireOut(Ep: Byte; var Tog: Byte; const B; Len: Byte);
var
  P: PByte;
  I: Byte;
begin
  P := @B;
  WrCmd(CMD_WR_USB_DATA7); WrDat(Len);
  for I := 0 to Len - 1 do WrDat(P[I]);
  WrCmd(CMD_SET_ENDP7); WrDat(Tog);
  WrCmd(CMD_ISSUE_TOKEN); WrDat((Ep shl 4) or PID_OUT);
  Tog := Tog xor $40;
end;

function SetAlt(Alt: Integer): Integer;
begin
  SetAlt := CtrlNoData(RT_SET_IF, REQ_SET_IFACE, Word(Alt), Word(StreamIf));
end;

procedure Disarm;
begin
  if not Armed then Exit;
  Armed := False;
  if SetAlt(0) = INT_SUCCESS then
    WriteLn('  interface ', StreamIf, ' put back to alt 0 (idle)')
  else
    WriteLn('  WARNING: could not return interface ', StreamIf,
            ' to alt 0.');
end;

procedure CleanUp;
begin
  Disarm;
  Quieten;
end;

{ A square wave, so that if anything ever DID come out of the speaker it
  would be unmistakable rather than a plausible-sounding hiss. 16-bit
  signed stereo, which is the only format this device offers. }
procedure FillTone(var B: array of Byte; Len: Word);
var
  I: Word;
  Up: Boolean;                  { NOT "Hi" -- that shadows the Hi() we need }
  V: Integer;
begin
  Up := True;
  I := 0;
  while I + 3 < Len do
  begin
    if (I mod 48) = 0 then Up := not Up;
    if Up then V := 8000 else V := -8000;
    B[I]     := Lo(Word(V));
    B[I + 1] := Hi(Word(V));
    B[I + 2] := Lo(Word(V));
    B[I + 3] := Hi(Word(V));
    Inc(I, 4);
  end;
end;

{ UAC1 endpoint control: the SAMPLING FREQUENCY.

  Worth trying even though bSamFreqType says one discrete rate, because
  that field describes what the device ADVERTISES and a few implementations
  accept more than they advertise. If a lower rate were accepted the whole
  arithmetic changes: 8 kHz 16-bit stereo is 32 bytes a frame, which fits
  in the chip's 64-byte buffer, and 8 kHz MONO is 16,000 bytes/s, which is
  under the 19,055 this chip has been measured at. That would turn a wall
  into a merely difficult problem, so it is the first thing to rule out.

  Note the recipient is the ENDPOINT (22h), not the interface -- sampling
  frequency is an endpoint control in UAC1, and sending it to the interface
  is a stall that looks like a refusal of the rate rather than of the
  address. }
function TrySampleRate(Hz: LongInt): Boolean;
var
  B  : array[0..3] of Byte;
  Got: Word;
  R  : Integer;
  RB : LongInt;
begin
  B[0] := Byte(Hz and $FF);
  B[1] := Byte((Hz shr 8) and $FF);
  B[2] := Byte((Hz shr 16) and $FF);
  R := CtrlOut($22, $01, $0100, Word(IsoEp), B, 3);
  Write('  SET_CUR sample rate ', Hz, ' Hz -> ', StatusName(R));
  if R <> INT_SUCCESS then
  begin
    WriteLn;
    TrySampleRate := False;
    Exit;
  end;
  { Accepting the write is not the same as honouring it. Read it back. }
  B[0] := 0; B[1] := 0; B[2] := 0;
  R := CtrlIn($A2, $81, $0100, Word(IsoEp), 3, B, SizeOf(B), Got);
  if (R = INT_SUCCESS) and (Got >= 3) then
  begin
    RB := LongInt(B[0]) or (LongInt(B[1]) shl 8) or (LongInt(B[2]) shl 16);
    WriteLn('   reads back ', RB, ' Hz');
    TrySampleRate := RB = Hz;
  end
  else
  begin
    WriteLn('   (cannot read it back: ', StatusName(R), ')');
    TrySampleRate := False;
  end;
end;

var
  Buf  : array[0..255] of Byte;
  Tog  : Byte;
  T0, T1: LongInt;
  Ok, Fail: Integer;
  Elapsed: LongInt;
  Rate : LongInt;

begin
  Banner('DAISO', VER, 'isochronous playback: the attempt, and the numbers');
  if HelpWanted then
  begin
    WriteLn('  DAISO [/P=260] [/N=n] [/GO] [/T]');
    WriteLn;
    WriteLn('    /N=n  packets to attempt, default 200');
    WriteLn('    /GO   actually transmit. Without it nothing is sent.');
    HelpTail;
    Halt(0);
  end;

  Packets := 200; Go := False; Armed := False; Hammer := 0;
  Zero := False; PktLen := 64; Fast := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    if UpCase(S[2]) = 'P' then Base := HexArg(S, 4)
    else if UpCase(S[2]) = 'N' then Packets := NumArg(S, 4)
    else if UpCase(S[2]) = 'T' then CtrlTrace := True
    else if Copy(UpCase(S), 2, 4) = 'ZERO' then Zero := True
    else if Copy(UpCase(S), 2, 4) = 'FAST' then Fast := True
    else if Copy(UpCase(S), 2, 4) = 'LEN=' then PktLen := Byte(NumArg(S, 6))
    else if Copy(UpCase(S), 2, 7) = 'HAMMER=' then
    begin
      Hammer := NumArg(S, 9);
      Go := True;
    end
    else if (Length(S) >= 3) and (UpCase(S[2]) = 'G')
            and (UpCase(S[3]) = 'O') then Go := True;
  end;
  if Packets < 1 then Packets := 1;
  if CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');

  ExitProc := @CleanUp;
  Rc := BringUp(Big, BigLen, Why);
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Why <> '' then WriteLn('  ', Why);
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  FindIso;
  if StreamIf < 0 then
  begin
    WriteLn;
    WriteLn('  no isochronous OUT endpoint, so there is no playback stream');
    WriteLn('  on this device to attempt. Nothing to do.');
    Halt(6);
  end;

  Fld('streaming iface', Dec1(StreamIf) + ' alt ' + Dec1(StreamAlt));
  Fld('endpoint', Hex2(IsoEp) + ' OUT, isochronous');
  Fld('wMaxPacketSize', Dec1(IsoMax) + ' bytes');
  Fld('needed every', '1 ms  (' + Dec1(LongInt(IsoMax) * 1000)
                      + ' bytes/s)');
  Fld('chip buffer', '64 bytes, and EpOut takes a Byte length');
  Fld('chip measured at', Dec1(CH375_BYTES_PER_SEC) + ' bytes/s');

  WriteLn;
  WriteLn('THE THREE WALLS');
  WriteLn('----------------------------------------------------------------');
  WriteLn('  1. transfer type. Isochronous has NO handshake. EpOut issues a');
  WriteLn('     token and then waits for one (WaitInt), and maintains a data');
  WriteLn('     toggle that isochronous does not use. The chip has no');
  WriteLn('     isochronous mode to select -- its tokens are OUT, IN and');
  WriteLn('     SETUP, used with bulk/interrupt semantics.');
  Write  ('  2. packet size. This endpoint wants ', IsoMax, ' bytes in ONE');
  WriteLn(' packet.');
  WriteLn('     The chip transmits from a 64-byte buffer. Even a perfect');
  if IsoMax > 64 then
    WriteLn('     host could not express this packet.')
  else
    WriteLn('     host could express this one -- unusual, worth noting.');
  Write  ('  3. rate. ', LongInt(IsoMax) * 1000, ' bytes/s required against ');
  WriteLn(CH375_BYTES_PER_SEC, ' measured,');
  WriteLn('     and the deadline is hard: a late packet is a click, not a');
  WriteLn('     delay. This is a factor of ',
          (LongInt(IsoMax) * 1000) div CH375_BYTES_PER_SEC, '.');

  if not Go then
  begin
    WriteLn;
    WriteLn('  /GO was not given, so nothing was transmitted.');
    WriteLn('  Add /GO to arm the interface and try it anyway.');
    Halt(0);
  end;

  WriteLn;
  WriteLn('ARMING AND ATTEMPTING');
  WriteLn('----------------------------------------------------------------');
  Rc := SetAlt(StreamAlt);
  WriteLn('  SET_INTERFACE ', StreamIf, ' alt ', StreamAlt, ' -> ',
          StatusName(Rc));
  if Rc <> INT_SUCCESS then
  begin
    WriteLn('  the device would not arm the stream, so nothing can be sent.');
    Halt(5);
  end;
  Armed := True;

  { Before sending a byte: will it take a slower rate? This is the only
    thing that could move the arithmetic, so it is asked first. }
  WriteLn;
  WriteLn('  asking for a slower rate (the only thing that could help):');
  if TrySampleRate(8000) then
    WriteLn('  *** 8000 Hz ACCEPTED -- re-read the verdict above, it is wrong')
  else if TrySampleRate(16000) then
    WriteLn('  *** 16000 Hz ACCEPTED -- re-read the verdict above')
  else
  begin
    TrySampleRate(48000);
    WriteLn('  no slower rate is honoured; 48 kHz stereo is the only format.');
  end;
  WriteLn;

  if PktLen < 4 then PktLen := 4;
  if PktLen > 64 then PktLen := 64;
  FillTone(Buf, PktLen);
  { $80 like every other polling tool here; BringUp has already put the
    retry count back to 0 so a refusal comes straight back instead of the
    chip grinding on it. }
  Tog := $80;
  Ok := 0; Fail := 0;
  T0 := Ticks;
  for I := 1 to Packets do
  begin
    { 64 bytes is the most the chip can be asked for -- already wrong for
      an endpoint that wants IsoMax, but this is the best case and the
      best case is the one worth measuring. }
    Rc := EpOut(IsoEp, Tog, Buf, 64);
    if Rc = INT_SUCCESS then Inc(Ok) else Inc(Fail);
    if I = 1 then
      WriteLn('  first packet -> ', StatusName(Rc), ' (', Rc, ')');
  end;
  T1 := Ticks;

  Elapsed := T1 - T0;
  if Elapsed < 1 then Elapsed := 1;
  WriteLn('  attempted ', Packets, ' packets of 64 bytes');
  WriteLn('    accepted by the chip : ', Ok);
  WriteLn('    refused              : ', Fail);
  { 18.2 ticks/s; x10 then /182 keeps it in LongInt without floating point. }
  Rate := (LongInt(Ok) * 64 * 182) div (Elapsed * 10);
  WriteLn('    elapsed              : ', Elapsed, ' ticks (~',
          (Elapsed * 10) div 182, '.', ((Elapsed * 1000) div 182) mod 10,
          ' s)');
  WriteLn('    throughput           : ', Rate, ' bytes/s');
  WriteLn('    needed               : ', LongInt(IsoMax) * 1000, ' bytes/s');

  WriteLn;
  if Ok = 0 then
  begin
    WriteLn('  Nothing was ACCEPTED, which is the expected answer: an');
    WriteLn('  isochronous endpoint does not hand back the handshake the');
    WriteLn('  chip is waiting for, so every transfer times out.');
    WriteLn;
    WriteLn('  That is NOT the same as nothing arriving. An OUT token puts');
    WriteLn('  its packet on the wire before any handshake is due, and');
    WriteLn('  measurement at the speaker says the bytes do land: recorded');
    WriteLn('  from the headphone jack, the noise floor is -44 dB, silent');
    WriteLn('  packets give -30 dB and a full-scale square wave -20 dB. The');
    WriteLn('  content changes the output by 10 dB, so it is being carried.');
    WriteLn;
    WriteLn('  What comes out is a broadband click-train at the PACKET rate,');
    WriteLn('  not the waveform -- the device is starved 95% of the time and');
    WriteLn('  what you hear is it reacting to that. Controllable noise, not');
    WriteLn('  playback. /HAMMER and /ZERO are how that was measured.');
  end
  else
  begin
    WriteLn('  Some packets were accepted. That is NOT playback: they are');
    WriteLn('  64-byte fragments of a stream that wants ', IsoMax,
            '-byte frames on');
    WriteLn('  a 1 ms clock, so the device receives malformed audio at a');
    WriteLn('  fraction of the rate. Worth recording, not worth building on.');
  end;

  { ---- the listening test ------------------------------------------
    The counters above say the CHIP was not satisfied. They do NOT say
    nothing reached the speaker: an OUT token puts its packet on the wire
    before any handshake is due, so the device may well be receiving
    malformed audio while the chip reports a timeout. The only way to
    settle that is to make a noise and listen, which is what /HAMMER is
    for -- it sends flat out for long enough to record from the other end
    of the speaker's headphone jack. A square wave at full scale, because
    the question is "is there ANY sound", not "is it accurate". }
  if Hammer > 0 then
  begin
    WriteLn;
    WriteLn('HAMMERING FOR ', Hammer, 's -- record the speaker now');
    WriteLn('----------------------------------------------------------------');
    { /ZERO fills the packet with silence instead of a square wave. It is
      the control for the whole listening test: if the speaker is loud for
      a tone and quiet for zeros, then the CONTENT is getting through and
      we are genuinely driving it. If both are equally loud, the noise is
      the device reacting to a broken stream and nothing is being carried. }
    if Zero then
    begin
      for I := 0 to 255 do Buf[I] := 0;
      WriteLn('  sending SILENCE (all zero packets)');
    end
    else
      WriteLn('  sending a full-scale square wave');
    Ok := 0; Fail := 0;
    T0 := Ticks;
    Spins := 0;
    while True do
    begin
      Elapsed := Ticks - T0;
      if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
      if Elapsed >= LongInt(Hammer) * 182 div 10 then Break;
      Inc(Spins);
      if Spins > 2000000 then Break;
      if KeyWaiting then begin EatKey; Break; end;
      if Fast then
      begin
        FireOut(IsoEp, Tog, Buf, PktLen);
        Inc(Fail);              { no status to have; counted as un-acked }
      end
      else if EpOut(IsoEp, Tog, Buf, PktLen) = INT_SUCCESS then Inc(Ok)
                                                           else Inc(Fail);
    end;
    Elapsed := Ticks - T0;
    if Elapsed < 1 then Elapsed := 1;
    WriteLn('  packets attempted : ', Ok + Fail);
    WriteLn('  accepted          : ', Ok);
    WriteLn('  attempts/second   : ', (LongInt(Ok + Fail) * 182) div
            (Elapsed * 10));
    WriteLn('  bytes/s if all landed: ',
            ((LongInt(Ok + Fail) * 64) * 182) div (Elapsed * 10));
    WriteLn('  needed            : ', LongInt(IsoMax) * 1000, ' bytes/s');
  end;

  Disarm;
  WriteLn;
  WriteLn('=== done ===');
  Halt(0);
end.
