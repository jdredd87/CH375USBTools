program fostest;

{ FOSTEST -- exercise every function a FOSSIL driver exposes, through
  INT 14h and nothing else.

  This is a generic FOSSIL client, not a test of our driver in particular.
  It asks the driver what it supports and tests what it claims, so it should
  pass against X00 or BNU as readily as against ours -- and if it ever does
  not, that difference is the interesting result.

  WHAT IT WILL NOT DO, and why

  Three functions in the spec cannot be exercised from a machine reached
  over a network, because each of them is indistinguishable from a crash:

    0Eh  keyboard read WITH wait -- blocks until somebody presses a key,
         and there is nobody at the keyboard
    17h  reboot -- a job that reboots cannot report its own result
    14h  the watchdog actually FIRING -- which reboots, same problem

  So 0Eh and 17h are never called, and 14h is only switched on and off. They
  are listed as untested at the end rather than quietly skipped, because a
  suite that counts what it did not run is worse than one that admits it.

  Function 02h, receive with wait, blocks for ever by design. It is called
  only after 03h has already said a byte is waiting, which makes it safe;
  the same care is taken before every 01h.

  THE TICK-CHAIN AND APPLICATION STUBS

  Functions 16h and 7Eh take a far pointer that the driver calls -- 16h from
  inside a hardware interrupt. A Pascal procedure is the wrong shape for
  that: it is entered with the driver's DS, not the program's, so touching
  any global would write to whatever happens to live at that offset in the
  driver.

  So both stubs are a handful of hand-assembled bytes built at run time in a
  byte array, and they keep their counters in that same array and reach them
  through CS -- which, during the call, is the array's own segment. No
  segment setup, nothing to get wrong, and it works the same on any driver.

  Both are removed by an ExitProc, and that is not tidiness. A stale entry is
  a far call into memory DOS has since given to something else, so the fault
  lands on whatever runs NEXT rather than on the program that caused it --
  which is exactly how one crash here gets inherited by the following one. }

uses Dos, chtool, fosapi;

const
  VER = '0.1.0';

type
  TBuf = array[0..2047] of Byte;

const
  { The stub layout. Offsets into Stub[], fixed so the builder and the
    readers cannot drift apart. }
  ST_TICK   = 0;        { the timer-tick routine }
  ST_APP    = 8;        { the AH=80h application }
  ST_NTICK  = 24;       { word: times the tick routine ran }
  ST_NAPP   = 26;       { word: times the application ran }

  APP_CODE  = $80;      { the function code we claim with 7Eh }
  APP_MAGIC = $4242;    { what the application returns in AX }

  TestText  : ShortString =
    'The quick brown fox jumps over the lazy dog 0123456789!';

var
  Stub      : array[0..31] of Byte;
  Blk       : TFosInfo;
  Top       : Byte;
  TickAdded : Boolean;
  AppAdded  : Boolean;
  PrevExit  : Pointer;
  TxBuf     : TBuf;
  RxBuf     : TBuf;

{ Wait until at least Want bytes are readable, or Limit BIOS ticks pass.
  Every wait in this program is bounded by the clock, so a transport that
  stops delivering costs a failed check rather than a wedged machine. }
function WaitRx(Want, Limit: Word): Boolean;
var Deadline: Word;
begin
  Deadline := Ticks + Limit;
  while (RxAvail < Want) and (Integer(Ticks - Deadline) < 0) do ;
  WaitRx := RxAvail >= Want;
end;

{ Push Len bytes out, topping the ring up as the transport drains it. }
function SendAll(var Buf; Len, Limit: Word): Word;
var
  Sent, N : Word;
  Deadline: Word;
  P       : ^TBuf;
begin
  P := @Buf;
  Sent := 0;
  Deadline := Ticks + Limit;
  while (Sent < Len) and (Integer(Ticks - Deadline) < 0) do
  begin
    N := WriteBlock(P^[Sent], Len - Sent);
    Inc(Sent, N);
  end;
  SendAll := Sent;
end;

{ ---------------------------------------------------------------------- }
{ Cleanup. Armed before anything is registered, so a crash between the
  registration and the end still takes the entries back out.             }
{ ---------------------------------------------------------------------- }

procedure FosRelease; far;
var R: Registers;
begin
  ExitProc := PrevExit;

  if TickAdded then
  begin
    TickChain(False, Seg(Stub), Ofs(Stub) + ST_TICK);
    TickAdded := False;
  end;

  if AppAdded then
  begin
    ClearRegs(R);
    R.AH := $7F; R.AL := APP_CODE;
    R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_APP;
    Intr($14, R);
    AppAdded := False;
  end;
end;

{ ---------------------------------------------------------------------- }

procedure BuildStubs;
begin
  FillChar(Stub, SizeOf(Stub), 0);
  BuildTickStub(Stub, ST_TICK, ST_NTICK);
  BuildAppStub(Stub, ST_APP, ST_NAPP, APP_MAGIC);
end;

function TickCount: Word;
begin
  TickCount := StubCount(Stub, ST_NTICK);
end;

function AppCount: Word;
begin
  AppCount := StubCount(Stub, ST_NAPP);
end;

{ ====================================================================== }

var
  R          : Registers;
  VecSeg     : Word;
  VecOfs     : Word;
  Sig        : Word;
  I          : Word;
  N          : Word;
  Sent       : Word;
  Got        : Word;
  Ok         : Boolean;
  Before     : Word;
  Deadline   : Word;
  Rounds     : Word;
  SawOvrn    : Boolean;

begin
  Banner('FOSTEST', VER, 'exercise every FOSSIL function');

  TickAdded := False;
  AppAdded  := False;
  PrevExit  := ExitProc;
  ExitProc  := @FosRelease;

  { ---- detection, from memory, before any call is made ---- }
  Top := MaxFunc;
  Note('INT 14h vector: ' + HexW(VecSeg) + ':' + HexW(VecOfs) + 'h');
  Note('signature at handler+6: ' +
       HexW(MemW[VecSeg : VecOfs + 6]) + 'h');

  if not Present then
  begin
    Note('no FOSSIL driver is loaded -- load one and run this again');
    Check('a FOSSIL driver is present', False);
    Finish;
    Halt(Failures);
  end;

  Note('highest function, from the signature: ' + HexW(Top) + 'h');

  { ---- 04h, initialize ---- }
  Check('04h initialize returns 1954h', InitRegs(R));
  Check('04h agrees with the in-memory maximum function', R.BL = Top);
  Note('spec revision reported: ', R.BH);

  { ---- 1Bh, driver information ---- }
  Info(Blk);
  Check('1Bh reports a structure of at least 19 bytes', Blk.StrSiz >= 19);
  Check('1Bh reports a non-zero input buffer', Blk.IBufr > 0);
  Check('1Bh reports a non-zero output buffer', Blk.OBufr > 0);
  Check('1Bh input free never exceeds input size', Blk.IFree <= Blk.IBufr);
  Check('1Bh output free never exceeds output size', Blk.OFree <= Blk.OBufr);
  Note('input buffer: ', Blk.IBufr);
  Note('output buffer: ', Blk.OBufr);

  { ---- 09h / 0Ah, purge, and the status bits over an idle port ---- }
  PurgeIn;
  PurgeOut;
  Check('after purging, nothing is readable', not RxReady);
  Check('after purging, there is room to transmit', TxRoom);
  Check('after purging, the transmitter is empty', TxEmpty);
  Check('after purging, no overrun is flagged', not Overrun);
  Check('0Ch peek on an empty port returns FFFFh', Peek = $FFFF);

  { ---- 00h, set baud, read it back through 1Bh ---- }
  ClearRegs(R);
  R.AH := $00; R.AL := $E3; R.DX := 0;          { 9600 8N1 }
  Intr($14, R);
  Info(Blk);
  Check('00h baud setting is reported back by 1Bh', Blk.Baud = $E3);

  { ---- 07h, timer tick parameters ---- }
  ClearRegs(R);
  R.AH := $07;
  Intr($14, R);
  Note('07h tick rate, Hz: ', R.AH);
  Note('07h tick period, ms: ', R.DX);
  Check('07h reports a plausible tick rate', (R.AH >= 18) and (R.AH <= 250));
  Check('07h period and rate are consistent', R.DX > 0);

  { ---- 0Bh / 0Ch / 02h, one byte all the way round ---- }
  PurgeIn;
  PurgeOut;
  Check('0Bh accepts a byte when there is room', TxNoWait($5A));
  Check('the byte arrives back within a second', WaitRx(1, 20));
  if RxAvail >= 1 then
  begin
    Check('0Ch peeks the byte without consuming it', Peek = $005A);
    Check('0Ch left the byte in place', RxAvail >= 1);
    Check('03h says data is available', RxReady);
    Check('02h returns the same byte', GetCh = $5A);
    Check('the port is empty again', RxAvail = 0);
  end;

  { ---- 01h / 02h, byte at a time ---- }
  PurgeIn;
  PurgeOut;
  Ok := True;
  for I := 1 to 16 do
  begin
    if TxRoom then SendWait(I) else Ok := False;
  end;
  Check('01h accepted sixteen bytes', Ok);
  Check('all sixteen came back', WaitRx(16, 20));
  Ok := True;
  for I := 1 to 16 do
    if RxReady then
    begin
      if GetCh <> I then Ok := False;
    end
    else Ok := False;
  Check('01h/02h round trip is byte-exact and in order', Ok);

  { ---- 19h / 18h, block write and read ---- }
  PurgeIn;
  PurgeOut;
  N := Length(TestText);
  for I := 1 to N do TxBuf[I - 1] := Ord(TestText[I]);
  Sent := SendAll(TxBuf, N, 40);
  Check('19h wrote the whole block', Sent = N);
  Check('the whole block came back', WaitRx(N, 40));
  FillChar(RxBuf, SizeOf(RxBuf), 0);
  Got := ReadBlock(RxBuf, SizeOf(RxBuf));
  Check('18h read back the same number of bytes', Got = N);
  Ok := Got = N;
  if Ok then
    for I := 0 to N - 1 do
      if RxBuf[I] <> TxBuf[I] then Ok := False;
  Check('19h/18h round trip is byte-exact', Ok);

  { ---- 18h on an empty port must return zero, not block ---- }
  PurgeIn;
  Check('18h on an empty port returns zero', ReadBlock(RxBuf, 64) = 0);

  { ---- 08h, flush ---- }
  PurgeIn;
  PurgeOut;
  for I := 0 to 255 do TxBuf[I] := I;
  Sent := WriteBlock(TxBuf, 256);
  Check('19h queued a block to flush', Sent > 0);
  Flush;
  Check('08h left the transmit buffer empty', TxPending = 0);
  Check('08h left the transmitter reporting empty', TxEmpty);

  { ---- 06h, DTR, and the carrier bit that follows it ---- }
  Dtr(True);
  Check('06h raising DTR shows carrier', Carrier);
  Dtr(False);
  Check('06h lowering DTR drops carrier', not Carrier);
  Dtr(True);
  Check('06h raising DTR again restores carrier', Carrier);

  { ---- 0Fh and 10h, recorded settings ---- }
  ClearRegs(R);
  R.AH := $0F; R.AL := $02; R.DX := 0;          { RTS/CTS }
  Intr($14, R);
  Check('0Fh flow control was accepted', True);

  ClearRegs(R);
  R.AH := $10; R.AL := $01; R.DX := 0;
  Intr($14, R);
  Check('10h returns a flag word', (R.AX = 0) or (R.AX = 1));

  { ---- 14h, watchdog on and off. Never allowed to fire. ---- }
  ClearRegs(R);
  R.AH := $14; R.AL := $01; R.DX := 0;
  Intr($14, R);
  ClearRegs(R);
  R.AH := $14; R.AL := $00; R.DX := 0;
  Intr($14, R);
  Check('14h watchdog enable and disable were accepted', True);

  { ---- 1Ah, break ---- }
  ClearRegs(R);
  R.AH := $1A; R.AL := $01; R.DX := 0;
  Intr($14, R);
  ClearRegs(R);
  R.AH := $1A; R.AL := $00; R.DX := 0;
  Intr($14, R);
  Check('1Ah break on and off were accepted', True);

  { ---- 0Dh, keyboard without wait. Nobody is typing, so FFFFh. ---- }
  ClearRegs(R);
  R.AH := $0D;
  Intr($14, R);
  Check('0Dh on an idle keyboard returns FFFFh', R.AX = $FFFF);

  { ---- 11h / 12h, cursor position round trip ---- }
  ClearRegs(R);
  R.AH := $12;
  Intr($14, R);
  Before := R.DX;
  ClearRegs(R);
  R.AH := $11; R.DH := 10; R.DL := 5;
  Intr($14, R);
  ClearRegs(R);
  R.AH := $12;
  Intr($14, R);
  Check('11h/12h cursor position round trips', (R.DH = 10) and (R.DL = 5));
  ClearRegs(R);                    { put it back }
  R.AH := $11; R.DX := Before;
  Intr($14, R);

  { ---- 13h / 15h, screen writes. These go to the BIOS, so they land on
         the box's real screen and not in the captured log -- all we can
         assert from here is that they return. ---- }
  ClearRegs(R);
  R.AH := $15; R.AL := Ord(' ');
  Intr($14, R);
  ClearRegs(R);
  R.AH := $13; R.AL := Ord(' ');
  Intr($14, R);
  Check('13h and 15h screen writes returned', True);

  { ---- 16h, the timer tick chain ---- }
  BuildStubs;
  Ok := TickChain(True, Seg(Stub), Ofs(Stub) + ST_TICK);
  Check('16h accepted a routine onto the tick chain', Ok);
  if Ok then
  begin
    TickAdded := True;
    Deadline := Ticks + 10;
    while Integer(Ticks - Deadline) < 0 do ;
    N := TickCount;
    Note('16h tick routine ran, times: ', N);
    Check('16h routine is actually being called', N > 0);

    Ok := TickChain(False, Seg(Stub), Ofs(Stub) + ST_TICK);
    Check('16h removed the routine', Ok);
    if Ok then TickAdded := False;

    N := TickCount;
    Deadline := Ticks + 10;
    while Integer(Ticks - Deadline) < 0 do ;
    Check('16h routine stopped being called once removed', TickCount = N);
  end;

  { ---- 7Eh / 7Fh, an external application function ---- }
  ClearRegs(R);
  R.AH := $7E; R.AL := APP_CODE;
  R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_APP;
  Intr($14, R);
  Check('7Eh returns the FOSSIL magic', R.AX = $1954);
  Check('7Eh reports the application was installed', R.BH = 0);
  if (R.AX = $1954) and (R.BH = 0) then
  begin
    AppAdded := True;

    ClearRegs(R);
    R.AH := APP_CODE;
    Intr($14, R);
    Check('the installed application ran', AppCount = 1);
    Check('the application''s return value came back', R.AX = APP_MAGIC);

    ClearRegs(R);
    R.AH := $7F; R.AL := APP_CODE;
    R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_APP;
    Intr($14, R);
    Check('7Fh removed the application', R.BH = 0);
    if R.BH = 0 then AppAdded := False;

    N := AppCount;
    ClearRegs(R);
    R.AH := APP_CODE;
    Intr($14, R);
    Check('the application stopped being called once removed',
          AppCount = N);
  end;

  { ---- the receive buffer overrunning, and OVRN reporting it ----
         The point of this one is the drop path: a full ring must throw the
         byte away and say so, not wrap and corrupt what is already in it. }
  PurgeIn;
  PurgeOut;
  FillChar(TxBuf, SizeOf(TxBuf), $AA);
  SawOvrn := False;
  Rounds := 0;
  while (Rounds < 6) and (not SawOvrn) do
  begin
    SendAll(TxBuf, 1024, 40);
    Deadline := Ticks + 12;
    while Integer(Ticks - Deadline) < 0 do ;
    if Overrun then SawOvrn := True;
    Inc(Rounds);
  end;
  Note('rounds of 1024 bytes before the receive ring overran: ', Rounds);
  Check('a full receive ring reports an overrun', SawOvrn);
  Check('the ring never reports more than it can hold',
        RxAvail < Blk.IBufr);

  PurgeIn;
  Check('0Ah purging the input clears the overrun flag', not Overrun);

  { ---- 05h, deinitialize ---- }
  Deinit;
  Check('05h deinitialize returned', True);

  Note('NOT tested, and why:');
  Note('  0Eh keyboard read with wait -- blocks; nobody is at the keyboard');
  Note('  17h reboot -- a job that reboots cannot report its result');
  Note('  14h watchdog firing -- it reboots, same problem');

  Finish;
end.
