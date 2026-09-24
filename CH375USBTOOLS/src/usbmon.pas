program usbmon;
{ USBMON -- watch the USB port for things being plugged in and pulled out.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  Everything else in the suite takes one look at whatever is attached.  This
  sits on the port instead, so hot-plug behaviour can be observed: how long
  a device takes to settle, whether it enumerates the same way twice, and
  which devices announce a disconnect properly rather than just going quiet.

    USBMON [/P=260] [/S=secs] [/E] [/Q]

      /P=hex   I/O base, default 260
      /S=dec   how long to watch, in seconds.  Default 60, 0 = until a key
      /E       enumerate each device as it arrives and print what it is.
               Without it only attach and detach are reported, which is
               the lighter touch and does not disturb the device
      /Q       quiet: only the events, no periodic status line

  Press a key to stop early.

  Attachment is read from register 07h bit 0 rather than waiting on the
  interrupt, because a device pulled out while the chip is idle does not
  always raise one -- polling the bit catches both directions reliably.

  Exit codes: 0 ok, 1 no chip }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

var
  Secs:  Word = 60;
  Enum:  Boolean = False;
  Quiet: Boolean = False;

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

var
  T0, T, Last: LongInt;
  Attached, WasAttached: Boolean;
  R7: Byte;
  Rc: Integer;
  Events: Word = 0;
  Elapsed: LongInt;
  I, Code: Integer;
  A, K: ShortString;
  V: LongInt;
  Stamp: ShortString;

procedure Usage;
begin
  Banner('USBMON', VER, 'watch the USB port for plug and unplug');
  WriteLn;
  WriteLn('  USBMON [/P=260] [/S=secs] [/E] [/Q]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /S=dec   how long to watch, in seconds.  Default 60,');
  WriteLn('           0 = until a key is pressed');
  WriteLn('  /E       enumerate each device as it arrives and say what it');
  WriteLn('           is.  Without it only attach and detach are reported,');
  WriteLn('           which is lighter and does not disturb the device');
  WriteLn('  /Q       quiet: only the events, no periodic status line');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Press a key to stop early.');
  WriteLn;
  WriteLn('Everything else in the suite takes one look at whatever is');
  WriteLn('attached.  This sits on the port, so hot-plug behaviour can be');
  WriteLn('watched: how long a device takes to settle, whether it');
  WriteLn('enumerates the same way twice, and which devices announce a');
  WriteLn('disconnect rather than just going quiet.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/E') or (A = '-E') then Enum := True
    else if (A = '/Q') or (A = '-Q') then Quiet := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/S=' then begin Val(A, V, Code); if Code = 0 then Secs := Word(V); end;
    end;
  end;

  Banner('USBMON', VER, 'USB port monitor');
  if not ChipHere(Base) then
  begin
    WriteLn('No CH375 responds at ', Hex4(Base), 'h.');
    Halt(1);
  end;
  ChipReset;
  WriteLn('chip ', Hex2(IcVer), ' at ', Hex4(Base), 'h');

  { Idle host mode with SOF running: enough for the attach bit to be live
    without holding a device in any particular state. }
  SetMode(6);
  DelayMs(100);

  if Secs = 0 then WriteLn('watching until a key is pressed')
              else WriteLn('watching for ', Secs, ' seconds; press a key to stop');
  WriteLn('plug something in, or pull it out');
  WriteLn;

  T0 := Ticks; Last := -1;
  R7 := GetReg($07);
  WasAttached := (R7 and 1) <> 0;
  if WasAttached then WriteLn('  0s   already attached  reg07=', Hex2(R7))
                 else WriteLn('  0s   port empty        reg07=', Hex2(R7));

  while True do
  begin
    T := Ticks;
    Elapsed := T - T0;
    if Elapsed < 0 then begin T0 := T; Elapsed := 0; end;   { midnight }
    if (Secs > 0) and (Elapsed >= LongInt(Secs) * 182 div 10) then Break;
    if KeyWaiting then begin EatKey; Break; end;

    R7 := GetReg($07);
    Attached := (R7 and 1) <> 0;
    Stamp := '  ' + Pad(Dec1(Elapsed * 10 div 182) + 's', 5);

    if Attached <> WasAttached then
    begin
      Inc(Events);
      if Attached then
      begin
        WriteLn(Stamp, 'ATTACHED           reg07=', Hex2(R7),
                '  low speed=', (R7 shr 4) and 1);
        if Enum then
        begin
          { Give the device the settling time a hub would, then bring the
            bus up from scratch -- a fresh device has not been addressed. }
          DelayMs(200);
          Rc := BusUp;
          if Rc = BU_OK then
            WriteLn('        enumerated ',
                    Hex4(DevDesc[8] or (Word(DevDesc[9]) shl 8)), ':',
                    Hex4(DevDesc[10] or (Word(DevDesc[11]) shl 8)),
                    '  ', ClassName(DevDesc[4], DevDesc[5], DevDesc[6]),
                    '  ep0 max ', Ep0Max)
          else
            WriteLn('        ', BusUpReason(Rc));
          SetMode(6);
          DelayMs(50);
        end;
      end
      else
        WriteLn(Stamp, 'DETACHED           reg07=', Hex2(R7));
      WasAttached := Attached;
    end
    else if (not Quiet) and (Elapsed div 182 <> Last) then
    begin
      Last := Elapsed div 182;
      if (Last mod 10) = 0 then
      begin
        if Attached then Write(Stamp, 'still attached     ')
                    else Write(Stamp, 'still empty        ');
        WriteLn('reg07=', Hex2(R7));
      end;
    end;

    DelayMs(50);
  end;

  WriteLn;
  WriteLn(Events, ' event(s) in ', (Ticks - T0) * 10 div 182, ' seconds.');
  Halt(0);
end.
