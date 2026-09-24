program camprobe;
{ CAMPROBE -- will an IBM PC Camera's isochronous video come through a
  CH375 at all?  CH375Camera, StevenC & Claude.  Public domain (the Unlicense).

    CAMPROBE [/P=260] [/W=320] [/F=0] [/K=64] [/N=3000] [/D=6] [/B=32] [/O=file] [/V] [/X]

  THE QUESTION.  CH375Audio established that the chip has no isochronous
  mode, and that an isochronous OUT endpoint never accepts a packet: the
  chip waits for a handshake the device never sends.  That result is about
  OUT.  An isochronous IN is a different shape of transaction -- the
  device answers the IN token with a data packet, which is exactly what a
  bulk IN device does, and the only thing missing is a handshake FROM THE
  HOST, which the chip will send and the device will ignore.  So it might
  simply work, and nobody has tried.

  Two things could still stop it, and this tool tells them apart:

    * the packet is too big.  The camera's endpoint says 1022 bytes; the
      chip holds 64.  But the camera's maximum packet is a register, and
      /K sets it -- 64 by default.
    * the data toggle.  Isochronous packets are always DATA0.  The chip is
      told to expect DATA0 on every token here; if it objects anyway, the
      status it reports says so, and /X reads the buffer regardless.

  WHAT IT PRINTS: a tally of every status the chip returned, the packet
  lengths that came back, the rate, the first /D packets that carried data
  in hex, and the distances between start-of-frame markers (00 FF), which
  is the number that says whether whole frames are arriving.

  IT PUTS THE CAMERA BACK: stream stopped, interface to alt 0, LED off, on
  every path once streaming has started. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, cit, ptime;

const
  VER = '0.2.0';
  MAXSOF = 24;

var
  Width:   Word = 320;
  ClkDiv:  Byte = 0;
  PktSize: Word = 64;
  Tokens:  LongInt = 3000;
  Dumps:   Word = 6;
  ReadAny: Boolean = False;
  OutName: ShortString = '';
  OutF:    File;
  OutBuf:  array[0..4095] of Byte;
  OutLen:  Word = 0;

  StTally:  array[-1..255] of LongInt;
  LenTally: array[0..64] of LongInt;
  Bytes:    LongInt = 0;
  SofAt:    array[1..MAXSOF] of LongInt;
  SofN:     Word = 0;
  SofTotal: LongInt = 0;
  PrevByte: Byte = $AA;
  StopHow:  Byte = 3;
  OvIdx, OvVal: array[1..8] of Word;
  OvN:      Byte = 0;
  ReEnum:   Boolean = False;

procedure Usage;
begin
  WriteLn;
  WriteLn('CAMPROBE [/P=hex] [/W=n] [/F=n] [/K=n] [/N=n] [/D=n] [/B=n] [/O=f] [/V] [/X]');
  WriteLn;
  WriteLn('Starts an IBM PC Camera (0545:8080 model 2) and issues IN tokens');
  WriteLn('at its isochronous video endpoint, reporting what comes back.');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /W=n     frame width: 176, 320 or 352.  Default 320');
  WriteLn('  /F=n     frame rate 0..31, 0 slowest.  Default 0');
  WriteLn('  /K=n     camera''s max packet size, 1..1022.  Default 64');
  WriteLn('  /N=n     IN tokens to issue.  Default 3000');
  WriteLn('  /D=n     hex-dump the first n packets that carry data.  Default 6');
  WriteLn('  /B=n     brightness 0..63.  Default 32, as Linux');
  WriteLn('  /O=file  also write every byte received to a file, raw');
  WriteLn('           as records: time, length, status, data -- camview.py');
  WriteLn('  /S=n     stop sequence: 0 none, 1 stream off, 2 +alt 0,');
  WriteLn('           3 +sensor idle and LED off (default)');
  WriteLn('  /R=i:v   write camera register i (hex) with v (hex) after the');
  WriteLn('           start sequence, before streaming.  Up to 8 of them');
  WriteLn('  /E       enumerate the camera again after stopping, and say');
  WriteLn('           whether it answers');
  WriteLn('  /V       print every register write');
  WriteLn('  /X       read the chip''s buffer even when the token did not');
  WriteLn('           report success');
  HelpTail;
end;

function NumArg(const S: ShortString; var V: LongInt): Boolean;
var C: Integer;
begin
  Val(S, V, C);
  NumArg := C = 0;
end;

function HexArg(const S: ShortString; var V: Word): Boolean;
var C: Integer; T: LongInt;
begin
  Val('$' + S, T, C);
  V := Word(T);
  HexArg := C = 0;
end;

procedure ParseArgs;
var
  I: Integer;
  A, K, V: ShortString;
  N: LongInt;
  Ok: Boolean;
  C: Integer;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if (Length(A) < 2) or not (A[1] in ['/', '-']) then
    begin
      WriteLn('unknown argument: ', A); Halt(2);
    end;
    K := UpCase(A[2]);
    V := Copy(A, 4, 255);
    Ok := True;
    case K[1] of
      'P': Ok := HexArg(V, Base);
      'W': begin Ok := NumArg(V, N); Width := N;
                 Ok := Ok and ((N = 176) or (N = 320) or (N = 352)); end;
      'F': begin Ok := NumArg(V, N) and (N >= 0) and (N <= 31); ClkDiv := N; end;
      'K': begin Ok := NumArg(V, N) and (N >= 1) and (N <= 1022); PktSize := N; end;
      'N': begin Ok := NumArg(V, N) and (N > 0); Tokens := N; end;
      'D': begin Ok := NumArg(V, N) and (N >= 0); Dumps := N; end;
      'B': begin Ok := NumArg(V, N) and (N >= 0) and (N <= 63); Brightness := N; end;
      'O': begin OutName := V; Ok := V <> ''; end;
      'S': begin Ok := NumArg(V, N) and (N >= 0) and (N <= 3); StopHow := N; end;
      'E': ReEnum := True;
      'R': begin
             C := Pos(':', V);
             Ok := (C > 1) and (OvN < 8);
             if Ok then
             begin
               Inc(OvN);
               Ok := HexArg(Copy(V, 1, C - 1), OvIdx[OvN]) and
                     HexArg(Copy(V, C + 1, 255), OvVal[OvN]);
             end;
           end;
      'V': Verbose := True;
      'X': ReadAny := True;
    else
      Ok := False;
    end;
    if not Ok then begin WriteLn('bad argument: ', A); Halt(2); end;
  end;
end;

{ Heartbeat on stderr, driven by the BIOS tick: it lands on the real
  screen, never in the captured output, and it moves only if the machine
  is alive. }
var LastBeat: LongInt = 0;
procedure Beat;
const Spin: array[0..3] of Char = ('|', '/', '-', '\');
var T: LongInt;
begin
  T := Ticks;
  if T = LastBeat then Exit;
  LastBeat := T;
  Write(StdErr, Spin[(T shr 2) and 3], #8);
end;

procedure Scan(const B: array of Byte; L: Byte);
var I: Integer;
begin
  for I := 0 to L - 1 do
  begin
    if (PrevByte = $00) and (B[I] = $FF) then
    begin
      Inc(SofTotal);
      if SofN < MAXSOF then
      begin
        Inc(SofN);
        SofAt[SofN] := Bytes + I;
      end;
    end;
    PrevByte := B[I];
  end;
end;

procedure Flush;
begin
  if (OutName <> '') and (OutLen > 0) then BlockWrite(OutF, OutBuf, OutLen);
  OutLen := 0;
end;

{ One record per token: time (4 bytes, PIT counts), length, status, then
  the data.  Failed tokens are recorded too, with length 0 -- when the
  gaps are is half of what the file is for. }
procedure Keep(T: LongInt; const B: array of Byte; L, St: Byte);
begin
  if OutName = '' then Exit;
  if OutLen + L + 6 > SizeOf(OutBuf) then Flush;
  Move(T, OutBuf[OutLen], 4);
  OutBuf[OutLen + 4] := L;
  OutBuf[OutLen + 5] := St;
  Inc(OutLen, 6);
  if L > 0 then Move(B[0], OutBuf[OutLen], L);
  Inc(OutLen, L);
end;

procedure Header;
var H: array[0..15] of Byte;
begin
  FillChar(H, SizeOf(H), 0);
  H[0] := Ord('C'); H[1] := Ord('A'); H[2] := Ord('M'); H[3] := Ord('R');
  Move(Width, H[4], 2);
  Move(PktSize, H[6], 2);
  H[8] := ClkDiv;
  H[9] := Brightness;
  BlockWrite(OutF, H, SizeOf(H));
end;

procedure Stream;
var
  Buf: array[0..63] of Byte;
  I, TNow, TA, TB: LongInt;
  SumTok, SumRd, SumAll: LongInt;
  R: Integer;
  L: Byte;
  Shown: Word;
  T0, T1: LongInt;
  Secs: Real;
begin
  Shown := 0;
  SumTok := 0; SumRd := 0; SumAll := 0;
  TB := Now;
  T0 := Ticks;
  for I := 1 to Tokens do
  begin
    Beat;
    TA := Now;
    WrCmd(CMD_SET_ENDP6); WrDat($80);            { DATA0, always }
    WrCmd(CMD_ISSUE_TOKEN); WrDat((STREAM_EP shl 4) or PID_IN);
    R := WaitInt(60);
    TNow := Now;
    Inc(SumTok, TNow - TA);
    Inc(StTally[R]);
    L := 0;
    if (R = INT_SUCCESS) or (ReadAny and (R >= 0)) then
    begin
      L := FastRead(Buf);
      if L > 64 then L := 0;
      Inc(LenTally[L]);
      if L > 0 then
      begin
        Scan(Buf, L);
        if Shown < Dumps then
        begin
          Inc(Shown);
          WriteLn('  packet ', I, '  status ', Hex2(Byte(R)), '  ', L,
                  ' bytes  at stream offset ', Bytes);
          HexDump(Buf, L, '    ');
        end;
        Inc(Bytes, L);
      end;
    end;
    Inc(SumRd, Now - TNow);
    Keep(TNow, Buf, L, Byte(R));
  end;
  SumAll := Now - TB;
  T1 := Ticks;
  Flush;
  Write(StdErr, ' '#8);

  Secs := (T1 - T0) / 18.2065;
  WriteLn;
  WriteLn('tokens   : ', Tokens, ' in ', Secs:0:2, ' s');
  if Secs > 0 then
  begin
    WriteLn('rate     : ', Round(Tokens / Secs), ' tokens/s, ',
            Round(Bytes / Secs), ' bytes/s');
  end;
  WriteLn('bytes    : ', Bytes);
  WriteLn('per token: ', (SumTok div Tokens) * 838 div 1000, ' us token-to-status, ',
          (SumRd div Tokens) * 838 div 1000, ' us reading, ',
          (SumAll div Tokens) * 838 div 1000, ' us in all');
end;

procedure Report;
var
  I: Integer;
  F: LongInt;
begin
  WriteLn;
  WriteLn('STATUS TALLY');
  for I := -1 to 255 do
    if StTally[I] > 0 then
      WriteLn('  ', StatusStr(I):44, '  ', StTally[I]:7);

  WriteLn;
  WriteLn('PACKET LENGTHS');
  for I := 0 to 64 do
    if LenTally[I] > 0 then
      WriteLn('  ', I:3, ' bytes  ', LenTally[I]:7);

  WriteLn;
  F := FrameBytes(Width);
  WriteLn('START-OF-FRAME MARKERS (00 FF): ', SofTotal,
          '   a full ', Width, ' frame is ', F, ' bytes');
  for I := 1 to SofN do
  begin
    Write('  at ', SofAt[I]:8);
    if I > 1 then Write('   +', SofAt[I] - SofAt[I - 1]);
    WriteLn;
  end;
end;

var
  R, I: Integer;
  V: Byte;
begin
  Banner('CAMPROBE', VER, 'does a camera''s video reach a CH375?');
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  FillChar(StTally, SizeOf(StTally), 0);
  FillChar(LenTally, SizeOf(LenTally), 0);

  PortDat := Base; PortCmd := Base + 1;
  WriteLn('I/O base ', Hex4(Base), '   width ', Width, '   rate ', ClkDiv,
          '   packet ', PktSize, '   tokens ', Tokens);

  R := CamUp;
  if R <> 0 then Halt(R);

  { A read first: the cheapest proof the vendor requests land at all. }
  R := RegR($0116, V);
  WriteLn('reg 0116 : ', Hex2(V), '   ', StatusStr(R));
  if R <> INT_SUCCESS then
  begin
    WriteLn('the camera does not answer a register read; stopping');
    Halt(9);
  end;

  M2Start(Width, ClkDiv, PktSize);
  WriteLn('start    : ', RegFails, ' register writes failed',
          '   (last ', StatusStr(LastFail), ')');

  for I := 1 to OvN do
  begin
    R := RegW(OvVal[I], OvIdx[I]);
    WriteLn('override : reg ', Hex4(OvIdx[I]), ' <- ', Hex4(OvVal[I]), '   ',
            StatusStr(R));
  end;

  R := SetAlt(1);
  WriteLn('SET_INTERFACE 0 alt 1 -> ', StatusStr(R));

  StreamGo;
  ClrStall($81);
  SetRetry($00);                 { an isochronous endpoint never NAKs;
                                   do not let the chip sit retrying }
  WriteLn('streaming: yes');
  WriteLn;

  if OutName <> '' then
  begin
    Assign(OutF, OutName);
    {$I-} Rewrite(OutF, 1); {$I+}
    if IOResult <> 0 then
    begin
      WriteLn('cannot create ', OutName);
      OutName := '';
    end
    else Header;
  end;

  PitFine;
  Stream;
  PitRestore;
  if OutName <> '' then begin Close(OutF); WriteLn('saved    : ', OutName); end;

  SetRetry($8F);
  R := 0;
  if StopHow >= 1 then StreamStop;
  if StopHow >= 2 then R := SetAlt(0);
  if StopHow >= 3 then M2Off;
  WriteLn('stop     : sequence ', StopHow, '   alt 0 -> ', StatusStr(R), '   ',
          RegFails, ' register writes failed in all');

  if ReEnum then
  begin
    R := RegR($0116, V);
    WriteLn('re-read  : reg 0116 -> ', Hex2(V), '   ', StatusStr(R),
            '   (no bus reset)');
    DelayMs(500);
    R := BusUp;
    WriteLn('re-enum  : ', BusUpReason(R));
  end;

  Report;
  if Bytes > 0 then Halt(0) else Halt(10);
end.
