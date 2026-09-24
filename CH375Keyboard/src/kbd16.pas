program kbd16;
{ KBD16 -- which INT 16h functions does this BIOS actually implement?
  CH375Keyboard, StevenC & Claude.  Public domain (the Unlicense).

  There are two generations of INT 16h. The original PC/XT BIOS has AH=00h
  (read), 01h (peek) and 02h (shift state). The AT-and-later "enhanced
  keyboard" BIOS adds AH=10h, 11h and 12h, which do the same three jobs but
  can report the keys a 101-key keyboard has and an 83-key one has not.

  Software written after about 1986 often prefers the enhanced calls. A
  program that reads ordinary typing through AH=00h/01h but drives its menu
  bar through AH=10h/11h would, on a BIOS that lacks the second set, be a
  program you can type into whose menus ignore you -- and that would look
  for all the world like a keyboard driver fault.

  This was written to test that theory against a real machine while chasing
  exactly that symptom in DOS EDIT. On the machine in question the answer
  came back "both sets work", so the theory was wrong and the tool stayed:
  it is two minutes of certainty about a thing that is otherwise pure
  supposition, and the next machine may well answer differently.

  The test does not need a keyboard. A word is written straight into the
  BIOS keyboard buffer, the way a keyboard interrupt would, and then each
  function is asked whether it can see it.

    KBD16

  Exit codes: 0 the enhanced calls work, 1 they do not, 2 not even the
              legacy calls work (which would mean the buffer write failed) }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses chtool;

const
  VER      = '1.0.0';
  PROBEKEY = $1E61;        { the 'a' key: scancode 1E, ascii 61 }

function PeekW(Seg, Ofs: Word): Word;
var P: ^Word;
begin
  P := Ptr(Seg, Ofs); PeekW := P^;
end;

procedure PokeW(Seg, Ofs, V: Word);
var P: ^Word;
begin
  P := Ptr(Seg, Ofs); P^ := V;
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

{ ---- the six functions, each called exactly as software would ---- }

function Peek01(var Got: Word): Boolean; assembler;
asm
  mov ah, 1
  int 16h
  jz  @none
  les di, Got
  mov es:[di], ax
  mov al, 1
  jmp @out
@none:
  mov al, 0
@out:
end;

function Peek11(var Got: Word): Boolean; assembler;
asm
  mov ah, 11h
  int 16h
  jz  @none
  les di, Got
  mov es:[di], ax
  mov al, 1
  jmp @out
@none:
  mov al, 0
@out:
end;

function Read00: Word; assembler;
asm
  mov ah, 0
  int 16h
end;

function Read10: Word; assembler;
asm
  mov ah, 10h
  int 16h
end;

function Shift02: Byte; assembler;
asm
  mov ah, 2
  int 16h
end;

function Shift12: Word; assembler;
asm
  mov ah, 12h
  int 16h
end;

{ Put one word in the BIOS buffer, exactly as a keyboard interrupt does. }
function Stuff(W: Word): Boolean;
var Head, Tail, Nxt, BStart, BEnd: Word;
begin
  Head   := PeekW($40, $1A);
  Tail   := PeekW($40, $1C);
  BStart := PeekW($40, $80);
  BEnd   := PeekW($40, $82);
  Nxt := Tail + 2;
  if Nxt >= BEnd then Nxt := BStart;
  if Nxt = Head then begin Stuff := False; Exit; end;
  PokeW($40, Tail, W);
  PokeW($40, $1C, Nxt);
  Stuff := True;
end;

procedure Drain;
var N: Integer; G: Word;
begin
  N := 0;
  while Peek01(G) and (N < 32) do begin Read00; Inc(N); end;
end;

{ ----------------------------------------------------------------------
  What the BIOS hands back for a given buffer word.

  This is the part that matters and the first version did not do: it tested
  one plain character. A keyboard driver writes ARROW keys into the buffer
  too, and the read path is entitled to translate -- AH=00h is specified to
  fold the enhanced-only encodings away, and a BIOS with "force NumLock"
  behaviour can rewrite the keypad. If an arrow comes back as something
  other than what went in, every menu in DOS is unreachable and the driver
  is blameless.
  ---------------------------------------------------------------------- }

procedure Probe(const Name: ShortString; W: Word);
var G, R00, R10: Word; P01, P11: Boolean; S: ShortString;
begin
  Drain;
  if not Stuff(W) then begin WriteLn('  ', Name, ': buffer full'); Exit; end;
  P01 := Peek01(G);
  R00 := Read00;
  Drain;
  Stuff(W);
  P11 := Peek11(G);
  R10 := Read10;
  Drain;
  S := '  ' + Name;
  while Length(S) < 12 do S := S + ' ';
  S := S + 'in ' + Hex4(W) + '   AH=00h -> ' + Hex4(R00) +
       '   AH=10h -> ' + Hex4(R10);
  if (R00 <> W) or (R10 <> W) then S := S + '   *** CHANGED';
  WriteLn(S);
  if not (P01 and P11) then
    WriteLn('              (a peek said no key was waiting)');
end;

var
  G: Word;
  Ok01, Ok11: Boolean;
  R00, R10: Word;
  Legacy, Enhanced: Boolean;

procedure Usage;
begin
  Banner('KBD16', VER, 'which INT 16h calls does this BIOS have?');
  WriteLn;
  WriteLn('  KBD16');
  WriteLn;
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('It takes no other switches, and needs no keyboard and no card.');
  WriteLn;
  WriteLn('There are two generations of INT 16h.  The original PC/XT BIOS');
  WriteLn('has AH=00h (read), 01h (peek) and 02h (shift state).  The AT');
  WriteLn('and later "enhanced keyboard" BIOS adds AH=10h, 11h and 12h,');
  WriteLn('which do the same three jobs but can report the keys a 101-key');
  WriteLn('keyboard has and an 83-key one has not.');
  WriteLn;
  WriteLn('Software written after about 1986 often prefers the enhanced');
  WriteLn('calls.  A program reading ordinary typing through AH=00h but');
  WriteLn('driving its menu bar through AH=10h would, on a BIOS lacking');
  WriteLn('the second set, be a program you can type into whose menus');
  WriteLn('ignore you -- which looks exactly like a driver fault.');
  WriteLn;
  WriteLn('A word is written straight into the BIOS keyboard buffer, the');
  WriteLn('way a keyboard interrupt would, and each function is then asked');
  WriteLn('whether it can see it.');
  WriteLn;
  WriteLn('Exit: 0 the enhanced calls work, 1 they do not, 2 not even the');
  WriteLn('      legacy calls work (the buffer write itself failed)');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Banner('KBD16', VER, 'which INT 16h calls does this BIOS have?');
  WriteLn;

  Drain;
  WriteLn('buffer start=', Hex4(PeekW($40, $80)),
          ' end=', Hex4(PeekW($40, $82)),
          ' head=', Hex4(PeekW($40, $1A)),
          ' tail=', Hex4(PeekW($40, $1C)));
  WriteLn;

  { ---- the legacy peek ---- }
  if not Stuff(PROBEKEY) then
  begin
    WriteLn('Could not write the BIOS keyboard buffer at all.');
    Halt(2);
  end;
  Ok01 := Peek01(G);
  WriteLn('AH=01h peek     : ', Ok01, '  ', Hex4(G),
          '   (want TRUE ', Hex4(PROBEKEY), ')');
  R00 := Read00;
  WriteLn('AH=00h read     : ', Hex4(R00),
          '   (want ', Hex4(PROBEKEY), ')');
  Legacy := Ok01 and (G = PROBEKEY) and (R00 = PROBEKEY);

  { ---- the enhanced peek ---- }
  Drain;
  if not Stuff(PROBEKEY) then
  begin
    WriteLn('Could not write the BIOS keyboard buffer the second time.');
    Halt(2);
  end;
  Ok11 := Peek11(G);
  WriteLn('AH=11h peek     : ', Ok11, '  ', Hex4(G),
          '   (want TRUE ', Hex4(PROBEKEY), ')');
  R10 := Read10;
  WriteLn('AH=10h read     : ', Hex4(R10),
          '   (want ', Hex4(PROBEKEY), ')');
  Enhanced := Ok11 and (G = PROBEKEY) and (R10 = PROBEKEY);

  Drain;
  WriteLn;
  WriteLn('what the BIOS hands back for each kind of key');
  Probe('char a',   $1E61);
  Probe('Enter',    $1C0D);
  Probe('Esc',      $011B);
  Probe('Alt-F',    $2100);
  Probe('F1',       $3B00);
  Probe('Down',     $5000);
  Probe('Down E0',  $50E0);
  Probe('Up',       $4800);
  Probe('Left',     $4B00);
  Probe('Right',    $4D00);
  WriteLn;
  WriteLn('AH=02h shift    : ', Hex2(Shift02));
  WriteLn('AH=12h shift    : ', Hex4(Shift12),
          '   (AL should match AH=02h)');
  WriteLn('40:96 bit4 (101-key claimed) = ',
          (PeekW($40, $96) shr 4) and 1);
  WriteLn;

  if not Legacy then
  begin
    WriteLn('The LEGACY calls do not work, which should be impossible.');
    WriteLn('Something else is hooking INT 16h.');
    Halt(2);
  end;
  WriteLn('legacy  AH=00h/01h/02h : work');

  if not Enhanced then
  begin
    WriteLn('enhanced AH=10h/11h/12h: DO NOT WORK on this BIOS.');
    WriteLn;
    WriteLn('That is the whole explanation for a program you can type');
    WriteLn('into whose menus ignore you.  Software that drives its menu');
    WriteLn('bar through the enhanced calls -- DOS EDIT does -- gets');
    WriteLn('nothing back, however correctly a keyboard driver fills the');
    WriteLn('BIOS buffer.  It is not a driver fault and no amount of');
    WriteLn('fixing the driver''s key delivery will help.');
    WriteLn;
    WriteLn('The fix would be for the driver to hook INT 16h and');
    WriteLn('implement the three enhanced calls in terms of the legacy');
    WriteLn('ones.  On THIS machine that is not needed -- see below.');
    Halt(1);
  end;
  WriteLn('enhanced AH=10h/11h/12h: work');
  WriteLn;
  WriteLn('Both generations are present, so this is not the cause of a');
  WriteLn('menu that ignores the keyboard.');
  Halt(0);
end.
