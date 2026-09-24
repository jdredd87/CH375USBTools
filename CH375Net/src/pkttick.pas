program pkttick;
{ PKTTICK -- is polling from a timer interrupt what breaks the receive path?
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  A controlled experiment, and nothing else.  USBPKT reads the bulk endpoint
  from inside INT 08h and wedges after a frame or two; USBRECV reads it from
  a normal loop and never does.  Everything else that differed between them
  has been tested and ruled out -- the polling rate (USBRECV was slowed to
  USBPKT's 28ms and stayed clean), the receive filter, the aggregation size,
  the data toggle, the endpoint clear.  What is left is where the code runs.

  So this runs ONE piece of code -- AxRxBurst, the reference, the one that
  works -- in both places, back to back, in a single program against a
  single bring-up:

    phase 1   from the foreground, with a delay between polls
    phase 2   from a hook on INT 08h, at the BIOS tick rate

  If phase 1 is clean and phase 2 wedges, the answer is interrupt context
  and USBPKT's receive logic is not the problem at all.  If both are clean,
  the fault is something USBPKT's assembly does that ax179.pas does not, and
  this rules out the last structural difference between them.

  The PIT is deliberately NOT reprogrammed.  Rate has already been
  eliminated, and leaving the timer alone keeps this test about one thing.
  18.2 polls a second is slower than USBPKT manages and slower than the
  28ms that was already proven fine in the foreground.

    PKTTICK [/P=260] [/S=secs] [/G]

      /P=hex   CH375 I/O base, default 260
      /S=dec   seconds per phase, default 12
      /G       leave the PHY at gigabit rather than forcing 10BASE-T

  Exit codes: 0 both phases clean, 1 phase 2 wedged, 2 both wedged,
  3 the adapter would not come up }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, ax179, Dos;

const
  VER   = '1.0.0';
  BUFSZ = 2048;

var
  Base:   Word    = $260;
  Secs:   Word    = 12;
  Giga:   Boolean = False;

procedure Usage;
begin
  Banner('PKTTICK', VER, 'timer-interrupt vs foreground receive');
  WriteLn;
  WriteLn('  PKTTICK [/P=hex] [/S=dec] [/G]');
  WriteLn;
  WriteLn('  /P=hex   CH375 I/O base, default 260');
  WriteLn('  /S=dec   seconds per phase, default 12');
  WriteLn('  /G       leave the PHY at gigabit');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Runs the SAME receive routine twice -- once from a normal loop,');
  WriteLn('once from a hook on the timer interrupt -- against one bring-up.');
  WriteLn('Everything else that differed between USBPKT and USBRECV has');
  WriteLn('already been ruled out, so this is the last one standing.');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/G') or (A = '-G') then Giga := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if K = '/P=' then
      begin
        Val('$' + A, V, Code);
        if Code = 0 then Base := Word(V);
      end
      else if K = '/S=' then
      begin
        Val(A, V, Code);
        if Code = 0 then Secs := Word(V);
      end;
    end;
  end;
end;

{ ---- what both phases count ------------------------------------------- }
type
  TTally = record
    Bursts, Frames, Naks, Errs, Over: Word;
    LastSt: Integer;
    Bytes:  LongInt;
  end;

var
  Fore, Intr: TTally;
  Buf:        array[0..BUFSZ - 1] of Byte;
  OldInt8:    Pointer;
  Armed:      Boolean = False;
  InTick:     Boolean = False;
  Hooked:     Boolean = False;

procedure Clear(var T: TTally);
begin
  FillChar(T, SizeOf(T), 0);
  T.LastSt := 0;
end;

{ Count a burst.  Frames are not parsed -- the layout checks live in
  USBRECV and this is not trying to repeat them.  What matters here is
  whether bursts keep ARRIVING and keep ENDING, because the failure being
  chased is a transfer that never terminates. }
procedure Tally(var T: TTally; St: Integer; Len: Word);
begin
  T.LastSt := St;
  if St = INT_RET_NAK then begin Inc(T.Naks); Exit; end;
  if St <> INT_SUCCESS then begin Inc(T.Errs); Exit; end;
  Inc(T.Bursts);
  T.Bytes := T.Bytes + Len;
  if AxRxOver > 0 then Inc(T.Over);
end;

{ ---- phase 2 ----------------------------------------------------------
  The handler chains to whatever was on INT 08h, so the BIOS clock keeps
  time and anything else hooked in front of us still runs.  The PIT is
  untouched, so this fires at the ordinary 18.2 Hz.

  InTick is a re-entry guard: a poll that finds data can outlast a tick.

  Armed is the stack guard, and it is not optional.  An FPC interrupt
  procedure runs on whatever stack it interrupted, and AxRxBurst wants a
  couple of hundred bytes of locals -- fire that while DOS or the BIOS is
  on one of its own small stacks and the machine dies for a reason that
  has nothing to do with what is being measured.  The main loop below sets
  Armed only while it is spinning on its OWN stack, doing nothing but
  reading memory, so the poll always has room. }
procedure Tick; interrupt;
var
  Len: Word;
  St:  Integer;
begin
  if Armed and not InTick then
  begin
    InTick := True;
    St := AxRxBurst(Buf, BUFSZ, Len);
    Tally(Intr, St, Len);
    InTick := False;
  end;
  asm
    pushf
    call far [OldInt8]
  end;
end;

procedure Hook;
begin
  GetIntVec($08, OldInt8);
  SetIntVec($08, @Tick);
  Hooked := True;
end;

procedure Unhook;
begin
  if not Hooked then Exit;
  Armed := False;
  SetIntVec($08, OldInt8);
  Hooked := False;
end;

procedure Report(const Name: ShortString; const T: TTally);
begin
  WriteLn;
  WriteLn(Name);
  WriteLn('  bursts       : ', T.Bursts);
  WriteLn('  bytes        : ', T.Bytes);
  WriteLn('  idle (NAK)   : ', T.Naks);
  WriteLn('  errors       : ', T.Errs);
  WriteLn('  overruns     : ', T.Over);
  WriteLn('  last status  : ', StatusStr(T.LastSt));
end;

var
  Rc:    Integer;
  TEnd:  LongInt;
  Len:   Word;
  St:    Integer;
  BadF, BadI: Boolean;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('PKTTICK', VER, 'timer-interrupt vs foreground receive');
  WriteLn;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    Halt(3);
  end;
  if not AxInit(False) then
  begin
    WriteLn('The adapter would not initialise.  USBLINK /V says where.');
    Halt(3);
  end;
  AxNegotiate(not Giga);
  AxLinkWait(15, Len);
  AxSetMedium(Giga);
  WriteLn('adapter up, MAC ', MacStr(Mac));
  WriteLn;

  Clear(Fore);
  Clear(Intr);

  { ---- phase 1: the foreground, as USBRECV does it ---- }
  WriteLn('phase 1: polling from the foreground for ', Secs, 's');
  AxRxReset;
  TEnd := Ticks + LongInt(Secs) * 18;
  while Ticks < TEnd do
  begin
    St := AxRxBurst(Buf, BUFSZ, Len);
    Tally(Fore, St, Len);
    DelayMs(55);                 { the BIOS tick, so both phases match }
  end;

  { ---- phase 2: the same call, from INT 08h ---- }
  WriteLn('phase 2: the same call, from a hook on INT 08h, for ', Secs, 's');
  AxRxReset;
  Hook;
  TEnd := Ticks + LongInt(Secs) * 18;
  Armed := True;
  while Ticks < TEnd do ;        { spin on our own stack and let it fire }
  Armed := False;
  Unhook;

  Report('foreground', Fore);
  Report('timer interrupt', Intr);

  { A phase is "wedged" if bursts stopped arriving.  On this network
    something broadcasts every few seconds, so a phase that saw the wire
    at all and then saw nothing is the failure being chased. }
  BadF := Fore.Bursts = 0;
  BadI := Intr.Bursts = 0;

  WriteLn;
  if BadF and BadI then
  begin
    WriteLn('Neither phase received anything.  That is not this test''s');
    WriteLn('answer -- it means the adapter was already wedged, or the');
    WriteLn('wire was silent.  Power-cycle and run it again.');
    Halt(2);
  end;
  if BadI then
  begin
    WriteLn('The foreground received and the interrupt did not, with the');
    WriteLn('same code and the same adapter.  Interrupt context is the');
    WriteLn('difference, and USBPKT''s receive logic is not the fault.');
    Halt(1);
  end;
  WriteLn('Both phases received.  Polling from the timer is NOT what');
  WriteLn('breaks it, so the fault is something USBPKT''s assembly does');
  WriteLn('that ax179.pas does not.');
  Halt(0);
end.
