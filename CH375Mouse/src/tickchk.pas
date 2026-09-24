program tickchk;
{ INT 08h chain-rate check  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  USBMOUSE speeds the PIT up by eight so it can poll the mouse at 145 Hz,
  and forwards only every eighth interrupt to the handler that was in the
  vector when it installed.  That keeps the BIOS tick, and everything that
  hooked INT 08h BEFORE the driver, at the 18.2 Hz they expect.

  Anything that hooks INT 08h AFTER the driver is a different matter: it
  sits above us in the chain and sees every interrupt, all 145 of them a
  second.  Windows is exactly that case -- it has to be started after the
  driver is loaded -- and a Windows whose tick runs eight times fast has a
  double-click window eight times too short, which looks precisely like
  "clicks work, double-clicks do not".

  This installs an INT 08h handler the same way Windows would, counts what
  arrives over a fixed stretch of DOS clock, and reports the rate.

  INT 1Ch is measured alongside it, because that one is different: the BIOS
  INT 08h handler is what issues INT 1Ch, and the driver calls the BIOS
  handler only every eighth interrupt -- so anything hooking INT 1Ch already
  sees the correct rate.  Which of the two a program uses decides whether the
  driver's timer multiplication is visible to it at all.

      TICKCHK [seconds]        default 10

  Run it with and without the driver loaded.  Both should say about 18.  }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses Dos, chtool;

const
  VER = '1.0.0';

var
  Count: Word;
  Count1C: Word;

  { push ds / push ax / mov ax,DSEG / mov ds,ax / inc [Count]
    pop ax / pop ds / jmp far old                                        }
  Hook: array[0..17] of Byte = (
    $1E, $50,
    $B8, $00, $00,                { +3  mov ax, seg Count   (patched)     }
    $8E, $D8,
    $FF, $06, $00, $00,           { +9  inc word [Count]    (patched)     }
    $58, $1F,
    $EA, $00, $00, $00, $00);     { +14 jmp far off:seg     (patched)     }

  Hook1C: array[0..17] of Byte = (
    $1E, $50,
    $B8, $00, $00,
    $8E, $D8,
    $FF, $06, $00, $00,
    $58, $1F,
    $EA, $00, $00, $00, $00);

function Now100: LongInt;
var H, Mi, S, C: Word;
begin
  GetTime(H, Mi, S, C);
  Now100 := LongInt(H) * 360000 + LongInt(Mi) * 6000 + LongInt(S) * 100 + C;
end;

var
  Old, Old1C: Pointer;
  N, Code: Integer;
  Got1C: Word;
  Rate1C: LongInt;
  T0, T1, Elapsed: LongInt;
  Got: Word;
  Rate: LongInt;
  R: Registers;

procedure Usage;
begin
  Banner('TICKCHK', VER, 'INT 08h chain-rate check');
  WriteLn;
  WriteLn('  TICKCHK [seconds]');
  WriteLn;
  WriteLn('  seconds  how long to measure, default 10');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Run it with and without the driver loaded.  Both should say');
  WriteLn('about 18.');
  WriteLn;
  WriteLn('USBMOUSE speeds the PIT up so it can poll the mouse fast, and');
  WriteLn('forwards only every nth interrupt to whatever was in the vector');
  WriteLn('when it installed.  That keeps the BIOS tick, and everything');
  WriteLn('that hooked INT 08h BEFORE the driver, at the 18.2 Hz they');
  WriteLn('expect.');
  WriteLn;
  WriteLn('Anything hooking INT 08h AFTER the driver is a different');
  WriteLn('matter: it sits above us in the chain and sees every interrupt.');
  WriteLn('Windows is exactly that case -- it has to be started after the');
  WriteLn('driver -- and a Windows whose tick runs eight times fast has a');
  WriteLn('double-click window eight times too short, which looks exactly');
  WriteLn('like "clicks work, double-clicks do not".');
  WriteLn;
  WriteLn('INT 1Ch is measured alongside it, because that one is');
  WriteLn('different: the BIOS INT 08h handler is what issues INT 1Ch, and');
  WriteLn('the driver calls the BIOS handler only every nth interrupt -- so');
  WriteLn('anything hooking INT 1Ch already sees the correct rate.  Which');
  WriteLn('of the two a program uses decides whether the driver''s timer');
  WriteLn('multiplication is visible to it at all.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  N := 10;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), N, Code);
    if (Code <> 0) or (N < 2) or (N > 60) then N := 10;
  end;

  Banner('TICKCHK', VER, 'INT 08h chain rate');
  R.AX := 0;
  Intr($33, R);
  if R.AX = $FFFF then
  begin
    R.AX := $7F00;
    Intr($33, R);
    WriteLn('an INT 33h driver is loaded (USB state ', R.BX, ')');
  end
  else
    WriteLn('no INT 33h driver loaded');

  GetIntVec($08, Old);
  WriteLn('INT 08h currently ', HexStr(Seg(Old^), 4), ':', HexStr(Ofs(Old^), 4));

  Hook[3]  := Lo(Seg(Count));   Hook[4]  := Hi(Seg(Count));
  Hook[9]  := Lo(Ofs(Count));   Hook[10] := Hi(Ofs(Count));
  Hook[14] := Lo(Ofs(Old^));    Hook[15] := Hi(Ofs(Old^));
  Hook[16] := Lo(Seg(Old^));    Hook[17] := Hi(Seg(Old^));

  GetIntVec($1C, Old1C);
  Hook1C[3]  := Lo(Seg(Count1C)); Hook1C[4]  := Hi(Seg(Count1C));
  Hook1C[9]  := Lo(Ofs(Count1C)); Hook1C[10] := Hi(Ofs(Count1C));
  Hook1C[14] := Lo(Ofs(Old1C^));  Hook1C[15] := Hi(Ofs(Old1C^));
  Hook1C[16] := Lo(Seg(Old1C^));  Hook1C[17] := Hi(Seg(Old1C^));

  Count := 0; Count1C := 0;
  SetIntVec($1C, Ptr(Seg(Hook1C), Ofs(Hook1C)));
  SetIntVec($08, Ptr(Seg(Hook), Ofs(Hook)));

  T0 := Now100;
  repeat T1 := Now100 until (T1 - T0) >= LongInt(N) * 100;
  Got := Count;
  Got1C := Count1C;
  Elapsed := T1 - T0;

  SetIntVec($08, Old);
  SetIntVec($1C, Old1C);

  Rate   := (LongInt(Got)   * 100) div Elapsed;
  Rate1C := (LongInt(Got1C) * 100) div Elapsed;
  WriteLn;
  WriteLn('over        : ', Elapsed div 100, '.', Elapsed mod 100, ' s');
  WriteLn('INT 08h     : ', Got, ' interrupts, ', Rate, ' Hz');
  WriteLn('INT 1Ch     : ', Got1C, ' interrupts, ', Rate1C, ' Hz');
  WriteLn;
  if (Rate >= 16) and (Rate <= 21) then
    WriteLn('INT 08h is normal: hooking after the driver is safe.')
  else
    WriteLn('INT 08h runs fast.  Anything hooking it after the driver runs',
            ' its timers this much too fast.');
  if (Rate1C >= 16) and (Rate1C <= 21) then
    WriteLn('INT 1Ch is normal: programs using the BIOS user tick are fine.')
  else
    WriteLn('INT 1Ch runs fast too.');
  if (Rate >= 16) and (Rate <= 21) then Halt(0) else Halt(1);
end.
