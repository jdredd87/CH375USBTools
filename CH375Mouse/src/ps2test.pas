program ps2test;
{ PS/2 BIOS mouse emulation test  --  CH375Mouse, StevenC
  Public domain (the Unlicense); see LICENSE.

  USBMOUSE /W makes the USB mouse look like a PS/2 pointing device to the
  BIOS interface, which is the only thing Windows 3.x understands.  This
  makes exactly the calls the Windows 3.0 MOUSE.DRV on this machine makes,
  in the same order, and checks the answers -- so the emulation can be
  proved without starting Windows, which on this box cannot be exited
  remotely.

  Taken from a disassembly of that driver:

      INT 15h AH=C0h   configuration table, model byte must be F8/FA/FC
      INT 11h          bit 2 set, "pointing device installed"
      INT 15h AX=C205h BH=3     initialise, 3-byte packets
              AX=C201h          reset
              AX=C203h BH=3     resolution
              AX=C207h ES:BX    set the callback
              AX=C206h BH=1     scaling 1:1
              AX=C202h BH=2     sample rate
              AX=C200h BH=1     enable

  The callback is hand-assembled into a byte array rather than written as a
  Pascal procedure, because the frame it is entered with is the BIOS's, not
  any calling convention the compiler knows: the caller pushes status, X, Y
  and Z and cleans up afterwards.

      PS2TEST [seconds]     watch for real packets, default 8               }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses Dos, chtool;

const
  VER = '1.0.0';

var
  Fails, Checks: Integer;

  { written by the callback, read by the test }
  P2Status, P2X, P2Y: Byte;
  P2Count: Word;

  { push bp / mov bp,sp / push ds / push ax / mov ax,DSEG / mov ds,ax
    mov al,[bp+0Ch] -> status ; [bp+0Ah] -> X ; [bp+08] -> Y
    inc P2Count / pop ax / pop ds / pop bp / retf                          }
  Handler: array[0..35] of Byte = (
    $55, $8B, $EC,                { push bp / mov bp,sp                     }
    $1E, $50,                     { push ds / push ax                       }
    $B8, $00, $00,                { +6  mov ax, seg data      (patched)     }
    $8E, $D8,                     { mov ds,ax                               }
    $8A, $46, $0C,                { mov al,[bp+0Ch]  status                 }
    $A2, $00, $00,                { +14 mov [P2Status],al     (patched)     }
    $8A, $46, $0A,                { mov al,[bp+0Ah]  X                      }
    $A2, $00, $00,                { +20 mov [P2X],al          (patched)     }
    $8A, $46, $08,                { mov al,[bp+08h]  Y                      }
    $A2, $00, $00,                { +26 mov [P2Y],al          (patched)     }
    $FF, $06, $00, $00,           { +30 inc word [P2Count]    (patched)     }
    $58, $1F, $5D,                { pop ax / pop ds / pop bp                }
    $CB);                         { retf -- the caller cleans the args up   }

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

function Hex1(B: Byte): Char;
begin
  if B < 10 then Hex1 := Chr(Ord('0') + B) else Hex1 := Chr(Ord('A') + B - 10);
end;

function Hex2(B: Byte): ShortString;
begin
  Hex2 := Hex1(B shr 4) + Hex1(B and 15);
end;

procedure M33(var R: Registers);
begin
  Intr($33, R);
end;

{ One INT 15h AH=C2h call.  Returns True on CF clear with AH = 0. }
function C2(Sub, BHv: Byte): Boolean;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $C2;
  R.AL := Sub;
  R.BH := BHv;
  Intr($15, R);
  C2 := ((R.Flags and 1) = 0) and (R.AH = 0);
end;

{ ---------------------------------------------------------------------
  HAND THE CALLBACK BACK EVEN IF WE DIE.

  This test registers a far callback that lives in ITS OWN memory, and
  tells the driver to start calling it.  The cleanup at the end of the
  program undoes both -- and a program that crashes never reaches its end.

  What that costs is not a leaked handle.  The driver goes on calling the
  address on every mouse report, into memory DOS has since handed to
  whatever ran next, so the crash is inherited by an innocent program and
  the machine wedges.  That happened repeatedly while chasing an unrelated
  fault, and each time it cost a power cycle and read as a NEW bug.

  An exit handler runs on a runtime error too, which is the whole point.
  --------------------------------------------------------------------- }
var
  PrevExit: Pointer;

procedure Ps2Release; far;
var R: Registers;
begin
  ExitProc := PrevExit;
  FillChar(R, SizeOf(R), 0);            { C200h BH=0: stop reporting }
  R.AH := $C2; R.AL := $00; R.BH := 0;
  Intr($15, R);
  FillChar(R, SizeOf(R), 0);            { C207h 0000:0000: forget us }
  R.AH := $C2; R.AL := $07; R.ES := 0; R.BX := 0;
  Intr($15, R);
end;

procedure Inject(Btn: Byte; Dx, Dy: Integer);
var R: Registers;
begin
  R.AX := $7F01;
  R.BX := Btn;
  R.CX := (Word(Dy and $FF) shl 8) or Word(Dx and $FF);
  M33(R);
end;

procedure PausePoll(Off: Word);
var R: Registers;
begin
  R.AX := $7F02;
  R.BX := Off;
  M33(R);
end;

function Now100: LongInt;
var H, Mi, S, C: Word;
begin
  GetTime(H, Mi, S, C);
  Now100 := LongInt(H) * 360000 + LongInt(Mi) * 6000 + LongInt(S) * 100 + C;
end;

var
  R: Registers;
  Model, Equip: Word;
  N, Code, I: Integer;
  T0: LongInt;
  Before, RepBefore: Word;

procedure Usage;
begin
  Banner('PS2TEST', VER, 'PS/2 BIOS mouse emulation test');
  WriteLn;
  WriteLn('  PS2TEST [seconds]');
  WriteLn;
  WriteLn('  seconds  how long to watch for real packets, default 8');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Needs USBMOUSE /W or USBCOMBO /W loaded.  /W makes the USB');
  WriteLn('mouse look like a PS/2 pointing device to the BIOS interface,');
  WriteLn('which is the only thing Windows 3.x understands.  This makes');
  WriteLn('exactly the calls the Windows 3.0 MOUSE.DRV makes, in the same');
  WriteLn('order, and checks the answers -- so the emulation can be proved');
  WriteLn('without starting Windows, which on this machine cannot be');
  WriteLn('exited remotely.');
  WriteLn;
  WriteLn('Taken from a disassembly of that driver:');
  WriteLn('  INT 15h AH=C0h   configuration table, model F8/FA/FC');
  WriteLn('  INT 11h          bit 2 set, "pointing device installed"');
  WriteLn('  INT 15h AX=C205h BH=3   initialise, 3-byte packets');
  WriteLn('          AX=C201h        reset');
  WriteLn('          AX=C203h BH=3   resolution');
  WriteLn('          AX=C207h ES:BX  set the callback');
  WriteLn('          AX=C206h BH=1   scaling 1:1');
  WriteLn('          AX=C202h BH=2   sample rate');
  WriteLn('          AX=C200h BH=1   enable');
  WriteLn;
  WriteLn('It reaches the driver through the BIOS, never the card, so');
  WriteLn('there is no I/O base to set here.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Fails := 0; Checks := 0;
  N := 8;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), N, Code);
    if (Code <> 0) or (N < 1) or (N > 60) then N := 8;
  end;

  Banner('PS2TEST', VER, 'USBMOUSE PS/2 BIOS emulation test');
  R.AX := 0; M33(R);
  if R.AX <> $FFFF then
  begin
    WriteLn('No INT 33h driver.  Load USBMOUSE /W first.');
    Halt(20);
  end;
  R.AX := $7F00; M33(R);
  WriteLn('USBMOUSE state ', R.BX, ', endpoint ', Lo(R.CX));

  { ---- what MOUSE.DRV probes before it believes anything ---- }
  WriteLn;
  WriteLn('the probe Windows 3.0 MOUSE.DRV performs');
  FillChar(R, SizeOf(R), 0);
  R.AH := $C0;
  Intr($15, R);
  Check('INT 15h AH=C0h returns a configuration table', (R.Flags and 1) = 0);
  if (R.Flags and 1) = 0 then
  begin
    Model := Mem[R.ES : R.BX + 2];
    WriteLn('  model byte = ', Hex2(Byte(Model)));
    Check('model is a PS/2 class the driver accepts (F8/FA/FC)',
          (Model = $F8) or (Model = $FA) or (Model = $FC));
  end;

  { Armed BEFORE anything is registered, so there is no window in which a
    crash could leave the driver calling us. }
  PrevExit := ExitProc;
  ExitProc := @Ps2Release;

  Equip := 0;
  asm
    int 11h
    mov Equip, ax
  end;
  WriteLn('  INT 11h equipment word = ', Hex2(Hi(Equip)), Hex2(Lo(Equip)));
  Check('bit 2 set: pointing device installed', (Equip and 4) <> 0);

  { ---- register the callback ---- }
  Handler[6]  := Lo(Seg(P2Status));  Handler[7]  := Hi(Seg(P2Status));
  Handler[14] := Lo(Ofs(P2Status));  Handler[15] := Hi(Ofs(P2Status));
  Handler[20] := Lo(Ofs(P2X));       Handler[21] := Hi(Ofs(P2X));
  Handler[26] := Lo(Ofs(P2Y));       Handler[27] := Hi(Ofs(P2Y));
  Handler[30] := Lo(Ofs(P2Count));   Handler[31] := Hi(Ofs(P2Count));

  WriteLn;
  WriteLn('the enable sequence, in MOUSE.DRV''s order');
  Check('C205h initialise, 3-byte packets', C2($05, 3));
  Check('C201h reset',                      C2($01, 0));
  Check('C203h set resolution',             C2($03, 3));

  FillChar(R, SizeOf(R), 0);
  R.AH := $C2; R.AL := $07;
  R.ES := Seg(Handler); R.BX := Ofs(Handler);
  Intr($15, R);
  Check('C207h set callback address', ((R.Flags and 1) = 0) and (R.AH = 0));

  Check('C206h scaling 1:1',                C2($06, 1));
  Check('C202h set sample rate',            C2($02, 2));
  Check('C200h enable',                     C2($00, 1));

  { ---- exact packets, driven by injection ---- }
  WriteLn;
  WriteLn('packet delivery');
  PausePoll(1);
  P2Count := 0;
  Inject(0, 5, 0);
  CheckEq('a report produces one callback', P2Count, 1);
  CheckEq('  status: bit 3 set, no buttons', P2Status, $08);
  CheckEq('  X passed through', P2X, 5);
  CheckEq('  Y is zero', P2Y, 0);

  P2Count := 0;
  Inject(0, 0, 3);
  CheckEq('  Y is inverted: USB counts down, PS/2 counts up',
          Integer(ShortInt(P2Y)), -3);
  CheckEq('  and the Y sign bit is set', P2Status and $20, $20);

  P2Count := 0;
  Inject(0, -4, 0);
  CheckEq('  negative X', Integer(ShortInt(P2X)), -4);
  CheckEq('  and the X sign bit is set', P2Status and $10, $10);

  P2Count := 0;
  Inject(1, 0, 0);
  CheckEq('  left button in bit 0', P2Status and 7, 1);
  Inject(2, 0, 0);
  CheckEq('  right button in bit 1', P2Status and 7, 2);
  Inject(4, 0, 0);
  CheckEq('  middle button in bit 2', P2Status and 7, 4);
  Inject(0, 0, 0);

  { ---- disabling really stops it ---- }
  Check('C200h disable', C2($00, 0));
  P2Count := 0;
  Inject(0, 9, 9);
  CheckEq('no callbacks once disabled', P2Count, 0);
  Check('C200h re-enable', C2($00, 1));

  { ---- real packets from the mouse ---- }
  PausePoll(0);
  WriteLn;
  WriteLn('watching for real PS/2 packets for ', N, ' seconds');
  Before := P2Count;
  R.AX := $7F00; M33(R);
  RepBefore := R.DX;
  T0 := Now100;
  repeat until (Now100 - T0) >= LongInt(N) * 100;
  R.AX := $7F00; M33(R);
  WriteLn('  packets delivered: ', P2Count - Before);
  WriteLn('  last: status ', Hex2(P2Status), '  X ', Integer(ShortInt(P2X)),
          '  Y ', Integer(ShortInt(P2Y)));
  { Only assert this if the mouse actually moved.  A stationary mouse sends
    nothing at all, so demanding packets here would make the suite fail for
    want of a hand on the desk rather than for want of working code. }
  if R.DX <> RepBefore then
    Check('the real mouse produces PS/2 packets', P2Count <> Before)
  else
    WriteLn('  (mouse idle -- nothing to deliver, so nothing asserted)');

  { ---- put it back ---- }
  C2($00, 0);
  FillChar(R, SizeOf(R), 0);
  R.AH := $C2; R.AL := $07; R.ES := 0; R.BX := 0;
  Intr($15, R);

  WriteLn;
  WriteLn(Checks - Fails, '/', Checks, ' checks passed.');
  if Fails > 20 then Fails := 20;
  Halt(Fails);
end.
