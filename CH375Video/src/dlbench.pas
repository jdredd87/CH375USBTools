program dlbench;
{ DLBENCH -- how fast can a DOS machine push pixels at a DisplayLink adapter?
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

    DLBENCH [/P=260] [/M=n] [/R=reps] [/O]

      /O   use ch375's EpOut instead of the inlined packet writer, so
           the two can be compared rather than argued about

  WHY THIS EXISTS BEFORE ANY OPTIMISATION

  CH375Net has four dead hypotheses written up in its CHANGELOG, each of
  which was a plausible speed-up that measured as nothing. The rule that
  came out of it is to measure first, and the specific trap is that
  per-operation figures do not predict cost inside real code.

  There is a concrete prediction to test here. A bulk endpoint on this
  device is 64 bytes a packet, and that is a USB limit rather than a
  tunable -- so every 64 bytes costs one full CH375 transaction:
  WR_USB_DATA7, the payload, SET_ENDP7, ISSUE_TOKEN, then waiting for the
  interrupt. If that round trip dominates, throughput is set by the
  transaction RATE and nothing else, and the only useful optimisation is
  to send fewer bytes. If instead the payload copy dominates, then a
  faster byte move -- REP OUTSB, where the CPU has it -- is worth having.

  CH375Net already measured the same shape on the Ethernet path and found
  it round-trip bound: inlining REP INSB there "moved 1 MB by 2 seconds in
  73", about 3%. This says whether the display path agrees.

  So the numbers that matter are not "KB/s" on its own but KB/s ALONGSIDE
  the transaction rate. A payload-bound path and a transaction-bound path
  can report the same KB/s and want opposite fixes.

  WHAT IT MEASURES

    packets   64-byte transactions per second, the floor on everything
    raw       a full screen sent as literal pixels, worst case
    rle       a full screen as solid runs, best case
    rect      a small rectangle, which is what animation actually costs
    text      a band of mixed detail, the realistic middle
    turn      the same eight bands horizontal, then vertical --
              the cost of laying a picture out across the grain

  Exit codes: 0 ok, otherwise the DlOpen reason (all <= 20) }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, dl;

const
  VER = '1.0.0';

var
  Reps:   Integer = 1;
  ModeIx: Integer = 0;
  T:      TDlTiming;
  Line:   array[0..1023] of Word;    { one scanline of working pixels }

procedure Fld(const Name, Value: ShortString);
var S: ShortString;
begin
  S := '  ' + Name;
  while Length(S) < 18 do S := S + ' ';
  WriteLn(S + Value);
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ Ticks are 18.2 Hz, so a measurement of a few ticks is mostly quantisation
  noise. Everything here is sized to run for at least a couple of seconds,
  and the tick count is printed so a too-short run is visible rather than
  quietly wrong. }
function Elapsed(T0: LongInt): LongInt;
begin
  Elapsed := Ticks - T0;
  if Elapsed < 0 then Elapsed := 0;
end;

{ Bytes per second from a tick count, without touching Real: ticks are
  18.2 Hz, so bytes/sec = bytes * 182 / (ticks * 10). }
function Rate(Bytes, Tk: LongInt): LongInt;
begin
  if Tk <= 0 then Rate := 0
  else Rate := (Bytes div Tk) * 182 div 10;
end;

procedure Report(const What: ShortString; T0, B0, P0: LongInt);
var
  Tk, B, P: LongInt;
begin
  Tk := Elapsed(T0);
  B := DlBytes - B0;
  P := DlPackets - P0;
  WriteLn('  ', What);
  WriteLn('      ', Dec1(B), ' bytes in ', Dec1(P), ' packets, ',
          Dec1(Tk), ' ticks');
  if Tk > 0 then
    WriteLn('      ', Dec1(Rate(B, Tk)), ' B/s      ',
            Dec1(Rate(P, Tk)), ' packets/s')
  else
    WriteLn('      too fast to time at 18.2 Hz -- raise /R');
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
  I, J, Rc: Integer;
  S:        ShortString;
  T0, B0, P0: LongInt;
  Px:       LongInt;

begin
  Banner('DLBENCH', VER, 'DisplayLink throughput on a CH375');

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'M': ModeIx := DecArg(S, 4);
        'R': Reps := DecArg(S, 4);
        'O': DlSlow := True;
      end;
  end;
  if (ModeIx < 0) or (ModeIx >= NDLMODES) then ModeIx := 0;
  if Reps < 1 then Reps := 1;
  T := DlModes[ModeIx];
  Px := LongInt(T.XRes) * T.YRes;

  ExitProc := @Quieten;
  Rc := DlOpen;
  if Rc <> DL_OK then
  begin
    WriteLn(DlWhy(Rc));
    Halt(Rc);
  end;

  Fld('mode', T.Name);
  Fld('framebuffer', Dec1(Px * 2) + ' bytes (' + Dec1(Px) + ' px at 16bpp)');
  Fld('bulk endpoint', Hex2(DlEpBulk) + ', 64 bytes a packet');
  Fld('reps', Dec1(Reps));
  WriteLn;

  if not DlSetMode(T) then
  begin
    WriteLn('the adapter stopped accepting the command stream');
    Halt(DL_REFUSED);
  end;

  WriteLn('---- 1. transaction rate, the floor under everything ----');
  WriteLn('  A solid fill is the cheapest possible command stream, so its');
  WriteLn('  packet rate is very close to the raw transaction rate.');
  DlZeroStats;
  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for J := 1 to Reps do
    if not DlFillRun(0, DlRgb(0, 0, 0), Px) then Break;
  Report('solid fill x' + Dec1(Reps), T0, B0, P0);
  WriteLn;

  WriteLn('---- 2. RLE, the best case ----');
  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for J := 1 to Reps do
    if not DlFillRun(0, DlRgb(255, 0, 0), Px) then Break;
  Report('full screen, one colour', T0, B0, P0);
  WriteLn('      = ', Dec1((DlBytes - B0) div Reps), ' bytes a frame,',
          ' against ', Dec1(Px * 2), ' raw');
  WriteLn;

  WriteLn('---- 3. literal pixels, the worst case ----');
  WriteLn('  Every pixel different, so nothing collapses into a repeat.');
  WriteLn('  This is the photograph case, and the ceiling on it.');
  for I := 0 to T.XRes - 1 do
    Line[I] := Word(I * 37 + 1);        { no two adjacent alike }
  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for I := 0 to T.YRes - 1 do
    if not DlRleRun(DlAddr(T, 0, I), @Line[0], T.XRes) then Break;
  if not DlSend then WriteLn('      send failed');
  Report('full screen, all literal', T0, B0, P0);
  WriteLn;

  WriteLn('---- 4. a small rectangle, which is what animation costs ----');
  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for J := 1 to 20 do
    if not DlFillRect(T, 100, 100, 64, 64, DlRgb(0, 255, 0)) then Break;
  if not DlSend then WriteLn('      send failed');
  Report('64x64 rect x20', T0, B0, P0);
  WriteLn('      = ', Dec1((DlBytes - B0) div 20), ' bytes a rect');
  WriteLn;

  WriteLn('---- 5. mixed detail, the realistic middle ----');
  WriteLn('  Mostly background with short runs of ink, which is what text');
  WriteLn('  and line art look like to the encoder.');
  for I := 0 to T.XRes - 1 do
    if (I mod 8) < 2 then Line[I] := DlRgb(255, 255, 255)
                     else Line[I] := DlRgb(0, 0, 40);
  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for I := 0 to T.YRes - 1 do
    if not DlRleRun(DlAddr(T, 0, I), @Line[0], T.XRes) then Break;
  if not DlSend then WriteLn('      send failed');
  Report('full screen, text-like', T0, B0, P0);
  WriteLn;

  WriteLn('---- 6. the same picture, turned ninety degrees ----');
  WriteLn('  Eight colour bands horizontally, then the same eight');
  WriteLn('  vertically.  Identical ink, identical area, and the encoder');
  WriteLn('  is a HORIZONTAL run-length coder -- so this is the cost of');
  WriteLn('  laying a picture out the way the wire does not want it.');
  WriteLn;

  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for I := 0 to 7 do
    if not DlFillRun(LongInt(I) * (T.YRes div 8) * T.XRes * 2,
                     DlRgb(255 - I * 30, I * 30, 128),
                     LongInt(T.YRes div 8) * T.XRes) then Break;
  if not DlSend then WriteLn('      send failed');
  Report('8 bands HORIZONTAL', T0, B0, P0);

  for I := 0 to T.XRes - 1 do
    Line[I] := DlRgb(255 - (I div (T.XRes div 8)) * 30,
                     (I div (T.XRes div 8)) * 30, 128);
  T0 := Ticks; B0 := DlBytes; P0 := DlPackets;
  for I := 0 to T.YRes - 1 do
    if not DlRleRun(DlAddr(T, 0, I), @Line[0], T.XRes) then Break;
  if not DlSend then WriteLn('      send failed');
  Report('8 bars VERTICAL', T0, B0, P0);
  WriteLn;

  WriteLn('---- totals ----');
  Fld('packets', Dec1(DlPackets));
  Fld('payload bytes', Dec1(DlBytes));
  Fld('of which padding', Dec1(DlPad) + '  ('
      + Dec1(DlPad * 100 div DlBytes) + '%)');
  Fld('NAKs retried', Dec1(DlNaks));
  WriteLn;
  WriteLn('READ IT LIKE THIS.  If packets/s is about the same in every');
  WriteLn('test above, the path is transaction-bound and the only');
  WriteLn('optimisation that can matter is sending fewer bytes -- a faster');
  WriteLn('byte move would buy nothing.  If packets/s climbs when the');
  WriteLn('command stream gets simpler, the payload copy is costing real');
  WriteLn('time and REP OUTSB is worth adding.');
  Halt(0);
end.
