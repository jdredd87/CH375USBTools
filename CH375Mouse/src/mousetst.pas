program mousetst;
{ INT 33h conformance test for USBMOUSE.COM  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  The USB half of this driver and its INT 33h half fail independently, so
  they are tested independently.  USBMOUSE exposes a private function 7F01h
  that pushes a fabricated three-byte HID boot report through exactly the
  same code a real one would take -- scaling, clamping, button edges, the
  text cursor, the event callback.  Every case is then exact and repeatable,
  which waving a real mouse can never be, and the checks still work when no
  mouse is attached at all.

  Function 7F02h suspends the driver's own polling while that runs.  It has
  to: with a live mouse the real reports land between an injection and the
  read-back, and the deterministic checks turn into a race.  Polling is put
  back before the last section, which watches for real reports.

  Run it with the driver already loaded:

      USBMOUSE
      MOUSETST
      USBMOUSE /U

  Exit code is the number of failed checks, capped at 20.                }

{$MODE OBJFPC}{$H-}

uses Dos, chtool;

const
  VER = '1.0.0';

var
  Fails: Integer;
  Checks: Integer;
  InjCount: Word;                 { reports pushed in by Inject }
  QuietAt: Word;                  { driver report count when polling stopped }

procedure M(var R: Registers);
begin
  Intr($33, R);
end;

procedure Check(const What: ShortString; Ok: Boolean);
begin
  Inc(Checks);
  if Ok then WriteLn('  ok    ', What)
  else begin WriteLn('  FAIL  ', What); Inc(Fails); end;
end;

procedure CheckEq(const What: ShortString; Got, Want: LongInt);
begin
  Inc(Checks);
  if Got = Want then WriteLn('  ok    ', What, ' = ', Got)
  else
  begin
    WriteLn('  FAIL  ', What, ' = ', Got, ', expected ', Want);
    Inc(Fails);
  end;
end;

{ Stop or restart the driver's own polling.  Returns the previous setting.
  Without this the checks below are a race: they inject an exact report and
  read the state straight back, and a real mouse moving under them makes the
  answer whatever the last real report said. }
function PausePoll(Off: Word): Word;
var R: Registers;
begin
  R.AX := $7F02;
  R.BX := Off;
  M(R);
  PausePoll := R.BX;
end;

{ Push one HID boot report into the driver. }
procedure Inject(Btn: Byte; Dx, Dy: Integer);
var R: Registers;
begin
  Inc(InjCount);
  R.AX := $7F01;
  R.BX := Btn;
  R.CX := (Word(Dy and $FF) shl 8) or Word(Dx and $FF);
  M(R);
end;

procedure GetPos(var Btn, X, Y: Integer);
var R: Registers;
begin
  R.AX := 3;
  M(R);
  Btn := R.BX; X := R.CX; Y := R.DX;
end;

var
  R: Registers;
  Btn, X, Y: Integer;
  I, Live, Ep, LastSt, NRep, NRep2: Integer;
  DrvSeg: Word;
  DrvVer: ShortString;
  T0: LongInt;
  H, Mn, Sc, Hu: Word;

procedure Usage;
begin
  Banner('MOUSETST', VER, 'INT 33h conformance test for USBMOUSE.COM');
  WriteLn;
  WriteLn('  MOUSETST');
  WriteLn;
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('It takes no other switches.  Run it with the driver loaded:');
  WriteLn('  USBMOUSE');
  WriteLn('  MOUSETST');
  WriteLn('  USBMOUSE /U');
  WriteLn;
  WriteLn('The USB half of the driver and its INT 33h half fail');
  WriteLn('independently, so they are tested independently.  USBMOUSE');
  WriteLn('exposes a private function 7F01h that pushes a fabricated');
  WriteLn('three-byte HID boot report through exactly the code a real one');
  WriteLn('would take -- scaling, clamping, button edges, the text cursor,');
  WriteLn('the event callback.  Every case is then exact and repeatable,');
  WriteLn('which waving a real mouse can never be, and the checks still');
  WriteLn('work with no mouse attached at all.');
  WriteLn;
  WriteLn('Function 7F02h suspends the driver''s polling while that runs.');
  WriteLn('It has to: with a live mouse the real reports land between an');
  WriteLn('injection and the read-back, and the deterministic checks turn');
  WriteLn('into a race.  Polling is restored before the last section,');
  WriteLn('which watches for real reports.');
  WriteLn;
  WriteLn('This talks to the resident driver through INT 33h, never to the');
  WriteLn('card, so there is no I/O base to set here -- USBMOUSE @hex sets');
  WriteLn('it, and USBMOUSE /S prints it back.');
  WriteLn;
  WriteLn('Exit code is the number of failed checks, capped at 20.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Fails := 0; Checks := 0; InjCount := 0;
  Banner('MOUSETST', VER, 'USBMOUSE INT 33h test');

  { ---- is the driver there at all? ---- }
  R.AX := 0;
  M(R);
  Check('function 00h reports a driver installed', R.AX = $FFFF);
  if R.AX <> $FFFF then
  begin
    WriteLn;
    WriteLn('No INT 33h driver responded.  Load USBMOUSE first.');
    Halt(20);
  end;
  CheckEq('button count', R.BX, 3);

  R.AX := $24;
  M(R);
  WriteLn('  INT 33h API level ', Hi(R.BX), '.', Lo(R.BX),
          '  type ', Hi(R.CX), '  irq ', Lo(R.CX));

  { Function 24h reports which INT 33h API the driver implements, which is
    deliberately 7.00 and says nothing about which build is loaded.  The
    build's own version is ASCII at offset 010Bh in the resident image, just
    past the 'USBMOUS1' signature, so it can be read straight out of memory
    without the driver having to answer a call.  Do not check it against a
    fixed number here: this passes for every version, which is the point. }
  DrvSeg := MemW[0 : $33 * 4 + 2];
  DrvVer := '';
  I := 0;
  while (I < 8) and (Mem[DrvSeg : $010B + I] <> Ord('$')) do
  begin
    DrvVer := DrvVer + Chr(Mem[DrvSeg : $010B + I]);
    Inc(I);
  end;
  Check('resident copy carries a version string',
        (Length(DrvVer) >= 3) and (Pos('.', DrvVer) > 1) and
        (DrvVer[1] >= '0') and (DrvVer[1] <= '9'));
  WriteLn('  USBMOUSE version ', DrvVer);

  R.AX := $7F00;
  M(R);
  Live := R.BX; Ep := Lo(R.CX); LastSt := Hi(R.CX); NRep := R.DX;
  Write('  USB state: ');
  case Live of
    0: WriteLn('no device found');
    1: WriteLn('mouse enumerated, endpoint ', Ep);
    2: WriteLn('something is plugged in but did not enumerate');
  else
    WriteLn('unknown (', Live, ')');
  end;
  WriteLn('  last CH375 poll status ', LastSt, ', reports so far ', NRep);

  PausePoll(1);
  R.AX := $7F00; M(R);
  QuietAt := R.DX;
  WriteLn('  (driver polling suspended for the deterministic checks)');

  { ---- position ---- }
  WriteLn;
  WriteLn('position and clamping');
  R.AX := 7; R.CX := 0;   R.DX := 639; M(R);
  R.AX := 8; R.CX := 0;   R.DX := 199; M(R);
  R.AX := 4; R.CX := 100; R.DX := 50;  M(R);
  GetPos(Btn, X, Y);
  CheckEq('set position X', X, 100);
  CheckEq('set position Y', Y, 50);

  { default sensitivity is 8 mickeys per 8 units, so one count is one unit }
  R.AX := $0F; R.CX := 8; R.DX := 8; M(R);
  Inject(0, 10, 5);
  GetPos(Btn, X, Y);
  CheckEq('X after +10', X, 110);
  CheckEq('Y after +5', Y, 55);

  Inject(0, -20, -10);
  GetPos(Btn, X, Y);
  CheckEq('X after -20', X, 90);
  CheckEq('Y after -10', Y, 45);

  { negative deltas are two's complement in the report byte }
  Inject(0, -1, 0);
  GetPos(Btn, X, Y);
  CheckEq('X after -1', X, 89);

  { clamp low }
  for I := 1 to 10 do Inject(0, -127, -127);
  GetPos(Btn, X, Y);
  CheckEq('clamped at min X', X, 0);
  CheckEq('clamped at min Y', Y, 0);

  { clamp high }
  for I := 1 to 10 do Inject(0, 127, 127);
  GetPos(Btn, X, Y);
  CheckEq('clamped at max X', X, 639);
  CheckEq('clamped at max Y', Y, 199);

  { narrowed range clamps too }
  R.AX := 7; R.CX := 100; R.DX := 200; M(R);
  R.AX := 8; R.CX := 20;  R.DX := 40;  M(R);
  for I := 1 to 10 do Inject(0, -127, -127);
  GetPos(Btn, X, Y);
  CheckEq('clamped at narrowed min X', X, 100);
  CheckEq('clamped at narrowed min Y', Y, 20);
  R.AX := 7; R.CX := 0; R.DX := 639; M(R);
  R.AX := 8; R.CX := 0; R.DX := 199; M(R);

  { ---- sub-unit accumulation ---- }
  WriteLn;
  WriteLn('sensitivity scaling');
  R.AX := 4; R.CX := 300; R.DX := 100; M(R);
  R.AX := $0F; R.CX := 16; R.DX := 16; M(R);   { 16 mickeys per 8 units = half }
  for I := 1 to 16 do Inject(0, 1, 0);
  GetPos(Btn, X, Y);
  CheckEq('16 counts at half speed move 8 units', X - 300, 8);
  R.AX := $0F; R.CX := 8; R.DX := 8; M(R);

  { ---- motion counters ---- }
  WriteLn;
  WriteLn('motion counters');
  R.AX := $0B; M(R);                            { clear }
  Inject(0, 7, -3);
  Inject(0, 5, 1);
  R.AX := $0B; M(R);
  CheckEq('mickeys X', Integer(R.CX), 12);
  CheckEq('mickeys Y', Integer(R.DX), -2);
  R.AX := $0B; M(R);
  CheckEq('counters cleared by reading', Integer(R.CX), 0);

  { ---- buttons ---- }
  WriteLn;
  WriteLn('buttons');
  { clear every counter this section asserts on, not just the left one --
    a stray report on any button would otherwise show up as an off-by-one
    somewhere unrelated }
  for I := 0 to 2 do
  begin
    R.AX := 5; R.BX := I; M(R);
    R.AX := 6; R.BX := I; M(R);
  end;
  R.AX := 4; R.CX := 200; R.DX := 80; M(R);

  Inject(1, 0, 0);
  GetPos(Btn, X, Y);
  CheckEq('left button down', Btn, 1);
  Inject(0, 0, 0);
  GetPos(Btn, X, Y);
  CheckEq('left button up', Btn, 0);

  R.AX := 5; R.BX := 0; M(R);
  CheckEq('left press count', R.BX, 1);
  CheckEq('press recorded at X', R.CX, 200);
  CheckEq('press recorded at Y', R.DX, 80);
  R.AX := 6; R.BX := 0; M(R);
  CheckEq('left release count', R.BX, 1);
  R.AX := 5; R.BX := 0; M(R);
  CheckEq('press count cleared by reading', R.BX, 0);

  Inject(2, 0, 0);
  GetPos(Btn, X, Y);
  CheckEq('right button down', Btn, 2);
  Inject(6, 0, 0);
  GetPos(Btn, X, Y);
  CheckEq('right and middle down', Btn, 6);
  Inject(0, 0, 0);
  R.AX := 5; R.BX := 2; M(R);
  CheckEq('middle press count', R.BX, 1);

  { ---- cursor show/hide must not fault ---- }
  WriteLn;
  WriteLn('cursor');
  R.AX := 1; M(R);
  Inject(0, 20, 10);
  R.AX := 2; M(R);
  Check('show, move and hide survived', True);

  { ---- reset ---- }
  R.AX := 0; M(R);
  GetPos(Btn, X, Y);
  CheckEq('reset centres X', X, 320);
  CheckEq('reset centres Y', Y, 100);

  { The checks above are only meaningful if nothing else was moving the
    mouse underneath them. }
  R.AX := $7F00; M(R);
  CheckEq('polling stayed suspended (reports applied)',
          R.DX - QuietAt, InjCount);

  { ---- did any real report arrive while we were working? ---- }
  PausePoll(0);
  WriteLn;
  WriteLn('watching for real USB reports for about 10 seconds');
  R.AX := $7F00; M(R);
  NRep := R.DX;
  GetTime(H, Mn, Sc, Hu);
  T0 := LongInt(H) * 360000 + LongInt(Mn) * 6000 + LongInt(Sc) * 100 + Hu;
  repeat
    GetTime(H, Mn, Sc, Hu);
    I := 0;
  until (LongInt(H) * 360000 + LongInt(Mn) * 6000 + LongInt(Sc) * 100 + Hu
         - T0) > 1000;
  R.AX := $7F00; M(R);
  NRep2 := R.DX;
  Live := R.BX; LastSt := Hi(R.CX);
  WriteLn('  reports delivered by the mouse: ', NRep2 - NRep);
  WriteLn('  USB state ', Live, ', last CH375 poll status ', LastSt);
  if NRep2 = NRep then
    WriteLn('  (none -- the USB side is not delivering; see README)')
  else
  begin
    GetPos(Btn, X, Y);
    WriteLn('  live position ', X, ',', Y, ' buttons ', Btn);
  end;

  WriteLn;
  WriteLn(Checks - Fails, '/', Checks, ' checks passed.');
  if Fails > 20 then Fails := 20;
  Halt(Fails);
end.
