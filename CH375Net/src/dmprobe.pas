program dmprobe;
{ DMPROBE -- read a Davicom DM96xx USB Ethernet chip's registers and say what
  it actually is.
  CH375Net, StevenC.  Public domain (the Unlicense).

      DMPROBE [/P=260] [/I=n] [/V] [/T]

        /P=hex   I/O base, default 260
        /I=dec   interface to claim. Default: the one that is NOT mass
                 storage -- see below
        /V       narrate the bring-up
        /T       trace every control-transfer stage

  WHY A SEPARATE PROBE

  `NETID` answers "what does the USB ID say", which on a re-badged part is
  a question about the box rather than the silicon.  This asks the CHIP.
  Davicom's register file is readable with one vendor control transfer and
  it contains things that cannot be faked by a label: the MAC address the
  adapter will actually use, the link status the PHY is reporting, and the
  chip revision.  If those read back as sensible values then the part is a
  DM96xx whatever the ID claims, and if they do not then it is not, and no
  amount of table-editing would have made a driver work.

  Strictly read-only.  It writes no register and changes no state, so it is
  safe to run against something that might not be a Davicom at all.

  THE TRAP THIS DEVICE CARRIES, and it is worth knowing before writing any
  driver for it: the adapter met here declares TWO interfaces, and the
  FIRST one is MASS STORAGE (class 08/06/50) with its own pair of bulk
  endpoints.  That is the "driver CD" flash that cheap dongles ship so
  Windows can install itself.  The Ethernet is the SECOND interface.

  A driver that takes the first bulk IN/OUT pair it finds -- which is the
  obvious way to write it, and what this project's own detection does --
  binds to the flash chip and then waits forever for frames from something
  that has never heard of Ethernet.  Nothing in the failure points at the
  cause.  So this tool reports both interfaces and picks by exclusion.

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering,
              6 registers do not look like a DM96xx }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '0.1.0';

  { Davicom vendor requests, as the Linux dm9601 driver issues them. }
  DM_READ_REGS = $00;
  DM_WRITE_REGS= $01;
  DM_WRITE_REG = $03;

  { The registers worth reading. }
  DM_NCR       = $00;   { network control }
  DM_NSR       = $01;   { network status -- link is bit 6 }
  DM_RCR       = $05;   { receive control }
  DM_EPCR      = $0B;   { EEPROM / PHY control }
  DM_PAR       = $10;   { six bytes of MAC }
  DM_CHIPR     = $2C;   { chip revision }

const
  { The ways a DM9601-alike might expect its register read to be framed.
    Recipient is the interesting variable: a part that routes vendor
    requests to an INTERFACE stalls -- or worse, silently ignores -- a
    device-recipient one. }
  NFRAME = 4;
  FrameName: array[0..NFRAME - 1] of ShortString = (
    'device recipient, req 00h, index = register  (Linux dm9601)',
    'interface recipient, req 00h, index = register',
    'device recipient, req 00h, VALUE = register',
    'device recipient, req 02h (read memory)');
  FrType : array[0..NFRAME - 1] of Byte = ($C0, $C1, $C0, $C0);
  FrReq  : array[0..NFRAME - 1] of Byte = ($00, $00, $00, $02);
  FrValA : array[0..NFRAME - 1] of Word = ($0000, $0000, $0000, $0000);
  FrIdxA : array[0..NFRAME - 1] of Word = ($0000, $0000, $0000, $0000);
  FrValB : array[0..NFRAME - 1] of Word = ($0000, $0000, $0010, $0000);
  FrIdxB : array[0..NFRAME - 1] of Word = ($0010, $0010, $0000, $0010);

type
  TBigCfg = array[0..1023] of Byte;

var
  Big     : TBigCfg;
  BigLen  : Word;
  Regs    : array[0..63] of Byte;
  Mac     : array[0..5] of Byte;
  VID, PID: Word;
  Rc, I   : Integer;
  S       : ShortString;
  Got     : Word;
  WantIf  : Integer;
  NetIf   : Integer;
  MassIf  : Integer;
  NetIn, NetOut, NetInt: Byte;
  Plausible: Boolean;
  Ok      : Boolean;
  Same    : Boolean;
  Honoured: Boolean;
  Alt     : array[0..63] of Byte;
  Alt2    : array[0..63] of Byte;
  One     : array[0..3] of Byte;
  AltA    : array[0..63] of Byte;
  AltB    : array[0..63] of Byte;
  Differ  : Boolean;
  Fr      : Integer;
  GoodFrame: Integer;

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

{ One vendor read of N registers starting at Reg.

  The buffer is CLEARED first and the status and length are reported,
  because the first version did neither and was thoroughly fooled: the
  request was refused, the buffer still held bytes from the configuration
  descriptor fetched moments earlier, and the tool printed those as though
  they were the chip's register file. They even looked plausible until the
  MAC came out as 03:08:00:00:00:00 -- which is an endpoint descriptor,
  not an address. A probe that cannot tell "it answered" from "it did not"
  is worse than no probe. }
function ReadRegsAs(RType, Req: Byte; Val, Idx: Word;
                    N: Byte; var Buf): Boolean;
var
  R, K: Integer;
  P: PByte;
begin
  P := @Buf;
  for K := 0 to 63 do P[K] := $CC;      { poison, so stale data shows up }
  Got := 0;
  R := CtrlIn(RType, Req, Val, Idx, N, Buf, 64, Got);
  Write('    type ', Hex2(RType), ' req ', Hex2(Req),
        ' val ', Hex4(Val), ' idx ', Hex4(Idx),
        ' -> ', StatusName(R), ', ', Got, ' bytes');
  if (R = INT_SUCCESS) and (Got >= N) then
  begin
    WriteLn('   OK');
    ReadRegsAs := True;
  end
  else
  begin
    WriteLn;
    ReadRegsAs := False;
  end;
end;

function ReadRegs(Reg, N: Byte; var Buf): Boolean;
begin
  ReadRegs := ReadRegsAs($C0, DM_READ_REGS, 0, Reg, N, Buf);
end;

{ Walk the configuration descriptor and separate the Ethernet interface
  from the mass-storage one. }
procedure FindInterfaces;
var
  P    : Word;
  L, T : Byte;
  CurIf: Integer;
  Cls  : Byte;
  Addr, Attr: Byte;
begin
  NetIf := -1; MassIf := -1;
  NetIn := 0; NetOut := 0; NetInt := 0;
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
      else if NetIf < 0 then
        NetIf := CurIf;
    end
    else if (T = $05) and (CurIf = NetIf) and (NetIf >= 0) then
    begin
      Addr := Big[P + 2];
      Attr := Big[P + 3] and $03;
      if Attr = 2 then
      begin
        if (Addr and $80) <> 0 then
        begin
          if NetIn = 0 then NetIn := Addr and $0F;
        end
        else if NetOut = 0 then NetOut := Addr and $0F;
      end
      else if (Attr = 3) and ((Addr and $80) <> 0) then
        if NetInt = 0 then NetInt := Addr and $0F;
    end;
    Inc(P, L);
  end;
end;

begin
  Banner('DMPROBE', VER, 'Davicom DM96xx register probe');
  if HelpWanted then
  begin
    WriteLn('  DMPROBE [/P=260] [/I=n] [/V] [/T]');
    WriteLn;
    WriteLn('    /I=n  interface to claim; default is the non-storage one');
    WriteLn('    /V    narrate the bring-up');
    HelpTail;
    Halt(0);
  end;

  WantIf := -1;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base := HexArg(S, 4);
      'I': WantIf := NumArg(S, 4);
      'V': Trace := @Narrate;
      'T': CtrlTrace := True;
    end;
  end;
  if CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');

  if not ChipHere(Base) then
  begin
    WriteLn('CHECK_EXIST found nothing -- resetting and re-asking.');
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

  { The whole configuration, in two fetches -- the second is what the
    chip's 64-byte GET_DESCR shortcut cannot do, and this device's
    descriptor is 69 bytes, which is exactly why a binary built before
    that fallback existed failed here with "the device answered, then
    stopped". }
  Rc := GetDescr(DT_CONFIG, 0, 0, Big, 9, BigLen);
  if BigLen < 9 then
  begin
    WriteLn('  cannot read the configuration header (', StatusName(Rc), ')');
    Halt(5);
  end;
  I := Big[2] or (Integer(Big[3]) shl 8);
  if I > SizeOf(Big) then I := SizeOf(Big);
  Rc := GetDescr(DT_CONFIG, 0, 0, Big, I, BigLen);
  if BigLen < Word(I) then
  begin
    WriteLn('  short configuration descriptor (', BigLen, ' of ', I, ')');
    Halt(5);
  end;
  Fld('config descriptor', Dec1(BigLen) + ' bytes');

  Rc := SetConfig(Big[5]);
  Fld('SET_CONFIGURATION', Dec1(Big[5]) + ' -> ' + StatusName(Rc));
  if Rc <> INT_SUCCESS then Halt(5);

  FindInterfaces;
  if WantIf >= 0 then NetIf := WantIf;
  WriteLn;
  WriteLn('INTERFACES');
  WriteLn('----------------------------------------------------------------');
  if MassIf >= 0 then
  begin
    WriteLn('  interface ', MassIf, '  MASS STORAGE -- the driver-CD flash,');
    WriteLn('               not the network. A driver that takes the first');
    WriteLn('               bulk pair it finds binds to THIS.');
  end;
  if NetIf < 0 then
  begin
    WriteLn('  no non-storage interface found.');
    Halt(6);
  end;
  WriteLn('  interface ', NetIf, '  the Ethernet one');
  Fld('bulk IN', Hex2(NetIn or $80));
  Fld('bulk OUT', Hex2(NetOut));
  if NetInt <> 0 then Fld('interrupt IN', Hex2(NetInt or $80));

  WriteLn;
  WriteLn('CHIP REGISTERS');
  WriteLn('----------------------------------------------------------------');
  { EVERY FRAMING, EACH JUDGED BY A/B/A -- because "success" means nothing.

    The first version tried framings in order and stopped at the first one
    that returned INT_SUCCESS. That was useless here: this device answers
    the very first framing with success and 32 bytes, so the alternatives
    were never tried at all. The bytes turned out to be its own descriptor
    residue sitting in the CH375's buffer.

    So success is not the test. The test is whether the register INDEX
    changes the answer, and the honest way to ask is A/B/A: read index 0,
    read index 10h, read index 0 again. Only "the two reads of 0 agree AND
    the middle one differs" means the device is really decoding wIndex.
    Anything else is a buffer, and a buffer will happily agree with itself
    all day. }
  { CLAIM THE INTERFACE FIRST.

    This is a composite device -- mass storage on interface 0, network on
    interface 1 -- and nothing had ever selected the network one. A
    function on a composite part is entitled to ignore vendor requests
    until its interface is claimed, and SET_CONFIGURATION alone does not
    claim anything. It costs one control transfer to rule out. }
  Rc := CtrlNoData($01, REQ_SET_IFACE, 0, Word(NetIf));
  WriteLn('  SET_INTERFACE ', NetIf, ' alt 0 -> ', StatusName(Rc));
  WriteLn;

  Honoured := False;
  WriteLn('  trying each framing, judged by A/B/A rather than by status:');
  for Fr := 0 to NFRAME - 1 do
  begin
    WriteLn;
    WriteLn('  [', Fr + 1, '] ', FrameName[Fr]);
    if not ReadRegsAs(FrType[Fr], FrReq[Fr], FrValA[Fr],
                      FrIdxA[Fr], 8, AltA) then Continue;
    if not ReadRegsAs(FrType[Fr], FrReq[Fr], FrValB[Fr],
                      FrIdxB[Fr], 8, Alt) then Continue;
    if not ReadRegsAs(FrType[Fr], FrReq[Fr], FrValA[Fr],
                      FrIdxA[Fr], 8, AltB) then Continue;
    Write('      A:');
    for I := 0 to 7 do Write(' ', Hex2(AltA[I]));
    WriteLn;
    Write('      B:');
    for I := 0 to 7 do Write(' ', Hex2(Alt[I]));
    WriteLn;
    Write('      A:');
    for I := 0 to 7 do Write(' ', Hex2(AltB[I]));
    WriteLn;
    Same := True;
    for I := 0 to 7 do if AltA[I] <> AltB[I] then Same := False;
    Differ := False;
    for I := 0 to 7 do if AltA[I] <> Alt[I] then Differ := True;
    if Same and Differ then
    begin
      WriteLn('      -> INDEX HONOURED. This framing reaches real registers.');
      Honoured := True;
      GoodFrame := Fr;
      Break;
    end
    else if not Same then
      WriteLn('      -> the same request twice gave different answers.')
    else
      WriteLn('      -> the index makes no difference.');
  end;

  { A single-byte read, which is how most drivers actually poll a status
    register. A device with a fixed-size reply block might only decode the
    index when asked for exactly one. }
  if not Honoured then
  begin
    WriteLn;
    WriteLn('  one byte at a time, A/B/A:');
    ReadRegsAs($C0, DM_READ_REGS, 0, $00, 1, AltA);
    ReadRegsAs($C0, DM_READ_REGS, 0, $01, 1, Alt);
    ReadRegsAs($C0, DM_READ_REGS, 0, $00, 1, AltB);
    WriteLn('    00h=', Hex2(AltA[0]), '  01h=', Hex2(Alt[0]),
            '  00h=', Hex2(AltB[0]));
    if (AltA[0] = AltB[0]) and (AltA[0] <> Alt[0]) then
    begin
      WriteLn('    -> INDEX HONOURED for single-byte reads.');
      Honoured := True;
      GoodFrame := 0;
    end
    else
      WriteLn('    -> no.');
  end;

  if not Honoured then
  begin
    WriteLn;
    WriteLn('  No framing decodes a register index.');
    WriteLn;
    WriteLn('VERDICT');
    WriteLn('----------------------------------------------------------------');
    WriteLn('  This device answers vendor control reads with SUCCESS and then');
    WriteLn('  returns whatever was last in the buffer -- its own descriptor');
    WriteLn('  bytes. That is not a Davicom register file, and no amount of');
    WriteLn('  adding 0FE6:9702 to a chipset table would have made a driver');
    WriteLn('  work. Something else drives this part.');
    WriteLn;
    WriteLn('  Worth knowing: a success status from a CH375 control transfer');
    WriteLn('  is not evidence the DEVICE understood the request. It is only');
    WriteLn('  evidence the transfer completed. Anything that reads back a');
    WriteLn('  device must prove the device is answering, and comparing two');
    WriteLn('  different reads is the cheapest proof there is.');
    Halt(6);
  end;

  { ONE REGISTER PER TRANSFER, because this part cannot do more.

    The multi-byte read returns a fixed eight-byte block whatever index is
    asked for, and only the single-byte form decodes wIndex. That is a
    defect in the clone rather than in the protocol -- the Linux driver
    reads blocks freely, and on a genuine part so could we -- but it is
    the shape of the thing in front of us, so the probe reads 32 registers
    with 32 transfers and says so rather than pretending.

    Anything built on this later must do the same. A driver that fetches
    the six MAC bytes in one go gets that fixed block instead and comes up
    with an address the adapter does not have. }
  WriteLn;
  WriteLn('  reading 32 registers, one transfer each');
  for I := 0 to 31 do
  begin
    Got := 0;
    Rc := CtrlIn($C0, DM_READ_REGS, 0, Word(I), 1, One, 4, Got);
    if (Rc = INT_SUCCESS) and (Got >= 1) then
      Regs[I] := One[0]
    else
      Regs[I] := $FF;
  end;

  WriteLn;
  Write('  00-0F:');
  for I := 0 to 15 do Write(' ', Hex2(Regs[I]));
  WriteLn;
  Write('  10-1F:');
  for I := 16 to 31 do Write(' ', Hex2(Regs[I]));
  WriteLn;

  WriteLn;
  Fld('NCR  (net control)', Hex2(Regs[DM_NCR]));
  Fld('NSR  (net status)', Hex2(Regs[DM_NSR]));
  if (Regs[DM_NSR] and $40) <> 0 then
    WriteLn('                        link UP')
  else
    WriteLn('                        link down (no cable?)');
  Fld('RCR  (rx control)', Hex2(Regs[DM_RCR]));

  for I := 0 to 5 do Mac[I] := Regs[DM_PAR + I];
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(Mac[I]);
  end;
  Fld('MAC (PAR 10-15)', S);

  { Does it look real? A MAC of all zeroes or all FFs is what an
    unprogrammed part or a failed read gives, and a multicast bit set in
    the first octet is not something a real adapter ships with. }
  Plausible := Honoured;
  if (Mac[0] or Mac[1] or Mac[2] or Mac[3] or Mac[4] or Mac[5]) = 0 then
    Plausible := False;
  if (Mac[0] and Mac[1] and Mac[2] and Mac[3] and Mac[4] and Mac[5]) = $FF then
    Plausible := False;
  if (Mac[0] and $01) <> 0 then Plausible := False;

  WriteLn;
  WriteLn('VERDICT');
  WriteLn('----------------------------------------------------------------');
  if Plausible then
  begin
    WriteLn('  The register file answers and the MAC is a sane unicast');
    WriteLn('  address, so this really is a Davicom DM96xx whatever its');
    WriteLn('  USB ID claims. A driver can be written against it.');
    Halt(0);
  end
  else
  begin
    if not Honoured then
    begin
      WriteLn('  The transfer reports success but the register INDEX makes no');
      WriteLn('  difference to what comes back, and what comes back is this');
      WriteLn('  device''s own descriptor bytes. So the request is not being');
      WriteLn('  implemented: the chip is answering with a zero-length data');
      WriteLn('  stage and the CH375 is handing us its previous buffer.');
      WriteLn;
      WriteLn('  This is NOT a Davicom DM96xx, whatever the 0FE6 vendor ID');
      WriteLn('  range suggests. Identify it before writing a driver.');
    end
    else
    begin
      WriteLn('  The register read succeeded but the MAC is ', S, ', which is');
      WriteLn('  not a usable address. Either the EEPROM is blank or this is');
      WriteLn('  not the chip its registers appear to be.');
    end;
    Halt(6);
  end;
end.
