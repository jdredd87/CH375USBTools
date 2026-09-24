unit Ecm;

{ CDC-ECM -- USB Ethernet the way the SPEC says, not the way one vendor did.

  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  WHY THIS IS WORTH HAVING

  ax179.pas drives one chip family. Every other adapter needs its own
  bring-up, its own register map, and its own reverse engineering. CDC-ECM
  is a USB CLASS: the device describes itself, and one driver works on
  every adapter that implements it, from any vendor, including ones nobody
  here has bought yet.

  It is also dramatically simpler than a vendor path. Bulk transfers carry
  RAW ETHERNET FRAMES -- no burst header, no trailer, no entry array, no
  per-frame length field to parse. A frame ends when a short packet ends
  it. The entire AX88179 receive parser, the tiling arithmetic and the
  FCS-trimming exist because that part packs frames into bursts; none of it
  applies here.

  WHAT PROMPTED IT

  An AX88179A that reports the same USB ID as the AX88179 (0B95:1790),
  enumerates, reads its MAC, reports link up, receives frames -- and cannot
  transmit through the vendor path. That part also offers CDC-ECM as a
  configuration. So the class driver has a device to prove itself on
  immediately, and one whose alternative does not work.

  NOTHING HERE IS HARDCODED TO THAT ADAPTER

  The configuration number, interface numbers, alt setting, endpoints and
  the MAC's string index are all DISCOVERED by walking the configuration
  descriptors. Hardcoding "configuration 3" would have worked on this one
  device and made the whole exercise pointless. }

{$MODE OBJFPC}{$H-}

interface

uses Ch375;

const
  { CDC descriptor subtypes we care about, from the class spec. }
  CS_INTERFACE       = $24;
  CDC_ST_ETHERNET    = $0F;   { Ethernet Networking functional descriptor }
  CDC_ST_UNION       = $06;

  { SET_ETHERNET_PACKET_FILTER bits. Without this the device is entitled to
    hand up nothing at all, and a silent receive path is a miserable thing
    to debug. }
  ECM_PF_PROMISCUOUS = $01;
  ECM_PF_ALL_MULTI   = $02;
  ECM_PF_DIRECTED    = $04;
  ECM_PF_BROADCAST   = $08;
  ECM_PF_MULTICAST   = $10;

  ECM_MAXFRAME       = 1536;

  { How long to keep asking, in polls. Sized the way usbpkt.asm sizes its
    own OUT retry (256): long enough that a busy device is waited out,
    short enough that a device which will never answer -- an ECM adapter
    with no link, say -- reports it rather than hanging the machine. }
  OUT_NAKS           = 256;
  MID_NAKS           = 512;

type
  TEcm = record
    CfgValue : Byte;              { configuration holding the ECM function }
    CtrlIf   : Byte;              { the communications interface }
    DataIf   : Byte;              { the CDC-data interface }
    DataAlt  : Byte;              { its alt setting that HAS endpoints }
    EpIn     : Byte;              { bulk IN endpoint number }
    EpOut    : Byte;              { bulk OUT endpoint number }
    EpInt    : Byte;              { interrupt IN, link notifications, 0=none }
    MacIdx   : Byte;              { iMACAddress string index }
    MaxSeg   : Word;
    Mac      : array[0..5] of Byte;
    TogIn    : Byte;
    TogOut   : Byte;
    TogInt   : Byte;
    Err      : ShortString;
  end;

{ Walk the configurations and fill in E. False if the device has no ECM
  function at all, which is not a failure -- most adapters do not. }
function EcmFind(var E: TEcm): Boolean;

{ Select the configuration, switch the data interface to the alt setting
  that has endpoints, read the MAC and open the packet filter. }
function EcmBringUp(var E: TEcm): Boolean;

{ One Ethernet frame, split into bulk packets here because the wire has no
  framing of its own -- see the note on the zero-length packet. }
function EcmSend(var E: TEcm; const Frame; Len: Word): Boolean;

{ One frame, or False if none had arrived within Tries polls of the bulk IN
  endpoint. The budget is POLLS and not milliseconds: with the chip set to
  report NAKs (see EcmBringUp) an empty poll is a few ISA cycles, and how
  many of those fit in a millisecond is a property of the machine rather
  than of this driver. A few hundred is the right order. }
function EcmRecv(var E: TEcm; var Frame; Max: Word;
                 var Got: Word; Tries: Word): Boolean;

function EcmMacStr(const E: TEcm): ShortString;

{ Drain one notification off the interrupt endpoint, if one is waiting.

  ECM devices report the link through this endpoint, as a NETWORK_CONNECTION
  notification carrying 1 for up and 0 for down. It is worth having because
  a down link and a broken driver look identical from the transmit side: the
  device simply NAKs the bulk OUT until you give up, which is a miserable
  thing to diagnose from the symptom alone.

  Notifications are sent on CHANGE, so silence means nothing at all -- False
  here is "nothing was waiting", never "the link is down". }
function EcmNotify(var E: TEcm; var Kind: Byte; var Value: Word): Boolean;

implementation

var
  Cfg: array[0..255] of Byte;     { one configuration descriptor }
  Pkt: array[0..63] of Byte;

function Hex1(B: Byte): Char;
begin
  if B < 10 then Hex1 := Chr(48 + B) else Hex1 := Chr(55 + B);
end;

function EcmMacStr(const E: TEcm): ShortString;
var I: Integer; S: ShortString;
begin
  S := '';
  for I := 0 to 5 do
  begin
    S := S + Hex1(E.Mac[I] shr 4) + Hex1(E.Mac[I] and 15);
    if I < 5 then S := S + ':';
  end;
  EcmMacStr := S;
end;

{ --------------------------------------------------------------------
  Discovery.

  Walk every configuration, and inside it every descriptor, looking for a
  communications interface with subclass 06 (Ethernet Networking Control
  Model). Everything else -- which data interface, which alt setting, which
  endpoints, where the MAC string lives -- is read from the descriptors that
  follow it rather than assumed.
  -------------------------------------------------------------------- }
function ScanConfig(var E: TEcm; NumCfg: Byte): Boolean;
var
  I, N: Word;
  Got: Word;
  St: Integer;
  P, Len, DType: Word;
  CurIf, CurAlt: Integer;
  SeenEcm: Boolean;
  HaveData: Boolean;
  TotLen: Word;
  C: Byte;
begin
  ScanConfig := False;
  for C := 0 to NumCfg - 1 do
  begin
    { Nine bytes first, to learn wTotalLength, then the whole thing. A
      configuration descriptor is only meaningful entire: the interface and
      endpoint descriptors trail it. }
    St := GetDescr(DT_CONFIG, C, 0, Cfg, 9, Got);
    if (St <> INT_SUCCESS) or (Got < 9) then Continue;
    TotLen := Cfg[2] + (Word(Cfg[3]) shl 8);
    if TotLen > SizeOf(Cfg) then TotLen := SizeOf(Cfg);
    St := GetDescr(DT_CONFIG, C, 0, Cfg, TotLen, Got);
    if St <> INT_SUCCESS then Continue;
    N := Got;
    if N > TotLen then N := TotLen;

    SeenEcm := False;
    HaveData := False;
    CurIf := -1;
    CurAlt := -1;
    E.EpIn := 0; E.EpOut := 0; E.EpInt := 0;
    E.DataIf := 0; E.DataAlt := 0; E.MacIdx := 0;

    P := 0;
    while (P + 2 <= N) and (Cfg[P] > 0) do
    begin
      Len := Cfg[P];
      DType := Cfg[P + 1];

      if (DType = DT_INTERFACE) and (P + 9 <= N) then
      begin
        CurIf := Cfg[P + 2];
        CurAlt := Cfg[P + 3];
        { class 02, subclass 06 = Ethernet Networking Control Model }
        if (Cfg[P + 5] = $02) and (Cfg[P + 6] = $06) then
        begin
          SeenEcm := True;
          E.CtrlIf := Byte(CurIf);
          E.CfgValue := Cfg[5];
        end
        else if SeenEcm and (not HaveData)
                and (Cfg[P + 5] = $0A) and (Cfg[P + 4] >= 2) then
        begin
          { CDC data, and this alt setting actually has endpoints. Alt 0
            deliberately has none -- an idle ECM device reserves no
            bandwidth -- so selecting it and wondering why nothing moves is
            the classic ECM mistake.

            The FIRST such alt setting is taken, not the last. A device may
            offer several at different bandwidths, and without the guard the
            walk would silently end up on whichever happened to come last. }
          E.DataIf := Byte(CurIf);
          E.DataAlt := Byte(CurAlt);
          HaveData := True;
        end;
      end

      else if SeenEcm and (DType = CS_INTERFACE) and (P + 3 <= N) then
      begin
        if (Cfg[P + 2] = CDC_ST_ETHERNET) and (P + 13 <= N) then
        begin
          E.MacIdx := Cfg[P + 3];
          E.MaxSeg := Cfg[P + 8] + (Word(Cfg[P + 9]) shl 8);
        end;
      end

      else if SeenEcm and (DType = DT_ENDPOINT) and (P + 7 <= N) then
      begin
        { An endpoint descriptor belongs to whichever interface descriptor
          last preceded it, so CurIf/CurAlt say who owns this one. Taking
          any bulk endpoint that happens to appear would pick up another
          function's entirely -- and on a composite device that is an
          endpoint number which will never answer. }
        if HaveData and (CurIf = E.DataIf) and (CurAlt = E.DataAlt)
           and ((Cfg[P + 3] and 3) = 2) then        { bulk }
        begin
          if (Cfg[P + 2] and $80) <> 0 then E.EpIn := Cfg[P + 2] and $0F
          else E.EpOut := Cfg[P + 2] and $0F;
        end
        else if (CurIf = E.CtrlIf) and ((Cfg[P + 3] and 3) = 3) then
          E.EpInt := Cfg[P + 2] and $0F;            { notification }
      end;

      Inc(P, Len);
    end;

    if SeenEcm and (E.EpIn <> 0) and (E.EpOut <> 0) then
    begin
      ScanConfig := True;
      Exit;
    end;
  end;
end;

function EcmFind(var E: TEcm): Boolean;
var
  Dev: array[0..17] of Byte;
  Got: Word;
  St: Integer;
begin
  EcmFind := False;
  E.Err := '';
  St := GetDescr(DT_DEVICE, 0, 0, Dev, 18, Got);
  if (St <> INT_SUCCESS) or (Got < 18) then
  begin
    E.Err := 'no device descriptor';
    Exit;
  end;
  if not ScanConfig(E, Dev[17]) then
  begin
    E.Err := 'no CDC-ECM function in any configuration';
    Exit;
  end;
  EcmFind := True;
end;

{ --------------------------------------------------------------------
  Bring-up. Four steps, and the middle two are the ones people miss.
  -------------------------------------------------------------------- }
function EcmBringUp(var E: TEcm): Boolean;
var
  S: array[0..63] of Byte;
  Got: Word;
  St: Integer;
  I, J: Integer;
  C: Char;
  V: Byte;
begin
  EcmBringUp := False;

  St := SetConfig(E.CfgValue);
  if St <> INT_SUCCESS then
  begin
    E.Err := 'SET_CONFIGURATION ' + StatusName(St);
    Exit;
  end;

  { SET_INTERFACE to the alt setting that HAS endpoints. Alt 0 has none by
    design, so a device left there is perfectly healthy and completely
    silent -- which looks exactly like a broken driver. }
  St := CtrlNoData($01, $0B, E.DataAlt, E.DataIf);
  if St <> INT_SUCCESS then
  begin
    E.Err := 'SET_INTERFACE ' + StatusName(St);
    Exit;
  end;

  { The MAC lives in a STRING descriptor, as twelve UTF-16 hex characters.
    Not a register, not a descriptor field -- the class spec really does
    put it in a string. }
  if E.MacIdx <> 0 then
  begin
    St := GetDescr(DT_STRING, E.MacIdx, $0409, S, SizeOf(S), Got);
    if (St = INT_SUCCESS) and (Got >= 2 + 24) then
    begin
      for I := 0 to 5 do
      begin
        V := 0;
        for J := 0 to 1 do
        begin
          C := UpCase(Chr(S[2 + (I * 2 + J) * 2]));
          if (C >= '0') and (C <= '9') then V := V * 16 + (Ord(C) - 48)
          else if (C >= 'A') and (C <= 'F') then V := V * 16 + (Ord(C) - 55)
          else V := V * 16;
        end;
        E.Mac[I] := V;
      end;
    end;
  end;

  { Open the packet filter, or the device is within its rights to deliver
    nothing. Directed and broadcast is the minimum that makes ARP work;
    multicast is added because IPv6 and mDNS are cheap to accept and their
    absence is confusing. }
  St := CtrlNoData($21, $43,
                   ECM_PF_DIRECTED or ECM_PF_BROADCAST or ECM_PF_MULTICAST,
                   E.CtrlIf);
  if St <> INT_SUCCESS then
  begin
    { Not fatal: some devices default to a usable filter and STALL this. }
    E.Err := 'packet filter refused (' + StatusName(St) + '), continuing';
  end;

  { Hand the chip back to us. BusUp leaves CMD_SET_RETRY on 8F -- retry
    NAKs in hardware -- which is right while enumerating, because a device
    still waking up should be waited for. It is exactly wrong for a data
    path: a NAK there means "busy, ask again", and a chip retrying it
    forever raises no interrupt at all, so every transfer reports "no
    interrupt" and there is nothing to distinguish a busy endpoint from a
    dead one.

    Measured here on the first hardware run: frame 1 went out, then every
    later bulk OUT reported no interrupt and all 40 receive polls did too.
    ax179.pas and usbpoll.pas already do this; usbpkt.asm says the same
    thing at length and retries NAKs in software instead. This unit was
    simply missing the line. }
  SetRetry($00);

  E.TogIn := $80;
  E.TogOut := $80;
  E.TogInt := $80;
  EcmBringUp := True;
end;

{ --------------------------------------------------------------------
  A frame goes out as 64-byte packets. THE ZERO-LENGTH PACKET MATTERS.

  There is no length field anywhere in ECM: the device knows a frame has
  ended because a transfer ends with a packet SHORTER than the endpoint's
  maximum. So a frame whose length is an exact multiple of 64 must be
  followed by an explicit zero-length packet, or the device sits waiting
  for a continuation that never comes and the frame is never transmitted.
  It is the same rule the AX88179 path handles with its 8000h padding, and
  it is much easier to forget here because nothing else needs a header.
  -------------------------------------------------------------------- }
function SendPkt(var E: TEcm; N: Byte): Boolean;
var
  St: Integer;
  Tries: Word;
begin
  { A NAK on an OUT means the device's buffer is full, not that anything is
    wrong -- so it is retried here rather than reported. The toggle is only
    advanced by EpOut on success, so re-issuing the same packet is correct
    and needs no bookkeeping. }
  SendPkt := False;
  Tries := OUT_NAKS;
  repeat
    St := EpOut(E.EpOut, E.TogOut, Pkt, N);
    if St = INT_SUCCESS then begin SendPkt := True; Exit; end;
    if St <> INT_RET_NAK then
    begin
      E.Err := 'bulk OUT ' + StatusName(St);
      Exit;
    end;
    Dec(Tries);
  until Tries = 0;
  E.Err := 'bulk OUT NAKed until we gave up (link down?)';
end;

function EcmSend(var E: TEcm; const Frame; Len: Word): Boolean;
var
  P: ^Byte;
  Off, N: Word;
begin
  EcmSend := False;
  P := @Frame;
  Off := 0;
  while Off < Len do
  begin
    N := Len - Off;
    if N > 64 then N := 64;
    Move(P[Off], Pkt, N);
    if not SendPkt(E, Byte(N)) then Exit;
    Inc(Off, N);
  end;
  if (Len and 63) = 0 then
    if not SendPkt(E, 0) then Exit;
  EcmSend := True;
end;

function EcmNotify(var E: TEcm; var Kind: Byte; var Value: Word): Boolean;
var
  St: Integer;
  N8: Byte;
begin
  EcmNotify := False;
  Kind := 0;
  Value := 0;
  if E.EpInt = 0 then Exit;
  N8 := 0;
  St := EpIn(E.EpInt, E.TogInt, Pkt, 64, N8);
  if (St <> INT_SUCCESS) or (N8 < 8) then Exit;
  { The notification is a setup-packet-shaped header: bmRequestType,
    bNotification, wValue, wIndex, wLength. }
  Kind := Pkt[1];
  Value := Pkt[2] + (Word(Pkt[3]) shl 8);
  EcmNotify := True;
end;

function EcmRecv(var E: TEcm; var Frame; Max: Word;
                 var Got: Word; Tries: Word): Boolean;
var
  P: ^Byte;
  St: Integer;
  N: Word;
  N8: Byte;
  Mid: Word;
begin
  EcmRecv := False;
  Got := 0;
  P := @Frame;
  Mid := MID_NAKS;
  repeat
    N8 := 0;
    St := EpIn(E.EpIn, E.TogIn, Pkt, 64, N8);
    N := N8;
    if St = INT_RET_NAK then
    begin
      { Nothing waiting. Only a NAK on the FIRST packet means idle; one
        part-way through means the device is still assembling and is worth
        waiting out. }
      if Got = 0 then
      begin
        if Tries = 0 then Exit;
        Dec(Tries);
        Continue;
      end;
      { Part-way through a frame the device is still assembling it, so this
        one is worth waiting out -- but only for a bounded number of polls.
        The first version looped here forever, which on a device that goes
        quiet mid-frame is a wedged machine rather than a failed read. }
      if Mid = 0 then
      begin
        E.Err := 'frame stopped part-way through';
        Exit;
      end;
      Dec(Mid);
      Continue;
    end;
    if St <> INT_SUCCESS then
    begin
      E.Err := 'bulk IN ' + StatusName(St);
      Exit;
    end;
    if N > 0 then
    begin
      if Got + N > Max then N := Max - Got;
      Move(Pkt, P[Got], N);
      Inc(Got, N);
    end;
    { A short packet ends the frame -- including a zero-length one. }
    if N < 64 then
    begin
      EcmRecv := Got > 0;
      Exit;
    end;
  until Got >= Max;
  EcmRecv := Got > 0;
end;

end.
