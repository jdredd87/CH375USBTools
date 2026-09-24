program clicktst;
{ Button diagnostic for USBMOUSE  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  Movement working while clicks do not splits the problem cleanly in two,
  and this says which half it is.  It watches three things at once:

    the raw HID report the driver last received      (function 7F03h)
    the button mask INT 33h reports                  (function 03h)
    the press and release counters                   (functions 05h/06h)

  If the raw report's byte 0 never goes non-zero, the press is not reaching
  the driver -- the mouse is not sending it, or not in the format expected.
  If it does but the INT 33h mask stays 0, the fault is in the driver.  If
  both move and an application still ignores clicks, that application is
  reading the mouse some other way, most likely the function 0Ch event
  handler.

      CLICKTST [seconds] [/Q]   default 30, /Q for no sound

  It beeps to say when it is watching, chirps once per button press so you
  get confirmation without having to look at the screen, and beeps twice
  when it is done.  The speaker runs off PIT channel 2, which is nothing to
  do with channel 0 that the driver reprograms, so this cannot disturb the
  poll rate or the DOS clock.

  Click any button while it runs.  Exit code 0 if a press was seen.        }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses Dos, chtool;

const
  VER = '1.0.0';

var
  Quiet: Boolean;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

procedure OutB(P: Word; V: Byte); assembler;
asm
  mov dx, P
  mov al, V
  out dx, al
end;

procedure Wait(Ms: Word);
var I, J: Word;
begin
  for I := 1 to Ms do
    for J := 1 to 700 do InB($61);
end;

{ PC speaker: PIT channel 2 in square-wave mode gated onto port 61h bits 0
  and 1.  Channel 0 -- the one USBMOUSE divides by eight to poll the mouse --
  is a different counter entirely and is not touched here. }
procedure Beep(Freq, Ms: Word);
var Div_: Word; Old: Byte;
begin
  if Quiet or (Freq = 0) then
  begin
    Wait(Ms);
    Exit;
  end;
  Div_ := Word(1193182 div LongInt(Freq));
  OutB($43, $B6);
  OutB($42, Lo(Div_));
  OutB($42, Hi(Div_));
  Old := InB($61);
  OutB($61, Old or 3);
  Wait(Ms);
  OutB($61, Old and $FC);
end;

procedure M(var R: Registers);
begin
  Intr($33, R);
end;

function Now100: LongInt;
var H, Mi, S, C: Word;
begin
  GetTime(H, Mi, S, C);
  Now100 := LongInt(H) * 360000 + LongInt(Mi) * 6000 + LongInt(S) * 100 + C;
end;

function Hex1(B: Byte): Char;
begin
  if B < 10 then Hex1 := Chr(Ord('0') + B) else Hex1 := Chr(Ord('A') + B - 10);
end;

function Hex2(B: Byte): ShortString;
begin
  Hex2 := Hex1(B shr 4) + Hex1(B and 15);
end;

var
  R: Registers;
  T0, T1: LongInt;
  N, Code: Integer;
  LastRaw, LastBtn, LastLen: Word;
  Raw0, Raw1, Raw2, Raw3, Seen, Len: Byte;
  Shown: Integer;
  PL, PR, PM: Word;
  AnyRaw, AnyInt: Boolean;

procedure Usage;
begin
  Banner('CLICKTST', VER, 'button diagnostic for USBMOUSE');
  WriteLn;
  WriteLn('  CLICKTST [seconds] [/Q]');
  WriteLn;
  WriteLn('  seconds  how long to watch, default 30');
  WriteLn('  /Q       no sound');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Movement working while clicks do not splits the problem cleanly');
  WriteLn('in two, and this says which half it is.  It watches three');
  WriteLn('things at once:');
  WriteLn('  the raw HID report the driver last received  (fn 7F03h)');
  WriteLn('  the button mask INT 33h reports              (fn 03h)');
  WriteLn('  the press and release counters               (fn 05h/06h)');
  WriteLn;
  WriteLn('If the raw report''s byte 0 never goes non-zero, the press is');
  WriteLn('not reaching the driver -- the mouse is not sending it, or not');
  WriteLn('in the format expected.  If it does but the INT 33h mask stays');
  WriteLn('0, the fault is in the driver.  If both move and an application');
  WriteLn('still ignores clicks, that application is reading the mouse');
  WriteLn('some other way, most likely the function 0Ch event handler.');
  WriteLn;
  WriteLn('It beeps when it starts watching, chirps once per press so you');
  WriteLn('get confirmation without looking at the screen, and beeps twice');
  WriteLn('when done.  The speaker runs off PIT channel 2, nothing to do');
  WriteLn('with channel 0 that the driver reprograms, so it cannot disturb');
  WriteLn('the poll rate or the DOS clock.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  N := 30;
  Quiet := False;
  for Code := 1 to ParamCount do
  begin
    if (ParamStr(Code) = '/Q') or (ParamStr(Code) = '/q') then Quiet := True;
  end;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), N, Code);
    if (Code <> 0) or (N < 5) or (N > 180) then N := 30;
  end;

  R.AX := 0; M(R);
  if R.AX <> $FFFF then
  begin
    WriteLn('No INT 33h driver.  Load USBMOUSE first.');
    Halt(1);
  end;

  R.AX := $7F00; M(R);
  WriteLn('USBMOUSE state ', R.BX, ', endpoint ', Lo(R.CX),
          ', reports so far ', R.DX);
  R.AX := $7F03; M(R);
  WriteLn('last raw report: ', Hex2(Lo(R.BX)), ' ', Hex2(Hi(R.BX)), ' ',
          Hex2(Lo(R.CX)), ' ', Hex2(Hi(R.CX)),
          '   length ', Hi(R.AX),
          '   button bits ever seen ', Hex2(Lo(R.AX)));
  WriteLn;
  WriteLn('  raw = the bytes the mouse sent, byte 0 is the button mask');
  WriteLn('  int33 = what function 03h reports');
  WriteLn;

  { clear the counters so anything below is from this run }
  R.AX := 5; R.BX := 0; M(R);
  R.AX := 5; R.BX := 1; M(R);
  R.AX := 5; R.BX := 2; M(R);
  R.AX := 6; R.BX := 0; M(R);
  R.AX := 6; R.BX := 1; M(R);
  R.AX := 6; R.BX := 2; M(R);

  WriteLn('*** MOVE AND CLICK THE MOUSE NOW -- watching for ', N,
          ' seconds ***');
  { rising two-tone, the last thing before the window opens: "go" }
  Beep(880, 180);
  Wait(60);
  Beep(1320, 260);

  LastRaw := $FFFF; LastBtn := $FFFF; LastLen := $FFFF;
  Shown := 0; AnyRaw := False; AnyInt := False;
  T0 := Now100;
  repeat
    R.AX := $7F03; M(R);
    Raw0 := Lo(R.BX); Raw1 := Hi(R.BX);
    Raw2 := Lo(R.CX); Raw3 := Hi(R.CX);
    Seen := Lo(R.AX); Len := Hi(R.AX);
    { Seen is the driver's running OR of every button mask it has received,
      so a press too brief to catch in either poll below still registers. }
    if (Raw0 <> 0) or (Seen <> 0) then AnyRaw := True;

    if ((Raw0 <> Lo(LastRaw)) or (Len <> LastLen)) and (Shown < 40) then
    begin
      Inc(Shown);
      WriteLn('  raw ', Hex2(Raw0), ' ', Hex2(Raw1), ' ', Hex2(Raw2), ' ',
              Hex2(Raw3), '   len ', Len, '   seen ', Hex2(Seen));
      LastRaw := Raw0;
      LastLen := Len;
    end;

    R.AX := 3; M(R);
    if R.BX <> 0 then AnyInt := True;
    if R.BX <> LastBtn then
    begin
      if Shown < 40 then
      begin
        Inc(Shown);
        WriteLn('  int33 buttons ', R.BX, '   x=', R.CX, ' y=', R.DX);
      end;
      { chirp on the way down only, so a click is one sound not two }
      if (R.BX <> 0) and ((LastBtn = 0) or (LastBtn = $FFFF)) then
        Beep(2200, 70);
      LastBtn := R.BX;
    end;

    T1 := Now100;
    if T1 < T0 then T0 := T1;
  until (T1 - T0) >= LongInt(N) * 100;

  { falling two-tone: "done" }
  Beep(1320, 180);
  Wait(60);
  Beep(880, 260);

  WriteLn;
  R.AX := $7F03; M(R);
  WriteLn('button bits ever seen in a raw report: ', Hex2(Lo(R.AX)));
  WriteLn('reports carrying a button down       : ', R.DX);
  PL := 0; PR := 0; PM := 0;
  R.AX := 5; R.BX := 0; M(R); PL := R.BX;
  R.AX := 5; R.BX := 1; M(R); PR := R.BX;
  R.AX := 5; R.BX := 2; M(R); PM := R.BX;
  WriteLn('press counts   left=', PL, '  right=', PR, '  middle=', PM);
  R.AX := 6; R.BX := 0; M(R); Write('release counts left=', R.BX);
  R.AX := 6; R.BX := 1; M(R); Write('  right=', R.BX);
  R.AX := 6; R.BX := 2; M(R); WriteLn('  middle=', R.BX);
  { the counters catch a click too short to be caught by polling }
  if (PL <> 0) or (PR <> 0) or (PM <> 0) then AnyInt := True;

  WriteLn;
  if AnyRaw and AnyInt then
    WriteLn('Presses arrive and INT 33h reports them.  The driver is fine.')
  else if AnyRaw then
    WriteLn('The mouse sent a button but INT 33h did not report it: driver bug.')
  else
    WriteLn('No button bit ever arrived from the mouse in ', N, ' seconds.');

  if AnyRaw then Halt(0) else Halt(5);
end.
