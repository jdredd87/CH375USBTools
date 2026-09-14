unit sr9700;
{ sr9700 -- CoreChip SR9700 / Davicom DM9601 USB Ethernet, over a CH375.
  CH375Net, StevenC.  Public domain (the Unlicense).

  The register interface is the DM9601's and the SR9700 inherits it, so one
  unit covers both.  What differs between real parts and the clones sold
  under these IDs is not the register map but which ACCESS FORMS they
  bother to implement, which is where the surprise in this one lives.

  THE CLONE'S DEFECT, and the reason every read here is one byte wide.

  A multi-byte register read on the adapter this was written against
  returns the PAR block from 10h regardless of wIndex.  Ask for eight
  bytes at 00h and you get the MAC address; ask for eight at 28h and you
  get the MAC address.  Nothing about that looks like a defect from the
  outside -- it looks exactly like a device that does not implement the
  protocol at all, which is what this project concluded for an evening.

  Single-byte reads decode wIndex correctly.  So RegRd reads one register
  per control transfer and there is no block form, deliberately: a driver
  that fetched the six MAC bytes in one go would get the fixed block and
  come up with the RIGHT answer for the MAC and the wrong answer for
  everything else, which is a far nastier way to be wrong than failing.

  On a genuine part the block read works and this is merely slower.  Six
  transfers to read a MAC is nothing next to being subtly wrong. }

{$MODE OBJFPC}{$H-}

interface

uses ch375;

const
  { Vendor requests, as the Linux dm9601 and sr9700 drivers issue them. }
  SR_RD_REGS = $00;
  SR_WR_REGS = $01;
  SR_WR_REG  = $03;

  { Registers. }
  SR_NCR   = $00;        { network control }
  SR_NSR   = $01;        { network status }
  SR_RCR   = $05;        { receive control }
  SR_ROCR  = $07;        { receive overflow counter }
  SR_EPCR  = $0B;        { EEPROM / PHY control }
  SR_EPAR  = $0C;        { EEPROM / PHY address }
  SR_EPDRL = $0D;        { EEPROM / PHY data low }
  SR_EPDRH = $0E;        { EEPROM / PHY data high }
  SR_PAR   = $10;        { physical address, six bytes }
  SR_MAR   = $16;        { multicast, eight bytes }
  SR_PRR   = $1F;        { PHY reset }

  { NCR bits }
  NCR_RST    = $01;
  NCR_LBK    = $06;
  NCR_FDX    = $08;
  NCR_WAKEEN = $40;

  { NSR bits }
  NSR_LINKST = $40;      { link is up }
  NSR_SPEED  = $80;      { 0 = 100 Mbps, 1 = 10 Mbps }

  { RCR bits }
  RCR_RXEN     = $01;
  RCR_PRMSC    = $02;    { promiscuous }
  RCR_RUNT     = $04;
  RCR_ALL      = $08;    { all multicast }
  RCR_DIS_CRC  = $10;
  RCR_DIS_LONG = $20;

  { PRR bits }
  PRR_PHY_RST = $01;

  { Frame framing on the bulk pipes.

    RX: three bytes of header -- status, then the length LOW then HIGH --
        and the length INCLUDES the four-byte Ethernet CRC.
    TX: two bytes of length, low then high, then the frame. }
  SR_RX_OVERHEAD = 3;
  SR_TX_OVERHEAD = 2;

type
  TMacAddr = array[0..5] of Byte;

var
  SrErr : ShortString;      { why the last call returned False }
  SrIf  : Byte;             { the network interface number }
  SrIn  : Byte;             { bulk IN endpoint number }
  SrOut : Byte;             { bulk OUT endpoint number }
  SrTogIn, SrTogOut: Byte;
  { Set before SrBringUp to skip the NCR reset -- see the note there. }
  SrNoReset: Boolean;

{ One register, one control transfer. See the note at the top. }
function  RegRd(Reg: Byte; var V: Byte): Boolean;
function  RegWr(Reg, V: Byte): Boolean;

{ Read the six PAR registers into M, one transfer each. }
function  ReadMac(var M: TMacAddr): Boolean;

{ Reset the chip, bring the PHY up, and enable the receiver.  Promisc
  decides whether the receiver keeps frames not addressed to it, which a
  packet driver generally wants and a first test definitely does. }
function  SrBringUp(Promisc: Boolean): Boolean;

{ Is the link up, and at what speed. }
function  SrLinkUp: Boolean;
function  SrIs10Mbps: Boolean;

{ Take one frame off the bulk IN pipe.  Got comes back as the length of
  the ETHERNET FRAME, with the three-byte header and the trailing CRC
  already removed, so the caller never sees either. }
function  SrRecv(var Buf; Max: Word; var Got: Word): Boolean;

{ Put one frame on the wire.  The two-byte length header is added here. }
function  SrSend(const Buf; Len: Word): Boolean;

implementation

function RegRd(Reg: Byte; var V: Byte): Boolean;
var
  B  : array[0..3] of Byte;
  Got: Word;
  R  : Integer;
begin
  V := 0;
  B[0] := 0;
  R := CtrlIn($C0, SR_RD_REGS, 0, Word(Reg), 1, B, SizeOf(B), Got);
  if (R <> INT_SUCCESS) or (Got < 1) then
  begin
    SrErr := 'register ' + Hex2(Reg) + ' read -> ' + StatusName(R);
    RegRd := False;
    Exit;
  end;
  V := B[0];
  RegRd := True;
end;

function RegWr(Reg, V: Byte): Boolean;
var R: Integer;
begin
  { The single-register write puts the VALUE in wValue and the register in
    wIndex, and has no data stage at all. }
  R := CtrlNoData($40, SR_WR_REG, Word(V), Word(Reg));
  if R <> INT_SUCCESS then
  begin
    SrErr := 'register ' + Hex2(Reg) + ' write -> ' + StatusName(R);
    RegWr := False;
    Exit;
  end;
  RegWr := True;
end;

function ReadMac(var M: TMacAddr): Boolean;
var I: Integer;
begin
  ReadMac := False;
  for I := 0 to 5 do
    if not RegRd(SR_PAR + Byte(I), M[I]) then Exit;
  ReadMac := True;
end;

function SrLinkUp: Boolean;
var V: Byte;
begin
  SrLinkUp := False;
  if not RegRd(SR_NSR, V) then Exit;
  SrLinkUp := (V and NSR_LINKST) <> 0;
end;

function SrIs10Mbps: Boolean;
var V: Byte;
begin
  SrIs10Mbps := False;
  if not RegRd(SR_NSR, V) then Exit;
  SrIs10Mbps := (V and NSR_SPEED) <> 0;
end;

function SrBringUp(Promisc: Boolean): Boolean;
var
  V: Byte;
  Rcr: Byte;
begin
  SrBringUp := False;
  SrErr := '';

  { THE RESET IS OPTIONAL, and it is the prime suspect for the hangs.

    NCR_RST resets the network chip, and on a part where the USB front end
    shares that reset the device drops off the bus in the middle of its own
    bring-up. Every transfer after it then talks to something that is no
    longer there, and the CH375 is left mid-transaction. That is exactly
    the shape of the two hangs this cost.

    A freshly enumerated adapter has just been reset by the bus anyway, so
    skipping it loses very little and is the safer default until the
    hardware has been watched through a bring-up that completes. }
  if not SrNoReset then
  begin
    if not RegWr(SR_NCR, NCR_RST) then Exit;
    DelayMs(20);
  end;

  { Bring the PHY out of reset. Held low, then released, then a moment to
    let it start its own auto-negotiation. }
  if not RegWr(SR_PRR, PRR_PHY_RST) then Exit;
  DelayMs(20);
  if not RegWr(SR_PRR, 0) then Exit;
  DelayMs(50);

  { Receive: enabled, drop runts and oversize, let the chip strip nothing
    -- the CRC is counted in the length and discarded by SrRecv. }
  Rcr := RCR_RXEN or RCR_DIS_LONG or RCR_DIS_CRC;
  if Promisc then Rcr := Rcr or RCR_PRMSC or RCR_ALL;
  if not RegWr(SR_RCR, Rcr) then Exit;

  { Read it back. A write that does not stick is the failure that wastes
    the most time later, because everything after it looks like a receive
    problem. }
  if not RegRd(SR_RCR, V) then Exit;
  if V <> Rcr then
  begin
    SrErr := 'RCR wrote ' + Hex2(Rcr) + ' but reads back ' + Hex2(V);
    Exit;
  end;

  { SET_RETRY 00 BEFORE ANY ENDPOINT IS POLLED, and it lives HERE rather
    than in each tool so that nobody can forget it.

    BusUp arms SET_RETRY 8F -- retry NAKs indefinitely -- which is right
    for enumeration and ruinous afterwards. An idle Ethernet endpoint NAKs
    constantly by design, so with infinite retry armed the chip grinds on
    a NAK, stops answering anything, and the machine has to be power
    cycled. That is exactly what the first run of SRLINK did.

    This project has now made the same mistake three times -- CH375Audio,
    CH375Serial and here -- which is three times too many for something a
    single line prevents. Putting it at the end of the bring-up, where the
    last control transfer happens, is the only placement that is both late
    enough (the descriptors still need retries) and impossible to skip. }
  SetRetry($00);

  SrBringUp := True;
end;

{ Take ONE Ethernet frame off the bulk IN pipe, reassembling it across as
  many 64-byte USB packets as it takes.

  THE HEADER IS ONLY ON THE FIRST PACKET. That is the whole of the bug
  this replaced. A frame of any real size spans several packets, and the
  continuation packets are pure data with no header at all -- so a reader
  that treats every packet as a fresh frame decodes the first one
  correctly and then reads the MIDDLE of the frame as an Ethernet header.

  The symptom is unmistakable once seen and baffling until then: a listing
  full of plausible frames interleaved with ones whose "MAC addresses" are
  ASCII text. 70:73:32:2E:63:6F is not an address, it is "ps2.co" out of
  the middle of somebody's SSDP announcement. Every one of those was a
  continuation packet.

  The length in the header counts the four-byte CRC, so the frame proper
  is Len-4 and the CRC is read and thrown away rather than handed up. }
function SrRecv(var Buf; Max: Word; var Got: Word): Boolean;
var
  Tmp   : array[0..79] of Byte;
  N     : Byte;
  R     : Integer;
  Total : Word;         { header + frame + CRC, as the chip counts it }
  Want  : Word;         { bytes of ETHERNET FRAME we want }
  Have  : Word;         { frame bytes copied so far }
  Seen  : Word;         { bytes of this frame's total consumed }
  P     : PByte;
  I     : Word;
  Guard : Integer;
begin
  Got := 0;
  SrRecv := False;
  P := @Buf;

  R := EpIn(SrIn, SrTogIn, Tmp, SizeOf(Tmp), N);
  if R <> INT_SUCCESS then Exit;
  SrRecv := True;                 { the pipe answered; maybe with nothing }
  if N < SR_RX_OVERHEAD then Exit;

  Total := Word(Tmp[1]) or (Word(Tmp[2]) shl 8);
  if Total < 4 then Exit;         { header present, no frame behind it }
  Want := Total - 4;              { drop the CRC }
  if Want = 0 then Exit;
  if Want > Max then Want := Max;

  { Whatever of the frame arrived in this first packet. }
  Have := Word(N) - SR_RX_OVERHEAD;
  Seen := Have;
  if Have > Want then Have := Want;

  { GUARDED, because Have can legitimately be zero -- a packet carrying
    nothing but the three-byte header -- and "for I := 0 to Have - 1" on a
    Word then counts to 65535 and writes 64 KB through the pointer.

    That is the SECOND time the same wrap has taken the machine down in
    this one function, in two different places, so it is worth naming the
    shape rather than just fixing the instance: a Word loop bound that can
    be zero is a 64 KB memory smear waiting to happen, and Pascal gives no
    warning at all. Every such loop here is now guarded. }
  if Have > 0 then
    for I := 0 to Have - 1 do P[I] := Tmp[SR_RX_OVERHEAD + I];

  { Keep pulling packets until the whole frame -- CRC included -- has been
    consumed, so the NEXT call starts on a real header. Guarded by a count
    as well as by the arithmetic: a chip that stops mid-frame must not
    become an endless loop. }
  Guard := 0;
  while (Seen < Total) and (Guard < 40) do
  begin
    Inc(Guard);
    R := EpIn(SrIn, SrTogIn, Tmp, SizeOf(Tmp), N);
    if (R <> INT_SUCCESS) or (N = 0) then Break;
    for I := 0 to Word(N) - 1 do
    begin
      if Seen + I >= Total then Break;
      if Have < Want then
      begin
        P[Have] := Tmp[I];
        Inc(Have);
      end;
    end;
    Inc(Seen, Word(N));
  end;

  Got := Have;
end;

function SrSend(const Buf; Len: Word): Boolean;
var
  Tmp : array[0..63] of Byte;
  P   : PByte;
  Sent: Word;
  N   : Byte;
  I   : Byte;
  R   : Integer;
  First: Boolean;
begin
  SrSend := False;
  P := @Buf;
  Sent := 0;
  First := True;
  while (Sent < Len) or First do
  begin
    N := 0;
    if First then
    begin
      { The two-byte length header rides in front of the first packet. }
      Tmp[0] := Byte(Len and $FF);
      Tmp[1] := Byte((Len shr 8) and $FF);
      N := 2;
      First := False;
    end;
    while (N < 64) and (Sent < Len) do
    begin
      Tmp[N] := P[Sent];
      Inc(N);
      Inc(Sent);
    end;
    R := EpOut(SrOut, SrTogOut, Tmp, N);
    if R <> INT_SUCCESS then
    begin
      SrErr := 'bulk OUT -> ' + StatusName(R);
      Exit;
    end;
    if (N < 64) then Break;
  end;
  SrSend := True;
end;

begin
  SrErr := '';
  SrTogIn := $80;
  SrTogOut := $80;
  SrNoReset := False;
end.
