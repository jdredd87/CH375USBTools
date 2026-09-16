program fosat;

{ FOSAT -- talk to a modem through INT 14h and nothing else.

  This is the end-to-end proof for the CH375 transport: an AT command goes
  out through FOSSIL function 19h, the reply comes back through 18h, and
  nothing in this program knows a CH375 exists. If it works, the whole
  stack works -- application, FOSSIL core, ring buffers, timer poll, bulk
  OUT, bulk IN, FTDI framing, modem.

  It also starts measuring, because the open question in this project is
  not whether the transport is correct but how fast it can be. ATI4 on a
  USRobotics Courier is a long multi-line dump -- several hundred bytes in
  one burst -- which is exactly the shape that shows whether the adapter is
  batching properly or forwarding a byte at a time.

  Nothing here blocks. Every wait is bounded by the BIOS tick, so a modem
  that says nothing costs a reported zero rather than a wedged machine. }

uses Dos, chtool, fosapi;

const
  VER = '0.1.0';

type
  TFosInfo = record
    StrSiz : Word;  MajVer: Byte;  MinVer: Byte;
    IdOfs  : Word;  IdSeg : Word;
    IBufr  : Word;  IFree : Word;
    OBufr  : Word;  OFree : Word;
    SWidth : Byte;  SHeight: Byte; Baud: Byte;
  end;

const
  HexDig : array[0..15] of Char = '0123456789ABCDEF';

var
  R    : Registers;
  Info : TFosInfo;
  Buf  : array[0..2047] of Byte;

function HexW(W: Word): ShortString;
begin
  HexW := HexDig[(W shr 12) and 15] + HexDig[(W shr 8) and 15] +
          HexDig[(W shr 4) and 15] + HexDig[W and 15];
end;

function Ticks: Word;
begin
  Ticks := MemW[$0040:$006C];
end;

procedure FosGetInfo(var I: TFosInfo);
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
  if I.IBufr = 0 then RxAvail := 0 else RxAvail := I.IBufr - 1 - I.IFree;
end;

procedure Purge;
begin
  FillChar(R, SizeOf(R), 0); R.AH := $0A; R.DX := 0; Intr($14, R);
  FillChar(R, SizeOf(R), 0); R.AH := $09; R.DX := 0; Intr($14, R);
end;

function WriteBlock(var B; Len: Word): Word;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $19; R.CX := Len; R.DX := 0;
  R.ES := Seg(B); R.DI := Ofs(B);
  Intr($14, R);
  WriteBlock := R.AX;
end;

function ReadBlock(var B; Max: Word): Word;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $18; R.CX := Max; R.DX := 0;
  R.ES := Seg(B); R.DI := Ofs(B);
  Intr($14, R);
  ReadBlock := R.AX;
end;

procedure SendStr(const S: ShortString);
var
  T    : array[0..79] of Byte;
  I, N : Word;
  Sent : Word;
  Dead : Word;
begin
  N := Length(S);
  for I := 1 to N do T[I - 1] := Ord(S[I]);
  Sent := 0;
  Dead := Ticks + 36;
  while (Sent < N) and (Integer(Ticks - Dead) < 0) do
    Inc(Sent, WriteBlock(T[Sent], N - Sent));
end;

{ Collect for up to Limit ticks, stopping early once Quiet ticks have gone
  by with nothing new -- which is how you read a modem whose reply length
  you do not know in advance. }
function Collect(Limit, Quiet: Word; var Elapsed: Word): Word;
var
  Total, N  : Word;
  Dead, Last: Word;
  Start     : Word;
begin
  Total := 0;
  Start := Ticks;
  Dead  := Start + Limit;
  Last  := Ticks;
  while Integer(Ticks - Dead) < 0 do
  begin
    N := ReadBlock(Buf[Total], SizeOf(Buf) - 1 - Total);
    if N > 0 then
    begin
      Inc(Total, N);
      Last := Ticks;
      if Total >= SizeOf(Buf) - 1 then Dead := Ticks;
    end
    else if Integer(Ticks - (Last + Quiet)) >= 0 then Dead := Ticks;
  end;
  Elapsed := Ticks - Start;
  Collect := Total;
end;

{ Print what came back, one line per CR, with anything unprintable shown as
  a hex escape so a framing fault looks like a framing fault rather than
  like a blank screen. }
procedure ShowReply(N: Word);
var
  I : Word;
  L : ShortString;
  B : Byte;
begin
  L := '';
  for I := 0 to N - 1 do
  begin
    B := Buf[I];
    if (B = 13) or (B = 10) then
    begin
      if Length(L) > 0 then
      begin
        WriteLn('  < ', L);
        L := '';
      end;
    end
    else if (B >= 32) and (B < 127) then
    begin
      L := L + Chr(B);
      if Length(L) > 70 then
      begin
        WriteLn('  < ', L);
        L := '';
      end;
    end
    else
      L := L + '<' + HexDig[(B shr 4) and 15] + HexDig[B and 15] + '>';
  end;
  if Length(L) > 0 then WriteLn('  < ', L);
end;

procedure Round(const Cmd: ShortString; Limit: Word; const What: ShortString);
var
  N, El : Word;
  Bps   : LongInt;
begin
  WriteLn;
  WriteLn('--- ', What, ' ---');
  Purge;
  SendStr(Cmd + #13);
  N := Collect(Limit, 8, El);
  ShowReply(N);
  Note('bytes back: ', N);
  Note('ticks taken: ', El);
  if (El > 0) and (N > 0) then
  begin
    { 18.2 ticks a second, kept in integers: bytes * 182 / (ticks * 10) }
    Bps := (LongInt(N) * 182) div (LongInt(El) * 10);
    Note('bytes/second: ', Bps);
  end;
  Check(What + ' produced a reply', N > 0);
end;

var
  VecSeg, VecOfs, Sig: Word;

begin
  Banner('FOSAT', VER, 'talk to a modem through INT 14h');

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

  FillChar(R, SizeOf(R), 0);
  R.AH := $04; R.DX := 0; R.BX := $4F50;
  Intr($14, R);
  Check('04h initialize returns 1954h', R.AX = $1954);

  FosGetInfo(Info);
  Note('input buffer: ', Info.IBufr);
  Note('output buffer: ', Info.OBufr);

  { AH=03h, AL bit 7: is there a carrier? On an idle modem there is not,
    and that is the correct answer rather than a fault. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $03; R.DX := 0;
  Intr($14, R);
  Note('status word: ' + HexW(R.AX));

  Round('AT', 36, 'AT');
  Round('ATE0', 36, 'ATE0 (stop the echo)');
  Round('ATI0', 36, 'ATI0');
  Round('ATI4', 180, 'ATI4 -- the long one');

  FillChar(R, SizeOf(R), 0);
  R.AH := $05; R.DX := 0;
  Intr($14, R);

  Finish;
end.
