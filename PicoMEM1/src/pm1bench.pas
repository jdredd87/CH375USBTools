program pm1bench;
{ PM1BENCH -- what does the PicoMEM cost to talk to?
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1BENCH [/T=n] [/C-] [/P=2A0]

  Four measurements, all of them things a program built on this card
  would do in a loop:

    * reading the counting test port, which is one 8-bit ISA read
    * reading the card's emulated RAM (its shared memory), a word at
      a time, against the same loop over the PC's own RAM -- the card
      answers an ISA memory cycle out of a Pico, so this is the real
      cost of using it as memory
    * reading the card's BIOS ROM the same way
    * a whole command round trip: argument, command, wait for ready,
      read the result

  Timed off the BIOS tick and reported per second.  Each test runs for
  a fixed number of ticks rather than a fixed number of turns, so the
  figures mean the same thing on a V30 and on a 386.

    /T=n  ticks per test (default 18, about one second)
    /C-   skip the command round trip, and send nothing to the card
    /P=   I/O base to try if the card BIOS does not answer (default 2A0)

  Exit code: 0 measured, 1 no card, 3 no shared memory. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.0.0';
  BATCH = 64;            { turns between clock reads: enough that the
                           clock read is not what is being measured }

var
  TicksPer: Integer;
  DoCmd: Boolean;
  ForceBase: Word;
  Sink: array[0..2047] of Word;    { the PC's own RAM, to read against }

function ParseNum(const S: string; var N: Integer): Boolean;
var I, V: Integer;
begin
  V := 0; ParseNum := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    if (S[I] < '0') or (S[I] > '9') then Exit;
    V := V * 10 + Ord(S[I]) - 48;
    if V > 900 then Exit;
  end;
  N := V; ParseNum := True;
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
var I, N: Integer; S: string; W: Word;
begin
  TicksPer := 18; DoCmd := True; ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'C': DoCmd := not ((Length(S) > 2) and (S[3] = '-'));
        'T': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 4), N) then TicksPer := N;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
  if TicksPer < 4 then TicksPer := 4;
end;

{ Per second, from a count of turns and the ticks they took.  The BIOS
  tick is 1193180/65536 per second: multiplying by 91 and dividing by 5
  is that ratio to within a tenth of a percent, in 32-bit integers. }
function PerSecond(Turns: LongInt; Tk: LongInt): LongInt;
begin
  if Tk <= 0 then PerSecond := 0
  else PerSecond := (Turns div Tk) * 91 div 5 +
                    ((Turns mod Tk) * 91 div 5) div Tk;
end;

procedure Report(const What: string; Turns, Tk: LongInt);
var P: LongInt;
begin
  P := PerSecond(Turns, Tk);
  Write('  ', What);
  WriteLn(P:12, ' per second');
end;

{ Each test: spin until the tick changes so the first turn starts on a
  boundary, then run in batches until the budget is spent. }
function StartClock: LongInt;
var T: LongInt;
begin
  T := Ticks;
  while Ticks = T do ;
  StartClock := Ticks;
end;

var
  T0, Elapsed, Turns: LongInt;
  I, J: Integer;
  B: Byte;
  W: Word;
  Res: Word;
  R: Byte;
  Bad: Word;
  Sum: LongInt;
  Sg, Of_: Word;
  CardRam, PcRam: LongInt;
begin
  Args;
  WriteLn('PM1BENCH ', VER, ' -- what the card costs to read and to ask');

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h (', Bad,
            ' of 100 test-port reads out of sequence)');
    Halt(1);
  end;
  if not SharedOK then begin
    WriteLn('no shared memory at ', Hex4(PmRomSeg), ':4000');
    Halt(3);
  end;
  WriteLn('card at ', Hex4(PmBase), 'h, ROM ', Hex4(PmRomSeg), 'h, ',
          TicksPer, ' ticks per test');
  WriteLn;

  Sum := 0;

  { 1. the counting test port: one 8-bit ISA input }
  Turns := 0;
  T0 := StartClock;
  while Ticks - T0 < TicksPer do begin
    for J := 1 to BATCH do B := InB(PmBase + 3);
    Inc(Turns, BATCH);
  end;
  Elapsed := Ticks - T0;
  Sum := Sum + B;
  Report('card I/O port read     ', Turns, Elapsed);

  { 2. the card's emulated RAM, a word at a time.

    Every memory row below uses this ONE loop shape, with both the
    segment and the offset in variables.  That is not fussiness: the
    first version wrote the card's rows as MemW[seg : CONSTANT + i] and
    the PC's as MemW[seg : variable + i], so the PC's loop did an extra
    addition per turn that the card's did not, and the ratio between
    them flattered the card.  An instrument has to do the same work on
    both sides of the comparison it is making. }
  CardRam := 0;
  Sg := PmRomSeg; Of_ := SHARED_OFS;
  Turns := 0;
  T0 := StartClock;
  while Ticks - T0 < TicksPer do begin
    for J := 1 to BATCH do W := MemW[Sg : Of_ + (J and $FE)];
    Inc(Turns, BATCH);
  end;
  Elapsed := Ticks - T0;
  Sum := Sum + W;
  Report('card RAM word read     ', Turns, Elapsed);
  CardRam := PerSecond(Turns, Elapsed);

  { 3. the card's BIOS ROM, the same loop }
  Sg := PmRomSeg; Of_ := 0;
  Turns := 0;
  T0 := StartClock;
  while Ticks - T0 < TicksPer do begin
    for J := 1 to BATCH do W := MemW[Sg : Of_ + (J and $FE)];
    Inc(Turns, BATCH);
  end;
  Elapsed := Ticks - T0;
  Sum := Sum + W;
  Report('card ROM word read     ', Turns, Elapsed);

  { 4. the PC's own RAM, through the same loop, so the only difference
    left is which chip answers the bus cycle }
  Sg := Seg(Sink); Of_ := Ofs(Sink);
  Turns := 0;
  T0 := StartClock;
  while Ticks - T0 < TicksPer do begin
    for J := 1 to BATCH do W := MemW[Sg : Of_ + (J and $FE)];
    Inc(Turns, BATCH);
  end;
  Elapsed := Ticks - T0;
  Sum := Sum + W;
  Report('the PC own RAM, same   ', Turns, Elapsed);
  PcRam := PerSecond(Turns, Elapsed);

  if DoCmd then begin
    { 5. a whole command round trip.  05h is used because it is the
      cheapest read-only command the card has: it looks one entry up
      in a table.  Anything built on this card pays this per call. }
    Turns := 0;
    R := CR_OK;
    T0 := StartClock;
    while (Ticks - T0 < TicksPer) and (R = CR_OK) do begin
      for J := 1 to 8 do begin
        R := Command(CMD_MEMTYPE, 52, 18, Res);
        if R <> CR_OK then Break;
      end;
      Inc(Turns, 8);
    end;
    Elapsed := Ticks - T0;
    if R <> CR_OK then
      WriteLn('  command round trip     FAILED: ', ResultName(R))
    else begin
      Report('command round trip     ', Turns, Elapsed);
      if Turns > 0 then
        WriteLn('    which is ', (Elapsed * 55000) div Turns,
                ' microseconds each');
    end;
  end else
    WriteLn('  command round trip     not measured (/C-)');

  WriteLn;
  if (PcRam > 0) and (CardRam > 0) then
    WriteLn('The card''s RAM reads at ', CardRam * 100 div PcRam,
            '% of the speed of the PC''s own.');
  WriteLn('The port and memory rows are ISA bus cycles that the Pico');
  WriteLn('answers in software, so they are the ceiling for anything');
  WriteLn('that treats the card as memory.  The command row is the');
  WriteLn('ceiling for anything that treats it as a device.');
  if Sum = $7FFFFFFF then WriteLn('(unreachable)');
end.
