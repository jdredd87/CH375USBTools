program camlive;
{ CAMLIVE -- the camera's picture on the DOS screen, over and over.
  CH375Camera, StevenC & Claude.  Public domain (the Unlicense).

    CAMLIVE [/M=320] [/D=AUTO] [/F=n] [/G] [/H=2] [/S=300] [/N=n] [/A]
            [/O=CAM] [/B=32] [/P=260]

  Takes a picture, draws it, holds it /H seconds, and takes the next.  Contrast and colour balance follow the
  scene: each picture is stretched by the previous one's histogram.

    /M   the camera mode -- 176 (176x144 YUV, 3 frames a picture), 320
         (320x240, 5 frames), 352 (352x288, the whole sensor, 6 frames).
         A frame is about a third of a second.
    /D   the screen -- AUTO (VESA 640x480 if this boot has it, else mode
         X 320x240), VESA, X, 13, 12 (640x480 in 16 greys), T50 (80x50
         text, half-block cells: 80x100), T25 (80x25 text), ASCII.  The
         text modes are the fastest and work on a mono card.
    /F   detail: 1 every pixel, 2 every other (the default in graphics),
         4 every fourth.  Drawing is most of the time on this CPU, and /F
         divides it by F squared.  The text modes choose their own.
    /G   grey instead of colour -- about twice as fast to draw.
    /A   when it stops, print the last picture as ASCII art on stdout,
         which is how it can be looked at through DOSBridge.

  Keys while it runs: S saves the picture (CAMn.BMP, or /O=name as the
  prefix), C switches colour and grey, Q or Esc stops.

  THE BUTTON on the camera saves the picture, like S.  It is register
  0113, latched, and checked after every strip taken, every strip drawn,
  and all through the hold; the save happens once the picture is whole.
  Checking once a picture was tried first and missed nearly every press:
  restarting the stream for each strip appears to clear the latch.

  WHERE THE TIME GOES, measured on the development machine (a V30):
  taking a 320x240 picture is 1.7 s; drawing it is 4.3 s in colour at /F=1
  and 1.0 s at /F=2, 2.2 s and 0.55 s in grey -- all of it in camfast's
  assembly, which FASTTEST checks against Pascal.  The text modes draw
  in a few hundred milliseconds. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses ch375, chtool, cit, camgrab, camdisp, camfile, camfast, vidfix;

const
  VER = '0.6.0';

var
  ModeNo:  Integer = 2;
  DispK:   TDisp = dAuto;
  Colour:  Boolean = True;
  Detail:  Integer = 0;            { 0 = let the display decide }
  HoldS:   Word = 2;
  Secs:    Word = 300;
  Count:   LongInt = 0;
  AsciiOut: Boolean = False;
  SavePfx: ShortString = 'CAM';
  Paint:   Boolean = False;        { /I: paint each strip as it lands }
  Rough:   Boolean = False;        { /R: no screen-resolution dither }
  Ready:   Boolean = False;        { /K: beep when ready for the button }
  ColourSaid: Boolean = False;     { /C or /G given: do not choose for me }

procedure Usage;
begin
  WriteLn;
  WriteLn('CAMLIVE [/M=n] [/D=disp] [/F=n] [/G] [/H=n] [/S=n] [/N=n] [/A]');
  WriteLn('        [/O=name] [/B=n] [/P=hex]');
  WriteLn;
  WriteLn('The camera''s picture on the screen, over and over.');
  WriteLn;
  WriteLn('  /M=n     176, 320 (default) or 352');
  WriteLn('  /D=x     AUTO VESA X 13 12 T50 T25 ASCII');
  WriteLn('  /F=n     detail 1, 2 or 4: every pixel, every other, every 4th');
  WriteLn('  /G       grey.  /C colour.  Default: colour, but grey in the');
  WriteLn('           text modes, where 16 greys beat 16 colours');
  WriteLn('  /H=n     seconds to hold each picture.  Default 2');
  WriteLn('  /S=n     stop after n seconds.  Default 300');
  WriteLn('  /N=n     stop after n pictures');
  WriteLn('  /A       print the last picture as ASCII on stdout at the end');
  WriteLn('  /K       beep three times when ready -- the button saves a');
  WriteLn('           picture from then on, with a chirp each time');
  WriteLn('  /R       rough: dither per sample, not per screen pixel.  About');
  WriteLn('           a second a picture faster, and blockier');
  WriteLn('  /I       paint each strip as it arrives (slower: each strip then');
  WriteLn('           waits for the next camera frame)');
  WriteLn('  /O=name  prefix for saved pictures.  Default CAM');
  WriteLn('  /B=n     brightness 0..63.  Default 32');
  HelpBaseLine;
  WriteLn;
  WriteLn('Keys: S save, C colour/grey, Q or Esc stop.');
  HelpTail;
end;

procedure ParseArgs;
var
  I, C: Integer;
  A, V: ShortString;
  N: LongInt;
  Ok: Boolean;
  K: TDisp;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if (Length(A) < 2) or not (A[1] in ['/', '-']) then
    begin
      WriteLn('unknown argument: ', A); Halt(2);
    end;
    V := Copy(A, 4, 255);
    Val(V, N, C);
    Ok := True;
    case UpCase(A[2]) of
      'P': begin Val('$' + V, N, C); Ok := C = 0; Base := N; end;
      'M': case N of
             176: ModeNo := 1;
             320: ModeNo := 2;
             352: ModeNo := 3;
           else Ok := False;
           end;
      'D': begin
             Ok := False;
             for C := 1 to Length(V) do V[C] := UpCase(V[C]);
             for K := Low(TDisp) to High(TDisp) do
               if DispName[K] = V then begin DispK := K; Ok := True; end;
           end;
      'F': begin Ok := (N = 1) or (N = 2) or (N = 4); Detail := N; end;
      'G': begin Colour := False; ColourSaid := True; end;
      'C': begin Colour := True; ColourSaid := True; end;
      'H': begin Ok := (C = 0) and (N >= 0) and (N < 600); HoldS := N; end;
      'S': begin Ok := (C = 0) and (N > 0) and (N < 36000); Secs := N; end;
      'N': begin Ok := (C = 0) and (N > 0); Count := N; end;
      'A': AsciiOut := True;
      'I': Paint := True;
      'R': Rough := True;
      'K': Ready := True;
      'O': begin SavePfx := V; Ok := (V <> '') and (Length(V) <= 60); end;
      'B': begin Ok := (C = 0) and (N >= 0) and (N <= 63); Brightness := N; end;
      'L': ;            { /L: phase log, handled in the main body }
    else
      Ok := False;
    end;
    if not Ok then begin WriteLn('bad argument: ', A); Halt(2); end;
  end;
end;

function GetKey: Char; assembler;
asm
  xor ah, ah
  int 16h
end;

function Num(N: LongInt): ShortString;
var S: ShortString;
begin
  Str(N, S);
  Num := S;
end;

{ ---- geometry ----

  The picture is drawn from a VIRTUAL picture of VW x VH samples: every
  Stride-th pixel (Stride = the /F detail).  MapX/MapY say which virtual
  sample each screen pixel shows.  When the screen is a whole-number
  multiple of the virtual picture the row is widened by camfast.Expand;
  otherwise (a picture larger than the screen, or the text grid) each
  screen pixel is looked up. }
var
  Stride: Integer;
  VW, VH: Integer;
  MapX: array[0..639] of Word;
  MapY: array[0..479] of Word;
  OX, OY, DW, DH, DS: Integer;       { DS = whole-number scale, 0 if none }
  { Dither at screen resolution: when a sample is drawn as a block, each
    sample is quantised at two thresholds and the block checkerboarded
    between them, instead of one flat value.  Not in mode 12h, whose
    planes are built once per picture row and only copied for repeats. }
  Fine: Boolean;

procedure BuildMap;
var S, I: Integer;
begin
  Stride := Detail;
  if TextMode then
  begin
    { about one sample per text column }
    if Stride = 0 then
    begin
      Stride := Mode.W div 80;
      if Stride >= 4 then Stride := 4 else if Stride >= 2 then Stride := 2
      else Stride := 1;
    end;
  end
  else if Stride = 0 then Stride := 2;
  VW := Mode.W div Stride;
  VH := Mode.H div Stride;
  DS := 0;
  if TextMode then
  begin
    DW := ScrW; DH := ScrH;
  end
  else
  begin
    S := ScrW div VW;
    if ScrH div VH < S then S := ScrH div VH;
    if S >= 1 then
    begin
      DS := S; DW := VW * S; DH := VH * S;
    end
    else
    begin
      DW := ScrW; DH := LongInt(ScrW) * VH div VW;
      if DH > ScrH then begin DH := ScrH; DW := LongInt(ScrH) * VW div VH; end;
    end;
  end;
  OX := (ScrW - DW) div 2;
  OY := (ScrH - DH) div 2;
  { mode X writes four pixels a byte: keep the picture on a 4-pixel edge }
  if Disp = dModeX then OX := OX and not 3;
  for I := 0 to DW - 1 do MapX[I] := LongInt(I) * VW div DW;
  for I := 0 to DH - 1 do MapY[I] := LongInt(I) * VH div DH;
  Fine := (not TextMode) and (DS >= 2) and (Disp <> d12) and not Rough;
end;

{ ---- levels ----

  camfast's SLut stretches each channel (grey uses SLutG) by the previous
  picture's 1st and 99th percentiles; its Cube, GQt and N16t tables turn
  the result into what the screen shows, with a 2x2 ordered dither. }
var
  Hist: array[0..2, 0..63] of Word;

const
  Dith: array[0..3] of Byte = (0, 2, 3, 1);
  { 6 x 6 x 6: the same six levels in every channel, so a grey lands on
    the cube's diagonal and stays grey.  6 x 7 x 6 was tried first -- one
    more green -- and turned every grey surface into a coloured
    checkerboard, because no grey sits on its lattice. }
  CubeLv: array[0..2] of Byte = (5, 5, 5);
  CubeMul: array[0..2] of Byte = (36, 6, 1);

procedure BuildQuant;
var
  Ch, D, V, Q, L, R, G, B: Integer;
begin
  L := Levels - 1;
  for D := 0 to 3 do
    for V := 0 to 255 do
    begin
      Q := (LongInt(V) * L * 4 + Dith[D] * 255) div (255 * 4);
      if Q > L then Q := L;
      GQt[D, V] := Q;
      for Ch := 0 to 2 do
      begin
        Q := (LongInt(V) * CubeLv[Ch] * 4 + Dith[D] * 255) div (255 * 4);
        if Q > CubeLv[Ch] then Q := CubeLv[Ch];
        case Ch of
          0: CubeR[D, V] := Q * CubeMul[0];
          1: CubeG[D, V] := Q * CubeMul[1];
          2: CubeB[D, V] := Q * CubeMul[2];
        end;
      end;
    end;
  for R := 0 to 15 do
    for G := 0 to 15 do
      for B := 0 to 15 do
        N16t[(R shl 8) or (G shl 4) or B] := Nearest16(R * 17, G * 17, B * 17);
end;

procedure BuildYuvTables;
var I: Integer;
begin
  for I := 0 to 255 do
  begin
    YRV[I] := ((I - 128) * 359) div 256;
    YBU[I] := ((I - 128) * 454) div 256;
    YGU[I] := ((I - 128) * 88) div 256;
    YGV[I] := ((I - 128) * 183) div 256;
  end;
end;

procedure LinearLut;
var V: Integer;
begin
  for V := 0 to 255 do
  begin
    SLutR[V] := V; SLutG[V] := V; SLutB[V] := V;
  end;
  FillChar(Hist, SizeOf(Hist), 0);
end;

{ One stretch for all three channels: from the lowest channel's 1st
  percentile to the highest channel's 99th.  Stretching each channel on its
  own -- tried first, as a free white balance -- pulled grey surfaces off
  grey, and the dither then turned them into coloured noise. }
procedure StretchLut;
var
  Ch, I, Lo, Hi, V, GLo, GHi: Integer;
  Total, Acc: LongInt;
begin
  GLo := 999; GHi := -1;
  for Ch := 0 to 2 do
  begin
    Total := 0;
    for I := 0 to 63 do Inc(Total, Hist[Ch, I]);
    if Total < 200 then Continue;
    Acc := 0; Lo := 0;
    for I := 0 to 63 do
    begin
      Inc(Acc, Hist[Ch, I]);
      if Acc > Total div 100 then begin Lo := I; Break; end;
    end;
    Acc := 0; Hi := 63;
    for I := 63 downto 0 do
    begin
      Inc(Acc, Hist[Ch, I]);
      if Acc > Total div 100 then begin Hi := I; Break; end;
    end;
    if Lo < GLo then GLo := Lo;
    if Hi > GHi then GHi := Hi;
  end;
  FillChar(Hist, SizeOf(Hist), 0);
  if GHi < 0 then Exit;
  Lo := GLo * 4; Hi := GHi * 4 + 3;
  if Hi - Lo < 24 then Hi := Lo + 24;
  for I := 0 to 255 do
  begin
    V := LongInt(I - Lo) * 255 div (Hi - Lo);
    if V < 0 then V := 0;
    if V > 255 then V := 255;
    SLutR[I] := V; SLutG[I] := V; SLutB[I] := V;
  end;
end;

{ A few samples of this row into the histogram -- every 4th value of
  every 8th row is plenty and keeps it off the clock. }
procedure Sample(N: Integer);
var K: Integer;
begin
  K := 0;
  while K < N do
  begin
    if Colour then
    begin
      Inc(Hist[0, FR[K] shr 2]); Inc(Hist[1, FG[K] shr 2]);
      Inc(Hist[2, FB[K] shr 2]);
    end
    else Inc(Hist[1, FG[K] shr 2]);
    Inc(K, 4);
  end;
end;

{ ---- drawing a strip ---- }

var
  RIe, BIe, RIo, BIo: array[0..1] of Byte;   { by row parity }

procedure BuildCorners;
var Y, X, K, P, Cor: Integer;
begin
  { which corner of a 2x2 is red / blue, for a block starting on an even
    (e) or odd (o) column, on an even or odd row -- from camgrab's order }
  for Y := 0 to 1 do
    for X := 0 to 1 do
      for K := 0 to 3 do
      begin
        Cor := BayerOrder[(((Y + (K shr 1)) and 1) shl 1) or ((X + (K and 1)) and 1)];
        P := K;
        if X = 0 then
        begin
          if Cor = 0 then RIe[Y] := P;
          if Cor = 2 then BIe[Y] := P;
        end
        else
        begin
          if Cor = 0 then RIo[Y] := P;
          if Cor = 2 then BIo[Y] := P;
        end;
      end;
end;

{ Virtual row VY, virtual columns V0 .. V0+N-1, into FQ. }
procedure RenderRow(VY, V0, N: Integer);
var
  SY, YS, X0, NB, K: Integer;
  Row: Word;
begin
  SY := VY * Stride;
  X0 := V0 * Stride;
  Row := VY and 1;
  if Mode.Fmt = fmtBayer then
  begin
    YS := SY;
    if YS > Mode.H - 2 then YS := Mode.H - 2;
    NB := N * Stride;                            { source bytes }
    Move(Pix[YS]^[X0], FA, NB);
    Move(Pix[YS + 1]^[X0], FC, NB);
    { the byte after the run, for the last 2x2 }
    if X0 + NB < Mode.W then
    begin
      FA[NB] := Pix[YS]^[X0 + NB]; FC[NB] := Pix[YS + 1]^[X0 + NB];
    end
    else
    begin
      FA[NB] := FA[NB - 2]; FC[NB] := FC[NB - 2];
    end;
    if Colour then
    begin
      if Stride = 1 then BayerRGB(N, RIe[YS and 1], BIe[YS and 1],
                                  RIo[YS and 1], BIo[YS and 1])
      else BayerCellRGB(N, Stride, RIe[YS and 1], BIe[YS and 1]);
    end
    else
    begin
      if Stride = 1 then BayerGrey(N) else BayerCellGrey(N, Stride);
    end;
  end
  else
  begin
    if Stride = 1 then
    begin
      Move(Pix[SY]^[X0], FA, N);
      Move(UPix[SY shr 1]^[X0 shr 1], FU, (N + 1) shr 1);
      Move(VPix[SY shr 1]^[X0 shr 1], FV, (N + 1) shr 1);
    end
    else
      for K := 0 to N - 1 do
      begin
        FA[K] := Pix[SY]^[X0 + K * Stride];
        FU[K shr 1] := UPix[SY shr 1]^[(X0 + K * Stride) shr 1];
        FV[K shr 1] := VPix[SY shr 1]^[(X0 + K * Stride) shr 1];
      end;
    if Colour then YuvRGB(N) else Move(FA, FG, N);
  end;
  if VY and 7 = 0 then Sample(N);
  if Fine then
  begin
    { two thresholds, a quarter and three quarters of a step: Expand2
      checkerboards them across the screen }
    if Colour then
    begin
      QuantCubeP(N, 3, 3, False); QuantCubeP(N, 2, 2, True);
    end
    else
    begin
      QuantGreyP(N, 3, 3, False); QuantGreyP(N, 2, 2, True);
    end;
  end
  else if not Colour then QuantGrey(N, Row)
  else if TextMode and (Disp <> dAscii) then Quant16(N)
  else QuantCube(N, Row);
end;

procedure DrawStrip(X, W: Word);
var
  V0, V1, DX0, DX1, DY, K, N, NV: Integer;
  VY, LastVY: Integer;
begin
  V0 := X div Stride;
  V1 := (X + W) div Stride;                      { exclusive }
  if V1 > VW then V1 := VW;
  NV := V1 - V0;
  if NV <= 0 then Exit;
  DX0 := -1; DX1 := -1;
  for K := 0 to DW - 1 do
    if (MapX[K] >= V0) and (MapX[K] < V1) then
    begin
      if DX0 < 0 then DX0 := K;
      DX1 := K;
    end;
  if DX0 < 0 then Exit;
  N := DX1 - DX0 + 1;
  LastVY := -1;
  for DY := 0 to DH - 1 do
  begin
    VY := MapY[DY];
    if Fine then
    begin
      { both checkerboard phases once per sample row; screen rows then
        alternate between them }
      if VY <> LastVY then
      begin
        RenderRow(VY, V0, NV);
        Expand2(NV, DS, False, False);
        Expand2(NV, DS, True, True);
        LastVY := VY;
      end;
      if Disp = dModeX then ModeXRow(OX + DX0, OY + DY, N, DY and 1 = 1)
      else if DY and 1 = 0 then PutRow(OX + DX0, OY + DY, FL, N)
      else PutRow(OX + DX0, OY + DY, FL2, N);
    end
    else if VY <> LastVY then
    begin
      RenderRow(VY, V0, NV);
      if DS > 0 then Expand(NV, DS)
      else for K := 0 to N - 1 do FL[K] := FQ[MapX[DX0 + K] - V0];
      LastVY := VY;
      if Disp = dModeX then ModeXRow(OX + DX0, OY + DY, N)
      else PutRow(OX + DX0, OY + DY, FL, N);
    end
    else if Disp = dModeX then ModeXRow(OX + DX0, OY + DY, N)
    else PutRowAgain(OY + DY, FL, OX + DX0, N);
  end;
end;

{ The PC speaker through the timer ports, for Ms of the BIOS clock. }
procedure Tone(Hz, Ms: Word);
var Dv: Word; T: LongInt;
begin
  Dv := 1193182 div Hz;
  OutB($43, $B6);
  OutB($42, Lo(Dv)); OutB($42, Hi(Dv));
  OutB($61, InB($61) or 3);
  T := Ticks + (LongInt(Ms) * 182 + 9999) div 10000;
  while Ticks < T do ;
  OutB($61, InB($61) and $FC);
end;

{ ---- the button ----

  Register 0113, measured with CAMBTN: 01 at rest, 00 when pressed, and
  it LATCHES -- it stays 00 until 01 is written back, and a write while the
  button is still held does nothing.  So: clear it at the start, and
  between pictures a 00 is a press (once), acknowledged until it reads 01
  again.  The latch is what lets a check every few seconds catch a press
  that happened in between. }

var
  BtnHeld: Boolean = False;
  BtnPresses: Integer = 0;
  SavePending: Boolean = False;

procedure ButtonReset;
begin
  RegW($0001, $0113);
  BtnHeld := False;
end;

function ButtonPressed: Boolean;
var V: Byte;
begin
  ButtonPressed := False;
  if RegR($0113, V) <> INT_SUCCESS then Exit;
  if V = 0 then
  begin
    RegW($0001, $0113);
    if not BtnHeld then
    begin
      BtnHeld := True;
      Inc(BtnPresses);
      ButtonPressed := True;
    end;
  end
  else BtnHeld := False;
end;

procedure PollButton;
begin
  if ButtonPressed then SavePending := True;
end;

procedure StripTaken(X, W: Word);
begin
  PollButton;
end;


{ ---- main ---- }

var
  R, Bad: Integer;
  SX, SW: Word;
  Pictures, Saves: LongInt;
  T0, TEnd, THold, TP: LongInt;
  Stop: Boolean;
  Ch: Char;
  LastPicMs: LongInt;

procedure Save;
var Name: ShortString;
begin
  Inc(Saves);
  Name := SavePfx + Num(Saves) + '.BMP';
  WriteBmp(Name, not Colour);
  Status(' saved ' + Name + ' ');
end;

procedure Keys;
begin
  while KeyWaiting do
  begin
    Ch := UpCase(GetKey);
    case Ch of
      'Q', #27: Stop := True;
      'S': Save;
      'C': if not ((Disp = d12) or (Disp = dAscii) or Mono) then
           begin
             Colour := not Colour;
             DispClose;
             DispOpen(Disp, Colour);
             BuildMap;
             LinearLut;
           end;
    end;
  end;
end;

{ /L: write each phase to C:\WORK\CAMLIVE.LOG, closing the file every
  time, so a machine that dies mid-run still says where it got to. }
var
  Logging: Boolean = False;

procedure Log(const S: string);
var F: Text;
begin
  if not Logging then Exit;
  Assign(F, 'C:\WORK\CAMLIVE.LOG');
  {$I-} Append(F); {$I+}
  if IOResult <> 0 then begin Assign(F, 'C:\WORK\CAMLIVE.LOG'); Rewrite(F); end;
  WriteLn(F, S);
  Close(F);
end;

begin
  Logging := ParamStr(1) = '/L';
  if not Logging then
    for R := 1 to ParamCount do if ParamStr(R) = '/L' then Logging := True;
  Log('--- CAMLIVE start');
  Log('vidfix : ' + VidFixReport);
  Log('  from ' + Num(VidFixFrom shr 16) + ':' + Num(VidFixFrom and $FFFF) +
      '  to ' + Num(VidFixTo shr 16) + ':' + Num(VidFixTo and $FFFF));
  Banner('CAMLIVE', VER, 'the camera''s picture on the screen');
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  PortDat := Base; PortCmd := Base + 1;

  Log('CamStart');
  R := CamStart(ModeNo, 0);
  if R <> 0 then Halt(R);
  Log('  CamStart ok, blanking ' + Num(BlankRun));
  ButtonReset;
  Log('  ButtonReset done');                     { a press latched earlier is not ours }

  Log('DispOpen');
  if not DispOpen(DispK, Colour) then
  begin
    CamStop;
    WriteLn('display ', DispName[DispK], ' is not available: ', VesaWhy);
    Halt(13);
  end;
  { mode 12h, ASCII and a mono card have no colour to show; and in the
    other text modes 16 greys draw a photograph better than 16 colours --
    compared on the screen, same scene -- unless /C asks for colour }
  if (Disp = d12) or (Disp = dAscii) or Mono then Colour := False
  else if TextMode and not ColourSaid then
  begin
    Colour := False;
    DispClose;
    DispOpen(Disp, False);
  end;
  Log('  DispOpen ok');
  Log('BuildMap');       BuildMap;
  Log('BuildQuant');     BuildQuant;
  Log('BuildYuvTables'); BuildYuvTables;
  Log('BuildCorners');   BuildCorners;
  Log('LinearLut');      LinearLut;
  Log('  tables built');

  Pictures := 0; Saves := 0;
  if Ready then
    for R := 1 to 3 do begin Tone(1200, 200); Tone(20000, 100); end;
  T0 := Ticks;
  TEnd := T0 + LongInt(Secs) * 182 div 10;
  Stop := False;
  LastPicMs := 0;
  Bad := 0;
  while not Stop do
  begin
    TP := Ticks;
    Log('picture: GrabPicture');
    if Paint then Inc(Bad, GrabPicture(@DrawStrip, 6))
    else
    begin
      { take every strip back to back, then draw: drawing between strips
        makes each grab miss the start of the next frame and wait a whole
        one more -- measured, a 320x240 picture went from 1.7 s to 3.4 s
        of capture with nothing but ASCII drawn between the strips }
      Inc(Bad, GrabPicture(@StripTaken, 6));
      Log('  grabbed; DrawStrip');
      { once every strip is in, the picture is whole: draw it line by line
        across the full width -- fewer, longer rows than strip by strip,
        and the screen fills top to bottom }
      DrawStrip(0, Mode.W);
      Log('  drawn');
      PollButton;
    end;
    LastPicMs := (Ticks - TP) * 55;
    Inc(Pictures);
    Log('  StretchLut');
    StretchLut;
    Log('  Status');
    Status(' ' + Num(Pictures) + '  ' + Num(Mode.W) + 'x' + Num(Mode.H) +
           ' /F' + Num(Stride) + '  ' + Num(LastPicMs) + ' ms ');
    PollButton;
    if SavePending then
    begin
      SavePending := False;
      Tone(2000, 80);
      Save;
      Status(' BUTTON: saved ' + SavePfx + Num(Saves) + '.BMP ');
    end;
    Log('  Keys');
    Keys;
    Log('  hold');
    { hold the picture -- the last one too, or /N=1 shows it for no time }
    THold := Ticks + LongInt(HoldS) * 182 div 10;
    while (not Stop) and (Ticks < THold) do
    begin
      Keys;
      PollButton;
      if SavePending then
      begin
        SavePending := False;
        Tone(2000, 80);
        Save;
        Status(' BUTTON: saved ' + SavePfx + Num(Saves) + '.BMP ');
      end;
      if Ticks >= TEnd then Stop := True;
    end;
    if (Count > 0) and (Pictures >= Count) then Stop := True;
    if Ticks >= TEnd then Stop := True;
  end;

  DispClose;
  CamStop;

  Write('mode    : ', Mode.W, 'x', Mode.H, ' on ', DispName[Disp],
        ', detail /F', Stride, ', ');
  if Colour then Write('colour') else Write('grey');
  if VesaWhy <> '' then Write('  (no VESA: ', VesaWhy, ')');
  WriteLn;
  WriteLn('pictures: ', Pictures, ' in ', (Ticks - T0) * 10 div 182,
          ' s; the last took ', LastPicMs, ' ms to take and draw; ',
          Bad, ' strips missed');
  WriteLn('saved   : ', Saves, '   button presses seen: ', BtnPresses);
  if AsciiOut then begin WriteLn; AsciiArt(Output, 79); end;
  { 12, as CAMSNAP: some strip never arrived whole }
  if Bad > 0 then Halt(12);
  Halt(0);
end.
