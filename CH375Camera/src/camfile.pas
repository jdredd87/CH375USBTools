unit camfile;
{ CAMFILE -- saving the camera's picture.  CH375Camera, StevenC & Claude.
  Public domain (the Unlicense).

  BMP because anything opens it, bottom-up as the format wants: 8-bit with
  a grey palette, or 24-bit colour.  Every width the camera has is a
  multiple of 4 bytes a row in both, so no padding.  RAW is the camera's
  own bytes: the Bayer mosaic, or the Y, U and V planes one after another. }

{$MODE OBJFPC}{$H-}

interface

procedure WriteBmp(const Name: ShortString; Grey: Boolean);
procedure WriteRaw(const Name: ShortString);

{ The picture as text, Cols characters wide.

  AsciiArt: each character the mean brightness of the block of pixels it
  covers, through " .:-=+*#%@", stretched between the 2nd and 98th
  percentile of the blocks.  Rows are half as many as the picture's shape
  would give, because a character is about twice as tall as it is wide.
  A first version sampled one pixel per character and read as noise; a
  70-character ramp was tried against this one and read worse.

  AnsiArt: two picture rows per text row, as upper/lower half-blocks in the
  16 CGA colours -- nearest colour after a light ordered dither, not error
  diffusion, which was tried and sprayed speckles over every flat grey.  ANSI.SYS can only show the 8
  dark colours as backgrounds (bright ones blink), so each cell puts the
  brighter pixel in the foreground, choosing the upper or lower half-block
  to suit.  TYPE it under ANSI.SYS, or open it in any ANSI viewer. }
procedure AsciiArt(var F: Text; Cols: Integer);
procedure AnsiArt(var F: Text; Cols: Integer);

{ Called once a row while writing, for a heartbeat.  Nil for none. }
var
  FileIdle: procedure = nil;

implementation

uses camgrab;

procedure Put32(var H: array of Byte; P: Integer; V: LongInt);
begin
  H[P] := V and $FF; H[P + 1] := (V shr 8) and $FF;
  H[P + 2] := (V shr 16) and $FF; H[P + 3] := (V shr 24) and $FF;
end;

procedure WriteBmp(const Name: ShortString; Grey: Boolean);
var
  F: File;
  Hdr: array[0..53] of Byte;
  Pal: array[0..1023] of Byte;
  Line: array[0..MAXW * 3 - 1] of Byte;
  R, G, B: array[0..MAXW - 1] of Byte;
  X, Y, I, Bpp, RowB: Integer;
  Off: LongInt;
begin
  if Grey then Bpp := 8 else Bpp := 24;
  RowB := Mode.W * (Bpp div 8);
  FillChar(Hdr, SizeOf(Hdr), 0);
  Off := 54;
  if Bpp = 8 then Off := 54 + 1024;
  Hdr[0] := Ord('B'); Hdr[1] := Ord('M');
  Put32(Hdr, 2, Off + LongInt(RowB) * Mode.H);
  Put32(Hdr, 10, Off);
  Put32(Hdr, 14, 40);
  Put32(Hdr, 18, Mode.W);
  Put32(Hdr, 22, Mode.H);
  Hdr[26] := 1;
  Hdr[28] := Bpp;
  Put32(Hdr, 34, LongInt(RowB) * Mode.H);
  if Bpp = 8 then Put32(Hdr, 46, 256);
  Assign(F, Name);
  Rewrite(F, 1);
  BlockWrite(F, Hdr, SizeOf(Hdr));
  if Bpp = 8 then
  begin
    for I := 0 to 255 do
    begin
      Pal[I * 4] := I; Pal[I * 4 + 1] := I; Pal[I * 4 + 2] := I;
      Pal[I * 4 + 3] := 0;
    end;
    BlockWrite(F, Pal, SizeOf(Pal));
  end;
  for Y := Mode.H - 1 downto 0 do
  begin
    if Assigned(FileIdle) then FileIdle;
    if Bpp = 8 then RowGrey(Y, 0, Mode.W, @Line)
    else
    begin
      RowRGB(Y, 0, Mode.W, @R, @G, @B);
      for X := 0 to Mode.W - 1 do
      begin
        Line[X * 3] := B[X]; Line[X * 3 + 1] := G[X]; Line[X * 3 + 2] := R[X];
      end;
    end;
    BlockWrite(F, Line, RowB);
  end;
  Close(F);
end;

const
  Ramp: string[10] = ' .:-=+*#%@';
  Cga: array[0..15, 0..2] of Byte = (
    (0, 0, 0), (0, 0, 170), (0, 170, 0), (0, 170, 170),
    (170, 0, 0), (170, 0, 170), (170, 85, 0), (170, 170, 170),
    (85, 85, 85), (85, 85, 255), (85, 255, 85), (85, 255, 255),
    (255, 85, 85), (255, 85, 255), (255, 255, 85), (255, 255, 255));
  AnsiOf: array[0..7] of Byte = (0, 4, 2, 6, 1, 5, 3, 7);   { CGA -> SGR }
  { A 2x2 ordered dither, added to all three channels alike so a grey
    stays grey.  The CGA set has only four greys, and without it a grey
    subject -- the cartridge it was tuned on -- came out one flat dark
    grey; compared at 0, 64 and 96, this strength showed its ridges. }
  Dith2: array[0..1, 0..1] of Integer = ((-36, 12), (36, -12));

type
  TCells = array[0..79] of LongInt;

var
  { globals, not locals: 38 KB would not fit on a DOS program's stack }
  Cells: array[0..60, 0..79] of Byte;
  Px:    array[0..119, 0..79] of Byte;              { CGA colour per half-cell }
  Mean:  array[0..119, 0..79, 0..2] of Byte;

{ Block means of picture rows Y0..Y1-1 into Cols cells, per channel. }
procedure BandMeans(Y0, Y1, Cols: Integer; var R, G, B: TCells; Grey: Boolean);
var
  Y, X, C, X0, X1: Integer;
  RR, GG, BB: array[0..MAXW - 1] of Byte;
  N: LongInt;
begin
  FillChar(R, SizeOf(R), 0); FillChar(G, SizeOf(G), 0); FillChar(B, SizeOf(B), 0);
  for Y := Y0 to Y1 - 1 do
  begin
    if Grey then RowGrey(Y, 0, Mode.W, @GG)
    else RowRGB(Y, 0, Mode.W, @RR, @GG, @BB);
    for C := 0 to Cols - 1 do
    begin
      X0 := LongInt(C) * Mode.W div Cols;
      X1 := LongInt(C + 1) * Mode.W div Cols;
      for X := X0 to X1 - 1 do
      begin
        Inc(G[C], GG[X]);
        if not Grey then begin Inc(R[C], RR[X]); Inc(B[C], BB[X]); end;
      end;
    end;
  end;
  for C := 0 to Cols - 1 do
  begin
    N := LongInt(Y1 - Y0) * (LongInt(C + 1) * Mode.W div Cols - LongInt(C) * Mode.W div Cols);
    if N = 0 then N := 1;
    R[C] := R[C] div N; G[C] := G[C] div N; B[C] := B[C] div N;
  end;
end;

{ Low and high percentiles of a set of 0..255 values given as a histogram. }
procedure Percentiles(const Hist: array of LongInt; var Lo, Hi: Integer);
var
  I: Integer;
  Total, Acc: LongInt;
begin
  Total := 0;
  for I := 0 to 255 do Inc(Total, Hist[I]);
  Lo := 0; Hi := 255;
  Acc := 0;
  for I := 0 to 255 do
  begin
    Inc(Acc, Hist[I]);
    if Acc * 50 > Total then begin Lo := I; Break; end;
  end;
  Acc := 0;
  for I := 255 downto 0 do
  begin
    Inc(Acc, Hist[I]);
    if Acc * 50 > Total then begin Hi := I; Break; end;
  end;
  if Hi <= Lo then Hi := Lo + 1;
end;

function Stretch(V, Lo, Hi: Integer): Integer;
begin
  V := LongInt(V - Lo) * 255 div (Hi - Lo);
  if V < 0 then V := 0;
  if V > 255 then V := 255;
  Stretch := V;
end;

procedure AsciiArt(var F: Text; Cols: Integer);
var
  Rows, Row, C, Lo, Hi, V: Integer;
  R, G, B: TCells;
  Hist: array[0..255] of LongInt;
  S: ShortString;
begin
  if Cols > 80 then Cols := 80;
  Rows := LongInt(Cols) * Mode.H div Mode.W div 2;
  if Rows > 60 then Rows := 60;
  FillChar(Hist, SizeOf(Hist), 0);
  for Row := 0 to Rows - 1 do
  begin
    if Assigned(FileIdle) then FileIdle;
    BandMeans(LongInt(Row) * Mode.H div Rows, LongInt(Row + 1) * Mode.H div Rows,
              Cols, R, G, B, True);
    for C := 0 to Cols - 1 do
    begin
      Cells[Row, C] := G[C];
      Inc(Hist[G[C]]);
    end;
  end;
  Percentiles(Hist, Lo, Hi);
  for Row := 0 to Rows - 1 do
  begin
    S := '';
    for C := 0 to Cols - 1 do
    begin
      V := Stretch(Cells[Row, C], Lo, Hi);
      S := S + Ramp[1 + V * 10 div 256];
    end;
    while (Length(S) > 0) and (S[Length(S)] = ' ') do Delete(S, Length(S), 1);
    WriteLn(F, S);
  end;
end;

function NearestCga(R, G, B: Integer): Byte;
var
  I, Best: Integer;
  D, BestD: LongInt;
begin
  Best := 0; BestD := MaxLongInt;
  for I := 0 to 15 do
  begin
    D := 3 * Sqr(LongInt(R - Cga[I, 0])) + 4 * Sqr(LongInt(G - Cga[I, 1])) +
         2 * Sqr(LongInt(B - Cga[I, 2]));
    if D < BestD then begin BestD := D; Best := I; end;
  end;
  NearestCga := Best;
end;

procedure AnsiArt(var F: Text; Cols: Integer);
var
  Rows, Row, C, Lo, Hi, T, U, Fg, Bg, Ch: Integer;
  R, G, B: TCells;
  Hist: array[0..255] of LongInt;
begin
  if Cols > 80 then Cols := 80;
  Rows := LongInt(Cols) * Mode.H div Mode.W;      { picture rows, 2 a line }
  Rows := Rows and not 1;
  if Rows > 120 then Rows := 120;
  FillChar(Hist, SizeOf(Hist), 0);
  for Row := 0 to Rows - 1 do
  begin
    if Assigned(FileIdle) then FileIdle;
    BandMeans(LongInt(Row) * Mode.H div Rows, LongInt(Row + 1) * Mode.H div Rows,
              Cols, R, G, B, False);
    for C := 0 to Cols - 1 do
    begin
      Mean[Row, C, 0] := R[C]; Mean[Row, C, 1] := G[C]; Mean[Row, C, 2] := B[C];
      Inc(Hist[R[C]]); Inc(Hist[G[C]]); Inc(Hist[B[C]]);
    end;
  end;
  { one stretch for all three channels, so greys stay grey }
  Percentiles(Hist, Lo, Hi);
  for Row := 0 to Rows - 1 do
    for C := 0 to Cols - 1 do
    begin
      T := Dith2[Row and 1, C and 1];
      Px[Row, C] := NearestCga(Stretch(Mean[Row, C, 0], Lo, Hi) + T,
                               Stretch(Mean[Row, C, 1], Lo, Hi) + T,
                               Stretch(Mean[Row, C, 2], Lo, Hi) + T);
    end;
  Write(F, #27'[0m');
  Row := 0;
  while Row < Rows do
  begin
    for C := 0 to Cols - 1 do
    begin
      T := Px[Row, C]; U := Px[Row + 1, C];
      { the brighter of the two goes in the foreground; a bright
        background would blink }
      if (U >= 8) and (T < 8) then
      begin Ch := 220; Fg := U; Bg := T; end        { lower half-block }
      else
      begin
        Ch := 223; Fg := T; Bg := U;               { upper half-block }
        if Bg >= 8 then Bg := Bg - 8;
      end;
      if T = U then
      begin
        Ch := 219; Fg := T; Bg := 0;               { full block }
      end;
      if Fg >= 8 then Write(F, #27'[1;', 30 + AnsiOf[Fg - 8], ';', 40 + AnsiOf[Bg], 'm')
                 else Write(F, #27'[0;', 30 + AnsiOf[Fg], ';', 40 + AnsiOf[Bg], 'm');
      Write(F, Chr(Ch));
    end;
    WriteLn(F, #27'[0m');
    Inc(Row, 2);
  end;
end;

procedure WriteRaw(const Name: ShortString);
var
  F: File;
  Y: Integer;
begin
  Assign(F, Name);
  Rewrite(F, 1);
  for Y := 0 to Mode.H - 1 do BlockWrite(F, Pix[Y]^, Mode.W);
  if Mode.Fmt = fmtYUV then
  begin
    for Y := 0 to Mode.H div 2 - 1 do BlockWrite(F, UPix[Y]^, Mode.W div 2);
    for Y := 0 to Mode.H div 2 - 1 do BlockWrite(F, VPix[Y]^, Mode.W div 2);
  end;
  Close(F);
end;

end.
