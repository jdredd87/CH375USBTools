program pkttest;
{ PKTTEST -- prove a packet driver transmits and receives, on the vector you
  name.  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  This is the test tool for USBPKT, and it exists because the alternative was
  borrowing somebody else's.  mTCP is an excellent stack and a poor probe:
  it finds its driver through a config file, so testing the CH375 adapter
  meant pointing MTCPCFG at a second config for the duration and pointing it
  back afterwards.  Two adapters, one environment variable, and a machine
  that is administered over the other one -- that arrangement only has to be
  got wrong once.

  So PKTTEST takes the vector as an argument.  There is no scan, no config
  file, and no default that could reach the wrong card by accident.  mTCP
  stays pinned to the working NE2000 at 60h and is never touched again.

    PKTTEST /M=<my ip> [/I=hex] [/T=<target ip>] [/S=secs] [/L] [/X]

      /M=a.b.c.d  the address to speak as.  Required: this borrows an
                  address rather than being given one, so pick one that is
                  free on your network.
      /I=hex      vector, default 65
      /T=a.b.c.d  ARP for this address and wait for the answer
      /S=secs     how long to wait or listen, default 5
      /N=count    repeat the ARP this many times and report the
                  average round trip.  One exchange is far shorter
                  than the 55ms BIOS tick, so the only honest way
                  to time it is to do a lot of them.
      /L          listen instead: show every frame that arrives
      /R          listen AND answer: reply to ARP for /M, and to pings.
                  With this running the adapter is pingable from another
                  machine, which is the only way to prove it takes UNICAST
                  traffic -- a driver can receive every broadcast on the
                  wire and still drop everything addressed to itself.
      /X          hex-dump each frame as well

  /L is the one to reach for when a driver is suspected of receiving
  rubbish.  It asks for every protocol and prints what turns up, so the
  question "is anything coming back at all, and does it look like Ethernet"
  gets a direct answer instead of an inference from a failed ping.

  Exit codes: 0 ok, 1 no driver on that vector, 2 access_type refused,
  3 nothing answered, 4 bad arguments }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, pktapi;

const
  VER = '1.0.0';
  ETH_ARP  = $0806;
  ETH_IP   = $0800;

var
  Vec:     Byte = $65;
  Secs:    Word = 5;
  MyIp:    TIp;
  Target:  TIp;
  HaveMy:  Boolean = False;
  HaveTgt: Boolean = False;
  Reps:    Word    = 1;
  Listen:  Boolean = False;
  Dump:    Boolean = False;
  Respond: Boolean = False;

procedure Usage;
begin
  Banner('PKTTEST', VER, 'packet driver send/receive test on a named vector');
  WriteLn;
  WriteLn('  PKTTEST /M=<my ip> [/I=hex] [/T=<target ip>] [/S=secs] [/L] [/X]');
  WriteLn;
  WriteLn('  /M=a.b.c.d  the address to speak as (required)');
  WriteLn('  /I=hex      vector, default 65');
  WriteLn('  /T=a.b.c.d  ARP for this address and wait for the answer');
  WriteLn('  /S=secs     how long to wait or listen, default 5');
  WriteLn('  /N=count    repeat and report the average round trip');
  WriteLn('  /L          listen: show every frame that arrives');
  WriteLn('  /R          listen and answer ARP and pings for /M');
  WriteLn('  /X          hex-dump each frame too');
  WriteLn('  /?          this screen');
  WriteLn;
  WriteLn('The vector is an argument and there is no scan, so this cannot');
  WriteLn('reach the wrong adapter by accident.  That is the whole point:');
  WriteLn('mTCP stays pointed at the network the machine is administered');
  WriteLn('over, permanently, and testing the other card never disturbs it.');
  WriteLn;
  WriteLn('/L is what to use when a driver is suspected of receiving');
  WriteLn('rubbish -- it asks for every protocol and prints what arrives.');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K, R: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/L') or (A = '-L') then Listen := True
    else if (A = '/R') or (A = '-R') then begin Listen := True; Respond := True; end
    else if (A = '/X') or (A = '-X') then Dump := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); R := Copy(A, 4, 250);
      if K = '/I=' then
      begin
        Val('$' + R, V, Code);
        if Code = 0 then Vec := Byte(V);
      end
      else if K = '/N=' then
      begin
        Val(R, V, Code);
        if Code = 0 then Reps := Word(V);
      end
      else if K = '/S=' then
      begin
        Val(R, V, Code);
        if Code = 0 then Secs := Word(V);
      end
      else if K = '/M=' then HaveMy  := ParseIp(R, MyIp)
      else if K = '/T=' then HaveTgt := ParseIp(R, Target);
    end;
  end;
end;

{ ------------------------------------------------------------------------ }

var
  Tx: TFrame;
  Rx: TFrame;

procedure BuildArp;
var I: Integer;
begin
  FillChar(Tx, SizeOf(Tx), 0);
  for I := 0 to 5 do Tx[I] := $FF;                  { broadcast }
  for I := 0 to 5 do Tx[6 + I] := PktMyMac[I];
  Tx[12] := Hi(ETH_ARP); Tx[13] := Lo(ETH_ARP);
  Tx[14] := 0; Tx[15] := 1;                         { htype ethernet }
  Tx[16] := Hi(ETH_IP); Tx[17] := Lo(ETH_IP);       { ptype ipv4 }
  Tx[18] := 6; Tx[19] := 4;                         { hlen, plen }
  Tx[20] := 0; Tx[21] := 1;                         { oper = request }
  for I := 0 to 5 do Tx[22 + I] := PktMyMac[I];
  for I := 0 to 3 do Tx[28 + I] := MyIp[I];
  { target hardware address stays zero -- that is what we are asking for }
  for I := 0 to 3 do Tx[38 + I] := Target[I];
end;

function EthType(const F: TFrame): Word;
begin
  EthType := (Word(F[12]) shl 8) or F[13];
end;

function TypeName(T: Word): ShortString;
begin
  case T of
    $0800: TypeName := 'IPv4';
    $0806: TypeName := 'ARP';
    $0835: TypeName := 'RARP';
    $86DD: TypeName := 'IPv6';
    $8100: TypeName := 'VLAN';
  else
    if T <= 1500 then TypeName := '802.3 len ' + Hex4(T)
                 else TypeName := 'type ' + Hex4(T);
  end;
end;

procedure ShowFrame(const F: TFrame; Len: Word);
var Src, Dst: TMac; I: Integer;
begin
  for I := 0 to 5 do begin Dst[I] := F[I]; Src[I] := F[6 + I]; end;
  WriteLn('  ', MacStr(Src), ' -> ', MacStr(Dst), '  ',
          TypeName(EthType(F)), '  ', Len, ' bytes');
  if Dump then HexDump(F, Len, '    ');
end;

{ ---- answering ----------------------------------------------------------

  Enough of a host to be pinged, and no more.  ARP so the other side can
  find us, and ICMP echo so it has something to ask.  There is no IP stack
  here and there is not going to be one; this is the smallest thing that
  makes the adapter answer to its address, because receiving broadcasts
  proves much less than it appears to. }

function ForUs(const F: TFrame; At: Integer): Boolean;
var I: Integer;
begin
  ForUs := False;
  for I := 0 to 3 do
    if F[At + I] <> MyIp[I] then Exit;
  ForUs := True;
end;

{ Ones-complement sum over Len bytes at Ofs, folded and inverted. }
function Checksum(const F: TFrame; Ofs, Len: Word): Word;
var Sum: LongInt; I: Word;
begin
  Sum := 0;
  I := 0;
  while I + 1 < Len do
  begin
    Sum := Sum + (LongInt(F[Ofs + I]) shl 8) + F[Ofs + I + 1];
    Inc(I, 2);
  end;
  if I < Len then Sum := Sum + (LongInt(F[Ofs + I]) shl 8);
  while (Sum shr 16) <> 0 do Sum := (Sum and $FFFF) + (Sum shr 16);
  Checksum := Word(not Sum);
end;

procedure AnswerArp(const F: TFrame);
var I: Integer;
begin
  FillChar(Tx, SizeOf(Tx), 0);
  for I := 0 to 5 do Tx[I]      := F[6 + I];       { back to the asker }
  for I := 0 to 5 do Tx[6 + I]  := PktMyMac[I];
  Tx[12] := Hi(ETH_ARP); Tx[13] := Lo(ETH_ARP);
  Tx[14] := 0; Tx[15] := 1;
  Tx[16] := Hi(ETH_IP); Tx[17] := Lo(ETH_IP);
  Tx[18] := 6; Tx[19] := 4;
  Tx[20] := 0; Tx[21] := 2;                        { reply }
  for I := 0 to 5 do Tx[22 + I] := PktMyMac[I];
  for I := 0 to 3 do Tx[28 + I] := MyIp[I];
  for I := 0 to 5 do Tx[32 + I] := F[22 + I];      { his hardware address }
  for I := 0 to 3 do Tx[38 + I] := F[28 + I];      { his protocol address }
  PktSend(Tx, 60);
end;

procedure AnswerPing(const F: TFrame; Len: Word);
var I: Integer; Ihl, Icmp: Word; C: Word;
begin
  Ihl := (F[14] and $0F) * 4;
  Icmp := 14 + Ihl;
  if Len < Icmp + 8 then Exit;
  Move(F, Tx, Len);
  for I := 0 to 5 do Tx[I]     := F[6 + I];
  for I := 0 to 5 do Tx[6 + I] := PktMyMac[I];
  { Swapping the addresses leaves the IP header's ones-complement sum
    unchanged -- the same words in a different order -- so that checksum
    stands and only ICMP's has to be redone. }
  for I := 0 to 3 do
  begin
    Tx[26 + I] := F[30 + I];
    Tx[30 + I] := F[26 + I];
  end;
  Tx[Icmp] := 0;                                   { echo reply }
  Tx[Icmp + 2] := 0; Tx[Icmp + 3] := 0;
  C := Checksum(Tx, Icmp, Len - Icmp);
  Tx[Icmp + 2] := Hi(C); Tx[Icmp + 3] := Lo(C);
  PktSend(Tx, Len);
end;

{ True when this frame is the ARP reply we asked for. }
function IsOurReply(const F: TFrame; Len: Word): Boolean;
var I: Integer;
begin
  IsOurReply := False;
  if Len < 42 then Exit;
  if EthType(F) <> ETH_ARP then Exit;
  if (F[20] <> 0) or (F[21] <> 2) then Exit;         { oper = reply }
  for I := 0 to 3 do
    if F[28 + I] <> Target[I] then Exit;             { from who we asked }
  IsOurReply := True;
end;

var
  Got:      Word;
  Deadline: LongInt;
  Frames:   LongInt;
  Answered: Boolean;
  Sender:   TMac;
  T0, T1:   LongInt;
  Done, Lost: Word;
  I:        Integer;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('PKTTEST', VER, 'packet driver send/receive test');

  if not HaveMy then
  begin
    WriteLn;
    WriteLn('/M is required -- this has to speak as some address, and it is');
    WriteLn('not going to invent one.  PKTTEST /? explains the rest.');
    Halt(4);
  end;
  if not Listen and not HaveTgt then
  begin
    WriteLn;
    WriteLn('Give it something to do: /T=<address> to ARP for, or /L to');
    WriteLn('listen.  PKTTEST /? explains the rest.');
    Halt(4);
  end;

  WriteLn('vector   : ', Hex2(Vec), 'h');
  if not PktSigAt(Vec) then
  begin
    WriteLn;
    WriteLn('No packet driver there.  PKTSCAN lists the vectors that do');
    WriteLn('have one.');
    Halt(1);
  end;

  { Every protocol, in both modes, and the ARP reply is picked out in
    software.  Asking the driver for one ethertype would be tidier and is
    exactly the wrong thing here: this tool exists to diagnose that driver,
    so it must not depend on the driver's type filtering being right.  When
    it was written the other way an ARP test saw zero frames while a listen
    on the same driver seconds earlier saw ARP going past. }
  if not PktOpen(Vec, $FFFF) then
  begin
    WriteLn;
    WriteLn(PktErr);
    Halt(2);
  end;

  WriteLn('our MAC  : ', MacStr(PktMyMac));
  WriteLn('speaking as ', IpStr(MyIp));
  WriteLn;

  Frames := 0;
  Answered := False;
  Deadline := Ticks + LongInt(Secs) * 182 div 10;

  if Listen then
  begin
    WriteLn('Listening for ', Secs, 's on every protocol.  Anything that');
    WriteLn('arrives is printed as it comes.');
    WriteLn;
    while Ticks < Deadline do
      if PktPoll(Rx, SizeOf(Rx), Got) then
      begin
        Inc(Frames);
        ShowFrame(Rx, Got);
        if Respond then
        begin
          if (Got >= 42) and (EthType(Rx) = ETH_ARP)
             and (Rx[20] = 0) and (Rx[21] = 1) and ForUs(Rx, 38) then
          begin
            WriteLn('    -> ARP reply');
            AnswerArp(Rx);
          end
          else if (Got >= 42) and (EthType(Rx) = ETH_IP)
                  and (Rx[23] = 1) and ForUs(Rx, 30)
                  and (Rx[14 + (Rx[14] and $0F) * 4] = 8) then
          begin
            WriteLn('    -> echo reply');
            AnswerPing(Rx, Got);
          end;
        end;
      end;
  end
  else
  begin
    BuildArp;
    if Reps > 1 then
    begin
      { Timing our own round trip, because mTCP's ping says about 50ms over
        this adapter and 4ms over the NE2000, and that number decides where
        to look next.  One exchange is far below the 55ms tick, so time a
        few hundred and divide. }
      WriteLn('Timing ', Reps, ' ARP round trips to ', IpStr(Target), '...');
      T0 := Ticks;
      Done := 0;
      Lost := 0;
      for I := 1 to Reps do
      begin
        PktSend(Tx, 60);
        Answered := False;
        Deadline := Ticks + 18;          { a second is generous }
        while (Ticks < Deadline) and not Answered do
          if PktPoll(Rx, SizeOf(Rx), Got) then
            if IsOurReply(Rx, Got) then Answered := True;
        if Answered then Inc(Done) else Inc(Lost);
      end;
      T1 := Ticks;
      WriteLn('  answered   : ', Done, ' of ', Reps, '   lost ', Lost);
      WriteLn('  elapsed    : ', T1 - T0, ' BIOS ticks');
      if Done > 0 then
        WriteLn('  round trip : ', ((T1 - T0) * 549) div (LongInt(Done) * 10),
                ' ms average');
      PktClose;
      if Done = 0 then Halt(3);
      Halt(0);
    end;
    WriteLn('ARP who-has ', IpStr(Target), '?');
    { 60 bytes, not 42: an Ethernet frame is padded to the minimum and some
      drivers will not do it for you. }
    if not PktSend(Tx, 60) then
      WriteLn('  send_pkt returned carry -- the driver sent nothing');

    while (Ticks < Deadline) and not Answered do
      if PktPoll(Rx, SizeOf(Rx), Got) then
      begin
        Inc(Frames);
        if IsOurReply(Rx, Got) then
        begin
          for I := 0 to 5 do Sender[I] := Rx[22 + I];
          WriteLn('  ', IpStr(Target), ' is at ', MacStr(Sender));
          Answered := True;
        end
        else
          { Everything else that turned up, because "no answer" and "no
            frames at all" are different faults and the count alone does
            not tell them apart. }
          ShowFrame(Rx, Got);
      end;
  end;

  WriteLn;
  WriteLn('frames in  : ', Frames);
  WriteLn('refused    : ', PktRxDrop, '   (upcall busy, or oversize)');
  WriteLn('sent ok    : ', PktTxOk);
  WriteLn('send failed: ', PktTxFail);

  PktClose;

  if Listen then
  begin
    if Frames = 0 then
    begin
      WriteLn;
      WriteLn('Nothing arrived at all.  On any real network something');
      WriteLn('broadcasts within a few seconds, so silence here means the');
      WriteLn('driver is not receiving rather than that the wire is quiet.');
      Halt(3);
    end;
    Halt(0);
  end;

  if not Answered then
  begin
    WriteLn;
    WriteLn('No answer.  If frames came in but none was the reply, the');
    WriteLn('driver receives and the target did not answer; if none came');
    WriteLn('in at all, try /L to see whether anything arrives.');
    Halt(3);
  end;
  Halt(0);
end.
