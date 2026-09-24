program combotst;
{ Conformance and diagnostic suite for USBCOMBO.COM  --  CH375Combo, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  USBCOMBO has three things that can fail independently: the USB half, the
  keyboard delivery path, and the INT 33h mouse interface.  The driver's own
  /T covers the second and the arithmetic of the third without any hardware
  attached.  This covers the parts /T cannot reach -- the INT 33h API as an
  application actually calls it, and what the device is really putting on
  the wire.

  Run it with the driver already loaded:

      USBCOMBO
      COMBOTST
      USBCOMBO /U

      COMBOTST /W        watch raw packets instead of running the checks
      COMBOTST /W=20     ...for 20 seconds
      COMBOTST /BEEP     play every cue and exit, to check you can hear them
      COMBOTST /KB=20    watch the KEYBOARD reports only, for 20 seconds.
                         The mouse produces far more traffic than the
                         keyboard, so with both traced the key reports
                         scroll away before they can be read -- which is
                         exactly what happened the first time a dropped
                         character needed attributing.

  THE POINT OF /W.  This adapter answers SET_PROTOCOL 0 with success and
  then sends its native report-ID format anyway, so the driver decides the
  format from the packet rather than from the request.  /W prints both the
  bytes as they arrived and the boot-shaped report the driver made of them.

  It also beeps.  The one thing no automated check can do is move the
  mouse, so /W asks a human to: two rising notes mean start moving and
  clicking, two falling notes mean stop.  Three high notes mean packets
  arrived and the driver threw them all away.

  That last case is not hypothetical.  An earlier build decided a 5-byte
  packet could not be real, on the grounds that the device had agreed to a
  3-byte boot protocol -- and it rejected 100% of real mouse data while
  every injected-report check still passed.  What caught it was moving the
  mouse and watching this output.

  Exit code is the number of failed checks, capped at 20.                }

{$MODE OBJFPC}{$H-}

uses Dos, ch375, chtool;
                   { ch375 gives InB/OutB/Ticks/KeyWaiting, chtool the
                     banner and /? every tool here shares -- and NOT crt,
                     which would paint the screen and print nothing }

const
  VER   = '1.0.0';
  SIG   = 'USBCMB01';
  { offsets inside the resident image -- see the pointer block in the .asm }
  O_SIG = $0103;
  O_VER = $010B;
  O_PTR = $0111;
  { Indices into that block, in words.  Counted off the dw list in the .asm
    rather than guessed: 0..5 are the six translation tables, and getting
    this wrong reads a neighbouring variable and reports it confidently,
    which is exactly what the first version of this program did. }
  P_NREPORTS = 6;
  P_NKEYS    = 7;
  P_NFULL    = 8;
  P_LIVE     = 9;
  P_LOCKS    = 10;
  P_EPIN     = 11;
  P_TICKN    = 12;
  P_NPOLLS   = 13;
  P_OLD33    = 17;
  P_MEPIN    = 18;
  P_MLIVE    = 19;
  P_MREPORTS = 20;
  P_CURX     = 21;
  P_CURY     = 22;
  P_BUTTONS  = 23;
  P_MOUID    = 24;
  P_HAS33    = 25;
  P_MWIRE    = 26;
  P_MREPLEN  = 27;
  P_NTMO     = 28;
  P_MTMO     = 29;
  P_NFLUSH   = 30;
  P_NREPLEN  = 31;
  P_MOUBOOT  = 32;
  P_MBOGUS   = 33;
  P_REPBUF   = 34;
  P_MIGNORED = 35;
  P_MSHORT   = 36;
  P_PS2ON    = 37;
  P_GAIN     = 38;

var
  Fails, Checks: Integer;
  ResSeg: Word;
  WasQuiet, SavedGain: Word;

{ ------------------------------------------------------------------ helpers }

{ PC speaker: PIT channel 2 in square-wave mode, gated onto port 61h bits 0
  and 1.  Channel 0 is the one the driver divides by eight to poll the
  device and is a different counter entirely -- nothing here touches it.

  This exists because the one thing the automated tests cannot do is move
  the mouse, so a human has to be told when to start and when to stop.  A
  line of text on a screen nobody is looking at does not do that. }
procedure Wait(Ms: Word);
var
  T0: LongInt;
begin
  T0 := Ticks;
  while Ticks - T0 < (LongInt(Ms) * 9 + 250) div 500 do ;
end;

procedure Tone(Freq, Ms: Word);
var
  D: Word;
  Old: Byte;
begin
  if Freq = 0 then begin Wait(Ms); Exit; end;
  D := Word(1193182 div LongInt(Freq));
  OutB($43, $B6);
  OutB($42, Lo(D));
  OutB($42, Hi(D));
  Old := InB($61);
  OutB($61, Old or 3);
  Wait(Ms);
  OutB($61, Old and $FC);
end;

{ These are deliberately long and repeated.  A short pair of notes from a
  PC speaker across a room is easy to miss entirely, and a cue that gets
  missed is worse than none -- the run is wasted and the result looks like
  a hardware fault rather than an absent human. }

{ GO: a rising three-note figure, twice.  "Start moving the mouse." }
procedure BeepGo;
var I: Integer;
begin
  for I := 1 to 2 do
  begin
    Tone(600, 180); Tone(900, 180); Tone(1300, 260);
    Wait(180);
  end;
end;

{ DONE: the same figure falling, twice.  "Hands off." }
procedure BeepDone;
var I: Integer;
begin
  for I := 1 to 2 do
  begin
    Tone(1300, 180); Tone(900, 180); Tone(600, 260);
    Wait(180);
  end;
end;

{ FAIL: four hard high notes.  Packets arrived and were all thrown away. }
procedure BeepFail;
var I: Integer;
begin
  for I := 1 to 4 do begin Tone(1500, 130); Wait(70); end;
end;

{ A tick each time a report is used, so movement is audible as it happens
  and you can tell a dead endpoint from a still mouse without reading the
  screen.  Kept very short -- this runs inside the watch loop. }
procedure BeepTick;
begin
  Tone(2200, 25);
end;

{ ALWAYS zero the record before Intr.

  FPC's Intr loads every field of Registers into the CPU, Flags included.
  Setting only R.AH and calling it hands the interrupt whatever happened to
  be on the stack for the rest -- and if the garbage in Flags has IF clear,
  interrupts come back off, the BIOS tick at 40:6C stops advancing, and any
  loop waiting on Ticks runs forever.  That is not hypothetical: it is what
  hung the machine the first time this program watched both endpoints. }
procedure M(var R: Registers);
begin
  Intr($33, R);
end;

{ INT 16h through a fully-initialised record.  Returns False if no key is
  waiting; otherwise takes one and returns it in Scan/Ascii. }
function TakeKey(var Scan, Ascii: Byte): Boolean;
var
  R: Registers;
begin
  TakeKey := False;
  if not KeyWaiting then Exit;
  FillChar(R, SizeOf(R), 0);
  R.AH := 0;
  Intr($16, R);
  Scan  := Hi(R.AX);
  Ascii := Lo(R.AX);
  TakeKey := True;
end;

procedure Check(const What: ShortString; Ok: Boolean);
begin
  Inc(Checks);
  if Ok then WriteLn('  ok    ', What)
  else begin WriteLn('  FAIL  ', What); Inc(Fails); end;
end;

procedure CheckEq(const What: ShortString; Got, Want: LongInt);
begin
  Inc(Checks);
  if Got = Want then WriteLn('  ok    ', What, ' = ', Got)
  else
  begin
    WriteLn('  FAIL  ', What, ' = ', Got, ', expected ', Want);
    Inc(Fails);
  end;
end;

{ A word out of the resident copy, by its index in the published pointer
  block.  Reading through the block rather than through hard-coded data
  addresses is the whole reason the block exists: the data can move between
  builds and this still reads the right thing, or fails loudly. }
function ResWord(Idx: Integer): Word;
var
  P: Word;
begin
  P := MemW[ResSeg : O_PTR + Idx * 2];
  ResWord := MemW[ResSeg : P];
end;

function ResByte(Idx: Integer): Byte;
var
  P: Word;
begin
  P := MemW[ResSeg : O_PTR + Idx * 2];
  ResByte := Mem[ResSeg : P];
end;

{ The only thing this program WRITES into the resident copy.  The checks
  below inject an exact report and read the scaled result back, and the
  driver's speed multiplier -- 16 by default, because the hardware needs it
  -- would multiply every expected value by 16.  Setting it to 1 for the
  arithmetic and restoring it afterwards keeps the checks testing the
  scaling itself rather than the setting. }
procedure SetResWord(Idx: Integer; V: Word);
var
  P: Word;
begin
  P := MemW[ResSeg : O_PTR + Idx * 2];
  MemW[ResSeg : P] := V;
end;

function ResBufByte(Idx, Ofs: Integer): Byte;
var
  P: Word;
begin
  P := MemW[ResSeg : O_PTR + Idx * 2];
  ResBufByte := Mem[ResSeg : P + Ofs];
end;

{ Find the driver by following INT 33h and looking for the signature.  The
  keyboard half hooks INT 08h and the mouse half INT 33h, and only one of
  them is a vector a program may safely follow -- walking the INT 08h chain
  means calling into whatever else is on it. }
var
  Int33Seg, Int33Off: Word;

function FindResident: Boolean;
var
  R: Registers;
  I: Integer;
  S: ShortString;
begin
  FindResident := False;
  R.AX := $3533;
  Intr($21, R);
  ResSeg := R.ES;
  Int33Seg := R.ES;
  Int33Off := R.BX;
  if ResSeg = 0 then Exit;
  S := '';
  for I := 0 to 7 do S := S + Chr(Mem[ResSeg : O_SIG + I]);
  FindResident := (S = SIG);
end;

function ResVersion: ShortString;
var
  I: Integer;
  C: Char;
begin
  ResVersion := '';
  for I := 0 to 15 do
  begin
    C := Chr(Mem[ResSeg : O_VER + I]);
    if C = '$' then Exit;
    ResVersion := ResVersion + C;
  end;
end;

{ ---------------------------------------------------- the private functions }

{ 7F02h: stop or restart the driver's own polling, returning the previous
  setting.  The deterministic checks need it -- they inject an exact report
  and read the state straight back, and a real mouse moving underneath makes
  that a race.  On this adapter it is not a theoretical race: the thing
  reports hundreds of times a second. }
function SetQuiet(Q: Word): Word;
var
  R: Registers;
begin
  R.AX := $7F02; R.BX := Q;
  M(R);
  SetQuiet := R.BX;
end;

procedure Inject(Btn, Dx, Dy: Byte);
var
  R: Registers;
begin
  R.AX := $7F01;
  R.BX := Btn;
  R.CX := Dx or (Word(Dy) shl 8);
  M(R);
end;

procedure GetPos(var X, Y, B: Word);
var
  R: Registers;
begin
  R.AX := 3;
  M(R);
  X := R.CX; Y := R.DX; B := R.BX;
end;

{ ---------------------------------------------------------------- /W watch }

{ A live view of BOTH endpoints at once.

  Two things went wrong with the first version of this and both are worth
  not repeating.  It broke out of the loop on ANY pending key -- and with a
  working keyboard half there is always a pending key, so it exited on its
  first iteration and reported "0 changes" as though the mouse were silent.
  And it watched only the mouse, which is half the question.

  So: drain the BIOS buffer first, leave only ESC as the way out, and show
  what both endpoints are sending.                                        }
procedure Watch(Secs: Word; KbdOnly: Boolean);
var
  R: Registers;
  T0: LongInt;
  LastW, W: ShortString;
  N, Drained: LongInt;
  Len: Byte;
  Keys0, Reps0, Bog0, KReps0: Word;
  Spins: LongInt;
  NKeys: Integer;
  Scan, Ascii, WireId: Byte;
  Typed: ShortString;
  UsedNow, UsedLast, Ign0, Sho0: Word;
  DUsed, DBog, DIgn, DSho: Word;
  K, LastK: ShortString;
  NK, Drain: LongInt;
  Bail: Boolean;
  Full0, Keys0d: Word;

  function KbdReport: ShortString;
  var
    J: Integer;
    T: ShortString;
  begin
    T := '';
    for J := 0 to 7 do T := T + Hex2(ResBufByte(P_REPBUF, J)) + ' ';
    KbdReport := T;
  end;

begin
  { Anything already in the BIOS buffer is a key the driver delivered before
    we started.  Take them out, or the ESC test below fires immediately. }
  Drained := 0;
  while KeyWaiting and (Drained < 64) do begin EatKey; Inc(Drained); end;

  Keys0  := ResWord(P_NKEYS);
  KReps0 := ResWord(P_NREPORTS);
  Reps0  := ResWord(P_MREPORTS);
  Bog0   := ResWord(P_MBOGUS);

  WriteLn;
  WriteLn('Watching BOTH endpoints for ', Secs, ' seconds.  ',
          Drained, ' stale keys drained.');
  WriteLn;
  WriteLn('  MOVE THE MOUSE.  Then type a few letters.  ESC stops early.');
  WriteLn;
  WriteLn('"wire" is the mouse packet as it arrived; "boot" is what the');
  WriteLn('driver made of it.  A 3-byte packet is a real boot report and is');
  WriteLn('used; a 5-byte one is the chip inventing data and is thrown away.');
  WriteLn;
  WriteLn('M = a mouse packet.  K = a KEYBOARD report, as the device');
  WriteLn('sent it: modifier byte then the six key slots, in the order');
  WriteLn('the device listed them.  Two usages appearing together in one');
  WriteLn('K line is the case that cannot be ordered -- if the delivered');
  WriteLn('text has them swapped, that is why, and it is not fixable.');
  WriteLn;
  BeepGo;                              { two rising notes: your turn }
  { Seed this from the packet ALREADY sitting in the buffer.  Starting it
    empty made the first read differ by definition, so a leftover packet
    from an earlier run counted as new traffic -- and with the mouse
    untouched that produced "packets arrived and none was used", complete
    with the failure beep, when in fact nothing had arrived at all. }
  R.AX := $7F04; M(R);
  LastW := Hex2(Lo(R.BX)) + ' ' + Hex2(Hi(R.BX)) + ' ' +
           Hex2(Lo(R.CX)) + ' ' + Hex2(Hi(R.CX)) + ' ' + Hex2(Lo(R.DX));
  LastK := KbdReport;
  N := 0; NK := 0; NKeys := 0; Typed := ''; Bail := False;
  Full0 := ResWord(P_NFULL);
  Keys0d := ResWord(P_NKEYS);
  UsedLast := ResWord(P_MREPORTS);
  Ign0 := ResWord(P_MIGNORED);
  Sho0 := ResWord(P_MSHORT);
  T0 := Ticks;
  { TWO limits, and the second is not belt-and-braces.  The clock limit is
    the one that matters normally; the iteration limit is what saves the
    machine if the BIOS tick ever stops advancing, because then the clock
    test can never fire and the only way out is a power cycle. }
  Spins := 0;
  while True do
  begin
    if Ticks - T0 > LongInt(Secs) * 18 then Break;
    Inc(Spins);
    if Spins > 2000000 then
    begin
      WriteLn('  (iteration limit hit -- the BIOS tick is not advancing)');
      Break;
    end;

    { Keys are TAKEN, not peeked at -- peeking needs INT 16h AH=1 and there
      is no safe way to ask that without a full record, which is what hung
      this program once already.  ESC stops the watch; everything else is
      remembered so the keyboard half can be reported at the end. }
    { Drain up to 16 keys per pass, not one.  The BIOS ring holds 15 words
      and this loop is slow while the mouse is streaming, so taking a single
      key per iteration let the driver fill the buffer faster than the
      harness emptied it -- and keys lost at the BUFFER look exactly like
      keys the driver never saw.  n_full below says which it was. }
    Drain := 0;
    while TakeKey(Scan, Ascii) and (Drain < 16) do
    begin
      Inc(Drain);
      if Ascii = 27 then begin Bail := True; Break; end;
      if NKeys < 60 then
      begin
        if (Ascii >= 32) and (Ascii < 127) then Typed := Typed + Chr(Ascii)
        else Typed := Typed + '<' + Hex2(Scan) + '>';
      end;
      Inc(NKeys);
    end;
    if Bail then Break;

    R.AX := $7F04;
    M(R);
    Len := Hi(R.DX);
    W := Hex2(Lo(R.BX)) + ' ' + Hex2(Hi(R.BX)) + ' ' +
         Hex2(Lo(R.CX)) + ' ' + Hex2(Hi(R.CX)) + ' ' + Hex2(Lo(R.DX));

    { One short tick per report the driver actually used.  Silence while
      you are moving the mouse means the mouse half is not working, and
      that is worth hearing rather than reading afterwards. }
    UsedNow := ResWord(P_MREPORTS);
    if UsedNow <> UsedLast then
    begin
      if (UsedNow - UsedLast) > 0 then BeepTick;
      UsedLast := UsedNow;
    end;

    { The keyboard's own report stream.  Without this there is no way to
      tell a transposition the DRIVER caused from one the typist or the
      adapter caused -- "hg" for "gh" reads identically either way. }
      K := KbdReport;
      if K <> LastK then
      begin
        WriteLn('  K  ', K);
        LastK := K;
        Inc(NK);
        if KbdOnly and (NK > 140) then Break;
      end;

    if (W <> LastW) and (Len > 0) and not KbdOnly then
    begin
      Write('  M  ', W, '  ');
      WireId := Lo(R.BX);              { before 7F03h overwrites R }
      R.AX := $7F03; M(R);
      Write(Hex2(Lo(R.BX)), ' ', Hex2(Hi(R.BX)), ' ', Hex2(Lo(R.CX)), '  ');
      Write(Len:3, '  ');
      { What the driver actually did with it, which is not a function of
        length alone.  A 5-byte packet led by 01 is report 1, the pointer,
        and its ID is stripped; led by 02 or 03 it is system control or
        consumer keys and is dropped.  3 or 4 bytes is a boot report. }
      if Len >= 5 then
      begin
        if WireId = 1 then WriteLn('used (ID stripped)')
        else WriteLn('dropped (not the pointer)');
      end
      else if Len >= 3 then WriteLn('used (boot report)')
      else WriteLn('too short');
      LastW := W;
      Inc(N);
      if (N + NK) > 150 then
      begin
        WriteLn('  ... 150 lines, that is enough to see the shape');
        Break;
      end;
    end;
  end;

  { Drain whatever is still queued.  The loop above exits on the clock, and
    anything the driver delivered in the last moments is still sitting in
    the BIOS ring -- counting that as lost made the driver look like it had
    dropped characters it had in fact handed over correctly. }
  while TakeKey(Scan, Ascii) and (NKeys < 200) do
  begin
    if NKeys < 60 then
    begin
      if (Ascii >= 32) and (Ascii < 127) then Typed := Typed + Chr(Ascii)
      else Typed := Typed + '<' + Hex2(Scan) + '>';
    end;
    Inc(NKeys);
  end;

  BeepDone;                            { two falling notes: hands off }
  WriteLn;
  WriteLn('--- mouse half ---');
  WriteLn('  distinct packets seen : ', N);
  WriteLn('  reports USED          : ', ResWord(P_MREPORTS) - Reps0);
  WriteLn('  packets REJECTED      : ', ResWord(P_MBOGUS) - Bog0);
  WriteLn('  pointer now           : x=', ResWord(P_CURX),
          ' y=', ResWord(P_CURY), ' buttons=', ResWord(P_BUTTONS));
  WriteLn;
  WriteLn('--- keyboard half ---');
  WriteLn('  distinct reports seen : ', NK);
  WriteLn('  reports               : ', ResWord(P_NREPORTS) - KReps0);
  WriteLn('  keys delivered        : ', ResWord(P_NKEYS) - Keys0);
  WriteLn('  last report bytes     : ', KbdReport);
  WriteLn('  keys that reached INT 16h : ', NKeys);
  WriteLn('  dropped, BIOS buffer full : ', ResWord(P_NFULL) - Full0);
  WriteLn('  what they were            : ', Typed);
  if (ResWord(P_NKEYS) - Keys0d) <> Word(NKeys) then
  begin
    WriteLn;
    WriteLn('  NOTE: the driver delivered ', ResWord(P_NKEYS) - Keys0d,
            ' keys and this program read ', NKeys, '.');
    WriteLn('  The difference was lost between the two, not by the driver:');
    WriteLn('  either the BIOS ring overflowed (see the count above) or');
    WriteLn('  this loop was too slow to keep up.  Do not read a missing');
    WriteLn('  character here as the driver dropping it.');
  end;
  WriteLn;
  { The verdict comes from the driver's counters, never from how many lines
    got printed.  The line count says how often the wire buffer changed,
    which is not the same as how many packets the driver accounted for. }
  DUsed := ResWord(P_MREPORTS)  - Reps0;
  DBog  := ResWord(P_MBOGUS)    - Bog0;
  DIgn  := ResWord(P_MIGNORED)  - Ign0;
  DSho  := ResWord(P_MSHORT)    - Sho0;
  WriteLn('  dropped: not-pointer ', DIgn, ', too short ', DSho,
          ', unusable ', DBog);
  WriteLn;

  if DUsed > 0 then
    WriteLn('VERDICT: mouse reports got through and moved the pointer.')
  else if (DBog + DIgn + DSho) > 0 then
  begin
    WriteLn('VERDICT: packets arrived and NONE was used.  Look at the len');
    WriteLn('column and the dropped counts above.');
    BeepFail;
  end
  else
  begin
    WriteLn('VERDICT: nothing arrived on the mouse endpoint at all, which');
    WriteLn('is correct if you did not touch it -- SET_IDLE 0 means the');
    WriteLn('device reports only when something changes.');
  end;
end;

{ The BIOS keyboard data area, which is shared state between this driver,
  the machine's own keyboard and DOS.  A driver that leaves a modifier bit
  set here makes every later keystroke a control sequence, and the machine
  looks like it has lost its keyboard entirely -- there is history of
  exactly that in CH375Keyboard.  Dumping it before and after a run is how
  that gets caught instead of guessed at. }
procedure DumpBios;
begin
  WriteLn('BIOS keyboard area:');
  WriteLn('  40:17 shift flags   = ', Hex2(Mem[$40:$17]),
          '   (bit0 Rshift 1 Lshift 2 Ctrl 3 Alt,');
  WriteLn('                          4 Scroll 5 Num 6 Caps 7 Ins)');
  WriteLn('  40:18 flags2        = ', Hex2(Mem[$40:$18]));
  WriteLn('  40:96 flags3        = ', Hex2(Mem[$40:$96]));
  WriteLn('  40:97 LED shadow    = ', Hex2(Mem[$40:$97]));
  WriteLn('  40:1A head          = ', Hex4(MemW[$40:$1A]),
          '   40:1C tail = ', Hex4(MemW[$40:$1C]));
end;

{ ------------------------------------------------------------------- checks }

procedure ReportResident;
begin
  WriteLn('--- the resident copy ---');
  WriteLn('  version              : ', ResVersion);
  WriteLn('  segment              : ', Hex4(ResSeg));
  WriteLn;
  WriteLn('  keyboard half  live  : ', ResByte(P_LIVE));
  WriteLn('                 ep    : ', ResByte(P_EPIN));
  WriteLn('                 polls : ', ResWord(P_NPOLLS));
  WriteLn('                 reps  : ', ResWord(P_NREPORTS));
  WriteLn('                 keys  : ', ResWord(P_NKEYS));
  WriteLn;
  WriteLn('  mouse half     live  : ', ResByte(P_MLIVE));
  WriteLn('                 ep    : ', ResByte(P_MEPIN));
  WriteLn('                 reps  : ', ResWord(P_MREPORTS));
  WriteLn('                 int33 : ', ResByte(P_HAS33));
  WriteLn('                 boot? : ', ResByte(P_MOUBOOT));
  WriteLn('                 rep ID: ', ResByte(P_MOUID));
  WriteLn('                 length: ', ResByte(P_MREPLEN));
  WriteLn('                 bogus : ', ResWord(P_MBOGUS));
  WriteLn('                 speed : ', ResWord(P_GAIN), ' (/G)');
  WriteLn('                 PS/2  : ', ResByte(P_PS2ON), ' (/W, for Windows)');
  WriteLn;
  WriteLn('  timeouts kbd/mouse   : ', ResWord(P_NTMO), ' / ', ResWord(P_MTMO));
  WriteLn('  stale ints flushed   : ', ResWord(P_NFLUSH));
  WriteLn;
end;

procedure CheckApi;
var
  R: Registers;
  X, Y, B: Word;
begin
  WriteLn('--- INT 33h, as an application calls it ---');

  R.AX := $24; M(R);
  CheckEq('24h reports API level 7.00', R.BX, $0700);
  CheckEq('24h says "other bus", no IRQ', R.CX, $0400);

  R.AX := 0; M(R);
  CheckEq('00h reset says a driver is present', R.AX, $FFFF);
  CheckEq('00h reports three buttons', R.BX, 3);

  { after a reset the pointer is centred on the default 640x200 range }
  GetPos(X, Y, B);
  CheckEq('03h x after reset', X, 320);
  CheckEq('03h y after reset', Y, 100);
  CheckEq('03h buttons after reset', B, 0);

  { ranges, then a set-position that has to be clamped into them }
  R.AX := 7; R.CX := 100; R.DX := 200; M(R);
  R.AX := 8; R.CX := 50;  R.DX := 150; M(R);
  R.AX := 4; R.CX := 0;   R.DX := 0;   M(R);
  GetPos(X, Y, B);
  CheckEq('04h below the x range clamps up', X, 100);
  CheckEq('04h below the y range clamps up', Y, 50);
  R.AX := 4; R.CX := 9999; R.DX := 9999; M(R);
  GetPos(X, Y, B);
  CheckEq('04h above the x range clamps down', X, 200);
  CheckEq('04h above the y range clamps down', Y, 150);

  { 07h/08h given backwards must still be taken as a range }
  R.AX := 7; R.CX := 400; R.DX := 300; M(R);
  R.AX := 4; R.CX := 0; R.DX := 0; M(R);
  GetPos(X, Y, B);
  CheckEq('07h swaps a reversed x range', X, 300);

  { sensitivity round-trip }
  R.AX := $1A; R.BX := 16; R.CX := 32; R.DX := 0; M(R);
  R.AX := $1B; M(R);
  CheckEq('1Ah/1Bh x sensitivity round-trips', R.BX, 16);
  CheckEq('1Ah/1Bh y sensitivity round-trips', R.CX, 32);

  { 0Fh is the same two numbers by another name }
  R.AX := $0F; R.CX := 8; R.DX := 16; M(R);
  R.AX := $1B; M(R);
  CheckEq('0Fh sets the same x mickey rate', R.BX, 8);
  CheckEq('0Fh sets the same y mickey rate', R.CX, 16);

  { 15h must report a state buffer big enough to be real }
  R.AX := $15; M(R);
  Check('15h state buffer size is plausible',
        (R.BX >= 32) and (R.BX <= 512));

  { 23h has no language table }
  R.AX := $23; M(R);
  CheckEq('23h reports English', R.BX, 0);
  WriteLn;
end;

procedure CheckInject;
var
  R: Registers;
  X, Y, B: Word;
  I: Integer;
begin
  WriteLn('--- fabricated reports through the real report path ---');

  { back to a known state: full range, default sensitivity, centred }
  R.AX := 0; M(R);

  { Function 00h does NOT clear the per-button press and release counters --
    only reading them through 05h and 06h does, and they have been banking
    real clicks from the physical mouse all along.  Drain all six before
    injecting anything, or the first check reads its own injected press plus
    however many times somebody clicked earlier and reports 2. }
  for I := 0 to 2 do
  begin
    R.AX := 5; R.BX := I; M(R);
    R.AX := 6; R.BX := I; M(R);
  end;

  Inject(0, 8, 8);
  GetPos(X, Y, B);
  CheckEq('+8 mickeys of x moves 8 units', X, 328);
  CheckEq('+8 mickeys of y moves 4 units', Y, 104);

  Inject(0, 248, 0);            { -8 as a signed byte }
  GetPos(X, Y, B);
  CheckEq('-8 mickeys of x moves back', X, 320);

  { slow movement must not be lost to truncation: eight single mickeys of
    y at 16 per 8 units is four units, and a driver that divides each one
    on its own gets nothing at all }
  R.AX := 4; R.CX := 320; R.DX := 100; M(R);
  Inject(0, 0, 1); Inject(0, 0, 1); Inject(0, 0, 1); Inject(0, 0, 1);
  Inject(0, 0, 1); Inject(0, 0, 1); Inject(0, 0, 1); Inject(0, 0, 1);
  GetPos(X, Y, B);
  CheckEq('eight single mickeys still move y', Y, 104);

  { buttons and their edges }
  Inject(1, 0, 0);
  GetPos(X, Y, B);
  CheckEq('a left press shows in 03h', B, 1);
  R.AX := 5; R.BX := 0; M(R);
  CheckEq('05h counts the left press', R.BX, 1);
  Inject(0, 0, 0);
  R.AX := 6; R.BX := 0; M(R);
  CheckEq('06h counts the left release', R.BX, 1);

  Inject(2, 0, 0); Inject(0, 0, 0);
  R.AX := 5; R.BX := 1; M(R);
  CheckEq('05h counts a right press separately', R.BX, 1);
  R.AX := 5; R.BX := 1; M(R);
  CheckEq('05h clears its count when read', R.BX, 0);

  Inject(4, 0, 0); Inject(0, 0, 0);
  R.AX := 5; R.BX := 2; M(R);
  CheckEq('05h counts a middle press', R.BX, 1);

  { three buttons at once, then all off, is one press and one release each }
  Inject(7, 0, 0);
  GetPos(X, Y, B);
  CheckEq('all three buttons at once', B, 7);
  Inject(0, 0, 0);
  GetPos(X, Y, B);
  CheckEq('and all three release together', B, 0);

  { 0Bh motion counters accumulate mickeys and clear on read }
  R.AX := $0B; M(R);
  Inject(0, 5, 3);
  R.AX := $0B; M(R);
  CheckEq('0Bh returns the x mickeys', Integer(R.CX), 5);
  CheckEq('0Bh returns the y mickeys', Integer(R.DX), 3);
  R.AX := $0B; M(R);
  CheckEq('0Bh clears the counters when read', Integer(R.CX), 0);
  WriteLn;
end;

procedure CheckStrip;
var
  R: Registers;
  Len, Id, Boot: Byte;
  Bogus, Used: Word;
begin
  WriteLn('--- what the device is actually sending ---');
  R.AX := $7F04; M(R);
  Len   := Hi(R.DX);
  Id    := Lo(R.AX);
  Boot  := ResByte(P_MOUBOOT);
  Bogus := ResWord(P_MBOGUS);
  Used  := ResWord(P_MREPORTS);

  WriteLn('  last packet          : ',
          Hex2(Lo(R.BX)), ' ', Hex2(Hi(R.BX)), ' ',
          Hex2(Lo(R.CX)), ' ', Hex2(Hi(R.CX)), ' ', Hex2(Lo(R.DX)),
          '   (', Len, ' bytes)');
  R.AX := $7F03; M(R);
  WriteLn('  as a boot report     : ',
          Hex2(Lo(R.BX)), ' ', Hex2(Hi(R.BX)), ' ', Hex2(Lo(R.CX)));
  WriteLn('  said yes to SET_PROT : ', Boot);
  WriteLn('  carries a report ID  : ', Id);
  WriteLn('  reports used         : ', Used);
  WriteLn('  packets unusable     : ', Bogus);

  if Len = 0 then
    WriteLn('  Nothing has arrived from the mouse endpoint yet.  Move the')
  else
  begin
    { The format is decided from the packet, never from SET_PROTOCOL's
      answer.  This adapter says yes to SET_PROTOCOL 0 and then sends
      report IDs anyway, so Boot = 1 alongside Id = 1 is the NORMAL case
      here and must not be treated as a contradiction -- an earlier build
      did exactly that and threw away every real packet. }
    if Id <> 0 then
    begin
      Check('a report-ID packet is at least 5 bytes', Len >= 5);
      if Boot = 1 then
        WriteLn('  It agreed to boot protocol and ignored its own answer.');
    end
    else
      Check('a boot report is 3 or 4 bytes', (Len >= 3) and (Len <= 4));

    { Whatever the format, packets that arrive must be getting used.  This
      is the check that would have caught the filter that rejected
      everything -- and note that it only means anything once something has
      actually arrived, which is why Len = 0 skips it. }
    Check('packets that arrive are used, not discarded', Used > 0);
  end;
  WriteLn;
end;

{ THE REGRESSION TEST THIS WHOLE PROJECT NEEDED -- in its corrected form.

  The first version asserted that an idle mouse leaves the pointer exactly
  where it is.  That is not a valid assertion about real hardware: this
  mouse is slightly noisy and genuinely reports small movements when
  untouched, and an earlier build mistook that for the chip fabricating
  packets and "fixed" it with a filter that threw away 100% of real mouse
  data.  Asserting stillness would have locked that mistake in.

  What IS worth asserting is that nothing arriving gets silently discarded.
  A driver that rejects real packets and a driver that receives none look
  identical from the INT 33h side -- both leave the pointer where it was --
  and the difference is exactly the counter pair below.  Movement while
  idle is reported, not judged.                                            }
procedure CheckQuiet;
var
  X0, Y0, B0, X1, Y1, B1: Word;
  T0: LongInt;
  Reps0, Bog0, DReps, DBog: Word;
begin
  WriteLn('--- three seconds of whatever the mouse is doing ---');
  GetPos(X0, Y0, B0);
  Reps0 := ResWord(P_MREPORTS);
  Bog0  := ResWord(P_MBOGUS);

  T0 := Ticks;
  while Ticks - T0 < 54 do ;

  GetPos(X1, Y1, B1);
  DReps := ResWord(P_MREPORTS) - Reps0;
  DBog  := ResWord(P_MBOGUS) - Bog0;

  WriteLn('  pointer   : x=', X1, ' y=', Y1,
          '  (was x=', X0, ' y=', Y0, ')');
  WriteLn('  reports   : ', DReps);
  WriteLn('  unusable  : ', DBog);

  { The one thing that must hold either way. }
  CheckEq('packets discarded as unusable', DBog, 0);

  if DReps > 0 then
    WriteLn('  The mouse is reporting.  If nobody touched it, it is a')
  else if (X0 = X1) and (Y0 = Y1) then
    WriteLn('  Quiet and still, which is what SET_IDLE 0 should give.')
  else
    WriteLn('  Pointer moved with no reports counted -- that should not');
  WriteLn;
end;

procedure CheckLive;
var
  Before, After: Word;
  T0: LongInt;
begin
  WriteLn('--- the poll is running ---');
  Check('the mouse half enumerated', ResByte(P_MLIVE) = 1);
  Check('INT 33h is hooked', ResByte(P_HAS33) = 1);

  Before := ResWord(P_NPOLLS);
  T0 := Ticks;
  while Ticks - T0 < 18 do ;
  After := ResWord(P_NPOLLS);
  Check('the timer is calling the poll', After <> Before);
  WriteLn('    keyboard polls in one second: ', After - Before);

  { A bounded wait that keeps giving up, or a stream of stale interrupts,
    both mean the chip is being driven wrongly.  Both were zero once the
    driver stopped asking two endpoints on the same tick, and if either
    starts climbing again that is where to look. }
  CheckEq('keyboard polls that timed out', ResWord(P_NTMO), 0);
  CheckEq('mouse polls that timed out', ResWord(P_MTMO), 0);
  CheckEq('stale interrupts flushed', ResWord(P_NFLUSH), 0);
  WriteLn;
end;

{ ---------------------------------------------------------------------- main }

var
  I: Integer;
  A, Arg: ShortString;
  DoWatch, DoBeepTest, KbdOnly, DoBios, DoFlush: Boolean;
  N: Integer;
  Secs, Code: Word;
  V: LongInt;

procedure Usage;
begin
  Banner('COMBOTST', VER, 'conformance and diagnostics for USBCOMBO.COM');
  WriteLn;
  WriteLn('  COMBOTST [/W[=secs]] [/KB[=secs]] [/BEEP] [/BIOS] [/FLUSH]');
  WriteLn;
  WriteLn('  (none)   run the conformance checks');
  WriteLn('  /W       watch raw packets instead of running the checks');
  WriteLn('  /W=20    ...for 20 seconds');
  WriteLn('  /KB=20   watch the KEYBOARD reports only.  The mouse makes far');
  WriteLn('           more traffic, so with both traced the key reports');
  WriteLn('           scroll away before they can be read');
  WriteLn('  /BIOS    dump the BIOS keyboard buffer state');
  WriteLn('  /FLUSH   print the INT 33h vector before and after');
  WriteLn('  /BEEP    play every cue and exit, to check you can hear them');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Run it with the driver already loaded:');
  WriteLn('  USBCOMBO');
  WriteLn('  COMBOTST');
  WriteLn('  USBCOMBO /U');
  WriteLn;
  WriteLn('USBCOMBO has three things that can fail independently: the USB');
  WriteLn('half, the keyboard delivery path, and the INT 33h mouse');
  WriteLn('interface.  The driver''s own /T covers the second and the');
  WriteLn('arithmetic of the third with no hardware attached.  This covers');
  WriteLn('what /T cannot reach: the INT 33h API as an application really');
  WriteLn('calls it, and what the device is really putting on the wire.');
  WriteLn;
  WriteLn('THE POINT OF /W.  This adapter answers SET_PROTOCOL 0 with');
  WriteLn('success and then sends its native report-ID format anyway, so');
  WriteLn('the driver decides the format from the packet rather than from');
  WriteLn('the request.  /W prints both the bytes as they arrived and the');
  WriteLn('boot-shaped report the driver made of them.');
  WriteLn;
  WriteLn('It also beeps.  The one thing no automated check can do is move');
  WriteLn('the mouse, so /W asks a human to: two rising notes mean start');
  WriteLn('moving and clicking, two falling notes mean stop.  Three high');
  WriteLn('notes mean packets arrived and the driver threw them all away.');
  WriteLn;
  WriteLn('That last case is not hypothetical.  An earlier build decided a');
  WriteLn('5-byte packet could not be real, on the grounds that the device');
  WriteLn('had agreed to a 3-byte boot protocol -- and it rejected 100% of');
  WriteLn('real mouse data while every injected-report check still passed.');
  WriteLn('What caught it was moving the mouse and watching this output.');
  WriteLn;
  WriteLn('Everything here reads the resident driver through its published');
  WriteLn('pointer block, never the card, so there is no I/O base to set.');
  WriteLn('USBCOMBO @hex sets it and USBCOMBO /S prints it back.');
  WriteLn;
  WriteLn('Exit code is the number of failed checks, capped at 20.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Banner('COMBOTST', VER, 'USBCOMBO.COM conformance and diagnostics');
  WriteLn;

  DoWatch := False;
  DoBeepTest := False;
  KbdOnly := False;
  DoBios := False;
  DoFlush := False;
  Secs := 10;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do
      if A[Code] in ['a'..'z'] then A[Code] := Chr(Ord(A[Code]) - 32);
    if (Copy(A, 1, 6) = '/FLUSH') or (Copy(A, 1, 6) = '-FLUSH') then
      DoFlush := True
    else if (Copy(A, 1, 5) = '/BIOS') or (Copy(A, 1, 5) = '-BIOS') then
      DoBios := True
    else if (Copy(A, 1, 3) = '/KB') or (Copy(A, 1, 3) = '-KB') then
    begin
      DoWatch := True;
      KbdOnly := True;
      if (Length(A) > 3) and (A[4] = '=') then
      begin
        Val(Copy(A, 5, 8), V, Code);
        if (Code = 0) and (V > 0) and (V < 600) then Secs := Word(V);
      end;
    end
    else if (Copy(A, 1, 5) = '/BEEP') or (Copy(A, 1, 5) = '-BEEP') then
      DoBeepTest := True
    else if (Copy(A, 1, 2) = '/W') or (Copy(A, 1, 2) = '-W') then
    begin
      DoWatch := True;
      Arg := Copy(A, 4, 8);
      if (Length(A) > 3) and (A[3] = '=') then
      begin
        Val(Arg, V, Code);
        if (Code = 0) and (V > 0) and (V < 600) then Secs := Word(V);
      end;
    end;
  end;

  { Print the vector whether or not the driver is there.  Comparing it
    across a load and an unload is how the INT 33h unhook gets checked:
    after /U it must be exactly what it was before, and it must not still
    point into the segment the driver was released from. }
  if DoFlush then
  begin
    WriteLn('Before:');
    DumpBios;
    N := 0;
    while KeyWaiting and (N < 64) do begin EatKey; Inc(N); end;
    WriteLn;
    WriteLn(N, ' keys discarded.');
    WriteLn;
    WriteLn('After:');
    DumpBios;
    Halt(0);
  end;

  if DoBios then
  begin
    DumpBios;
    Halt(0);
  end;

  if DoBeepTest then
  begin
    WriteLn('Speaker check.  You should hear, in order:');
    WriteLn;
    WriteLn('  1. GO    -- three rising notes, twice');
    Wait(600); BeepGo;
    WriteLn('  2. tick  -- one short high blip (one per mouse report)');
    Wait(600); BeepTick;
    WriteLn('  3. DONE  -- three falling notes, twice');
    Wait(600); BeepDone;
    WriteLn('  4. FAIL  -- four hard high notes');
    Wait(600); BeepFail;
    WriteLn;
    WriteLn('If you heard nothing, the speaker is disconnected or muted');
    WriteLn('and COMBOTST /W will need you to watch the screen instead.');
    Halt(0);
  end;

  if DoBios then
  begin
    DumpBios;
    Halt(0);
  end;

  if not FindResident then
  begin
    WriteLn('INT 33h vector       : ', Hex4(Int33Seg), ':', Hex4(Int33Off));
    WriteLn;
    WriteLn('USBCOMBO.COM is not loaded, or the copy in memory is a');
    WriteLn('different build.  Load it first:');
    WriteLn;
    WriteLn('    USBCOMBO');
    WriteLn('    COMBOTST');
    WriteLn('    USBCOMBO /U');
    Halt(20);
  end;

  Fails := 0;
  Checks := 0;
  WriteLn('INT 33h vector       : ', Hex4(Int33Seg), ':', Hex4(Int33Off));
  ReportResident;

  if DoWatch then
  begin
    Watch(Secs, KbdOnly);
    Halt(0);
  end;

  CheckLive;
  CheckStrip;
  CheckQuiet;

  { Everything below injects exact reports and reads the state back, so the
    driver's own poll has to stop first.  On this adapter that matters: it
    reports continuously, and a real report landing between an injection and
    the read-back turns every check into a coin toss. }
  WasQuiet := SetQuiet(1);
  SavedGain := ResWord(P_GAIN);
  SetResWord(P_GAIN, 1);
  CheckApi;
  CheckInject;
  SetResWord(P_GAIN, SavedGain);
  SetQuiet(WasQuiet);

  { Leave the pointer somewhere sensible rather than wherever the last
    check left it. }
  WriteLn('--- done ---');
  WriteLn('  ', Checks - Fails, ' of ', Checks, ' checks passed');
  if Fails = 0 then
    WriteLn('  PASS')
  else
    WriteLn('  ', Fails, ' FAILED');

  if Fails > 20 then Halt(20) else Halt(Fails);
end.
