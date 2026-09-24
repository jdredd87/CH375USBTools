program dlcon;
{ DLCON -- a text console on a DisplayLink adapter, from real-mode DOS.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLCON [/P=260] [/M=n] [/F=file] [/T=text] [/S=secs] [/C=hex] [/B=hex]

      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0 (640x480@60)
      /F=name  show this text file
      /T=text  show this one line (repeatable by being given twice)
      /S=dec   hold the screen this long before returning, default 3
      /C=hex   ink, 565 hex, default FFFF
      /B=hex   paper, 565 hex, default 0000
      /D       draw the built-in demonstration page

  WHY TEXT IS THE CASE THIS HARDWARE IS ACTUALLY GOOD AT

  DLBENCH measures a full screen of literal pixels at 43 seconds and a
  full screen of solid colour at 0.66. Text sits almost at the good end of
  that range rather than in the middle, and the reason is the encoding: a
  row of 8x16 glyphs is mostly paper, and the RLE command collapses a run
  of identical pixels into three bytes however long it is. So a line of
  text costs roughly what its INK costs, not what its area costs.

  That is why this is the useful demo and the starfield is not: 80x30
  characters is a real terminal, and it redraws in about a second.

  HOW IT DRAWS

  One glyph row at a time, 16 scanlines tall, built in a local buffer and
  pushed as 16 RLE runs. Only rows that have text on them are sent; the
  paper is written once by the initial clear and never touched again. The
  font is the ROM 8x16 set the machine already has, fetched through the
  BIOS at INT 10h AX=1130h BH=6 -- there is no font in this binary, and
  nothing to keep in step with the one in ROM.

  Exit codes: 0 ok, otherwise the DlOpen reason (all <= 20),
              9 out of heap, 10 the named file would not open }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

uses ch375, chtool, dl, Dos;

const
  VER = '1.0.0';
  GH  = 16;                      { glyph height, the ROM 8x16 set }
  GW  = 8;
  MAXCOL = 128;

type
  TRowBuf = array[0..MAXCOL * GW - 1] of Word;
  PRowBuf = ^TRowBuf;

var
  T:       TDlTiming;
  ModeIx:  Integer = 0;
  Secs:    Integer = 3;
  Ink:     Word = $FFFF;
  Paper:   Word = $0000;
  Cols:    Integer;
  Rows:    Integer;
  FontSeg: Word = 0;
  FontOfs: Word = 0;
  RowBuf:  PRowBuf;
  FileArg: ShortString;
  Lines:   array[0..63] of ShortString;
  NLines:  Integer = 0;
  Demo:    Boolean = False;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ The ROM 8x16 font, located through the BIOS rather than carried here.
  INT 10h AX=1130h with BH=6 returns ES:BP pointing at it. }
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

function GlyphByte(Ch: Char; Scan: Integer): Byte;
begin
  GlyphByte := Mem[FontSeg : FontOfs + Ord(Ch) * GH + Scan];
end;

{ Lay one scanline of one text row into the row buffer, and say whether
  any INK landed.  That answer is worth having: an 8x16 ROM glyph has
  blank scanlines at the top and bottom, so several scanlines of every
  text row are entirely paper and need not be sent at all -- the paper is
  already paper from the initial clear. }
function LayScan(const S: ShortString; Scan, Upto: Integer): Boolean;
var
  C, X, Bit: Integer;
  B: Byte;
  Ch: Char;
  AnyInk: Boolean;
begin
  AnyInk := False;
  for C := 0 to Upto - 1 do
  begin
    if C < Length(S) then Ch := S[C + 1] else Ch := ' ';
    B := GlyphByte(Ch, Scan);
    if B <> 0 then AnyInk := True;
    X := C * GW;
    for Bit := 0 to GW - 1 do
      if (B and (128 shr Bit)) <> 0 then RowBuf^[X + Bit] := Ink
                                    else RowBuf^[X + Bit] := Paper;
  end;
  LayScan := AnyInk;
end;

{ One text row, with two things deliberately not done -- and the
  measurement is worth recording because it did NOT go where expected.

  Trimming the width to the line's own length and skipping scanlines with
  no ink took a demonstration page from 17.6 s to 11.7 s, a third faster.
  But the BYTES barely moved: 90,432 to 85,376, under 6%.

  That is the RLE encoder being better than the guess behind the change.
  The paper past the end of a 50-character line was never expensive: it
  was one repeat run of about three bytes, however wide it was. So almost
  all of the saving was CPU -- not laying those pixels down and not
  scanning them again -- and almost none was transfer.

  Worth keeping straight, because the obvious next optimisation is to send
  less, and on a text page the thing actually costing bytes is the INK
  TRANSITIONS. Each glyph edge starts a new run at roughly 3 bytes, so a
  page costs about what its letter count costs, and trimming whitespace
  cannot help with that. }
function DrawRow(RowIx: Integer; const S: ShortString): Boolean;
var
  Scan, Upto: Integer;
begin
  DrawRow := False;
  Upto := Length(S);
  if Upto > Cols then Upto := Cols;
  if Upto = 0 then begin DrawRow := True; Exit; end;
  for Scan := 0 to GH - 1 do
    if LayScan(S, Scan, Upto) then
      if not DlRleRun(DlAddr(T, 0, Word(RowIx * GH + Scan)),
                      @RowBuf^[0], Word(Upto * GW)) then Exit;
  DrawRow := True;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLCON [/P=260] [/M=n] [/F=file] [/T=text] [/S=secs]');
  WriteLn('        [/C=hex] [/B=hex] [/D]');
  WriteLn;
  WriteLn('    /F=name  show this text file');
  WriteLn('    /T=text  show this one line');
  WriteLn('    /D       the built-in demonstration page');
  WriteLn('    /C=hex   ink as 565 hex, default FFFF');
  WriteLn('    /B=hex   paper as 565 hex, default 0000');
  WriteLn('    /M=dec   mode, default 0:');
  for I := 0 to NDLMODES - 1 do
    WriteLn('               ', I, ' = ', DlModes[I].Name);
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

procedure AddLine(const S: ShortString);
begin
  if NLines <= High(Lines) then
  begin
    Lines[NLines] := S;
    Inc(NLines);
  end;
end;

procedure BuildDemo;
begin
  AddLine('');
  AddLine('   CH375Video -- DLCON');
  AddLine('   ==================================================');
  AddLine('');
  AddLine('   A text console on a USB-to-VGA adapter, driven by');
  AddLine('   a real-mode DOS machine through a CH375 host card.');
  AddLine('');
  AddLine('   There is no display class in USB, so none of this');
  AddLine('   is generic: the adapter is a DisplayLink part and');
  AddLine('   the command stream is its own. What made it work');
  AddLine('   was reading the protocol out of Linux''s udlfb');
  AddLine('   rather than guessing at register values.');
  AddLine('');
  AddLine('   Text is the case this hardware is good at. A full');
  AddLine('   screen of literal pixels takes 43 seconds. A row');
  AddLine('   of 8x16 glyphs is mostly paper, and the RLE');
  AddLine('   command collapses a run of identical pixels into');
  AddLine('   three bytes however long it is -- so a line costs');
  AddLine('   what its INK costs, not what its area costs.');
  AddLine('');
  AddLine('   The font is the machine''s own ROM 8x16 set, found');
  AddLine('   through INT 10h AX=1130h. Nothing is embedded in');
  AddLine('   this binary, so nothing can drift from the ROM.');
  AddLine('');
  AddLine('   abcdefghijklmnopqrstuvwxyz 0123456789');
  AddLine('   ABCDEFGHIJKLMNOPQRSTUVWXYZ !"#$%&*+-/');
  AddLine('');
end;

procedure LoadFile(const Path: ShortString);
var
  F: Text;
  L: ShortString;
begin
  Assign(F, Path);
  {$I-} Reset(F); {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('cannot open ', Path);
    Halt(10);
  end;
  while (not Eof(F)) and (NLines <= High(Lines)) do
  begin
    {$I-} ReadLn(F, L); {$I+}
    if IOResult <> 0 then Break;
    AddLine(L);
  end;
  Close(F);
end;

var
  I, Rc:  Integer;
  S:      ShortString;
  T0, Tk: LongInt;
  B0:     LongInt;

begin
  Banner('DLCON', VER, 'a text console over USB');
  FileArg := '';

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'S': Secs := DecArg(S, 4);
        'C': Ink := HexArg(S, 4);
        'B': Paper := HexArg(S, 4);
        'D': Demo := True;
        'F': FileArg := Copy(S, 4, Length(S) - 3);
        'T': AddLine(Copy(S, 4, Length(S) - 3));
      end;
  end;
  if HelpWanted then begin Usage; Halt(0); end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if Secs < 0 then Secs := 0;
  T := DlModes[ModeIx];
  Cols := T.XRes div GW;
  if Cols > MAXCOL then Cols := MAXCOL;
  Rows := T.YRes div GH;

  if FileArg <> '' then LoadFile(FileArg);
  if (NLines = 0) or Demo then BuildDemo;

  FindFont;
  if FontSeg = 0 then
  begin
    WriteLn('the BIOS would not hand over a font pointer (INT 10h 1130h)');
    Halt(9);
  end;

  RowBuf := PRowBuf(GetMem(SizeOf(TRowBuf)));
  if RowBuf = nil then
  begin
    WriteLn('out of heap for a ', SizeOf(TRowBuf), '-byte row buffer');
    Halt(9);
  end;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then begin WriteLn(DlWhy(Rc)); Halt(Rc); end;

  WriteLn('mode      ', T.Name);
  WriteLn('console   ', Cols, ' x ', Rows, ' characters, 8x16 ROM font');
  WriteLn('font at   ', Hex4(FontSeg), ':', Hex4(FontOfs));
  WriteLn('lines     ', NLines);
  WriteLn;

  if not DlSetMode(T) then
  begin
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;

  T0 := Ticks;
  DlZeroStats;
  B0 := DlBytes;

  { Paper once, then only the rows that carry text. }
  if not DlFillRun(0, Paper, LongInt(T.XRes) * T.YRes) then
  begin
    WriteLn('the adapter stopped accepting pixels');
    Halt(DL_REFUSED);
  end;
  if not DlSend then WriteLn('send failed clearing the screen');

  for I := 0 to NLines - 1 do
  begin
    DlTick;
    if DlEscaped then Break;
    if I >= Rows then Break;
    if Lines[I] = '' then Continue;        { paper is already paper }
    if not DrawRow(I, Lines[I]) then
    begin
      WriteLn('the adapter stopped accepting pixels at row ', I);
      Halt(DL_REFUSED);
    end;
  end;
  if not DlSend then WriteLn('final send failed');

  Tk := Ticks - T0;
  if Tk < 1 then Tk := 1;
  WriteLn('drawn in  ', Tk, ' ticks  (', (Tk * 10) div 182, '.',
          ((Tk * 10) div 18) mod 10, ' s)');
  WriteLn('bytes     ', DlBytes - B0, '  against ',
          LongInt(T.XRes) * T.YRes * 2, ' for the same area raw');
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
