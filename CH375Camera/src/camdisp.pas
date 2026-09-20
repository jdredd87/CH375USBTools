unit camdisp;
{ CAMDISP -- every way this machine can put a camera picture on its
  screen.  CH375Camera, StevenC.  Public domain (the Unlicense).

  The camera gives 176x144, 320x240 or 352x288; the screen can be any of

      VESA   640x480x256   VBE mode 101h -- only on the boots when the
                           card reports its full 1 MB (docs/graphics.md)
      X      320x240x256   mode X, unchained -- on every VGA, and exactly
                           the camera's 320x240
      13     320x200x256   mode 13h, the one that always works
      12     640x480x16    mode 12h, 16 greys; on every VGA
      T50    80x50 text    half-block cells: 80x100 "pixels"
      T25    80x25 text    half-block cells: 80x50
      ASCII  80x50 / 80x25 characters by brightness, no colour at all

  The graphics modes take palette indices -- 64 greys at 0..63, or the
  216-colour cube, R*36 + G*6 + B -- and show the picture at the largest whole-number
  scale that fits, centred.  The text modes take 16 colours per half-cell,
  from a palette this unit programs: 16 greys, or a 16-colour set.

  THE TEXT MODES ARE THE FAST ONES.  80x100 is 8000 picture samples,
  against 76800 for a 320x240 picture at 1:1, and writing a character
  cell is one word.  They are how the picture can be followed while it is
  still being taken, and they work on the mono card this machine sometimes
  boots with (mode 7, at B000). }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

type
  TDisp = (dAuto, dVesa, dModeX, d13, d12, dT50, dT25, dAscii);

const
  DispName: array[TDisp] of string[5] =
    ('AUTO', 'VESA', 'X', '13', '12', 'T50', 'T25', 'ASCII');

  { palette indices shared by every graphics mode }
  C_BACK = 254;
  C_TEXT = 255;

var
  Disp:     TDisp = dAuto;
  ScrW, ScrH: Integer;          { pixel grid: for text, cells x2 high }
  TextMode: Boolean;            { cells, not pixels }
  Mono:     Boolean;            { the card came up mono (mode 7) }
  Levels:   Integer;            { distinct values a pixel can take }
  VesaWhy:  string[40] = '';    { why VESA was not used }

{ Open display K (dAuto picks the best available).  Colour selects the
  palette: grey ramp or colour set.  False if K cannot be had. }
function  DispOpen(K: TDisp; Colour: Boolean): Boolean;
procedure DispClose;

{ A row of N pixel values at (X, Y) on the pixel grid.  Values are palette
  indices in the graphics modes; 0..15 in the text modes (a grey level or
  a colour of the 16-colour set); 0..9 in ASCII (a brightness step). }
procedure PutRow(X, Y: Integer; const Src; N: Word);

{ The row last given to PutRow, again at another Y -- the scaled modes
  repeat every row, and in mode 12h the conversion is the cost. }
procedure PutRowAgain(Y: Integer; const Src; X: Integer; N: Word);

{ A line of status text in the top-left corner, in whatever the mode
  allows. }
procedure Status(const S: ShortString);

{ The ASCII picture as it stands, for printing to stdout at the begin
  Move(Set16, Pal16, SizeOf(Pal16));
end. }
function AsciiRow(Y: Integer): ShortString;

{ Nearest of the current 16 text colours to an RGB value (0..255 each). }
function Nearest16(R, G, B: Byte): Byte;

{ Load 16 text colours (6-bit DAC values).  Nearest16 follows.  A
  palette chosen per picture by median cut was tried and removed: the
  small bright things -- the thing being photographed, usually -- lost
  their colour to the large dull areas, and a full nearest-colour table
  cannot be rebuilt per picture on this CPU. }
procedure LoadText16(const P: array of Byte);

{ The 16-colour set, as 6-bit DAC values. }
const
  Set16: array[0..15, 0..2] of Byte = (
    (0, 0, 0),    (0, 0, 42),   (0, 42, 0),   (0, 42, 42),
    (42, 0, 0),   (42, 0, 42),  (42, 21, 0),  (42, 42, 42),
    (21, 21, 21), (21, 21, 63), (21, 63, 21), (21, 63, 63),
    (63, 21, 21), (63, 21, 63), (63, 63, 21), (63, 63, 63));

var
  { the 16 text colours as they stand; starts as Set16 }
  Pal16: array[0..15, 0..2] of Byte;

implementation

uses ch375, vidfix;   { vidfix: FPC's runtime can hook INT 10h with a coprocessor stub,
                           which wedges a 386 that has no 387 on the first video
                           call. Inert on a V30 and on anything with an FPU. }

var
  TxtDac: array[0..15] of Byte;     { DAC entry behind each text colour }

type
  TModeInfo = packed record
    Attributes     : Word;
    WinAAttr       : Byte;
    WinBAttr       : Byte;
    WinGranularity : Word;
    WinSize        : Word;
    WinASeg        : Word;
    WinBSeg        : Word;
    WinFuncPtr     : LongInt;
    BytesPerLine   : Word;
    Filler         : array[0..237] of Byte;
  end;

var
  OldMode:  Byte;
  MInfo:    TModeInfo;
  Pitch:    Word;
  GranB:    LongInt;
  CurBank:  Integer = -1;
  TextSeg:  Word = $B800;
  Cols, Rows: Integer;
  { The text modes keep the picture's half-cells here, so a cell can be
    rebuilt when only one of its halves changes. }
  Cell:     array[0..99, 0..79] of Byte;
  FontSeg, FontOfs: Word;

const
  Ramp: string[10] = ' .:-=+*#%@';

{ ---- BIOS ---- }

function GetMode: Byte; assembler;
asm
  mov ah, 0Fh
  int 10h
end;

procedure BiosMode(M: Byte); assembler;
asm
  xor ah, ah
  mov al, M
  int 10h
end;

procedure SetDac(I, R, G, B: Byte);
begin
  OutB($3C8, I);
  OutB($3C9, R); OutB($3C9, G); OutB($3C9, B);
end;

procedure FindFont;
var S, O: Word;
begin
  asm
    push bp
    push es
    mov  ax, 1130h
    mov  bh, 3
    int  10h
    mov  ax, bp
    mov  dx, es
    pop  es
    pop  bp
    mov  O, ax
    mov  S, dx
  end;
  FontSeg := S; FontOfs := O;
end;

{ ---- VESA ---- }

function VbeInfo(M: Word): Word;
var S, O, R: Word;
begin
  S := Seg(MInfo); O := Ofs(MInfo);
  asm
    push es
    mov  ax, S
    mov  es, ax
    mov  di, O
    mov  cx, M
    mov  ax, 4F01h
    int  10h
    pop  es
    mov  R, ax
  end;
  VbeInfo := R;
end;

function VbeSet(M: Word): Word;
var R: Word;
begin
  asm
    mov ax, 4F02h
    mov bx, M
    int 10h
    mov R, ax
  end;
  VbeSet := R;
end;

function TryVesa: Boolean;
begin
  TryVesa := False;
  FillChar(MInfo, SizeOf(MInfo), 0);
  if VbeInfo($101) <> $004F then begin VesaWhy := 'mode 101h not offered this boot'; Exit; end;
  if (MInfo.Attributes and 1) = 0 then begin VesaWhy := 'mode 101h not supported'; Exit; end;
  if (MInfo.WinAAttr and 5) <> 5 then begin VesaWhy := 'no writable window A'; Exit; end;
  if MInfo.WinASeg <> $A000 then begin VesaWhy := 'window A not at A000'; Exit; end;
  if MInfo.WinGranularity = 0 then begin VesaWhy := 'no window granularity'; Exit; end;
  if VbeSet($101) <> $004F then begin VesaWhy := 'mode set refused'; Exit; end;
  Pitch := MInfo.BytesPerLine;
  if Pitch = 0 then Pitch := 640;
  GranB := LongInt(MInfo.WinGranularity) * 1024;
  CurBank := -1;
  TryVesa := True;
end;

procedure Bank(B: Integer);
var P: Word;
begin
  if B = CurBank then Exit;
  CurBank := B;
  P := B;
  asm
    mov ax, 4F05h
    xor bx, bx
    mov dx, P
    int 10h
  end;
end;

procedure VesaRun(X, Y: Integer; const Src; Len: Word);
var
  Off: LongInt;
  W, First: Word;
  P: PByte;
begin
  P := @Src;
  Off := LongInt(Y) * Pitch + X;
  while Len > 0 do
  begin
    W := Off mod GranB;
    First := Len;
    if LongInt(W) + First > GranB then First := GranB - W;
    Bank(Off div GranB);
    Move(P^, Mem[$A000: W], First);
    Inc(P, First); Inc(Off, First); Dec(Len, First);
  end;
end;

{ ---- mode X, 320x240 unchained ----
  The textbook register set (Abrash): mode 13h, chain-4 off, 480-line
  timing with each line doubled.  Pixel (x, y) is plane x mod 4 at offset
  y*80 + x div 4. }

procedure CrtcW(I, V: Byte);
begin
  OutB($3D4, I); OutB($3D5, V);
end;

procedure EnterModeX;
begin
  BiosMode($13);
  OutB($3C4, 4); OutB($3C5, 6);          { chain-4 off, odd/even off }
  OutB($3C4, 0); OutB($3C5, 1);          { synchronous reset }
  OutB($3C2, $E3);                       { 480-line clock and polarity }
  OutB($3C4, 0); OutB($3C5, 3);          { restart }
  OutB($3D4, $11); OutB($3D5, InB($3D5) and $7F);   { unprotect }
  CrtcW($06, $0D); CrtcW($07, $3E); CrtcW($09, $41);
  CrtcW($10, $EA); CrtcW($11, $AC); CrtcW($12, $DF);
  CrtcW($14, $00); CrtcW($15, $E7); CrtcW($16, $06);
  CrtcW($17, $E3);
  OutB($3C4, 2); OutB($3C5, $0F);        { all planes }
  FillChar(Mem[$A000:0], 19200, 0);
end;

procedure ModeXRun(X, Y: Integer; const Src; N: Word);
var
  P: PByte;
  Pl, I: Integer;
  Base: Word;
begin
  P := @Src;
  Base := Y * 80;
  for Pl := 0 to 3 do
  begin
    OutB($3C4, 2); OutB($3C5, 1 shl ((X + Pl) and 3));
    I := Pl;
    while I < N do
    begin
      Mem[$A000: Base + (X + I) shr 2] := P[I];
      Inc(I, 4);
    end;
  end;
end;

{ ---- mode 12h, 640x480x16, planar ----
  Four bit planes, eight pixels a byte.  Used here for 16 greys: the
  attribute controller is set to pass colours 0..15 straight through to
  DAC entries 0..15, which are then loaded with a grey ramp. }

procedure Enter12;
var I: Integer;
begin
  BiosMode($12);
  InB($3DA);
  for I := 0 to 15 do
  begin
    OutB($3C0, I); OutB($3C0, I);
  end;
  OutB($3C0, $20);                        { palette back on }
end;

{ Pixels are packed eight to a byte in each of four planes, so a row is
  converted once -- bit p of each pixel shifted into plane p's byte, in
  assembly -- and kept in P12, and a repeated row (every row repeats at
  the scales mode 12h is used at) is only copied out again: Again12.
  Measured before this: 64 s to draw one picture in Pascal. }
var
  P12: array[0..3, 0..79] of Byte;
  P12X, P12N: Word;

procedure Build12(const Src; N: Word);
var
  S: Pointer;
  Groups, Pl: Word;
begin
  S := @Src;
  Groups := (N + 7) shr 3;
  for Pl := 0 to 3 do
  begin
    asm
      push ds
      push es
      lds  si, S
      mov  ax, seg P12
      mov  es, ax
      lea  di, P12
      mov  ax, Pl
      mov  cl, 80
      mul  cl
      add  di, ax                  { P12[Pl] }
      mov  cx, Pl
      inc  cl                      { shift count: bit Pl into carry }
      mov  dx, Groups
    @grp:
      xor  ah, ah
      mov  bx, 8
    @bit:
      lodsb
      shr  al, cl
      rcl  ah, 1
      dec  bx
      jnz  @bit
      mov  es:[di], ah
      inc  di
      dec  dx
      jnz  @grp
      pop  es
      pop  ds
    end;
  end;
end;

procedure Again12(Y: Integer);
var Pl: Integer;
begin
  for Pl := 0 to 3 do
  begin
    OutB($3C4, 2); OutB($3C5, 1 shl Pl);
    Move(P12[Pl, 0], Mem[$A000: Y * 80 + P12X shr 3], P12N);
  end;
  OutB($3C4, 2); OutB($3C5, $0F);
end;

procedure Run12(X, Y: Integer; const Src; N: Word);
begin
  Build12(Src, N);
  P12X := X;
  P12N := (N + 7) shr 3;
  Again12(Y);
end;

{ ---- text ---- }

procedure SetText50;
begin
  BiosMode(3);
  asm
    mov ax, 1112h                  { 8x8 font: 50 rows }
    xor bl, bl
    int 10h
  end;
end;

procedure NoBlink;
begin
  asm
    mov ax, 1003h                  { attribute bit 7 = bright background }
    xor bl, bl
    int 10h
  end;
end;

{ The attribute controller maps text colours 0..15 to DAC entries; read
  where each one points, then load those entries with Pal. }
procedure TextPalette(Grey: Boolean);
var
  I, D, V: Integer;
  Regs: array[0..16] of Byte;
  S, O: Word;
begin
  S := Seg(Regs); O := Ofs(Regs);
  asm
    push es
    mov  ax, S
    mov  es, ax
    mov  dx, O
    mov  ax, 1009h
    int  10h
    pop  es
  end;
  for I := 0 to 15 do
  begin
    D := Regs[I];
    TxtDac[I] := D;
    if Grey then
    begin
      V := I * 63 div 15;
      SetDac(D, V, V, V);
      Pal16[I, 0] := V; Pal16[I, 1] := V; Pal16[I, 2] := V;
    end
    else
    begin
      SetDac(D, Set16[I, 0], Set16[I, 1], Set16[I, 2]);
      Pal16[I, 0] := Set16[I, 0]; Pal16[I, 1] := Set16[I, 1];
      Pal16[I, 2] := Set16[I, 2];
    end;
  end;
end;

procedure LoadText16(const P: array of Byte);
var I: Integer;
begin
  for I := 0 to 15 do
  begin
    Pal16[I, 0] := P[I * 3]; Pal16[I, 1] := P[I * 3 + 1]; Pal16[I, 2] := P[I * 3 + 2];
    SetDac(TxtDac[I], P[I * 3], P[I * 3 + 1], P[I * 3 + 2]);
  end;
end;

procedure PutCell(CX, CY: Integer);
var
  T, B: Byte;
  Ch: Char;
  Att: Byte;
begin
  if (CX < 0) or (CX >= Cols) or (CY < 0) or (CY >= Rows) then Exit;
  if Disp = dAscii then
  begin
    T := Cell[CY, CX];
    Ch := Ramp[1 + T];
    MemW[TextSeg: (CY * Cols + CX) * 2] := Ord(Ch) or ($0700);
    Exit;
  end;
  T := Cell[CY * 2, CX];
  B := Cell[CY * 2 + 1, CX];
  if Mono then
  begin
    { no colour at all: shade by the pair's mean }
    T := (T + B) div 2;
    case T div 4 of
      0: begin Ch := ' ';    Att := $07; end;
      1: begin Ch := #176;   Att := $07; end;
      2: begin Ch := #177;   Att := $07; end;
    else begin Ch := #219;   Att := $0F; end;
    end;
    MemW[TextSeg: (CY * Cols + CX) * 2] := Ord(Ch) or (Word(Att) shl 8);
    Exit;
  end;
  { upper half-block in the foreground, the lower half is background }
  MemW[TextSeg: (CY * Cols + CX) * 2] := 223 or (Word((B shl 4) or T) shl 8);
end;

{ ---- the interface ---- }

procedure GreyPalette;
var I: Integer;
begin
  for I := 0 to 63 do SetDac(I, I, I, I);
  SetDac(C_BACK, 8, 8, 8);
  SetDac(C_TEXT, 63, 63, 63);
end;

procedure CubePalette;
var R, G, B: Integer;
begin
  for R := 0 to 5 do
    for G := 0 to 5 do
      for B := 0 to 5 do
        SetDac(R * 36 + G * 6 + B, R * 63 div 5, G * 63 div 5, B * 63 div 5);
  SetDac(C_BACK, 8, 8, 8);
  SetDac(C_TEXT, 63, 63, 63);
end;

function DispOpen(K: TDisp; Colour: Boolean): Boolean;
var I: Integer;
begin
  DispOpen := False;
  OldMode := GetMode and $7F;
  Mono := OldMode = 7;
  if Mono then TextSeg := $B000 else TextSeg := $B800;
  TextMode := False;

  if K = dAuto then
  begin
    if Mono then K := dT25
    else if TryVesa then K := dVesa
    else K := dModeX;
  end
  else if K = dVesa then
  begin
    if not TryVesa then Exit;
  end;
  Disp := K;

  case K of
    dVesa:  begin ScrW := 640; ScrH := 480; Levels := 64; end;
    dModeX: begin EnterModeX; ScrW := 320; ScrH := 240; Levels := 64; end;
    d13:    begin BiosMode($13); ScrW := 320; ScrH := 200; Levels := 64; end;
    d12:    begin Enter12; ScrW := 640; ScrH := 480; Levels := 16; end;
    dT50, dT25, dAscii:
      begin
        TextMode := True;
        if Mono then BiosMode(7)
        else if K = dT25 then BiosMode(3)
        else SetText50;
        if not Mono then begin NoBlink; if K <> dAscii then TextPalette(not Colour); end;
        Cols := 80;
        if (K = dT25) or Mono then Rows := 25 else Rows := 50;
        if Mono and (K = dT50) then Disp := dT25;
        if K = dAscii then begin ScrW := 80; ScrH := Rows; Levels := 10; end
        else begin ScrW := 80; ScrH := Rows * 2; Levels := 16; end;
        FillChar(Cell, SizeOf(Cell), 0);
        for I := 0 to Cols * Rows - 1 do MemW[TextSeg: I * 2] := $0720;
        { hide the cursor }
        asm
          mov ah, 01h
          mov cx, 2000h
          int 10h
        end;
      end;
  end;

  if not TextMode then
  begin
    FindFont;
    if K = d12 then
    begin
      for I := 0 to 15 do SetDac(I, I * 63 div 15, I * 63 div 15, I * 63 div 15);
    end
    else if Colour then CubePalette else GreyPalette;
  end;
  DispOpen := True;
end;

procedure DispClose;
begin
  BiosMode(OldMode);
end;

procedure PutRow(X, Y: Integer; const Src; N: Word);
var
  P: PByte;
  I, CY: Integer;
begin
  if (Y < 0) or (Y >= ScrH) or (N = 0) then Exit;
  if X < 0 then Exit;
  if X + N > ScrW then N := ScrW - X;
  P := @Src;
  case Disp of
    dVesa:  VesaRun(X, Y, Src, N);
    dModeX: ModeXRun(X, Y, Src, N);
    d13:    Move(Src, Mem[$A000: Y * 320 + X], N);
    d12:    Run12(X, Y, Src, N);
    dT50, dT25:
      begin
        for I := 0 to N - 1 do Cell[Y, X + I] := P[I];
        CY := Y shr 1;
        for I := 0 to N - 1 do PutCell(X + I, CY);
      end;
    dAscii:
      begin
        for I := 0 to N - 1 do Cell[Y, X + I] := P[I];
        for I := 0 to N - 1 do PutCell(X + I, Y);
      end;
  end;
end;

procedure PutRowAgain(Y: Integer; const Src; X: Integer; N: Word);
begin
  if (Disp = d12) and (Y >= 0) and (Y < ScrH) then Again12(Y)
  else PutRow(X, Y, Src, N);
end;

procedure Status(const S: ShortString);
var
  I, R, B: Integer;
  Bits: Byte;
  Line: array[0..319] of Byte;
  L: Integer;
begin
  L := Length(S);
  if L = 0 then Exit;
  if TextMode then
  begin
    for I := 1 to L do
      if I <= 80 then MemW[TextSeg: (I - 1) * 2] := Ord(S[I]) or $0F00;
    Exit;
  end;
  if L > 40 then L := 40;
  if Disp = d12 then Exit;                 { planar text is not worth it }
  for R := 0 to 7 do
  begin
    for I := 1 to L do
    begin
      Bits := Mem[FontSeg: FontOfs + Ord(S[I]) * 8 + R];
      for B := 0 to 7 do
        if (Bits and ($80 shr B)) <> 0 then Line[(I - 1) * 8 + B] := C_TEXT
                                       else Line[(I - 1) * 8 + B] := C_BACK;
    end;
    PutRow(0, R, Line, L * 8);
  end;
end;

function AsciiRow(Y: Integer): ShortString;
var
  S: ShortString;
  X: Integer;
begin
  S := '';
  for X := 0 to 79 do S := S + Ramp[1 + Cell[Y, X]];
  while (Length(S) > 0) and (S[Length(S)] = ' ') do Delete(S, Length(S), 1);
  AsciiRow := S;
end;

function Nearest16(R, G, B: Byte): Byte;
var
  I, Best: Integer;
  D, BestD: LongInt;
  DR, DG, DB: Integer;
begin
  Best := 0; BestD := MaxLongInt;
  for I := 0 to 15 do
  begin
    DR := Integer(R shr 2) - Pal16[I, 0];
    DG := Integer(G shr 2) - Pal16[I, 1];
    DB := Integer(B shr 2) - Pal16[I, 2];
    D := LongInt(DR) * DR * 3 + LongInt(DG) * DG * 4 + LongInt(DB) * DB * 2;
    if D < BestD then begin BestD := D; Best := I; end;
  end;
  Nearest16 := Best;
end;

begin
  Move(Set16, Pal16, SizeOf(Pal16));
end.
