program dldash;
{ DLDASH -- a colour dashboard on a DisplayLink adapter: boxes, gauges,
  a scrolling ticker, and a live keyboard.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLDASH [/P=260] [/M=n] [/S=secs] [/K] [/R=n]

      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0
      /S=dec   seconds to run, default 20
      /K       INTERACTIVE: read the machine's keyboard.  Keys change the
               readings, Tab moves the highlight, Esc quits
      /R=dec   redraw everything every n frames, as a cost comparison
      /B       blank the adapter's output on the way out
      /T=dec   scroll the ticker every n frames; 0 turns it off.
               The ticker changes a WHOLE ROW every time it moves, which
               is about half of everything this screen sends -- so this
               is the one knob that visibly trades motion for rate

  WHAT THIS IS FOR

  DLCON draws a page and stops. This is the other half: a screen that
  changes a little, often. Everything on it -- the panels, the gauges, the
  ticker, the log -- is ordinary text in the ROM font, and the only reason
  it can move at all is that dlscr sends the DIFFERENCE.

  THE NUMBER THAT MAKES THE POINT. A full 80x30 repaint on this path is
  about 85,000 bytes and 11 seconds. A gauge that moves one cell is about
  80 bytes. Three orders of magnitude, and the tool prints cells-changed
  and bytes every frame so the claim stays visible rather than becoming
  folklore. /R forces a full repaint periodically if you want to watch the
  difference directly.

  COLOUR AND BOXES COST NOTHING EXTRA. The attribute is a byte per cell,
  ink in the low nibble and paper in the high, exactly as DOS has always
  meant it -- and the CP437 line-drawing characters are already in the ROM
  font, so a double-ruled border costs precisely what the same number of
  letters costs. There is no graphics here at all; it is a text screen
  that happens to be rendered a pixel at a time.

  THE READINGS ARE NOT REAL. They are a deterministic walk, because a
  dashboard that invents plausible numbers is indistinguishable from one
  reading a broken sensor, and this is a demonstration of the DISPLAY.
  Where real data would go is marked in the source.

  Exit codes: 0 ok, 9 no ROM font, otherwise the DlOpen reason }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

uses ch375, chtool, dl, dlscr;

const
  VER = '1.0.0';
  NGAUGE = 4;
  MAXLOG = 44;                 { a 64-row screen leaves room for this many }
  GaugeName: array[0..NGAUGE - 1] of ShortString =
    ('THROUGHPUT', 'PACKET RATE', 'BUFFER USE', 'ERROR RATE');
  GaugeUnit: array[0..NGAUGE - 1] of ShortString =
    ('KB/s', 'pkt/s', '%', 'ppm');

  { Under 255: a ShortString is a length byte and 255 of text, and this
    is a constant rather than a buffer. }
  TICKER = '  CH375Video -- a text screen over USB, drawn from the ROM '
         + 'font.  Only what CHANGES is sent: a moving gauge costs about '
         + '80 bytes where a full repaint costs 85,000.  Boxes and colour '
         + 'are free -- CP437 is in the font.  ***  ';


type
  TLogLine = string[110];

var
  T:        TDlTiming;
  ModeIx:   Integer = 0;
  Secs:     Integer = 20;
  Live:     Boolean = False;
  FullEvery: Integer = 0;
  BlankOut: Boolean = False;
  TickEvery: Integer = 1;

  Val:      array[0..NGAUGE - 1] of Integer;
  Vel:      array[0..NGAUGE - 1] of Integer;
  Sel:      Integer = 0;
  Seed:     Word = 7919;
  TickPos:  Integer = 1;
  Frames:   LongInt = 0;
  LogTop:   Integer = 0;
  LogDrawn: Integer = -1;
  { TLogLine, not ShortString.  A ShortString is 256 bytes whatever is in
    it, so 44 of them is 11 KB of data segment for lines that can never be
    wider than the screen -- and at 160x64 dlscr's cell buffers already
    take 40 KB of the 64 K available, which is what pushed this over.

    That is the cheap half of the problem. The expensive half is those two
    cell buffers, and they are the thing to move onto the heap if a mode
    larger than 1280x1024 is ever wanted. }
  Logs:     array[0..MAXLOG - 1] of TLogLine;
  { Worked out from the screen size at start-up rather than assumed, so a
    160x64 mode does not draw an 80x30 dashboard in its top corner and
    leave two thirds of the screen empty. }
  LogY:     Integer = 15;
  LogH:     Integer = 9;
  LogN:     Integer = 6;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var R: ShortString;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

function RPad(const S: ShortString; N: Integer): ShortString;
var R: ShortString;
begin
  R := S;
  while Length(R) < N do R := ' ' + R;
  RPad := R;
end;

function Rnd(N: Word): Word;
begin
  Seed := Word(Seed * 25173 + 13849);
  Rnd := (Seed shr 4) mod N;
end;

function GetKey: Char; assembler;
asm
  mov ah, 0
  int 16h
end;

procedure AddLog(const S: ShortString);
var I: Integer;
begin
  for I := 0 to LogN - 2 do Logs[I] := Logs[I + 1];
  Logs[LogN - 1] := S;
  Inc(LogTop);
end;

{ ---------------------------------------------------------------- layout }

{ The FURNITURE -- panels, borders, titles, key help.  None of it ever
  changes, so it is drawn ONCE.  Calling this every frame cost a 2,400
  cell ScrClear plus every box and title, all of which the diff then
  correctly decided not to send: pure CPU spent proving nothing moved. }
procedure DrawFrame;
var I: Integer;
begin
  ScrClear(clBlack or (clBlack shl 4));

  { Title bar, reverse video: paper light grey, ink black. }
  ScrFill(0, 0, ScrCols, 1, ' ', clBlack or (clLightGrey shl 4));
  ScrWrite(2, 0, 'CH375Video  DLDASH', clBlack or (clLightGrey shl 4));
  ScrWrite(ScrCols - 22, 0, 'USB display  ' + Dec1(ScrCols) + 'x'
           + Dec1(ScrRows), clBlack or (clLightGrey shl 4));

  { Gauge panel. }
  ScrBox(1, 2, 46, 12, clLightCyan, True);
  ScrTitle(1, 2, 46, 'READINGS', clWhite);

  { Status panel. }
  ScrBox(48, 2, ScrCols - 49, 12, clLightBlue, False);
  ScrTitle(48, 2, ScrCols - 49, 'LINK', clWhite);

  { Log panel -- fills whatever is left above the ticker, so a tall mode
    gets a tall log rather than a band of empty screen. }
  ScrBox(1, LogY, ScrCols - 2, LogH, clDarkGrey, False);
  ScrTitle(1, LogY, ScrCols - 2, 'EVENTS', clLightGrey);

  { Ticker rail. }
  ScrFill(0, ScrRows - 2, ScrCols, 1, ' ', clBlack or (clBlue shl 4));

  { Key help. }
  if Live then
    ScrWrite(1, ScrRows - 1, 'TAB select   +/- adjust   L log   R redraw'
             + '   ESC quit', clDarkGrey)
  else
    ScrWrite(1, ScrRows - 1, 'running unattended -- /K for the keyboard',
             clDarkGrey);
  for I := 0 to NGAUGE - 1 do ;
end;

procedure DrawGauges;
var
  I, Y: Integer;
  At, NameAt: Byte;
begin
  for I := 0 to NGAUGE - 1 do
  begin
    Y := 4 + I * 2;
    if Live and (I = Sel) then NameAt := clBlack or (clYellow shl 4)
                          else NameAt := clLightGrey;
    ScrWrite(3, Y, Pad(GaugeName[I], 12), NameAt);

    { Green while healthy, yellow past 70, red past 88 -- and the ERROR
      gauge reads the other way round, because a high error rate is the
      bad one. }
    if I = 3 then
    begin
      if Val[I] > 30 then At := clLightRed
      else if Val[I] > 10 then At := clYellow
      else At := clLightGreen;
    end
    else
    begin
      if Val[I] > 88 then At := clLightRed
      else if Val[I] > 70 then At := clYellow
      else At := clLightGreen;
    end;

    ScrBar(16, Y, 20, Val[I], At, clDarkGrey);
    ScrWrite(37, Y, RPad(Dec1(Val[I]), 3) + ' '
             + Pad(GaugeUnit[I], 5), At);
  end;
end;

procedure DrawStatus;
var X, W: Integer;
begin
  X := 50;
  W := ScrCols - 53;
  ScrWrite(X, 4,  Pad('adapter', 11) + 'DisplayLink', clLightGrey);
  ScrWrite(X, 5,  Pad('mode', 11) + T.Name, clLightGrey);
  ScrWrite(X, 6,  Pad('screen', 11) + Dec1(ScrCols) + ' x '
           + Dec1(ScrRows) + ' cells', clLightGrey);
  ScrWrite(X, 7,  Pad('frame', 11) + Dec1(Frames), clWhite);
  ScrWrite(X, 8,  Pad('cells sent', 11) + RPad(Dec1(ScrCellsSent), 5),
           clLightGreen);
  ScrWrite(X, 9,  Pad('bytes', 11) + RPad(Dec1(DlBytes), 8), clLightGreen);
  ScrWrite(X, 10, Pad('packets', 11) + RPad(Dec1(DlPackets), 8),
           clLightGrey);
  ScrWrite(X, 11, Pad('NAKs', 11) + RPad(Dec1(DlNaks), 8), clLightGrey);
  if W > 0 then ;
end;

{ Only when a line was actually added.  The log shifts all six rows when
  it does, which is 444 cells -- affordable occasionally, not every
  frame, and rebuilding the padded strings was costing more than the
  sending. }
procedure DrawLog;
var I: Integer;
begin
  if LogTop = LogDrawn then Exit;
  LogDrawn := LogTop;
  for I := 0 to LogN - 1 do
    ScrWrite(3, LogY + 1 + I, Pad(Logs[I], ScrCols - 6), clLightGrey);
end;

{ Straight into the cells.  The first version built an 80-character
  ShortString with S := S + TICKER[C], which copies the whole string on
  every append -- 3,200 character moves a frame to produce 80 cells. }
procedure DrawTicker;
var
  I, C: Integer;
  At: Byte;
begin
  At := clWhite or (clBlue shl 4);
  for I := 0 to ScrCols - 1 do
  begin
    C := ((TickPos + I - 1) mod Length(TICKER)) + 1;
    ScrPut(I, ScrRows - 2, TICKER[C], At);
  end;
end;

{ Where real data would arrive.  This is a deterministic walk so the
  picture is reproducible; a dashboard that invents plausible readings is
  indistinguishable from one wired to a broken sensor. }
procedure StepReadings;
var I: Integer;
begin
  for I := 0 to NGAUGE - 1 do
  begin
    Val[I] := Val[I] + Vel[I];
    if Val[I] > 100 then begin Val[I] := 100; Vel[I] := -Vel[I]; end;
    if Val[I] < 0 then begin Val[I] := 0; Vel[I] := -Vel[I]; end;
    if Rnd(100) < 12 then Vel[I] := Integer(Rnd(9)) - 4;
  end;
  if Rnd(100) < 14 then
    case Rnd(4) of
      0: AddLog('link  frame ' + Dec1(Frames) + '  throughput '
                + Dec1(Val[0]) + ' KB/s');
      1: AddLog('warn  buffer at ' + Dec1(Val[2]) + '% -- watching');
      2: AddLog('info  ' + Dec1(DlPackets) + ' packets, '
                + Dec1(DlNaks) + ' NAKs');
    else
      AddLog('ok    steady');
    end;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLDASH [/P=260] [/M=n] [/S=secs] [/K] [/R=n]');
  WriteLn;
  WriteLn('    /S=dec  seconds to run, default 20');
  WriteLn('    /K      interactive: TAB select, +/- adjust, L log,');
  WriteLn('            R redraw everything, ESC quit');
  WriteLn('    /R=dec  force a full repaint every n frames, to compare');
  WriteLn('    /B      blank the adapter''s output on the way out');
  WriteLn('    /L      log each start-up stage to C:\WORK\DLDASH.LOG,');
  WriteLn('            which survives a hang when the screen does not');
  WriteLn('    /T=dec  scroll the ticker every n frames, 0 to stop it');
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
  I, Rc:    Integer;
  S:        ShortString;
  T0, Dead: LongInt;
  B0:       LongInt;
  C:        Char;
  Quit:     Boolean;
  FullN:    LongInt = 0;
  CellsTot: LongInt = 0;

begin
  Banner('DLDASH', VER, 'a colour dashboard over USB');

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'S': Secs := DecArg(S, 4);
        'K': Live := True;
        'R': FullEvery := DecArg(S, 4);
        'B': BlankOut := True;
        'L': DlMarkTo := 'C:\WORK\DLDASH.LOG';
        'T': TickEvery := DecArg(S, 4);
      end;
  end;
  if HelpWanted then begin Usage; Halt(0); end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if Secs < 1 then Secs := 1;
  T := DlModes[ModeIx];

  for I := 0 to NGAUGE - 1 do
  begin
    Val[I] := 20 + Integer(Rnd(60));
    Vel[I] := Integer(Rnd(7)) - 3;
  end;
  for I := 0 to MAXLOG - 1 do Logs[I] := '';

  { Breadcrumbs across the whole start-up, because this is the span that
    freezes and nothing about it reaches the screen: the banner is the
    last thing printed and the next WriteLn is after all four stages
    below. Whatever the log ends on is where it stopped. }
  DlSay('bringing the adapter up...');
  DlMark('--- start, mode ' + T.Name);

  ExitProc := @Quieten;
  DlMark('DlOpen: begin');
  Rc := DlOpen;
  DlMark('DlOpen: returned ' + Dec1(Rc));
  DlSay('adapter open, setting the mode...');
  if Rc <> DL_OK then begin WriteLn(DlWhy(Rc)); Halt(Rc); end;

  DlMark('DlSetMode: begin');
  if not DlSetMode(T) then
  begin
    DlMark('DlSetMode: REFUSED');
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;
  DlMark('DlSetMode: ok');
  DlSay('mode set, clearing the screen...');

  DlMark('clear: begin');
  DlFillRun(0, DlRgb(0, 0, 0), LongInt(T.XRes) * T.YRes);
  DlSend;
  DlMark('clear: ok, ' + Dec1(DlBytes) + ' bytes, '
         + Dec1(DlPackets) + ' packets, ' + Dec1(DlNaks) + ' NAKs');

  DlSay('screen cleared, locating the ROM font...');
  DlMark('ScrInit: begin');
  if not ScrInit(T) then
  begin
    WriteLn('the BIOS would not hand over a font pointer (INT 10h 1130h)');
    Halt(9);
  end;
  { The framebuffer was just filled with black, so say so -- otherwise
    the first flush repaints 2,400 cells to put spaces where spaces
    already are, which is most of the delay before anything appears. }
  { Size the layout now the screen size is known.  Two rows at the
    bottom are the ticker and the key help. }
  LogY := 15;
  LogH := ScrRows - LogY - 3;
  if LogH < 4 then LogH := 4;
  LogN := LogH - 2;
  if LogN < 1 then LogN := 1;
  if LogN > MAXLOG then LogN := MAXLOG;

  { AFTER the layout is sized, not before.  AddLog puts a line at
    Logs[LogN-1], so anything logged while LogN was still its default of 6
    lands in slot 5 and stays there -- which showed up as a gap between
    the boot line and everything after it. }
  AddLog('boot  dlscr up, ROM font located');

  ScrAssumeCleared(clBlack or (clBlack shl 4));
  DlMark('ScrInit: ok, ' + Dec1(ScrCols) + 'x' + Dec1(ScrRows));
  WriteLn('mode      ', T.Name);
  WriteLn('screen    ', ScrCols, ' x ', ScrRows, ' cells, 8x16 ROM font');
  if Live then WriteLn('keyboard  live -- TAB / +- / L / R / ESC')
          else WriteLn('keyboard  not read (/K for interactive)');
  WriteLn;

  DlZeroStats;
  B0 := DlBytes;
  T0 := Ticks;
  Dead := T0 + (LongInt(Secs) * 182) div 10;
  Quit := False;

  DlMark('DrawFrame: begin');
  DrawFrame;                                  { once -- see the note there }
  DlMark('DrawFrame: ok -- entering the loop');
  DlSay('running -- Esc stops it.');

  while not Quit do
  begin
    if Ticks < T0 then Break;                 { midnight rollover }
    if Ticks >= Dead then Break;
    DlTick;                                   { the machine is alive }

    { Esc gets you out whether or not /K was given.  Without this the
      tool ran silently for its whole duration and answered nothing --
      which from the machine's own prompt is indistinguishable from a
      lockup, and cost a power cycle to find out otherwise. }
    if not Live then
      if DlEscaped then Break;

    StepReadings;
    DrawGauges;
    DrawStatus;
    DrawLog;
    if TickEvery > 0 then DrawTicker;

    if (FullEvery > 0) and (Frames mod FullEvery = 0) and (Frames > 0) then
    begin
      ScrInvalidate;
      DrawFrame;
      LogDrawn := -1;
      Inc(FullN);
    end;

    if not ScrFlush then
    begin
      WriteLn('the adapter stopped accepting the command stream');
      Break;
    end;
    CellsTot := CellsTot + ScrCellsSent;
    Inc(Frames);
    if (DlMarkTo <> '') and (Frames mod 5 = 0) then
      DlMark('frame ' + Dec1(Frames) + ', ' + Dec1(DlBytes) + ' bytes');
    if (TickEvery > 0) and (Frames mod TickEvery = 0) then
      TickPos := (TickPos mod Length(TICKER)) + 1;

    if Live then
      while KeyWaiting do
      begin
        C := GetKey;
        case C of
          #27: Quit := True;
          #9:  Sel := (Sel + 1) mod NGAUGE;
          '+', '=': if Val[Sel] < 100 then Val[Sel] := Val[Sel] + 5;
          '-', '_': if Val[Sel] > 0 then Val[Sel] := Val[Sel] - 5;
          'l', 'L': AddLog('key   operator note at frame ' + Dec1(Frames));
          'r', 'R': begin ScrInvalidate; DrawFrame; LogDrawn := -1;
                          AddLog('key   full repaint forced'); end;
        end;
      end;
  end;

  WriteLn('frames    ', Frames);
  if Frames > 0 then
  begin
    WriteLn('cells/fr  ', CellsTot div Frames, '  of ',
            LongInt(ScrCols) * ScrRows, ' on the screen');
    WriteLn('bytes/fr  ', (DlBytes - B0) div Frames);
    WriteLn('fps       ', (Frames * 182) div (Ticks - T0 + 1) div 10, '.',
            ((Frames * 182) div (Ticks - T0 + 1)) mod 10);
  end;
  if FullN > 0 then WriteLn('full repaints forced: ', FullN);
  WriteLn('packets   ', DlPackets);
  WriteLn('NAKs      ', DlNaks);
  WriteLn;
  WriteLn('A full repaint of this screen is about ',
          LongInt(ScrCols) * ScrRows * 80, ' bytes.  The figure above is');
  WriteLn('what sending only the difference actually cost.');

  { What the display is left showing, said out loud.

    The adapter has its OWN framebuffer, so it keeps the last thing it was
    sent after this program has exited -- there is nothing to "close". That
    is deliberate and it is what lets a dashboard stay up after the tool
    that drew it has gone, but it surprises anybody expecting a program to
    tidy its screen away, so it is now stated rather than left to be
    discovered. /B blanks it instead. }
  WriteLn;
  if BlankOut then
  begin
    DlBlank(True);
    WriteLn('Display BLANKED (/B).');
  end
  else
  begin
    WriteLn('The adapter keeps its own framebuffer, so the last frame is');
    WriteLn('still on the screen and will stay there until something else');
    WriteLn('writes to it.  Nothing is left running.  /B blanks it.');
  end;
  Halt(0);
end.
