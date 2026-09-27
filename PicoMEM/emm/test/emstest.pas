program emstest;
{ EMSTEST -- does an EMS driver behave, and how fast is it?
  PicoMEM tools, StevenC & Claude.  Public domain (the Unlicense).

    EMSTEST          the behaviour test, then the benchmark
    EMSTEST /T       the behaviour test only
    EMSTEST /B       the benchmark only

  Written to compare two builds of PMEMM, the PicoMEM EMS driver, but it
  speaks plain LIM EMS 4.0 through INT 67h and works on any driver.

  THE BEHAVIOUR TEST prints one line per check: the status code the
  driver returned and whatever it handed back, with a CRC-32 over any
  memory it touched.  Nothing in it depends on timing or on addresses
  that move, so two drivers that behave the same print the SAME
  TRANSCRIPT -- diff them.  The final line is a CRC over every line, so
  one number says whether anything differed.  It covers every function
  the driver implements: allocation and its errors, 44h mapping into all
  four windows, 50h both ways, 4Eh/4Fh/47h/48h map save and restore,
  51h reallocation up and down with the contents checked, the handle
  names and directory, and 57h move and exchange -- conventional and
  expanded in all four combinations, overlapping both ways, odd lengths
  and offsets, and regions that cross page boundaries.

  THE BENCHMARK times each call in a fixed number of BIOS ticks and
  reports calls (or KB) per second.

  It allocates what it uses and frees it on the way out, so it can run
  with anything else holding EMS.  Needs 80 free pages (1.25 MB).

  Exit code: 0 ran, 1 no EMS driver, 2 not enough EMS, 3 a check that
  must hold (data written through the window read back wrong) failed. }

{$MODE OBJFPC}{$H-}

uses Dos, vidfix;

const
  VER = '1.0.0';
  BIGPAGES = 64;          { the main test handle: 1 MB }
  BUFSZ = 49152;          { conventional buffers, 3 pages }

type
  TBuf = array[0..BUFSZ - 1] of Byte;
  PBuf = ^TBuf;

var
  R: Registers;
  Frame: Word;
  H1, H2: Word;
  BufA, BufB: PBuf;
  TransCrc: LongWord;
  Fails: Integer;
  CrcTab: array[0..255] of LongWord;
  DoTest, DoBench: Boolean;
  LastBeat: Word;
  Spin: Byte;

{ ---------------------------------------------------------------- misc }

procedure InitCrc;
var i, j: Integer; c: LongWord;
begin
  for i := 0 to 255 do begin
    c := i;
    for j := 1 to 8 do
      if (c and 1) <> 0 then c := (c shr 1) xor $EDB88320 else c := c shr 1;
    CrcTab[i] := c;
  end;
end;

function CrcMem(p: Pointer; n: Word): LongWord;
var c: LongWord; b: ^Byte; i: Word;
begin
  c := $FFFFFFFF; b := p;
  for i := 1 to n do begin
    c := CrcTab[(c xor b^) and $FF] xor (c shr 8);
    Inc(b);
  end;
  CrcMem := not c;
end;

function Hex(v: LongWord; d: Integer): string;
const H: string[16] = '0123456789ABCDEF';
var s: string;
begin
  s := '';
  while d > 0 do begin s := H[(v and 15) + 1] + s; v := v shr 4; Dec(d); end;
  Hex := s;
end;

function Dec2(v: LongInt): string;
var s: string;
begin Str(v, s); Dec2 := s; end;

function Ticks: Word;
begin Ticks := MemW[$40:$6C]; end;

{ Heartbeat on stderr, driven by the clock: COMMAND.COM cannot redirect
  handle 2, so it lands on the real screen and nowhere else. }
procedure Beat;
const S: array[0..3] of Char = '|/-\';
var t: Word; c: array[0..1] of Char;
begin
  t := Ticks;
  if t = LastBeat then Exit;
  LastBeat := t;
  Spin := (Spin + 1) and 3;
  c[0] := S[Spin]; c[1] := #8;
  asm
    push ds
    mov  ax, ss
    mov  ds, ax
    lea  dx, c
    mov  cx, 2
    mov  bx, 2
    mov  ah, 40h
    int  21h
    pop  ds
  end;
end;

{ Every transcript line goes through here, so the final CRC covers them all. }
procedure T(const s: string);
begin
  WriteLn(s);
  TransCrc := CrcMem(@s[1], Length(s)) xor ((TransCrc shl 1) or (TransCrc shr 31));
  Beat;
end;

procedure Must(ok: Boolean; const what: string);
begin
  if not ok then begin
    Inc(Fails);
    T('  ** FAILED: ' + what);
  end;
end;

procedure Ems(ax: Word);
begin
  R.AX := ax;
  Intr($67, R);
end;

function St: string;
begin St := 'AH=' + Hex(R.AH, 2); end;

{ number of differing bytes (0 = same); CompareByte takes a 16-bit
  signed length on this target, so it cannot compare 40000 bytes }
function Differ(var a, b; n: Word): Word;
var pa, pb: ^Byte; k, d: Word;
begin
  pa := @a; pb := @b; d := 0;
  for k := 1 to n do begin
    if pa^ <> pb^ then Inc(d);
    Inc(pa); Inc(pb);
  end;
  Differ := d;
end;

{ index of the first differing byte, or n if none }
function FirstDiff(var a, b; n: Word): Word;
var pa, pb: ^Byte; k: Word;
begin
  pa := @a; pb := @b;
  for k := 0 to n - 1 do begin
    if pa^ <> pb^ then begin FirstDiff := k; Exit; end;
    Inc(pa); Inc(pb);
  end;
  FirstDiff := n;
end;

{ ------------------------------------------------------- window access }

function WinSeg(phys: Integer): Word;
begin WinSeg := Frame + Word(phys) * $400; end;

{ Fill a 16 KB window with a word pattern that encodes the handle and
  logical page, so any page landing in the wrong place is caught. }
procedure FillWin(phys: Integer; v: Word);
var s: Word;
begin
  s := WinSeg(phys);
  asm
    push es
    push di
    mov  es, s
    xor  di, di
    mov  ax, v
    mov  cx, 2000h
    cld
    rep  stosw
    pop  di
    pop  es
  end;
  Mem[s:0] := Lo(v) xor $5A;      { plus one byte that differs from the rest }
end;

function CheckWin(phys: Integer; v: Word): Boolean;
var s: Word; left: Word;
begin
  s := WinSeg(phys);
  if Mem[s:0] <> (Lo(v) xor $5A) then begin CheckWin := False; Exit; end;
  asm
    push es
    push di
    mov  es, s
    mov  di, 2
    mov  ax, v
    mov  cx, 1FFFh
    cld
    repe scasw
    mov  left, cx
    pop  di
    pop  es
  end;
  CheckWin := (left = 0) and (MemW[s:$3FFE] = v);
end;

function PageTag(h, p: Word): Word;
begin PageTag := (h shl 8) xor (p * 37) xor $A5C3; end;

function Map(phys: Byte; log, h: Word): Byte;
begin
  R.BX := log; R.DX := h;
  Ems($4400 or phys);
  Map := R.AH;
end;

{ ---------------------------------------------------------- the tests }

procedure TestBasics;
var total, free: Word;
begin
  Ems($4000); T('40 status          ' + St);
  Ems($4100); T('41 frame           ' + St + ' seg=' + Hex(R.BX, 4));
  Ems($4200); total := R.DX; free := R.BX;
  T('42 pages           ' + St + ' total=' + Dec2(total));
  Ems($4600); T('46 version         ' + St + ' AL=' + Hex(R.AL, 2));
  Ems($4B00); T('4B handles         ' + St);
  R.BX := 0; Ems($4300); T('43 alloc 0         ' + St);
  R.BX := total + 1; Ems($4300); T('43 alloc total+1   ' + St);
  R.BX := free + 1; Ems($4300);
  if free < total then T('43 alloc free+1    ' + St)
  else T('43 alloc free+1    (skipped, all free)');
  Ems($3F00); T('3F bad function    ' + St);
  Ems($5E00); T('5E bad function    ' + St);
end;

procedure TestMap;
var p, ph: Integer; ok: Boolean;
begin
  R.BX := BIGPAGES; Ems($4300); H1 := R.DX;
  T('43 alloc ' + Dec2(BIGPAGES) + '       ' + St);
  R.BX := 3; Ems($4300); H2 := R.DX;
  T('43 alloc 3         ' + St);
  Ems($4B00); T('4B handles         ' + St + ' BX=' + Dec2(R.BX - 2));
  R.DX := H1; Ems($4C00); T('4C pages H1        ' + St + ' BX=' + Dec2(R.BX));
  R.DX := H2; Ems($4C00); T('4C pages H2        ' + St + ' BX=' + Dec2(R.BX));

  { write every page through a window that rotates, read every page back
    through a different one }
  ok := True;
  for p := 0 to BIGPAGES - 1 do begin
    ph := p and 3;
    if Map(ph, p, H1) <> 0 then ok := False;
    FillWin(ph, PageTag(H1, p));
  end;
  for p := 0 to 2 do begin
    Map(p, p, H2); FillWin(p, PageTag(H2, p));
  end;
  Must(ok, '44 mapping while filling');
  ok := True;
  for p := BIGPAGES - 1 downto 0 do begin
    ph := (p + 1) and 3;
    if Map(ph, p, H1) <> 0 then ok := False;
    if not CheckWin(ph, PageTag(H1, p)) then ok := False;
  end;
  for p := 0 to 2 do begin
    Map(3 - p, p, H2);
    if not CheckWin(3 - p, PageTag(H2, p)) then ok := False;
  end;
  Must(ok, '44 all pages read back through another window');
  T('44 fill+verify     ' + Dec2(BIGPAGES + 3) + ' pages ' + Hex(Ord(ok), 1));

  T('44 phys 4          AH=' + Hex(Map(4, 0, H1), 2));
  T('44 phys 255        AH=' + Hex(Map(255, 0, H1), 2));
  T('44 log out of rng  AH=' + Hex(Map(0, BIGPAGES, H1), 2));
  T('44 log 255 on H2   AH=' + Hex(Map(0, 255, H2), 2));
  T('44 handle 99       AH=' + Hex(Map(0, 0, 99), 2));
  T('44 handle 63 free  AH=' + Hex(Map(0, 0, 63), 2));
  T('44 unmap           AH=' + Hex(Map(2, $FFFF, H1), 2));
  T('44 remap same      AH=' + Hex(Map(1, 5, H1), 2) + ' ' + Hex(Map(1, 5, H1), 2));
  Must(CheckWin(1, PageTag(H1, 5)), '44 remap same page');
end;

type
  TMapPair = record a, b: Word; end;

var
  Pairs: array[0..7] of TMapPair;

procedure Map50(sub: Byte; n: Word; h: Word);
begin
  R.CX := n; R.DX := h;
  R.DS := Seg(Pairs); R.SI := Ofs(Pairs);
  Ems($5000 or sub);
end;

procedure TestMap50;
var i: Integer; ok: Boolean;
begin
  for i := 0 to 3 do begin Pairs[i].a := 10 + i; Pairs[i].b := 3 - i; end;
  Map50(0, 4, H1); ok := R.AH = 0;
  for i := 0 to 3 do if not CheckWin(3 - i, PageTag(H1, 10 + i)) then ok := False;
  T('50/00 map 4        ' + St + ' ' + Hex(Ord(ok), 1));
  Must(ok, '50/00 contents');

  for i := 0 to 3 do begin Pairs[i].a := 40 + i; Pairs[i].b := WinSeg(i); end;
  Map50(1, 4, H1); ok := R.AH = 0;
  for i := 0 to 3 do if not CheckWin(i, PageTag(H1, 40 + i)) then ok := False;
  T('50/01 map 4 by seg ' + St + ' ' + Hex(Ord(ok), 1));
  Must(ok, '50/01 contents');

  Pairs[0].a := 1; Pairs[0].b := 4;   Map50(0, 1, H1); T('50/00 phys 4       ' + St);
  Pairs[0].a := 1; Pairs[0].b := $D000; Map50(1, 1, H1); T('50/01 bad seg      ' + St);
  Pairs[0].a := 70; Pairs[0].b := 0;  Map50(0, 1, H1); T('50/00 log range    ' + St);
  Map50(0, 5, H1); T('50/00 count 5      ' + St);
  Map50(0, 0, H1); T('50/00 count 0      ' + St);
  Map50(0, 1, 99); T('50/00 handle 99    ' + St);
  Map50(2, 1, H1); T('50/02              ' + St);
  Pairs[0].a := $FFFF; Pairs[0].b := 1; Map50(0, 1, H1); T('50/00 unmap        ' + St);
end;

procedure TestMapSave;
var i: Integer; sz: Word; ok: Boolean;
begin
  for i := 0 to 3 do Map(i, 20 + i, H1);
  Ems($4E03); sz := R.AL; T('4E/03 size         ' + St + ' AL=' + Dec2(sz));
  FillChar(BufA^, 256, $EE);
  R.ES := Seg(BufA^); R.DI := Ofs(BufA^); Ems($4E00);
  T('4E/00 get          ' + St + ' crc=' + Hex(CrcMem(BufA, 64), 8));
  for i := 0 to 3 do Map(i, 30 + i, H1);
  R.DS := Seg(BufA^); R.SI := Ofs(BufA^); Ems($4E01);
  ok := True;
  for i := 0 to 3 do if not CheckWin(i, PageTag(H1, 20 + i)) then ok := False;
  T('4E/01 set          ' + St + ' ' + Hex(Ord(ok), 1));
  Must(ok, '4E/01 restored the windows');
  for i := 0 to 3 do Map(i, 50 + i, H1);
  R.DS := Seg(BufA^); R.SI := Ofs(BufA^);
  R.ES := Seg(BufB^); R.DI := Ofs(BufB^); Ems($4E02);
  ok := True;
  for i := 0 to 3 do if not CheckWin(i, PageTag(H1, 20 + i)) then ok := False;
  T('4E/02 get+set      ' + St + ' ' + Hex(Ord(ok), 1) + ' crc=' + Hex(CrcMem(BufB, 64), 8));
  Must(ok, '4E/02');
  Move(BufA^, BufB^, 64); BufB^[2] := BufB^[2] xor 1;   { corrupt a port }
  R.DS := Seg(BufB^); R.SI := Ofs(BufB^); Ems($4E01);
  T('4E/01 corrupt      ' + St);
  Ems($4E04); T('4E/04              ' + St);

  { 47h/48h }
  for i := 0 to 3 do Map(i, 60 + i, H1);
  R.DX := H1; Ems($4700); T('47 save H1         ' + St);
  R.DX := H1; Ems($4700); T('47 save H1 again   ' + St);
  for i := 0 to 3 do Map(i, i, H1);
  R.DX := H2; Ems($4800); T('48 restore H2 none ' + St);
  R.DX := H1; Ems($4800);
  ok := True;
  for i := 0 to 3 do if not CheckWin(i, PageTag(H1, 60 + i)) then ok := False;
  T('48 restore H1      ' + St + ' ' + Hex(Ord(ok), 1));
  Must(ok, '48 restored the windows');
  R.DX := H1; Ems($4800); T('48 restore again   ' + St);
  R.DX := 99; Ems($4700); T('47 handle 99       ' + St);

  { 4Fh partial }
  R.BX := 2; Ems($4F02); T('4F/02 size 2       ' + St + ' AL=' + Dec2(R.AL));
  R.BX := 5; Ems($4F02); T('4F/02 size 5       ' + St);
  for i := 0 to 3 do Map(i, 8 + i, H1);
  Pairs[0].a := 2; Pairs[0].b := WinSeg(1); Pairs[1].a := WinSeg(3);
  R.DS := Seg(Pairs); R.SI := Ofs(Pairs); R.ES := Seg(BufA^); R.DI := Ofs(BufA^);
  Ems($4F00); T('4F/00 get 2        ' + St + ' crc=' + Hex(CrcMem(BufA, 20), 8));
  Map(1, 0, H1); Map(3, 0, H1);
  R.DS := Seg(BufA^); R.SI := Ofs(BufA^); Ems($4F01);
  ok := CheckWin(1, PageTag(H1, 9)) and CheckWin(3, PageTag(H1, 11));
  T('4F/01 set 2        ' + St + ' ' + Hex(Ord(ok), 1));
  Must(ok, '4F/01 restored the windows');
end;

{ ---- 57h: move and exchange.  The reference is conventional memory: a
  region is copied out of EMS with 44h-mapped reads, so the check does
  not rely on the function being tested. }

type
  TMove = packed record
    len: LongInt;
    stype: Byte; shandle: Word; soff: Word; sseg: Word;
    dtype: Byte; dhandle: Word; doff: Word; dseg: Word;
  end;

var
  Mv: TMove;

procedure Do57(sub: Byte);
begin
  R.DS := Seg(Mv); R.SI := Ofs(Mv);
  Ems($5700 or sub);
end;

{ read len bytes of handle h from page p offset o into BufB via 44h }
procedure ReadEms(h, p, o: Word; len: Word);
var done, n: Word;
begin
  done := 0;
  while done < len do begin
    Map(0, p, h);
    n := $4000 - o;
    if n > len - done then n := len - done;
    Move(Mem[Frame:o], BufB^[done], n);
    Inc(done, n); Inc(p); o := 0;
  end;
end;

procedure SetConv(var mv: TMove; toDest: Boolean; p: Pointer);
begin
  if toDest then begin mv.dtype := 0; mv.dhandle := 0; mv.dseg := Seg(p^); mv.doff := Ofs(p^); end
  else begin mv.stype := 0; mv.shandle := 0; mv.sseg := Seg(p^); mv.soff := Ofs(p^); end;
end;

procedure SetExp(var mv: TMove; toDest: Boolean; h, p, o: Word);
begin
  if toDest then begin mv.dtype := 1; mv.dhandle := h; mv.dseg := p; mv.doff := o; end
  else begin mv.stype := 1; mv.shandle := h; mv.sseg := p; mv.soff := o; end;
end;

procedure TestMove;
var i: Word; ok: Boolean; c: LongWord;
  procedure Pattern(seed: Byte);
  var k: Word;
  begin for k := 0 to BUFSZ - 1 do BufA^[k] := Byte(k * 7 + seed + (k shr 8)); end;
  procedure M(const nm: string; sub: Byte);
  var sv0, sv3: Word;
  begin
    Map(0, 1, H1); Map(3, 2, H1);          { the move must leave these alone }
    Do57(sub);
    sv0 := MemW[WinSeg(0):100]; sv3 := MemW[WinSeg(3):100];
    T(nm + St + ' win ' + Hex(Ord((sv0 = PageTag(H1, 1)) and (sv3 = PageTag(H1, 2))), 1));
  end;
begin
  { conventional -> expanded, odd everything, crossing two page ends }
  Pattern(1);
  FillChar(Mv, SizeOf(Mv), 0);
  Mv.len := 40001; SetConv(Mv, False, @BufA^[3]); SetExp(Mv, True, H1, 4, 16383);
  M('57/00 c->e 40001   ', 0);
  ReadEms(H1, 4, 16383, 40001);
  ok := Differ(BufA^[3], BufB^[0], 40001) = 0;
  T('57/00 c->e check   ' + Hex(Ord(ok), 1) + ' first bad ' + Dec2(FirstDiff(BufA^[3], BufB^[0], 40001)));
  Must(ok, '57/00 conventional to expanded');

  { expanded -> conventional back out }
  FillChar(BufB^, BUFSZ div 2, 0); FillChar(BufB^[BUFSZ div 2], BUFSZ div 2, 0);
  Mv.len := 40001; SetExp(Mv, False, H1, 4, 16383); SetConv(Mv, True, @BufB^[1]);
  M('57/00 e->c 40001   ', 0);
  ok := Differ(BufA^[3], BufB^[1], 40001) = 0;
  T('57/00 e->c check   ' + Hex(Ord(ok), 1) + ' crc=' + Hex(CrcMem(BufB, BUFSZ), 8));
  Must(ok, '57/00 expanded to conventional');

  { small and boundary lengths, even offsets }
  for i := 0 to 5 do begin
    case i of
      0: Mv.len := 1; 1: Mv.len := 2; 2: Mv.len := 3;
      3: Mv.len := 16384; 4: Mv.len := 16385; 5: Mv.len := 32768;
    end;
    Pattern(i + 20);
    SetConv(Mv, False, BufA); SetExp(Mv, True, H1, 12, 0);
    M('57/00 c->e ' + Dec2(Mv.len) + '     ', 0);
    ReadEms(H1, 12, 0, Word(Mv.len) + 2);
    ok := Differ(BufA^[0], BufB^[0], Word(Mv.len)) = 0;
    T('  check ' + Hex(Ord(ok), 1) + ' first bad ' + Dec2(FirstDiff(BufA^[0], BufB^[0], Word(Mv.len))) + ' tail crc=' + Hex(CrcMem(@BufB^[Word(Mv.len)], 2), 8));
    Must(ok, '57/00 length ' + Dec2(Mv.len));
  end;

  { expanded -> expanded, different handles }
  Mv.len := 20000; SetExp(Mv, False, H1, 4, 100); SetExp(Mv, True, H2, 0, 5);
  M('57/00 e->e h1->h2  ', 0);
  ReadEms(H2, 0, 5, 20000); c := CrcMem(BufB, 20000);
  ReadEms(H1, 4, 100, 20000);
  T('  check ' + Hex(Ord(c = CrcMem(BufB, 20000)), 1) + ' crc=' + Hex(c, 8));
  Must(c = CrcMem(BufB, 20000), '57/00 expanded to expanded');

  { same handle, overlapping forward and backward }
  Mv.len := 30000; SetExp(Mv, False, H1, 20, 0); SetExp(Mv, True, H1, 20, 1000);
  M('57/00 overlap fwd  ', 0);
  ReadEms(H1, 20, 0, 31000); T('  crc=' + Hex(CrcMem(BufB, 31000), 8));
  Mv.len := 30000; SetExp(Mv, False, H1, 24, 1000); SetExp(Mv, True, H1, 24, 0);
  M('57/00 overlap back ', 0);
  ReadEms(H1, 24, 0, 31000); T('  crc=' + Hex(CrcMem(BufB, 31000), 8));

  { conventional -> conventional, overlapping both ways }
  Pattern(9);
  Mv.len := 10000; SetConv(Mv, False, @BufA^[0]); SetConv(Mv, True, @BufA^[333]);
  M('57/00 c->c ovl fwd ', 0); T('  crc=' + Hex(CrcMem(BufA, 12000), 8));
  Pattern(9);
  Mv.len := 10000; SetConv(Mv, False, @BufA^[333]); SetConv(Mv, True, @BufA^[0]);
  M('57/00 c->c ovl bk  ', 0); T('  crc=' + Hex(CrcMem(BufA, 12000), 8));

  { errors }
  Mv.len := 16384; SetExp(Mv, False, H1, 4, 16384); SetConv(Mv, True, BufB);
  M('57/00 offset 16384 ', 0);
  Mv.len := 16385 * 3; SetExp(Mv, False, H2, 1, 0); SetConv(Mv, True, BufB);
  M('57/00 past handle  ', 0);
  Mv.len := 1048577; M('57/00 len > 1MB    ', 0);
  Mv.len := 100; SetExp(Mv, False, 99, 0, 0); M('57/00 handle 99    ', 0);
  Mv.len := 100; SetExp(Mv, False, H1, 0, 0); Mv.dtype := 2; M('57/00 type 2       ', 0);
  Mv.len := 100; SetConv(Mv, False, Ptr($FFFF, 0)); SetConv(Mv, True, BufB);
  M('57/00 wrap 1MB     ', 0);
  Mv.len := 0; SetConv(Mv, False, BufA); SetConv(Mv, True, BufB);
  M('57/00 len 0        ', 0);

  { exchange: conventional <-> expanded, odd length, crossing pages }
  Pattern(77);
  ReadEms(H1, 40, 16000, 20001); Move(BufB^, BufB^[24000], 20001);
  Mv.len := 20001; SetConv(Mv, False, @BufA^[1]); SetExp(Mv, True, H1, 40, 16000);
  M('57/01 c<->e 20001  ', 1);
  ok := Differ(BufA^[1], BufB^[24000], 20001) = 0;
  ReadEms(H1, 40, 16000, 20001);
  Pattern(77);
  ok := ok and (Differ(BufA^[1], BufB^[0], 20001) = 0);
  T('  check ' + Hex(Ord(ok), 1));
  Must(ok, '57/01 exchange');
  Mv.len := 20000; SetExp(Mv, False, H1, 4, 0); SetExp(Mv, True, H1, 4, 100);
  M('57/01 overlap      ', 1);
  Mv.len := 5000; SetExp(Mv, False, H1, 4, 0); SetExp(Mv, True, H2, 0, 1);
  M('57/01 e<->e        ', 1);
  ReadEms(H1, 4, 0, 5000); c := CrcMem(BufB, 5000);
  ReadEms(H2, 0, 1, 5000); T('  crc=' + Hex(c, 8) + ' ' + Hex(CrcMem(BufB, 5000), 8));
  Do57(2); T('57/02              ' + St);
end;

procedure TestRealloc;
var ok: Boolean; p: Integer; free0: Word;
begin
  Ems($4200); free0 := R.BX;
  R.DX := H2; R.BX := 10; Ems($5100); T('51 H2 3->10        ' + St + ' BX=' + Dec2(R.BX));
  Ems($4200); T('  free delta ' + Dec2(LongInt(free0) - R.BX));
  ok := True;
  for p := 0 to 2 do begin Map(0, p, H2); if not CheckWin(0, PageTag(H2, p)) then ok := False; end;
  for p := 3 to 9 do begin
    if Map(p and 3, p, H2) <> 0 then ok := False;
    FillWin(p and 3, PageTag(H2, p));
  end;
  for p := 0 to 9 do begin Map(0, p, H2); if not CheckWin(0, PageTag(H2, p)) then ok := False; end;
  T('  kept+new pages ' + Hex(Ord(ok), 1));
  Must(ok, '51 grow kept the old pages');
  { H1 must be untouched by H2 growing }
  ok := True;
  for p := 0 to BIGPAGES - 1 do begin Map(1, p, H1); if not CheckWin(1, PageTag(H1, p)) then ok := False; end;
  T('  H1 intact ' + Hex(Ord(ok), 1));
  Must(ok, '51 grow disturbed another handle');
  R.DX := H2; R.BX := 4; Ems($5100); T('51 H2 10->4        ' + St + ' BX=' + Dec2(R.BX));
  ok := True;
  for p := 0 to 3 do begin Map(0, p, H2); if not CheckWin(0, PageTag(H2, p)) then ok := False; end;
  T('  kept pages ' + Hex(Ord(ok), 1) + ' page 4 AH=' + Hex(Map(0, 4, H2), 2));
  Must(ok, '51 shrink kept the low pages');
  R.DX := H2; R.BX := 0; Ems($5100); T('51 H2 ->0          ' + St + ' BX=' + Dec2(R.BX));
  R.DX := H2; Ems($4C00); T('  4C              ' + St + ' BX=' + Dec2(R.BX));
  R.DX := H2; R.BX := 3; Ems($5100); T('51 H2 0->3         ' + St + ' BX=' + Dec2(R.BX));
  for p := 0 to 2 do begin Map(p, p, H2); FillWin(p, PageTag(H2, p)); end;
  R.DX := H2; R.BX := 9999; Ems($5100); T('51 H2 ->9999       ' + St + ' BX=' + Dec2(R.BX));
  R.DX := 99; R.BX := 1; Ems($5100); T('51 handle 99       ' + St);
  ok := True;
  for p := 0 to BIGPAGES - 1 do begin Map(1, p, H1); if not CheckWin(1, PageTag(H1, p)) then ok := False; end;
  T('  H1 intact ' + Hex(Ord(ok), 1));
  Must(ok, '51 disturbed another handle');
end;

procedure TestNames;
const N1: array[0..7] of Char = 'EMSTEST1';
      N2: array[0..7] of Char = 'EMSTEST2';
var i: Integer;
begin
  R.DX := H1; R.DS := Seg(N1); R.SI := Ofs(N1); Ems($5301); T('53/01 name H1      ' + St);
  R.DX := H2; R.DS := Seg(N1); R.SI := Ofs(N1); Ems($5301); T('53/01 dup name     ' + St);
  R.DX := H2; R.DS := Seg(N2); R.SI := Ofs(N2); Ems($5301); T('53/01 name H2      ' + St);
  FillChar(BufA^, 16, 0);
  R.DX := H1; R.ES := Seg(BufA^); R.DI := Ofs(BufA^); Ems($5300);
  T('53/00 get H1       ' + St + ' ' + Hex(CrcMem(BufA, 8), 8));
  R.DS := Seg(N2); R.SI := Ofs(N2); Ems($5401); T('54/01 find N2      ' + St + ' same=' + Hex(Ord(R.DX = H2), 1));
  R.DS := Seg(Pairs); R.SI := Ofs(Pairs); FillChar(Pairs, 8, $41); Ems($5401);
  T('54/01 find none    ' + St);
  Ems($5402); T('54/02 total        ' + St + ' BX=' + Dec2(R.BX));
  R.ES := Seg(BufA^); R.DI := Ofs(BufA^); Ems($5400); T('54/00 dir          ' + St + ' AL=' + Dec2(R.AL - 2));
  Ems($5403); T('54/03              ' + St);
  R.ES := Seg(BufA^); R.DI := Ofs(BufA^); Ems($4D00);
  T('4D all handles     ' + St + ' BX=' + Dec2(R.BX - 2));
  R.DX := H1; Ems($5200); T('52/00 attr H1      ' + St + ' AL=' + Hex(R.AL, 2));
  R.DX := H1; R.BX := 1; Ems($5201); T('52/01 set attr     ' + St);
  Ems($5202); T('52/02 capability   ' + St + ' AL=' + Hex(R.AL, 2));
  R.ES := Seg(BufA^); R.DI := Ofs(BufA^); Ems($5800);
  T('58/00 mappable     ' + St + ' CX=' + Dec2(R.CX) + ' crc=' + Hex(CrcMem(BufA, 16), 8));
  Ems($5801); T('58/01              ' + St + ' CX=' + Dec2(R.CX));
  R.ES := Seg(BufA^); R.DI := Ofs(BufA^); Ems($5900);
  T('59/00 hardware     ' + St + ' crc=' + Hex(CrcMem(BufA, 10), 8));
  Ems($5901); T('59/01 raw pages    ' + St);
  Ems($5B02); T('5B/02 alt size     ' + St + ' DX=' + Dec2(R.DX));
  i := 0;
end;

procedure TestFree;
begin
  R.DX := H1; Ems($4500); T('45 free H1         ' + St);
  R.DX := H1; Ems($4500); T('45 free H1 again   ' + St);
  R.DX := H2; Ems($4500); T('45 free H2         ' + St);
  Ems($4B00); T('4B handles         ' + St);
end;

{ ---------------------------------------------------------- benchmark }

var
  BHnd: Word;           { handle for the timed loops }
  BP0, BP1: Word;      { two logical pages }
  BFn: Word;

{ One batch of 64 calls of the same INT 67h function.  Assembly, so the
  loop costs a few clocks against the several hundred of the call. }
procedure Batch44Alt; assembler;
asm
  mov  cx, 32
@l:
  mov  ax, 4400h
  mov  bx, BP0
  mov  dx, BHnd
  int  67h
  mov  ax, 4400h
  mov  bx, BP1
  mov  dx, BHnd
  int  67h
  loop @l
end;

procedure Batch44Same; assembler;
asm
  mov  cx, 64
@l:
  mov  ax, 4400h
  mov  bx, BP0
  mov  dx, BHnd
  int  67h
  loop @l
end;

procedure Batch40; assembler;
asm
  mov  cx, 64
@l:
  mov  ax, 4000h
  int  67h
  loop @l
end;

procedure Batch50; assembler;
asm
  mov  bx, 16
@l:
  push bx
  mov  ax, 5000h
  mov  cx, 4
  mov  dx, BHnd
  mov  si, offset Pairs
  int  67h
  mov  ax, 5000h
  mov  cx, 4
  mov  dx, BHnd
  mov  si, offset Pairs + 16
  int  67h
  pop  bx
  dec  bx
  jnz  @l
end;

procedure Batch4E; assembler;
asm
  push es
  push ds
  pop  es
  mov  cx, 32
@l:
  push cx
  mov  ax, 4E00h
  mov  di, offset Pairs
  int  67h
  mov  ax, 4E01h
  mov  si, offset Pairs
  int  67h
  pop  cx
  loop @l
  pop  es
end;

procedure Batch4748; assembler;
asm
  mov  cx, 32
@l:
  mov  ax, 4700h
  mov  dx, BHnd
  int  67h
  mov  ax, 4800h
  mov  dx, BHnd
  int  67h
  loop @l
end;

procedure Batch57; assembler;
asm
  mov  cx, 4
@l:
  push cx
  mov  ax, BFn
  mov  si, offset Mv
  int  67h
  pop  cx
  loop @l
end;

type TBatch = procedure;

{ run batches for 'secs' seconds of ticks, return calls per second }
function Rate(b: TBatch; perBatch: Word): LongInt;
const TK = 36;         { two seconds }
var t0, t: Word; n: LongInt;
begin
  n := 0;
  t0 := Ticks;
  repeat t := Ticks until t <> t0;           { start on a tick edge }
  t0 := t;
  repeat
    b;
    Inc(n, perBatch);
    t := Ticks;
  until Word(t - t0) >= TK;
  Rate := n * 182 div (Word(t - t0) * 10);
  Beat;
end;

procedure Bench;
var rt: LongInt;
begin
  WriteLn;
  WriteLn('benchmark: calls per second, 2 s each');
  R.BX := 8; Ems($4300);
  if R.AH <> 0 then begin WriteLn('  no EMS for the benchmark, AH=', Hex(R.AH, 2)); Exit; end;
  BHnd := R.DX; BP0 := 0; BP1 := 1;
  Pairs[0].a := 0; Pairs[0].b := 0; Pairs[1].a := 1; Pairs[1].b := 1;
  Pairs[2].a := 2; Pairs[2].b := 2; Pairs[3].a := 3; Pairs[3].b := 3;
  Pairs[4].a := 4; Pairs[4].b := 0; Pairs[5].a := 5; Pairs[5].b := 1;
  Pairs[6].a := 6; Pairs[6].b := 2; Pairs[7].a := 7; Pairs[7].b := 3;

  WriteLn('  40   status (dispatch only)  ', Rate(@Batch40, 64):7);
  WriteLn('  44   map, page changes       ', Rate(@Batch44Alt, 64):7);
  WriteLn('  44   map, same page          ', Rate(@Batch44Same, 64):7);
  WriteLn('  50   map 4 pages at once     ', Rate(@Batch50, 32):7);
  WriteLn('  4E   get+set page map, pair  ', Rate(@Batch4E, 32):7);
  WriteLn('  47   save+restore, pair      ', Rate(@Batch4748, 32):7);

  FillChar(Mv, SizeOf(Mv), 0);
  Mv.len := 16384; SetConv(Mv, False, BufA); SetExp(Mv, True, BHnd, 2, 0);
  BFn := $5700; rt := Rate(@Batch57, 4);
  WriteLn('  57   move 16K conv->EMS      ', rt:7, '   = ', rt * 16, ' KB/s');
  SetExp(Mv, False, BHnd, 2, 0); SetConv(Mv, True, BufA);
  rt := Rate(@Batch57, 4);
  WriteLn('  57   move 16K EMS->conv      ', rt:7, '   = ', rt * 16, ' KB/s');
  SetExp(Mv, False, BHnd, 2, 0); SetExp(Mv, True, BHnd, 5, 0);
  rt := Rate(@Batch57, 4);
  WriteLn('  57   move 16K EMS->EMS       ', rt:7, '   = ', rt * 16, ' KB/s');
  SetConv(Mv, False, BufA); SetExp(Mv, True, BHnd, 2, 0);
  BFn := $5701; rt := Rate(@Batch57, 4);
  WriteLn('  57   exchange 16K conv<->EMS ', rt:7, '   = ', rt * 16, ' KB/s');
  SetConv(Mv, False, BufA); SetConv(Mv, True, BufB);
  BFn := $5700; rt := Rate(@Batch57, 4);
  WriteLn('  57   move 16K conv->conv     ', rt:7, '   = ', rt * 16, ' KB/s');
  Mv.len := 16383; SetConv(Mv, False, @BufA^[1]); SetExp(Mv, True, BHnd, 2, 1);
  rt := Rate(@Batch57, 4);
  WriteLn('  57   move 16383 odd c->EMS   ', rt:7, '   = ', rt * 16, ' KB/s');

  R.DX := BHnd; Ems($4500);
end;

{ ---------------------------------------------------------------- main }

function DriverPresent: Boolean;
const Name: array[0..7] of Char = 'EMMXXXX0';
var v: Pointer; p: ^Byte; i: Integer;
begin
  GetIntVec($67, v);
  DriverPresent := False;
  if v = nil then Exit;
  p := Ptr(Seg(v^), 10);
  for i := 0 to 7 do begin
    if Char(p^) <> Name[i] then Exit;
    Inc(p);
  end;
  DriverPresent := True;
end;

var
  i: Integer; s: string; v: Pointer;
begin
  WriteLn('EMSTEST ', VER, ' -- EMS behaviour and speed -- StevenC & Claude');
  DoTest := True; DoBench := True;
  for i := 1 to ParamCount do begin
    s := ParamStr(i);
    if (s = '/T') or (s = '/t') or (s = '-t') then DoBench := False;
    if (s = '/B') or (s = '/b') or (s = '-b') then DoTest := False;
  end;
  if not DriverPresent then begin
    WriteLn('no EMS driver (no EMMXXXX0 at the INT 67h segment)');
    Halt(1);
  end;
  GetIntVec($67, v);
  WriteLn('INT 67h -> ', Hex(Seg(v^), 4), ':', Hex(Ofs(v^), 4));
  InitCrc;
  New(BufA); New(BufB);
  Ems($4100); Frame := R.BX;
  Ems($4200);
  if R.BX < BIGPAGES + 16 then begin
    WriteLn('only ', R.BX, ' free pages; need ', BIGPAGES + 16);
    Halt(2);
  end;
  TransCrc := 0; Fails := 0;
  if DoTest then begin
    WriteLn('--- behaviour: this part should be identical between drivers ---');
    TestBasics; TestMap; TestMap50; TestMapSave; TestRealloc;
    TestMove; TestNames; TestFree;
    WriteLn('--- transcript crc ', Hex(TransCrc, 8), '   data checks failed: ', Fails, ' ---');
  end;
  if DoBench then Bench;
  if Fails > 0 then Halt(3);
end.
