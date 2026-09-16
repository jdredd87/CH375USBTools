program fosbbs;

{ FOSBBS -- a BBS that thinks it is talking to a modem, used as the test bed
  for everything a real BBS could ask a FOSSIL driver to do.

  It believes all of the following, which is what a 1991 BBS believed, and
  none of which is true:

    * there is a modem on a serial port
    * AH=03h bit 7 of AL is DCD, and DCD means somebody is on the line
    * when DCD goes away, the caller hung up
    * to hang up yourself, drop DTR with AH=06h

  There is no modem and no serial port. The point is that this program
  cannot tell, and contains neither the word TCP nor the word telnet.

  WHAT IT COVERS, and why each is here rather than assumed:

    calls in a row    a BBS answers, hangs up and answers again for weeks.
                      One call proves nothing about the second, which is
                      where anything left over from the first turns up.
    8-BIT CLEAN       the property a BBS most depends on and the one most
                      easily broken in silence: a file transfer sends every
                      byte value, including 0FFh, which is the telnet
                      escape, and 00h, which is the NVT line-ending filler.
                      Both directions are checked against a known pattern.
    block I/O         18h and 19h, because that is what a transfer protocol
                      uses. One byte at a time through 01h/02h is the menu
                      path, not the transfer path.
    buffer accounting 1Bh under load, which is how a caller throttles.
    housekeeping      00h, 0Fh, 10h, 14h, 16h, 1Ah -- the calls a BBS makes
                      and then trusts. Exercised DURING a live call,
                      because that is when getting one wrong drops the line.
    carrier loss      the caller hanging up mid-sentence, which is the
                      normal way calls end and one a BBS must survive.

  FOSBBS [seconds]    how long to keep the line open. Default 120.

  Every wait is bounded by the BIOS tick. A BBS that waits for ever is
  correct on a real machine and a wedged one here. }

uses Dos, chtool, fosapi;

const
  VER = '0.1.0';

const
  { The tick-chain stub, built as machine code at run time.

    A routine handed to function 16h is called from inside a hardware
    interrupt with the DRIVER's DS, so a Pascal procedure is the wrong
    shape -- touching any global would write into the driver. These few
    bytes keep their counter in the same array and reach it through CS,
    which during the call is that array's own segment. Nothing to set up,
    and nothing to get wrong. }
  ST_TICK  = 0;
  ST_COUNT = 8;

  UPLOAD_N   = 2048;           { what we ask the caller to send }
  DOWNLOAD_N = 4096;           { what we send: sixteen copies of 0..255 }
  LARGE_N    = 131072;         { the endurance run: 128 KB, as a file would be }

var
  R        : Registers;
  PrevExit : Pointer;
  WaitSecs : Word;
  Callers  : Word;
  Served   : Word;
  BinOk    : Word;
  BinBad   : Word;
  HouseOk  : Word;
  HouseBad : Word;
  Dropped  : Word;          { calls that ended because the caller vanished }
  Stub     : array[0..15] of Byte;
  TickOn   : Boolean;
  Buf      : array[0..1023] of Byte;

function Ticks: Word;
begin
  Ticks := MemW[$0040:$006C];
end;

function Status: Word;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $03; R.DX := 0;
  Intr($14, R);
  Status := R.AX;
end;

function Carrier: Boolean;
begin
  Carrier := (Status and $0080) <> 0;
end;

function CharWaiting: Boolean;
begin
  CharWaiting := (Status and $0100) <> 0;
end;

function GetCh: Byte;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $02; R.DX := 0;
  Intr($14, R);
  GetCh := R.AL;
end;

procedure PutCh(B: Byte);
var Dead: Word;
begin
  Dead := Ticks + 36;
  repeat
    FillChar(R, SizeOf(R), 0);
    R.AH := $0B; R.AL := B; R.DX := 0;
    Intr($14, R);
    if R.AX = 1 then Exit;
  until (Integer(Ticks - Dead) >= 0) or (not Carrier);
end;

procedure Send(const S: ShortString);
var I: Integer;
begin
  for I := 1 to Length(S) do PutCh(Ord(S[I]));
end;

procedure SendLn(const S: ShortString);
begin
  Send(S);
  PutCh(13);
  PutCh(10);
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

procedure Flush;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $08; R.DX := 0;
  Intr($14, R);
end;

procedure PurgeIn;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $0A; R.DX := 0;
  Intr($14, R);
end;

procedure DropDtr;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $06; R.AL := 0; R.DX := 0;
  Intr($14, R);
end;

procedure RaiseDtr;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $06; R.AL := 1; R.DX := 0;
  Intr($14, R);
end;

procedure Deinit;
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $05; R.DX := 0;
  Intr($14, R);
end;

function OutFree: Word;
var I: array[0..18] of Byte;
begin
  FillChar(I, SizeOf(I), 0);
  FillChar(R, SizeOf(R), 0);
  R.AH := $1B; R.CX := SizeOf(I); R.DX := 0;
  R.ES := Seg(I); R.DI := Ofs(I);
  Intr($14, R);
  OutFree := I[14] or (Word(I[15]) shl 8);
end;

procedure BuildStub;
var W: Word;
begin
  FillChar(Stub, SizeOf(Stub), 0);
  W := Ofs(Stub) + ST_COUNT;
  Stub[ST_TICK + 0] := $2E;                    { CS: }
  Stub[ST_TICK + 1] := $FF;                    { inc word [disp16] }
  Stub[ST_TICK + 2] := $06;
  Stub[ST_TICK + 3] := Lo(W);
  Stub[ST_TICK + 4] := Hi(W);
  Stub[ST_TICK + 5] := $CB;                    { retf }
end;

function TickCount: Word;
begin
  TickCount := Stub[ST_COUNT] or (Word(Stub[ST_COUNT + 1]) shl 8);
end;

procedure TickHook(TurnOn: Boolean);
begin
  FillChar(R, SizeOf(R), 0);
  R.AH := $16;
  if TurnOn then R.AL := 1 else R.AL := 0;
  R.ES := Seg(Stub); R.DX := Ofs(Stub) + ST_TICK;
  Intr($14, R);
  if R.AX = 0 then TickOn := TurnOn;
end;

{ A tick-chain entry left behind is a far call into memory DOS has since
  reused, and the fault then lands on whatever runs NEXT rather than on this
  program -- the same shape as the dangling PS/2 callback that made one
  crash get inherited by the following one. }
procedure BbsRelease; far;
begin
  ExitProc := PrevExit;
  if TickOn then TickHook(False);
  DropDtr;
  Deinit;
end;

function GetLine(var S: ShortString; Limit: Word): Boolean;
var
  B    : Byte;
  Dead : Word;
begin
  S := '';
  Dead := Ticks + Limit;
  while True do
  begin
    if not Carrier then begin GetLine := False; Exit; end;
    if Integer(Ticks - Dead) >= 0 then begin GetLine := False; Exit; end;
    if CharWaiting then
    begin
      B := GetCh;
      Dead := Ticks + Limit;
      case B of
        13 : begin PutCh(13); PutCh(10); GetLine := True; Exit; end;
        10, 0 : ;
        8, 127 :
          if Length(S) > 0 then
          begin
            Dec(S[0]);
            PutCh(8); PutCh(32); PutCh(8);
          end;
      else
        if (B >= 32) and (B < 127) and (Length(S) < 60) then
        begin
          S := S + Chr(B);
          PutCh(B);
        end;
      end;
    end;
  end;
end;

function Three(V: Word): ShortString;
begin
  Three := Chr(48 + (V div 100) mod 10) +
           Chr(48 + (V div 10) mod 10) +
           Chr(48 + V mod 10);
end;

function Five(V: Word): ShortString;
begin
  Five := Chr(48 + (V div 10000) mod 10) + Chr(48 + (V div 1000) mod 10) +
          Chr(48 + (V div 100) mod 10) + Chr(48 + (V div 10) mod 10) +
          Chr(48 + V mod 10);
end;

{ ------------------------------------------------------------------- }
{  Download: every byte value, sixteen times over, through block       }
{  writes. If 0FFh is not doubled on the wire the caller sees a short   }
{  block; if it is doubled twice, a long one. The count alone catches   }
{  either, and the comparison says where.                              }
{ ------------------------------------------------------------------- }
procedure DoBinDown;
var
  Sent, N, I, Chunk : Word;
  Dead              : Word;
begin
  SendLn('BEGIN BINARY ' + Five(DOWNLOAD_N));
  Flush;
  Sent := 0;
  Dead := Ticks + 1080;
  while (Sent < DOWNLOAD_N) and Carrier and (Integer(Ticks - Dead) < 0) do
  begin
    Chunk := DOWNLOAD_N - Sent;
    if Chunk > SizeOf(Buf) then Chunk := SizeOf(Buf);
    for I := 0 to Chunk - 1 do Buf[I] := (Sent + I) and $FF;
    N := WriteBlock(Buf, Chunk);
    Inc(Sent, N);
    if N = 0 then
      while (OutFree < 64) and Carrier and (Integer(Ticks - Dead) < 0) do ;
  end;
  Flush;
  SendLn('');
  SendLn('END BINARY ' + Five(Sent));
  WriteLn('  sent ', Sent, ' binary bytes');
end;

{ ------------------------------------------------------------------- }
{  Upload: the caller sends a known block and we check it here. This is }
{  the direction that exercises un-doubling 0FFh, the receive ring      }
{  under load, and the window we advertise.                            }
{ ------------------------------------------------------------------- }
procedure DoBinUp;
var
  Got, N, I : Word;
  Dead      : Word;
  Bad       : Word;
  FirstBad  : Word;
  Expect    : Byte;
begin
  PurgeIn;
  SendLn('SEND ' + Five(UPLOAD_N));
  Flush;
  Got := 0;
  Bad := 0;
  FirstBad := 0;
  Dead := Ticks + 1080;
  while (Got < UPLOAD_N) and Carrier and (Integer(Ticks - Dead) < 0) do
  begin
    N := ReadBlock(Buf, SizeOf(Buf));
    if N > 0 then
    begin
      Dead := Ticks + 540;
      for I := 0 to N - 1 do
      begin
        Expect := (Got + I) and $FF;
        if Buf[I] <> Expect then
        begin
          if Bad = 0 then FirstBad := Got + I;
          Inc(Bad);
        end;
      end;
      Inc(Got, N);
    end;
  end;
  if (Got = UPLOAD_N) and (Bad = 0) then
  begin
    SendLn('UPLOAD OK ' + Five(Got));
    Inc(BinOk);
  end
  else
  begin
    SendLn('UPLOAD BAD got=' + Five(Got) + ' wrong=' + Five(Bad) +
           ' first=' + Five(FirstBad));
    Inc(BinBad);
  end;
  WriteLn('  upload: got ', Got, ' wrong ', Bad);
end;

{ ------------------------------------------------------------------- }
{  The calls a BBS makes and then trusts, exercised on a LIVE line.     }
{ ------------------------------------------------------------------- }
procedure DoHousekeeping;
var
  Before, After : Word;
  Dead          : Word;
  Ok            : Boolean;
begin
  Ok := True;

  FillChar(R, SizeOf(R), 0);
  R.AH := $00; R.AL := $E3; R.DX := 0;         { 9600 8N1 }
  Intr($14, R);
  SendLn('00h set baud     : accepted');

  FillChar(R, SizeOf(R), 0);
  R.AH := $0F; R.AL := $02; R.DX := 0;
  Intr($14, R);
  SendLn('0Fh flow control : accepted');

  FillChar(R, SizeOf(R), 0);
  R.AH := $10; R.AL := $01; R.DX := 0;
  Intr($14, R);
  SendLn('10h ctrl-C check : returns ' + Three(R.AX));

  { A real BBS turns the watchdog on so a dropped carrier reboots the
    machine. It must never fire while the line is up. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $14; R.AL := $01; R.DX := 0;
  Intr($14, R);
  FillChar(R, SizeOf(R), 0);
  R.AH := $14; R.AL := $00; R.DX := 0;
  Intr($14, R);
  SendLn('14h watchdog     : on and off, line still up');

  FillChar(R, SizeOf(R), 0);
  R.AH := $1A; R.AL := $01; R.DX := 0;
  Intr($14, R);
  FillChar(R, SizeOf(R), 0);
  R.AH := $1A; R.AL := $00; R.DX := 0;
  Intr($14, R);
  SendLn('1Ah break        : on and off');

  { The tick chain is how a BBS runs a status line and an inactivity timer.
    It must be called, and must STOP being called when removed. }
  BuildStub;
  TickHook(True);
  if TickOn then
  begin
    Dead := Ticks + 10;
    while Integer(Ticks - Dead) < 0 do ;
    Before := TickCount;
    TickHook(False);
    After := TickCount;
    Dead := Ticks + 10;
    while Integer(Ticks - Dead) < 0 do ;
    SendLn('16h tick chain   : ran ' + Five(Before) + ', stopped at ' +
           Five(After));
    if Before = 0 then Ok := False;
    if TickCount <> After then Ok := False;
  end
  else
  begin
    SendLn('16h tick chain   : REFUSED');
    Ok := False;
  end;

  SendLn('1Bh output free  : ' + Five(OutFree));

  if Carrier then SendLn('03h carrier      : still up')
  else Ok := False;

  if Ok then
  begin
    SendLn('HOUSEKEEPING OK');
    Inc(HouseOk);
  end
  else
  begin
    SendLn('HOUSEKEEPING FAILED');
    Inc(HouseBad);
  end;
end;

{ ------------------------------------------------------------------- }
{  The endurance run. 4 KB proves the path is correct; it says nothing    }
{  about what happens over a real file, where the ring wraps hundreds of  }
{  times, the sequence numbers climb past anything a Word could hold, and }
{  any slow leak has time to show. Counters here are LongInt for exactly  }
{  that reason -- 128 KB does not fit in the Word the 4 KB test used.     }
{ ------------------------------------------------------------------- }
procedure DoLarge;
var
  Sent   : LongInt;
  Chunk  : Word;
  N, I   : Word;
  Dead   : Word;
  Start  : Word;
  Secs   : Word;
  Rate   : LongInt;
begin
  SendLn('BEGIN LARGE 131072');
  Flush;
  Sent := 0;
  Start := Ticks;
  Dead := Ticks + 5400;                       { five minutes, then give up }
  while (Sent < LARGE_N) and Carrier and (Integer(Ticks - Dead) < 0) do
  begin
    if (LARGE_N - Sent) > LongInt(SizeOf(Buf)) then Chunk := SizeOf(Buf)
    else Chunk := Word(LARGE_N - Sent);
    for I := 0 to Chunk - 1 do
      Buf[I] := Byte((Sent + I) and $FF);
    N := WriteBlock(Buf, Chunk);
    if N > 0 then
    begin
      Sent := Sent + N;
      Dead := Ticks + 900;                    { progress resets the clock }
    end
    else
      while (OutFree < 64) and Carrier and (Integer(Ticks - Dead) < 0) do ;
  end;
  Flush;
  Secs := (Ticks - Start) div 18;
  if Secs = 0 then Secs := 1;
  Rate := Sent div Secs;
  SendLn('');
  SendLn('END LARGE');
  WriteLn('  large transfer: ', Sent, ' bytes in ', Secs, 's');
  WriteLn('  about ', Rate, ' bytes/second');
end;

{ Two commands that exist for a person rather than for a test harness. The
  rest of this menu checks bytes; these are the ones worth looking at. }
procedure DoTime;
var
  H, M, Sec, Hun : Word;
  Y, Mo, D, Dow  : Word;
  function Two(V: Word): ShortString;
  begin
    if V < 10 then Two := '0' + Chr(48 + V)
    else Two := Chr(48 + (V div 10) mod 10) + Chr(48 + V mod 10);
  end;
begin
  GetTime(H, M, Sec, Hun);
  GetDate(Y, Mo, D, Dow);
  SendLn('The clock on this machine says ' + Two(H) + ':' + Two(M) + ':' +
         Two(Sec));
  SendLn('and the date is ' + Two(D) + '/' + Two(Mo) + '/' +
         Two(Y mod 100) + '.');
end;

procedure DoInfo;
begin
  SendLn('');
  SendLn('FOSBBS, running on an 8086-class DOS machine.');
  SendLn('');
  SendLn('It believes there is a modem on COM1. It watches DCD to know when');
  SendLn('somebody has called, reads and writes through INT 14h, and hangs');
  SendLn('up by dropping DTR. That is all a BBS ever knew how to do.');
  SendLn('');
  SendLn('There is no modem. There is no serial port. You are connected over');
  SendLn('TCP to a FOSSIL driver sitting on a packet driver, and the carrier');
  SendLn('this program is watching is a socket being accepted.');
  SendLn('');
  SendLn('This program contains no networking code, and neither the word TCP');
  SendLn('nor the word telnet appears anywhere in it.');
end;

procedure ShowMenu;
begin
  SendLn('');
  SendLn('   [T] What time is it');
  SendLn('   [S] What is this thing');
  SendLn('   [E] Echo test');
  SendLn('   [H] Housekeeping     (the calls a BBS trusts)');
  SendLn('');
  SendLn('   These three send RAW BINARY and will look like noise:');
  SendLn('   [B] Binary download  (4 KB, 8-bit clean check)');
  SendLn('   [L] Large download   (128 KB endurance run)');
  SendLn('   [U] Binary upload    (waits for 2 KB from you)');
  SendLn('');
  SendLn('   [X] Abandon the call without cleaning up');
  SendLn('   [G] Goodbye');
  SendLn('');
  Send('Command: ');
end;

procedure DoEcho;
var S: ShortString;
begin
  SendLn('Type a line and I will send it back. Empty line ends.');
  while True do
  begin
    Send('> ');
    if not GetLine(S, 600) then Exit;
    if Length(S) = 0 then Exit;
    SendLn('You said: ' + S);
  end;
end;

procedure Session;
var
  S     : ShortString;
  Alive : Boolean;
  Dead  : Word;
begin
  Inc(Callers);
  WriteLn('  call ', Callers, ' answered');
  SendLn('');
  SendLn('=======================================');
  SendLn('  FOSBBS -- answering call ' + Three(Callers));
  SendLn('=======================================');
  SendLn('Connected. There is no modem here, but do not tell the BBS.');

  Alive := True;
  while Alive and Carrier do
  begin
    ShowMenu;
    if not GetLine(S, 900) then Break;
    if Length(S) = 0 then Continue;
    case UpCase(S[1]) of
      'T' : DoTime;
      'S' : DoInfo;
      'B' : DoBinDown;
      'L' : DoLarge;
      'X' : begin
              { Walk away mid-call, leaving the line open and the driver
                holding its handles -- which is what a BBS that has just
                crashed looks like from the driver's side. Whatever comes
                next has to clean this up; nothing here will.

                The tick-chain entry IS removed first, because a stale one
                is a far call into memory DOS is about to reuse and that
                would take the next program down for reasons unrelated to
                what is being tested. }
              SendLn('');
              SendLn('Abandoning the call. No hangup, no cleanup.');
              Flush;
              WriteLn('  abandoning the call deliberately');
              if TickOn then TickHook(False);
              ExitProc := PrevExit;
              Halt(0);
            end;
      'U' : DoBinUp;
      'H' : DoHousekeeping;
      'E' : DoEcho;
      'G' : begin
              SendLn('');
              SendLn('Goodbye. Dropping carrier.');
              Alive := False;
            end;
    else
      SendLn('No such command: ' + S);
    end;
  end;

  if not Carrier then
  begin
    { The normal way a call ends: somebody closed their terminal. A BBS has
      to notice mid-sentence and give the line back, not sit writing into a
      connection that is gone. }
    Inc(Dropped);
    WriteLn('  the caller hung up');
  end
  else
    WriteLn('  we hung up');

  Flush;
  Inc(Served);
  DropDtr;

  { Wait for the line to actually come down before listening again, or the
    next turn round the loop sees a carrier that has not dropped yet and
    answers a call nobody made. }
  Dead := Ticks + 90;
  while Carrier and (Integer(Ticks - Dead) < 0) do ;
  RaiseDtr;
end;

var
  VecSeg, VecOfs, Sig : Word;
  Dead                : Word;
  Code                : Integer;

begin
  Banner('FOSBBS', VER, 'a BBS that thinks it has a modem');

  WaitSecs := 120;
  if ParamCount >= 1 then
  begin
    Val(ParamStr(1), WaitSecs, Code);
    if (Code <> 0) or (WaitSecs = 0) then WaitSecs := 120;
  end;

  Callers  := 0;
  Served   := 0;
  BinOk    := 0;
  BinBad   := 0;
  HouseOk  := 0;
  HouseBad := 0;
  Dropped  := 0;
  TickOn   := False;
  PrevExit := ExitProc;
  ExitProc := @BbsRelease;

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
  Check('the line opened', R.AX = $1954);

  RaiseDtr;
  WriteLn('  holding the line open for ', WaitSecs, ' seconds');
  Dead := Ticks + WaitSecs * 18;

  while Integer(Ticks - Dead) < 0 do
    if Carrier then Session;

  Note('calls answered: ', Callers);
  Note('calls served to the end: ', Served);
  Note('binary checks passed: ', BinOk);
  Note('binary checks failed: ', BinBad);
  Note('housekeeping passed: ', HouseOk);
  Note('housekeeping failed: ', HouseBad);
  Note('calls the caller dropped: ', Dropped);

  Check('at least two calls were answered', Callers >= 2);
  Check('a dropped caller was noticed', Dropped > 0);
  Check('every call was served to the end', Served = Callers);
  Check('no binary upload failed', BinBad = 0);
  Check('at least one binary upload was checked', BinOk > 0);
  Check('no housekeeping round failed', HouseBad = 0);
  Check('at least one housekeeping round ran', HouseOk > 0);

  if TickOn then TickHook(False);
  Check('no tick-chain entry was left behind', not TickOn);

  DropDtr;
  Deinit;
  ExitProc := PrevExit;

  Finish;
end.
