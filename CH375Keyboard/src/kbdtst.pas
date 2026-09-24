program kbdtst;
{ KBDTST -- check a loaded USBKBD.COM.
  CH375Keyboard, StevenC & Claude.  Public domain (the Unlicense).

  Two jobs, and the first is the interesting one.

  THE TABLE CHECK.  USBKBD carries its HID-usage translation as assembly
  tables; hidkey.pas carries the same mapping as case statements, and
  KBDRAW uses that one.  Two hand-written copies of one mapping is exactly
  the kind of thing that drifts silently -- somebody fixes a key in one and
  not the other, and the driver and the diagnostic then disagree about what
  the keyboard just did.  So the resident image publishes where its tables
  are, at 0111h, and this walks all 256 usages comparing byte for byte.
  It needs no keyboard and no human.

  THE DRIVER CHECK.  The resident copy's own state: that it is there, that
  it enumerated something, that its counters move, and that the BIOS
  keyboard buffer it writes into is where it should be.

    KBDTST [/W=secs] [/Q]

      /W=dec   after the checks, wait this long for keys and print what
               arrives through INT 16h.  Needs somebody to type
      /Q       only failures

  Exit code is the number of failed checks, capped at 20 -- the bridge
  cannot read anything higher. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses hidkey, chtool;

const
  VER = '1.0.0';

const
  SIG_OFS = $0103;      { 'USBKBD01'        }
  VER_OFS = $010B;      { '1.0.0$'          }
  PTR_OFS = $0111;      { the table offsets }

var
  ResSeg: Word = 0;
  Pass, Fail: Integer;
  Quiet: Boolean = False;
  WaitS: Word = 0;

  PScan, PMod, PPlain, PShift, PExt, NExt: Word;
  { where the resident copy keeps its counters, read from the same block }
  PReports, PKeys, PFull, PLive, PLocks, PEp, PTick, PPolls: Word;
  PEnh: Word;

function Hex2(B: Byte): ShortString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4] + H[B and 15];
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := Hex2(Hi(W)) + Hex2(Lo(W));
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

procedure Chk(const Name: ShortString; Cond: Boolean);
begin
  if Cond then
  begin
    Inc(Pass);
    if not Quiet then WriteLn('  ok    ', Name);
  end
  else
  begin
    Inc(Fail);
    WriteLn('  FAIL  ', Name);
  end;
end;

{ 0040:006C, the BIOS tick counter at 18.2 Hz. }
function Ticks: LongInt;
var P: ^LongInt;
begin
  P := Ptr($40, $6C); Ticks := P^;
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

{ INT 08h's current owner, or 0. }
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

function Int08Seg: Word; assembler;
asm
  push es
  mov  ax, 3508h
  int  21h
  mov  ax, es
  pop  es
end;

function FindResident: Word;
var
  S: Word;
  I: Integer;
  Sig: array[0..7] of Char;
const
  Want = 'USBKBD01';
begin
  FindResident := 0;
  S := Int08Seg;
  if S = 0 then Exit;
  for I := 0 to 7 do Sig[I] := Chr(PeekB(S, SIG_OFS + I));
  for I := 0 to 7 do
    if Sig[I] <> Want[I + 1] then Exit;
  FindResident := S;
end;

function ResVersion: ShortString;
var I: Integer; C: Char; R: ShortString;
begin
  R := '';
  for I := 0 to 15 do
  begin
    C := Chr(PeekB(ResSeg, VER_OFS + I));
    if C = '$' then Break;
    R := R + C;
  end;
  ResVersion := R;
end;

{ ----------------------------------------------------------------------
  The table check
  ---------------------------------------------------------------------- }

function ResScanOf(U: Byte): Byte;
begin
  ResScanOf := 0;
  if (U >= $04) and (U <= $65) then
    ResScanOf := PeekB(ResSeg, PScan + U - $04)
  else if (U >= $E0) and (U <= $E7) then
    ResScanOf := PeekB(ResSeg, PMod + U - $E0);
end;

function ResIsExt(U: Byte): Boolean;
var I: Word;
begin
  ResIsExt := False;
  for I := 0 to NExt - 1 do
    if PeekB(ResSeg, PExt + I) = U then begin ResIsExt := True; Exit; end;
end;

procedure CheckTables;
var
  U: Integer;
  BadScan, BadExt, BadPlain, BadShift: Integer;
  Mine, Theirs: Byte;
  FirstBad: Integer;
begin
  WriteLn;
  WriteLn('-- the two translation tables --');

  BadScan := 0; FirstBad := -1;
  for U := 0 to 255 do
  begin
    Mine   := ScanOf(Byte(U));
    Theirs := ResScanOf(Byte(U));
    if Mine <> Theirs then
    begin
      Inc(BadScan);
      if FirstBad < 0 then FirstBad := U;
      if BadScan <= 6 then
        WriteLn('        usage ', Hex2(Byte(U)), ' (', UsageName(Byte(U)),
                '): hidkey says ', Hex2(Mine),
                ', USBKBD says ', Hex2(Theirs));
    end;
  end;
  Chk('scancode table agrees for all 256 usages', BadScan = 0);

  BadExt := 0;
  for U := 0 to 255 do
    if IsExtended(Byte(U)) <> ResIsExt(Byte(U)) then
    begin
      Inc(BadExt);
      if BadExt <= 6 then
        WriteLn('        usage ', Hex2(Byte(U)), ' (', UsageName(Byte(U)),
                '): extended flag differs');
    end;
  Chk('E0-prefix list agrees for all 256 usages', BadExt = 0);

  { The character tables cover 04h..38h only. }
  BadPlain := 0; BadShift := 0;
  for U := $04 to $38 do
  begin
    Theirs := PeekB(ResSeg, PPlain + U - $04);
    Mine   := Byte(Translate(Byte(U), 0, False, False).Ascii);
    { Translate applies Ctrl/Alt/Caps; with no modifiers and no locks its
      ASCII is exactly the unshifted table entry, which is what makes this
      comparison meaningful rather than circular. }
    if Mine <> Theirs then
    begin
      Inc(BadPlain);
      if BadPlain <= 6 then
        WriteLn('        usage ', Hex2(Byte(U)), ': plain ', Hex2(Mine),
                ' vs ', Hex2(Theirs));
    end;
    Theirs := PeekB(ResSeg, PShift + U - $04);
    Mine   := Byte(Translate(Byte(U), MOD_LSHIFT, False, False).Ascii);
    if Mine <> Theirs then
    begin
      Inc(BadShift);
      if BadShift <= 6 then
        WriteLn('        usage ', Hex2(Byte(U)), ': shifted ', Hex2(Mine),
                ' vs ', Hex2(Theirs));
    end;
  end;
  Chk('unshifted character table agrees', BadPlain = 0);
  Chk('shifted character table agrees', BadShift = 0);
end;

{ ----------------------------------------------------------------------
  A few things the translation itself must get right, checked here rather
  than left to a human noticing their keyboard is odd.
  ---------------------------------------------------------------------- }

procedure CheckRules;
var E: TKeyEvent;
begin
  WriteLn;
  WriteLn('-- translation rules --');

  E := Translate($04, 0, False, False);
  Chk('a unshifted is scancode 1E, ascii 61', (E.Scan = $1E) and (E.Ascii = $61));

  E := Translate($04, MOD_LSHIFT, False, False);
  Chk('A shifted is ascii 41', E.Ascii = $41);

  E := Translate($04, 0, True, False);
  Chk('a with Caps Lock is ascii 41', E.Ascii = $41);

  E := Translate($04, MOD_LSHIFT, True, False);
  Chk('a with Caps Lock and Shift is ascii 61 again', E.Ascii = $61);

  { The one that catches the classic bug: Caps Lock must not act as a
    second Shift on the digit row. }
  E := Translate($1E, 0, True, False);
  Chk('1 with Caps Lock is still "1", not "!"', E.Ascii = Ord('1'));
  E := Translate($1E, MOD_LSHIFT, False, False);
  Chk('1 with Shift is "!"', E.Ascii = Ord('!'));

  E := Translate($04, MOD_LCTRL, False, False);
  Chk('Ctrl-A is ascii 01', E.Ascii = 1);
  E := Translate($06, MOD_LCTRL, False, False);
  Chk('Ctrl-C is ascii 03', E.Ascii = 3);

  E := Translate($04, MOD_LALT, False, False);
  Chk('Alt-A has no ascii', E.Ascii = 0);

  E := Translate($52, 0, False, False);
  Chk('Up arrow is extended, scancode 48, no ascii',
      E.Ext and (E.Scan = $48) and (E.Ascii = 0));

  E := Translate($E4, 0, False, False);
  Chk('RightCtrl is extended, scancode 1D', E.Ext and (E.Scan = $1D));

  E := Translate($62, 0, False, True);
  Chk('keypad 0 with NumLock is "0"', E.Ascii = Ord('0'));
  E := Translate($62, 0, False, False);
  Chk('keypad 0 without NumLock has no ascii', E.Ascii = 0);

  E := Translate($00, 0, False, False);
  Chk('usage 00 produces nothing', not E.Ok);
  E := Translate($01, 0, False, False);
  Chk('rollover usage 01 produces nothing', not E.Ok);

  Chk('BiosFlags maps Shift+Ctrl+Caps correctly',
      BiosFlags(MOD_LSHIFT or MOD_RCTRL, True, False, False) =
      (KF_LSHIFT or KF_CTRL or KF_CAPS));
end;

{ ----------------------------------------------------------------------
  The resident driver and the BIOS buffer
  ---------------------------------------------------------------------- }

procedure CheckDriver;
var
  Head, Tail, Start, Ends: Word;
  R1, R2: Word;
  T0: LongInt;
begin
  WriteLn;
  WriteLn('-- the resident driver --');
  Chk('a copy of USBKBD is resident', ResSeg <> 0);
  if ResSeg = 0 then
  begin
    WriteLn('        load it first:  USBKBD');
    Exit;
  end;
  WriteLn('        version ', ResVersion, ' at segment ', Hex4(ResSeg));

  Chk('the published table pointers are plausible',
      (PScan > $100) and (PScan < $2000) and (PMod > PScan) and
      (PPlain > PMod) and (PShift > PPlain) and (PExt > PShift));
  WriteLn('        tab_scan=', Hex4(PScan), ' tab_mod=', Hex4(PMod),
          ' tab_plain=', Hex4(PPlain));
  WriteLn('        tab_shift=', Hex4(PShift), ' tab_ext=', Hex4(PExt),
          ' (', NExt, ' entries)');
  Chk('the scancode table is 98 entries long', PMod - PScan = 98);
  Chk('the modifier table is 8 entries long', PPlain - PMod = 8);
  Chk('the unshifted table is 53 entries long', PShift - PPlain = 53);
  Chk('the E0 list is 18 entries long', NExt = 18);

  WriteLn('        live=', PeekB(ResSeg, PLive),
          ' endpoint=', PeekB(ResSeg, PEp),
          ' divisor=', PeekB(ResSeg, PTick),
          ' locks=', Hex2(PeekB(ResSeg, PLocks)));
  WriteLn('        polls=', PeekW(ResSeg, PPolls),
          ' reports=', PeekW(ResSeg, PReports),
          ' keys=', PeekW(ResSeg, PKeys),
          ' dropped=', PeekW(ResSeg, PFull));
  Chk('a keyboard enumerated', PeekB(ResSeg, PLive) = 1);
  WriteLn('        40:17=', Hex2(PeekB($40, $17)),
          ' 40:18=', Hex2(PeekB($40, $18)),
          ' 40:96=', Hex2(PeekB($40, $96)),
          '   /E=', PeekB(ResSeg, PEnh));
  Chk('the timer divisor is in range',
      (PeekB(ResSeg, PTick) >= 1) and (PeekB(ResSeg, PTick) <= 16));
  if PeekW(ResSeg, PFull) > 0 then
  begin
    WriteLn('        note: ', PeekW(ResSeg, PFull), ' key(s) dropped.  That is');
    WriteLn('        correct when the BIOS buffer is full and nothing is');
    WriteLn('        reading it -- a held key auto-repeating into an idle');
    WriteLn('        machine fills all 15 slots in about a second.');
  end;

  { The BIOS keyboard buffer, which is where the driver puts everything. }
  Head  := PeekW($40, $1A);
  Tail  := PeekW($40, $1C);
  Start := PeekW($40, $80);
  Ends  := PeekW($40, $82);
  WriteLn('        BIOS buffer ', Hex4(Start), '..', Hex4(Ends),
          '  head ', Hex4(Head), '  tail ', Hex4(Tail));
  Chk('the BIOS buffer bounds are sane', (Ends > Start) and (Start >= $1E));
  Chk('the head is inside the buffer', (Head >= Start) and (Head <= Ends));
  Chk('the tail is inside the buffer', (Tail >= Start) and (Tail <= Ends));

  { The driver polls from the timer, so its POLL counter has to move on its
    own while this program does nothing but wait.  That is the whole
    difference between "loaded" and "working" -- and it has to be the poll
    count rather than the report count, because SET_IDLE 0 means an idle
    keyboard sends nothing and a perfectly healthy driver would otherwise
    look frozen. }
  R1 := PeekW(ResSeg, PPolls);
  T0 := Ticks;
  while Ticks - T0 < 20 do ;                { about a second }
  R2 := PeekW(ResSeg, PPolls);
  WriteLn('        polls ', R1, ' -> ', R2, ' over about a second');
  Chk('the driver is polling from the timer interrupt', R2 > R1);
  { At divisor 8 the fast tick is about 145 Hz, and one in eight goes
    downstream, so roughly 127 polls a second.  A wide window, because the
    point is to catch "not running" and "running at the wrong rate", not
    to measure the crystal. }
  Chk('the poll rate is in the right order of magnitude',
      (R2 - R1 > 40) and (R2 - R1 < 400));
end;

{ The bits that matter, spelled out, so a dump does not have to be decoded
  by hand at the machine. }
function FlagWords(F17, F18, F96: Byte): ShortString;
var S: ShortString;
begin
  S := '';
  if (F17 and KF_LSHIFT) <> 0 then S := S + 'LShift ';
  if (F17 and KF_RSHIFT) <> 0 then S := S + 'RShift ';
  if (F18 and $01) <> 0 then S := S + 'LCtrl ';
  if (F18 and $02) <> 0 then S := S + 'LAlt ';
  if (F96 and $04) <> 0 then S := S + 'RCtrl ';
  if (F96 and $08) <> 0 then S := S + 'RAlt ';
  if (F17 and KF_CTRL) <> 0 then S := S + '(ctrl) ';
  if (F17 and KF_ALT)  <> 0 then S := S + '(alt) ';
  if (F17 and KF_CAPS) <> 0 then S := S + 'Caps ';
  if (F17 and KF_NUM)  <> 0 then S := S + 'Num ';
  if (F96 and $10) <> 0 then S := S + '[101-key] ';
  if S = '' then S := '(nothing held)';
  FlagWords := S;
end;

procedure WatchKeys;
var
  T0: LongInt;
  W: Word;
  N: Integer;
  L17, L18, L96: Byte;
begin
  if WaitS = 0 then Exit;
  WriteLn;
  WriteLn('-- keys arriving through INT 16h, ', WaitS, ' seconds --');
  WriteLn('   type on the USB keyboard.  Esc ends it early.');
  WriteLn('   For a menu problem the three to try are Alt on its own,');
  WriteLn('   Alt+F, and an arrow key.  What matters is 40:18 bit 1 and');
  WriteLn('   40:96 bit 3 following Alt up and down -- that is what a');
  WriteLn('   text-mode menu bar actually watches.');
  WriteLn('   before any key:  40:17=', Hex2(PeekB($40, $17)),
          ' 40:18=', Hex2(PeekB($40, $18)),
          ' 40:96=', Hex2(PeekB($40, $96)));
  N := 0;
  L17 := PeekB($40, $17); L18 := PeekB($40, $18); L96 := PeekB($40, $96);
  T0 := Ticks;
  while Ticks - T0 < LongInt(WaitS) * 182 div 10 do
  begin
    { Alt pressed on its own never puts a word in the buffer -- the only
      trace it leaves is in the shift bytes, so those are watched
      separately or the interesting case is invisible. }
    if (PeekB($40, $17) <> L17) or (PeekB($40, $18) <> L18)
       or (PeekB($40, $96) <> L96) then
    begin
      L17 := PeekB($40, $17); L18 := PeekB($40, $18); L96 := PeekB($40, $96);
      WriteLn('        shift   40:17=', Hex2(L17),
              ' 40:18=', Hex2(L18), ' 40:96=', Hex2(L96),
              '   ', FlagWords(L17, L18, L96));
    end;
    if KeyReady then
    begin
      W := GetKey;
      Inc(N);
      Write('        scan ', Hex2(Hi(W)), '  ascii ', Hex2(Lo(W)));
      if (Lo(W) >= 32) and (Lo(W) < 127) then Write('  "', Chr(Lo(W)), '"');
      WriteLn('   40:17=', Hex2(PeekB($40, $17)),
              ' 40:18=', Hex2(PeekB($40, $18)),
              ' 40:96=', Hex2(PeekB($40, $96)));
      if Hi(W) = $01 then Break;              { Esc ends it early }
    end;
  end;
  WriteLn('        ', N, ' key(s) read back through the BIOS.');
  Chk('at least one key came through INT 16h', N > 0);
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/Q') or (A = '-Q') then Quiet := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if K = '/W=' then begin Val(A, V, Code); if Code = 0 then WaitS := Word(V); end;
    end;
  end;
end;

procedure Usage;
begin
  Banner('KBDTST', VER, 'check a loaded USBKBD.COM');
  WriteLn;
  WriteLn('  KBDTST [/W=secs] [/Q]');
  WriteLn;
  WriteLn('  /W=dec   after the checks, wait this long for keys and print');
  WriteLn('           what arrives through INT 16h.  Needs somebody to type');
  WriteLn('  /Q       only failures');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Two jobs, and the first is the interesting one.');
  WriteLn;
  WriteLn('THE TABLE CHECK.  USBKBD carries its HID-usage translation as');
  WriteLn('assembly tables; hidkey.pas carries the same mapping as case');
  WriteLn('statements, and KBDRAW uses that one.  Two hand-written copies');
  WriteLn('of one mapping drift silently -- somebody fixes a key in one');
  WriteLn('and not the other.  So the resident image publishes where its');
  WriteLn('tables are, at 0111h, and this walks all 256 usages comparing');
  WriteLn('byte for byte.  It needs no keyboard and no human.');
  WriteLn;
  WriteLn('THE DRIVER CHECK.  That the resident copy is there, that it');
  WriteLn('enumerated something, that its counters move, and that the BIOS');
  WriteLn('keyboard buffer it writes into is where it should be.');
  WriteLn;
  WriteLn('This talks to the resident driver, never to the card, so it');
  WriteLn('needs no /P= -- the driver already knows its own I/O base, and');
  WriteLn('USBKBD /S prints it.');
  WriteLn;
  WriteLn('Exit code is the number of failed checks, capped at 20.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('KBDTST', VER, 'USBKBD conformance');
  Pass := 0; Fail := 0;

  ResSeg := FindResident;
  if ResSeg <> 0 then
  begin
    PScan  := PeekW(ResSeg, PTR_OFS);
    PMod   := PeekW(ResSeg, PTR_OFS + 2);
    PPlain := PeekW(ResSeg, PTR_OFS + 4);
    PShift := PeekW(ResSeg, PTR_OFS + 6);
    PExt   := PeekW(ResSeg, PTR_OFS + 8);
    NExt   := PeekW(ResSeg, PTR_OFS + 10);
    PReports := PeekW(ResSeg, PTR_OFS + 12);
    PKeys    := PeekW(ResSeg, PTR_OFS + 14);
    PFull    := PeekW(ResSeg, PTR_OFS + 16);
    PLive    := PeekW(ResSeg, PTR_OFS + 18);
    PLocks   := PeekW(ResSeg, PTR_OFS + 20);
    PEp      := PeekW(ResSeg, PTR_OFS + 22);
    PTick    := PeekW(ResSeg, PTR_OFS + 24);
    PPolls   := PeekW(ResSeg, PTR_OFS + 26);
    PEnh     := PeekW(ResSeg, PTR_OFS + 28);
  end;

  CheckRules;
  if ResSeg <> 0 then CheckTables;
  CheckDriver;
  if ResSeg <> 0 then WatchKeys;

  WriteLn;
  WriteLn(Pass, ' passed, ', Fail, ' failed.');
  if Fail > 20 then Fail := 20;
  Halt(Fail);
end.
