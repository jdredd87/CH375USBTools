program fospkt;

{ FOSPKT -- open and close a FOSSIL session on the packet-driver transport.

  This tests the part that can take the machine off the network, and it
  tests it before any TCP exists on top: function 04h takes two packet
  driver handles and starts answering ARP, function 05h gives them back.
  Nothing else here matters yet.

  WHY THIS IS THE RISKY ONE. The packet driver hands our handler a far
  pointer that it calls at interrupt time for every matching frame. Exiting
  without releasing leaves that pointer aimed at memory DOS has since given
  to something else, and the next matching frame jumps into it -- which is a
  box with no network, on a machine that is reached over that network.

  So the session is bracketed three deep:

    1. this program calls 05h on its normal path
    2. an ExitProc calls 05h if it dies on any other path
    3. the driver's own watchdog releases the handles after about a minute
       with no FOSSIL calls, even if this program never runs again

  The third is the one that matters, because the first two both assume this
  program still gets to execute. }

uses Dos, chtool, fosapi;

const
  VER = '0.1.0';

const
  HexDig : array[0..15] of Char = '0123456789ABCDEF';

var
  R        : Registers;
  PrevExit : Pointer;
  Opened   : Boolean;

function HexW(W: Word): ShortString;
begin
  HexW := HexDig[(W shr 12) and 15] + HexDig[(W shr 8) and 15] +
          HexDig[(W shr 4) and 15] + HexDig[W and 15];
end;

function Ticks: Word;
begin
  Ticks := MemW[$0040:$006C];
end;

procedure Deinit;
var Q: Registers;
begin
  FillChar(Q, SizeOf(Q), 0);
  Q.AH := $05; Q.DX := 0;
  Intr($14, Q);
end;

procedure FosRelease; far;
begin
  ExitProc := PrevExit;
  if Opened then Deinit;
end;

procedure Settle(T: Word);
var D: Word;
begin
  D := Ticks + T;
  while Integer(Ticks - D) < 0 do ;
end;

var
  VecSeg, VecOfs, Sig: Word;

begin
  Banner('FOSPKT', VER, 'open and close a packet-driver session');

  Opened   := False;
  PrevExit := ExitProc;
  ExitProc := @FosRelease;

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

  { 04h binds the handles and sends the first ARP request. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $04; R.DX := 0; R.BX := $4F50;
  Intr($14, R);
  Check('04h initialize returns 1954h', R.AX = $1954);
  Opened := R.AX = $1954;

  { Give the peer time to answer, and us time to answer anything it asks. }
  Settle(40);

  FillChar(R, SizeOf(R), 0);
  R.AH := $03; R.DX := 0;
  Intr($14, R);
  Note('status word after two seconds: ' + HexW(R.AX));

  { 05h hands both handles back. Everything after this point is running on
    a machine whose network belongs to the bridge again -- which is the
    whole thing being tested, and the proof is that this job's result
    reaches Windows at all. }
  Deinit;
  Opened := False;
  Check('05h deinitialize returned', True);

  Settle(10);
  Note('the handles are back; if you can read this, the link survived');

  Finish;
end.
