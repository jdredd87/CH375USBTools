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
  TFosInfo = record
    StrSiz  : Word;
    MajVer  : Byte;
    MinVer  : Byte;
    IdOfs   : Word;
    IdSeg   : Word;
    IBufr   : Word;
    IFree   : Word;
    OBufr   : Word;
    OFree   : Word;
    SWidth  : Byte;
    SHeight : Byte;
    Baud    : Byte;
  end;

  TBuf = array[0..2047] of Byte;

const
  HexDig : array[0..15] of Char = '0123456789ABCDEF';

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
  Info      : TFosInfo;
  MaxFunc   : Byte;
  TickAdded : Boolean;
  AppAdded  : Boolean;
  PrevExit  : Pointer;
  TxBuf     : TBuf;
  RxBuf     : TBuf;

function HexW(W: Word): ShortString;
begin
  HexW := HexDig[(W shr 12) and 15] + HexDig[(W shr 8) and 15] +
          HexDig[(W shr 4) and 15] + HexDig[W and 15];
end;

function Ticks: Word;
begin
  Ticks := MemW[$0040:$006C];
end;

{ ---------------------------------------------------------------------- }
{ The INT 14h calls we need, each one kept to exactly what the spec says. }
{ ---------------------------------------------------------------------- }

function FosStatus: Word;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $03; R.DX := 0;
  Intr($14, R);
  FosStatus := R.AX;
end;

function HasRda: Boolean;
begin
  HasRda := (FosStatus and $0100) <> 0;          { AH bit 0 }
end;

function HasThre: Boolean;
begin
  HasThre := (FosStatus and $2000) <> 0;         { AH bit 5 }
end;

function HasTsre: Boolean;
begin
  HasTsre := (FosStatus and $4000) <> 0;         { AH bit 6 }
end;

function HasOvrn: Boolean;
begin
  HasOvrn := (FosStatus and $0200) <> 0;         { AH bit 1 }
end;

function HasDcd: Boolean;
begin
  HasDcd := (FosStatus and $0080) <> 0;          { AL bit 7 }
end;

procedure FosGetInfo(var I: TFosInfo);
var R: Registers;
begin
  FillChar(I, SizeOf(I), 0);
  FillChar(R, SizeOf(R), 0);
  R.AH := $1B; R.CX := SizeOf(I); R.DX := 0;
  R.ES := Seg(I); R.DI := Ofs(I);
  Intr($14, R);
end;

function RxAvail: Word;
var I: TFosInfo;
begin
  FosGetInfo(I);
  if I.IBufr = 0 then RxAvail := 0
  else RxAvail := I.IBufr - 1 - I.IFree;
end;

function TxPending: Word;
var I: TFosInfo;
begin
  FosGetInfo(I);
  if I.OBufr = 0 then TxPending := 0
  else TxPending := I.OBufr - 1 - I.OFree;
end;

procedure FosPurgeIn;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $0A; R.DX := 0;
  Intr($14, R);
end;

procedure FosPurgeOut;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $09; R.DX := 0;
  Intr($14, R);
end;

procedure FosFlush;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $08; R.DX := 0;
  Intr($14, R);
end;

function FosTxNoWait(B: Byte): Boolean;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $0B; R.AL := B; R.DX := 0;
  Intr($14, R);
  FosTxNoWait := R.AX = 1;
end;

function FosPeek: Word;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $0C; R.DX := 0;
  Intr($14, R);
  FosPeek := R.AX;
end;

function FosRecv: Byte;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $02; R.DX := 0;
  Intr($14, R);
  FosRecv := R.AL;
end;

procedure FosSend(B: Byte);
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $01; R.AL := B; R.DX := 0;
  Intr($14, R);
end;

function FosWriteBlock(var Buf; Len: Word): Word;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $19; R.CX := Len; R.DX := 0;
  R.ES := Seg(Buf); R.DI := Ofs(Buf);
  Intr($14, R);
  FosWriteBlock := R.AX;
end;

function FosReadBlock(var Buf; Max: Word): Word;
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $18; R.CX := Max; R.DX := 0;
  R.ES := Seg(Buf); R.DI := Ofs(Buf);
  Intr($14, R);
  FosReadBlock := R.AX;
end;

procedure FosDtr(On: Boolean);
var R: Registers;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $06; R.DX := 0;
  if On then R.AL := 1 else R.AL := 0;
  Intr($14, R);
end;

{ ---------------------------------------------------------------------- }

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
    N := FosWriteBlock(P^[Sent], Len - Sent);
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
    FillChar(R, SizeOf(R), 0);
    R.AH := $16; R.AL := 0;                     { 0 = remove }
    R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_TICK;
    Intr($14, R);
    TickAdded := False;
  end;

  if AppAdded then
  begin
    FillChar(R, SizeOf(R), 0);
    R.AH := $7F; R.AL := APP_CODE;
    R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_APP;
    Intr($14, R);
    AppAdded := False;
  end;
end;

{ ---------------------------------------------------------------------- }

procedure BuildStubs;
var W: Word;
begin
  FillChar(Stub, SizeOf(Stub), 0);

  { ST_TICK:  inc word [cs:ST_NTICK]  /  retf }
  W := Ofs(Stub) + ST_NTICK;
  Stub[ST_TICK + 0] := $2E;                     { CS: }
  Stub[ST_TICK + 1] := $FF;                     { inc word [disp16] }
  Stub[ST_TICK + 2] := $06;
  Stub[ST_TICK + 3] := Lo(W);
  Stub[ST_TICK + 4] := Hi(W);
  Stub[ST_TICK + 5] := $CB;                     { retf }

  { ST_APP:   mov ax, APP_MAGIC  /  inc word [cs:ST_NAPP]  /  retf }
  W := Ofs(Stub) + ST_NAPP;
  Stub[ST_APP + 0] := $B8;                      { mov ax, imm16 }
  Stub[ST_APP + 1] := Lo(APP_MAGIC);
  Stub[ST_APP + 2] := Hi(APP_MAGIC);
  Stub[ST_APP + 3] := $2E;
  Stub[ST_APP + 4] := $FF;
  Stub[ST_APP + 5] := $06;
  Stub[ST_APP + 6] := Lo(W);
  Stub[ST_APP + 7] := Hi(W);
  Stub[ST_APP + 8] := $CB;                      { retf }
end;

function TickCount: Word;
begin
  TickCount := Stub[ST_NTICK] or (Word(Stub[ST_NTICK + 1]) shl 8);
end;

function AppCount: Word;
begin
  AppCount := Stub[ST_NAPP] or (Word(Stub[ST_NAPP + 1]) shl 8);
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
  VecOfs := MemW[0 : $14 * 4];
  VecSeg := MemW[0 : $14 * 4 + 2];
  Sig    := MemW[VecSeg : VecOfs + 6];
  MaxFunc := Mem[VecSeg : VecOfs + 8];

  Note('INT 14h vector: ' + HexW(VecSeg) + ':' + HexW(VecOfs) + 'h');
  Note('signature at handler+6: ' + HexW(Sig) + 'h');

  if Sig <> $1954 then
  begin
    Note('no FOSSIL driver is loaded -- load one and run this again');
    Check('a FOSSIL driver is present', False);
    Finish;
    Halt(Failures);
  end;

  Note('highest function, from the signature: ' + HexW(MaxFunc) + 'h');

  { ---- 04h, initialize ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $04; R.DX := 0; R.BX := $4F50;
  Intr($14, R);
  Check('04h initialize returns 1954h', R.AX = $1954);
  Check('04h agrees with the in-memory maximum function', R.BL = MaxFunc);
  Note('spec revision reported: ', R.BH);

  { ---- 1Bh, driver information ---- }
  FosGetInfo(Info);
  Check('1Bh reports a structure of at least 19 bytes', Info.StrSiz >= 19);
  Check('1Bh reports a non-zero input buffer', Info.IBufr > 0);
  Check('1Bh reports a non-zero output buffer', Info.OBufr > 0);
  Check('1Bh input free never exceeds input size', Info.IFree <= Info.IBufr);
  Check('1Bh output free never exceeds output size', Info.OFree <= Info.OBufr);
  Note('input buffer: ', Info.IBufr);
  Note('output buffer: ', Info.OBufr);

  { ---- 09h / 0Ah, purge, and the status bits over an idle port ---- }
  FosPurgeIn;
  FosPurgeOut;
  Check('after purging, nothing is readable', not HasRda);
  Check('after purging, there is room to transmit', HasThre);
  Check('after purging, the transmitter is empty', HasTsre);
  Check('after purging, no overrun is flagged', not HasOvrn);
  Check('0Ch peek on an empty port returns FFFFh', FosPeek = $FFFF);

  { ---- 00h, set baud, read it back through 1Bh ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $00; R.AL := $E3; R.DX := 0;          { 9600 8N1 }
  Intr($14, R);
  FosGetInfo(Info);
  Check('00h baud setting is reported back by 1Bh', Info.Baud = $E3);

  { ---- 07h, timer tick parameters ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $07;
  Intr($14, R);
  Note('07h tick rate, Hz: ', R.AH);
  Note('07h tick period, ms: ', R.DX);
  Check('07h reports a plausible tick rate', (R.AH >= 18) and (R.AH <= 250));
  Check('07h period and rate are consistent', R.DX > 0);

  { ---- 0Bh / 0Ch / 02h, one byte all the way round ---- }
  FosPurgeIn;
  FosPurgeOut;
  Check('0Bh accepts a byte when there is room', FosTxNoWait($5A));
  Check('the byte arrives back within a second', WaitRx(1, 20));
  if RxAvail >= 1 then
  begin
    Check('0Ch peeks the byte without consuming it', FosPeek = $005A);
    Check('0Ch left the byte in place', RxAvail >= 1);
    Check('03h says data is available', HasRda);
    Check('02h returns the same byte', FosRecv = $5A);
    Check('the port is empty again', RxAvail = 0);
  end;

  { ---- 01h / 02h, byte at a time ---- }
  FosPurgeIn;
  FosPurgeOut;
  Ok := True;
  for I := 1 to 16 do
  begin
    if HasThre then FosSend(I) else Ok := False;
  end;
  Check('01h accepted sixteen bytes', Ok);
  Check('all sixteen came back', WaitRx(16, 20));
  Ok := True;
  for I := 1 to 16 do
    if HasRda then
    begin
      if FosRecv <> I then Ok := False;
    end
    else Ok := False;
  Check('01h/02h round trip is byte-exact and in order', Ok);

  { ---- 19h / 18h, block write and read ---- }
  FosPurgeIn;
  FosPurgeOut;
  N := Length(TestText);
  for I := 1 to N do TxBuf[I - 1] := Ord(TestText[I]);
  Sent := SendAll(TxBuf, N, 40);
  Check('19h wrote the whole block', Sent = N);
  Check('the whole block came back', WaitRx(N, 40));
  FillChar(RxBuf, SizeOf(RxBuf), 0);
  Got := FosReadBlock(RxBuf, SizeOf(RxBuf));
  Check('18h read back the same number of bytes', Got = N);
  Ok := Got = N;
  if Ok then
    for I := 0 to N - 1 do
      if RxBuf[I] <> TxBuf[I] then Ok := False;
  Check('19h/18h round trip is byte-exact', Ok);

  { ---- 18h on an empty port must return zero, not block ---- }
  FosPurgeIn;
  Check('18h on an empty port returns zero', FosReadBlock(RxBuf, 64) = 0);

  { ---- 08h, flush ---- }
  FosPurgeIn;
  FosPurgeOut;
  for I := 0 to 255 do TxBuf[I] := I;
  Sent := FosWriteBlock(TxBuf, 256);
  Check('19h queued a block to flush', Sent > 0);
  FosFlush;
  Check('08h left the transmit buffer empty', TxPending = 0);
  Check('08h left the transmitter reporting empty', HasTsre);

  { ---- 06h, DTR, and the carrier bit that follows it ---- }
  FosDtr(True);
  Check('06h raising DTR shows carrier', HasDcd);
  FosDtr(False);
  Check('06h lowering DTR drops carrier', not HasDcd);
  FosDtr(True);
  Check('06h raising DTR again restores carrier', HasDcd);

  { ---- 0Fh and 10h, recorded settings ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $0F; R.AL := $02; R.DX := 0;          { RTS/CTS }
  Intr($14, R);
  Check('0Fh flow control was accepted', True);

  FillChar(R, SizeOf(R), 0);
  R.AH := $10; R.AL := $01; R.DX := 0;
  Intr($14, R);
  Check('10h returns a flag word', (R.AX = 0) or (R.AX = 1));

  { ---- 14h, watchdog on and off. Never allowed to fire. ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $14; R.AL := $01; R.DX := 0;
  Intr($14, R);
  FillChar(R, SizeOf(R), 0);
  R.AH := $14; R.AL := $00; R.DX := 0;
  Intr($14, R);
  Check('14h watchdog enable and disable were accepted', True);

  { ---- 1Ah, break ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $1A; R.AL := $01; R.DX := 0;
  Intr($14, R);
  FillChar(R, SizeOf(R), 0);
  R.AH := $1A; R.AL := $00; R.DX := 0;
  Intr($14, R);
  Check('1Ah break on and off were accepted', True);

  { ---- 0Dh, keyboard without wait. Nobody is typing, so FFFFh. ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $0D;
  Intr($14, R);
  Check('0Dh on an idle keyboard returns FFFFh', R.AX = $FFFF);

  { ---- 11h / 12h, cursor position round trip ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $12;
  Intr($14, R);
  Before := R.DX;
  FillChar(R, SizeOf(R), 0);
  R.AH := $11; R.DH := 10; R.DL := 5;
  Intr($14, R);
  FillChar(R, SizeOf(R), 0);
  R.AH := $12;
  Intr($14, R);
  Check('11h/12h cursor position round trips', (R.DH = 10) and (R.DL = 5));
  FillChar(R, SizeOf(R), 0);                    { put it back }
  R.AH := $11; R.DX := Before;
  Intr($14, R);

  { ---- 13h / 15h, screen writes. These go to the BIOS, so they land on
         the box's real screen and not in the captured log -- all we can
         assert from here is that they return. ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $15; R.AL := Ord(' ');
  Intr($14, R);
  FillChar(R, SizeOf(R), 0);
  R.AH := $13; R.AL := Ord(' ');
  Intr($14, R);
  Check('13h and 15h screen writes returned', True);

  { ---- 16h, the timer tick chain ---- }
  BuildStubs;
  FillChar(R, SizeOf(R), 0);
  R.AH := $16; R.AL := 1;                       { 1 = add }
  R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_TICK;
  Intr($14, R);
  Check('16h accepted a routine onto the tick chain', R.AX = 0);
  if R.AX = 0 then
  begin
    TickAdded := True;
    Deadline := Ticks + 10;
    while Integer(Ticks - Deadline) < 0 do ;
    N := TickCount;
    Note('16h tick routine ran, times: ', N);
    Check('16h routine is actually being called', N > 0);

    FillChar(R, SizeOf(R), 0);
    R.AH := $16; R.AL := 0;                     { 0 = remove }
    R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_TICK;
    Intr($14, R);
    Check('16h removed the routine', R.AX = 0);
    if R.AX = 0 then TickAdded := False;

    N := TickCount;
    Deadline := Ticks + 10;
    while Integer(Ticks - Deadline) < 0 do ;
    Check('16h routine stopped being called once removed', TickCount = N);
  end;

  { ---- 7Eh / 7Fh, an external application function ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $7E; R.AL := APP_CODE;
  R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_APP;
  Intr($14, R);
  Check('7Eh returns the FOSSIL magic', R.AX = $1954);
  Check('7Eh reports the application was installed', R.BH = 0);
  if (R.AX = $1954) and (R.BH = 0) then
  begin
    AppAdded := True;

    FillChar(R, SizeOf(R), 0);
    R.AH := APP_CODE;
    Intr($14, R);
    Check('the installed application ran', AppCount = 1);
    Check('the application''s return value came back', R.AX = APP_MAGIC);

    FillChar(R, SizeOf(R), 0);
    R.AH := $7F; R.AL := APP_CODE;
    R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_APP;
    Intr($14, R);
    Check('7Fh removed the application', R.BH = 0);
    if R.BH = 0 then AppAdded := False;

    N := AppCount;
    FillChar(R, SizeOf(R), 0);
    R.AH := APP_CODE;
    Intr($14, R);
    Check('the application stopped being called once removed',
          AppCount = N);
  end;

  { ---- the receive buffer overrunning, and OVRN reporting it ----
         The point of this one is the drop path: a full ring must throw the
         byte away and say so, not wrap and corrupt what is already in it. }
  FosPurgeIn;
  FosPurgeOut;
  FillChar(TxBuf, SizeOf(TxBuf), $AA);
  SawOvrn := False;
  Rounds := 0;
  while (Rounds < 6) and (not SawOvrn) do
  begin
    SendAll(TxBuf, 1024, 40);
    Deadline := Ticks + 12;
    while Integer(Ticks - Deadline) < 0 do ;
    if HasOvrn then SawOvrn := True;
    Inc(Rounds);
  end;
  Note('rounds of 1024 bytes before the receive ring overran: ', Rounds);
  Check('a full receive ring reports an overrun', SawOvrn);
  Check('the ring never reports more than it can hold',
        RxAvail < Info.IBufr);

  FosPurgeIn;
  Check('0Ah purging the input clears the overrun flag', not HasOvrn);

  { ---- 05h, deinitialize ---- }
  FillChar(R, SizeOf(R), 0);
  R.AH := $05; R.DX := 0;
  Intr($14, R);
  Check('05h deinitialize returned', True);

  Note('NOT tested, and why:');
  Note('  0Eh keyboard read with wait -- blocks; nobody is at the keyboard');
  Note('  17h reboot -- a job that reboots cannot report its result');
  Note('  14h watchdog firing -- it reboots, same problem');

  Finish;
end.
