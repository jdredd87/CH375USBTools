unit dlscr;
{ A text screen with colour and dirty tracking, drawn over DisplayLink.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

  DLCON drew a page and stopped. Anything interactive -- a terminal, a
  dashboard, a gauge that moves -- needs the opposite: a screen you change
  a little of, often, without paying for the parts that did not change.

  So this keeps TWO cell buffers. `Scr` is what you have asked for and
  `Shown` is what is on the glass; ScrFlush sends the difference. A gauge
  ticking in the corner of a full page costs the gauge, not the page.

  WHY THAT MATTERS SO MUCH HERE. A full 80x30 repaint is about 85,000
  bytes and 11 seconds on this path. One changed cell is roughly 80. The
  ratio is a thousand to one, and it is the difference between a display
  and a slideshow -- so the diff is not an optimisation, it is the only
  reason an interactive screen is possible at all.

  THREE THINGS MAKE THE DIFF CHEAP

  * Changed cells are merged along the ROW before drawing. A cell is 8
    scanline runs, so two neighbours redrawn separately are 16 runs where
    one wider run is 8. DLBENCH test 6 measures what ignoring the
    horizontal grain costs: 13x in wall clock.

  * A scanline of the run that is entirely background is skipped. An 8x16
    glyph has blank rows top and bottom, and the paper there is already
    the right colour.

  * Nothing is sent for a cell whose character AND attribute both match
    what is already shown.

  THE FONT IS THE MACHINE'S OWN. INT 10h AX=1130h BH=6 returns a pointer
  to the ROM 8x16 set, so nothing is embedded here and nothing can drift
  from it. That also means the CP437 line-drawing characters are free --
  boxes cost no more than letters, which is why ScrBox is three lines. }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

interface

uses ch375, dl;

const
  { 1280 / 8 and 1024 / 16 -- the largest mode in DlModes.  Two cell
    buffers at 160x64 is 40,960 bytes, which is most of a 64K data
    segment; anything larger would have to go on the heap. }
  SCR_MAXCOL = 160;
  SCR_MAXROW = 64;
  GW = 8;
  GH = 16;

  { The CGA sixteen, which is what an attribute byte means everywhere in
    DOS: low nibble ink, high nibble paper. }
  clBlack     = 0;   clBlue      = 1;   clGreen     = 2;   clCyan      = 3;
  clRed       = 4;   clMagenta   = 5;   clBrown     = 6;   clLightGrey = 7;
  clDarkGrey  = 8;   clLightBlue = 9;   clLightGreen= 10;  clLightCyan = 11;
  clLightRed  = 12;  clLightMag  = 13;  clYellow    = 14;  clWhite     = 15;

  { CP437 line drawing, single and double. }
  bxH  = #196; bxV  = #179; bxTL = #218; bxTR = #191;
  bxBL = #192; bxBR = #217; bxLT = #195; bxRT = #180;
  dbH  = #205; dbV  = #186; dbTL = #201; dbTR = #187;
  dbBL = #200; dbBR = #188; dbLT = #204; dbRT = #185;
  shLo = #176; shMid = #177; shHi = #178; shSolid = #219;

type
  TCell = record
    Ch: Char;
    At: Byte;
  end;

var
  ScrCols: Integer = 0;
  ScrRows: Integer = 0;
  ScrCellsSent: LongInt = 0;   { how many cells the last flush drew }

function  ScrInit(const T: TDlTiming): Boolean;
procedure ScrClear(At: Byte);
procedure ScrPut(X, Y: Integer; Ch: Char; At: Byte);
procedure ScrWrite(X, Y: Integer; const S: ShortString; At: Byte);
procedure ScrFill(X, Y, W, H: Integer; Ch: Char; At: Byte);
procedure ScrBox(X, Y, W, H: Integer; At: Byte; Dbl: Boolean);
procedure ScrTitle(X, Y, W: Integer; const S: ShortString; At: Byte);

{ A horizontal bar gauge: Pct of W cells filled.  The partial cell uses
  the CP437 shade characters, which gives four sub-steps per cell for
  free and makes a slow-moving gauge look like it is moving. }
procedure ScrBar(X, Y, W: Integer; Pct: Integer; AtOn, AtOff: Byte);

{ Send only what changed.  Returns False if the adapter stopped taking
  the command stream. }
function  ScrFlush: Boolean;

{ Force the next flush to redraw everything -- after a mode change, or
  anything else that invalidates the glass. }
procedure ScrInvalidate;

{ Tell the screen what is ALREADY on the glass, when you know.

  Callers clear the framebuffer to a colour before they start, and without
  this the first flush does not know that: it assumes nothing is on the
  screen and redraws all 2,400 cells, which on this path is about eleven
  seconds of apparently doing nothing. Almost every one of those cells is
  a space on the colour that was just written -- so almost all of that
  work produces no change at all.

  Saying so afterwards drops the first frame to the cells that actually
  have something in them. }
procedure ScrAssumeCleared(At: Byte);

implementation

var
  Scr:     array[0..SCR_MAXROW - 1, 0..SCR_MAXCOL - 1] of TCell;
  Shown:   array[0..SCR_MAXROW - 1, 0..SCR_MAXCOL - 1] of TCell;
  Pal:     array[0..15] of Word;
  FontSeg: Word = 0;
  FontOfs: Word = 0;
  Mode:    TDlTiming;
  Row:     array[0..SCR_MAXCOL * GW - 1] of Word;

{ INT 10h AX=1130h BH=6 -- the ROM 8x16 font, in ES:BP. }
procedure FindFont; assembler;
asm
    push  bp
    push  es
    mov   ax, $1130
    mov   bh, 6
    int   $10
    mov   ax, es
    mov   [FontSeg], ax
    mov   [FontOfs], bp
    pop   es
    pop   bp
end;

procedure BuildPal;
begin
  { The CGA sixteen at their usual intensities. }
  Pal[0]  := DlRgb(0, 0, 0);        Pal[8]  := DlRgb(85, 85, 85);
  Pal[1]  := DlRgb(0, 0, 170);      Pal[9]  := DlRgb(85, 85, 255);
  Pal[2]  := DlRgb(0, 170, 0);      Pal[10] := DlRgb(85, 255, 85);
  Pal[3]  := DlRgb(0, 170, 170);    Pal[11] := DlRgb(85, 255, 255);
  Pal[4]  := DlRgb(170, 0, 0);      Pal[12] := DlRgb(255, 85, 85);
  Pal[5]  := DlRgb(170, 0, 170);    Pal[13] := DlRgb(255, 85, 255);
  Pal[6]  := DlRgb(170, 85, 0);     Pal[14] := DlRgb(255, 255, 85);
  Pal[7]  := DlRgb(170, 170, 170);  Pal[15] := DlRgb(255, 255, 255);
end;

function ScrInit(const T: TDlTiming): Boolean;
var X, Y: Integer;
begin
  Mode := T;
  ScrCols := T.XRes div GW;
  ScrRows := T.YRes div GH;
  if ScrCols > SCR_MAXCOL then ScrCols := SCR_MAXCOL;
  if ScrRows > SCR_MAXROW then ScrRows := SCR_MAXROW;

  FindFont;
  BuildPal;

  for Y := 0 to SCR_MAXROW - 1 do
    for X := 0 to SCR_MAXCOL - 1 do
    begin
      Scr[Y, X].Ch := ' ';   Scr[Y, X].At := clLightGrey;
      { A character that cannot occur, so the first flush draws the lot. }
      Shown[Y, X].Ch := #1;  Shown[Y, X].At := $FF;
    end;
  ScrInit := FontSeg <> 0;
end;

procedure ScrInvalidate;
var X, Y: Integer;
begin
  for Y := 0 to SCR_MAXROW - 1 do
    for X := 0 to SCR_MAXCOL - 1 do
    begin
      Shown[Y, X].Ch := #1;
      Shown[Y, X].At := $FF;
    end;
end;

procedure ScrAssumeCleared(At: Byte);
var X, Y: Integer;
begin
  for Y := 0 to SCR_MAXROW - 1 do
    for X := 0 to SCR_MAXCOL - 1 do
    begin
      Shown[Y, X].Ch := ' ';
      Shown[Y, X].At := At;
    end;
end;

procedure ScrClear(At: Byte);
var X, Y: Integer;
begin
  for Y := 0 to ScrRows - 1 do
    for X := 0 to ScrCols - 1 do
    begin
      Scr[Y, X].Ch := ' ';
      Scr[Y, X].At := At;
    end;
end;

procedure ScrPut(X, Y: Integer; Ch: Char; At: Byte);
begin
  if (X < 0) or (Y < 0) or (X >= ScrCols) or (Y >= ScrRows) then Exit;
  Scr[Y, X].Ch := Ch;
  Scr[Y, X].At := At;
end;

procedure ScrWrite(X, Y: Integer; const S: ShortString; At: Byte);
var I: Integer;
begin
  for I := 1 to Length(S) do
    ScrPut(X + I - 1, Y, S[I], At);
end;

procedure ScrFill(X, Y, W, H: Integer; Ch: Char; At: Byte);
var I, J: Integer;
begin
  for J := 0 to H - 1 do
    for I := 0 to W - 1 do
      ScrPut(X + I, Y + J, Ch, At);
end;

{ Boxes are free: the CP437 line-drawing characters are already in the
  ROM font, so a border costs exactly what the same number of letters
  would. }
procedure ScrBox(X, Y, W, H: Integer; At: Byte; Dbl: Boolean);
var
  I: Integer;
  H_, V_, TL, TR, BL, BR: Char;
begin
  if (W < 2) or (H < 2) then Exit;
  if Dbl then
  begin
    H_ := dbH; V_ := dbV; TL := dbTL; TR := dbTR; BL := dbBL; BR := dbBR;
  end
  else
  begin
    H_ := bxH; V_ := bxV; TL := bxTL; TR := bxTR; BL := bxBL; BR := bxBR;
  end;
  ScrPut(X, Y, TL, At);
  ScrPut(X + W - 1, Y, TR, At);
  ScrPut(X, Y + H - 1, BL, At);
  ScrPut(X + W - 1, Y + H - 1, BR, At);
  for I := 1 to W - 2 do
  begin
    ScrPut(X + I, Y, H_, At);
    ScrPut(X + I, Y + H - 1, H_, At);
  end;
  for I := 1 to H - 2 do
  begin
    ScrPut(X, Y + I, V_, At);
    ScrPut(X + W - 1, Y + I, V_, At);
  end;
end;

procedure ScrTitle(X, Y, W: Integer; const S: ShortString; At: Byte);
var Cx: Integer;
begin
  Cx := X + (W - Length(S) - 2) div 2;
  ScrPut(Cx, Y, ' ', At);
  ScrWrite(Cx + 1, Y, S, At);
  ScrPut(Cx + 1 + Length(S), Y, ' ', At);
end;

{ Pct is 0..100.  The partial cell uses the shade characters, which give
  four sub-steps per cell -- so a gauge crossing one cell in ten seconds
  still visibly moves instead of sitting still and then jumping. }
procedure ScrBar(X, Y, W: Integer; Pct: Integer; AtOn, AtOff: Byte);
var
  Full, Rem, I: Integer;
  Q: Integer;
begin
  if Pct < 0 then Pct := 0;
  if Pct > 100 then Pct := 100;
  Q := (Pct * W * 4) div 100;         { quarter-cells }
  Full := Q div 4;
  Rem := Q mod 4;
  for I := 0 to W - 1 do
    if I < Full then ScrPut(X + I, Y, shSolid, AtOn)
    else if I = Full then
    begin
      case Rem of
        0: ScrPut(X + I, Y, ' ', AtOff);
        1: ScrPut(X + I, Y, shLo, AtOn);
        2: ScrPut(X + I, Y, shMid, AtOn);
      else
        ScrPut(X + I, Y, shHi, AtOn);
      end;
    end
    else ScrPut(X + I, Y, ' ', AtOff);
end;

{ ------------------------------------------------------------- flushing }

function GlyphByte(Ch: Char; Scan: Integer): Byte;
begin
  GlyphByte := Mem[FontSeg : FontOfs + Ord(Ch) * GH + Scan];
end;

{ Lay one scanline of a run of cells into Row, and say whether anything
  other than paper landed.  An all-paper scanline still has to be drawn
  when the PAPER itself changed, so the caller decides -- this only
  reports whether there is ink. }
function LayRun(Y, X1, X2, Scan: Integer): Boolean;
var
  X, O: Integer;
  B: Byte;
  Fg, Bg: Word;
  AnyInk: Boolean;
begin
  AnyInk := False;
  O := 0;
  for X := X1 to X2 do
  begin
    B := GlyphByte(Scr[Y, X].Ch, Scan);
    Fg := Pal[Scr[Y, X].At and $0F];
    Bg := Pal[(Scr[Y, X].At shr 4) and $0F];
    if B <> 0 then AnyInk := True;

    { UNROLLED, and the mask constants are literals rather than 128 shr
      Bit.  This is the innermost loop in the whole unit: a 160-cell
      change is 160 x 16 x 8 = 20,480 trips through it, and the loop
      overhead plus a variable shift was costing more than the work.
      CLAUDE.md measures a shift by CL at 185,021/s against 206,260 for an
      immediate one, but the real saving here is the loop itself. }
    if (B and 128) <> 0 then Row[O]   := Fg else Row[O]   := Bg;
    if (B and  64) <> 0 then Row[O+1] := Fg else Row[O+1] := Bg;
    if (B and  32) <> 0 then Row[O+2] := Fg else Row[O+2] := Bg;
    if (B and  16) <> 0 then Row[O+3] := Fg else Row[O+3] := Bg;
    if (B and   8) <> 0 then Row[O+4] := Fg else Row[O+4] := Bg;
    if (B and   4) <> 0 then Row[O+5] := Fg else Row[O+5] := Bg;
    if (B and   2) <> 0 then Row[O+6] := Fg else Row[O+6] := Bg;
    if (B and   1) <> 0 then Row[O+7] := Fg else Row[O+7] := Bg;
    Inc(O, GW);
  end;
  LayRun := AnyInk;
end;

{ Does this cell already look right on the glass?

  Not simply "same character and same attribute", because A SPACE RENDERS
  AS SOLID PAPER and its ink colour cannot be seen. Comparing the whole
  attribute byte treats a grey-on-black space as different from a
  black-on-black one and redraws it for no visible reason.

  That is not a corner case. A panel padded out with spaces in the
  foreground colour of its text covered 6,776 cells of an otherwise
  unchanged 160x64 screen -- two thirds of a full repaint, to draw nothing
  anybody could see. }
function Same(Y, X: Integer): Boolean;
begin
  if (Scr[Y, X].Ch = ' ') and (Shown[Y, X].Ch = ' ') then
    Same := (Scr[Y, X].At and $F0) = (Shown[Y, X].At and $F0)
  else
    Same := (Scr[Y, X].Ch = Shown[Y, X].Ch)
            and (Scr[Y, X].At = Shown[Y, X].At);
end;

function ScrFlush: Boolean;
var
  X, Y, Scan: Integer;
  X1, X2: Integer;
begin
  ScrFlush := False;
  ScrCellsSent := 0;

  for Y := 0 to ScrRows - 1 do
  begin
    X := 0;
    while X < ScrCols do
    begin
      if Same(Y, X) then
      begin
        Inc(X);
        Continue;
      end;

      { Merge the whole changed stretch into one run -- see the header:
        drawing two neighbours separately is twice the scanline runs for
        the same pixels. }
      X1 := X;
      X2 := X;
      while (X2 + 1 < ScrCols) and not Same(Y, X2 + 1) do Inc(X2);

      for Scan := 0 to GH - 1 do
      begin
        LayRun(Y, X1, X2, Scan);
        if not DlRleRun(DlAddr(Mode, Word(X1 * GW), Word(Y * GH + Scan)),
                        @Row[0], Word((X2 - X1 + 1) * GW)) then Exit;
      end;

      for X := X1 to X2 do
      begin
        Shown[Y, X] := Scr[Y, X];
        Inc(ScrCellsSent);
      end;
      X := X2 + 1;
    end;
  end;

  ScrFlush := DlSend;
end;

end.
