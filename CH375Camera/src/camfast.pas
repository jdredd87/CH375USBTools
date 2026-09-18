unit camfast;
{ CAMFAST -- the per-pixel work of drawing a camera picture, in assembly.
  CH375Camera, StevenC.  Public domain (the Unlicense).

  WHY.  CAMLIVE's first renderer was plain Pascal, and it spent 160 us a
  pixel -- 25 s to put one 320x240 picture on the screen in mode X, when
  the camera had taken it in 1.7.  That is not a slow algorithm; it is
  this CPU running compiled 16-bit code.  BENCH on this machine measures
  an array store at 15 us.  The raycaster found the same thing
  (docs/raycast.md): the inner loops are assembly or they are slow.

  HOW IT IS SHAPED.  Every routine works on the fixed buffers below, which
  are globals and so live in the data segment with the tables -- one
  segment, DS, for everything, and no far pointers in the loops.  The
  caller copies the two source rows in (Move is a string instruction and
  cheap), calls one step at a time, and copies the result out.  Each step
  is one simple loop, easy to check against the Pascal it replaced, which
  FASTTEST does on the machine itself. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

const
  FMAX = 360;

var
  { inputs: two picture rows (a Bayer 2x2 needs both), or Y and the
    chroma for the YUV mode.  One spare byte past the end, which the
    caller fills, so the last pixel's 2x2 has a right-hand neighbour. }
  FA, FC:     array[0..FMAX + 1] of Byte;
  FU, FV:     array[0..FMAX div 2 + 1] of Byte;
  { intermediate and output }
  FR, FG, FB: array[0..FMAX] of Byte;
  FQ, FQ2:    array[0..FMAX] of Byte;
  FL, FL2:    array[0..1279] of Byte;       { expanded screen rows }

  { tables, filled by the caller }
  SLutR, SLutG, SLutB: array[0..255] of Byte;        { contrast stretch }
  { four dither phases: [row parity * 2 + column parity] }
  CubeR, CubeG, CubeB: array[0..3, 0..255] of Byte;
  GQt:        array[0..3, 0..255] of Byte;           { grey steps }
  N16t:       array[0..4095] of Byte;                { text colours }
  YRV, YGU, YGV, YBU: array[0..255] of Integer;
  ClipT:      array[0..767] of Byte;                 { Clip(v) = ClipT[v+256] }

{ Bayer: FA/FC -> FR/FG/FB.  RIe/BIe say which corner of a 2x2 starting on
  an even column is red and which blue (0 a, 1 a+1, 2 c, 3 c+1); RIo/BIo
  the same for an odd column. }
procedure BayerRGB(N: Word; RIe, BIe, RIo, BIo: Byte);
{ Bayer: FA/FC -> FG as the 2x2 mean. }
procedure BayerGrey(N: Word);
{ YUV: FA is Y, FU/FV the chroma for pixel pairs, first pixel even.
  -> FR/FG/FB }
procedure YuvRGB(N: Word);

{ Bayer, one sample per 2x2 CELL every Stride pixels (Stride even): the
  cell at FA/FC[k*Stride].  Cells start on even columns, so red and blue
  are always the same corners -- RI and BI, 0..3 as above. }
procedure BayerCellRGB(N, Stride: Word; RI, BI: Byte);
procedure BayerCellGrey(N, Stride: Word);

{ FR/FG/FB -> FQ: SLut per channel, then the cube; the dither phase
  follows the column, and Row (0 or 1) picks the other pair of phases on
  odd rows. }
procedure QuantCube(N, Row: Word);
{ FG -> FQ: SLutG then GQt, dithered the same way. }
procedure QuantGrey(N, Row: Word);
{ FR/FG/FB -> FQ: SLut per channel, then the 16-colour table. }
procedure Quant16(N: Word);

{ The same two quantisers with the dither phase for even and odd columns
  given outright (0..3 each), writing to FQ, or to FQ2 with ToQ2. }
procedure QuantCubeP(N, PhE, PhO: Word; ToQ2: Boolean);
procedure QuantGreyP(N, PhE, PhO: Word; ToQ2: Boolean);

{ FQ -> FL, each value S times. }
procedure Expand(N, S: Word);

{ FQ and FQ2 -> FL, each value S times, taking FQ on even screen columns
  and FQ2 on odd ones -- or the other way round with Swap.  With FQ and
  FQ2 quantised at two dither thresholds, that is a dither at SCREEN
  resolution even when one sample covers a block of pixels. }
procedure Expand2(N, S: Word; Swap: Boolean; ToFL2: Boolean = False);

{ FL[0..N-1] (or FL2) to mode X at (X, Y); X a multiple of 4. }
procedure ModeXRow(X, Y, N: Word; FromFL2: Boolean = False);

procedure BuildClip;

implementation

procedure BuildClip;
var I: Integer;
begin
  for I := 0 to 767 do
    if I < 256 then ClipT[I] := 0
    else if I > 511 then ClipT[I] := 255
    else ClipT[I] := I - 256;
end;

procedure BayerGrey(N: Word); assembler;
asm
  mov  cx, N
  jcxz @out
  xor  bx, bx
@lp:
  xor  ax, ax
  xor  dx, dx
  mov  al, byte ptr FA[bx]
  mov  dl, byte ptr FA[bx+1]
  add  ax, dx
  mov  dl, byte ptr FC[bx]
  add  ax, dx
  mov  dl, byte ptr FC[bx+1]
  add  ax, dx
  shr  ax, 1
  shr  ax, 1
  mov  byte ptr FG[bx], al
  inc  bx
  loop @lp
@out:
end;

{ Red and blue each come from one corner of the 2x2, and which corner
  depends only on whether the block starts on an even or an odd column --
  so the four corner ADDRESSES are worked out once, and the loop picks a
  pair by parity.  Green is what is left of the four-pixel sum, halved. }
function CornerAddr(C: Byte): Word;
begin
  case C of
    0: CornerAddr := Ofs(FA);
    1: CornerAddr := Ofs(FA) + 1;
    2: CornerAddr := Ofs(FC);
  else CornerAddr := Ofs(FC) + 1;
  end;
end;

procedure BayerRGB(N: Word; RIe, BIe, RIo, BIo: Byte);
var RBe, BBe, RBo, BBo: Word;
begin
  RBe := CornerAddr(RIe); BBe := CornerAddr(BIe);
  RBo := CornerAddr(RIo); BBo := CornerAddr(BIo);
  asm
    mov  cx, N
    jcxz @out
    xor  bx, bx
  @lp:
    xor  ax, ax
    xor  dx, dx
    mov  al, byte ptr FA[bx]
    mov  dl, byte ptr FA[bx+1]
    add  ax, dx
    mov  dl, byte ptr FC[bx]
    add  ax, dx
    mov  dl, byte ptr FC[bx+1]
    add  ax, dx
    test bl, 1
    jnz  @odd
    mov  si, RBe
    mov  di, BBe
    jmp  @go
  @odd:
    mov  si, RBo
    mov  di, BBo
  @go:
    mov  dl, [si+bx]
    mov  byte ptr FR[bx], dl
    sub  ax, dx
    mov  dl, [di+bx]
    mov  byte ptr FB[bx], dl
    sub  ax, dx
    shr  ax, 1
    mov  byte ptr FG[bx], al
    inc  bx
    loop @lp
  @out:
  end;
end;

var
  YK, YN: Word;

{ One pixel's Y plus its pair's U and V, through the tables and the clip
  table.  Every index register is spoken for, so the pixel counter lives
  in memory.  The sums stay inside the clip table: red Y+YRV runs -180 to
  433, green -134 to 390, blue -227 to 480, all within -256..511. }
procedure YuvRGB(N: Word);
begin
  YN := N;
  if YN = 0 then Exit;
  YK := 0;
  asm
  @lp:
    mov  bx, YK
    mov  si, bx
    shr  si, 1
    xor  ax, ax
    mov  al, byte ptr FV[si]
    shl  ax, 1
    mov  di, ax
    xor  ax, ax
    mov  al, byte ptr FU[si]
    shl  ax, 1
    mov  si, ax
    xor  dx, dx
    mov  dl, byte ptr FA[bx]
    mov  ax, dx
    add  ax, word ptr YRV[di]
    add  ax, 256
    mov  bx, ax
    mov  al, byte ptr ClipT[bx]
    mov  bx, YK
    mov  byte ptr FR[bx], al
    mov  ax, dx
    sub  ax, word ptr YGU[si]
    sub  ax, word ptr YGV[di]
    add  ax, 256
    mov  bx, ax
    mov  al, byte ptr ClipT[bx]
    mov  bx, YK
    mov  byte ptr FG[bx], al
    mov  ax, dx
    add  ax, word ptr YBU[si]
    add  ax, 256
    mov  bx, ax
    mov  al, byte ptr ClipT[bx]
    mov  bx, YK
    mov  byte ptr FB[bx], al
    inc  bx
    mov  YK, bx
    cmp  bx, YN
    jb   @lp
  end;
end;

procedure BayerCellGrey(N, Stride: Word); assembler;
asm
  mov  cx, N
  jcxz @out
  xor  bx, bx                  { source index }
  xor  di, di                  { output index }
  mov  si, Stride
@lp:
  xor  ax, ax
  xor  dx, dx
  mov  al, byte ptr FA[bx]
  mov  dl, byte ptr FA[bx+1]
  add  ax, dx
  mov  dl, byte ptr FC[bx]
  add  ax, dx
  mov  dl, byte ptr FC[bx+1]
  add  ax, dx
  shr  ax, 1
  shr  ax, 1
  mov  byte ptr FG[di], al
  add  bx, si
  inc  di
  loop @lp
@out:
end;

procedure BayerCellRGB(N, Stride: Word; RI, BI: Byte);
var RA, BA, Str: Word;
begin
  RA := CornerAddr(RI); BA := CornerAddr(BI); Str := Stride;
  asm
    mov  cx, N
    jcxz @out
    xor  bx, bx
    xor  di, di
  @lp:
    xor  ax, ax
    xor  dx, dx
    mov  al, byte ptr FA[bx]
    mov  dl, byte ptr FA[bx+1]
    add  ax, dx
    mov  dl, byte ptr FC[bx]
    add  ax, dx
    mov  dl, byte ptr FC[bx+1]
    add  ax, dx
    mov  si, RA
    mov  dl, [si+bx]
    mov  byte ptr FR[di], dl
    sub  ax, dx
    mov  si, BA
    mov  dl, [si+bx]
    mov  byte ptr FB[di], dl
    sub  ax, dx
    shr  ax, 1
    mov  byte ptr FG[di], al
    add  bx, Str
    inc  di
    loop @lp
  @out:
  end;
end;

var
  QBase, QDelta, QDst: Word;

procedure QuantGreyP(N, PhE, PhO: Word; ToQ2: Boolean);
begin
  QBase := PhE shl 8;
  QDelta := (PhE xor PhO) shl 8;
  if ToQ2 then QDst := Ofs(FQ2) else QDst := Ofs(FQ);
  asm
    mov  cx, N
    jcxz @out
    xor  si, si
    mov  dx, QBase
    mov  di, QDst
  @lp:
    xor  bx, bx
    mov  bl, byte ptr FG[si]
    mov  bl, byte ptr SLutG[bx]
    add  bx, dx
    mov  al, byte ptr GQt[bx]
    mov  [di], al
    inc  si
    inc  di
    xor  dx, QDelta
    loop @lp
  @out:
  end;
end;

procedure QuantCubeP(N, PhE, PhO: Word; ToQ2: Boolean);
begin
  QBase := PhE shl 8;
  QDelta := (PhE xor PhO) shl 8;
  if ToQ2 then QDst := Ofs(FQ2) else QDst := Ofs(FQ);
  asm
    mov  cx, N
    jcxz @out
    xor  si, si
    mov  dx, QBase
    mov  di, QDst
  @lp:
    xor  bx, bx
    mov  bl, byte ptr FR[si]
    mov  bl, byte ptr SLutR[bx]
    add  bx, dx
    mov  al, byte ptr CubeR[bx]
    xor  bx, bx
    mov  bl, byte ptr FG[si]
    mov  bl, byte ptr SLutG[bx]
    add  bx, dx
    add  al, byte ptr CubeG[bx]
    xor  bx, bx
    mov  bl, byte ptr FB[si]
    mov  bl, byte ptr SLutB[bx]
    add  bx, dx
    add  al, byte ptr CubeB[bx]
    mov  [di], al
    inc  si
    inc  di
    xor  dx, QDelta
    loop @lp
  @out:
  end;
end;

procedure QuantGrey(N, Row: Word); assembler;
asm
  mov  cx, N
  jcxz @out
  xor  si, si
  mov  dx, Row                 { 0 or 512, then +256 on odd columns }
  and  dx, 1
  mov  ax, dx
  mov  dh, al
  shl  dh, 1                   { dx = Row*512 }
  xor  dl, dl
@lp:
  xor  bx, bx
  mov  bl, byte ptr FG[si]
  mov  bl, byte ptr SLutG[bx]
  add  bx, dx
  mov  al, byte ptr GQt[bx]
  mov  byte ptr FQ[si], al
  inc  si
  xor  dx, 256
  loop @lp
@out:
end;

procedure QuantCube(N, Row: Word); assembler;
asm
  mov  cx, N
  jcxz @out
  xor  si, si
  mov  dx, Row
  and  dx, 1
  mov  ax, dx
  mov  dh, al
  shl  dh, 1                   { dx = Row*512 }
  xor  dl, dl
@lp:
  xor  bx, bx
  mov  bl, byte ptr FR[si]
  mov  bl, byte ptr SLutR[bx]
  add  bx, dx
  mov  al, byte ptr CubeR[bx]
  xor  bx, bx
  mov  bl, byte ptr FG[si]
  mov  bl, byte ptr SLutG[bx]
  add  bx, dx
  add  al, byte ptr CubeG[bx]
  xor  bx, bx
  mov  bl, byte ptr FB[si]
  mov  bl, byte ptr SLutB[bx]
  add  bx, dx
  add  al, byte ptr CubeB[bx]
  mov  byte ptr FQ[si], al
  inc  si
  xor  dx, 256
  loop @lp
@out:
end;

{ index = ((R and F0h) shl 4) or (G and F0h) or (B shr 4) }
procedure Quant16(N: Word); assembler;
asm
  mov  cx, N
  jcxz @out
  xor  si, si
@lp:
  xor  bx, bx
  mov  bl, byte ptr FR[si]
  mov  al, byte ptr SLutR[bx]
  and  al, 0F0h
  xor  ah, ah
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  shl  ax, 1
  mov  dx, ax
  mov  bl, byte ptr FG[si]
  mov  al, byte ptr SLutG[bx]
  and  al, 0F0h
  or   dl, al
  mov  bl, byte ptr FB[si]
  mov  al, byte ptr SLutB[bx]
  shr  al, 1
  shr  al, 1
  shr  al, 1
  shr  al, 1
  or   dl, al
  mov  bx, dx
  mov  al, byte ptr N16t[bx]
  mov  byte ptr FQ[si], al
  inc  si
  loop @lp
@out:
end;

procedure Expand(N, S: Word);
begin
  if S = 1 then begin Move(FQ, FL, N); Exit; end;
  asm
    mov  cx, N
    jcxz @out
    push es
    push ds
    pop  es
    lea  si, FQ
    lea  di, FL
    mov  dx, S
    cld
  @lp:
    lodsb
    push cx
    mov  cx, dx
    rep  stosb
    pop  cx
    loop @lp
    pop  es
  @out:
  end;
end;

{ An even S is the common case (x2, x4) and each sample is then the same
  two-byte pair repeated, so it is one REP STOSW.  Odd S goes a byte at a
  time.  Measured: the byte loop on every screen row made a VESA picture
  take 9 s instead of 5. }
procedure Expand2(N, S: Word; Swap: Boolean; ToFL2: Boolean = False);
var T, Dst, Half, OddS: Word;
begin
  if Swap then T := 1 else T := 0;
  if ToFL2 then Dst := Ofs(FL2) else Dst := Ofs(FL);
  Half := S shr 1;
  if S and 1 = 1 then
  begin
    { odd S: S-1 bytes as words, then one more byte of the phase the run
      began with -- which flips the next sample's starting phase }
    OddS := S;
    asm
      mov  cx, N
      jcxz @out
      push es
      push ds
      pop  es
      xor  si, si
      mov  di, Dst
      mov  dx, T
      cld
    @k:
      mov  al, byte ptr FQ[si]
      mov  ah, byte ptr FQ2[si]
      test dl, 1
      jz   @keep
      xchg al, ah
    @keep:
      push cx
      mov  cx, Half
      rep  stosw
      stosb
      pop  cx
      mov  bx, OddS
      and  bx, 1
      xor  dx, bx
      inc  si
      loop @k
      pop  es
    @out:
    end;
    Exit;
  end;
  if S and 1 = 0 then
  begin
    asm
      mov  cx, N
      jcxz @out
      push es
      push ds
      pop  es
      xor  si, si
      mov  di, Dst
      cld
    @k:
      mov  al, byte ptr FQ[si]
      mov  ah, byte ptr FQ2[si]
      test T, 1
      jz   @keep
      xchg al, ah
    @keep:
      push cx
      mov  cx, Half
      rep  stosw
      pop  cx
      inc  si
      loop @k
      pop  es
    @out:
    end;
    Exit;
  end;
  asm
    mov  cx, N
    jcxz @out
    xor  si, si
    mov  di, Dst
    mov  dx, T                   { bit 0: 1 = take FQ2 next }
  @k:
    mov  bl, byte ptr FQ[si]
    mov  bh, byte ptr FQ2[si]
    push cx
    mov  cx, S
  @j:
    mov  al, bl
    test dl, 1
    jz   @put
    mov  al, bh
  @put:
    mov  [di], al
    inc  di
    xor  dl, 1
    loop @j
    pop  cx
    inc  si
    loop @k
  @out:
  end;
end;

procedure ModeXRow(X, Y, N: Word; FromFL2: Boolean = False);
var
  Pl, Base, Cnt, Src, Buf: Word;
begin
  if FromFL2 then Buf := Ofs(FL2) else Buf := Ofs(FL);
  Base := Y * 80 + X shr 2;
  for Pl := 0 to 3 do
  begin
    if Pl >= N then Break;
    Cnt := (N - Pl + 3) shr 2;
    Src := Pl;
    asm
      mov  dx, 3C4h
      mov  al, 2
      out  dx, al
      inc  dx
      mov  cl, byte ptr Pl
      mov  al, 1
      shl  al, cl
      out  dx, al
      push es
      mov  ax, 0A000h
      mov  es, ax
      mov  di, Base
      mov  si, Src
      add  si, Buf
      mov  cx, Cnt
    @lp:
      mov  al, [si]
      mov  es:[di], al
      add  si, 4
      inc  di
      loop @lp
      pop  es
    end;
  end;
end;

begin
  BuildClip;
end.
