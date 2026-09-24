unit netchip;
{ NETCHIP -- what kind of USB Ethernet adapter is this, and can we drive it?
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  This project started as a driver for one adapter that happened to be on
  the desk. The goal is a CH375 network driver for USB-to-RJ45 adapters in
  general, and the first thing that needs is an honest answer to "what have
  you actually plugged in".

  There are two ways to recognise one, and they are not equally good.

  BY CLASS is the right way. CDC-ECM and CDC-NCM are standards: an adapter
  that declares interface class 02 subclass 06 (or 0D) can be driven
  without knowing who made it, because the standard says where the frames
  go. Anything that speaks ECM should eventually work here with no table
  entry at all.

  BY VID/PID is the way that actually gets you online, because most cheap
  adapters are vendor-specific and tell you nothing useful about themselves
  in their descriptors -- the AX88179 on this desk reports class FF/FF/00,
  which means "ask the manufacturer". For those there is no alternative to
  a table.

  So this holds both, and reports what it finds rather than guessing. An
  adapter that is recognised but not implemented says so plainly; that is
  far more use than a driver that fails somewhere in the bring-up and
  leaves you wondering whether the cable is bad. }

{$MODE OBJFPC}{$H-}

interface

uses ch375;

type
  { How the adapter is driven, not who made it.  Two chips from different
    vendors with the same register interface share a family. }
  TNetFamily = (
    nfUnknown,        { not recognised at all }
    nfAX88179,        { ASIX AX88179/178A -- implemented }
    nfAX88772,        { ASIX AX88772 family -- not implemented }
    nfAX88172,        { ASIX AX88172/178 -- not implemented }
    nfRTL815x,        { Realtek RTL8152/8153/8156 -- not implemented }
    nfLAN95xx,        { Microchip/SMSC LAN95xx -- not implemented }
    nfDM9601,         { Davicom DM9601 -- not implemented }
    nfMCS7830,        { Moschip MCS7830 -- not implemented }
    nfCDC_ECM,        { USB CDC Ethernet Control Model -- the standard one }
    nfCDC_NCM,        { CDC Network Control Model }
    nfRNDIS           { Microsoft RNDIS, as phones tethering do }
  );

  TNetId = record
    Vid, Pid:  Word;
    Family:    TNetFamily;
    Name:      ShortString;    { what the chip is }
    Supported: Boolean;        { can this program actually drive it }
    ByClass:   Boolean;        { recognised from descriptors, not a table }
  end;

{ Work out what is attached.  BusUp must have run: this reads the device
  and configuration descriptors that BusUp already fetched, and issues no
  transfers of its own. }
function  IdentifyAdapter: TNetId;

function  FamilyName(F: TNetFamily): ShortString;

{ True if the descriptors describe a communications-class device, whatever
  the vendor is.  These are the adapters that ought to work without anybody
  adding a table entry for them. }
function  LooksLikeCDC(var Sub: Byte): Boolean;

implementation

const
  { The adapters worth naming.  Being in this table means "recognised",
    NOT "supported" -- Supported is decided by the family, in one place,
    so that adding a driver is one edit and not two.

    These are the chips behind almost every cheap USB-to-RJ45 dongle sold
    in the last twenty years.  The list is not exhaustive and does not need
    to be: anything missing still gets identified by class if it speaks
    CDC, and reported as an unknown vendor device if it does not. }
  NENTRY = 28;
  Tbl: array[0..NENTRY - 1] of record
    V, P: Word; F: TNetFamily; N: ShortString;
  end = (
    (V: $0B95; P: $1790; F: nfAX88179; N: 'ASIX AX88179'),
    (V: $0B95; P: $178A; F: nfAX88179; N: 'ASIX AX88178A'),
    (V: $0B95; P: $7720; F: nfAX88772; N: 'ASIX AX88772'),
    (V: $0B95; P: $772A; F: nfAX88772; N: 'ASIX AX88772A'),
    (V: $0B95; P: $772B; F: nfAX88772; N: 'ASIX AX88772B'),
    (V: $0B95; P: $7E2B; F: nfAX88772; N: 'ASIX AX88772B'),
    (V: $0B95; P: $1720; F: nfAX88172; N: 'ASIX AX88172'),
    (V: $0B95; P: $1780; F: nfAX88172; N: 'ASIX AX88178'),
    (V: $0BDA; P: $8152; F: nfRTL815x; N: 'Realtek RTL8152'),
    (V: $0BDA; P: $8153; F: nfRTL815x; N: 'Realtek RTL8153'),
    (V: $0BDA; P: $8156; F: nfRTL815x; N: 'Realtek RTL8156'),
    (V: $0424; P: $EC00; F: nfLAN95xx; N: 'SMSC LAN9512/9514'),
    (V: $0424; P: $9500; F: nfLAN95xx; N: 'SMSC LAN9500'),
    (V: $0424; P: $7500; F: nfLAN95xx; N: 'Microchip LAN7500'),
    (V: $0424; P: $7800; F: nfLAN95xx; N: 'Microchip LAN7800'),
    { CoreChip SR9700 and the clones sold under its IDs. The 0FE6 range is
      Kontron/ICS; 9700 is the SR9700 proper and 9702 is a clone that has
      been seen answering the same register protocol, with the caveat that
      it only implements SINGLE-BYTE register reads -- see ADAPTERS.md. }
    (V: $0FE6; P: $9700; F: nfDM9601; N: 'CoreChip SR9700'),
    (V: $0FE6; P: $9702; F: nfDM9601; N: 'SR9700 clone (single-byte regs)'),
    (V: $0FE6; P: $8101; F: nfDM9601; N: 'DM9601 (Kontron)'),
    (V: $07AA; P: $9601; F: nfDM9601; N: 'Corega FEther USB-TXC'),
    (V: $0A46; P: $9601; F: nfDM9601; N: 'Davicom DM9601'),
    (V: $0A46; P: $0268; F: nfDM9601; N: 'Davicom DM9601'),
    (V: $9710; P: $7830; F: nfMCS7830; N: 'Moschip MCS7830'),
    (V: $9710; P: $7832; F: nfMCS7830; N: 'Moschip MCS7832'),
    (V: $13B1; P: $0041; F: nfAX88772; N: 'Linksys USB200M (AX88772)'),
    (V: $2001; P: $1A02; F: nfAX88772; N: 'D-Link DUB-E100 (AX88772)'),
    (V: $07D1; P: $3C05; F: nfAX88772; N: 'D-Link DUB-E100 (AX88772)'),
    (V: $050D; P: $5055; F: nfAX88172; N: 'Belkin F5D5055 (AX88178)'),
    (V: $17EF; P: $7203; F: nfAX88772; N: 'Lenovo USB Ethernet (AX88772)')
  );

function FamilyName(F: TNetFamily): ShortString;
begin
  case F of
    nfAX88179: FamilyName := 'ASIX AX88179/178A';
    nfAX88772: FamilyName := 'ASIX AX88772 family';
    nfAX88172: FamilyName := 'ASIX AX88172/178';
    nfRTL815x: FamilyName := 'Realtek RTL815x';
    nfLAN95xx: FamilyName := 'SMSC/Microchip LAN95xx';
    nfDM9601:  FamilyName := 'Davicom DM9601';
    nfMCS7830: FamilyName := 'Moschip MCS783x';
    nfCDC_ECM: FamilyName := 'CDC Ethernet (ECM)';
    nfCDC_NCM: FamilyName := 'CDC Network Control Model';
    nfRNDIS:   FamilyName := 'Microsoft RNDIS';
  else
    FamilyName := 'unrecognised';
  end;
end;

{ Only one family is driven today.  Kept as a single case statement so that
  implementing another is one edit here plus the driver itself, rather than
  a boolean sprinkled through a table where entries disagree with each
  other over time. }
function IsSupported(F: TNetFamily): Boolean;
begin
  IsSupported := (F = nfAX88179);
end;

function LooksLikeCDC(var Sub: Byte): Boolean;
var
  P, Len: Word;
begin
  LooksLikeCDC := False;
  Sub := 0;
  { Walk the configuration descriptor looking for an interface descriptor
    of class 02.  bLength/bDescriptorType at the front of every one, so the
    walk is the same for all of them. }
  P := 0;
  Len := CfgLen;
  while (P + 2) < Len do
  begin
    if CfgDesc[P] = 0 then Break;             { malformed; stop rather than spin }
    if (CfgDesc[P + 1] = $04) and (P + 6 < Len) then   { INTERFACE }
      if CfgDesc[P + 5] = $02 then                     { communications }
      begin
        Sub := CfgDesc[P + 6];
        LooksLikeCDC := True;
        Exit;
      end;
    P := P + CfgDesc[P];
  end;
end;

function IdentifyAdapter: TNetId;
var
  I: Integer;
  Sub: Byte;
  R: TNetId;
begin
  R.Vid := DevDesc[8]  or (Word(DevDesc[9])  shl 8);
  R.Pid := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  R.Family := nfUnknown;
  R.Name := '';
  R.ByClass := False;

  { The table first.  A vendor-specific adapter cannot be recognised any
    other way, and a chip that also happens to expose a CDC interface is
    still better driven through the interface we know about. }
  for I := 0 to NENTRY - 1 do
    if (Tbl[I].V = R.Vid) and (Tbl[I].P = R.Pid) then
    begin
      R.Family := Tbl[I].F;
      R.Name   := Tbl[I].N;
      Break;
    end;

  { Then the descriptors, which is how an adapter nobody has tabulated
    still gets identified. }
  if R.Family = nfUnknown then
    if LooksLikeCDC(Sub) then
    begin
      R.ByClass := True;
      case Sub of
        $06: begin R.Family := nfCDC_ECM; R.Name := 'CDC Ethernet adapter'; end;
        $0D: begin R.Family := nfCDC_NCM; R.Name := 'CDC NCM adapter'; end;
        $02: begin R.Family := nfRNDIS;   R.Name := 'RNDIS adapter'; end;
      else
        begin
          R.Family := nfCDC_ECM;
          R.Name := 'communications-class device';
        end;
      end;
    end;

  if R.Name = '' then R.Name := 'unrecognised device';
  R.Supported := IsSupported(R.Family);
  IdentifyAdapter := R;
end;

end.
