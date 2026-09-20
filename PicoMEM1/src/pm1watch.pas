program pm1watch;
{ PM1WATCH -- watch the WHOLE of the card's shared memory for changes.
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1WATCH [/S=n] [/K] [/2] [/T] [/B-] [/P=2A0]

  Every other tool here reads a place it already knows about.  This one
  reads all 8 KB, many times a second, and reports every byte that
  moved -- the question to ask when you do not know where an answer is
  supposed to land, or whether there is one at all.

    /S=n seconds per window (default 20)
    /K   turn the card's KEYBOARD reporting on for the run (command
         54h), and off again afterwards
    /2   TWO windows, back to back, and compare them.  The first asks
         you to do the thing; the second asks you to keep still.  The
         card is the boot disk, so its saved registers and its disk
         buffer churn from ordinary disk traffic whatever you do, and
         the only honest way to separate that background from a real
         event is to run the same window twice and take the difference
    /T   self-test: ask for the USB list before the snapshot and the
         DISK list in the middle of the window, so the parameter area
         genuinely changes content and the watch must see it.  An
         instrument that reports nothing is worth nothing until it has
         reported something.

         The first version of this sent the SAME query both times and
         reported nothing at all: re-asking rewrites byte-for-byte
         identical text, and a watcher looking for changed VALUES
         cannot see a write that changes none.
    /B-  no sounds
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  The cues are on the PC SPEAKER and on stderr, which the bridge does
  not redirect, so both reach whoever is standing at the machine:

    a long two-tone siren   ->  DO IT NOW (type, move the mouse)
    one short low tone      ->  HANDS OFF, keep still
    a falling three-tone    ->  the window has closed

  ON /K, AND WHY THE ANSWER IS PROBABLY NO.  The card claims a USB
  keyboard and says so -- PM1STAT shows "1: USB keyboard" -- but in the
  published firmware the flag command 54h sets is never read by
  anything, and IRQ_R_KEYBOARD, the interrupt source reserved for
  keystrokes, is defined in a header and raised nowhere.  Compare the
  mouse, which is wired up end to end and does work.  The sources are
  also NEWER than the BIOS on this card, so a feature missing there is
  certainly missing here.  /K exists so the negative can be shown with
  the switch turned on rather than argued from reading alone.

  Exit code: 0 something changed, 1 no card, 3 no shared memory,
  5 nothing changed at all. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.1.0';
  MAXCHG = 400;          { distinct offsets remembered }
  NREG   = 10;           { regions tallied }

type
  TChange = record
    Ofs: Word;
    First, Last: Byte;
    Count: Word;
  end;

var
  Secs: Word;
  DoKeyb, TwoPhase, SelfTest, DoBeep: Boolean;
  ForceBase: Word;
  Snap: array[0..SHARED_LEN - 1] of Byte;
  Chg: array[0..MAXCHG - 1] of TChange;
  NChg: Integer;
  Overflow: LongInt;
  RegHits: array[0..NREG - 1] of LongInt;
  RegA, RegB: array[0..NREG - 1] of LongInt;
  Sweeps: LongInt;
  Fired: Boolean;

function ParseNum(const S: string; var W: Word): Boolean;
var I: Integer; V: LongInt;
begin
  V := 0; ParseNum := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    if (S[I] < '0') or (S[I] > '9') then Exit;
    V := V * 10 + Ord(S[I]) - 48;
    if V > 3600 then Exit;
  end;
  W := V; ParseNum := True;
end;

function ParseHex(const S: string; var W: Word): Boolean;
var I: Integer; C: Char; V: Word;
begin
  V := 0; ParseHex := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    C := UpCase(S[I]);
    case C of
      '0'..'9': V := V * 16 + Ord(C) - 48;
      'A'..'F': V := V * 16 + Ord(C) - 55;
    else Exit;
    end;
  end;
  W := V; ParseHex := True;
end;

procedure Args;
var I: Integer; S: string; W: Word;
begin
  Secs := 20; DoKeyb := False; TwoPhase := False;
  SelfTest := False; DoBeep := True; ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'K': DoKeyb := True;
        '2': TwoPhase := True;
        'T': SelfTest := True;
        'B': DoBeep := not ((Length(S) > 2) and (S[3] = '-'));
        'S': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 9), W) then Secs := W;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
  if Secs < 4 then Secs := 4;
end;

{ Straight at the 8253 and port 61h -- never Crt, whose unit
  initialisation takes the output driver away from the bridge. }
procedure Tone(Freq: Word; Dur: Word);
var D: Word; Old: Byte; T0: LongInt;
begin
  D := Word(LongInt(1193180) div LongInt(Freq));
  OutB($43, $B6);
  OutB($42, Lo(D));
  OutB($42, Hi(D));
  Old := InB($61);
  OutB($61, Old or 3);
  T0 := Ticks;
  while (Ticks - T0 < Dur) and (Ticks >= T0) do ;
  OutB($61, Old and $FC);
end;

procedure Gap(Dur: Word);
var T0: LongInt;
begin
  T0 := Ticks;
  while (Ticks - T0 < Dur) and (Ticks >= T0) do ;
end;

{ An ATTENTION sound, not a polite one: whoever has to type is not
  reading the terminal this prints on.  The pause afterwards is time to
  get a hand to the keyboard. }
procedure CueGo;
var I: Integer;
begin
  if not DoBeep then Exit;
  for I := 1 to 8 do begin
    Tone(880, 3);
    Tone(1320, 3);
  end;
  Gap(9);
end;

procedure CueStill;
begin
  if DoBeep then begin Tone(440, 6); Gap(9); end;
end;

procedure CueTick;
begin
  if DoBeep then Tone(1320, 1);
end;

procedure CueEnd;
begin
  if not DoBeep then Exit;
  Tone(1320, 3); Gap(1); Tone(880, 3); Gap(1); Tone(660, 6);
end;

{ What is this offset part of?  Anchored on the parameter area PM1CARD
  found, the only fixed point that holds on both firmwares. }
function RegionOf(Ofs: Word): Integer;
var Pccmd, IrqV: Word;
begin
  Pccmd := PmParam - 36;
  IrqV  := PmParam - 32;
  if Ofs < 32 then RegionOf := 0
  else if Ofs < 64 then RegionOf := 1
  else if Ofs < 82 then RegionOf := 2
  else if Ofs < Pccmd then RegionOf := 3
  else if Ofs < IrqV then RegionOf := 4
  else if Ofs < PmParam then RegionOf := 5
  else if Ofs < 4096 then RegionOf := 6
  else if Ofs < 6144 then RegionOf := 7
  else RegionOf := 8;
end;

function RegionName(R: Integer): string;
begin
  case R of
    0: RegionName := 'BIOS variables';
    1: RegionName := 'disk parameter table';
    2: RegionName := 'saved registers (an INT 13h in flight)';
    3: RegionName := 'configuration';
    4: RegionName := 'PC command block';
    5: RegionName := 'IRQ variables (where the mouse lands)';
    6: RegionName := 'parameter area (text answers)';
    7: RegionName := 'disk buffer (sector data)';
  else
    RegionName := 'DMA buffer';
  end;
end;

function Region(Ofs: Word): string;
var IrqV: Word;
begin
  IrqV := PmParam - 32;
  if (Ofs >= IrqV) and (Ofs < PmParam) then
    case Ofs - IrqV of
      11: begin Region := 'IRQ vars: mouse X'; Exit; end;
      12: begin Region := 'IRQ vars: mouse Y'; Exit; end;
      13: begin Region := 'IRQ vars: mouse buttons'; Exit; end;
    end;
  Region := RegionName(RegionOf(Ofs));
end;

procedure Note(Ofs: Word; Was, Now_: Byte);
var I: Integer;
begin
  Inc(RegHits[RegionOf(Ofs)]);
  for I := 0 to NChg - 1 do
    if Chg[I].Ofs = Ofs then begin
      Chg[I].Last := Now_;
      Inc(Chg[I].Count);
      Exit;
    end;
  if NChg >= MAXCHG then begin Inc(Overflow); Exit; end;
  Chg[NChg].Ofs := Ofs;
  Chg[NChg].First := Was;
  Chg[NChg].Last := Now_;
  Chg[NChg].Count := 1;
  Inc(NChg);
end;

{ One window: cue, snapshot, then sweep until the time is up.  The cue
  and the progress go to stderr, which the bridge does not redirect, so
  they land on the machine's own screen where the hands are. }
procedure Window(const Prompt: string; Go: Boolean);
var
  O: Word; B: Byte;
  T0, TEnd, TMid, TTick, Spun: LongInt;
  I: Integer;
  Res: Word;
begin
  NChg := 0; Overflow := 0; Sweeps := 0; Fired := False;
  for I := 0 to NREG - 1 do RegHits[I] := 0;

  if SelfTest then begin
    Res := 0;
    Command(CMD_USB_STATUS, 0, 91, Res);
  end;

  WriteLn(StdErr);
  WriteLn(StdErr, '>>> ', Prompt);
  if Go then CueGo else CueStill;

  { after the cue, so the tones themselves are not in the window }
  for O := 0 to SHARED_LEN - 1 do Snap[O] := SharedB(O);

  T0 := Ticks;
  TEnd := T0 + LongInt(Secs) * 91 div 5;
  TMid := T0 + (TEnd - T0) div 2;
  TTick := T0 + 91;
  Spun := -1;

  while (Ticks < TEnd) and (Ticks >= T0) do begin
    if SelfTest and (not Fired) and (Ticks >= TMid) then begin
      Fired := True;
      Res := 0;
      Command(CMD_DISK_STAT, 0, 91, Res);
    end;
    for O := 0 to SHARED_LEN - 1 do begin
      B := SharedB(O);
      if B <> Snap[O] then begin
        Note(O, Snap[O], B);
        Snap[O] := B;
      end;
    end;
    Inc(Sweeps);
    if Ticks shr 2 <> Spun then begin
      Spun := Ticks shr 2;
      Write(StdErr, '.');
    end;
    if (Ticks >= TTick) and (Ticks < TEnd - 18) then begin
      TTick := Ticks + 91;
      CueTick;
    end;
  end;
  WriteLn(StdErr);
  CueEnd;
end;

procedure ShowTally;
var I: Integer;
begin
  for I := 0 to NREG - 1 do
    if RegHits[I] > 0 then
      WriteLn('   ', RegHits[I]:7, '  ', RegionName(I));
end;

procedure ShowDetail;
var I: Integer;
begin
  WriteLn('   offset  first  last  times  what it is');
  for I := 0 to NChg - 1 do
    if RegionOf(Chg[I].Ofs) <> 7 then
      WriteLn('   +', Chg[I].Ofs:5, '     ', Hex2(Chg[I].First), '    ',
              Hex2(Chg[I].Last), ' ', Chg[I].Count:6, '  ',
              Region(Chg[I].Ofs));
  if Overflow > 0 then
    WriteLn('   (', Overflow, ' change(s) past the ', MAXCHG,
            ' offsets remembered; the tally above is complete)');
end;

var
  Bad: Word;
  I: Integer;
  Res: Word;
  R: Byte;
  Rc: Integer;
  Diff: LongInt;
begin
  Args;
  WriteLn('PM1WATCH ', VER, ' -- every byte of the card''s shared memory');
  Rc := 0;

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h');
    Halt(1);
  end;
  if not SharedOK then begin
    WriteLn('no shared memory at ', Hex4(PmRomSeg), ':4000');
    Halt(3);
  end;
  if not FindParam then
    WriteLn('the parameter area was not found; regions below are guesses')
  else
    WriteLn('answers at +', PmParam, ', IRQ variables at +', PmParam - 32);

  if DoKeyb then begin
    Res := 0;
    R := Command(CMD_KEYB_ONOFF, 1, 91, Res);
    WriteLn('keyboard reporting on (54h): ', ResultName(R));
  end;

  if TwoPhase then begin
    WriteLn;
    WriteLn('Two windows of ', Secs, ' seconds each.');
    WriteLn('  siren    -> DO IT NOW');
    WriteLn('  low tone -> HANDS OFF, keep still');

    Window('DO IT NOW -- hit keys, keep hitting them', True);
    for I := 0 to NREG - 1 do RegA[I] := RegHits[I];

    Window('HANDS OFF -- touch nothing until the falling tones', False);
    for I := 0 to NREG - 1 do RegB[I] := RegHits[I];

    WriteLn;
    WriteLn('changes per region, ', Secs, ' seconds each:');
    WriteLn('     doing it   keeping still   difference   region');
    for I := 0 to NREG - 1 do
      if (RegA[I] > 0) or (RegB[I] > 0) then begin
        Diff := RegA[I] - RegB[I];
        WriteLn('   ', RegA[I]:9, RegB[I]:14, Diff:13, '   ', RegionName(I));
      end;
    WriteLn;
    WriteLn('A region that moves in BOTH windows is the card getting on');
    WriteLn('with its own work: this machine boots from it, so the saved');
    WriteLn('registers and the disk buffer move on every INT 13h whatever');
    WriteLn('anyone does.  Only a region that moves while you act and sits');
    WriteLn('still while you do not is evidence of anything.');
  end else begin
    Window('GO -- do the thing being watched for', True);
    WriteLn;
    WriteLn(Sweeps, ' sweeps of 8192 bytes in ', Secs, ' seconds');
    if NChg = 0 then begin
      WriteLn('NOT ONE BYTE of the card''s shared memory changed.');
      Rc := 5;
    end else begin
      WriteLn('changes by region:');
      ShowTally;
      WriteLn;
      WriteLn(NChg, ' distinct offset(s), disk buffer omitted:');
      ShowDetail;
    end;
    if SelfTest then begin
      WriteLn;
      if Fired and (NChg > 0) then
        WriteLn('self-test: the disk list was sent mid-window, and the',
                ' watch saw it.')
      else if Fired then
        WriteLn('self-test: the disk list was sent and the watch SAW',
                ' NOTHING -- do not trust the result above.')
      else
        WriteLn('self-test: the query never fired; the window was too short.');
    end;
  end;

  if DoKeyb then begin
    Res := 0;
    R := Command(CMD_KEYB_ONOFF, 0, 91, Res);
    WriteLn('keyboard reporting off (54h): ', ResultName(R));
  end;

  Halt(Rc);
end.
