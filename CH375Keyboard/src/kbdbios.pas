program kbdbios;
{ KBDBIOS -- dump the BIOS keyboard data area.
  CH375Keyboard, StevenC & Claude.  Public domain (the Unlicense).

  A resident keyboard driver does not own the keyboard state; it borrows it.
  Everything it touches -- the three shift bytes, the buffer head and tail,
  the LED shadow -- belongs to the BIOS and has to be handed back in a
  condition the BIOS's own INT 09h handler can still work with.

  This exists because USBKBD 1.1.0 got that wrong: after `USBKBD /U` the
  machine's ordinary PS/2 keyboard stopped working, and nothing in the
  driver's own status output could show why. The way to find a bug like
  that is to photograph the data area before and after and subtract.

    KBDBIOS [/S=file]

      /S=file  also write the dump to a file, so two runs can be compared
               with FC on the DOS side or diffed on the host

  Nothing here writes to the data area. It is safe to run at any time,
  including with a driver loaded. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses chtool;

const
  VER = '1.0.0';

var
  SaveTo: ShortString = '';

function Hex2(B: Byte): ShortString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4] + H[B and 15];
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := Hex2(Hi(W)) + Hex2(Lo(W));
end;

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

function PeekB(Seg, Ofs: Word): Byte;
var P: ^Byte;
begin
  P := Ptr(Seg, Ofs); PeekB := P^;
end;

function PeekW(Seg, Ofs: Word): Word;
var P: ^Word;
begin
  P := Ptr(Seg, Ofs); PeekW := P^;
end;

function VecSeg(N: Byte): Word;
begin
  VecSeg := PeekW(0, N * 4 + 2);
end;

function VecOfs(N: Byte): Word;
begin
  VecOfs := PeekW(0, N * 4);
end;

var
  Out1: Text;
  Saving: Boolean = False;

procedure Say(const S: ShortString);
begin
  WriteLn(S);
  if Saving then WriteLn(Out1, S);
end;

function Bits(B: Byte; const Names: array of ShortString): ShortString;
var I: Integer; S: ShortString;
begin
  S := '';
  for I := 0 to 7 do
    if (B and (1 shl I)) <> 0 then
      if I <= High(Names) then
        if Names[I] <> '' then S := S + Names[I] + ' ';
  if S = '' then S := '-';
  Bits := S;
end;

var
  F17, F18, F96, F97: Byte;
  Head, Tail, BStart, BEnd: Word;
  I: Word;
  S: ShortString;
  Code: Integer;
  A, K: ShortString;

procedure Usage;
begin
  Banner('KBDBIOS', VER, 'dump the BIOS keyboard data area');
  WriteLn;
  WriteLn('  KBDBIOS [/S=file]');
  WriteLn;
  WriteLn('  /S=file  also write the dump to a file, so two runs can be');
  WriteLn('           compared with FC on the DOS side or diffed on a host');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('A resident keyboard driver does not own the keyboard state; it');
  WriteLn('borrows it.  The three shift bytes, the buffer head and tail,');
  WriteLn('the LED shadow -- all belong to the BIOS and have to be handed');
  WriteLn('back in a condition its own INT 09h can still work with.');
  WriteLn;
  WriteLn('This exists because USBKBD 1.1.0 got that wrong: after /U the');
  WriteLn('machine''s own keyboard stopped working and nothing in the');
  WriteLn('driver''s status output could show why.  The way to find a bug');
  WriteLn('like that is to photograph the data area before and after and');
  WriteLn('subtract.');
  WriteLn;
  WriteLn('Nothing here writes to the data area.  It is safe to run at any');
  WriteLn('time, including with a driver loaded.  It reads the BIOS, not');
  WriteLn('the card, so there is no I/O base to set.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Banner('KBDBIOS', VER, 'BIOS keyboard data area');
  WriteLn;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3);
      if K = '/S=' then SaveTo := Copy(ParamStr(I), 4, 60);
    end;
  end;
  if SaveTo <> '' then
  begin
    Assign(Out1, SaveTo);
    {$I-} Rewrite(Out1); {$I+}
    Saving := IOResult = 0;
    if not Saving then WriteLn('(cannot write ', SaveTo, '; printing only)');
  end;

  F17 := PeekB($40, $17);
  F18 := PeekB($40, $18);
  F96 := PeekB($40, $96);
  F97 := PeekB($40, $97);

  Say('=== KBDBIOS -- BIOS keyboard data area ===');
  Say('');
  Say('40:17 = ' + Hex2(F17) + '   ' +
      Bits(F17, ['RShift', 'LShift', 'Ctrl', 'Alt',
                 'ScrollLock', 'NumLock', 'CapsLock', 'Insert']));
  Say('40:18 = ' + Hex2(F18) + '   ' +
      Bits(F18, ['LCtrl-down', 'LAlt-down', 'SysReq-down', 'PAUSE-ACTIVE',
                 'ScrLk-down', 'NumLk-down', 'CapsLk-down', 'Ins-down']));
  Say('40:96 = ' + Hex2(F96) + '   ' +
      Bits(F96, ['lastE1', 'lastE0', 'RCtrl-down', 'RAlt-down',
                 '101-key', 'forceNumLock', 'firstIDchar',
                 'ID-READ-IN-PROGRESS']));
  Say('40:97 = ' + Hex2(F97) + '   ' +
      Bits(F97, ['ScrollLED', 'NumLED', 'CapsLED', '',
                 'ACK-received', 'resend', 'LED-UPDATE-BUSY',
                 'xmit-error']));
  Say('');
  Say('The two in capitals are the ones that stop a keyboard dead without');
  Say('breaking anything else: 40:18 bit 3 puts the BIOS in its Pause hold');
  Say('loop, and 40:96 bit 7 makes it swallow scancodes as keyboard-ID');
  Say('bytes.  40:97 bit 6 does much the same while an LED update is');
  Say('believed to be outstanding.');
  Say('');

  Head   := PeekW($40, $1A);
  Tail   := PeekW($40, $1C);
  BStart := PeekW($40, $80);
  BEnd   := PeekW($40, $82);
  Say('buffer  start=' + Hex4(BStart) + ' end=' + Hex4(BEnd) +
      ' head=' + Hex4(Head) + ' tail=' + Hex4(Tail));
  if Head = Tail then Say('        (empty)')
                 else Say('        (holding data)');
  if (Head < BStart) or (Head >= BEnd) or (Tail < BStart) or (Tail >= BEnd) then
    Say('        *** head or tail is OUTSIDE the buffer -- the BIOS insert')
  else
    Say('        head and tail are both in range');
  if (Head < BStart) or (Head >= BEnd) or (Tail < BStart) or (Tail >= BEnd) then
    Say('            path will never accept another key');

  S := '        ';
  for I := BStart to BEnd - 1 do
  begin
    S := S + Hex2(PeekB($40, I));
    if ((I - BStart) and 1) = 1 then S := S + ' ';
    if ((I - BStart) and 15) = 15 then begin Say(S); S := '        '; end;
  end;
  if Length(S) > 8 then Say(S);
  Say('');

  Say('vectors INT 08h = ' + Hex4(VecSeg(8))  + ':' + Hex4(VecOfs(8)));
  Say('        INT 09h = ' + Hex4(VecSeg(9))  + ':' + Hex4(VecOfs(9)));
  Say('        INT 15h = ' + Hex4(VecSeg($15)) + ':' + Hex4(VecOfs($15)));
  Say('        INT 16h = ' + Hex4(VecSeg($16)) + ':' + Hex4(VecOfs($16)));
  Say('        INT 1Ch = ' + Hex4(VecSeg($1C)) + ':' + Hex4(VecOfs($1C)));
  Say('');
  Say('8259 mask port 21h = ' + Hex2(InB($21)) + '  (bit 1 clear = IRQ1');
  Say('        the keyboard interrupt is enabled)');

  if Saving then Close(Out1);
end.
