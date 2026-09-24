program usbpoll;
{ USBPOLL -- poll an endpoint and show what comes back.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  Enumerates, configures the device, then sits on an IN endpoint printing
  every packet.  With no /E it finds the first interrupt IN endpoint by
  itself, which is the one a keyboard, mouse or gamepad talks on.

    USBPOLL [/P=260] [/E=n] [/I=n] [/N=count] [/S=secs] [/W=ms]
            [/A] [/B] [/K] [/M]

      /P=hex   I/O base, default 260
      /E=n     endpoint number.  Default: the first interrupt IN endpoint
      /I=n     interface to put in boot protocol, default the HID one found
      /N=dec   packets to wait for before stopping, default 40.  Counts
               real packets, not poll attempts
      /S=dec   give up after this many seconds whichever comes first,
               default 20.  An idle device NAKs forever and would
               otherwise hold the machine for as long as /N asked for --
               which, run from a test harness, looks exactly like a hang
      /W=dec   ms between polls, default 8
      /A       print every poll, NAKs included.  Very noisy; it is how you
               tell "device is silent" from "program is not polling"
      /R=dec   HID idle rate, in 4 ms units.  The default is 0, meaning
               "report only when something changes", which is what a
               driver wants.  A nonzero rate makes the device repeat its
               current state forever -- which is how you see a key that
               was ALREADY held down when polling started, since that is
               not a change and produces nothing at rate 0.  /R=25 is
               every 100 ms
      /B       ask for HID boot protocol (the default for a HID interface)
      /K       decode packets as HID boot keyboard reports
      /M       decode packets as HID boot mouse reports
               Without /K or /M the interface protocol decides

  Nothing here is mouse- or keyboard-specific underneath: an unrecognised
  endpoint is polled just the same and its bytes printed as bytes.

  Exit codes: 0 packets seen, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 could not configure,
              6 no suitable endpoint, 7 polled but nothing ever arrived }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

var
  Cfg:     array[0..1023] of Byte;
  Pkt:     array[0..63] of Byte;
  Prev:    array[0..63] of Byte;
  CfgLenG: Word = 0;
  EpWant:  Integer = -1;
  IfWant:  Integer = -1;
  NWant:   Word = 40;
  Secs:    Word = 20;
  Gap:     Word = 8;
  Idle:    Word = 0;
  ShowAll: Boolean = False;
  AsKbd:   Boolean = False;
  AsMouse: Boolean = False;
  CfgVal:  Byte = 1;
  EpMax:   Byte = 8;
  EpIval:  Byte = 0;
  IfProto: Byte = 0;
  IsHid:   Boolean = False;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var R: ShortString;
begin
  R := S; while Length(R) < N do R := R + ' '; Pad := R;
end;

{ Walk the configuration for the first interrupt IN endpoint, remembering
  which interface it belongs to and whether that interface is HID. }
procedure FindEndpoint;
var
  P, L: Word;
  T, CurIf, CurCls, CurPro: Byte;
begin
  CurIf := $FF; CurCls := 0; CurPro := 0;
  if CfgLenG >= 6 then CfgVal := Cfg[5];
  P := 0;
  while P + 2 <= CfgLenG do
  begin
    L := Cfg[P]; T := Cfg[P + 1];
    if (L < 2) or (P + L > CfgLenG) then Break;
    if (T = DT_INTERFACE) and (L >= 9) then
    begin
      CurIf := Cfg[P + 2]; CurCls := Cfg[P + 5]; CurPro := Cfg[P + 7];
    end
    else if (T = DT_ENDPOINT) and (L >= 7) then
    begin
      if (EpWant < 0) and ((Cfg[P + 2] and $80) <> 0)
         and ((Cfg[P + 3] and 3) = 3) then
      begin
        EpWant := Cfg[P + 2] and $0F;
        EpMax  := Cfg[P + 4];
        EpIval := Cfg[P + 6];
        if IfWant < 0 then IfWant := CurIf;
        IsHid   := CurCls = 3;
        IfProto := CurPro;
      end;
    end;
    Inc(P, L);
  end;
end;

{ Which interface a caller-supplied /E lives on -- needed so boot protocol
  is asked of the right one. }
procedure FindIfaceFor(Ep: Integer);
var
  P, L: Word;
  T, CurIf, CurCls, CurPro: Byte;
begin
  CurIf := $FF; CurCls := 0; CurPro := 0;
  P := 0;
  while P + 2 <= CfgLenG do
  begin
    L := Cfg[P]; T := Cfg[P + 1];
    if (L < 2) or (P + L > CfgLenG) then Break;
    if (T = DT_INTERFACE) and (L >= 9) then
    begin
      CurIf := Cfg[P + 2]; CurCls := Cfg[P + 5]; CurPro := Cfg[P + 7];
    end
    else if (T = DT_ENDPOINT) and (L >= 7) then
      if (Cfg[P + 2] and $0F) = Ep then
      begin
        if IfWant < 0 then IfWant := CurIf;
        EpMax := Cfg[P + 4]; EpIval := Cfg[P + 6];
        IsHid := CurCls = 3; IfProto := CurPro;
        Exit;
      end;
    Inc(P, L);
  end;
end;

function ModName(M: Byte): ShortString;
var S: ShortString;
begin
  S := '';
  if (M and $01) <> 0 then S := S + 'LCtrl ';
  if (M and $02) <> 0 then S := S + 'LShift ';
  if (M and $04) <> 0 then S := S + 'LAlt ';
  if (M and $08) <> 0 then S := S + 'LGui ';
  if (M and $10) <> 0 then S := S + 'RCtrl ';
  if (M and $20) <> 0 then S := S + 'RShift ';
  if (M and $40) <> 0 then S := S + 'RAlt ';
  if (M and $80) <> 0 then S := S + 'RGui ';
  ModName := S;
end;

function KeyName(U: Byte): ShortString;
begin
  KeyName := '';
  if (U >= $04) and (U <= $1D) then KeyName := Chr(Ord('A') + U - $04)
  else if (U >= $1E) and (U <= $26) then KeyName := Chr(Ord('1') + U - $1E)
  else if (U >= $3A) and (U <= $45) then KeyName := 'F' + Dec1(U - $39)
  else case U of
    $01: KeyName := 'ROLLOVER';
    $27: KeyName := '0';
    $28: KeyName := 'Enter';   $29: KeyName := 'Esc';
    $2A: KeyName := 'BkSp';    $2B: KeyName := 'Tab';
    $2C: KeyName := 'Space';   $2D: KeyName := '-';
    $2E: KeyName := '=';       $2F: KeyName := '[';
    $30: KeyName := ']';       $31: KeyName := '\';
    $33: KeyName := ';';       $34: KeyName := '''';
    $35: KeyName := '`';       $36: KeyName := ',';
    $37: KeyName := '.';       $38: KeyName := '/';
    $39: KeyName := 'CapsLk';  $47: KeyName := 'ScrLk';
    $46: KeyName := 'PrtSc';   $48: KeyName := 'Pause';
    $49: KeyName := 'Ins';     $4A: KeyName := 'Home';
    $4B: KeyName := 'PgUp';    $4C: KeyName := 'Del';
    $4D: KeyName := 'End';     $4E: KeyName := 'PgDn';
    $4F: KeyName := 'Right';   $50: KeyName := 'Left';
    $51: KeyName := 'Down';    $52: KeyName := 'Up';
    $53: KeyName := 'NumLk';
  else
    if U <> 0 then KeyName := Hex2(U);
  end;
end;

procedure ShowKbd(Len: Byte);
var I: Integer; S: ShortString; N: ShortString;
begin
  if Len < 3 then Exit;
  S := '        ' + ModName(Pkt[0]);
  if S = '        ' then S := '        (no modifier) ';
  N := '';
  for I := 2 to Len - 1 do
    if Pkt[I] <> 0 then
    begin
      if N <> '' then N := N + ' ';
      N := N + KeyName(Pkt[I]);
    end;
  if N = '' then N := '(no keys)';
  WriteLn(S, ' ', N);
end;

procedure ShowMouseRep(Len: Byte);
var S: ShortString; B: Byte;
begin
  if Len < 3 then Exit;
  B := Pkt[0] and 7;
  S := '        buttons ';
  if (B and 1) <> 0 then S := S + 'L' else S := S + '-';
  if (B and 4) <> 0 then S := S + 'M' else S := S + '-';
  if (B and 2) <> 0 then S := S + 'R' else S := S + '-';
  S := S + '  dx ' + Pad(Dec1(Sgn(Pkt[1])), 5) + ' dy ' +
       Pad(Dec1(Sgn(Pkt[2])), 5);
  if Len >= 4 then S := S + ' wheel ' + Dec1(Sgn(Pkt[3]));
  WriteLn(S);
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/A') or (A = '-A') then ShowAll := True
    else if (A = '/K') or (A = '-K') then AsKbd := True
    else if (A = '/M') or (A = '-M') then AsMouse := True
    else if (A = '/B') or (A = '-B') then { boot is the default }
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/E=' then begin Val(A, V, Code); if Code = 0 then EpWant := Integer(V); end
      else if K = '/I=' then begin Val(A, V, Code); if Code = 0 then IfWant := Integer(V); end
      else if K = '/N=' then begin Val(A, V, Code); if Code = 0 then NWant := Word(V); end
      else if K = '/S=' then begin Val(A, V, Code); if Code = 0 then Secs := Word(V); end
      else if K = '/R=' then begin Val(A, V, Code); if Code = 0 then Idle := Word(V); end
      else if K = '/W=' then begin Val(A, V, Code); if Code = 0 then Gap := Word(V); end;
    end;
  end;
end;

var
  Rc, St: Integer;
  Got: Word;
  QLen, N, Tog, I: Byte;
  Polls, NGot, NNak, NErr, NSame: Word;
  Same: Boolean;
  UserEp: Boolean;
  T0, Elapsed: LongInt;
  Stopped: ShortString;

procedure Usage;
begin
  Banner('USBPOLL', VER, 'poll an endpoint and show what comes back');
  WriteLn;
  WriteLn('  USBPOLL [/P=260] [/E=n] [/I=n] [/N=count] [/S=secs] [/W=ms]');
  WriteLn('          [/R=n] [/A] [/B] [/K] [/M]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /E=n     endpoint number.  Default: the first interrupt IN');
  WriteLn('  /I=n     interface to put in boot protocol, default the HID');
  WriteLn('  /N=dec   packets to wait for, default 40.  Counts real');
  WriteLn('           packets, not poll attempts');
  WriteLn('  /S=dec   give up after this many seconds, default 20.  An');
  WriteLn('           idle device NAKs forever and would otherwise hold');
  WriteLn('           the machine for as long as /N asked for -- which,');
  WriteLn('           run from a test harness, looks exactly like a hang');
  WriteLn('  /W=dec   ms between polls, default 8');
  WriteLn('  /A       print every poll, NAKs included.  Very noisy; it is');
  WriteLn('           how you tell a silent device from a program that is');
  WriteLn('           not polling');
  WriteLn('  /R=dec   HID idle rate in 4 ms units, default 0 = report only');
  WriteLn('           on change.  A nonzero rate makes the device repeat');
  WriteLn('           its state, which is how you see a key that was');
  WriteLn('           ALREADY held when polling started.  /R=25 is 100 ms');
  WriteLn('  /B       ask for HID boot protocol (default for a HID iface)');
  WriteLn('  /K       decode packets as HID boot keyboard reports');
  WriteLn('  /M       decode packets as HID boot mouse reports');
  WriteLn('           Without /K or /M the interface protocol decides');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Nothing here is mouse- or keyboard-specific underneath: an');
  WriteLn('unrecognised endpoint is polled just the same and its bytes');
  WriteLn('printed as bytes.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  UserEp := EpWant >= 0;
  Banner('USBPOLL', VER, 'CH375 endpoint poll');

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;

  St := GetDescr(DT_CONFIG, 0, 0, Cfg, 9, Got);
  if Got >= 4 then
  begin
    Got := Cfg[2] or (Word(Cfg[3]) shl 8);
    if Got > SizeOf(Cfg) then Got := SizeOf(Cfg);
    St := GetDescr(DT_CONFIG, 0, 0, Cfg, Got, CfgLenG);
  end;
  if CfgLenG < 9 then
  begin
    St := GetDescrQuick(DT_CONFIG, Cfg, SizeOf(Cfg), QLen);
    CfgLenG := QLen;
  end;
  if CfgLenG < 9 then
  begin
    WriteLn('Cannot read the configuration descriptor.');
    Halt(5);
  end;

  if UserEp then FindIfaceFor(EpWant) else FindEndpoint;
  if CfgLenG >= 6 then CfgVal := Cfg[5];

  if EpWant < 0 then
  begin
    WriteLn('This device has no interrupt IN endpoint.');
    WriteLn('USBINFO lists what it does have; /E=n polls one by number.');
    Halt(6);
  end;

  WriteLn('device ', Hex4(DevDesc[8] or (Word(DevDesc[9]) shl 8)), ':',
          Hex4(DevDesc[10] or (Word(DevDesc[11]) shl 8)),
          '  endpoint ', EpWant, '  max ', EpMax,
          '  interval ', EpIval, ' ms');

  St := SetConfig(CfgVal);
  WriteLn('SET_CONFIGURATION ', CfgVal, ' -> ', StatusStr(St));
  if St <> INT_SUCCESS then Halt(5);

  { A HID interface is asked for boot protocol and infinite idle.  Both are
    optional -- a device that does not implement them stalls, which
    CtrlNoData clears -- and both make the report layout predictable. }
  if IsHid and (IfWant >= 0) then
  begin
    WriteLn('SET_PROTOCOL boot  -> ',
            StatusStr(CtrlNoData($21, HID_SET_PROTOCOL, 0, Word(IfWant))));
    WriteLn('SET_IDLE ', Idle, '        -> ',
            StatusStr(CtrlNoData($21, HID_SET_IDLE, Idle shl 8, Word(IfWant))));
    if (not AsKbd) and (not AsMouse) then
    begin
      AsKbd   := IfProto = 1;
      AsMouse := IfProto = 2;
    end;
  end;

  { No retry: a NAK has to come straight back, or an idle device would
    block the poll loop for as long as it stayed idle. }
  SetRetry($00);
  WriteLn;
  WriteLn('polling endpoint ', EpWant, ' for ', NWant, ' packets or ',
          Secs, ' seconds');
  WriteLn('press a key ON THE USB DEVICE; any key on the PC keyboard stops');
  WriteLn;

  Tog := $80;
  Polls := 0; NGot := 0; NNak := 0; NErr := 0; NSame := 0;
  for I := 0 to SizeOf(Prev) - 1 do Prev[I] := 0;

  T0 := Ticks; Stopped := 'packet count reached';
  while NGot < NWant do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;   { midnight }
    if (Secs > 0) and (Elapsed >= LongInt(Secs) * 182 div 10) then
    begin
      Stopped := 'time limit'; Break;
    end;
    if KeyWaiting then
    begin
      EatKey; Stopped := 'stopped from the PC keyboard'; Break;
    end;
    Inc(Polls);
    St := EpIn(Byte(EpWant), Tog, Pkt, SizeOf(Pkt), N);
    if St = INT_SUCCESS then
    begin
      Inc(NGot);
      Same := True;
      for I := 0 to N - 1 do if Pkt[I] <> Prev[I] then Same := False;
      if Same then Inc(NSame);
      for I := 0 to N - 1 do Prev[I] := Pkt[I];

      Write('  ', Pad(Dec1(NGot), 5), Pad(Dec1(N) + 'B', 5));
      for I := 0 to N - 1 do Write(Hex2(Pkt[I]), ' ');
      if Same then Write('  (repeat)');
      WriteLn;
      if AsKbd   then ShowKbd(N);
      if AsMouse then ShowMouseRep(N);
    end
    else if St = INT_RET_NAK then
    begin
      Inc(NNak);
      if ShowAll then WriteLn('  poll ', Polls, ' -> NAK (nothing to say)');
    end
    else
    begin
      Inc(NErr);
      if (NErr <= 5) or ShowAll then
        WriteLn('  poll ', Polls, ' -> ', StatusStr(St));
      if St = INT_RET_STALL then
      begin
        { A stalled interrupt endpoint stays stalled until cleared, and the
          toggle restarts at DATA0 afterwards. }
        ClrStall(Byte(EpWant) or $80);
        Tog := $80;
      end;
      if St = INT_DISCONNECT then
      begin
        WriteLn('  the device was unplugged.');
        Stopped := 'device unplugged';
        Break;
      end;
    end;
    DelayMs(Gap);
  end;

  WriteLn;
  WriteLn('stopped: ', Stopped, ' after ', (Ticks - T0) * 10 div 182, 's');
  WriteLn('polls ', Polls, ', packets ', NGot, ' (', NSame,
          ' identical to the one before), NAK ', NNak, ', errors ', NErr);
  if NGot = 0 then
  begin
    WriteLn('Nothing ever arrived.  A device that NAKs every poll is');
    WriteLn('working and simply has nothing to report -- press a key on it');
    WriteLn('while this runs.  Errors rather than NAKs mean the endpoint');
    WriteLn('number or the configuration is wrong; USBINFO shows both.');
    Halt(7);
  end;
  Halt(0);
end.
