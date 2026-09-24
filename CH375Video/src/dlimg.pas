program dlimg;
{ DLIMG -- load an image file and display it, scaled to fit.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLIMG file [/P=260] [/M=n] [/F=fit|fill|one] [/S=secs] [/I]

      file     a .BMP -- 24-bit, 8-bit palette, or 4-bit palette,
               uncompressed (BI_RGB)
      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0
      /F=name  fit  keep the aspect, letterbox to fit inside  (default)
               fill keep the aspect, crop to cover the screen
               one  no scaling, one image pixel per screen pixel
      /S=dec   seconds to hold the picture, default 8
      /I       report the file's header and stop, drawing nothing

  WHY BMP, AND WHY ONLY BMP

  BMP is the only common format whose pixels can be read without first
  implementing a decompressor. GIF needs LZW, PNG needs Deflate, JPEG
  needs a DCT and a Huffman decoder -- each of those is a project on its
  own and none of them would teach anything about this adapter. PCX would
  be the reasonable next one: its RLE is a dozen lines.

  So this is deliberately the FILE-HANDLING and SCALING demonstration, not
  a codec. Everything interesting here is in how the picture is moved and
  resized, which is what the header below is really about.

  THE IMAGE IS NEVER HELD IN MEMORY

  A 640x480 24-bit BMP is 921,600 bytes and this machine has about 514 KB
  of heap, so loading one whole is not an option -- and would not help if
  it were, because the framebuffer it is going to is 614,400 bytes and
  that does not fit either.

  Instead the file is read ONE SOURCE ROW AT A TIME, in the order the
  destination needs. For each screen row the source row is computed,
  seeked to, read, scaled across, and sent. Memory is one source row plus
  one destination row whatever the picture's size, and a 2000x1500 photo
  costs exactly what a 320x240 one does.

  That is also why the scaler is nearest-neighbour: with only the current
  row in hand there is nothing to interpolate vertically against, and
  fetching neighbours would mean seeking backwards through the file for
  every output row.

  BMP ROWS RUN BOTTOM-UP, which is the trap in this format. A positive
  biHeight means the first row in the file is the BOTTOM of the picture,
  and an upside-down photograph is a very visible bug that no counter
  reports. A negative biHeight means top-down; both are handled.

  Exit codes: 0 ok, 9 out of heap, 10 the file would not open,
              11 not a BMP this can read, otherwise the DlOpen reason }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}

uses ch375, chtool, dl;

const
  VER = '1.0.0';
  MAXSRC = 4096;              { widest source row in pixels we will take }

type
  TRow = array[0..2047] of Word;

var
  T:        TDlTiming;
  ModeIx:   Integer = 0;
  Secs:     Integer = 8;
  Fit:      ShortString;
  InfoOnly: Boolean = False;
  FileArg:  ShortString;

  F:        file;
  SrcW:     LongInt = 0;
  SrcH:     LongInt = 0;
  Bpp:      Integer = 0;
  TopDown:  Boolean = False;
  DataOfs:  LongInt = 0;
  RowBytes: LongInt = 0;
  Pal:      array[0..255] of Word;

  SrcBuf:   PByte;            { one source row, as it sits in the file }
  Dst:      TRow;             { one destination row, 16bpp }
  { Which source column each destination column reads from, worked out
    ONCE.  See the note above the scaling loop -- this table is the
    difference between 207 seconds and something usable. }
  XMap:     array[0..2047] of Word;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

function LeWord(const B: array of Byte; O: Integer): Word;
begin
  LeWord := B[O] or (Word(B[O + 1]) shl 8);
end;

function LeLong(const B: array of Byte; O: Integer): LongInt;
begin
  LeLong := LongInt(B[O]) or (LongInt(B[O + 1]) shl 8)
          or (LongInt(B[O + 2]) shl 16) or (LongInt(B[O + 3]) shl 24);
end;

{ ------------------------------------------------------------------ BMP }

function OpenBmp(const Path: ShortString): Boolean;
var
  H:   array[0..63] of Byte;
  PB:  array[0..1023] of Byte;
  Got: LongInt;
  HdrSize, NPal, I: LongInt;
  Comp: LongInt;
begin
  OpenBmp := False;
  Assign(F, Path);
  {$I-} Reset(F, 1); {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('cannot open ', Path);
    Halt(10);
  end;

  {$I-} BlockRead(F, H, 54, Got); {$I+}
  if (IOResult <> 0) or (Got < 54) then
  begin
    WriteLn('too short to be a BMP (', Got, ' bytes read)');
    Exit;
  end;
  if (H[0] <> Ord('B')) or (H[1] <> Ord('M')) then
  begin
    WriteLn('no "BM" signature -- not a BMP');
    Exit;
  end;

  DataOfs := LeLong(H, 10);
  HdrSize := LeLong(H, 14);
  SrcW    := LeLong(H, 18);
  SrcH    := LeLong(H, 22);
  Bpp     := LeWord(H, 28);
  Comp    := LeLong(H, 30);

  { A negative height means the rows are stored top-down. }
  TopDown := SrcH < 0;
  if TopDown then SrcH := -SrcH;

  if HdrSize < 40 then
  begin
    WriteLn('BITMAPCOREHEADER (', HdrSize, ' bytes) is not supported --');
    WriteLn('this reads the 40-byte BITMAPINFOHEADER and later.');
    Exit;
  end;
  if Comp <> 0 then
  begin
    WriteLn('compression type ', Comp, ' -- only uncompressed BI_RGB is');
    WriteLn('read here.  Re-save the file without RLE.');
    Exit;
  end;
  if (Bpp <> 24) and (Bpp <> 8) and (Bpp <> 4) and (Bpp <> 32) then
  begin
    WriteLn(Bpp, ' bits per pixel -- this reads 4, 8, 24 and 32.');
    Exit;
  end;
  if (SrcW < 1) or (SrcW > MAXSRC) or (SrcH < 1) then
  begin
    WriteLn('implausible size ', SrcW, ' x ', SrcH);
    Exit;
  end;

  { Rows are padded out to a 4-byte boundary, and forgetting that shears
    the picture diagonally -- which looks like a scaling bug and is not. }
  RowBytes := ((SrcW * Bpp + 31) div 32) * 4;

  if Bpp <= 8 then
  begin
    NPal := LeLong(H, 46);
    if NPal = 0 then NPal := LongInt(1) shl Bpp;
    if NPal > 256 then NPal := 256;
    Seek(F, 14 + HdrSize);
    {$I-} BlockRead(F, PB, NPal * 4, Got); {$I+}
    if (IOResult <> 0) or (Got < NPal * 4) then
    begin
      WriteLn('the palette is truncated');
      Exit;
    end;
    { BMP palette entries are B, G, R, reserved. }
    for I := 0 to NPal - 1 do
      Pal[I] := DlRgb(PB[I * 4 + 2], PB[I * 4 + 1], PB[I * 4]);
  end;

  OpenBmp := True;
end;

{ Read source row Sy (0 = TOP of the picture) into SrcBuf. }
function ReadSrcRow(Sy: LongInt): Boolean;
var
  FileRow, Got: LongInt;
begin
  ReadSrcRow := False;
  if TopDown then FileRow := Sy else FileRow := SrcH - 1 - Sy;
  Seek(F, DataOfs + FileRow * RowBytes);
  if IOResult <> 0 then Exit;
  {$I-} BlockRead(F, SrcBuf^, RowBytes, Got); {$I+}
  if (IOResult <> 0) or (Got < RowBytes) then Exit;
  ReadSrcRow := True;
end;

{ One source pixel as 5-6-5.  X is a Word, not a LongInt: this is called
  once per destination pixel and 32-bit indexing here was measurable. }
function SrcPixel(X: Word): Word;
var P: PByte;
begin
  P := SrcBuf;
  case Bpp of
    32: SrcPixel := DlRgb(P[X * 4 + 2], P[X * 4 + 1], P[X * 4]);
    24: SrcPixel := DlRgb(P[X * 3 + 2], P[X * 3 + 1], P[X * 3]);
     8: SrcPixel := Pal[P[X]];
     4: if (X and 1) = 0 then SrcPixel := Pal[P[X shr 1] shr 4]
                         else SrcPixel := Pal[P[X shr 1] and $0F];
  else
    SrcPixel := 0;
  end;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLIMG file [/P=260] [/M=n] [/F=fit|fill|one] [/S=secs] [/I]');
  WriteLn;
  WriteLn('    file    a .BMP: 4, 8, 24 or 32 bpp, uncompressed');
  WriteLn('    /F=fit  keep the aspect, letterbox inside the screen');
  WriteLn('    /F=fill keep the aspect, crop to cover the screen');
  WriteLn('    /F=one  no scaling, one image pixel per screen pixel');
  WriteLn('    /S=dec  seconds to hold the picture, default 8');
  WriteLn('    /I      report the header and stop');
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
  I, Rc:      Integer;
  S:          ShortString;
  DW, DH:     LongInt;        { the drawn size, in screen pixels }
  OX, OY:     LongInt;        { where it starts on the screen }
  Y:          LongInt;
  Xi:         Integer;
  Sy:         LongInt;
  T0, Tk:     LongInt;
  B0:         LongInt;
  LastSy:     LongInt;

begin
  Banner('DLIMG', VER, 'a BMP loaded, scaled and shown over USB');
  Fit := 'fit';
  FileArg := '';

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (Length(S) > 1) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'S': Secs := DecArg(S, 4);
        'I': InfoOnly := True;
        'F': Fit := LowerCase(Copy(S, 4, Length(S) - 3));
      end
    else if FileArg = '' then
      FileArg := S;
  end;
  if HelpWanted or (FileArg = '') then begin Usage; Halt(0); end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if Secs < 0 then Secs := 0;
  T := DlModes[ModeIx];

  if not OpenBmp(FileArg) then Halt(11);

  WriteLn('file      ', FileArg);
  WriteLn('image     ', SrcW, ' x ', SrcH, ', ', Bpp, ' bpp, ',
          'rows ', RowBytes, ' bytes');
  if TopDown then WriteLn('order     top-down')
             else WriteLn('order     bottom-up (the usual BMP way)');

  { Work out the drawn size.  All integer: the ratio is compared by cross
    multiplication rather than by dividing, because an integer divide here
    would quantise the aspect badly on small pictures. }
  if Fit = 'one' then
  begin
    DW := SrcW; DH := SrcH;
  end
  else if Fit = 'fill' then
  begin
    if SrcW * T.YRes > SrcH * T.XRes then
    begin
      DH := T.YRes; DW := (SrcW * T.YRes) div SrcH;
    end
    else
    begin
      DW := T.XRes; DH := (SrcH * T.XRes) div SrcW;
    end;
  end
  else
  begin
    if SrcW * T.YRes > SrcH * T.XRes then
    begin
      DW := T.XRes; DH := (SrcH * T.XRes) div SrcW;
    end
    else
    begin
      DH := T.YRes; DW := (SrcW * T.YRes) div SrcH;
    end;
  end;
  if DW < 1 then DW := 1;
  if DH < 1 then DH := 1;
  if DW > 2047 then DW := 2047;          { the row buffer and the map }

  OX := (LongInt(T.XRes) - DW) div 2;
  OY := (LongInt(T.YRes) - DH) div 2;

  WriteLn('mode      ', T.Name);
  WriteLn('drawn     ', DW, ' x ', DH, '  (', Fit, ')');
  if (OX < 0) or (OY < 0) then
    WriteLn('          cropped: ', -OX, ' px off each side, ',
            -OY, ' off top and bottom');

  if InfoOnly then
  begin
    Close(F);
    WriteLn;
    WriteLn('/I given -- header only, nothing drawn.');
    Halt(0);
  end;

  { Build the column map once.  DW is bounded by the mode width, so this
    is at most a couple of thousand entries. }
  for Xi := 0 to Integer(DW) - 1 do
  begin
    Sy := (LongInt(Xi) * SrcW) div DW;
    if Sy >= SrcW then Sy := SrcW - 1;
    if Sy < 0 then Sy := 0;
    XMap[Xi] := Word(Sy);
  end;

  SrcBuf := PByte(GetMem(RowBytes + 8));
  if SrcBuf = nil then
  begin
    WriteLn('out of heap for a ', RowBytes, '-byte source row');
    Halt(9);
  end;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then begin WriteLn(DlWhy(Rc)); Halt(Rc); end;

  if not DlSetMode(T) then
  begin
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;
  DlFillRun(0, DlRgb(0, 0, 0), LongInt(T.XRes) * T.YRes);
  DlSend;

  DlZeroStats;
  B0 := DlBytes;
  T0 := Ticks;
  LastSy := -1;

  for Y := 0 to DH - 1 do
  begin
    DlTick;
    if DlEscaped then
    begin
      WriteLn('stopped at row ', Y, ' of ', DH, ' -- Esc');
      Break;
    end;
    if OY + Y < 0 then Continue;
    if OY + Y >= T.YRes then Break;

    { Nearest neighbour, and the source row is only re-read when it
      actually changes -- scaling a 200-row picture up to 480 would
      otherwise seek and read the same row twice for nothing. }
    Sy := (Y * SrcH) div DH;
    if Sy <> LastSy then
    begin
      if not ReadSrcRow(Sy) then
      begin
        WriteLn('the file ended early at source row ', Sy);
        Break;
      end;
      LastSy := Sy;
    end;

    { A table lookup, not arithmetic.  The obvious way computes
      (X * SrcW) div DW inside this loop -- a 32-bit multiply AND a 32-bit
      divide for every destination pixel, 307,200 of them for a 640x480
      screen. BENCH rates those at 10,920 and 7,280 a second, which is
      about 70 seconds of pure arithmetic, and the first version measured
      207 seconds against 7 of actual transfer.

      The ratio is the whole reason: CLAUDE.md records 32-bit arithmetic
      costing 5-8x its 16-bit equivalent on this toolchain, because FPC
      calls a software routine for LongInt multiply and divide. The map is
      built once per picture instead of once per pixel. }
    for Xi := 0 to Integer(DW) - 1 do
      Dst[Xi] := SrcPixel(XMap[Xi]);

    { Only the part that lands on the screen. }
    if OX >= 0 then
      Rc := 0
    else
      Rc := Integer(-OX);
    I := Integer(DW) - Rc;
    if OX + DW > T.XRes then I := Integer(LongInt(T.XRes) - (OX + Rc));
    if I > 0 then
      if not DlRleRun(DlAddr(T, Word(OX + Rc), Word(OY + Y)),
                      @Dst[Rc], Word(I)) then
      begin
        WriteLn('the adapter stopped accepting pixels at row ', Y);
        Break;
      end;
  end;
  if not DlSend then WriteLn('final send failed');
  Close(F);

  Tk := Ticks - T0;
  if Tk < 1 then Tk := 1;
  WriteLn;
  WriteLn('drawn in  ', Tk, ' ticks  (', (Tk * 10) div 182, '.',
          ((Tk * 100) div 182) mod 10, ' s)');
  WriteLn('bytes     ', DlBytes - B0, '  against ', DW * DH * 2,
          ' for the same area raw');
  WriteLn('packets   ', DlPackets);
  WriteLn('NAKs      ', DlNaks);

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
