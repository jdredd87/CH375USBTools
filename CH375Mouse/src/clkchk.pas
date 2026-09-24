program clkchk;
{ DOS clock check  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  USBMOUSE divides the PIT by eight so it can poll the mouse at 145 Hz, and
  forwards every eighth tick to the original INT 08h.  If that arithmetic
  were wrong the DOS clock would run eight times fast or eight times slow,
  and nothing else in the driver would look any different.

  So: wait until the DOS clock says N seconds have passed, and let the
  caller time the run from outside.  Real elapsed time equal to N means the
  chain is intact; N/8 or 8N means it is not.

      CLKCHK [seconds]        default 20                                  }

{$MODE OBJFPC}{$H-}

uses Dos, chtool;

const
  VER = '1.0.0';

function Now100: LongInt;
var H, M, S, C: Word;
begin
  GetTime(H, M, S, C);
  Now100 := LongInt(H) * 360000 + LongInt(M) * 6000 + LongInt(S) * 100 + C;
end;

var
  T0, T1, Want: LongInt;
  N, Code: Integer;
  H, M, S, C: Word;

procedure Usage;
begin
  Banner('CLKCHK', VER, 'DOS clock check');
  WriteLn;
  WriteLn('  CLKCHK [seconds]');
  WriteLn;
  WriteLn('  seconds  how long to wait for, default 20');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('USBMOUSE divides the PIT so it can poll the mouse fast, and');
  WriteLn('forwards every nth tick to the original INT 08h.  If that');
  WriteLn('arithmetic were wrong the DOS clock would run fast or slow and');
  WriteLn('nothing else in the driver would look any different.');
  WriteLn;
  WriteLn('So: wait until the DOS clock says N seconds have passed, and');
  WriteLn('let the caller time the run from outside.  Real elapsed time');
  WriteLn('equal to N means the chain is intact; N/8 or 8N means it is');
  WriteLn('not.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Banner('CLKCHK', VER, 'DOS clock check');
  N := 20;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), N, Code);
    if (Code <> 0) or (N < 1) or (N > 120) then N := 20;
  end;
  Want := LongInt(N) * 100;

  GetTime(H, M, S, C);
  WriteLn('DOS clock now ', H, ':', M, ':', S, '.', C);
  WriteLn('waiting for the DOS clock to advance ', N, ' seconds');
  T0 := Now100;
  repeat
    T1 := Now100;
    if T1 < T0 then T0 := T1;          { midnight rollover }
  until (T1 - T0) >= Want;
  GetTime(H, M, S, C);
  WriteLn('DOS clock now ', H, ':', M, ':', S, '.', C);
  WriteLn('DOS says ', (T1 - T0) div 100, '.', (T1 - T0) mod 100,
          ' seconds elapsed');
  Halt(0);
end.
