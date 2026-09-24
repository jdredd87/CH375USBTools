program mousedemo;
{ Live INT 33h mouse demo  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  Shows the text-mode cursor and then sits reading the mouse, so the pointer
  can be watched moving on the real screen through the capture card while
  the jiggler pushes it around.  The numbers come back over the bridge; the
  cursor itself only exists in video memory, so seeing it is the one part
  that needs a photograph.

      MOUSEDEMO [seconds]        default 25                                }

{$MODE OBJFPC}{$H-}

uses Dos, chtool;

const
  VER = '1.0.0';

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

var
  R: Registers;
  T0, T1, Last: LongInt;
  N, Code: Integer;
  Rep0, Rep1: Word;

procedure Usage;
begin
  Banner('MDEMO', VER, 'live INT 33h mouse demo');
  WriteLn;
  WriteLn('  MDEMO [seconds]');
  WriteLn;
  WriteLn('  seconds  how long to run, default 25');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Needs USBMOUSE or USBCOMBO loaded.  Shows the text-mode cursor');
  WriteLn('and then sits reading the mouse, so the pointer can be watched');
  WriteLn('moving on the real screen.  The numbers come back over the');
  WriteLn('bridge; the cursor itself only exists in video memory, so');
  WriteLn('seeing it is the one part that needs a photograph.');
  WriteLn;
  WriteLn('There is no pointer at the DOS prompt otherwise -- only a');
  WriteLn('program that asks for one gets one, which is why a mouse that');
  WriteLn('seems dead at the prompt is usually working.  This is the');
  WriteLn('quickest program to ask.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Banner('MDEMO', VER, 'live INT 33h mouse demo');
  N := 25;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), N, Code);
    if (Code <> 0) or (N < 1) or (N > 120) then N := 25;
  end;

  R.AX := 0; M(R);
  if R.AX <> $FFFF then
  begin
    WriteLn('No INT 33h driver.  Load USBMOUSE first.');
    Halt(1);
  end;
  R.AX := $7F00; M(R);
  Rep0 := R.DX;
  WriteLn('USBMOUSE live, state ', R.BX, ', endpoint ', Lo(R.CX));

  { A 25x80 text screen in the standard 640x200 virtual space }
  R.AX := 7; R.CX := 0; R.DX := 639; M(R);
  R.AX := 8; R.CX := 0; R.DX := 199; M(R);
  R.AX := 4; R.CX := 320; R.DX := 100; M(R);
  R.AX := 1; M(R);                            { show the cursor }

  WriteLn('cursor shown; move the mouse.  ', N, ' seconds.');
  T0 := Now100;
  Last := -1;
  repeat
    R.AX := 3; M(R);
    T1 := Now100;
    if T1 < T0 then T0 := T1;
    if (T1 - T0) div 100 <> Last then
    begin
      Last := (T1 - T0) div 100;
      WriteLn('  t=', Last, 's  x=', R.CX, ' y=', R.DX,
              '  col=', R.CX div 8, ' row=', R.DX div 8,
              '  buttons=', R.BX);
    end;
  until (T1 - T0) >= LongInt(N) * 100;

  R.AX := 2; M(R);                            { hide it again }
  R.AX := $7F00; M(R);
  Rep1 := R.DX;
  WriteLn('reports received during the demo: ', Rep1 - Rep0);
  if Rep1 = Rep0 then Halt(5);
  Halt(0);
end.
