program netid;
{ NETID -- what USB network adapter is plugged into the CH375, and can this
  project drive it?
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

    NETID [/P=260] [/V]

      /P=hex   CH375 I/O base, default 260
      /V       also dump the interfaces and endpoints it found

  Run this before anything else when a new adapter arrives. It answers
  three questions in order, and stops being useful only when all three are
  yes:

    is anything there, and does it enumerate
    what chip is it
    is that chip one this project can actually drive

  The third is the point. An adapter that is recognised but unimplemented
  says so in one line, which is worth a great deal more than a driver that
  fails partway through a bring-up and leaves you wondering about the
  cable, the card, the address or the chip.

  Exit codes: 0 supported adapter, 1 no chip, 3 nothing attached,
              4 attached but silent, 5 recognised but not implemented,
              6 not recognised as a network adapter at all }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, netchip;

const
  VER = '1.0.0';

var
  Verbose: Boolean = False;

procedure Usage;
begin
  Banner('NETID', VER, 'identify the USB network adapter on a CH375');
  WriteLn;
  WriteLn('  NETID [/P=260] [/V]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /V       also dump the interfaces and endpoints it found');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Run this first when a new adapter arrives.  It says what the');
  WriteLn('chip is and whether this project can drive it -- which is worth');
  WriteLn('more than a bring-up that fails halfway and leaves you');
  WriteLn('wondering about the cable, the card, the address or the chip.');
  WriteLn;
  WriteLn('Two ways of recognising an adapter, and they are not equally');
  WriteLn('good.  BY CLASS is the right way: CDC-ECM and CDC-NCM are');
  WriteLn('standards, and an adapter declaring interface class 02 can be');
  WriteLn('driven without knowing the manufacturer.  BY VID/PID is the way');
  WriteLn('that gets you online, because most cheap adapters are');
  WriteLn('vendor-specific -- the AX88179 this was written against reports');
  WriteLn('class FF/FF/00, which means "ask the manufacturer".');
  WriteLn;
  WriteLn('Exit: 0 supported, 1 no chip, 3 nothing attached, 4 silent,');
  WriteLn('      5 recognised but not implemented, 6 not a network adapter');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/V') or (A = '-V') then Verbose := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end;
    end;
  end;
end;

{ Walk the configuration descriptor printing interfaces and endpoints.  The
  same walk NETCHIP uses to spot a CDC interface, printed instead of
  matched. }
procedure ShowInterfaces;
var
  P, Len: Word;
  N: Integer;
begin
  P := 0;
  Len := CfgLen;
  N := 0;
  while (P + 2) < Len do
  begin
    if CfgDesc[P] = 0 then Break;
    case CfgDesc[P + 1] of
      $04: if P + 8 < Len then
           begin
             Inc(N);
             WriteLn('  interface ', CfgDesc[P + 2],
                     '  class ', Hex2(CfgDesc[P + 5]),
                     '/', Hex2(CfgDesc[P + 6]),
                     '/', Hex2(CfgDesc[P + 7]),
                     '  ', ClassName(CfgDesc[P + 5], CfgDesc[P + 6],
                                     CfgDesc[P + 7]));
           end;
      $05: if P + 4 < Len then
             WriteLn('    endpoint ', Hex2(CfgDesc[P + 2]), '  ',
                     EpTypeName(CfgDesc[P + 3]),
                     '  max ', CfgDesc[P + 4] or
                               (Word(CfgDesc[P + 5]) shl 8));
    end;
    P := P + CfgDesc[P];
  end;
  if N = 0 then WriteLn('  (no interface descriptors found)');
end;

var
  Rc: Integer;
  Id: TNetId;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('NETID', VER, 'USB network adapter identification');

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;

  Id := IdentifyAdapter;

  WriteLn;
  WriteLn('device   : ', Hex4(Id.Vid), ':', Hex4(Id.Pid),
          '  ', VendorName(Id.Vid));
  WriteLn('chip     : ', Id.Name);
  WriteLn('family   : ', FamilyName(Id.Family));
  if Id.ByClass then
    WriteLn('           (recognised from its descriptors, not a table)');
  if LowSpeed then WriteLn('bus      : low speed -- wrong for a network adapter')
              else WriteLn('bus      : full speed (12 Mbps)');

  if Verbose then
  begin
    WriteLn;
    ShowInterfaces;
  end;

  WriteLn;
  if Id.Supported then
  begin
    { USBLINK used to be named here as a prerequisite.  It is not one:
      USBPKT enumerates and brings the adapter up itself.  Saying
      otherwise sent people through two commands where one does, and
      running USBLINK first actively gets in the way -- it leaves the
      device enumerated, which is the state USBPKT then has to fight. }
    WriteLn('SUPPORTED.  Run USBPKT and point mTCP at it:');
    WriteLn;
    WriteLn('    USBPKT                       (loads on vector 65h)');
    WriteLn('    packetint 0x65              (one line in your mTCP config)');
    WriteLn;
    WriteLn('USBPKT needs nothing run before it.  See INSTALL.md.');
    Halt(0);
  end;

  if Id.Family = nfUnknown then
  begin
    WriteLn('NOT RECOGNISED as a network adapter.');
    WriteLn;
    WriteLn('It is not in the table and its descriptors do not declare a');
    WriteLn('communications class, so there is nothing to go on.  USBINFO');
    WriteLn('dumps everything the device will say about itself, and HIDREP');
    WriteLn('decodes it if it turns out to be something else entirely.');
    WriteLn;
    { Worth saying, because this verdict is advisory and gets taken as
      final.  USBPKT does not look at the USB ID at all -- it brings up
      whatever enumerates -- so an ASIX part wearing somebody else's ID,
      which docks and own-brand dongles very often are, works fine
      despite this message. }
    WriteLn('This verdict is advisory.  USBPKT does not check the USB ID');
    WriteLn('at all, so if you suspect a rebadged ASIX part -- docks and');
    WriteLn('own-brand dongles often are -- just run it.  A wrong guess');
    WriteLn('fails at a numbered step and harms nothing.  ADAPTERS.md');
    WriteLn('has the detail.');
    Halt(6);
  end;

  { The DM9601 family has a packet driver now.  It is still handled
    separately from the ASIX default because the note below is worth
    printing to anybody holding one of these: the register quirk is not
    something a reader would guess, and it is the first thing to check if a
    bring-up written from a datasheet does not work. }
  if Id.Family = nfDM9601 then
  begin
    WriteLn('SUPPORTED.  USBPKT drives this family.');
    WriteLn;
    WriteLn('Run USBPKT and point mTCP at it -- and use a COPY of MTCP.CFG,');
    WriteLn('not the one the working network uses.  USBPKT /T brings the');
    WriteLn('adapter up and quits WITHOUT going resident, which is the safe');
    WriteLn('way to check a new one.  SRLINK is the diagnostic: it shows');
    WriteLn('every step of the bring-up and can send an ARP and wait to be');
    WriteLn('answered.');
    WriteLn;
    WriteLn('Note the quirk before writing anything: some of these clones');
    WriteLn('only decode a register index on SINGLE-BYTE reads, and answer');
    WriteLn('a multi-byte read with a fixed block -- so a driver that reads');
    WriteLn('the six MAC bytes in one go gets the right MAC and the wrong');
    WriteLn('everything else.  ADAPTERS.md has it.');
    WriteLn;
    Halt(0);
  end;

  WriteLn('RECOGNISED, BUT NOT IMPLEMENTED.');
  WriteLn;
  WriteLn('This is a ', FamilyName(Id.Family), '.  CDC-ECM, the');
  WriteLn('SR9700/DM9601 and the ASIX AX88179/178A are driven today, and');
  WriteLn('this is none of them.  Nothing here will bring it up, and');
  WriteLn('that is a gap in this project rather than a fault in the');
  WriteLn('adapter.');
  WriteLn;
  if (Id.Family = nfCDC_ECM) or (Id.Family = nfCDC_NCM) then
  begin
    WriteLn('It speaks a STANDARD, though, which makes it the most');
    WriteLn('valuable kind to implement next: a CDC-ECM driver works with');
    WriteLn('every adapter that speaks ECM, whoever made it, instead of');
    WriteLn('one more entry in a table of vendor quirks.');
  end
  else
  begin
    WriteLn('USBINFO and USBCTL are the tools for working out what it');
    WriteLn('wants; the AX88179 support in ax179.pas is the worked example');
    WriteLn('of what a chipset driver here has to provide.');
  end;
  Halt(5);
end.
