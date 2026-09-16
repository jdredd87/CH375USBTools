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

var
  Blk  : TFosInfo;
  Buf  : array[0..2047] of Byte;

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
      L := L + '<' + HexB(B) + '>';
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
  PurgeIn;
  PurgeOut;
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

begin
  Banner('FOSAT', VER, 'talk to a modem through INT 14h');

  if not Present then
  begin
    Note('no FOSSIL driver is loaded');
    Check('a FOSSIL driver is present', False);
    Finish;
    Halt(Failures);
  end;

  Check('04h initialize returns 1954h', Init);

  Info(Blk);
  Note('input buffer: ', Blk.IBufr);
  Note('output buffer: ', Blk.OBufr);

  { AH=03h, AL bit 7: is there a carrier? On an idle modem there is not,
    and that is the correct answer rather than a fault. }
  Note('status word: ' + HexW(Status));

  Round('AT', 36, 'AT');
  Round('ATE0', 36, 'ATE0 (stop the echo)');
  Round('ATI0', 36, 'ATI0');
  Round('ATI4', 180, 'ATI4 -- the long one');

  Deinit;
  Finish;
end.
