program srlink;
{ SRLINK -- bring up an SR9700 / DM9601 USB Ethernet adapter over a CH375
  and see whether real frames arrive.
  CH375Net, StevenC.  Public domain (the Unlicense).

      SRLINK [/P=260] [/S=secs] [/M] [/X] [/V] [/T]

        /P=hex   I/O base, default 260
        /S=dec   seconds to listen for frames, default 15
        /M       promiscuous: keep frames not addressed to us.  On by
                 default, because a quiet network addressed to somebody
                 else is indistinguishable from a dead receiver
        /X       print each frame as hex as well as decoded
        /V       narrate the bring-up
        /T       trace every control-transfer stage

  WHAT THIS ANSWERS

  Whether the adapter works, which is a different question from whether it
  answers its registers.  Reading a register proves the control pipe and
  the chip's identity; it says nothing about whether a frame from the wire
  ever reaches the host.  This resets the chip, brings the PHY up, enables
  the receiver and then sits on the bulk IN endpoint reporting what turns
  up.

  A network is never silent.  Within a few seconds any real segment
  produces ARP, broadcasts, spanning-tree, mDNS, or somebody's laptop
  saying hello.  So the test is honest in the direction that matters: if
  frames arrive and decode as Ethernet, the receive path works; if nothing
  arrives, the answer is "not proven" rather than "broken", and the tool
  says which.

  IT DOES NOT GO RESIDENT and installs no packet driver.  USBPKT is what
  does that, and it should not be pointed at a chipset until something
  like this has shown frames moving. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, sr9700;

const
  VER = '0.1.0';

type
  TBigCfg = array[0..1023] of Byte;

var
  Big     : TBigCfg;
  BigLen  : Word;
  Mac     : TMacAddr;
  VID, PID: Word;
  Rc, I   : Integer;
  S       : ShortString;
  Secs    : Integer;
  Promisc : Boolean;
  ShowHex : Boolean;
  NoReset : Boolean;
  DoArp   : Boolean;
  ArpOk   : Boolean;
  ArpIp   : LongInt;
  SrcIp   : LongInt;
  NArpReply: LongInt;
  BenchN  : Integer;
  NSent   : LongInt;
  MassIf  : Integer;
  Frame   : array[0..1599] of Byte;
  Got     : Word;
  NFrames, NBytes, NArp, NIp, NBcast: LongInt;
  T0, Elapsed, Spins: LongInt;
  V       : Byte;

{ Say where we are, on STDERR.

  Everything this program prints normally goes to stdout, which the bridge
  redirects into a file that only arrives when the job finishes. A job that
  never finishes therefore produces NOTHING, and two hangs in a row said
  exactly as much about where they happened as a blank screen would.

  DOS 6.22 cannot redirect handle 2, which is usually a nuisance and is
  the whole point here: these land on the real screen where a camera can
  read them even when the machine never gets to the end. }
procedure Stage(const T: ShortString);
begin
  Write(StdErr, '  [', T, ']'#13#10);
end;

procedure Quieten;
begin
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

function Dec1(V: LongInt): ShortString;
var T: ShortString;
begin
  Str(V, T);
  Dec1 := T;
end;

procedure Fld(const N, V: ShortString);
var T: ShortString;
begin
  T := '  ' + N;
  while Length(T) < 22 do T := T + ' ';
  WriteLn(T, ': ', V);
end;

procedure Narrate(const Line: ShortString);
begin
  WriteLn(Line);
end;

function NumArg(const A: ShortString; From: Integer): LongInt;
var V: LongInt; I: Integer;
begin
  V := 0; I := From;
  while (I <= Length(A)) and (A[I] >= '0') and (A[I] <= '9') do
  begin
    V := V * 10 + (Ord(A[I]) - 48);
    Inc(I);
  end;
  NumArg := V;
end;

function HexArg(const A: ShortString; From: Integer): Word;
var V, I: Integer; C: Char;
begin
  V := 0;
  for I := From to Length(A) do
  begin
    C := UpCase(A[I]);
    if (C >= '0') and (C <= '9') then V := V * 16 + (Ord(C) - 48)
    else if (C >= 'A') and (C <= 'F') then V := V * 16 + (Ord(C) - 55)
    else Break;
  end;
  HexArg := V;
end;

function MacStr(const M; N: Integer): ShortString;
var
  P: PByte;
  I: Integer;
  T: ShortString;
begin
  P := @M;
  T := '';
  for I := 0 to N - 1 do
  begin
    if I > 0 then T := T + ':';
    T := T + Hex2(P[I]);
  end;
  MacStr := T;
end;

{ Find the network interface and its bulk endpoints, skipping the
  mass-storage one that these adapters put FIRST. }
procedure FindNet;
var
  P    : Word;
  L, T : Byte;
  CurIf: Integer;
  Cls  : Byte;
  Addr, Attr: Byte;
begin
  SrIf := 0; SrIn := 0; SrOut := 0; MassIf := -1;
  CurIf := -1; Cls := 0;
  P := 0;
  while P + 2 <= BigLen do
  begin
    L := Big[P];
    T := Big[P + 1];
    if (L = 0) or (P + L > BigLen) then Break;
    if T = $04 then
    begin
      CurIf := Big[P + 2];
      Cls := Big[P + 5];
      if Cls = $08 then
      begin
        if MassIf < 0 then MassIf := CurIf;
      end
      else if SrIn = 0 then
        SrIf := Byte(CurIf);
    end
    else if (T = $05) and (CurIf = SrIf) and (Cls <> $08) then
    begin
      Addr := Big[P + 2];
      Attr := Big[P + 3] and $03;
      if Attr = 2 then
      begin
        if (Addr and $80) <> 0 then
        begin
          if SrIn = 0 then SrIn := Addr and $0F;
        end
        else if SrOut = 0 then SrOut := Addr and $0F;
      end;
    end;
    Inc(P, L);
  end;
end;

procedure ShowFrame(var F; N: Word);
var
  P: PByte;
  Typ: Word;
  K: Integer;
begin
  P := @F;
  if N < 14 then
  begin
    WriteLn('  runt, ', N, ' bytes');
    Exit;
  end;
  Typ := (Word(P[12]) shl 8) or P[13];
  Write('  ', N:4, ' bytes  ', MacStr(P[6], 6), ' -> ', MacStr(P[0], 6));
  Write('  type ', Hex4(Typ));
  case Typ of
    $0806: begin Write('  ARP'); Inc(NArp); end;
    $0800: begin Write('  IPv4'); Inc(NIp); end;
    $86DD: Write('  IPv6');
    $8100: Write('  VLAN');
  end;
  if (P[0] and $01) <> 0 then
  begin
    Write('  (bcast/mcast)');
    Inc(NBcast);
  end;
  WriteLn;
  if ShowHex then
  begin
    Write('       ');
    for K := 0 to 31 do
    begin
      if K >= N then Break;
      Write(' ', Hex2(P[K]));
    end;
    WriteLn;
  end;
end;

{ Build an ARP request for Target, from our own MAC and SrcIp.

  ARP is the right transmit test and nothing else comes close. It is 42
  bytes so it fits in one USB packet; every host on the segment is obliged
  to answer one addressed to it; the answer comes back to OUR MAC
  specifically rather than to a broadcast, so receiving it proves the
  adapter's address filter as well as the wire; and it needs no IP stack,
  no configuration and no cooperation from anything on this machine.

  A reply is therefore end-to-end proof: the frame we built left the host,
  crossed the wire, was understood by a real device, and its answer came
  back through the same adapter. Nothing short of that proves transmit at
  all -- a send that returns "success" only means the chip took the bytes. }
procedure BuildArp(var F: array of Byte; const Src: TMacAddr;
                   SrcIp, DstIp: LongInt; var Len: Word);
var I: Integer;
begin
  for I := 0 to 59 do F[I] := 0;
  for I := 0 to 5 do F[I] := $FF;              { to broadcast }
  for I := 0 to 5 do F[6 + I] := Src[I];
  F[12] := $08; F[13] := $06;                  { ARP }
  F[14] := $00; F[15] := $01;                  { Ethernet }
  F[16] := $08; F[17] := $00;                  { IPv4 }
  F[18] := 6; F[19] := 4;
  F[20] := $00; F[21] := $01;                  { request }
  for I := 0 to 5 do F[22 + I] := Src[I];
  F[28] := Byte((SrcIp shr 24) and $FF);
  F[29] := Byte((SrcIp shr 16) and $FF);
  F[30] := Byte((SrcIp shr 8) and $FF);
  F[31] := Byte(SrcIp and $FF);
  { 32..37 target MAC stays zero -- it is what is being asked for }
  F[38] := Byte((DstIp shr 24) and $FF);
  F[39] := Byte((DstIp shr 16) and $FF);
  F[40] := Byte((DstIp shr 8) and $FF);
  F[41] := Byte(DstIp and $FF);
  Len := 60;                                   { pad to the minimum frame }
end;

function IpStr(V: LongInt): ShortString;
var T: ShortString;
begin
  T := Dec1((V shr 24) and $FF) + '.' + Dec1((V shr 16) and $FF) + '.'
     + Dec1((V shr 8) and $FF) + '.' + Dec1(V and $FF);
  IpStr := T;
end;

begin
  Banner('SRLINK', VER, 'SR9700/DM9601 bring-up and receive test');
  if HelpWanted then
  begin
    WriteLn('  SRLINK [/P=260] [/S=secs] [/M] [/X] [/V] [/T]');
    WriteLn;
    WriteLn('    /S=n  seconds to listen, default 15');
    WriteLn('    /M    promiscuous (default on)');
    WriteLn('    /X    hex-dump each frame');
    WriteLn('    /Q    skip the ARP transmit test');
    WriteLn('    /B=n  send n frames as fast as possible and time it');
    WriteLn('    /N    skip the chip reset (it is the prime suspect for');
    WriteLn('          the adapter dropping off the bus mid-bring-up)');
    HelpTail;
    Halt(0);
  end;

  Secs := 15; Promisc := True; ShowHex := False; NoReset := False;
  { Defaults chosen for the network this was developed on; /G and /A move
    them. The source address is deliberately NOT the one the machine's
    other adapter uses -- two interfaces answering for one address is a
    good way to spend an evening blaming the wrong thing. }
  DoArp := True; ArpOk := False; BenchN := 0;
  ArpIp := (LongInt(192) shl 24) or (LongInt(168) shl 16)
           or (LongInt(50) shl 8) or 1;
  SrcIp := (LongInt(192) shl 24) or (LongInt(168) shl 16)
           or (LongInt(50) shl 8) or 77;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base := HexArg(S, 4);
      'S': Secs := NumArg(S, 4);
      'M': Promisc := True;
      'X': ShowHex := True;
      'N': NoReset := True;
      'Q': DoArp := False;
      'B': BenchN := NumArg(S, 4);
      'V': Trace := @Narrate;
      'T': CtrlTrace := True;
    end;
  end;
  if Secs < 1 then Secs := 1;
  if CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');

  { Abort any NAK still in flight on the way out, however this exits.
    Without it a program that stops mid-poll strands a transaction and the
    NEXT program reports "no CH375 at 0260" on a card that is fitted. }
  ExitProc := @Quieten;

  Stage('chip');
  if not ChipHere(Base) then
  begin
    ChipReset;
    DelayMs(200);
    if not ChipHere(Base) then
    begin
      WriteLn(BusUpReason(BU_NO_CHIP));
      Halt(BU_NO_CHIP);
    end;
  end;
  Stage('enumerate');
  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  PID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  Fld('device', Hex4(VID) + ':' + Hex4(PID));

  Stage('descriptors');
  Rc := GetDescr(DT_CONFIG, 0, 0, Big, 9, BigLen);
  if BigLen < 9 then
  begin
    WriteLn('  cannot read the configuration header');
    Halt(5);
  end;
  I := Big[2] or (Integer(Big[3]) shl 8);
  if I > SizeOf(Big) then I := SizeOf(Big);
  Rc := GetDescr(DT_CONFIG, 0, 0, Big, I, BigLen);
  if BigLen < Word(I) then
  begin
    WriteLn('  short configuration descriptor');
    Halt(5);
  end;

  Stage('set config');
  Rc := SetConfig(Big[5]);
  if Rc <> INT_SUCCESS then
  begin
    WriteLn('  SET_CONFIGURATION -> ', StatusName(Rc));
    Halt(5);
  end;

  Stage('find endpoints');
  FindNet;
  if (SrIn = 0) or (SrOut = 0) then
  begin
    WriteLn('  no bulk pair on a non-storage interface.');
    Halt(6);
  end;
  if MassIf >= 0 then
    Fld('storage interface', Dec1(MassIf) + '  (skipped -- driver CD)');
  Fld('network interface', Dec1(SrIf));
  Fld('bulk IN / OUT', Hex2(SrIn or $80) + ' / ' + Hex2(SrOut));

  { Composite device: claim the function before talking to it. }
  Stage('set interface');
  Rc := CtrlNoData($01, REQ_SET_IFACE, 0, Word(SrIf));
  Fld('SET_INTERFACE', Dec1(SrIf) + ' -> ' + StatusName(Rc));

  WriteLn;
  WriteLn('BRING-UP');
  WriteLn('----------------------------------------------------------------');
  Stage('chip bring-up');
  SrNoReset := NoReset;
  if not SrBringUp(Promisc) then
  begin
    WriteLn('  failed: ', SrErr);
    Halt(5);
  end;
  WriteLn('  reset, PHY released, receiver enabled and read back');

  Stage('read MAC');
  if not ReadMac(Mac) then
  begin
    WriteLn('  cannot read the MAC: ', SrErr);
    Halt(5);
  end;
  Fld('MAC', MacStr(Mac, 6));

  if RegRd(SR_NSR, V) then
  begin
    Fld('NSR', Hex2(V));
    if (V and NSR_LINKST) <> 0 then
    begin
      if (V and NSR_SPEED) <> 0 then
        WriteLn('                        link UP at 10 Mbps')
      else
        WriteLn('                        link UP at 100 Mbps');
    end
    else
    begin
      WriteLn('                        link DOWN -- is a cable plugged in?');
      WriteLn('                        Listening anyway; nothing will come.');
    end;
  end;

  WriteLn;
  WriteLn('LISTENING FOR ', Secs, 's');
  WriteLn('----------------------------------------------------------------');
  { TRANSMIT. Ask the gateway who it is and wait for it to say. }
  if DoArp then
  begin
    Stage('arp');
    WriteLn;
    WriteLn('TRANSMIT TEST -- ARP for ', IpStr(ArpIp));
    WriteLn('----------------------------------------------------------------');
    BuildArp(Frame, Mac, SrcIp, ArpIp, Got);
    WriteLn('  asking, as ', IpStr(SrcIp), ' / ', MacStr(Mac, 6));
    if not SrSend(Frame, Got) then
    begin
      WriteLn('  the send was refused: ', SrErr);
      WriteLn('  Transmit does not work; nothing below will help.');
      Halt(8);
    end;
    WriteLn('  sent ', Got, ' bytes');

    NArpReply := 0;
    while KeyWaiting do EatKey;
    T0 := Ticks; Spins := 0;
    while True do
    begin
      Elapsed := Ticks - T0;
      if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
      if Elapsed >= 90 then Break;              { about five seconds }
      Inc(Spins);
      if Spins > 20000 then Break;
      if SrRecv(Frame, SizeOf(Frame), Got) then
        if Got >= 42 then
          { An ARP REPLY, addressed to us, answering what we asked. }
          if (Frame[12] = $08) and (Frame[13] = $06)
             and (Frame[20] = $00) and (Frame[21] = $02) then
          begin
            Inc(NArpReply);
            Write('  REPLY from ', IpStr((LongInt(Frame[28]) shl 24)
                  or (LongInt(Frame[29]) shl 16)
                  or (LongInt(Frame[30]) shl 8) or Frame[31]));
            WriteLn('  is at ', MacStr(Frame[22], 6));
            Break;
          end;
    end;

    WriteLn;
    if NArpReply > 0 then
    begin
      WriteLn('  *** TRANSMIT AND RECEIVE BOTH WORK. The frame left this');
      WriteLn('  machine, crossed the wire, was understood by a real host,');
      WriteLn('  and its answer came back through this adapter addressed to');
      WriteLn('  our own MAC.');
      ArpOk := True;
    end
    else
    begin
      WriteLn('  No reply in five seconds. Either the frame never left, or');
      WriteLn('  nothing at ', IpStr(ArpIp), ' answered. Try /G with the');
      WriteLn('  address of something you know is switched on.');
    end;
  end;

  { TRANSMIT THROUGHPUT.

    Send a burst of ARP requests as fast as the pipe will take them and
    time it. ARP is used again because it is 60 bytes, needs no state, and
    a gateway will answer as many as it feels like without either end
    having to agree about anything -- so the numbers measure THIS adapter
    rather than a negotiation.

    Frames sent is the honest figure; frames answered is not, because a
    switch or a gateway is entitled to rate-limit ARP and often does. }
  if BenchN > 0 then
  begin
    Stage('tx bench');
    WriteLn;
    WriteLn('TRANSMIT THROUGHPUT -- ', BenchN, ' frames of 60 bytes');
    WriteLn('----------------------------------------------------------------');
    BuildArp(Frame, Mac, SrcIp, ArpIp, Got);
    NSent := 0;
    T0 := Ticks;
    for I := 1 to BenchN do
      if SrSend(Frame, Got) then Inc(NSent);
    Elapsed := Ticks - T0;
    if Elapsed < 1 then Elapsed := 1;
    WriteLn('  sent            : ', NSent, ' of ', BenchN);
    WriteLn('  elapsed         : ', (Elapsed * 10) div 182, '.',
            ((Elapsed * 1000) div 182) mod 10, ' s');
    WriteLn('  frames/second   : ', (LongInt(NSent) * 182) div (Elapsed * 10));
    WriteLn('  bytes/second    : ',
            ((LongInt(NSent) * 60) * 182) div (Elapsed * 10));
    if RegRd(SR_ROCR, V) then
      WriteLn('  rx overflow now : ', Hex2(V));
  end;

  Stage('listening');
  NFrames := 0; NBytes := 0; NArp := 0; NIp := 0; NBcast := 0;
  while KeyWaiting do EatKey;
  T0 := Ticks; Spins := 0;
  while True do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
    if Elapsed >= LongInt(Secs) * 182 div 10 then Break;
    Inc(Spins);
    { A much tighter spin bound than the clock alone. Each failed EpIn
      burns its whole WaitInt budget, so a few thousand of them is
      already minutes -- and if the chip has stopped answering, the
      clock-based limit is the only thing left and it must not be the
      only thing. }
    if Spins > 20000 then
    begin
      WriteLn('  stopping: ', Spins, ' polls without the clock advancing.');
      Break;
    end;
    if KeyWaiting then begin EatKey; WriteLn('  stopped.'); Break; end;

    { A heartbeat on stderr, driven by the SPIN COUNT rather than the
      clock, because the question it answers is "is this loop turning at
      all". A time-driven tick cannot tell a loop that is spinning from
      one blocked inside a single call -- both look silent -- and that is
      exactly the distinction two hangs have now turned on. }
    if (Spins mod 25) = 0 then Write(StdErr, '.');

    if SrRecv(Frame, SizeOf(Frame), Got) then
      if Got > 0 then
      begin
        Inc(NFrames);
        Inc(NBytes, Got);
        Write(StdErr, '#');
        if NFrames <= 20 then ShowFrame(Frame, Got);
      end;
  end;

  WriteLn;
  Stage('done');
  WriteLn('RESULT');
  WriteLn('----------------------------------------------------------------');
  Fld('frames', Dec1(NFrames));
  Fld('bytes', Dec1(NBytes));
  Fld('ARP / IPv4', Dec1(NArp) + ' / ' + Dec1(NIp));
  Fld('broadcast/multicast', Dec1(NBcast));
  if RegRd(SR_ROCR, V) then Fld('overflow counter', Hex2(V));

  WriteLn;
  if NFrames > 0 then
  begin
    WriteLn('  FRAMES ARRIVED AND DECODE AS ETHERNET. The receive path');
    WriteLn('  works: chip reset, PHY, receiver and the bulk IN pipe are');
    WriteLn('  all doing their job.');
    if ArpOk then
    begin
      WriteLn;
      WriteLn('  AND TRANSMIT WORKS: the ARP above was answered. Both');
      WriteLn('  directions are proven on real traffic.');
    end
    else if DoArp then
    begin
      WriteLn;
      WriteLn('  TRANSMIT IS NOT PROVEN -- the ARP went unanswered.');
    end;
    Halt(0);
  end
  else
  begin
    WriteLn('  Nothing arrived. That is NOT proof the adapter is broken --');
    WriteLn('  an unplugged cable, a switch port that has not come up, or a');
    WriteLn('  genuinely silent segment all look the same from here. Check');
    WriteLn('  the NSR line above first: no link means nothing was ever');
    WriteLn('  going to arrive.');
    Halt(7);
  end;
end.
