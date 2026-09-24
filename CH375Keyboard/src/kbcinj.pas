program kbcinj;
{ KBCINJ -- prove 8042 command D2h works on this machine.
  CH375Keyboard, StevenC & Claude.  Public domain (the Unlicense).

  `USBKBD /K` delivers keys by handing scancodes to the keyboard controller
  with command D2h, so they arrive as real IRQ1 interrupts and are
  indistinguishable from a keyboard's own. That is the only way to reach a
  program that hooks INT 09h -- DOS EDIT's menus, and most games.

  It also needs an AT-class 8042. An XT-class controller has no D2h, and
  writing it there can leave the controller confused with no keyboard at
  all until the machine is power-cycled. So before trusting /K it is worth
  ten seconds proving the mechanism, which is all this does: inject a known
  scancode, then see whether INT 16h hands back the character the BIOS
  should have made of it.

  No CH375, no USB keyboard and no driver are needed, and nothing is left
  resident.

    KBCINJ [/Q]

      /Q   only the verdict

  Exit codes: 0 injection works, 1 no controller answers,
              2 the controller took the byte but nothing came back,
              3 something came back but not what was injected }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses chtool;

const
  VER    = '1.0.0';
  SCAN_A = $1E;         { the 'a' key -- make code }
  WANT   = $1E61;       { what INT 16h should return for it }

var
  Quiet: Boolean = False;

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

function KeyReady: Boolean; assembler;
asm
  mov ah, 1
  int 16h
  mov al, 0
  jz  @none
  mov al, 1
@none:
end;

function GetKey: Word; assembler;
asm
  mov ah, 0
  int 16h
end;

function Ticks: LongInt;
var P: ^LongInt;
begin
  P := Ptr($40, $6C); Ticks := P^;
end;

function Hex2(B: Byte): ShortString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4] + H[B and 15];
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := Hex2(Hi(W)) + Hex2(Lo(W));
end;

procedure Say(const S: ShortString);
begin
  if not Quiet then WriteLn(S);
end;

{ Wait for the 8042's input buffer to drain. Bounded, because a controller
  that has stopped answering must not become a hang. }
function KbcReady: Boolean;
var I: Word; V: Byte;
begin
  KbcReady := False;
  for I := 1 to 20000 do
  begin
    V := InB($64);
    if V = $FF then Exit;              { nothing there at all }
    if (V and $02) = 0 then begin KbcReady := True; Exit; end;
  end;
end;

function Inject(B: Byte): Boolean;
begin
  Inject := False;
  if not KbcReady then Exit;
  OutB($64, $D2);                      { write to the output buffer }
  if not KbcReady then Exit;
  OutB($60, B);
  Inject := True;
end;

var
  I, Code: Integer;
  A: ShortString;
  St: Byte;
  W: Word;
  T0: LongInt;
  Got: Boolean;
  N: Integer;

procedure Usage;
begin
  Banner('KBCINJ', VER, 'prove 8042 command D2h works on this machine');
  WriteLn;
  WriteLn('  KBCINJ [/Q]');
  WriteLn;
  WriteLn('  /Q       only the verdict');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('USBKBD /K and USBCOMBO /K deliver keys by handing scancodes to');
  WriteLn('the keyboard controller with command D2h, so they arrive as');
  WriteLn('real IRQ1 interrupts.  That is the only way to reach a program');
  WriteLn('that hooks INT 09h -- DOS EDIT''s menus, and most games.');
  WriteLn;
  WriteLn('It needs an AT-class 8042.  An XT-class machine has no D2h, and');
  WriteLn('writing it there can leave the controller confused with no');
  WriteLn('keyboard at all until the machine is power-cycled.  So before');
  WriteLn('trusting /K it is worth ten seconds proving the mechanism,');
  WriteLn('which is all this does: inject a known scancode, then see');
  WriteLn('whether INT 16h hands back the character the BIOS made of it.');
  WriteLn;
  WriteLn('No CH375, no USB keyboard and no driver are needed, so there is');
  WriteLn('no I/O base to set.  Nothing is left resident.');
  WriteLn;
  WriteLn('Exit: 0 injection works, 1 no controller answers, 2 the');
  WriteLn('      controller took the byte but nothing came back,');
  WriteLn('      3 something came back but not what was injected');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/Q') or (A = '-Q') then Quiet := True;
  end;

  if not Quiet then Banner('KBCINJ', VER, 'does 8042 command D2h work here?');
  Say('');

  St := InB($64);
  Say('port 64h status = ' + Hex2(St));
  if St = $FF then
  begin
    WriteLn('No keyboard controller answers port 64h.');
    WriteLn('USBKBD /K cannot work on this machine; the BIOS-buffer mode');
    WriteLn('(the default) is the one to use.');
    Halt(1);
  end;
  Say('        bit0 output buffer full = ' + Hex2(St and 1));
  Say('        bit1 input buffer full  = ' + Hex2((St shr 1) and 1));
  Say('');

  { Drain anything already pending, so what we read back is ours. }
  N := 0;
  while KeyReady and (N < 32) do begin GetKey; Inc(N); end;
  if N > 0 then Say('drained ' + Hex2(Byte(N)) + ' pending keystroke(s)');

  Say('injecting scancode ' + Hex2(SCAN_A) + ' (the "a" key), make then break');
  if not Inject(SCAN_A) then
  begin
    WriteLn('The controller would not accept the make code.');
    Halt(1);
  end;
  { The break code matters: without it the BIOS believes the key is still
    held, and on a real keyboard that is what starts typematic repeat. }
  Inject(SCAN_A or $80);

  Got := False; W := 0;
  T0 := Ticks;
  while Ticks - T0 < 36 do               { about two seconds }
    if KeyReady then
    begin
      W := GetKey;
      Got := True;
      Break;
    end;

  Say('');
  if not Got then
  begin
    WriteLn('The controller took the byte, but INT 16h never produced a key.');
    WriteLn('Either IRQ1 is masked or this controller ignores D2h.');
    WriteLn('USBKBD /K will not work here; use the default mode.');
    Halt(2);
  end;

  Say('INT 16h returned ' + Hex4(W) + ', wanted ' + Hex4(WANT));
  if W <> WANT then
  begin
    WriteLn('Injection works, but the result was ', Hex4(W),
            ' rather than ', Hex4(WANT), '.');
    WriteLn('The mechanism is fine; something is translating differently');
    WriteLn('(a keyboard in the wrong scancode set, or a resident driver');
    WriteLn('in the way).  USBKBD /K is worth trying anyway.');
    Halt(3);
  end;

  WriteLn('8042 D2h injection works: an injected scancode came back');
  WriteLn('through INT 16h as the right character.  USBKBD /K will work');
  WriteLn('on this machine.');
  Halt(0);
end.
