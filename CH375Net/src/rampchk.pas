program RampChk;

{ RAMPCHK -- check a downloaded test file against the ramp it should be.

  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

      RAMPCHK file [/Q]
      RAMPCHK file /W=<bytes>      write a ramp instead of checking one

  The test server's sample files are a repeating 00..FF ramp, so the correct
  byte at any offset is simply (offset mod 256).  That makes a downloaded
  file self-describing in a way a checksum can never be: a CRC only ever
  says "no", whereas this says WHERE and, much more usefully, HOW.

  The distinction that matters is between bytes that were ALTERED and a
  stream that was SHIFTED.  If a receive path drops or duplicates bytes,
  everything after the seam still reads as a clean ramp -- just one that no
  longer lines up with its own address -- so every later byte mismatches by
  the SAME amount.  One enormous run with a constant delta therefore means
  "N bytes went missing here", and N is the delta.  Scattered short runs
  with varying deltas mean something is corrupting bytes in place.  Those
  two have completely different causes and a checksum cannot tell them
  apart.

  /W is what makes this able to accuse the DISK rather than the network.
  Write a ramp locally, read it back, and check it -- no packet driver, no
  adapter, no server anywhere in the path.  If a file that never crossed a
  wire comes back wrong, nothing about the network needed investigating.
  That test is worth running BEFORE any theory about receive, because it is
  the one that can rule out half the machine in a single pass.

  Exit codes, all well under the 20 the bridge can read back:
    0  the file is exactly the ramp
    1  altered bytes
    2  the stream is shifted -- bytes were dropped or duplicated
    3  could not read the file }

{$MODE OBJFPC}{$H-}

uses vidfix;   { see vidfix.pas: the runtime can hook INT 10h }


{ A live sign of life, and it has to go to STDERR to be one.

  A bridge job runs with stdout redirected into OUT.TXT, so anything written
  the ordinary way is invisible until the job ends -- which is exactly how a
  26-minute read came to be indistinguishable from a wedged machine while it
  was working perfectly.  COMMAND.COM 6.22 has no stderr redirection at all,
  so handle 2 reaches the console whatever the batch does with handle 1.
  That keeps the captured output clean AND puts a heartbeat on the screen.

  One character followed by a backspace, so it animates in place and scrolls
  nothing -- the same trick UGET uses in DOSBridge, and for the same reason:
  the screen is a status display, not a scrollback. }

const
  VER     = '1.0.0';
  SPINCH  = '|/-';
{ Tick EVERY block, and the reason is the whole point of having a spinner.

  This started at one tick per 256 KB, which on this machine is one move
  every EIGHTEEN SECONDS -- long enough that anybody watching concludes the
  thing is wedged, which is precisely the question the spinner exists to
  answer.  A heartbeat slower than the observer's patience is not a
  heartbeat.  At one tick per 8 KB block it moves about twice a second.

  The cost is one two-byte DOS write per 8 KB read: about 640 of them across
  a 5 MB file, against six minutes of disk, so well under a second in total
  and not measurable against the read it is reporting on. }
  BUFSZ   = 8192;
  MAXRUNS = 10;        { how many runs we keep detail on; all are counted }

{ How many matching bytes end a run.
  A run used to end at the FIRST byte that matched, which is right for a
  ramp and hopeless for the counter pattern: a small displacement only
  changes the low byte or two of each 32-bit word -- the high bytes are
  zero either way and match -- so one 162-byte fault was reported as 41
  separate single-byte runs, and the structure was lost completely.
  Tolerating a short gap coalesces those back into the one region they
  are, and leaves genuinely isolated damage still isolated. }
  GAPOK   = 8;

type
  TRun = record
    Start: LongInt;
    Last:  LongInt;      { offset of the last byte that actually differed }
    Len:   LongInt;
    Delta: Byte;
    Mixed: Boolean;    { the delta was NOT constant across this run }
    First: array[0..31] of Byte;
    NFirst: Byte;
    { Every DISTINCT displacement seen in this run, with how many bytes
      carried it.  The 32-byte window above only ever showed the start of
      a run, so the structure past it was being INFERRED -- and the whole
      argument about this fault rests on that structure being exactly
      "4 bytes at one displacement, the rest at another".  Counting the
      deltas measures it instead of assuming it. }
    NDelta: Byte;
    DVal:   array[0..5] of Byte;
    DCnt:   array[0..5] of LongInt;
  end;

var
  F:       file;
  WSize:   LongInt;
  Buf:     array[0..BUFSZ - 1] of Byte;
  Ref:     array[0..BUFSZ - 1] of Byte;   { what a clean block must contain }
  Runs:    array[0..MAXRUNS - 1] of TRun;
  Name:    ShortString;
  Quiet:   Boolean;
  Pos_:    LongInt;
  Bad:     LongInt;
  NRuns:   LongInt;
  Cur:     Integer;    { index into Runs, or -1 when past MAXRUNS }
  InRun:   Boolean;
  Gap:     Integer;    { matching bytes since the last difference }
  Got, I:  Integer;
  Expect, D: Byte;
  Blocks:  LongInt;
  Spin:    Byte;
  FastOK:  LongInt;   { blocks cleared by one compare instead of 8192 }
  Counter: Boolean;   { /K -- the 32-bit counter pattern, not the ramp }
  W0:      LongInt;
  { RefL MUST alias Ref, not sit beside it.  The counter reference is
    built as longwords and compared as bytes, and the first version
    declared two separate arrays -- so it filled one and compared the
    other, which would have reported every single block as corrupt. }
  RefL:    array[0..BUFSZ div 4 - 1] of LongInt absolute Ref;

{ What byte belongs at this offset?

  Two patterns, and the second exists because the first cannot answer the
  question this whole investigation turns on.  A ramp repeats every 256
  bytes, so a displacement is only ever knowable MODULO 256 -- the observed
  corruption reads as "-64, or -320, or -576" and nothing separates them.
  The 32-bit counter has a period of four gigabytes, so every displacement
  inside a 5 MB file is unique: decode the word sitting in the wrong place
  and its index IS the offset it came from. }
function Want(Ofs: LongInt): Byte;
var W: LongInt;
begin
  if not Counter then
    Want := Byte(Ofs and 255)
  else
  begin
    W := Ofs shr 2;
    case Byte(Ofs and 3) of
      0: Want := Byte(W and 255);
      1: Want := Byte((W shr 8) and 255);
      2: Want := Byte((W shr 16) and 255);
    else Want := Byte((W shr 24) and 255);
    end;
  end;
end;

{ One block, one move of the spinner. }
procedure Tick;
begin
  Inc(Blocks);
  Spin := (Spin + 1) and 3;
  Write(StdErr, SPINCH[Spin + 1], #8);
end;

{ Tally one displacement against the run's distinct-delta list. }
procedure NoteDelta(R: Integer; D: Byte);
var J: Integer;
begin
  for J := 0 to Runs[R].NDelta - 1 do
    if Runs[R].DVal[J] = D then
    begin
      Inc(Runs[R].DCnt[J]);
      Exit;
    end;
  if Runs[R].NDelta > 5 then Exit;          { more than six: say so below }
  Runs[R].DVal[Runs[R].NDelta] := D;
  Runs[R].DCnt[Runs[R].NDelta] := 1;
  Inc(Runs[R].NDelta);
end;

function Hex2(B: Byte): ShortString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4] + H[B and 15];
end;

procedure Usage;
begin
  WriteLn('RAMPCHK ', VER, ' -- is this file the 00..FF ramp it should be?', ' -- StevenC & Claude');
  WriteLn;
  WriteLn('  RAMPCHK file [/Q]');
  WriteLn('  RAMPCHK file /W=<bytes>   WRITE a ramp of that size');
  WriteLn('  RAMPCHK file /K           the 32-BIT COUNTER pattern, whose');
  WriteLn('                            4 GB period makes a displacement');
  WriteLn('                            exact instead of modulo 256');
  WriteLn;
  WriteLn('The test server serves files whose byte at offset N is N mod 256.');
  WriteLn('This reports not just THAT a download went wrong but HOW: bytes');
  WriteLn('altered in place look nothing like a stream that lost or gained');
  WriteLn('bytes and carried on, and only the second explains itself.');
  WriteLn;
  WriteLn;
  WriteLn('/W writes a ramp with no network in the path at all, so reading');
  WriteLn('it back accuses the disk directly and rules out half the machine.');
  WriteLn;
  WriteLn('  rc 0  exactly the ramp      rc 2  shifted: bytes dropped/dup''d');
  WriteLn('  rc 1  altered bytes         rc 3  cannot read it');
end;

procedure StartRun(At: LongInt; Delta: Byte);
begin
  Inc(NRuns);
  if NRuns <= MAXRUNS then
  begin
    Cur := NRuns - 1;
    Runs[Cur].Start  := At;
    Runs[Cur].Last   := At;
    Runs[Cur].Len    := 0;
    Runs[Cur].Delta  := Delta;
    Runs[Cur].Mixed  := False;
    Runs[Cur].NFirst := 0;
    Runs[Cur].NDelta := 0;
  end
  else
    Cur := -1;
end;

procedure Report;
var
  R: Integer;
  J: Integer;
  S: ShortString;
  Al: Byte;
  SrcW, SrcO, DstO: LongInt;
begin
  WriteLn;
  Write('  size        : ', Pos_, ' bytes');
  WriteLn;
  WriteLn('  mismatches  : ', Bad);
  WriteLn('  blocks fast : ', FastOK);
  WriteLn('  runs        : ', NRuns);
  if NRuns = 0 then Exit;

  WriteLn;
  R := 0;
  while (R < NRuns) and (R < MAXRUNS) do
  begin
    Write('  run ', R + 1, ': offset ', Runs[R].Start,
          '  len ', Runs[R].Last - Runs[R].Start + 1,
          '  delta +', Runs[R].Delta);
    if Runs[R].Mixed then Write('  (NOT constant)')
                     else Write('  (constant)');
    WriteLn;
    { Expected alongside got, because the SHAPE is the diagnosis.  Wrong
      bytes that are themselves a clean run of consecutive values are
      payload from somewhere else in the stream, not bit errors -- and the
      width of each such group says what granularity mangled it. }
    S := '';
    for J := 0 to Runs[R].NFirst - 1 do
      S := S + Hex2(Want(Runs[R].Start + J)) + ' ';
    if S <> '' then WriteLn('           want ', S);
    S := '';
    for J := 0 to Runs[R].NFirst - 1 do S := S + Hex2(Runs[R].First[J]) + ' ';
    if S <> '' then WriteLn('           got  ', S);
    { The payoff of the counter pattern: read the misplaced word and its
      index is the absolute offset the data actually came from, so the
      displacement is exact rather than a residue. }
    if Counter then
    begin
      Al := Byte((4 - (Runs[R].Start and 3)) and 3);
      { Several words, not one.  The observed fault is TWO pieces at
        different displacements -- four bytes from one place and the rest
        from another -- so decoding a single word would show half of it and
        read as the whole. }
      J := Al;
      while J + 4 <= Runs[R].NFirst do
      begin
        SrcW := LongInt(Runs[R].First[J])
              + LongInt(Runs[R].First[J + 1]) * 256
              + LongInt(Runs[R].First[J + 2]) * 65536
              + LongInt(Runs[R].First[J + 3]) * 16777216;
        SrcO := SrcW * 4;
        DstO := Runs[R].Start + J;
        WriteLn('           +', J, ' came from ', SrcO,
                '  displacement ', SrcO - DstO);
        Inc(J, 4);
      end;
    end;
    Write('           deltas');
    for J := 0 to Runs[R].NDelta - 1 do
      Write(' +', Runs[R].DVal[J], ' x', Runs[R].DCnt[J]);
    if Runs[R].NDelta > 5 then Write(' ...and more');
    WriteLn;
    Inc(R);
  end;
  if NRuns > MAXRUNS then
    WriteLn('  ... and ', NRuns - MAXRUNS, ' more run(s), not detailed');
end;

var
  Rc: Integer;
  Tail: LongInt;
  S: ShortString;
  J: Integer;

begin
  Quiet := False;
  Counter := False;
  WSize := 0;
  Name := '';
  for I := 1 to ParamCount do
  begin
    if (ParamStr(I)[1] = '/') or (ParamStr(I)[1] = '-') then
    begin
      if UpCase(ParamStr(I)[2]) = 'K' then Counter := True
      else if UpCase(ParamStr(I)[2]) = 'Q' then Quiet := True
      else if UpCase(ParamStr(I)[2]) = 'W' then
      begin
        S := ParamStr(I);
        J := 3;
        if (Length(S) >= 3) and (S[3] = '=') then J := 4;
        WSize := 0;
        while (J <= Length(S)) and (S[J] >= '0') and (S[J] <= '9') do
        begin
          WSize := WSize * 10 + (Ord(S[J]) - 48);
          Inc(J);
        end;
        if WSize <= 0 then begin Usage; Halt(3); end;
      end
      else begin Usage; Halt(3); end;
    end
    else
      Name := ParamStr(I);
  end;

  if Name = '' then begin Usage; Halt(3); end;

  if WSize > 0 then
  begin
    WriteLn('=== RAMPCHK ', VER, ' -- writing ', WSize, ' bytes to ', Name, ' ===');
    Assign(F, Name);
    {$I-} Rewrite(F, 1); {$I+}
    if IOResult <> 0 then
    begin
      WriteLn('RAMPCHK: cannot create ', Name);
      Halt(3);
    end;
    Pos_   := 0;
    Blocks := 0;
    Spin   := 0;
    while Pos_ < WSize do
    begin
      Got := BUFSZ;
      if WSize - Pos_ < Got then Got := WSize - Pos_;
      for I := 0 to Got - 1 do Buf[I] := Want(Pos_ + I);
      {$I-} BlockWrite(F, Buf, Got); {$I+}
      if IOResult <> 0 then
      begin
        WriteLn('RAMPCHK: write failed at ', Pos_);
        Close(F);
        Halt(3);
      end;
      Inc(Pos_, Got);
      Tick;
    end;
    {$I-} Close(F); {$I+}
    if IOResult <> 0 then
    begin
      WriteLn('RAMPCHK: close failed -- the file may be short');
      Halt(3);
    end;
    WriteLn('  written.  Now read it back with RAMPCHK ', Name);
    Halt(0);
  end;

  Assign(F, Name);
  {$I-} Reset(F, 1); {$I+}
  if IOResult <> 0 then
  begin
    WriteLn('RAMPCHK: cannot open ', Name);
    Halt(3);
  end;

  if not Quiet then
    WriteLn('=== RAMPCHK ', VER, ' -- ', Name, ' ===');

  Pos_   := 0;
  Bad    := 0;
  Blocks := 0;
  Spin   := 0;
  FastOK := 0;
  NRuns := 0;
  if not Counter then
    for I := 0 to BUFSZ - 1 do Ref[I] := Byte(I and 255);
  Cur   := -1;
  InRun := False;

  { The whole-block shortcut, and it is worth 15x on this machine.
    Checking a byte at a time is a Pascal loop over five million
    iterations, which is CPU-bound at around 340 seconds for 5 MB -- far
    longer than reading the file. But BUFSZ is a multiple of the ramp's
    256-byte period and every block starts at a multiple of BUFSZ, so
    EVERY block's expected contents are the same 8192 bytes. Build that
    once and a clean block costs one CompareByte instead of 8192 tests.
    Only blocks that fail it pay for the per-byte walk that locates the
    runs, and on a healthy file that is none of them. }
  repeat
    {$I-} BlockRead(F, Buf, BUFSZ, Got); {$I+}
    if IOResult <> 0 then
    begin
      WriteLn('RAMPCHK: read failed at ', Pos_);
      Close(F);
      Halt(3);
    end;
    if Counter then
    begin
      { The counter reference depends on WHERE the block is, so it has to
        be rebuilt per block -- 2048 longword stores against 8192 byte
        comparisons, so the shortcut still pays, just less. }
      W0 := Pos_ shr 2;
      for I := 0 to (BUFSZ div 4) - 1 do RefL[I] := W0 + I;
    end;
    if (Got > 0) and (CompareByte(Buf, Ref, Got) = 0) then
    begin
      { Clean, so any run open at the end of the last block ends here. }
      InRun := False;
      Inc(Pos_, Got);
      Inc(FastOK);
      Tick;
      if Got < BUFSZ then Break;
      Continue;
    end;
    for I := 0 to Got - 1 do
    begin
      Expect := Want(Pos_);
      if Buf[I] <> Expect then
      begin
        D := Byte(Buf[I] - Expect);
        Inc(Bad);
        if not InRun then
        begin
          InRun := True;
          Gap := 0;
          StartRun(Pos_, D);
        end;
        Gap := 0;
        if Cur >= 0 then
        begin
          Runs[Cur].Last := Pos_;
          if Runs[Cur].Delta <> D then Runs[Cur].Mixed := True;
          NoteDelta(Cur, D);
        end;
      end
      else if InRun then
      begin
        Inc(Gap);
        if Gap > GAPOK then InRun := False;
      end;

      { The window is CONTIGUOUS from the run's start, matching bytes
        included.  Capturing only the differing ones was fine for a ramp
        and useless for the counter pattern, where the decode needs four
        bytes in a row to read a word out of -- and with only mismatches
        kept it never had them. }
      if InRun and (Cur >= 0) and (Runs[Cur].NFirst < 32)
         and (Pos_ - Runs[Cur].Start < 32) then
      begin
        Runs[Cur].First[Runs[Cur].NFirst] := Buf[I];
        Inc(Runs[Cur].NFirst);
      end;
      Inc(Pos_);
    end;
    Tick;
  until Got < BUFSZ;
  Close(F);
  Write(StdErr, ' ', #8);            { leave the cell clean }

  Report;

  { A shift announces itself: ONE run, constant delta, running to the end of
    the file.  Nothing else looks like that, because a ramp that has lost N
    bytes still reads as a perfect ramp -- just N out of step with its own
    address, for every byte that follows. }
  WriteLn;
  if Bad = 0 then
  begin
    if Counter then
      WriteLn('  VERDICT: exactly the counter.  Every word is its own index.')
    else
      WriteLn('  VERDICT: exactly the ramp.  Every byte is offset mod 256.');
    Rc := 0;
  end
  else
  begin
    { Tolerant of the run ending a little short of EOF.  A real shift can
      resynchronise by luck in its last few bytes -- the ramp repeats every
      256, so a tail that happens to line up ends the run early without
      making the diagnosis any less true. }
    Tail := Runs[0].Last + 1;
    if (NRuns = 1) and (not Runs[0].Mixed) and (Tail >= Pos_ - 512) then
    begin
      WriteLn('  VERDICT: SHIFTED, not altered.  From offset ', Runs[0].Start,
              ' every');
      WriteLn('  byte is a clean ramp reading ', Runs[0].Delta,
              ' ahead of where it belongs, so');
      WriteLn('  ', Runs[0].Delta, ' byte(s) were DROPPED there (or ',
              256 - Runs[0].Delta, ' duplicated).');
      WriteLn('  Look at framing and burst boundaries, not at bit errors.');
      Rc := 2;
    end
    else
    begin
      WriteLn('  VERDICT: ', Bad, ' altered byte(s) in ', NRuns, ' run(s).');
      WriteLn('  The stream stayed in step, so this is corruption in place');
      WriteLn('  rather than a framing fault.  A run whose delta is NOT');
      WriteLn('  constant is real corruption; a short constant-delta run is');
      WriteLn('  a seam that resynchronised.');
      Rc := 1;
    end;
  end;
  Halt(Rc);
end.
