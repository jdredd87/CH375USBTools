program foswdog;

{ FOSWDOG -- prove the watchdog actually fires.

  The watchdog exists for one case: the application that opened the line has
  DIED while holding the packet driver's handles. On this machine those
  handles are the bridge's own network, so a driver that keeps them after
  its application is gone takes the box off the air until somebody walks
  over to it.

  THIS TEST IS ITS OWN PROOF, which is the reason it is shaped like this.
  Function 04h takes the handles. From that moment the bridge cannot reach
  Windows. This program then goes quiet for longer than the watchdog's
  timeout, touching INT 14h not once -- so if the watchdog works, the
  handles come back on their own, the agent starts polling again, and this
  job's result is delivered. If it does not work, nothing is ever heard from
  this machine again and the job times out.

  So: a result arriving at all IS the pass. The counters are the detail.

  It deliberately installs NO ExitProc to release the line. Everywhere else
  in this project that would be a bug -- it is the dangling-callback hazard
  that made one crash get inherited by the next program. Here it is the
  whole point: the watchdog is the only safety net left, and a test that
  quietly tidied up after itself would prove nothing about it.

  The wait uses the BIOS tick at 0040:006C directly. It must not call
  INT 14h, because every INT 14h call feeds the watchdog. }

uses Dos, chtool, fosapi;

const
  VER = '0.1.0';

const
  QUIET_SECS = 75;              { the driver gives up at about 60 }

var
  R      : Registers;
  T0, T1 : Word;
  Dead   : Word;
  Secs   : Word;

function Ticks: Word;
begin
  Ticks := MemW[$0040:$006C];
end;

var
  VecSeg, VecOfs, Sig : Word;

begin
  Banner('FOSWDOG', VER, 'prove the watchdog fires');

  VecOfs := MemW[0 : $14 * 4];
  VecSeg := MemW[0 : $14 * 4 + 2];
  Sig    := MemW[VecSeg : VecOfs + 6];
  if Sig <> $1954 then
  begin
    Note('no FOSSIL driver is loaded');
    Check('a FOSSIL driver is present', False);
    Finish;
    Halt(Failures);
  end;

  WriteLn('  opening the line -- this takes the packet driver handles,');
  WriteLn('  which is the bridge''s own network. From here until the');
  WriteLn('  watchdog fires, this machine cannot be reached.');

  FillChar(R, SizeOf(R), 0);
  R.AH := $04; R.DX := 0; R.BX := $4F50;
  Intr($14, R);
  Check('the line opened', R.AX = $1954);

  T0 := Ticks;
  Dead := T0 + QUIET_SECS * 18;

  { Not one INT 14h call in here. Every one of them would feed the
    watchdog, and a test that keeps petting the thing it is trying to
    provoke is not a test. }
  while Integer(Ticks - Dead) < 0 do ;

  T1 := Ticks;
  Secs := (T1 - T0) div 18;
  Note('seconds spent silent: ', Secs);

  WriteLn('  still here, and this text only reaches Windows if the');
  WriteLn('  watchdog gave the handles back on its own.');

  Check('the silence lasted longer than the watchdog timeout',
        Secs >= 70);

  { No 05h and no ExitProc, deliberately. If the handles are free now, the
    driver freed them. }
  Finish;
end.
