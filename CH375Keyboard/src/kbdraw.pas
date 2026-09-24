program kbdraw;
{ KBDRAW -- watch a USB keyboard's boot reports and what they translate to.
  CH375Keyboard, StevenC & Claude.  Public domain (the Unlicense).

  The non-resident half of this project, and the one to run first.  It does
  everything USBKBD.COM does except go resident: enumerates the keyboard,
  puts it in boot protocol, polls the interrupt endpoint, turns each report
  into press and release events, and prints the scancode and ASCII byte the
  driver would put in the BIOS buffer.

  If a key comes out wrong here it will come out wrong in the driver, and
  this is very much the easier of the two to debug -- nothing is hooked, so
  a mistake prints a wrong line instead of wedging the machine.

    KBDRAW [/P=260] [/S=secs] [/R=n] [/L] [/X]

      /P=hex   I/O base, default 260
      /S=dec   how long to run, default 30 seconds
      /R=dec   HID idle rate in 4 ms units, default 0 = report on change.
               A nonzero rate repeats the current state, which is the only
               way to see a key that was already held down when this began
      /L       drive the lock LEDs.  Caps, Num and Scroll Lock toggle on
               press and the keyboard's lights are updated to match, which
               is what proves the OUTPUT path works before the resident
               driver has to rely on it
      /X       show every report, not just the ones that changed

  Exit codes: 0 saw at least one keypress, 1 no chip, 2 chip too old,
              3 nothing attached, 4 attached but silent, 5 not a keyboard,
              6 could not configure, 7 nothing was ever typed }

{$MODE OBJFPC}{$H-}

uses ch375, hidkey, chtool;

const
  VER = '1.0.0';

var
  Cfg:     array[0..1023] of Byte;
  Rep:     array[0..63] of Byte;
  Prev:    array[0..7] of Byte;
  CfgLen:  Word = 0;
  Secs:    Word = 30;
  Idle:    Word = 0;
  DoLeds:  Boolean = False;
  ShowAll: Boolean = False;

  KbdIf:   Integer = -1;
  KbdEp:   Integer = -1;
  EpIval:  Byte = 0;
  CfgVal:  Byte = 1;

  Caps, Num, Scroll: Boolean;
  Leds, WantLeds: Byte;
  NPress, NRelease, NReports: Word;

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

{ Find the interface whose protocol says "keyboard", and its interrupt IN
  endpoint.  A combo device puts the mouse on another interface, so the
  protocol byte matters rather than just taking the first HID it sees. }
procedure FindKeyboard;
var
  P, L: Word;
  T, CurIf, CurCls, CurSub, CurPro: Byte;
  InKbd: Boolean;
begin
  CurIf := $FF; CurCls := 0; CurSub := 0; CurPro := 0; InKbd := False;
  if CfgLen >= 6 then CfgVal := Cfg[5];
  P := 0;
  while P + 2 <= CfgLen do
  begin
    L := Cfg[P]; T := Cfg[P + 1];
    if (L < 2) or (P + L > CfgLen) then Break;
    if (T = DT_INTERFACE) and (L >= 9) then
    begin
      CurIf := Cfg[P + 2]; CurCls := Cfg[P + 5];
      CurSub := Cfg[P + 6]; CurPro := Cfg[P + 7];
      InKbd := (CurCls = 3) and (CurPro = 1);
      if InKbd and (KbdIf < 0) then KbdIf := CurIf;
    end
    else if (T = DT_ENDPOINT) and (L >= 7) then
      if InKbd and (KbdEp < 0) and ((Cfg[P + 2] and $80) <> 0)
         and ((Cfg[P + 3] and 3) = 3) then
      begin
        KbdEp := Cfg[P + 2] and $0F;
        EpIval := Cfg[P + 6];
      end;
    Inc(P, L);
  end;
end;

{ HID SET_REPORT, output report 0, one byte of LED bits.  On the control
  endpoint, because a boot keyboard is not required to have an interrupt
  OUT endpoint and most do not. }
function SetLeds(V: Byte): Integer;
var B: array[0..0] of Byte;
begin
  B[0] := V;
  SetLeds := CtrlOut($21, HID_SET_REPORT, $0200, Word(KbdIf), B, 1);
end;

function InReport(U: Byte; const R: array of Byte): Boolean;
var I: Integer;
begin
  InReport := False;
  for I := 2 to 7 do
    if R[I] = U then begin InReport := True; Exit; end;
end;

procedure ShowEvent(const Tag: ShortString; U, Mods: Byte);
var
  E: TKeyEvent;
  S: ShortString;
begin
  E := Translate(U, Mods, Caps, Num);
  S := '  ' + Pad(Tag, 8) + Pad(Hex2(U), 4) + Pad(UsageName(U), 9);
  if not E.Ok then
    S := S + '(no PC equivalent)'
  else
  begin
    if E.Ext then S := S + 'E0 ';
    S := S + 'scan ' + Hex2(E.Scan);
    if E.Ascii <> 0 then
    begin
      S := S + '  ascii ' + Hex2(E.Ascii);
      if (E.Ascii >= 32) and (E.Ascii < 127) then
        S := S + ' "' + Chr(E.Ascii) + '"';
    end
    else
      S := S + '  ascii --';
    S := S + '   BIOS word ' + Hex2(E.Scan) + Hex2(E.Ascii);
  end;
  WriteLn(S);
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/L') or (A = '-L') then DoLeds := True
    else if (A = '/X') or (A = '-X') then ShowAll := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/S=' then begin Val(A, V, Code); if Code = 0 then Secs := Word(V); end
      else if K = '/R=' then begin Val(A, V, Code); if Code = 0 then Idle := Word(V); end;
    end;
  end;
end;

var
  Rc, St: Integer;
  Got: Word;
  QLen, N, Tog, I: Byte;
  T0, Elapsed: LongInt;
  U: Byte;
  Mods, OldMods: Byte;
  Changed: Boolean;

procedure Usage;
begin
  Banner('KBDRAW', VER, 'watch a USB keyboard and what it translates to');
  WriteLn;
  WriteLn('  KBDRAW [/P=260] [/S=secs] [/R=n] [/L] [/X]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /S=dec   how long to run, default 30 seconds');
  WriteLn('  /R=dec   HID idle rate in 4 ms units, default 0 = report on');
  WriteLn('           change.  A nonzero rate repeats the current state,');
  WriteLn('           which is the only way to see a key that was already');
  WriteLn('           held down when this began');
  WriteLn('  /L       drive the lock LEDs.  Caps, Num and Scroll toggle on');
  WriteLn('           press and the keyboard lights follow, which proves');
  WriteLn('           the OUTPUT path before the resident driver needs it');
  WriteLn('  /X       show every report, not just the ones that changed');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('The non-resident half of this project, and the one to run');
  WriteLn('first.  It does everything USBKBD.COM does except go resident.');
  WriteLn('If a key comes out wrong here it will come out wrong in the');
  WriteLn('driver, and this is much the easier of the two to debug --');
  WriteLn('nothing is hooked, so a mistake prints a wrong line instead of');
  WriteLn('wedging the machine.');
  WriteLn;
  WriteLn('Exit: 0 saw a keypress, 1 no chip, 2 chip too old, 3 nothing');
  WriteLn('      attached, 4 attached but silent, 5 not a keyboard,');
  WriteLn('      6 could not configure, 7 nothing was ever typed');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('KBDRAW', VER, 'USB keyboard report viewer');

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
    St := GetDescr(DT_CONFIG, 0, 0, Cfg, Got, CfgLen);
  end;
  if CfgLen < 9 then
  begin
    St := GetDescrQuick(DT_CONFIG, Cfg, SizeOf(Cfg), QLen);
    CfgLen := QLen;
  end;

  FindKeyboard;
  if (KbdIf < 0) or (KbdEp < 0) then
  begin
    WriteLn('No HID boot keyboard interface here.');
    WriteLn('USBINFO in CH375USBTOOLS lists what this device does have; a');
    WriteLn('keyboard shows class 03 subclass 01 protocol 01.');
    Halt(5);
  end;

  WriteLn('device ', Hex4(DevDesc[8] or (Word(DevDesc[9]) shl 8)), ':',
          Hex4(DevDesc[10] or (Word(DevDesc[11]) shl 8)),
          '  keyboard on interface ', KbdIf, ', endpoint ', KbdEp,
          ', interval ', EpIval, ' ms');

  St := SetConfig(CfgVal);
  WriteLn('SET_CONFIGURATION ', CfgVal, ' -> ', StatusStr(St));
  if St <> INT_SUCCESS then Halt(6);
  WriteLn('SET_PROTOCOL boot   -> ',
          StatusStr(CtrlNoData($21, HID_SET_PROTOCOL, 0, Word(KbdIf))));
  WriteLn('SET_IDLE ', Idle, '          -> ',
          StatusStr(CtrlNoData($21, HID_SET_IDLE, Idle shl 8, Word(KbdIf))));

  Caps := False; Num := False; Scroll := False;
  Leds := $FF;                       { force the first sync }
  if DoLeds then
  begin
    WantLeds := 0;
    WriteLn('SET_REPORT leds 00  -> ', StatusStr(SetLeds(0)));
    Leds := 0;
  end;

  SetRetry($00);
  WriteLn;
  WriteLn('watching for ', Secs, ' seconds -- type on the USB keyboard.');
  WriteLn('press any key on the PC keyboard to stop.');
  WriteLn;

  for I := 0 to 7 do Prev[I] := 0;
  OldMods := 0;
  Tog := $80;
  NPress := 0; NRelease := 0; NReports := 0;
  T0 := Ticks;

  while True do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
    if (Secs > 0) and (Elapsed >= LongInt(Secs) * 182 div 10) then Break;
    if KeyWaiting then begin EatKey; Break; end;

    St := EpIn(Byte(KbdEp), Tog, Rep, SizeOf(Rep), N);
    if St = INT_SUCCESS then
    begin
      if N >= 3 then
      begin
        Inc(NReports);
        for I := N to 7 do Rep[I] := 0;

        { A rollover error is the keyboard saying it has lost track, not a
          key.  Acting on it produces a burst of nonsense exactly when
          somebody is typing fast. }
        if Rep[2] = USG_ROLLOVER then
        begin
          WriteLn('  rollover -- more keys held than the keyboard can report');
          Continue;
        end;

        Mods := Rep[0];
        Changed := Mods <> OldMods;
        for I := 2 to 7 do if Rep[I] <> Prev[I] then Changed := True;

        if Changed or ShowAll then
        begin
          Write('  report  ');
          for I := 0 to 7 do Write(Hex2(Rep[I]), ' ');
          WriteLn('  mods ', ModifierNames(Mods));
        end;

        { Presses: in this report, not in the last one. }
        for I := 2 to 7 do
        begin
          U := Rep[I];
          if (U > USG_ROLLOVER) and (not InReport(U, Prev)) then
          begin
            Inc(NPress);
            if U = $39 then Caps   := not Caps;
            if U = $53 then Num    := not Num;
            if U = $47 then Scroll := not Scroll;
            ShowEvent('press', U, Mods);
          end;
        end;

        { Releases: in the last report, not in this one. }
        for I := 2 to 7 do
        begin
          U := Prev[I];
          if (U > USG_ROLLOVER) and (not InReport(U, Rep)) then
          begin
            Inc(NRelease);
            ShowEvent('release', U, Mods);
          end;
        end;

        if DoLeds then
        begin
          WantLeds := 0;
          if Num    then WantLeds := WantLeds or LED_NUM;
          if Caps   then WantLeds := WantLeds or LED_CAPS;
          if Scroll then WantLeds := WantLeds or LED_SCROLL;
          if WantLeds <> Leds then
          begin
            St := SetLeds(WantLeds);
            WriteLn('  leds -> ', Hex2(WantLeds), '  ', StatusStr(St));
            Leds := WantLeds;
          end;
        end;

        for I := 0 to 7 do Prev[I] := Rep[I];
        OldMods := Mods;
      end;
    end
    else if St = INT_RET_STALL then
    begin
      ClrStall(Byte(KbdEp) or $80);
      Tog := $80;
    end
    else if St = INT_DISCONNECT then
    begin
      WriteLn('  the keyboard was unplugged.');
      Break;
    end;

    DelayMs(8);
  end;

  WriteLn;
  WriteLn('reports ', NReports, ', presses ', NPress,
          ', releases ', NRelease);
  WriteLn('lock state: caps=', Caps, ' num=', Num, ' scroll=', Scroll);
  if NPress = 0 then
  begin
    WriteLn('Nothing was typed.  With /R=0 a key already held down when');
    WriteLn('this started is not a change and produces no report -- /R=25');
    WriteLn('makes the keyboard repeat its state every 100 ms instead.');
    Halt(7);
  end;
  Halt(0);
end.
