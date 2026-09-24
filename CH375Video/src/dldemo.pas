program dldemo;
{ DLDEMO -- moving graphics on a DisplayLink adapter, from real-mode DOS.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLDEMO [/P=260] [/M=n] [/D=name] [/S=secs] [/C]

      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0 (640x480@60)
      /D=name  which demo: balls, stars, cube, bars, raster, life.
               Default balls
      /S=dec   seconds to run, default 20
      /C       clear to the background and stop, nothing animated

  THE CONSTRAINT THAT SHAPES ALL OF THIS

  A 640x480 16bpp framebuffer is 614,400 bytes and this machine has about
  514 KB of free heap, so THERE IS NO BACK BUFFER. Nothing here can render
  a frame locally and blit it; the screen is write-only and remote, and
  the only affordable way to animate is to touch the pixels that changed
  and nothing else.

  That is not a workaround, it is the whole design. DLBENCH measures a
  full solid screen at about 0.66 s and a full screen of literal pixels at
  43 s -- so a demo that redraws everything gets 1.5 fps at best and 0.02
  at worst. A 64x64 rectangle costs 44 ms, which is 23 fps. The difference
  between those two numbers is the difference between a demo and a
  slideshow, and it is entirely about how much is sent.

  So each demo below erases only where it drew and draws only where it
  must, and reports the bytes it actually spent per frame. If a change
  makes a demo look better and the bytes-per-frame go up, it got slower,
  and the number is printed so that is visible rather than argued about.

  INTEGER MATHS, AND A COPROCESSOR WOULD NOT HELP -- though not for the
  reason first written here. This file used to claim the machine had no
  x87 fitted. It has: an 8087, which answers the probe and passes every
  arithmetic test. The claim came from a stale note rather than from
  asking the hardware.

  The conclusion survives the correction, and DLFRACT measured it: Q8
  integer beats the 8087 two to one on this machine, because an FMUL is of
  the order of a hundred clocks against roughly 25 for a 16-bit IMUL. On
  top of that, everything in THIS file is transfer-bound anyway -- at
  19 KB/s the geometry is free and the wire is the whole cost -- so the
  arithmetic could be free and the frame rate would not move.

  So every demo here is integer fixed point with a 64-entry quarter sine
  table, and that is a measured choice rather than a limitation.

  NOR ANY 186-CLASS TRICK, for the same measured reason. REP OUTSB is an
  80186 instruction that a plain 8086 lacks, and DLBENCH says the byte loop
  is now about 0.3 ms of a 3.4 ms packet -- so it is worth ~6% and costs a
  run-time CPU gate with an 8086 fallback beside it. The inlined portable
  loop in dl.pas already took the 4x.

  Exit codes: 0 ok, otherwise the DlOpen reason (all <= 20) }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}

uses ch375, chtool, dl;

const
  VER = '1.0.0';

  { sin(i * 90 / 64 degrees) * 4096, one quarter wave. The other three are
    reflections, which is what Sin4096 below is for. }
  SinQ: array[0..63] of Integer = (
        0,   101,   201,   301,   401,   501,   601,   700,
      799,   897,   995,  1092,  1189,  1285,  1380,  1474,
     1567,  1660,  1751,  1842,  1931,  2019,  2106,  2191,
     2276,  2359,  2440,  2520,  2598,  2675,  2751,  2824,
     2896,  2967,  3035,  3102,  3166,  3229,  3290,  3349,
     3406,  3461,  3513,  3564,  3612,  3659,  3703,  3745,
     3784,  3822,  3857,  3889,  3920,  3948,  3973,  3996,
     4017,  4036,  4052,  4065,  4076,  4085,  4091,  4095);

  NBALL   = 5;
  BALLSZ  = 28;
  NSTAR   = 120;
  BARH    = 6;

  { Conway's Life on a chunky grid.  80x60 cells of 8x8 pixels fills a
    640x480 screen exactly, and the two generation buffers are 4,800
    bytes each -- small enough to stay in the data segment. }
  LW      = 80;
  LH      = 60;
  LCELL   = 8;

  { The cube is rendered into a local tile and blitted, because a wireframe
    is mostly background and RLE collapses that -- whereas erasing the
    bounding box and then drawing over it would send the same area twice. }
  TSZ = 112;

type
  TWordArr = array[0..TSZ * TSZ - 1] of Word;
  PWordArr = ^TWordArr;

  TBall = record
    X, Y, Dx, Dy: Integer;
    Col: Word;
  end;

var
  T:       TDlTiming;
  ModeIx:  Integer = 0;
  Secs:    Integer = 20;
  Which:   ShortString;
  ClearOnly: Boolean = False;
  Bg:      Word;

  Balls:   array[0..NBALL - 1] of TBall;
  StarX:   array[0..NSTAR - 1] of Integer;
  StarY:   array[0..NSTAR - 1] of Integer;
  StarV:   array[0..NSTAR - 1] of Integer;
  StarC:   array[0..NSTAR - 1] of Word;

  { On the HEAP, not in DGROUP: 176x176 words is 61,952 bytes and the
    whole data segment is 64K, so this is the one allocation that has to
    go outside it.  There is about 514 KB of free heap to put it in. }
  Tile:    PWordArr;
  Row:     array[0..1023] of Word;

  BarY:    array[0..7] of Integer;
  LifeA:   array[0..LW * LH - 1] of Byte;
  LifeB:   array[0..LW * LH - 1] of Byte;
  LifeInit: Boolean = False;
  Frames:  LongInt = 0;
  Seed:    Word = 12345;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ A plain LCG. Reproducible on purpose: a demo that looks different every
  run cannot be compared against its own screenshot. }
function Rnd(N: Word): Word;
begin
  Seed := Word(Seed * 25173 + 13849);
  Rnd := (Seed shr 4) mod N;
end;

{ sin of a 0..255 angle, in Q12. }
function Sin4096(A: Integer): Integer;
begin
  A := A and 255;
  if A < 64 then Sin4096 := SinQ[A]
  else if A < 128 then Sin4096 := SinQ[127 - A]
  else if A < 192 then Sin4096 := -SinQ[A - 128]
  else Sin4096 := -SinQ[255 - A];
end;

function Cos4096(A: Integer): Integer;
begin
  Cos4096 := Sin4096(A + 64);
end;

{ ------------------------------------------------------------------ tile }

{ FillWord, not a Pascal loop.  CLAUDE.md measures REP STOSW at 439,821
  words a second against 68,322 for a per-element array store -- 6.4x --
  and the tile clear was the single biggest cost in the cube demo, which
  DLDEMO measured as CPU-bound rather than transfer-bound. }
procedure TileClear(C: Word);
begin
  FillWord(Tile^[0], TSZ * TSZ, C);
end;

procedure TilePix(X, Y: Integer; C: Word);
begin
  if (X < 0) or (Y < 0) or (X >= TSZ) or (Y >= TSZ) then Exit;
  Tile^[Y * TSZ + X] := C;
end;

{ Bresenham, integer only. }
procedure TileLine(X0, Y0, X1, Y1: Integer; C: Word);
var
  Dx, Dy, Sx, Sy, Er, E2: Integer;
begin
  Dx := X1 - X0; if Dx < 0 then Dx := -Dx;
  Dy := Y1 - Y0; if Dy < 0 then Dy := -Dy;
  if X0 < X1 then Sx := 1 else Sx := -1;
  if Y0 < Y1 then Sy := 1 else Sy := -1;
  Er := Dx - Dy;
  while True do
  begin
    TilePix(X0, Y0, C);
    if (X0 = X1) and (Y0 = Y1) then Break;
    E2 := Er * 2;
    if E2 > -Dy then begin Er := Er - Dy; X0 := X0 + Sx; end;
    if E2 < Dx then begin Er := Er + Dx; Y0 := Y0 + Sy; end;
  end;
end;

{ Push the tile out, one RLE run per row. A wireframe row is a long
  background run, a pixel or two of ink, and another long run -- which is
  exactly the shape the encoder is good at. }
function TileBlit(Ox, Oy: Word): Boolean;
var Y, X: Integer;
begin
  TileBlit := False;
  { Straight out of the tile.  Copying each row into a staging buffer
    first was 2 far-pointer accesses per pixel -- 61,952 of them a frame --
    for no reason: the rows are already contiguous. }
  for Y := 0 to TSZ - 1 do
    if not DlRleRun(DlAddr(T, Ox, Oy + Y), @Tile^[Y * TSZ], TSZ) then Exit;
  TileBlit := DlSend;
end;

{ ----------------------------------------------------------------- demos }

{ Erase where it was, draw where it is. Two small solid rectangles per
  ball per frame and nothing else touched -- about 480 bytes a ball. }
function DemoBalls: Boolean;
var
  I: Integer;
begin
  DemoBalls := False;
  for I := 0 to NBALL - 1 do
  begin
    if not DlFillRect(T, Word(Balls[I].X), Word(Balls[I].Y),
                      BALLSZ, BALLSZ, Bg) then Exit;
    Balls[I].X := Balls[I].X + Balls[I].Dx;
    Balls[I].Y := Balls[I].Y + Balls[I].Dy;
    if Balls[I].X < 0 then
      begin Balls[I].X := 0; Balls[I].Dx := -Balls[I].Dx; end;
    if Balls[I].Y < 0 then
      begin Balls[I].Y := 0; Balls[I].Dy := -Balls[I].Dy; end;
    if Balls[I].X > T.XRes - BALLSZ - 1 then
      begin Balls[I].X := T.XRes - BALLSZ - 1; Balls[I].Dx := -Balls[I].Dx; end;
    if Balls[I].Y > T.YRes - BALLSZ - 1 then
      begin Balls[I].Y := T.YRes - BALLSZ - 1; Balls[I].Dy := -Balls[I].Dy; end;
    if not DlFillRect(T, Word(Balls[I].X), Word(Balls[I].Y),
                      BALLSZ, BALLSZ, Balls[I].Col) then Exit;
  end;
  DemoBalls := DlSend;
end;

{ The cheapest thing that can possibly move: one pixel erased and one
  drawn per star, about 18 bytes each. }
function DemoStars: Boolean;
var
  I: Integer;
  One: Word;
begin
  DemoStars := False;
  for I := 0 to NSTAR - 1 do
  begin
    One := Bg;
    if not DlRleRun(DlAddr(T, Word(StarX[I]), Word(StarY[I])),
                    @One, 1) then Exit;
    StarX[I] := StarX[I] - StarV[I];
    if StarX[I] < 0 then
    begin
      StarX[I] := T.XRes - 1;
      StarY[I] := Rnd(T.YRes);
    end;
    One := StarC[I];
    if not DlRleRun(DlAddr(T, Word(StarX[I]), Word(StarY[I])),
                    @One, 1) then Exit;
  end;
  DemoStars := DlSend;
end;

{ A rotating wireframe cube, integer fixed point throughout. }
function DemoCube(Ang: Integer): Boolean;
const
  Vx: array[0..7] of Integer = (-1,  1,  1, -1, -1,  1,  1, -1);
  Vy: array[0..7] of Integer = (-1, -1,  1,  1, -1, -1,  1,  1);
  Vz: array[0..7] of Integer = (-1, -1, -1, -1,  1,  1,  1,  1);
  Ea: array[0..11] of Integer = (0,1,2,3, 4,5,6,7, 0,1,2,3);
  Eb: array[0..11] of Integer = (1,2,3,0, 5,6,7,4, 4,5,6,7);
var
  I:        Integer;
  Sx, Sy:   array[0..7] of Integer;
  Ca, Sa, Cb, Sb: Integer;
  X, Y, Z, X2, Z2, Y2: LongInt;
  D:        LongInt;
  Ink, Edge: Word;
begin
  Ca := Cos4096(Ang);      Sa := Sin4096(Ang);
  Cb := Cos4096(Ang * 2);  Sb := Sin4096(Ang * 2);

  for I := 0 to 7 do
  begin
    X := LongInt(Vx[I]) * 40;
    Y := LongInt(Vy[I]) * 40;
    Z := LongInt(Vz[I]) * 40;
    { yaw, then pitch -- Q12 throughout, shifted back after each product }
    X2 := (X * Ca - Z * Sa) div 4096;
    Z2 := (X * Sa + Z * Ca) div 4096;
    Y2 := (Y * Cb - Z2 * Sb) div 4096;
    Z2 := (Y * Sb + Z2 * Cb) div 4096;
    D  := Z2 + 220;
    if D < 40 then D := 40;
    Sx[I] := Integer(TSZ div 2 + (X2 * 200) div D);
    Sy[I] := Integer(TSZ div 2 + (Y2 * 200) div D);
  end;

  TileClear(Bg);
  Ink  := DlRgb(120, 255, 120);
  Edge := DlRgb(255, 200, 60);
  for I := 0 to 11 do
  begin
    if I < 4 then Edge := DlRgb(255, 200, 60)
    else if I < 8 then Edge := Ink
    else Edge := DlRgb(120, 180, 255);
    TileLine(Sx[Ea[I]], Sy[Ea[I]], Sx[Eb[I]], Sy[Eb[I]], Edge);
  end;

  DemoCube := TileBlit((T.XRes - TSZ) div 2, (T.YRes - TSZ) div 2);
end;

{ Sliding colour bars: full-width motion, and the cheapest thing that
  touches every column.

  The first version drew without erasing, so 203 frames of bars piled up
  into a striped mess -- which looked deliberate enough in a screenshot to
  pass unnoticed, and was caught only by the capture. An animation that
  never erases is not fast, it is wrong. }
function DemoBars(Phase: Integer): Boolean;
var
  I, Y, H: Integer;
begin
  DemoBars := False;
  H := T.YRes div 8;
  for I := 0 to 7 do
    if BarY[I] >= 0 then
      if not DlFillRect(T, 0, Word(BarY[I]), T.XRes, BARH, Bg) then Exit;
  for I := 0 to 7 do
  begin
    Y := ((I * H) + Phase) mod (T.YRes - H);
    BarY[I] := Y;
    if not DlFillRect(T, 0, Word(Y), T.XRes, BARH,
                      DlRgb(255 - I * 30, I * 30, 128 + I * 15)) then Exit;
  end;
  DemoBars := DlSend;
end;

{ FULL-SCREEN animation that is actually affordable, which on this path
  means one where every scanline is a single colour.

  A row of identical pixels is one RLE run whatever its width -- about ten
  bytes for 256 pixels -- so a whole 480-line screen of horizontal bands
  costs roughly 480 runs, not 307,200 pixels. That is the difference
  between a full-screen effect at a usable rate and the 43 seconds a
  screen of literal pixels takes.

  This is the classic raster-bar effect for exactly that reason: it was
  cheap on hardware that could change one colour per scanline, and it is
  cheap here for the same shape of reason. Each bar is a vertical gradient
  moved by a sine, and rows not covered by a bar are background. }
function DemoRaster(Phase: Integer): Boolean;
const
  NBAR = 5;
  BARW = 28;                       { half-height of a bar, in rows }
var
  Y, I, D, Lvl: Integer;
  Amp, C:       LongInt;
  Centre: array[0..NBAR - 1] of Integer;
  Col: Word;
  RunY: Integer;
  RunCol: Word;
begin
  DemoRaster := False;
  { LongInt on the product, and this is not defensive typing.  Sin4096
    returns +/-4096 and the amplitude here is about 208, so the product
    reaches 851,968 -- and Integer on this target is SIXTEEN BITS. Left as
    Integer it wraps, Centre lands anywhere, and the run-builder below
    then emits a different colour on nearly every row.

    Clamped as well, because a bar centre outside the screen is a bug
    whatever produced it, and a demo that quietly draws 480 separate runs
    a frame is indistinguishable from one that is merely slow. }
  Amp := LongInt(T.YRes div 2) - BARW - 4;
  if Amp < 0 then Amp := 0;
  for I := 0 to NBAR - 1 do
  begin
    C := LongInt(T.YRes div 2)
         + (LongInt(Sin4096(Phase * 2 + I * 40)) * Amp) div 4096;
    if C < 0 then C := 0;
    if C > LongInt(T.YRes) - 1 then C := LongInt(T.YRes) - 1;
    Centre[I] := Integer(C);
  end;

  { Walk the screen once, emitting a run only where the colour changes --
    so a screen with five bars on it costs about eleven runs, not 480. }
  RunY := 0;
  RunCol := Bg;
  for Y := 0 to T.YRes - 1 do
  begin
    Col := Bg;
    for I := 0 to NBAR - 1 do
    begin
      D := Y - Centre[I];
      if D < 0 then D := -D;
      if D < BARW then
      begin
        { QUANTISED, and this is the whole point of the demo.

          The first version made each bar a smooth gradient, so the colour
          changed on nearly every row -- 280 rows of unique colour, one RLE
          run each, 13,741 bytes a frame and 1.1 fps. A gradient is exactly
          what defeats a run-length encoder, and "full-screen effect" did
          not save it.

          Stepping the level to 6 shades turns each bar back into a
          handful of flat bands, which is what makes a whole 640x480 screen
          cost tens of runs instead of hundreds. The picture barely
          changes; the cost changes by an order of magnitude. }
        Lvl := ((255 - (D * 255) div BARW) div 48) * 48;
        case I mod 5 of
          0: Col := DlRgb(Lvl, Lvl div 5, Lvl div 5);
          1: Col := DlRgb(Lvl div 5, Lvl, Lvl div 5);
          2: Col := DlRgb(Lvl div 5, Lvl div 4, Lvl);
          3: Col := DlRgb(Lvl, Lvl, Lvl div 6);
        else
          Col := DlRgb(Lvl, Lvl div 3, Lvl);
        end;
      end;
    end;
    if Col <> RunCol then
    begin
      if Y > RunY then
        if not DlFillRun(DlAddr(T, 0, Word(RunY)), RunCol,
                         LongInt(Y - RunY) * T.XRes) then Exit;
      RunY := Y;
      RunCol := Col;
    end;
  end;
  if T.YRes > RunY then
    if not DlFillRun(DlAddr(T, 0, Word(RunY)), RunCol,
                     LongInt(T.YRes - RunY) * T.XRes) then Exit;
  DemoRaster := DlSend;
end;

{ Conway's Life, and the reason it is here: it is the only demo that
  sends a DELTA.

  Everything else either repaints the whole screen or knows exactly which
  rectangle it moved. Life knows neither -- the cells that change are
  scattered and different every generation -- so it has to compare the new
  state against the old and send only the difference. That is the
  technique a real terminal or windowing layer would need on this path,
  and it is the one worth having demonstrated.

  The cost is therefore the CHANGE, not the picture: a settled pattern
  with a few blinkers costs almost nothing a frame, while a boiling random
  soup costs nearly a full repaint. Both are the same code. }
function DemoLife: Boolean;
var
  X, Y, I, N:     Integer;
  Cx, Cy:         Integer;
  Yu, Yd:         Integer;
  Ru, Rc, Rd:     Integer;
  Xl, Xr:         Integer;
  Alive:          Byte;
  Changed:        Integer;
begin
  DemoLife := False;

  if not LifeInit then
  begin
    for I := 0 to LW * LH - 1 do
    begin
      LifeA[I] := 0;
      { 0, not a sentinel: the screen is ALREADY background from the
        startup clear, so only the live cells need drawing. Forcing all
        4,800 cells to draw cost 398,528 bytes and ate a 25-second run in
        a single frame. }
      LifeB[I] := 0;
    end;

    { GLIDERS, not a random soup, and the reason is the whole point of
      this demo. A random field changes about 1,400 of its 4,800 cells
      every generation -- 88,597 bytes, which is most of a full repaint,
      and the delta buys almost nothing. Gliders change roughly ten cells
      each, so the same code costs a fraction of that.

      Both numbers are real and both are worth knowing: a delta is only
      as cheap as the change is small, and nothing about the technique
      rescues content that genuinely churns. }
    for N := 0 to 13 do
    begin
      Cx := 3 + Integer(Rnd(LW - 8));
      Cy := 3 + Integer(Rnd(LH - 8));
      LifeA[Cy * LW + Cx + 1] := 1;
      LifeA[(Cy + 1) * LW + Cx + 2] := 1;
      LifeA[(Cy + 2) * LW + Cx] := 1;
      LifeA[(Cy + 2) * LW + Cx + 1] := 1;
      LifeA[(Cy + 2) * LW + Cx + 2] := 1;
    end;
    LifeInit := True;
  end;

  { Draw the difference against what is already on the glass. }
  { MERGED ALONG THE ROW, because a cell is 8 separate scanline runs and
    two neighbours changing the same way are 16 runs done as 8. The
    encoder is horizontal, so anything that wants to be cheap has to be
    built horizontally -- DLBENCH test 6 measures what ignoring that
    costs. }
  Changed := 0;
  for Y := 0 to LH - 1 do
  begin
    X := 0;
    while X < LW do
    begin
      I := Y * LW + X;
      if LifeA[I] = LifeB[I] then begin Inc(X); Continue; end;
      Alive := LifeA[I];
      N := X;
      while (N < LW) and (LifeA[Y * LW + N] <> LifeB[Y * LW + N])
            and (LifeA[Y * LW + N] = Alive) do Inc(N);
      Inc(Changed, N - X);
      if Alive <> 0 then
      begin
        if not DlFillRect(T, Word(X * LCELL), Word(Y * LCELL),
                          Word((N - X) * LCELL), LCELL,
                          DlRgb(120, 255, 160)) then Exit;
      end
      else
        if not DlFillRect(T, Word(X * LCELL), Word(Y * LCELL),
                          Word((N - X) * LCELL), LCELL, Bg) then Exit;
      X := N;
    end;
  end;
  if not DlSend then Exit;

  { Step a generation into LifeB, edges wrapping -- and WITHOUT a single
    division, which is the whole reason this runs at a useful rate.

    The obvious way writes ((Y+dy+LH) mod LH) * LW + ((X+dx+LW) mod LW)
    inside the neighbour loop: four divisions per neighbour, eight
    neighbours, 4,800 cells -- over 150,000 divisions a generation. BENCH
    measures a 16-bit divide on this machine at 52,561 a second, so that
    alone is about 2.9 seconds, and it measured exactly that: 0.3 fps on
    frames costing only 4,400 bytes.

    Wrapping is a comparison, not a modulus. The row bases are computed
    once per row and the column neighbours once per cell. }
  for Y := 0 to LH - 1 do
  begin
    Yu := Y - 1; if Yu < 0 then Yu := LH - 1;
    Yd := Y + 1; if Yd >= LH then Yd := 0;
    Ru := Yu * LW;
    Rc := Y * LW;
    Rd := Yd * LW;
    for X := 0 to LW - 1 do
    begin
      Xl := X - 1; if Xl < 0 then Xl := LW - 1;
      Xr := X + 1; if Xr >= LW then Xr := 0;
      N := LifeA[Ru + Xl] + LifeA[Ru + X] + LifeA[Ru + Xr]
         + LifeA[Rc + Xl]                 + LifeA[Rc + Xr]
         + LifeA[Rd + Xl] + LifeA[Rd + X] + LifeA[Rd + Xr];
      I := Rc + X;
      if LifeA[I] <> 0 then
      begin
        if (N = 2) or (N = 3) then LifeB[I] := 1 else LifeB[I] := 0;
      end
      else
        if N = 3 then LifeB[I] := 1 else LifeB[I] := 0;
    end;
  end;

  { LifeB is the next generation; LifeA becomes what is on the screen. }
  for I := 0 to LW * LH - 1 do
  begin
    Alive := LifeA[I];
    LifeA[I] := LifeB[I];
    LifeB[I] := Alive;
  end;

  WriteLn('  gen: ', Changed, ' cells changed');
  DemoLife := True;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLDEMO [/P=260] [/M=n] [/D=name] [/S=secs] [/C]');
  WriteLn;
  WriteLn('    /D=balls   bouncing rectangles, erase-and-draw');
  WriteLn('    /D=stars   a scrolling starfield, one pixel each');
  WriteLn('    /D=cube    a rotating wireframe cube, integer maths');
  WriteLn('    /D=bars    sliding colour bars');
  WriteLn('    /D=raster  FULL-SCREEN raster bars -- one run per band,');
  WriteLn('               which is the effect this encoder is built for');
  WriteLn('    /D=life    Conway''s Life, 80x60 cells -- the only demo');
  WriteLn('               that sends a DELTA rather than a picture');
  WriteLn('    /C         clear the screen and stop');
  WriteLn('    /M=dec     mode, default 0:');
  for I := 0 to NDLMODES - 1 do
    WriteLn('                 ', I, ' = ', DlModes[I].Name);
  HelpTail;
end;

function HexArg(const S: ShortString; From: Integer): Word;
var I: Integer; V: Word;
begin
  V := 0;
  for I := From to Length(S) do
    case UpCase(S[I]) of
      '0'..'9': V := V * 16 + (Ord(S[I]) - 48);
      'A'..'F': V := V * 16 + (Ord(UpCase(S[I])) - 55);
    end;
  HexArg := V;
end;

function DecArg(const S: ShortString; From: Integer): Integer;
var I, V: Integer;
begin
  V := 0;
  for I := From to Length(S) do
    if (S[I] >= '0') and (S[I] <= '9') then V := V * 10 + (Ord(S[I]) - 48);
  DecArg := V;
end;

procedure Quieten;
begin
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

var
  I, Rc:   Integer;
  S:       ShortString;
  T0, Tk:  LongInt;
  B0:      LongInt;
  Ang:     Integer;
  Deadline: LongInt;

begin
  Banner('DLDEMO', VER, 'moving graphics over USB');
  Which := 'balls';

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'S': Secs := DecArg(S, 4);
        'C': ClearOnly := True;
        'D': Which := LowerCase(Copy(S, 4, Length(S) - 3));
        'H': begin Usage; Halt(0); end;
      end;
  end;
  if HelpWanted then begin Usage; Halt(0); end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if Secs < 1 then Secs := 1;
  T := DlModes[ModeIx];

  Tile := PWordArr(GetMem(LongInt(TSZ) * TSZ * SizeOf(Word)));
  if Tile = nil then
  begin
    WriteLn('could not get ', LongInt(TSZ) * TSZ * 2,
            ' bytes of heap for the render tile');
    Halt(9);
  end;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then begin WriteLn(DlWhy(Rc)); Halt(Rc); end;

  WriteLn('mode      ', T.Name);
  WriteLn('demo      ', Which);
  WriteLn('seconds   ', Secs);
  WriteLn;

  if not DlSetMode(T) then
  begin
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;

  Bg := DlRgb(0, 0, 48);
  if not DlFillRun(0, Bg, LongInt(T.XRes) * T.YRes) then
  begin
    WriteLn('the adapter stopped accepting pixels');
    Halt(DL_REFUSED);
  end;
  if not DlSend then WriteLn('send failed clearing the screen');

  if ClearOnly then
  begin
    WriteLn('cleared, and nothing animated (/C).');
    Halt(0);
  end;

  for I := 0 to NBALL - 1 do
  begin
    Balls[I].X := 40 + Rnd(T.XRes - BALLSZ - 80);
    Balls[I].Y := 40 + Rnd(T.YRes - BALLSZ - 80);
    Balls[I].Dx := 5 + Integer(Rnd(7));
    Balls[I].Dy := 3 + Integer(Rnd(5));
    if (I and 1) = 0 then Balls[I].Dx := -Balls[I].Dx;
    case I mod 5 of
      0: Balls[I].Col := DlRgb(255, 60, 60);
      1: Balls[I].Col := DlRgb(60, 255, 60);
      2: Balls[I].Col := DlRgb(80, 140, 255);
      3: Balls[I].Col := DlRgb(255, 220, 40);
    else
      Balls[I].Col := DlRgb(255, 255, 255);
    end;
  end;
  for I := 0 to NSTAR - 1 do
  begin
    StarX[I] := Rnd(T.XRes);
    StarY[I] := Rnd(T.YRes);
    StarV[I] := 2 + Integer(Rnd(9));
    case Rnd(4) of
      0: StarC[I] := DlRgb(255, 255, 255);
      1: StarC[I] := DlRgb(180, 200, 255);
      2: StarC[I] := DlRgb(255, 230, 190);
    else
      StarC[I] := DlRgb(140, 140, 170);
    end;
  end;

  for I := 0 to 7 do BarY[I] := -1;

  DlZeroStats;
  T0 := Ticks;
  Deadline := T0 + (LongInt(Secs) * 182) div 10;
  B0 := DlBytes;
  Ang := 0;
  Rc := 0;

  while True do
  begin
    if Ticks < T0 then Break;                  { midnight rollover }
    if Ticks >= Deadline then Break;
    DlTick;
    if DlEscaped then Break;

    if Which = 'stars' then
    begin
      if not DemoStars then begin Rc := 1; Break; end;
    end
    else if Which = 'cube' then
    begin
      if not DemoCube(Ang) then begin Rc := 1; Break; end;
      Ang := (Ang + 4) and 255;
    end
    else if Which = 'bars' then
    begin
      if not DemoBars(Ang) then begin Rc := 1; Break; end;
      Ang := (Ang + 7) mod (T.YRes - (T.YRes div 8));
    end
    else if Which = 'raster' then
    begin
      if not DemoRaster(Ang) then begin Rc := 1; Break; end;
      Ang := (Ang + 3) and 255;
    end
    else if Which = 'life' then
    begin
      if not DemoLife then begin Rc := 1; Break; end;
    end
    else
    begin
      if not DemoBalls then begin Rc := 1; Break; end;
    end;
    Inc(Frames);
  end;

  Tk := Ticks - T0;
  if Tk < 1 then Tk := 1;

  WriteLn('frames    ', Frames);
  WriteLn('ticks     ', Tk, '  (', (Tk * 10) div 182, ' s)');
  if Frames > 0 then
  begin
    { fps x10, to avoid Real: frames * 182 / ticks. }
    WriteLn('fps       ', (Frames * 182) div Tk, ' / 10  = ',
            (Frames * 182) div Tk div 10, '.',
            ((Frames * 182) div Tk) mod 10);
    WriteLn('bytes/fr  ', (DlBytes - B0) div Frames);
  end;
  WriteLn('packets   ', DlPackets);
  WriteLn('NAKs      ', DlNaks);
  if Rc <> 0 then
    WriteLn('STOPPED EARLY -- the adapter stopped accepting the stream.');
  Halt(0);
end.
