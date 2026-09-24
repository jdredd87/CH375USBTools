program serprobe;
{ SERPROBE -- identify a USB-to-serial adapter over a CH375 and work out how
  it would have to be driven.
  CH375Serial, StevenC & Claude.  Public domain (the Unlicense).

    SERPROBE [/P=260] [/C=n] [/S=secs] [/E=n] [/V] [/T]

      /P=hex   I/O base, default 260
      /C=dec   configuration INDEX to select, default 0
      /S=dec   after bring-up, poll the IN endpoints for this many seconds
               and print whatever arrives, raw
      /E=dec   which endpoint to poll with /S. Default: the status pipe if
               the device has one, else the data pipe
      /V       narrate the bring-up
      /T       trace every control-transfer stage

  WHY A PROBE FIRST, AGAIN

  CH375Video learned this and CH375Audio confirmed it: identify before
  driving, in a separate tool, because a half-configured device is a device
  the next run has to guess about.  Here there is an extra reason.  Only
  CDC-ACM is a standard; every other USB-to-serial part is a private vendor
  protocol, so "which protocol" is the whole question and it has to be
  answered from the device rather than from the box it came in.

  THE THING THIS TOOL EXISTS TO CATCH: MORE THAN ONE CONFIGURATION.

  A USB device may offer several configurations and the host picks ONE.
  Nearly everything has exactly one, so nearly every driver -- including
  the first draft of this project's bring-up -- fetches configuration index
  0 and sends its bConfigurationValue without ever looking.

  The adapter this was written against has TWO, and they are not
  interchangeable:

      index 0, value 1   EP 81/82 are INTERRUPT IN
      index 1, value 2   EP 81/82 are BULK IN

  Same endpoints, same numbers, same everything else -- only the transfer
  type differs.  Both are drivable from a CH375, which does interrupt and
  bulk, but bulk is the one to want for a data pipe.  A driver that took
  index 0 without looking would work, slower, for reasons that would never
  show up in its own logs.

  Note also that the descriptor INDEX and the bConfigurationValue are
  different numbers -- 0/1 and 1/2 here -- and sending the index where the
  value belongs selects nothing at all.  This device makes that mistake
  visible, which is a good reason to keep it as the reference part.

  WHAT IT CANNOT TELL YOU.  Whether anything is plugged into the SERIAL end.
  With an empty port a healthy adapter and a dead one look identical from
  here: the data pipe NAKs either way.  /S is how to look at the status
  pipe, which on parts that have one does report the modem lines and will
  change when a cable is attached.

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering,
              6 attached but it is not a serial adapter }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, dser;

const
  VER = '0.1.0';

var
  Big     : TBigCfg;
  BigLen  : Word;
  Why     : ShortString;
  Dev     : TSerDev;
  VID, PID: Word;
  WantCfg : Integer;
  Secs    : Integer;
  WantEp  : Integer;
  I       : Integer;
  S       : ShortString;
  Rc      : Integer;
  NCfg    : Byte;

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

{ Print one configuration's interfaces and endpoints. Kept separate from
  SerDetect because this is for a person to read and that is for a driver
  to use, and one routine doing both ends up serving neither. }
procedure ShowConfig(const C: TBigCfg; Len: Word);
var
  P    : Word;
  L, T : Byte;
  W    : Word;
  Attr : Byte;
begin
  P := 0;
  while P + 2 <= Len do
  begin
    L := C[P];
    T := C[P + 1];
    if (L = 0) or (P + L > Len) then Break;
    case T of
      $02:
        WriteLn('    value ', C[P + 5], ', ', C[P + 4],
                ' interface(s), ', C[P + 8] * 2, ' mA');
      $04:
        WriteLn('    INTERFACE ', C[P + 2], ' alt ', C[P + 3], '  class ',
                Hex2(C[P + 5]), '/', Hex2(C[P + 6]), '/', Hex2(C[P + 7]),
                '  ', ClassName(C[P + 5], C[P + 6], C[P + 7]),
                '  ', C[P + 4], ' endpoint(s)');
      $05:
        begin
          W := C[P + 4] or (Word(C[P + 5]) shl 8);
          Attr := C[P + 3] and $03;
          Write('      EP ', Hex2(C[P + 2]), '  ');
          if (C[P + 2] and $80) <> 0 then Write('IN   ') else Write('OUT  ');
          Write(EpTypeName(C[P + 3]), '  max ', W);
          if Attr = 2 then Write('   <- CH375 drives this well')
          else if Attr = 3 then Write('   <- CH375 drives this too')
          else if Attr = 1 then Write('   <- ISOCHRONOUS: out of reach');
          WriteLn;
        end;
      $24:
        WriteLn('      CDC functional descriptor, subtype ', Hex2(C[P + 2]));
    end;
    Inc(P, L);
  end;
end;

{ Poll an IN endpoint and print whatever turns up.

  This is the only way to learn a vendor protocol without the vendor's
  documentation, and it is deliberately dumb: no interpretation, just the
  bytes and how often they came. A status pipe that reports the modem
  lines will change when a cable is plugged in, which is the experiment
  worth running once there is something to plug in. }
procedure PollEp(Ep: Byte; Secs: Integer);
var
  Tog   : Byte;
  Buf   : array[0..79] of Byte;
  Got   : Byte;
  R     : Integer;
  T0, Elapsed, Spins: LongInt;
  NGot, NNak, NErr, Shown: LongInt;
  LastBad, NOther: LongInt;
  K     : Integer;
  Same  : Boolean;
  Prev  : array[0..79] of Byte;
  PrevN : Byte;
begin
  Tog := $80;
  NGot := 0; NNak := 0; NErr := 0; Shown := 0;
  LastBad := -999; NOther := 0;
  PrevN := 0;
  for K := 0 to 79 do Prev[K] := 0;
  WriteLn;
  WriteLn('  polling endpoint ', Hex2(Ep), ' IN for ', Secs, 's');
  WriteLn('  (a key on the DOS keyboard stops early)');
  WriteLn;
  while KeyWaiting do EatKey;
  T0 := Ticks; Spins := 0;
  while True do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
    if Elapsed >= LongInt(Secs) * 182 div 10 then Break;
    Inc(Spins);
    if Spins > 500000 then Break;
    if KeyWaiting then begin EatKey; WriteLn('  stopped.'); Break; end;

    R := EpIn(Ep, Tog, Buf, SizeOf(Buf), Got);
    if R <> INT_SUCCESS then
    begin
      if R = -1 then Inc(NNak) else Inc(NErr);
      { Keep the FIRST failing status and how many were like it. "errors
        5548" says nothing; "5548 x NAK" and "5548 x STALL" are completely
        different diagnoses -- one is an idle endpoint behaving correctly
        and the other is an endpoint that needs clearing. }
      if LastBad = -999 then LastBad := R
      else if R <> LastBad then Inc(NOther);
      Continue;
    end;
    Inc(NGot);
    if Got = 0 then Continue;

    { Only print a packet that differs from the last one. A status pipe
      repeats itself several times a second, and a tool that prints every
      repeat buries the one packet that changed -- which is the only one
      anybody is watching for. }
    Same := (Got = PrevN);
    if Same then
      for K := 0 to Got - 1 do
        if Buf[K] <> Prev[K] then Same := False;
    if Same then Continue;

    Write('  ', Got:2, ' bytes:');
    for K := 0 to Got - 1 do
    begin
      if K = 16 then Break;
      Write(' ', Hex2(Buf[K]));
    end;
    if Got > 16 then Write(' ...');
    WriteLn;
    Inc(Shown);
    PrevN := Got;
    for K := 0 to Got - 1 do Prev[K] := Buf[K];
  end;

  WriteLn;
  WriteLn('  packets ', NGot, ', distinct ', Shown,
          ', timeouts ', NNak, ', other ', NErr);
  if LastBad <> -999 then
  begin
    Write('  the failures were: ', StatusName(Integer(LastBad)),
          ' (', LastBad, ')');
    if NOther > 0 then Write(', plus ', NOther, ' of other kinds');
    WriteLn;
  end;
  if NGot = 0 then
  begin
    WriteLn('  Nothing arrived. On a data pipe with nothing plugged into');
    WriteLn('  the serial end that is the CORRECT answer and says nothing');
    WriteLn('  about the adapter.');
  end;
end;

begin
  Banner('SERPROBE', VER, 'USB-to-serial adapter probe');
  if HelpWanted then
  begin
    WriteLn('  SERPROBE [/P=260] [/C=n] [/S=secs] [/E=n] [/V] [/T]');
    WriteLn;
    WriteLn('    /C=n     configuration INDEX to select, default 0');
    WriteLn('    /S=secs  poll an IN endpoint and print what arrives');
    WriteLn('    /E=n     which endpoint to poll (default: the status pipe)');
    HelpTail;
    Halt(0);
  end;

  WantCfg := 0; Secs := 0; WantEp := -1;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base := HexArg(S, 4);
      'C': WantCfg := NumArg(S, 4);
      'S': Secs := NumArg(S, 4);
      'E': WantEp := HexArg(S, 4);
      'V': Trace := @Narrate;
      'T': CtrlTrace := True;
    end;
  end;
  if CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');

  ExitProc := @Quieten;
  Rc := BringUpCfg(Byte(WantCfg), Big, BigLen, Why);
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Why <> '' then WriteLn('  ', Why);
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  PID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  NCfg := 1;
  if DevLen >= 18 then NCfg := DevDesc[17];

  Fld('chip', 'CH375 rev ' + Hex2(IcVer));
  Fld('ep0 max', Dec1(Ep0Max) + ' bytes');
  Fld('device', Hex4(VID) + ':' + Hex4(PID) + '  ' + VendorName(VID));
  Fld('configurations', Dec1(NCfg));
  Fld('selected', 'index ' + Dec1(WantCfg) + ', value ' + Dec1(Big[5]));

  WriteLn;
  WriteLn('SELECTED CONFIGURATION');
  WriteLn('----------------------------------------------------------------');
  ShowConfig(Big, BigLen);

  { Every OTHER configuration, read but not selected. This is the part
    that catches a device whose good configuration is not index 0. }
  if NCfg > 1 then
  begin
    { Retries back ON for these reads. BringUpCfg finishes by setting the
      retry count to 0, which is right for polling an endpoint and wrong
      for a control transfer: a device that NAKs once while preparing a
      descriptor then fails on the first ask. That is exactly what these
      reads did until this pair of lines was added, and the failure said
      "device returned NAK" rather than "you turned retries off". }
    SetRetry($8F);
    WriteLn;
    WriteLn('THE OTHER CONFIGURATION(S) -- read, not selected');
    WriteLn('----------------------------------------------------------------');
    for I := 0 to NCfg - 1 do
      if I <> WantCfg then
      begin
        WriteLn('  index ', I, ':');
        if GetConfigFull(Byte(I), Big, BigLen, Why) then
          ShowConfig(Big, BigLen)
        else
          WriteLn('    ', Why);
      end;
    { Put the selected one back so the report below describes what is
      actually configured rather than the last one fetched. }
    if not GetConfigFull(Byte(WantCfg), Big, BigLen, Why) then
    begin
      WriteLn('  lost the selected configuration: ', Why);
      Halt(5);
    end;
    SetRetry($00);              { and off again before anything is polled }
  end;

  if not SerDetect(Big, BigLen, VID, PID, Dev) then
  begin
    WriteLn;
    WriteLn('  No pair of bulk endpoints, so this is not a serial adapter');
    WriteLn('  in any shape this project understands.');
    Halt(6);
  end;

  WriteLn;
  WriteLn('VERDICT');
  WriteLn('----------------------------------------------------------------');
  Fld('family', SerFamilyName(Dev.Family));
  { Printed as the FULL endpoint address, direction bit included. The
    record stores the number with bit 7 masked off because that is what
    EpIn and EpOut want, but showing the masked value makes an IN and an
    OUT endpoint with the same number look identical -- "data OUT 01, data
    IN 01" -- which is exactly how this first read. }
  Fld('data OUT', Hex2(Dev.EpOut) + '  (addr ' + Hex2(Dev.EpOut)
                  + ')  max ' + Dec1(Dev.EpOutMax));
  Fld('data IN', Hex2(Dev.EpIn) + '  (addr ' + Hex2(Dev.EpIn or $80)
                 + ')  max ' + Dec1(Dev.EpInMax));
  if Dev.EpCtrlOut <> 0 then
    Fld('control OUT', Hex2(Dev.EpCtrlOut) + '  (addr '
        + Hex2(Dev.EpCtrlOut) + ')');
  if Dev.EpStatIn <> 0 then
    Fld('status IN', Hex2(Dev.EpStatIn) + '  (addr '
        + Hex2(Dev.EpStatIn or $80) + ')');
  if Dev.HasNotify then
    Fld('notify IN', Hex2(Dev.EpNotify) + '  (addr '
        + Hex2(Dev.EpNotify or $80) + ')  interrupt');
  if Dev.StatusHdr > 0 then
    Fld('per-packet header', Dec1(Dev.StatusHdr) + ' status byte(s) to strip');

  WriteLn;
  if SerSupported(Dev.Family) then
    WriteLn('  This family has a line-setting path written. SERTERM can')
  else
  begin
    WriteLn('  This family is RECOGNISED but not yet driven. Its baud rate');
    WriteLn('  and line settings go through a private vendor protocol that');
    WriteLn('  is not implemented here, so nothing can be configured yet.');
    WriteLn;
    WriteLn('  The data path is ordinary bulk, though, so raw bytes can');
    WriteLn('  still be pushed and pulled at whatever rate the adapter');
    WriteLn('  happens to be set to.');
  end;

  WriteLn;
  Fld('115200 baud needs', '11520 bytes/s');
  Fld('9600 baud needs', '960 bytes/s');
  Fld('this CH375 does', '~19000 bytes/s measured (DLBENCH)');
  WriteLn('  So the LINK is not the limit here, which is the whole reason');
  WriteLn('  this project is worth doing where CH375Audio was not.');

  if Secs > 0 then
  begin
    if WantEp < 0 then
    begin
      if Dev.EpStatIn <> 0 then WantEp := Dev.EpStatIn
      else if Dev.HasNotify then WantEp := Dev.EpNotify
      else WantEp := Dev.EpIn;
    end;
    PollEp(Byte(WantEp), Secs);
  end;

  WriteLn;
  WriteLn('=== done ===');
  Halt(0);
end.
