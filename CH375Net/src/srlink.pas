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
  MassIf  : Integer;
  Frame   : array[0..1599] of Byte;
  Got     : Word;
  NFrames, NBytes, NArp, NIp, NBcast: LongInt;
  T0, Elapsed, Spins: LongInt;
  V       : Byte;

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

begin
  Banner('SRLINK', VER, 'SR9700/DM9601 bring-up and receive test');
  if HelpWanted then
  begin
    WriteLn('  SRLINK [/P=260] [/S=secs] [/M] [/X] [/V] [/T]');
    WriteLn;
    WriteLn('    /S=n  seconds to listen, default 15');
    WriteLn('    /M    promiscuous (default on)');
    WriteLn('    /X    hex-dump each frame');
    HelpTail;
    Halt(0);
  end;

  Secs := 15; Promisc := True; ShowHex := False;
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

  Rc := SetConfig(Big[5]);
  if Rc <> INT_SUCCESS then
  begin
    WriteLn('  SET_CONFIGURATION -> ', StatusName(Rc));
    Halt(5);
  end;

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
  Rc := CtrlNoData($01, REQ_SET_IFACE, 0, Word(SrIf));
  Fld('SET_INTERFACE', Dec1(SrIf) + ' -> ' + StatusName(Rc));

  WriteLn;
  WriteLn('BRING-UP');
  WriteLn('----------------------------------------------------------------');
  if not SrBringUp(Promisc) then
  begin
    WriteLn('  failed: ', SrErr);
    Halt(5);
  end;
  WriteLn('  reset, PHY released, receiver enabled and read back');

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

    if SrRecv(Frame, SizeOf(Frame), Got) then
      if Got > 0 then
      begin
        Inc(NFrames);
        Inc(NBytes, Got);
        if NFrames <= 20 then ShowFrame(Frame, Got);
      end;
  end;

  WriteLn;
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
    WriteLn('  all doing their job. Transmit is a separate question and');
    WriteLn('  this tool has not asked it.');
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
