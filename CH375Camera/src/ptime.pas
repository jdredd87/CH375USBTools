unit ptime;
{ PTIME -- a microsecond clock from the 8253/8254 timer, for stamping
  packets.  CH375Camera, StevenC & Claude.  Public domain (the Unlicense).

  The BIOS runs timer channel 0 in mode 3 (square wave), where the counter
  steps down by TWO and passes through its range twice per 55 ms period --
  so a single read cannot say which half it is in.  PitFine reprograms the
  same channel, same 65536 divisor, into mode 2 (rate generator), where it
  steps by one through the whole period.  IRQ 0 still fires at 18.2 Hz, so
  the BIOS clock and everything hooked on it carry on as before.
  PitRestore puts mode 3 back, and must run before the program exits.

  Now returns (tick * 65536 + elapsed counts): 1,193,182 per second,
  0.84 us a count.  Only the low 16 bits of the tick are used, so it wraps
  after an hour, which is far longer than any capture.

  THE RACE.  The counter can wrap and raise IRQ 0 while interrupts are off
  for the read, in which case the BIOS tick is one behind the counter.
  The PIC's request register says whether IRQ 0 is pending; if it is, and
  the counter has only just restarted, the tick is corrected here. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

procedure PitFine;
procedure PitRestore;
function  Now: LongInt;

const
  PIT_HZ = 1193182;

implementation

uses ch375;

procedure PitFine;
begin
  asm cli end;
  OutB($43, $34);               { channel 0, lo/hi, mode 2, binary }
  OutB($40, 0);
  OutB($40, 0);                 { 65536 }
  asm sti end;
end;

procedure PitRestore;
begin
  asm cli end;
  OutB($43, $36);               { channel 0, lo/hi, mode 3, binary }
  OutB($40, 0);
  OutB($40, 0);
  asm sti end;
end;

function Now: LongInt;
var
  Lo, Hi, Irr: Byte;
  Cnt, Tick, Elapsed: Word;
begin
  asm cli end;
  OutB($43, $00);               { latch channel 0 }
  Lo := InB($40);
  Hi := InB($40);
  Tick := MemW[$0040:$006C];
  OutB($20, $0A);               { OCW3: next read of 20h is the IRR }
  Irr := InB($20);
  asm sti end;
  Cnt := Word(Hi) shl 8 or Lo;
  Elapsed := Word(0 - Cnt);     { counts since the last reload }
  if ((Irr and 1) <> 0) and (Elapsed < $8000) then Inc(Tick);
  Now := LongInt(Tick) shl 16 or Elapsed;
end;

end.
