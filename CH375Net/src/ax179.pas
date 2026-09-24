unit ax179;
{ AX179 -- the ASIX AX88179 as reached through a CH375 in host mode.
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  Everything that knows what an AX88179 is lives here: the register map,
  the two vendor requests, the bring-up sequence, and the bulk read that
  collects one transfer.  USBLINK, USBRECV and eventually the packet driver
  are all thin things sitting on top of it.

  The register numbers are the Linux ax88179_178a driver's, and they were
  checked against the real part before a line of this was written --
  AX_ACCESS_MAC with AX_NODE_ID returned the same plausible MAC four times
  running, and the status registers decoded sensibly.  That is what says
  the map is right for this silicon, rather than merely plausible.

  WHAT THIS UNIT DOES NOT DO.  Transmit.  It also does not interpret the
  receive buffer -- AxRxBurst hands back the bytes exactly as the chip
  produced them, because the layout is the thing USBRECV exists to
  establish rather than assume.  See the note above AxRxBurst.

  NO crt UNIT, here or anywhere in this repository: it bypasses stdout and
  anything capturing the output gets nothing. }

{$MODE OBJFPC}{$H-}

interface

uses ch375;

const
  AX_VENDOR        = $0B95;    { ASIX }
  AX_PID_88179     = $1790;

  { ---- the two vendor requests everything is built from.  Both put the
    register number in wValue and its length in wIndex, which is unusual
    enough to be worth saying once. ---- }
  AX_ACCESS_MAC    = $01;
  AX_ACCESS_PHY    = $02;

  { ---- MAC-side registers ---- }
  AX_PHYSICAL_LINK = $02;      { 01 = full speed, 02 = high, 04 = super }
  AX_GENERAL_STATUS= $03;      { bit 2 = EEPROM/eFuse config loaded }
  AX_RX_CTL        = $0B;
  AX_NODE_ID       = $10;
  AX_MEDIUM_MODE   = $22;
  AX_MONITOR_MODE  = $24;
  AX_PHYPWR_RSTCTL = $26;
  AX_RX_BULK_QCTRL = $2E;
  AX_CLK_SELECT    = $33;
  AX_RXCOE_CTL     = $34;
  AX_TXCOE_CTL     = $35;
  AX_PAUSE_HIGH    = $54;
  AX_PAUSE_LOW     = $55;

  { ---- RX_CTL bits ---- }
  RX_CTL_STOP      = $0000;
  RX_CTL_PROMISC   = $0001;
  RX_CTL_ALLMULTI  = $0002;
  RX_CTL_BROADCAST = $0008;
  RX_CTL_MULTICAST = $0010;
  RX_CTL_ACCEPT_PHY= $0020;    { frames addressed to our own MAC }
  RX_CTL_START     = $0080;
  RX_CTL_DROP_CRC  = $0100;
  RX_CTL_IP_ALIGN  = $0200;    { pads each frame by 2 -- see AxInit }

  { ---- MEDIUM_MODE bits ---- }
  MED_GIGA         = $0001;
  MED_FULL_DUPLEX  = $0002;
  MED_ALWAYS_ONE   = $0004;
  MED_EN_125MHZ    = $0008;
  MED_RXFLOW_EN    = $0010;
  MED_TXFLOW_EN    = $0020;
  MED_RECEIVE_EN   = $0100;
  MED_PS           = $0200;    { 100 Mbps when GIGA is clear }

  AX_PHY_ID        = $03;      { the internal PHY's MDIO address }

  { ---- standard MII registers ---- }
  MII_BMCR         = 0;
  MII_BMSR         = 1;
  MII_PHYSID1      = 2;
  MII_PHYSID2      = 3;
  MII_ANAR         = 4;
  MII_ANLPAR       = 5;
  MII_GBCR         = 9;

  BMCR_ANRESTART   = $0200;
  BMCR_ANENABLE    = $1000;
  BMSR_LINK        = $0004;
  BMSR_ANEGCOMPLETE= $0020;

  AX_EP_INT        = 1;        { EP 81, link status, 8 bytes }
  AX_EP_BULK_IN    = 2;        { EP 82, frames in  }
  AX_EP_BULK_OUT   = 3;        { EP 03, frames out }

  AX_MAXFRAME      = 1514;

type
  TMac = array[0..5] of Byte;

var
  Mac:      TMac;              { filled by AxInit }
  AxTrace:  Boolean = False;   { print every register access }

  { AX_RX_BULK_QCTRL, the five bytes that decide how much the chip piles
    into one bulk transfer.  Getting these wrong is not subtle: with the
    control byte at zero NO limit is enabled, so the chip keeps appending
    frames for as long as traffic arrives and the transfer simply never
    ends.  One capture ran to 55,680 bytes before the buffer gave up.

    Control 7 enables all three limits -- size, timer and inter-frame gap.
    AxBulkSize is what makes a transfer small enough for a machine that
    drains it 64 bytes at a time; Linux uses 0x18 here because it has 20 KB
    of URB to fill and can absorb it. }
  AxBulkCtrl: Byte = $07;
  { 01, not 02.  This is the adapter's aggregation buffer in KB, and it has
    to be smaller than the driver's receive buffer with room for the metadata
    that follows the frames -- not merely equal to it.  USBPKT's rxbuf is 2048
    bytes, so at 02 every single burst overflowed it by the width of the
    trailer, and an overflowed burst is not a truncated burst: the remainder
    has to be read and thrown away to find the next boundary, so the whole
    thing is lost.  1 KB bursts also read inside one timer tick on a machine
    which 2 KB does not. }
  AxBulkSize: Byte = $01;
  AxBulkTimer: Word = $0080;   { flush early rather than wait for a full
                                 burst -- latency matters more than
                                 efficiency at these speeds }
  AxBulkIfg:  Byte = $08;
  AxStep:   procedure(const What: ShortString; St: Integer) = nil;
                               { set it and AxInit narrates itself }

{ ---- register access ---- }
function AxMacRd(Reg: Byte; Len: Word; var Buf): Integer;
function AxMacWr(Reg: Byte; Len: Word; const Buf): Integer;
function AxMacWr8(Reg: Byte; V: Byte): Integer;
function AxMacWr16(Reg: Byte; V: Word): Integer;
function AxMacRd16(Reg: Byte; var V: Word): Integer;
function AxPhyRd(Reg: Byte; var V: Word): Integer;
function AxPhyWr(Reg: Byte; V: Word): Integer;

{ ---- bring-up ----
  AxInit powers the PHY, sets the clocks, reads the MAC into Mac, turns
  off everything that would change the frame layout, and starts the
  receiver.  True if every step succeeded. }
function  AxInit(Promisc: Boolean): Boolean;

{ Restrict the PHY's advertisement and restart autonegotiation.  TenOnly
  withdraws the gigabit and 100 offers -- see USBLINK's header for why
  that is the right default on an 8086 and not on a 486. }
function  AxNegotiate(TenOnly: Boolean): Boolean;

{ Poll BMSR until the link comes up or Secs elapses. }
function  AxLinkWait(Secs: Word; var Bmsr: Word): Boolean;

{ Tell the MAC what the PHY negotiated.  The MAC does not learn the speed
  by itself, and a link that is up while the medium register disagrees
  passes no traffic at all. }
function  AxSetMedium(Giga: Boolean): Integer;

function  MacStr(const M: TMac): ShortString;

{ ---- receive ----
  Collects ONE bulk transfer: 64-byte packets until a short one ends it.
  Len comes back as the total.

  It returns the bytes exactly as the chip produced them and interprets
  nothing.  The AX88179 does not put a bare frame on this endpoint -- the
  buffer ends with a count and an offset pointing at a metadata array
  earlier in the same buffer -- and establishing that layout empirically,
  rather than trusting a recollection of somebody else's driver, is the
  whole job of USBRECV.

  Returns INT_SUCCESS with Len > 0 when something arrived, INT_RET_NAK
  when the endpoint had nothing (which is the normal idle case and not an
  error), or a CH375 error code. }
function  AxRxBurst(var Buf; Max: Word; var Len: Word): Integer;
procedure AxRxReset;           { forget the data toggle, after a stall }

{ ---- transmit ----
  The AX88179 wants an 8-byte header in front of every frame: two
  little-endian 32-bit words.  The first is the frame length.  The second
  is zero, except that when the whole thing -- header included -- comes to
  an exact multiple of the endpoint's packet size, bit 15 and bit 31 are
  set to tell the chip padding follows.  That case also needs a
  zero-length packet to terminate the USB transfer, which is a separate
  requirement that happens to arise at the same moment and is easy to
  confuse with it. }
function  AxTxFrame(const Frame; Len: Word): Integer;
procedure AxTxReset;

var
  { Bytes AxRxBurst had to read and throw away because Buf was full.
    Non-zero means the buffer is too small for what the chip is sending,
    and the burst in Buf is a fragment rather than a transfer -- its
    trailer will be somewhere in the discarded part. }
  AxRxOver: Word = 0;

implementation

var
  RxTog: Byte = $80;           { SET_ENDP6 argument; bit 6 is the toggle }
  TxTog: Byte = $80;           { SET_ENDP7, same arrangement }
  TxBuf: array[0..8 + AX_MAXFRAME] of Byte;

procedure Say(const S: ShortString);
begin
  if AxTrace then WriteLn('    ', S);
end;

procedure Note(const What: ShortString; St: Integer);
begin
  if AxStep <> nil then AxStep(What, St);
end;

function AxMacRd(Reg: Byte; Len: Word; var Buf): Integer;
var Got: Word; St: Integer;
begin
  St := CtrlIn($C0, AX_ACCESS_MAC, Reg, Len, Len, Buf, Len, Got);
  Say('MAC[' + Hex2(Reg) + '] read ' + Hex4(Len) + ' -> ' + StatusStr(St));
  if (St >= 0) and (Got <> Len) then St := -1;
  AxMacRd := St;
end;

function AxMacWr(Reg: Byte; Len: Word; const Buf): Integer;
var St: Integer;
begin
  St := CtrlOut($40, AX_ACCESS_MAC, Reg, Len, Buf, Byte(Len));
  Say('MAC[' + Hex2(Reg) + '] write ' + Hex4(Len) + ' -> ' + StatusStr(St));
  AxMacWr := St;
end;

function AxMacWr8(Reg: Byte; V: Byte): Integer;
begin
  AxMacWr8 := AxMacWr(Reg, 1, V);
end;

function AxMacWr16(Reg: Byte; V: Word): Integer;
begin
  { The chip is little-endian and so is the 8086, so a Word goes out low
    byte first with no swapping anywhere in this unit. }
  AxMacWr16 := AxMacWr(Reg, 2, V);
end;

function AxMacRd16(Reg: Byte; var V: Word): Integer;
begin
  AxMacRd16 := AxMacRd(Reg, 2, V);
end;

function AxPhyRd(Reg: Byte; var V: Word): Integer;
var Got: Word; St: Integer;
begin
  St := CtrlIn($C0, AX_ACCESS_PHY, AX_PHY_ID, Reg, 2, V, 2, Got);
  Say('PHY[' + Hex2(Reg) + '] read -> ' + StatusStr(St) + ' ' + Hex4(V));
  if (St >= 0) and (Got <> 2) then St := -1;
  AxPhyRd := St;
end;

function AxPhyWr(Reg: Byte; V: Word): Integer;
var St: Integer;
begin
  St := CtrlOut($40, AX_ACCESS_PHY, AX_PHY_ID, Reg, V, 2);
  Say('PHY[' + Hex2(Reg) + '] write ' + Hex4(V) + ' -> ' + StatusStr(St));
  AxPhyWr := St;
end;

function MacStr(const M: TMac): ShortString;
var S: ShortString; I: Integer;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(M[I]);
  end;
  MacStr := S;
end;

function AxInit(Promisc: Boolean): Boolean;
var
  Ok: Boolean;
  Q: array[0..4] of Byte;
  W: Word;

  procedure Do1(const What: ShortString; S: Integer);
  begin
    Note(What, S);
    if S < 0 then Ok := False;
  end;

var
  CfgVal: Byte;
begin
  Ok := True;

  { SET_CONFIGURATION FIRST, and it is not optional.  BusUp fetches the
    descriptors and assigns the address, and stops there -- a device that
    has an address but no configuration is in Address state, where its
    endpoints do not exist yet.  Control transfers to endpoint 0 work
    perfectly in that state, which is exactly what makes this trap so
    good: every register read and write below succeeded, the link came
    up, and then every single IN token to the bulk endpoint timed out.
    7056 of them, in the run that found this.

    The value comes out of the configuration descriptor rather than being
    assumed to be 1 -- it usually is, and it is not guaranteed to be. }
  CfgVal := CfgDesc[5];
  if CfgVal = 0 then CfgVal := 1;
  Do1('set configuration ' + Hex2(CfgVal), SetConfig(CfgVal));

  { Stop the chip retrying NAKs.  BusUp sets 8F -- retry for ever -- which
    is right while enumerating, because a device that is still waking up
    should be waited for rather than given up on.  It is exactly wrong for
    polling an endpoint that is idle most of the time: the CH375 sits
    there retrying instead of reporting, our own wait expires, and the
    poll comes back as "no interrupt" having taken seconds.  That is what
    it looked like when found -- two polls in nine seconds.  With no
    retry, an idle endpoint answers NAK immediately and the loop runs at
    full speed. }
  SetRetry($00);
  Note('no NAK retry while polling', 0);

  { Two writes, not one: the reset line has to be seen low and then high.
    The 200 ms afterwards is not optional -- the PHY is still coming out
    of reset before then and answers MDIO with all ones. }
  Do1('PHY power/reset low',  AxMacWr16(AX_PHYPWR_RSTCTL, $0000));
  DelayMs(20);
  Do1('PHY power/reset high', AxMacWr16(AX_PHYPWR_RSTCTL, $0020));
  DelayMs(200);
  Do1('clock select',         AxMacWr8(AX_CLK_SELECT, $03));
  DelayMs(100);

  Do1('read MAC address',     AxMacRd(AX_NODE_ID, 6, Mac));

  { The bulk-in queue is where this parts company with the Linux driver:
    same register, opposite goal.  Linux wants big transfers because it
    can absorb them; this wants small ones because it cannot.  See the
    note by AxBulkCtrl -- zeroing the register does NOT mean "no
    aggregation", it means "no limit", which is the opposite. }
  Q[0] := AxBulkCtrl;
  Q[1] := Byte(AxBulkTimer and $FF);
  Q[2] := Byte(AxBulkTimer shr 8);
  Q[3] := AxBulkSize;
  Q[4] := AxBulkIfg;
  Do1('bulk-in queue, size ' + Hex2(AxBulkSize),
      AxMacWr(AX_RX_BULK_QCTRL, 5, Q));

  Do1('pause watermark low',  AxMacWr8(AX_PAUSE_LOW,  $34));
  Do1('pause watermark high', AxMacWr8(AX_PAUSE_HIGH, $52));

  { Checksum offload off: it changes the layout on both paths, and a
    first driver has enough to get right without it. }
  Do1('rx checksum offload off', AxMacWr8(AX_RXCOE_CTL, $00));
  Do1('tx checksum offload off', AxMacWr8(AX_TXCOE_CTL, $00));
  Do1('wake-on-LAN monitor off', AxMacWr8(AX_MONITOR_MODE, $00));

  { IP_ALIGN deliberately clear.  It pads every frame by two bytes so an
    IP header lands on a word boundary, which matters to a CPU that
    faults on unaligned access and not at all to an 8086.  Off means one
    less thing between the wire and the parser -- and USBRECV checks that
    the frames really do start where that implies. }
  W := RX_CTL_START or RX_CTL_ACCEPT_PHY or RX_CTL_BROADCAST or
       RX_CTL_DROP_CRC;
  if Promisc then W := W or RX_CTL_PROMISC or RX_CTL_ALLMULTI;
  Do1('rx control', AxMacWr16(AX_RX_CTL, W));

  RxTog := $80;
  TxTog := $80;
  AxInit := Ok;
end;

function AxNegotiate(TenOnly: Boolean): Boolean;
var Ok: Boolean;

  procedure Do1(const What: ShortString; S: Integer);
  begin
    Note(What, S);
    if S < 0 then Ok := False;
  end;

begin
  Ok := True;
  if TenOnly then
  begin
    { Restricting the advertisement rather than forcing the speed: the far
      end then agrees to 10BASE-T through ordinary autonegotiation instead
      of being left to work out why its partner went quiet.  ANAR 0061 is
      10BASE-T half and full with the 802.3 selector; GBCR 0 withdraws the
      gigabit offer. }
    Do1('withdraw 1000BASE-T advertisement', AxPhyWr(MII_GBCR, $0000));
    Do1('advertise 10BASE-T only',           AxPhyWr(MII_ANAR, $0061));
  end;
  Do1('restart autonegotiation',
      AxPhyWr(MII_BMCR, BMCR_ANENABLE or BMCR_ANRESTART));
  AxNegotiate := Ok;
end;

function AxLinkWait(Secs: Word; var Bmsr: Word): Boolean;
var T0: LongInt;
begin
  T0 := Ticks;
  Bmsr := 0;
  while True do
  begin
    DelayMs(250);
    { BMSR latches link-down low, so it is read twice by convention: the
      first read clears the latch and the second is the current state. }
    if AxPhyRd(MII_BMSR, Bmsr) < 0 then Break;
    if AxPhyRd(MII_BMSR, Bmsr) < 0 then Break;
    if (Bmsr and BMSR_LINK) <> 0 then Break;
    if Word((Ticks - T0) div 18) >= Secs then Break;
    if KeyWaiting then begin EatKey; Break; end;
  end;
  AxLinkWait := (Bmsr and BMSR_LINK) <> 0;
end;

function AxSetMedium(Giga: Boolean): Integer;
var Med: Word;
begin
  Med := MED_RECEIVE_EN or MED_ALWAYS_ONE or MED_RXFLOW_EN or
         MED_TXFLOW_EN or MED_FULL_DUPLEX;
  if Giga then Med := Med or MED_GIGA or MED_EN_125MHZ;
  AxSetMedium := AxMacWr16(AX_MEDIUM_MODE, Med);
end;

procedure AxRxReset;
begin
  RxTog := $80;
end;

function AxRxBurst(var Buf; Max: Word; var Len: Word): Integer;
var
  P: PByte;
  Got: Byte;
  St: Integer;
  Waits: Word;
  Drain: Word;
  Scratch: array[0..63] of Byte;
begin
  P := @Buf;
  Len := 0;
  AxRxOver := 0;
  Waits := 0;
  while True do
  begin
    if Len + 64 > Max then
    begin
      { The buffer is full and the transfer is not finished.  Leaving it
        half-drained is the worst thing we could do -- the next read would
        pick up the middle of this transfer and every burst after it would
        be garbage -- so the remainder is read and discarded, and the
        caller is told how much went missing. }
      { Bounded, and it has to be.  The chip can stream continuously --
        one capture ran to 55,680 bytes without a short packet -- so an
        unbounded drain on a busy network never returns, and a DOS program
        that never returns takes the machine with it.  64 KB is far more
        than any sane burst and still finite. }
      Drain := 0;
      repeat
        St := EpIn(AX_EP_BULK_IN, RxTog, Scratch, 64, Got);
        if St <> INT_SUCCESS then Break;
        AxRxOver := AxRxOver + Got;
        Inc(Drain);
      until (Got < 64) or (Drain >= 1024);
      Break;
    end;
    St := EpIn(AX_EP_BULK_IN, RxTog, P[Len], 64, Got);
    if St <> INT_SUCCESS then
    begin
      { A NAK on the FIRST read is the idle case: nothing was waiting,
        and the caller wants to know that rather than see an error.

        A NAK is not the end of anything.  In USB a bulk transfer ends
        with a SHORT packet -- fewer than 64 bytes, possibly zero -- and a
        NAK in the middle only means "not ready yet, ask again".  Ending
        the burst here truncated every multi-frame transfer: the first
        capture stopped at 256 bytes with a second frame cut in half and
        the trailer nowhere in it, which is what sent this looking for a
        layout that was not the problem.

        So mid-burst NAKs are retried, and only run out of patience after
        a bounded number of them -- a device that has genuinely stopped
        mid-transfer would otherwise hang the loop for ever. }
      if (St = INT_RET_NAK) and (Len > 0) then
      begin
        Inc(Waits);
        if Waits < 2000 then Continue;
      end;
      AxRxBurst := St;
      Exit;
    end;
    Len := Len + Got;
    Waits := 0;                          { progress: patience resets }
    if Got < 64 then Break;              { a short packet ends a transfer }
  end;
  AxRxBurst := INT_SUCCESS;
end;

procedure AxTxReset;
begin
  TxTog := $80;
end;

function AxTxFrame(const Frame; Len: Word): Integer;
var
  P: PByte;
  I, Total, Ofs, Chunk: Word;
  Flags: LongInt;
  St: Integer;
begin
  if (Len < 14) or (Len > AX_MAXFRAME) then
  begin
    AxTxFrame := -1;
    Exit;
  end;

  P := @Frame;

  { Header word 1: the length.  Word 2: the padding flag, and only when
    the total lands exactly on a packet boundary. }
  TxBuf[0] := Byte(Len and $FF);
  TxBuf[1] := Byte((Len shr 8) and $FF);
  TxBuf[2] := 0;
  TxBuf[3] := 0;
  Total := Len + 8;
  if (Total mod 64) = 0 then Flags := $80008000 else Flags := 0;
  TxBuf[4] := Byte(Flags and $FF);
  TxBuf[5] := Byte((Flags shr 8) and $FF);
  TxBuf[6] := Byte((Flags shr 16) and $FF);
  TxBuf[7] := Byte((Flags shr 24) and $FF);

  for I := 0 to Len - 1 do TxBuf[8 + I] := P[I];

  { Out in 64-byte packets.  A transfer ends with a short packet, so when
    the total is an exact multiple of 64 an explicit zero-length one has
    to be sent or the far end waits for more that never comes. }
  Ofs := 0;
  while Ofs < Total do
  begin
    Chunk := Total - Ofs;
    if Chunk > 64 then Chunk := 64;
    St := EpOut(AX_EP_BULK_OUT, TxTog, TxBuf[Ofs], Byte(Chunk));
    if St <> INT_SUCCESS then
    begin
      AxTxFrame := St;
      Exit;
    end;
    Ofs := Ofs + Chunk;
  end;
  if (Total mod 64) = 0 then
  begin
    St := EpOut(AX_EP_BULK_OUT, TxTog, TxBuf[0], 0);
    if St <> INT_SUCCESS then
    begin
      AxTxFrame := St;
      Exit;
    end;
  end;

  AxTxFrame := INT_SUCCESS;
end;

end.
