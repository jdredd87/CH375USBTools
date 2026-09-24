program dlfract;
{ DLFRACT -- compute a Mandelbrot set in fixed point and show it over USB.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLFRACT [/P=260] [/M=n] [/W=n] [/I=n] [/S=secs] [/R] [/8] [/Z=n]

      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0 (640x480@60)
      /W=dec   COMPUTED width, default 160.  The picture is expanded to
               fill the mode, so this is detail, not size
      /I=dec   iteration limit, default 16
      /S=dec   seconds to hold the finished picture, default 5
      /R       draw the rows as they are computed, instead of computing
               the whole picture and then sending it
      /8       force the 8087 path
      /Q       force the Q8 integer path
               (with neither, the right one is CHOSEN -- see below)
      /Z=dec   zoom in on the seahorse valley by this factor, default 1

  WHY THIS IS HERE, AND WHAT IT MEASURES

  Every other tool in CH375Video is transfer-bound: the CPU has nothing
  much to do and the USB path is the whole cost. This one inverts that
  deliberately, and then TIMES BOTH HALVES SEPARATELY so the claim is
  measured rather than asserted.

  A Mandelbrot is the right load for it because the arithmetic is
  irreducible -- there is no encoding trick that makes the escape-time
  loop cheaper -- while the PICTURE is unusually kind to a run-length
  encoder, being made of large flat bands of equal iteration count.

  THE ARITHMETIC IS Q8 AND 16-BIT, WHICH IS THE WHOLE PERFORMANCE STORY.
  BENCH on this machine measures a 16-bit multiply at 58,640 a second and
  a 32-bit one at 10,920 -- 5.4x -- because FPC calls a software routine
  for LongInt. The inner loop needs three multiplies per iteration, so
  done in LongInt a 160x100 picture at 16 iterations would spend about
  70 seconds in the multiplier alone. MulQ8 below is a single 16x16->32
  IMUL and a shift across the register pair, which is what makes this
  finish in a useful time. CLAUDE.md records the same lesson from the
  dosbridge Mandelbrot: moving it from Q10 LongInt to Q8 with one IMUL
  was worth more than every other optimisation combined.

  Q8 means 1.0 is 256, and the escape radius of 2 squared is 4.0 = 1024.
  zr and zi stay inside +/-512, so their products fit the 16-bit result
  the shift produces.

  AND THERE IS A COPROCESSOR, so /8 runs the same picture through it and
  the two can be compared instead of argued about. Two things are worth
  separating in that comparison:

  SPEED is not the coprocessor's advantage here, and that is MEASURED on
  this machine, not assumed:

      Q8 integer   compute 20.4 s
      8087 double  compute 40.7 s

  Two to one to the integer path, because an 8087 FMUL is of the order of
  a hundred clocks plus the handshake against roughly 25 for a 16-bit
  IMUL. So "there is a coprocessor, use it" is the wrong rule here.

  PRECISION is. Q8 has EIGHT fractional bits, so its whole grid is 1/256
  apart. The default view spans 3.0 across the picture, which is already
  only a few Q8 steps per pixel, and zooming past about 8x leaves Q8 with
  less than one step per pixel: the picture goes blocky and then wrong.
  The 8087's 64-bit mantissa does not care. /Z zooms, and the difference
  shows up immediately.

  SO THE CHOICE IS AUTOMATIC, and made on whether Q8 can resolve the view
  rather than on what hardware happens to be fitted. Q8's grid is 1/256,
  so the question is how many of those steps fall across one pixel:

      steps per pixel = (768 / zoom) / computed width

  Below about two, Q8 is quantising the picture rather than drawing it,
  and the coprocessor is used IF ONE ANSWERED THE PROBE. Above that the
  integer path runs, because it is twice as fast and loses nothing. /8
  and /Q override in either direction.

  With no coprocessor fitted the integer path is simply used throughout
  and the tool says so -- a deep zoom then comes out visibly blocky, which
  is an honest picture of what the machine can do rather than a refusal.

  The probe itself is FNINIT then FNSTCW, both NO-WAIT forms and safe with
  nothing socketed. The arithmetic after them is not safe, so it is never
  reached unless the probe answered.

  Exit codes: 0 ok, 9 out of heap, otherwise the DlOpen reason (all <= 20) }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

uses ch375, chtool, dl;

const
  VER = '1.0.0';
  MAXW = 320;                 { widest picture we will compute }
  MAXH = 200;

type
  TIter = array[0..MAXW * MAXH - 1] of Byte;
  PIter = ^TIter;
  TRow  = array[0..1023] of Word;

var
  FpuCw:    Word;
  UseFpu:   Boolean = False;
  ForceFpu: Boolean = False;
  ForceInt: Boolean = False;
  FpuThere: Boolean = False;
  StepsPP:  LongInt = 0;
  Zoom:    Integer = 1;
  T:       TDlTiming;
  ModeIx:  Integer = 0;
  CW:      Integer = 160;     { computed width  }
  CH_:     Integer = 100;     { computed height }
  MaxIt:   Integer = 16;
  Secs:    Integer = 5;
  AsYouGo: Boolean = False;
  Iter:    PIter;
  Row:     TRow;
  Pal:     array[0..31] of Word;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ (A*B) >> 8 as ONE 16x16->32 IMUL and a shift across DX:AX.

  FPC has no 16-bit fixed-point multiply, so writing this in Pascal as
  (LongInt(A) * B) shr 8 calls the 32-bit software multiply -- 10,920 a
  second against 58,640 for the 16-bit instruction. Three of these run per
  Mandelbrot iteration, so that difference is the difference between this
  tool finishing and this tool being abandoned.

  The shift is the classic trick: the result's low word is the high byte
  of AX joined to the low byte of DX. }
function MulQ8(A, B: Integer): Integer; assembler;
asm
    mov  ax, [A]
    imul word ptr [B]
    mov  al, ah
    mov  ah, dl
end;

{ FNINIT then read the control word back.  Both are NO-WAIT forms, so
  this is safe with nothing socketed -- which is the whole reason the
  probe is written this way rather than just doing a multiply and seeing
  what happens. 03FF is an 8087, 037F a 287 or later. }
function HasFpu: Boolean; assembler;
asm
    fninit
    mov   word ptr [FpuCw], $5A5A
    fnstcw word ptr [FpuCw]
    mov   ax, [FpuCw]
    and   ax, $103F
    cmp   ax, $003F
    mov   al, 0
    jne   @nofpu
    mov   al, 1
@nofpu:
end;

{ The same escape-time loop in double precision.  Deliberately a separate
  function rather than a flag inside the integer one: mixing them would
  put a branch in the inner loop and make the comparison meaningless. }
function EscapeFpu(Cr, Ci: Double): Byte;
var
  Zr, Zi, Zr2, Zi2: Double;
  N: Integer;
begin
  Zr := 0.0; Zi := 0.0;
  for N := 1 to MaxIt do
  begin
    Zr2 := Zr * Zr;
    Zi2 := Zi * Zi;
    if Zr2 + Zi2 > 4.0 then
    begin
      EscapeFpu := Byte(N);
      Exit;
    end;
    Zi := 2.0 * Zr * Zi + Ci;
    Zr := Zr2 - Zi2 + Cr;
  end;
  EscapeFpu := 0;
end;

procedure BuildPal;
var I: Integer;
begin
  { A ramp that stays legible on a capture card: dark blue through cyan
    and yellow to white, with the interior black. }
  for I := 0 to 31 do
    if I = 0 then Pal[I] := DlRgb(0, 0, 0)
    else if I < 6  then Pal[I] := DlRgb(0, 0, 60 + I * 30)
    else if I < 12 then Pal[I] := DlRgb(0, (I - 5) * 38, 255)
    else if I < 20 then Pal[I] := DlRgb((I - 11) * 30, 255, 255 - (I - 11) * 28)
    else if I < 27 then Pal[I] := DlRgb(255, 255, (I - 19) * 34)
    else Pal[I] := DlRgb(255, 255, 255);
end;

{ The escape-time loop, Q8 throughout.  1.0 is 256; the escape test is
  |z|^2 > 4.0, which is 1024. }
function Escape(Cr, Ci: Integer): Byte;
var
  Zr, Zi, Zr2, Zi2: Integer;
  N: Integer;
begin
  Zr := 0; Zi := 0;
  for N := 1 to MaxIt do
  begin
    Zr2 := MulQ8(Zr, Zr);
    Zi2 := MulQ8(Zi, Zi);
    if Zr2 + Zi2 > 1024 then
    begin
      Escape := Byte(N);
      Exit;
    end;
    Zi := MulQ8(Zr, Zi) * 2 + Ci;
    Zr := Zr2 - Zi2 + Cr;
  end;
  Escape := 0;                        { never escaped: inside the set }
end;

{ One computed row, expanded to fill the mode's width and sent as however
  many scanlines that row is worth.  Adjacent expanded pixels are
  identical, so the encoder collapses each into one run -- which is why a
  low computed width costs almost nothing extra to display large. }
function SendRow(Cy: Integer): Boolean;
var
  X, I, Sc, BW, BH, Y0: Integer;
  C: Word;
begin
  SendRow := False;
  BW := T.XRes div CW;
  BH := T.YRes div CH_;
  if BW < 1 then BW := 1;
  if BH < 1 then BH := 1;

  for X := 0 to CW - 1 do
  begin
    { 0 means it never escaped -- the interior, and the only black.
      Everything else cycles through 1..31 so a high iteration count
      bands rather than saturating. }
    I := Iter^[Cy * CW + X];
    if I = 0 then C := Pal[0] else C := Pal[((I - 1) mod 31) + 1];
    for I := 0 to BW - 1 do
      if X * BW + I < SizeOf(Row) div 2 then Row[X * BW + I] := C;
  end;

  Y0 := Cy * BH;
  for Sc := 0 to BH - 1 do
  begin
    if Y0 + Sc >= T.YRes then Break;
    if not DlRleRun(DlAddr(T, 0, Word(Y0 + Sc)), @Row[0],
                    Word(CW * BW)) then Exit;
  end;
  SendRow := True;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLFRACT [/P=260] [/M=n] [/W=n] [/I=n] [/S=secs] [/R]');
  WriteLn;
  WriteLn('    /W=dec  computed width, default 160 (detail, not size)');
  WriteLn('    /I=dec  iteration limit, default 16');
  WriteLn('    /S=dec  seconds to hold the picture, default 5');
  WriteLn('    /R      draw rows as they are computed');
  WriteLn('    /8      force the 8087 path');
  WriteLn('    /Q      force the Q8 integer path');
  WriteLn('    /Z=dec  zoom on the seahorse valley, default 1');
  WriteLn('    /M=dec  mode, default 0:');
  for I := 0 to NDLMODES - 1 do
    WriteLn('              ', I, ' = ', DlModes[I].Name);
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
  I, Rc, X, Y: Integer;
  S:           ShortString;
  Cr, Ci:      Integer;
  X0, X1, Y0, Y1: Integer;
  FCx, FCy, FSpanX, FSpanY, FCr, FCi: Double;
  TComp, TSend, T0, TAll: LongInt;
  B0:          LongInt;

begin
  Banner('DLFRACT', VER, 'a Mandelbrot in fixed point, shown over USB');

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'W': CW := DecArg(S, 4);
        'I': MaxIt := DecArg(S, 4);
        'S': Secs := DecArg(S, 4);
        'R': AsYouGo := True;
        'Z': Zoom := DecArg(S, 4);
        '8': ForceFpu := True;
        'Q': ForceInt := True;
      end;
  end;
  if HelpWanted then begin Usage; Halt(0); end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if CW < 40 then CW := 40;
  if CW > MAXW then CW := MAXW;
  if MaxIt < 2 then MaxIt := 2;
  { A deep zoom needs iterations, not just precision: at 16x most of the
    view either escapes at once or survives the limit, and a low cap
    paints all of the latter black.  The palette CYCLES instead of
    clamping, so the count is free to go high. }
  if MaxIt > 250 then MaxIt := 250;
  if Secs < 0 then Secs := 0;
  if Zoom < 1 then Zoom := 1;
  T := DlModes[ModeIx];

  { Keep the aspect roughly right for the mode rather than assuming 4:3. }
  CH_ := (CW * T.YRes) div T.XRes;
  if CH_ < 20 then CH_ := 20;
  if CH_ > MAXH then CH_ := MAXH;

  Iter := PIter(GetMem(LongInt(CW) * CH_));
  if Iter = nil then
  begin
    WriteLn('out of heap for a ', LongInt(CW) * CH_, '-byte iteration map');
    Halt(9);
  end;
  BuildPal;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then begin WriteLn(DlWhy(Rc)); Halt(Rc); end;

  { How many Q8 steps fall across one pixel at this zoom.  Scaled by 10 so
    a fractional answer survives integer division. }
  FpuThere := HasFpu;
  StepsPP := (7680 div Zoom) div CW;

  if ForceInt then UseFpu := False
  else if ForceFpu then UseFpu := True
  else UseFpu := FpuThere and (StepsPP < 20);

  if UseFpu and not FpuThere then
  begin
    WriteLn('/8 given but no coprocessor answered the probe.');
    WriteLn('Refusing to run x87 arithmetic -- the WAIT would hang the');
    WriteLn('machine, which needs hands on it to clear.');
    Halt(12);
  end;

  Write('coproc    ');
  if FpuThere then WriteLn('8087 present (control word ', Hex4(FpuCw), ')')
              else WriteLn('none -- integer path throughout');
  WriteLn('Q8 steps  ', StepsPP div 10, '.', StepsPP mod 10,
          ' per pixel  (under 2.0 and Q8 is quantising, not drawing)');
  if UseFpu then
    WriteLn('maths     8087 double precision -- chosen for RANGE, and it is')
  else
    WriteLn('maths     Q8 fixed point, 16-bit IMUL -- 2x faster than the');
  if UseFpu then
    WriteLn('          about half the speed of the integer path')
  else
    WriteLn('          coprocessor here, and enough bits for this view');
  if Zoom > 1 then
    WriteLn('view      seahorse valley, zoom ', Zoom, 'x')
  else
    WriteLn('view      the classic one');

  WriteLn('mode      ', T.Name);
  WriteLn('computed  ', CW, ' x ', CH_, ', ', MaxIt, ' iterations max');
  WriteLn('shown as  ', (T.XRes div CW) * CW, ' x ',
          (T.YRes div CH_) * CH_, '  (', T.XRes div CW, 'x',
          T.YRes div CH_, ' blocks)');
  WriteLn;

  if not DlSetMode(T) then
  begin
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;
  DlFillRun(0, DlRgb(0, 0, 0), LongInt(T.XRes) * T.YRes);
  DlSend;

  DlZeroStats;
  B0 := DlBytes;
  TAll := Ticks;
  TComp := 0;
  TSend := 0;

  { The classic view: real -2.2..0.8, imaginary -1.2..1.2, in Q8, and the
    seahorse valley to zoom into. }
  X0 := -563; X1 := 205;
  Y0 := -307; Y1 := 307;
  FCx := -0.743643887; FCy := 0.131825904;
  FSpanX := 3.0 / Zoom;
  FSpanY := FSpanX * CH_ / CW;
  if Zoom > 1 then
  begin
    { Same window for the integer path, so the two are comparable -- and
      so the point at which Q8 runs out of bits is visible rather than
      hidden by quietly using a different view. }
    X0 := Round((FCx - FSpanX / 2) * 256);
    X1 := Round((FCx + FSpanX / 2) * 256);
    Y0 := Round((FCy - FSpanY / 2) * 256);
    Y1 := Round((FCy + FSpanY / 2) * 256);
  end;

  for Y := 0 to CH_ - 1 do
  begin
    DlTick;
    if DlEscaped then
    begin
      WriteLn('stopped at row ', Y, ' of ', CH_, ' -- Esc');
      Break;
    end;
    T0 := Ticks;
    if UseFpu then
    begin
      FCi := (FCy - FSpanY / 2) + FSpanY * Y / CH_;
      for X := 0 to CW - 1 do
      begin
        FCr := (FCx - FSpanX / 2) + FSpanX * X / CW;
        Iter^[Y * CW + X] := EscapeFpu(FCr, FCi);
      end;
    end
    else
    begin
      Ci := Y0 + (LongInt(Y1 - Y0) * Y) div CH_;
      for X := 0 to CW - 1 do
      begin
        Cr := X0 + (LongInt(X1 - X0) * X) div CW;
        Iter^[Y * CW + X] := Escape(Cr, Ci);
      end;
    end;
    TComp := TComp + (Ticks - T0);

    if AsYouGo then
    begin
      T0 := Ticks;
      if not SendRow(Y) then
      begin
        WriteLn('the adapter stopped accepting pixels at row ', Y);
        Halt(DL_REFUSED);
      end;
      TSend := TSend + (Ticks - T0);
    end;
  end;

  if not AsYouGo then
  begin
    T0 := Ticks;
    for Y := 0 to CH_ - 1 do
      if not SendRow(Y) then
      begin
        WriteLn('the adapter stopped accepting pixels at row ', Y);
        Halt(DL_REFUSED);
      end;
    TSend := TSend + (Ticks - T0);
  end;
  if not DlSend then WriteLn('final send failed');

  TAll := Ticks - TAll;
  if TAll < 1 then TAll := 1;

  WriteLn('compute   ', TComp, ' ticks  (', (TComp * 10) div 182, '.',
          ((TComp * 100) div 182) mod 10, ' s)');
  WriteLn('transfer  ', TSend, ' ticks  (', (TSend * 10) div 182, '.',
          ((TSend * 100) div 182) mod 10, ' s)');
  WriteLn('total     ', TAll, ' ticks  (', (TAll * 10) div 182, '.',
          ((TAll * 100) div 182) mod 10, ' s)');
  WriteLn('compute is ', (TComp * 100) div TAll, '% of it');
  WriteLn('bytes     ', DlBytes - B0, '  against ',
          LongInt(T.XRes) * T.YRes * 2, ' for the same area raw');
  WriteLn('packets   ', DlPackets);
  WriteLn('NAKs      ', DlNaks);
  WriteLn;
  WriteLn('Every other tool here is transfer-bound.  If compute is the');
  WriteLn('bigger number above, this one is not -- which is the point of');
  WriteLn('timing the two halves apart rather than quoting one total.');

  if Secs > 0 then
  begin
    T0 := Ticks;
    while True do
    begin
      if Ticks < T0 then Break;
      if Ticks - T0 >= (LongInt(Secs) * 182) div 10 then Break;
    end;
  end;
  Halt(0);
end.
