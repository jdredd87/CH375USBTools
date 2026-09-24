program dltest;
{ DLTEST -- draw test patterns on a DisplayLink adapter and ask the person
  watching whether each one appeared.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLTEST [/P=260] [/M=n] [/W=secs] [/A=secs] [/N] [/Q] [/B] [/X=n] [/Y=n]

      /P=hex   I/O base, default 260
      /M=dec   video mode index, default 0
      /W=dec   seconds to hold each pattern before asking, default 3
      /A=dec   seconds to wait for an answer, default 10
      /N       do not ask anything -- just run the patterns, unattended
      /Q       no beep
      /B       blank the output again on the way out
      /X=n     move the picture n pixels right (negative = left)
      /Y=n     move the picture n lines down (negative = up)

  A picture landing off-centre is USUALLY the monitor needing its own
  auto-adjust, not the timings.  Press that first -- it is what fixed the
  DELL 1708FP here.  /X and /Y exist to prove where the fault is, and have
  no default.

  HOW THE ASKING WORKS, AND WHY IT IS ON STDERR

  A job's stdout is redirected into C:\WORK\OUT.TXT and reaches nobody
  until the job has finished, so a prompt written there would be read some
  minutes after the moment it was asking about.  DOS cannot redirect
  handle 2 at all -- normally a nuisance in this project -- so stderr lands
  on the machine's real screen, which is exactly where somebody watching it
  is looking.  The prompt and the verdict go there; the narration goes to
  stdout for the transcript.

  Each question beeps FIRST, because a prompt is useless if nobody's eyes
  are on the screen while the pattern is up.  Then it waits a bounded
  number of seconds.  No answer is recorded as "no answer" and the run
  moves on, because the two cases it cannot tell apart -- the pattern did
  not appear, and nobody was looking -- are both non-answers, and
  collapsing them into "fail" would put a guess in the log.  Every wait is
  bounded by the BIOS tick counter, so an unattended run finishes on its
  own rather than turning a job into a hang.

  Exit codes: 0 every pattern confirmed seen, 7 the adapter stopped
              accepting the command stream, 8 patterns were sent but NOT
              confirmed (told no, or nobody answered) -- deliberately
              distinct from 0; otherwise the DlOpen reason (all <= 20) }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

uses ch375, chtool, dl;

const
  VER = '1.1.0';
  PIT_FREQ = 1193180;

  { 16bpp 5-6-5.  Chosen so the bands cannot be mistaken for a monitor's
    own blank screen or its "no signal" caption -- which is the failure a
    single solid colour would be ambiguous about. }
  NBANDS = 8;
  Bands: array[0..NBANDS - 1] of Word =
    ($F800, $07E0, $001F, $FFFF, $FFE0, $07FF, $F81F, $8410);
  BandNames = 'red green blue white yellow cyan magenta grey';

var
  T:        TDlTiming;
  ModeIx:   Integer = 0;
  HoldSecs: Integer = 3;
  AskSecs:  Integer = 10;
  NoAsk:    Boolean = False;
  NoBeep:   Boolean = False;
  BlankOut: Boolean = False;
  HNudge:   Integer = 0;
  VNudge:   Integer = 0;
  NSeen:    Integer = 0;
  NUnseen:  Integer = 0;
  NNoAns:   Integer = 0;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ Everything that waits is measured against the BIOS tick counter at
  18.2 Hz, never a spin count -- a spin loop calibrated on one machine means
  nothing on any other, and a wait that cannot expire is how a job
  turns into a hang that needs hands on the keyboard. }
procedure WaitTicks(N: LongInt);
var T0: LongInt;
begin
  T0 := Ticks;
  while True do
  begin
    if Ticks < T0 then Break;            { midnight rollover }
    if Ticks - T0 >= N then Break;
  end;
end;

procedure WaitSecs(S: Integer);
begin
  WaitTicks((LongInt(S) * 182) div 10);
end;

procedure SpeakerOff;
begin
  OutB($61, InB($61) and $FC);
end;

procedure Attention;
var D: Word;
begin
  if NoBeep then Exit;
  D := Word(PIT_FREQ div 1000);
  OutB($43, $B6);
  OutB($42, Lo(D));
  OutB($42, Hi(D));
  OutB($61, InB($61) or 3);
  WaitTicks(3);
  SpeakerOff;
end;

function GetKey: Char; assembler;
asm
  mov ah, 0
  int 16h
end;

{ Hold the pattern, then beep and ask -- bounded, and honest about a
  non-answer.  Returns 'Y', 'N' or '?'. }
function AskSeen(const What: ShortString): Char;
var
  T0, Limit: LongInt;
  C:         Char;
begin
  WriteLn('  showing: ', What);
  WaitSecs(HoldSecs);

  if NoAsk then
  begin
    AskSeen := '?';
    Inc(NNoAns);
    WriteLn('  /N given -- not asked.');
    Exit;
  end;

  Attention;
  Write(ErrOutput, '>> ', What, ' -- SEEN IT?  Y/N  (',
        Dec1(AskSecs), 's) ');

  C := #0;
  T0 := Ticks;
  Limit := (LongInt(AskSecs) * 182) div 10;
  while True do
  begin
    if KeyWaiting then begin C := GetKey; Break; end;
    if Ticks < T0 then Break;
    if Ticks - T0 >= Limit then Break;
  end;

  if (C = 'Y') or (C = 'y') then
  begin
    AskSeen := 'Y'; Inc(NSeen);
    WriteLn(ErrOutput, ' yes');
    WriteLn('  CONFIRMED SEEN.');
  end
  else if (C = 'N') or (C = 'n') then
  begin
    AskSeen := 'N'; Inc(NUnseen);
    WriteLn(ErrOutput, ' no');
    WriteLn('  reported NOT seen.');
  end
  else
  begin
    AskSeen := '?'; Inc(NNoAns);
    if C = #0 then
    begin
      WriteLn(ErrOutput, ' (no answer)');
      WriteLn('  NO ANSWER in ', AskSecs, 's -- which means either the');
      WriteLn('  pattern did not appear or nobody was watching.  Those');
      WriteLn('  are not distinguishable from here and are not guessed at.');
    end
    else
    begin
      WriteLn(ErrOutput, ' (not Y or N)');
      WriteLn('  answered with something other than Y or N -- taken as');
      WriteLn('  no answer rather than interpreted.');
    end;
  end;
end;

{ Horizontal bands, which tile the framebuffer as contiguous runs and so
  cost almost nothing to encode. }
function Bandy: Boolean;
var
  I:    Integer;
  Rows: LongInt;
  Px:   LongInt;
begin
  Bandy := False;
  Rows := T.YRes div NBANDS;
  for I := 0 to NBANDS - 1 do
  begin
    Px := Rows * T.XRes;
    if I = NBANDS - 1 then
      Px := (LongInt(T.YRes) - Rows * (NBANDS - 1)) * T.XRes;
    if not DlFillRun(LongInt(I) * Rows * T.XRes * 2, Bands[I], Px) then Exit;
  end;
  Bandy := DlSend;
end;

function Solid(C: Word): Boolean;
begin
  Solid := False;
  if not DlFillRun(0, C, LongInt(T.XRes) * T.YRes) then Exit;
  Solid := DlSend;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
var I: Integer;
begin
  WriteLn('  DLTEST [/P=260] [/M=n] [/W=secs] [/A=secs] [/N] [/Q] [/B]');
  WriteLn('         [/X=n] [/Y=n]');
  WriteLn;
  WriteLn('    /W=dec  seconds to hold each pattern, default 3');
  WriteLn('    /A=dec  seconds to wait for an answer, default 10');
  WriteLn('    /N      do not ask -- run the patterns unattended');
  WriteLn('    /Q      no beep');
  WriteLn('    /B      blank the output again on the way out');
  WriteLn('    /X=n    move the picture n pixels right (negative = left)');
  WriteLn('    /Y=n    move the picture n lines down (negative = up)');
  WriteLn('    /M=dec  mode, default 0:');
  for I := 0 to NDLMODES - 1 do
    WriteLn('              ', I, ' = ', DlModes[I].Name);
  WriteLn;
  WriteLn('  A picture landing off-centre is USUALLY the monitor needing');
  WriteLn('  its own auto-adjust, not the timings.  Press that first --');
  WriteLn('  it is what fixed the DELL 1708FP here.  /X and /Y exist to');
  WriteLn('  prove where the fault is, and have no default.');
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

function SignedArg(const S: ShortString; From: Integer): Integer;
var Neg: Boolean;
begin
  Neg := (From <= Length(S)) and (S[From] = '-');
  if Neg then Inc(From);
  if Neg then SignedArg := -DecArg(S, From)
         else SignedArg :=  DecArg(S, From);
end;

{ Leave the chip fit for the next program, and the speaker quiet.  A token
  stranded in the chip makes the NEXT tool report "no CH375 at 0260" on a
  card that is plainly fitted, and a beep left gated leaves the machine
  screaming -- both cost somebody a walk to the machine. }
procedure Quieten;
begin
  SpeakerOff;
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

var
  I, Rc: Integer;
  S:     ShortString;

begin
  Banner('DLTEST', VER, 'DisplayLink video-output test');
  if HelpWanted then begin Usage; Halt(0); end;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'W': HoldSecs := DecArg(S, 4);
        'A': AskSecs := DecArg(S, 4);
        'N': NoAsk := True;
        'Q': NoBeep := True;
        'B': BlankOut := True;
        'X': HNudge := SignedArg(S, 4);
        'Y': VNudge := SignedArg(S, 4);
      end;
  end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if HoldSecs < 0 then HoldSecs := 0;
  if AskSecs < 1 then AskSecs := 1;
  T := DlModes[ModeIx];

  { Move the active region within the line and frame WITHOUT changing
    either total or the dot clock, so it stays the same mode and only the
    picture's position inside it moves.  Whatever leaves one porch goes
    into the other. }
  if HNudge <> 0 then
  begin
    if (Integer(T.LeftM) + HNudge >= 0)
       and (Integer(T.RightM) - HNudge >= 0) then
    begin
      T.LeftM  := Word(Integer(T.LeftM) + HNudge);
      T.RightM := Word(Integer(T.RightM) - HNudge);
      WriteLn('h-nudge  ', HNudge, ' px (line total unchanged)');
    end
    else
      WriteLn('h-nudge  ', HNudge, ' REFUSED -- it would drive a porch',
              ' negative, corrupting the mode rather than moving it.');
  end;
  if VNudge <> 0 then
  begin
    if (Integer(T.UpperM) + VNudge >= 0)
       and (Integer(T.LowerM) - VNudge >= 0) then
    begin
      T.UpperM := Word(Integer(T.UpperM) + VNudge);
      T.LowerM := Word(Integer(T.LowerM) - VNudge);
      WriteLn('v-nudge  ', VNudge, ' lines (frame total unchanged)');
    end
    else
      WriteLn('v-nudge  ', VNudge, ' REFUSED -- it would drive a porch',
              ' negative.');
  end;

  WriteLn('I/O base ', Hex4(Base), 'h');
  WriteLn('mode     ', T.Name, '  (', LongInt(T.XRes) * T.YRes * 2,
          ' bytes a frame at 16bpp)');
  WriteLn;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then
  begin
    WriteLn(DlWhy(Rc));
    { When it is the wrong CHIP rather than a fault, say which chip and
      why -- the same words every other tool uses, from the same table. }
    if Rc = DL_NOTDL then
    begin
      WriteLn;
      WriteLn('  ', Hex4(DlDevVID), ':', Hex4(DlDevPID), '  ',
              DlFamilyName(DlDevFamily));
      WriteLn;
      DlFamilyVerdict(DlDevFamily);
    end;
    Halt(Rc);
  end;
  WriteLn('bulk OUT endpoint ', Hex2(DlEpBulk));
  WriteLn;

  { ---- 1. the mode ---- }
  WriteLn('TEST 1 -- set the mode and unblank');
  if not DlSetMode(T) then
  begin
    WriteLn('  the adapter stopped accepting the command stream.');
    Halt(7);
  end;
  WriteLn('  sent.  A monitor takes a second or two to sync.');
  WaitSecs(2);
  { Asked about the monitor LEAVING "no signal" rather than about "any
    picture", because at this point the framebuffer holds whatever was
    left in it and there is nothing specific to describe.  This is also
    the redundant question: any later pattern being seen proves the mode
    was set, since nothing can appear without it. }
  AskSeen('mode ' + T.Name + ' -- monitor STOPPED saying "no signal"');

  { ---- 2. a solid fill ---- }
  WriteLn;
  WriteLn('TEST 2 -- solid red, whole screen');
  if not Solid($F800) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen('solid RED filling the whole screen');

  { ---- 3. the bands ---- }
  WriteLn;
  WriteLn('TEST 3 -- ', NBANDS, ' horizontal colour bands');
  WriteLn('  top to bottom: ', BandNames);
  if not Bandy then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen(Dec1(NBANDS) + ' colour bands, red at the top');

  { ---- 4. blue, to settle the byte order ---- }
  WriteLn;
  WriteLn('TEST 4 -- solid blue');
  WriteLn('  This one is about BYTE ORDER, not about drawing.  If it comes');
  WriteLn('  out blue the 5-6-5 pixels are going out the right way round;');
  WriteLn('  if it is red or green they are byte-swapped, and the bands');
  WriteLn('  above would have looked plausible while being wrong.');
  if not Solid($001F) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen('solid BLUE -- not red, not green');

  { ---- 5. the stale tail ---- }
  WriteLn;
  WriteLn('TEST 5 -- does the END of a fill actually land?');
  WriteLn('  White over blue, and the question is about the BOTTOM RIGHT');
  WriteLn('  corner only.  The command parser does not act on the last');
  WriteLn('  command of a transfer until more bytes follow it, so without');
  WriteLn('  AF padding the final command -- 256 pixels -- silently does');
  WriteLn('  nothing and the previous colour survives there.  That reads');
  WriteLn('  as a drawing bug and is a framing one, so it gets its own');
  WriteLn('  test rather than hiding inside "did you see white".');
  if not Solid($FFFF) then
  begin
    WriteLn('  the adapter stopped accepting pixels.');
    Halt(7);
  end;
  AskSeen('ALL white -- no blue surviving in the bottom-right corner');

  if BlankOut then
  begin
    DlBlank(True);
    WriteLn;
    WriteLn('Output blanked again (/B).');
  end;

  { ---- the tally ---- }
  WriteLn;
  WriteLn('================================================================');
  WriteLn('  confirmed seen : ', NSeen);
  WriteLn('  reported unseen: ', NUnseen);
  WriteLn('  no answer      : ', NNoAns);
  WriteLn('  bytes sent     : ', DlBytes, ' in ', DlPackets, ' packets');
  WriteLn('================================================================');
  if (NUnseen = 0) and (NNoAns = 0) then
  begin
    WriteLn('Every pattern was confirmed by somebody looking at it.  That is');
    WriteLn('the only instrument that can settle this, and it says the');
    WriteLn('adapter is displaying what it was told to.');
    Halt(0);
  end;
  WriteLn('NOT a clean pass.  Patterns were sent and the command stream was');
  WriteLn('accepted throughout -- so what is unproven is whether anything');
  WriteLn('reached the glass, and that is exactly what "no answer" leaves');
  WriteLn('open.  Re-run with somebody watching before reading anything');
  WriteLn('into it either way.');
  Halt(8);
end.
