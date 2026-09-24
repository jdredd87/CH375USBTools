program usbsend;
{ USBSEND -- transmit through an AX88179 on a CH375, and prove it landed.
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  Step three.  USBLINK proved the control path and USBRECV proved receive;
  this proves transmit, and it proves it the only way that counts.

  A write to the bulk endpoint returning "success" means the CH375 accepted
  the bytes.  It says nothing at all about whether a frame reached the
  wire -- a header field in the wrong place, a length off by the eight
  bytes of the header itself, a padding flag missed, and the chip discards
  the lot in silence and reports nothing.  So this does not check that the
  write succeeded.  It sends an ARP request and waits for a machine
  somewhere else on the network to answer it.  A reply cannot be
  manufactured at this end: it means another computer received our frame,
  parsed it, believed it, and addressed a response back to this MAC.

    USBSEND [/P=260] [/I=a.b.c.d] [/T=a.b.c.d] [/N=count] [/S=secs]
           [/G] [/V] [/X]

      /P=hex   CH375 I/O base, default 260
      /I=ip    the address to claim as ours.  Required.
               It only has to be free and on the right subnet -- nothing
               here keeps it, and nothing else will be using it
      /T=ip    who to ask about.  Required.  A router is the
               safest bet: it is always up and it always answers ARP
      /N=dec   how many requests to send, default 3
      /S=dec   how long to wait for a reply, default 5 seconds
      /G       leave the PHY at gigabit -- see USBLINK /?
      /V       print every register access
      /X       hex dump the frame being sent and any reply

  Exit codes: 0 a reply came back -- transmit works, 1 no chip,
              3 nothing attached, 5 not an ASIX adapter,
              6 would not initialise, 7 no link,
              8 the send itself failed, 9 sent but nothing replied }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, ax179;

const
  VER   = '1.0.0';
  BUFSZ = 16384;

  ETH_ARP = $0806;

var
  { No default addresses, deliberately.  This is somebody else's tool as
    much as ours, and a default of 192.168.50.x is a tool that silently
    ARPs a subnet the user has never heard of -- on a network where that
    range might well belong to someone.  Both are required; PKTTEST has
    worked this way since it was written. }
  OurIp:   array[0..3] of Byte = (0, 0, 0, 0);
  TgtIp:   array[0..3] of Byte = (0, 0, 0, 0);
  HaveOur: Boolean = False;
  HaveTgt: Boolean = False;
  Count:   Word    = 3;
  Secs:    Word    = 5;
  Giga:    Boolean = False;
  Dump:    Boolean = False;
  Frame:   array[0..59] of Byte;   { 42 bytes of ARP, padded to the 60 an
                                     Ethernet frame has to be }
  Buf:     array[0..BUFSZ - 1] of Byte;
  Steps:   Integer = 0;

function IpStr(const A: array of Byte): ShortString;
var S, T: ShortString; I: Integer;
begin
  S := '';
  for I := 0 to 3 do
  begin
    Str(A[I], T);
    if I > 0 then S := S + '.';
    S := S + T;
  end;
  IpStr := S;
end;

function ParseIp(const S: ShortString; var A: array of Byte): Boolean;
var I, P, Code: Integer; Part: ShortString; V: LongInt;
begin
  ParseIp := False;
  P := 1;
  for I := 0 to 3 do
  begin
    Part := '';
    while (P <= Length(S)) and (S[P] <> '.') do
    begin
      Part := Part + S[P];
      Inc(P);
    end;
    Inc(P);                            { step over the dot }
    if Part = '' then Exit;
    Val(Part, V, Code);
    if (Code <> 0) or (V < 0) or (V > 255) then Exit;
    A[I] := Byte(V);
  end;
  ParseIp := True;
end;

{ An ARP request, built by hand.  42 bytes of content in a 60-byte frame:
  Ethernet will not carry anything shorter, and while this chip would pad
  it for us, a frame that is the right length before it leaves is one less
  thing to wonder about when no reply comes back. }
procedure BuildArp;
var I: Integer;
begin
  for I := 0 to 59 do Frame[I] := 0;

  for I := 0 to 5 do Frame[I] := $FF;            { to: broadcast }
  for I := 0 to 5 do Frame[6 + I] := Mac[I];     { from: us }
  Frame[12] := $08; Frame[13] := $06;            { ethertype ARP }

  Frame[14] := $00; Frame[15] := $01;            { hardware: Ethernet }
  Frame[16] := $08; Frame[17] := $00;            { protocol: IPv4 }
  Frame[18] := 6;                                { hardware address length }
  Frame[19] := 4;                                { protocol address length }
  Frame[20] := $00; Frame[21] := $01;            { operation: request }

  for I := 0 to 5 do Frame[22 + I] := Mac[I];    { sender hardware }
  for I := 0 to 3 do Frame[28 + I] := OurIp[I];  { sender protocol }
  { target hardware stays all zero -- that is the question being asked }
  for I := 0 to 3 do Frame[38 + I] := TgtIp[I];  { target protocol }
end;

function MacAt(const B: array of Byte; Ofs: Word): ShortString;
var M: TMac; I: Integer;
begin
  for I := 0 to 5 do M[I] := B[Ofs + I];
  MacAt := MacStr(M);
end;

{ Walk a received burst looking for an ARP reply that answers ours.  The
  buffer layout is the one USBRECV established: frames at the front padded
  to 8 bytes, 4-byte entries at hdr_off, a count-and-offset trailer at the
  very end. }
function FindArpReply(Len: Word; var Who: ShortString): Boolean;
var
  RxHdr: LongInt;
  PktCnt, HdrOff, I, Ofs, PktLen, Ent: Word;
  H: LongInt;
  Ok: Boolean;
  J: Integer;
begin
  FindArpReply := False;
  if Len < 8 then Exit;

  RxHdr  := LongInt(Buf[Len-4]) or (LongInt(Buf[Len-3]) shl 8) or
            (LongInt(Buf[Len-2]) shl 16) or (LongInt(Buf[Len-1]) shl 24);
  PktCnt := Word(RxHdr and $FFFF);
  HdrOff := Word((RxHdr shr 16) and $FFFF);
  if (PktCnt < 1) or (PktCnt > 32) then Exit;
  if HdrOff + 4 > Len - 4 then Exit;
  Ent := (Len - 4 - HdrOff) div PktCnt;
  if Ent = 0 then Exit;

  Ofs := 0;
  for I := 0 to PktCnt - 1 do
  begin
    if HdrOff + I * Ent + 4 > Len then Exit;
    H := LongInt(Buf[HdrOff + I*Ent]) or
         (LongInt(Buf[HdrOff + I*Ent + 1]) shl 8) or
         (LongInt(Buf[HdrOff + I*Ent + 2]) shl 16) or
         (LongInt(Buf[HdrOff + I*Ent + 3]) shl 24);
    PktLen := Word((H shr 16) and $1FFF);
    if (PktLen < 42) or (Ofs + PktLen > Len) then Exit;

    { ARP, operation 2, and the sender is who we asked about. }
    if ((Word(Buf[Ofs+12]) shl 8) or Buf[Ofs+13]) = ETH_ARP then
      if ((Word(Buf[Ofs+20]) shl 8) or Buf[Ofs+21]) = 2 then
      begin
        Ok := True;
        for J := 0 to 3 do
          if Buf[Ofs + 28 + J] <> TgtIp[J] then Ok := False;
        if Ok then
        begin
          Who := MacAt(Buf, Ofs + 22);
          if Dump then HexDumpAt(Buf, Ofs, PktLen, '    ');
          FindArpReply := True;
          Exit;
        end;
      end;

    Ofs := Ofs + ((PktLen + 7) and $FFF8);
  end;
end;

procedure ShowStep(const What: ShortString; St: Integer);
var I: Integer;
begin
  Write('  ', What);
  for I := Length(What) + 2 to 35 do Write('.');
  if St >= 0 then WriteLn(' ok')
  else begin WriteLn(' FAILED (', StatusStr(St), ')'); Inc(Steps); end;
end;

procedure Usage;
begin
  Banner('USBSEND', VER, 'transmit through an AX88179 and prove it landed');
  WriteLn;
  WriteLn('  USBSEND [/P=260] [/I=a.b.c.d] [/T=a.b.c.d] [/N=count]');
  WriteLn('         [/S=secs] [/G] [/V] [/X]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /I=ip    the address to claim as ours, default');
  WriteLn('           has to be free and on the right subnet -- nothing');
  WriteLn('           right subnet -- nothing here keeps it');
  WriteLn('  /T=ip    who to ask about (required).  A router is');
  WriteLn('           the safest bet: always up, always answers ARP');
  WriteLn('  /N=dec   how many requests to send, default 3');
  WriteLn('  /S=dec   how long to wait for a reply, default 5 seconds');
  WriteLn('  /G       leave the PHY at gigabit -- see USBLINK /?');
  WriteLn('  /V       print every register access');
  WriteLn('  /X       hex dump the frame sent and any reply');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('A write to the bulk endpoint returning "success" means the');
  WriteLn('CH375 accepted the bytes.  It says nothing about whether a');
  WriteLn('frame reached the wire -- a header field in the wrong place, a');
  WriteLn('length off by the eight bytes of the header itself, a padding');
  WriteLn('flag missed, and the chip discards the lot in silence.');
  WriteLn;
  WriteLn('So this does not check that the write succeeded.  It sends an');
  WriteLn('ARP request and waits for another machine to answer.  A reply');
  WriteLn('cannot be manufactured at this end: it means a real computer');
  WriteLn('received our frame, parsed it, believed it, and addressed a');
  WriteLn('response back to this MAC.');
  WriteLn;
  WriteLn('Exit: 0 a reply came back, 1 no chip, 3 nothing attached,');
  WriteLn('      5 not an ASIX adapter, 6 would not initialise, 7 no');
  WriteLn('      link, 8 the send failed, 9 sent but nothing replied');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K, Rest: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/G') or (A = '-G') then Giga := True
    else if (A = '/X') or (A = '-X') then Dump := True
    else if (A = '/V') or (A = '-V') then AxTrace := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); Rest := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + Rest, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/N=' then begin Val(Rest, V, Code); if Code = 0 then Count := Word(V); end
      else if K = '/S=' then begin Val(Rest, V, Code); if Code = 0 then Secs := Word(V); end
      else if K = '/I=' then HaveOur := ParseIp(Rest, OurIp)
      else if K = '/T=' then HaveTgt := ParseIp(Rest, TgtIp);
    end;
  end;
end;

var
  Rc, St: Integer;
  Vid, Bmsr, Len: Word;
  I: Word;
  T0, TEnd: LongInt;
  Who: ShortString;
  Sent, Polls: Word;
  Got: Boolean;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('USBSEND', VER, 'AX88179 transmit');

  if not (HaveOur and HaveTgt) then
  begin
    WriteLn;
    WriteLn('/I and /T are both required -- an address to speak as, and');
    WriteLn('one to ask about.  This will not guess: a guess would put');
    WriteLn('somebody else''s address on your wire.  Your router is the');
    WriteLn('safest /T; any free address on the same subnet does for /I.');
    WriteLn;
    WriteLn('    USBSEND /I=<free address> /T=<your router>');
    Halt(4);
  end;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;
  Vid := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  if Vid <> AX_VENDOR then
  begin
    WriteLn('Not an ASIX adapter.  USBINFO will say what you have.');
    Halt(5);
  end;

  AxStep := @ShowStep;
  WriteLn('Bringing the chip up');
  if (not AxInit(False)) or (Steps > 0) then
  begin
    WriteLn;
    WriteLn('The chip would not initialise.  /V shows which access failed.');
    Halt(6);
  end;
  WriteLn;
  WriteLn('MAC address: ', MacStr(Mac));

  AxNegotiate(not Giga);
  Write('Waiting for a link');
  if not AxLinkWait(15, Bmsr) then
  begin
    WriteLn;
    WriteLn('No link.  BMSR = ', Hex4(Bmsr), '.  Check the cable.');
    Halt(7);
  end;
  WriteLn(' up.');
  AxSetMedium(Giga);
  AxStep := nil;

  BuildArp;
  WriteLn;
  WriteLn('Asking ', IpStr(TgtIp), ' who it is, claiming to be ',
          IpStr(OurIp));
  if Dump then
  begin
    WriteLn('  the frame going out, 60 bytes:');
    HexDump(Frame, 60, '    ');
  end;

  AxRxReset;
  AxTxReset;

  Sent  := 0;
  Polls := 0;
  Got   := False;
  Who   := '';

  for I := 1 to Count do
  begin
    St := AxTxFrame(Frame, 60);
    if St <> INT_SUCCESS then
    begin
      WriteLn('  send ', I, ' FAILED: ', StatusStr(St));
      Continue;
    end;
    Inc(Sent);
    WriteLn('  request ', I, ' sent');

    { Listen after each one rather than sending them all first: a reply
      to the first request usually arrives before the second would go. }
    T0   := Ticks;
    TEnd := T0 + (LongInt(Secs) * 18) div Count + 9;
    while (Ticks < TEnd) and (not Got) do
    begin
      if KeyWaiting then begin EatKey; Break; end;
      St := AxRxBurst(Buf, BUFSZ, Len);
      Inc(Polls);
      if (St = INT_SUCCESS) and (Len > 0) then
        if FindArpReply(Len, Who) then Got := True;
    end;
    if Got then Break;
  end;

  WriteLn;
  WriteLn('--- done ---');
  WriteLn('  requests sent : ', Sent);
  WriteLn('  polls         : ', Polls);

  if Sent = 0 then
  begin
    WriteLn;
    WriteLn('Nothing went out at all.  The bulk OUT endpoint refused every');
    WriteLn('write, which is a CH375 or configuration problem rather than');
    WriteLn('a frame-format one -- USBLINK /V will show the bring-up.');
    Halt(8);
  end;

  if not Got then
  begin
    WriteLn;
    WriteLn('Sent, but nothing answered.');
    WriteLn;
    WriteLn('The CH375 accepted the bytes, so the failure is further out:');
    WriteLn('either the frame never reached the wire -- an 8-byte header');
    WriteLn('the chip did not like, and it drops those in silence -- or it');
    WriteLn('did and nothing wanted to answer.  Worth checking before');
    WriteLn('blaming the header:');
    WriteLn('  * is ', IpStr(TgtIp), ' really on this network and up?');
    WriteLn('  * is ', IpStr(OurIp), ' free, and on the same subnet?');
    WriteLn('  * does USBRECV /A see other traffic?  If it sees nothing');
    WriteLn('    either, the problem is the link and not the transmit');
    WriteLn('    path.');
    Halt(9);
  end;

  WriteLn;
  WriteLn('REPLY from ', Who, ' -- ', IpStr(TgtIp), ' answered us.');
  WriteLn;
  WriteLn('That frame was built here, pushed through the CH375, put on the');
  WriteLn('wire by the adapter, received by another machine, understood,');
  WriteLn('and answered to this MAC.  Transmit works.');
  Halt(0);
end.
