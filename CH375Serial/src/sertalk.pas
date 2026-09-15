program sertalk;
{ SERTALK -- open a USB-to-serial port, send a string, and print what
  comes back.
  CH375Serial, StevenC.  Public domain (the Unlicense).

    SERTALK [/P=260] [/C=n] [/B=9600] [/S=secs] [/A=text] [/R] [/X] [/T]

      /P=hex   I/O base, default 260
      /C=dec   configuration INDEX.  Default: try each until one yields a
               serial adapter this project can drive
      /B=dec   baud rate, default 9600
      /A=text  send this, followed by CR. Default "AT"
      /S=dec   seconds to listen after sending, default 4
      /R       raw: do not send anything, just listen
      /X       also dump the status pipe
      /T       trace every control-transfer stage

  IT WORKS ON ANY FAMILY dser CAN DRIVE.  The Keyspan arm below is kept
  because it builds the usa90 control message by hand and prints it field
  by field, which is the whole reason this tool exists and which SerOpen
  deliberately hides; every other family goes through SerOpen.  Verified
  against a modem on a Keyspan (06CD:0121) and an FTDI (0403:6001), the
  latter at 9600, 19200, 38400 and 115200.

  WHAT THIS IS AND IS NOT

  It is an experiment with a self-checking answer, not a driver.  The
  Keyspan message format is not published; what is publicly known comes
  from the Linux keyspan driver, and the layout below is RECONSTRUCTED
  rather than copied from a specification.  Reconstructed layouts are
  usually wrong somewhere.

  That would normally make this exactly the kind of guessing this
  collection avoids -- except that the device on the far end settles it
  for us.  A Hayes modem answers "AT" with "OK".  If OK comes back, then
  the control message was understood, the port was enabled, the baud rate
  was close enough, both bulk pipes work, and the whole chain from the host
  through a CH375 through a USB adapter to a serial device is proven --
  regardless of whether every field offset is perfect.  If it does not
  come back, nothing here is proven and this file says so.

  Most modems auto-baud from the "AT" prefix, which is a useful property:
  it means the baud rate only has to be near enough for the modem to lock
  on, rather than exactly what we think we asked for.

  THE MESSAGE

  Keyspan's usa90 control message is a flat block of bytes on a SEPARATE
  control endpoint -- not a USB control transfer, and not the data pipe.
  Its shape is "set flag, then value" for most settings, so a block of
  zeros changes nothing, which makes it safe to send and easy to extend
  one field at a time.  Three fields do the real work here:

    portEnabled    nothing moves until this is 1
    setClocking + baudLo/baudHi   the divisor
    returnStatus   ask for a status message now, so the status pipe
                   stops NAKing and we can see the modem's control lines

  The divisor for this part is baudclk / (baud * 16) with baudclk =
  14,769,231.  At 9600 that is 96.

  Exit codes: 0 something came back, 1 no chip, 2 chip too old,
              3 nothing attached, 5 device stopped answering,
              6 not the family this tool drives,
              7 the port opened but nothing answered }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, dser;

const
  VER = '0.1.0';
  KEYSPAN_BAUDCLK = 14769231;
  NSWEEP = 7;

  { Offsets into the usa90 port control message. Named rather than spelled
    as numbers so that a correction later is one line per field and shows
    up in a diff as what it is. }
  O_SETCLOCKING = 0;
  O_BAUDLO      = 1;
  O_BAUDHI      = 2;
  O_SETLCR      = 3;
  O_LCR         = 4;
  O_SETRXMODE   = 5;
  O_RXMODE      = 6;
  O_SETTXMODE   = 7;
  O_TXMODE      = 8;
  O_SETTXFLOW   = 9;
  O_TXFLOW      = 10;
  O_SETRXFLOW   = 11;
  O_RXFLOW      = 12;
  O_SENDXOFF    = 13;
  O_SENDXON     = 14;
  O_XONCHAR     = 15;
  O_XOFFCHAR    = 16;
  O_SENDCHAR    = 17;
  O_TXCHAR      = 18;
  O_SETRTS      = 19;
  O_RTS         = 20;
  O_SETDTR      = 21;
  O_DTR         = 22;
  O_RXFWDLEN    = 23;
  O_RXFWDTMO    = 24;
  O_TXACK       = 25;
  O_PORTENABLED = 26;
  O_TXFLUSH     = 27;
  O_TXBREAK     = 28;
  O_LOOPBACK    = 29;
  O_RXFLUSH     = 30;
  O_RXFORWARD   = 31;
  O_CANCELXOFF  = 32;
  O_RETSTATUS   = 33;
  CTRLMSG_LEN   = 34;

  { lcr, as the 16550-style byte everyone uses }
  DATABITS_8    = $03;
  STOPBITS_1    = $00;
  PARITY_NONE   = $00;

const
  SweepRates: array[0..NSWEEP - 1] of LongInt =
    (9600, 19200, 38400, 2400, 57600, 115200, 1200);

var
  Big     : TBigCfg;
  BigLen  : Word;
  Why     : ShortString;
  Dev     : TSerDev;
  VID, PID: Word;
  WantCfg : Integer;
  CfgIdx  : Integer;
  Found   : Boolean;
  Baud    : LongInt;
  Secs    : Integer;
  Send    : ShortString;
  RawOnly : Boolean;
  Loop    : Boolean;
  Sweep   : Boolean;
  Lines   : Boolean;
  ShowStat: Boolean;
  RawHex  : Boolean;
  FwdLen  : Byte;
  Dial    : ShortString;
  I       : Integer;
  S       : ShortString;
  Rc      : Integer;
  TogOut, TogIn, TogStat, TogCtl: Byte;
  GotAny  : Boolean;

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
  while Length(T) < 20 do T := T + ' ';
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

{ Print a buffer as hex and as text side by side. A modem's answer is
  readable ASCII, so seeing it as text is the whole point; the hex is
  there because CR and LF are the bytes that tell you the framing is
  right and they are invisible otherwise. }
procedure Show(const Tag: ShortString; var B: array of Byte; N: Byte);
var K: Integer;
begin
  Write('  ', Tag, ' ', N:2, ':');
  for K := 0 to N - 1 do
  begin
    if K = 16 then Break;
    Write(' ', Hex2(B[K]));
  end;
  if N > 16 then Write(' ..');
  Write('  |');
  for K := 0 to N - 1 do
  begin
    if K = 24 then Break;
    if (B[K] >= 32) and (B[K] < 127) then Write(Chr(B[K])) else Write('.');
  end;
  WriteLn('|');
end;

{ Decode the usa90 status message.

  Fourteen bytes, and the length is the first evidence the layout is right:
  the reconstructed struct is exactly 14 and the adapter sends exactly 14.

    0 msr   1 cts   2 dcd   3 dsr   4 ri
    5 txXoff  6 rxBreak  7 rxOverrun  8 rxParity  9 rxFrame
   10 portState  11 messageAck  12 charAck  13 controlResponse

  portState bit 7 is "enabled", which is the single most useful bit here:
  it says whether the control message actually opened the port, as opposed
  to being accepted and ignored. }
procedure ShowStatus(var B: array of Byte; N: Byte);
var S: ShortString;
begin
  if N < 14 then
  begin
    Show('ST', B, N);
    WriteLn('     (', N, ' bytes -- not the 14 a usa90 status message has)');
    Exit;
  end;
  S := '';
  if (B[0] and $10) <> 0 then S := S + 'CTS ';
  if (B[0] and $20) <> 0 then S := S + 'DSR ';
  if (B[0] and $40) <> 0 then S := S + 'RI ';
  if (B[0] and $80) <> 0 then S := S + 'DCD ';
  if S = '' then S := '(none asserted)';
  Write('  STATUS  msr ', Hex2(B[0]), '  ', S);
  if (B[10] and $80) <> 0 then Write(' | port ENABLED')
                          else Write(' | port disabled');
  if (B[10] and $40) <> 0 then Write(' txbreak');
  if (B[10] and $20) <> 0 then Write(' LOOPBACK');
  if B[13] <> 0 then Write(' | control ack ', B[13]);
  if B[11] <> 0 then Write(' | msgAck ', B[11]);
  if B[12] <> 0 then Write(' | TX-ACK ', B[12]);
  if B[7] <> 0 then Write(' | overrun ', B[7]);
  if B[8] <> 0 then Write(' | parity ', B[8]);
  if B[9] <> 0 then Write(' | framing ', B[9]);
  WriteLn;
end;

{ Ask for one status message and print it. Used by the line test, where
  the whole question is what the inputs read after an output changed. }
procedure ReadStatusOnce;
var
  Buf : array[0..79] of Byte;
  Got : Byte;
  R   : Integer;
  T0  : LongInt;
  Done: Boolean;
begin
  Done := False;
  T0 := Ticks;
  while (not Done) and (Ticks - T0 < 36) do
  begin
    if Dev.EpStatIn = 0 then Exit;     { no status pipe on this family }
    R := EpIn(Dev.EpStatIn, TogStat, Buf, SizeOf(Buf), Got);
    if (R = INT_SUCCESS) and (Got >= 14) then
    begin
      if (Buf[0] and $10) <> 0 then Write('CTS ') else Write('cts ');
      if (Buf[0] and $20) <> 0 then Write('DSR ') else Write('dsr ');
      if (Buf[0] and $80) <> 0 then Write('DCD ') else Write('dcd ');
      if (Buf[0] and $40) <> 0 then Write('RI ') else Write('ri ');
      WriteLn(' (msr ', Hex2(Buf[0]), ')');
      Done := True;
    end;
  end;
  if not Done then WriteLn('no status came back');
end;

{ Send a line of text plus CR on the data pipe. }
procedure SendLine(const T: ShortString);
var
  B: array[0..79] of Byte;
  N: Byte;
  K: Integer;
  R: Integer;
begin
  N := 0;
  for K := 1 to Length(T) do
  begin
    if N >= 78 then Break;
    B[N] := Ord(T[K]);
    Inc(N);
  end;
  B[N] := 13; Inc(N);
  WriteLn('  > ', T);
  R := EpOut(Dev.EpOut, TogOut, B, N);
  if R <> INT_SUCCESS then
    WriteLn('    (send -> ', StatusName(R), ')');
end;

{ Build and send the port control message. }
{ Open the port.  The Keyspan arm builds the usa90 message by hand because
  this tool's whole purpose is to show it; every other family goes through
  dser, which is the same code SERTERM and USBMOUSE use. }
function OpenPort(BaudRate: LongInt; Rts, Dtr: Byte): Boolean;
var
  M   : array[0..CTRLMSG_LEN - 1] of Byte;
  Div_: LongInt;
  R   : Integer;
  K   : Integer;
begin
  { Everything except the Keyspan: dser knows the control path for it. }
  if Dev.Family <> sfKeyspan then
  begin
    OpenPort := SerOpen(Dev, BaudRate, 8, 0, 1, SerBatchFor(BaudRate));
    Exit;
  end;

  for K := 0 to CTRLMSG_LEN - 1 do M[K] := 0;

  Div_ := KEYSPAN_BAUDCLK div (BaudRate * 16);
  if Div_ < 1 then Div_ := 1;

  M[O_SETCLOCKING] := 1;
  M[O_BAUDLO]      := Byte(Div_ and $FF);
  M[O_BAUDHI]      := Byte((Div_ shr 8) and $FF);
  M[O_SETLCR]      := 1;
  M[O_LCR]         := DATABITS_8 or STOPBITS_1 or PARITY_NONE;
  M[O_SETRXMODE]   := 1;
  M[O_RXMODE]      := 0;
  M[O_SETTXMODE]   := 1;
  M[O_TXMODE]      := 0;
  M[O_SETTXFLOW]   := 1;
  M[O_TXFLOW]      := 0;              { no flow control: no cable for it }
  M[O_SETRXFLOW]   := 1;
  M[O_RXFLOW]      := 0;
  M[O_SETRTS]      := 1;
  M[O_RTS]         := Rts;
  M[O_SETDTR]      := 1;
  M[O_DTR]         := Dtr;            { a modem wants DTR up }
  { HOW MANY CHARACTERS THE ADAPTER BATCHES BEFORE FORWARDING.

    This was 1 -- forward the instant a byte arrives -- which gives the
    lowest latency and is what a terminal wants. It is also why ATI7 came
    back shredded, and the reason is a number this project already knew.

    One character per USB packet means 960 packets/second at 9600 baud,
    and 9600 is the SLOW setting. A CH375 on a slow host manages a few
    hundred packets/second: CH375Audio measured 131-138/s for 64-byte
    bulk transfers and DLBENCH puts the ceiling around 19 KB/s. So the
    adapter was producing packets several times faster than the host could
    collect them, and the overflow shows up as dropped and torn characters
    -- which reads as a baud-rate or framing fault and is neither.

    Batching fixes it from the right end: ask for whole mouthfuls instead
    of single bytes and the packet rate falls by the batch factor while
    the BYTE rate is unchanged. The timeout is what keeps it responsive --
    a short reply that never reaches the batch size is still forwarded
    after this many milliseconds, so "OK" does not sit waiting for 31 more
    characters that will never come. }
  M[O_RXFWDLEN]    := FwdLen;
  M[O_RXFWDTMO]    := 16;
  { Ask the adapter to acknowledge characters it has actually TRANSMITTED.
    This is what separates "the modem ignored us" from "the bytes never
    left the adapter" -- without it, a dead TX line and a deaf modem look
    identical from here. charAck in the status message then counts what
    went out. }
  M[O_TXACK]       := 1;
  M[O_PORTENABLED] := 1;              { the field that makes anything happen }
  { The adapter's own TX->RX loopback, which is the cleanest possible test
    of the USB data path: it takes the modem, the baud rate and the cable
    out of the question entirely. If bytes sent on the data OUT pipe come
    back on the data IN pipe, everything between this program and the
    adapter is proven and any remaining fault is beyond it. }
  if Loop then M[O_LOOPBACK] := 1;
  M[O_RXFLUSH]     := 1;
  M[O_RETSTATUS]   := 1;              { answer now, so the status pipe talks }

  Fld('baud asked', Dec1(BaudRate));
  Fld('divisor', Dec1(Div_) + '  (' + Hex2(M[O_BAUDHI]) + ' '
                 + Hex2(M[O_BAUDLO]) + ')');
  Fld('actual baud', Dec1(KEYSPAN_BAUDCLK div (Div_ * 16)));
  Fld('rx batching', Dec1(FwdLen) + ' char(s) or 16 ms');
  Fld('control msg', Dec1(CTRLMSG_LEN) + ' bytes to EP '
                     + Hex2(Dev.EpCtrlOut));

  R := EpOut(Dev.EpCtrlOut, TogCtl, M, CTRLMSG_LEN);
  WriteLn('  control message -> ', StatusName(R));
  OpenPort := R = INT_SUCCESS;
end;

{ Listen on the data pipe (and optionally the status pipe) for a while. }
procedure Listen(Secs: Integer);
var
  Buf   : array[0..79] of Byte;
  Got   : Byte;
  R     : Integer;
  T0, Elapsed, Spins: LongInt;
  NData, NStat: LongInt;
  K     : Integer;
  Line  : ShortString;
  LineN : Byte;
begin
  NData := 0; NStat := 0;
  LineN := 0; Line := '';
  while KeyWaiting do EatKey;
  T0 := Ticks; Spins := 0;
  while True do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
    if Elapsed >= LongInt(Secs) * 182 div 10 then Break;
    Inc(Spins);
    if Spins > 800000 then Break;
    if KeyWaiting then begin EatKey; Break; end;

    R := EpIn(Dev.EpIn, TogIn, Buf, SizeOf(Buf), Got);
    if (R = INT_SUCCESS) and (Got > Dev.StatusHdr) then
    begin
      { Strip the per-packet header before showing anything. Dev.StatusHdr
        is 1 for Keyspan and 2 for FTDI; leaving it in puts a NUL between
        every character and makes a working link look broken. }
      for K := 0 to Got - 1 - Dev.StatusHdr do
        Buf[K] := Buf[K + Dev.StatusHdr];
      Got := Got - Dev.StatusHdr;
      if RawHex then Show('RX', Buf, Got);
      { Assemble into lines rather than printing byte by byte.

        rxForwardingLength is 1, so the adapter forwards each character the
        instant it arrives -- lowest latency, and exactly what a terminal
        wants, but it means one USB packet per character. Printed raw that
        turns "OK" into three lines of hex. Buffer until LF and the reply
        reads as what it is. }
      for K := 0 to Got - 1 do
      begin
        if (Buf[K] = 10) or (LineN >= 70) then
        begin
          if LineN > 0 then
          begin
            Line[0] := Chr(LineN);
            WriteLn('  < ', Line);
            LineN := 0;
          end;
        end
        else if Buf[K] <> 13 then
        begin
          Inc(LineN);
          if (Buf[K] >= 32) and (Buf[K] < 127) then
            Line[LineN] := Chr(Buf[K])
          else
            Line[LineN] := '.';
        end;
      end;
      Inc(NData);
      GotAny := True;
    end;

    if ShowStat and (Dev.EpStatIn <> 0) then
    begin
      R := EpIn(Dev.EpStatIn, TogStat, Buf, SizeOf(Buf), Got);
      if (R = INT_SUCCESS) and (Got > 0) then
      begin
        ShowStatus(Buf, Got);
        Inc(NStat);
      end;
    end;
  end;
  if LineN > 0 then
  begin
    Line[0] := Chr(LineN);
    WriteLn('  < ', Line);
  end;
  WriteLn;
  WriteLn('  data packets ', NData, ', status packets ', NStat);
end;

var
  Out_: array[0..79] of Byte;
  N   : Byte;

begin
  Banner('SERTALK', VER, 'talk to a device on a USB serial adapter');
  if HelpWanted then
  begin
    WriteLn('  SERTALK [/P=260] [/C=1] [/B=9600] [/A=text] [/S=secs]');
    WriteLn('          [/R] [/X] [/T]');
    WriteLn;
    WriteLn('    /B=n     baud, default 9600');
    WriteLn('    /A=text  send this then CR. Default AT');
    WriteLn('    /S=secs  how long to listen, default 4');
    WriteLn('    /R       listen only, send nothing');
    WriteLn('    /L       adapter loopback: TX wired to RX inside the');
    WriteLn('             adapter, so the modem is taken out of the test');
    WriteLn('    /X       dump the status pipe as well');
    WriteLn('    /H       also show every RX packet as raw hex');
    WriteLn('    /D=num   dial num, listen, then ALWAYS hang up');
    WriteLn('    /F=n     characters the adapter batches per USB packet,');
    WriteLn('             default 32. /F=1 is lowest latency and drops');
    WriteLn('             data above a few hundred baud on a slow host');
    WriteLn('    /W       sweep the usual baud rates looking for an answer');
    WriteLn('    /M       drive RTS/DTR and read CTS/DSR back, to find out');
    WriteLn('             whether the control lines are really looped');
    HelpTail;
    Halt(0);
  end;

  WantCfg := -1; Baud := 9600; Secs := 4; Send := 'AT';
  RawOnly := False; ShowStat := False; GotAny := False; Loop := False;
  Sweep := False; Lines := False; RawHex := False; FwdLen := 32;
  Dial := '';
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base := HexArg(S, 4);
      'C': WantCfg := NumArg(S, 4);
      'B': Baud := NumArg(S, 4);
      'S': Secs := NumArg(S, 4);
      'A': Send := Copy(S, 4, 60);
      'R': RawOnly := True;
      'L': Loop := True;
      'W': Sweep := True;
      'M': Lines := True;
      'H': RawHex := True;
      'F': FwdLen := Byte(NumArg(S, 4));
      'D': Dial := Copy(S, 4, 40);
      'X': ShowStat := True;
      'T': CtrlTrace := True;
    end;
  end;
  if Baud < 50 then Baud := 9600;
  if FwdLen < 1 then FwdLen := 1;
  if FwdLen > 64 then FwdLen := 64;
  if Secs < 1 then Secs := 1;
  if CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');

  ExitProc := @Quieten;
{ FIND THE CONFIGURATION RATHER THAN ASSUMING ONE.

  The default used to be index 1, which is right for the Keyspan on this
  bench -- it declares two configurations and only the second carries a
  bulk pair, its first putting interrupt endpoints where the data should be
  -- and wrong for everything with a single configuration.  An FTDI has
  only index 0, so the default asked for a configuration that does not
  exist and the tool failed before it reached the adapter it was pointed at.

  Trying each in turn and taking the first that yields a serial adapter
  this project can drive costs one descriptor read per miss and makes the
  switch a thing you reach for when a device is unusual, not a thing you
  must know in advance. /C= still forces one. }
  CfgIdx := WantCfg;
  if CfgIdx < 0 then CfgIdx := 0;
  Found := False;
  while CfgIdx <= 3 do
  begin
    Rc := BringUpCfg(Byte(CfgIdx), Big, BigLen, Why);
    if Rc = BU_OK then
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
  if Found then Rc := BU_OK;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Why <> '' then WriteLn('  ', Why);
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  PID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  if not SerDetect(Big, BigLen, VID, PID, Dev) then
  begin
    WriteLn('  no bulk endpoint pair; not a serial adapter.');
    Halt(6);
  end;

  Fld('device', Hex4(VID) + ':' + Hex4(PID) + '  ' + SerFamilyName(Dev.Family));
  { THIS USED TO REFUSE ANYTHING BUT A KEYSPAN.

    It was written before dser existed, as the experiment that
    reconstructed the Keyspan control message, so it builds that message
    itself and knew no other.  dser now drives several families behind one
    interface, and a tool that says "AT" and listens for "OK" has nothing
    Keyspan-specific about it at all.

    So the Keyspan path stays -- it prints the message field by field and
    dumps the status pipe, which is why this tool exists and which SerOpen
    deliberately hides -- and everything else goes through SerOpen. }
  if not SerSupported(Dev.Family) then
  begin
    WriteLn;
    WriteLn('  A ', SerFamilyName(Dev.Family), ' is recognised but dser has');
    WriteLn('  no line-setting path for it, so opening its port is not');
    WriteLn('  attempted.  Saying so beats pretending: a port that was');
    WriteLn('  never opened delivers nothing, and "no answer" is exactly');
    WriteLn('  what a wrong baud rate looks like.');
    Halt(6);
  end;
  if (Dev.Family = sfKeyspan) and (Dev.EpCtrlOut = 0) then
  begin
    WriteLn('  no separate control endpoint; this is not the usa90 shape.');
    Halt(6);
  end;

  TogOut := $80; TogIn := $80; TogStat := $80; TogCtl := $80;

  WriteLn;
  WriteLn('OPENING THE PORT');
  WriteLn('----------------------------------------------------------------');
  if Loop then
    WriteLn('  LOOPBACK requested: the modem is out of the path.');
  if not OpenPort(Baud, 1, 1) then
  begin
    WriteLn;
    WriteLn('  The adapter would not take the control message, so the port');
    WriteLn('  was never opened and nothing below would mean anything.');
    Halt(7);
  end;

  if not RawOnly then
  begin
    N := 0;
    for I := 1 to Length(Send) do
    begin
      Out_[N] := Ord(Send[I]);
      Inc(N);
    end;
    Out_[N] := 13; Inc(N);          { CR -- what a modem waits for }
    WriteLn;
    Show('TX', Out_, N);
    Rc := EpOut(Dev.EpOut, TogOut, Out_, N);
    WriteLn('  sent -> ', StatusName(Rc));
  end;

  { DOES CTS FOLLOW OUR RTS?

    The trap this answers: on a null-modem or crossover cable, RTS is
    wired to CTS and DTR to DSR, so those inputs mirror our own outputs
    and a completely disconnected adapter looks exactly like a modem
    asserting its lines. The port here showed CTS and DSR up while no
    baud rate got an answer, which is precisely that shape.

    Drive the two outputs through all four combinations and read the
    inputs back. If the inputs track the outputs, the lines are looped --
    the cable is crossed, or nothing is on the far end -- and no baud rate
    was ever going to work. If they do not, the far end really is
    asserting them and the fault is elsewhere. }
  { DIALLING, and the reason it is one mode rather than three commands.

    A modem that has gone off-hook stays off-hook. If this program sent
    ATDT and then exited -- because it finished, or because somebody
    pressed a key, or because it crashed -- the line would be left seized
    and the only way back would be another run or the modem's power
    switch. So dial, listen and hang up are a single unbroken sequence
    with the ATH on every path out, including the early ones.

    The speaker is turned on first (M1 = on until carrier, L3 = loud) so
    that whoever is standing next to the modem can hear what is actually
    happening. Dial tone, DTMF digits and ringing are three completely
    different failures and no result code distinguishes them as well as
    listening does. }
  if Dial <> '' then
  begin
    WriteLn;
    WriteLn('DIALLING ', Dial);
    WriteLn('----------------------------------------------------------------');
    SendLine('ATM1L3');
    Listen(2);
    { X3: dial BLIND -- do not wait for a dial tone -- but still detect
      busy. A VOIP adapter very often produces a dial tone that a modem of
      this age does not recognise, which comes back as NO DIAL TONE from a
      line that is perfectly serviceable. X3 removes the modem's opinion
      from the question; if the line really is dead the call simply fails
      later instead, which is a more informative failure. }
    SendLine('ATX3');
    Listen(2);
    SendLine('ATDT' + Dial);
    WriteLn('  (listening ', Secs, 's -- the phone should ring)');
    Listen(Secs);
    WriteLn;
    WriteLn('  hanging up');
    SendLine('ATH');
    Listen(3);
    SendLine('ATM0');
    Listen(2);
    WriteLn;
    WriteLn('  The line has been released. If anything above says the modem');
    WriteLn('  is still off-hook, run:  SERTALK /A=ATH');
    WriteLn;
    WriteLn('=== done ===');
    Halt(0);
  end;

  if Lines then
  begin
    WriteLn;
    WriteLn('MODEM LINE TEST');
    WriteLn('----------------------------------------------------------------');
    WriteLn('  driving RTS and DTR, reading CTS and DSR back');
    WriteLn;
    for I := 0 to 3 do
    begin
      Rc := I and 1;                       { RTS }
      N := (I shr 1) and 1;                { DTR }
      Write('  RTS=', Rc, ' DTR=', N, ' -> ');
      if not OpenPort(Baud, Byte(Rc), N) then
      begin
        WriteLn('control message refused');
        Continue;
      end;
      DelayMs(300);
      ReadStatusOnce;
    end;
    WriteLn;
    WriteLn('  If CTS tracked RTS and DSR tracked DTR, those lines are');
    WriteLn('  LOOPED BACK: a crossover/null-modem cable, or nothing');
    WriteLn('  attached. Either way the modem never saw the AT.');
    WriteLn;
    WriteLn('=== done ===');
    Halt(0);
  end;

  if Sweep then
  begin
    WriteLn;
    WriteLn('BAUD SWEEP');
    WriteLn('----------------------------------------------------------------');
    WriteLn('  A modem auto-bauds from the "AT" prefix, but only if the rate');
    WriteLn('  is close enough for it to lock on. Rather than guess, try the');
    WriteLn('  usual ones and see which answers.');
    for I := 0 to NSWEEP - 1 do
    begin
      WriteLn;
      WriteLn('  --- ', SweepRates[I], ' baud');
      if not OpenPort(SweepRates[I], 1, 1) then Continue;
      N := 0;
      Out_[N] := Ord('A'); Inc(N);
      Out_[N] := Ord('T'); Inc(N);
      Out_[N] := 13; Inc(N);
      { Twice: many modems use the first AT only to measure the bit rate
        and answer the second. }
      Rc := EpOut(Dev.EpOut, TogOut, Out_, N);
      Listen(2);
      Rc := EpOut(Dev.EpOut, TogOut, Out_, N);
      Listen(2);
      if GotAny then
      begin
        WriteLn;
        WriteLn('  *** ', SweepRates[I], ' baud ANSWERED');
        Break;
      end;
    end;
    if not GotAny then
    begin
      WriteLn;
      WriteLn('  No rate answered.');
    end;
    WriteLn;
    WriteLn('=== done ===');
    if GotAny then Halt(0) else Halt(7);
  end;

  WriteLn;
  WriteLn('LISTENING FOR ', Secs, 's');
  WriteLn('----------------------------------------------------------------');
  Listen(Secs);

  WriteLn;
  if GotAny then
  begin
    WriteLn('  SOMETHING CAME BACK. That is the whole chain proven: the host,');
    WriteLn('  a CH375, a USB serial adapter, and a device on the far end.');
    Halt(0);
  end
  else
  begin
    WriteLn('  Nothing came back.');
    WriteLn('  With a reconstructed control message that is the expected');
    WriteLn('  failure and it does NOT mean the adapter or the modem is at');
    WriteLn('  fault -- the most likely cause is that the message layout is');
    WriteLn('  wrong, so the port never actually opened. /X shows whether');
    WriteLn('  the status pipe woke up, which is the first thing to check:');
    WriteLn('  a status packet means the message WAS understood.');
    Halt(7);
  end;
end.
