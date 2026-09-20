program camsnap;
{ CAMSNAP -- take a still photograph with an IBM PC Camera over a CH375.
  CH375Camera, StevenC.  Public domain (the Unlicense).

    CAMSNAP [/P=260] [/M=320] [/O=SNAP] [/G] [/B=32] [/T=n] [/H=n] [/V]

  Writes name.BMP -- 24-bit colour, or 8-bit grey with /G -- and
  name.RAW, the camera's own bytes: the Bayer mosaic (GRBG, one byte a
  pixel) at 320x240 and 352x288, or the Y, U and V planes one after the
  other at 176x144.

  /M picks the camera's mode, and these are all it has natively:

      176   176x144, YUV 4:2:0 -- the whole sensor scaled by half
      320   320x240, Bayer     -- the middle of the sensor
      352   352x288, Bayer     -- the whole sensor

  HOW.  The camera streams far faster than a CH375 can read, and drops
  what is not read; see camgrab.pas.  What does arrive whole is a narrow
  window of the picture -- 64 pixels wide, the full height -- so the
  picture is taken as vertical strips, one camera frame each: 3 frames at
  176, 5 at 320, 6 at 352.  About a third of a second a frame.

  The scene has to hold still while the strips are taken.  It is a
  photograph, not a video. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, cit, camgrab, camfile;

const
  VER = '0.4.0';

var
  OutBase:  ShortString = 'SNAP';
  ModeNo:   Integer = 2;
  Grey:     Boolean = False;
  Tries:    Integer = 8;
  StripH:   Integer = 0;          { 0 = the full height }
  Chatty:   Boolean = False;
  Art:      Boolean = False;        { /A: also .TXT and .ANS, ASCII to stdout }

procedure Usage;
begin
  WriteLn;
  WriteLn('CAMSNAP [/P=hex] [/M=n] [/O=name] [/G] [/B=n] [/T=n] [/H=n] [/V]');
  WriteLn;
  WriteLn('Takes one still from an IBM PC Camera (0545:8080 model 2) and');
  WriteLn('writes name.BMP and name.RAW.  The scene must keep still.');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /M=n     mode: 176 (176x144 YUV), 320 (320x240 Bayer, default),');
  WriteLn('           352 (352x288 Bayer)');
  WriteLn('  /O=name  output name without extension.  Default SNAP');
  WriteLn('  /G       grey BMP instead of colour');
  WriteLn('  /B=n     brightness 0..63.  Default 32');
  WriteLn('  /T=n     frames to wait for each strip.  Default 8');
  WriteLn('  /H=n     strip height in lines, a multiple of 8.  Default: all');
  WriteLn('  /A       also name.TXT (ASCII art, printed here too) and name.ANS');
  WriteLn('           (ANSI half-block colour art: TYPE it under ANSI.SYS)');
  WriteLn('  /V       per-strip detail: frames, lines, tokens');
  HelpTail;
end;

procedure ParseArgs;
var
  I, C: Integer;
  A, V: ShortString;
  N: LongInt;
  Ok: Boolean;
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
      'O': begin OutBase := V; Ok := (V <> '') and (Length(V) <= 60); end;
      'G': Grey := True;
      'B': begin Ok := (C = 0) and (N >= 0) and (N <= 63); Brightness := N; end;
      'T': begin Ok := (C = 0) and (N > 0) and (N < 100); Tries := N; end;
      'H': begin Ok := (C = 0) and (N >= 8) and (N <= 288) and (N mod 8 = 0);
                 StripH := N; end;
      'V': Chatty := True;
      'A': Art := True;
    else
      Ok := False;
    end;
    if not Ok then begin WriteLn('bad argument: ', A); Halt(2); end;
  end;
end;

var LastBeat: LongInt = 0;
procedure Beat;
const Spin: array[0..3] of Char = ('|', '/', '-', '\');
var T: LongInt;
begin
  T := Ticks;
  if T = LastBeat then Exit;
  LastBeat := T;
  Write(StdErr, Spin[(T shr 2) and 3], #8);
end;

var
  TF: Text;
  R, Bad, I: Integer;
  X, Y, W, H: Word;
  T0, TS: LongInt;
  Ok: Boolean;
begin
  Banner('CAMSNAP', VER, 'a still photograph through a CH375');
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  PortDat := Base; PortCmd := Base + 1;

  R := CamStart(ModeNo, 0);
  if R <> 0 then Halt(R);
  camgrab.Idle := @Beat;
  WriteLn('mode   : ', Mode.W, 'x', Mode.H, ' ',
          Copy('BayerYUV  ', 1 + 5 * Ord(Mode.Fmt), 5));
  WriteLn('speed  : ', TokensPer110ms, ' tokens per 110 ms, so blanking is ',
          BlankRun, ' empty packets');

  T0 := Ticks;
  Bad := 0;
  for I := 0 to StripCount - 1 do
  begin
    StripAt(I, X, W);
    Y := 0;
    while Y < Mode.H do
    begin
      H := Mode.H - Y;
      if (StripH > 0) and (H > StripH) then H := StripH;
      TS := Ticks;
      Ok := GrabWindow(X, Y, W, H, Tries);
      if not Ok then Inc(Bad);
      if Chatty or not Ok then
        WriteLn('  strip x ', X:3, ' y ', Y:3, '  ', W, 'x', H, '  ',
                Copy('ok  MISS', 1 + 4 * Ord(not Ok), 4),
                '  frames ', GWFrames, '  best ', GWBest, ' lines  ',
                GWTokens, ' tokens  ', (Ticks - TS) * 55, ' ms',
                '  break ', GWBreak, '  fails ', GWFails,
                '  last status ', Hex2(PktStatus), '  revived ', GWRevive);
      Inc(Y, H);
    end;
  end;
  WriteLn('time   : ', (Ticks - T0) * 55, ' ms');
  Write(StdErr, ' '#8);

  CamStop;

  FileIdle := @Beat;
  WriteRaw(OutBase + '.RAW');
  WriteBmp(OutBase + '.BMP', Grey);
  WriteLn('wrote  : ', OutBase, '.RAW  ', OutBase, '.BMP');
  if Art then
  begin
    Assign(TF, OutBase + '.TXT'); Rewrite(TF); AsciiArt(TF, 79); Close(TF);
    Assign(TF, OutBase + '.ANS'); Rewrite(TF); AnsiArt(TF, 79); Close(TF);
    WriteLn('wrote  : ', OutBase, '.TXT  ', OutBase, '.ANS');
    WriteLn;
    AsciiArt(Output, 79);
  end;
  if Bad > 0 then
  begin
    WriteLn(Bad, ' strips never arrived whole');
    Halt(12);
  end;
  Halt(0);
end.
