program usblink;
{ USBLINK -- bring up an ASIX AX88179 USB Ethernet adapter over a CH375.
  CH375Net, StevenC.  Public domain (the Unlicense).

  Step one of the networking project, and the one that decided whether the
  rest was worth writing.  It runs the initialisation sequence in
  ax179.pas -- power the PHY, set the clocks, read the MAC, configure the
  receive path, negotiate a link -- and prints what came back at every
  stage.  Nothing goes resident and no frames are moved; USBRECV does that.

    USBLINK [/P=260] [/F] [/G] [/V] [/W=secs]

      /P=hex   CH375 I/O base, default 260
      /G       leave the PHY in gigabit mode.  The default forces 10BASE-T,
               and that is not a mistake -- see "WHY 10BASE-T" below
      /V       print every register access
      /W=dec   wait this long for the link, default 15 seconds

  WHY 10BASE-T.  This chip is a gigabit part and the machine at the other
  end of it is an 8086.  Every byte of every frame crosses the ISA bus one
  IN instruction at a time through a 64-byte window, so a 1514-byte frame
  is 24 separate CH375 transfers.  Whatever that works out to, it is not
  megabits.  A gigabit link feeding a receiver that slow does not degrade
  gracefully -- it overruns the chip's buffers and stays overrun.  Dropping
  the PHY to 10 Mbps throws away no performance that was ever available.
  It is done by restricting what the PHY advertises rather than by forcing
  the speed, so the switch at the far end negotiates normally instead of
  being left to guess.

  On a 486 that calculation changes, which is why the speed is a switch
  and not a constant.

  Exit codes: 0 link up, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 not an ASIX adapter,
              6 the chip would not initialise, 7 no link within /W }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, ax179;

const
  VER = '1.0.0';

var
  Giga:   Boolean = False;
  Force:  Boolean = False;
  WaitS:  Word    = 15;
  Bad:    Integer = 0;

procedure ShowStep(const What: ShortString; St: Integer);
var I: Integer;
begin
  Write('  ', What);
  for I := Length(What) + 2 to 35 do Write('.');
  if St >= 0 then WriteLn(' ok')
  else begin WriteLn(' FAILED (', StatusStr(St), ')'); Inc(Bad); end;
end;

procedure Usage;
begin
  Banner('USBLINK', VER, 'bring up an ASIX AX88179 over a CH375');
  WriteLn;
  WriteLn('  USBLINK [/P=260] [/F] [/G] [/V] [/W=secs]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /F       try the AX88179 bring-up even if the USB vendor ID');
  WriteLn('           is not ASIX.  Rebadged parts are common and USBPKT');
  WriteLn('           never checks the ID anyway');
  WriteLn('  /G       leave the PHY in gigabit mode.  The default forces');
  WriteLn('           10BASE-T, and that is not a mistake -- see below');
  WriteLn('  /V       print every register access');
  WriteLn('  /W=dec   wait this long for the link, default 15 seconds');
  WriteLn('  /K=hex   bulk-in aggregation TIMER, default 0080.  The chip');
  WriteLn('           holds received data until this expires, however');
  WriteLn('           often we ask for it, so it is a floor under the');
  WriteLn('           round-trip time and not a throughput knob');
  WriteLn('  /B=hex   bulk-in burst size, default 02');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Runs the full AX88179 initialisation -- power the PHY, set the');
  WriteLn('clocks, read the MAC, configure the receive path, negotiate a');
  WriteLn('link -- and prints what came back at each stage.  Nothing goes');
  WriteLn('resident and no frames are moved; USBRECV does that.');
  WriteLn;
  WriteLn('WHY 10BASE-T.  This is a gigabit chip and the host driving');
  WriteLn('it is orders of magnitude slower.  Every byte crosses the ISA');
  WriteLn('bus one IN at a time through a 64-byte window, so one');
  WriteLn('1514-byte frame is 24 separate CH375 transfers.  A gigabit');
  WriteLn('link feeding a receiver that slow does not degrade');
  WriteLn('gracefully -- it overruns and stays overrun.  Dropping to');
  WriteLn('10 Mbps throws away no performance that was ever available.');
  WriteLn('It is done by restricting what the PHY advertises, not by');
  WriteLn('forcing the speed, so the switch at the far end negotiates');
  WriteLn('normally instead of guessing.');
  WriteLn;
  WriteLn('On a 486 that calculation changes, which is why /G exists.');
  WriteLn;
  WriteLn('Exit: 0 link up, 1 no chip, 2 chip too old, 3 nothing');
  WriteLn('      attached, 4 attached but silent, 5 not an ASIX adapter,');
  WriteLn('      6 would not initialise, 7 no link within /W');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/V') or (A = '-V') then AxTrace := True
    else if (A = '/G') or (A = '-G') then Giga := True
    else if (A = '/F') or (A = '-F') then Force := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/W=' then begin Val(A, V, Code); if Code = 0 then WaitS := Word(V); end
      else if K = '/K=' then begin Val('$' + A, V, Code); if Code = 0 then AxBulkTimer := Word(V); end
      else if K = '/B=' then begin Val('$' + A, V, Code); if Code = 0 then AxBulkSize := Byte(V); end;
    end;
  end;
end;

var
  Rc:   Integer;
  Vid, Pid, W, Bmsr, Anlpar, Id1, Id2: Word;
  B:    Byte;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('USBLINK', VER, 'AX88179 bring-up over a CH375');

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;

  Vid := DevDesc[8]  or (Word(DevDesc[9])  shl 8);
  Pid := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  WriteLn('device   : ', Hex4(Vid), ':', Hex4(Pid));
  { USBPKT does not check this at all -- it enumerates whatever is there
    and runs the bring-up.  That is deliberate, and it is why a rebadged
    ASIX part works: plenty of adapters, docks especially, ship AX88179
    silicon under the vendor's own USB ID.

    So this refusing to look was the wrong way round.  USBLINK is the
    tool you reach for when USBPKT fails, and on exactly the adapter
    where that question is interesting it would not start.  /F says try
    anyway.  The worst case is a register write that times out, which is
    information rather than damage. }
  if (Vid <> AX_VENDOR) and not Force then
  begin
    WriteLn;
    WriteLn('That is not an ASIX vendor ID, and this only knows the');
    WriteLn('AX88179 register map.');
    WriteLn;
    WriteLn('If you believe it is an ASIX part under somebody else''s');
    WriteLn('ID -- docks and own-brand dongles often are -- then /F');
    WriteLn('tries the bring-up regardless.  USBPKT never checks the ID');
    WriteLn('at all, so it will already have tried.  USBINFO dumps what');
    WriteLn('the device says about itself.');
    Halt(5);
  end;
  if Vid <> AX_VENDOR then
    WriteLn('not an ASIX ID -- trying the AX88179 bring-up anyway (/F)');
  if LowSpeed then WriteLn('bus      : low speed -- that cannot be right for a NIC')
              else WriteLn('bus      : full speed (12 Mbps)');
  WriteLn;

  AxStep := @ShowStep;
  WriteLn('Bringing the chip up');
  if (not AxInit(False)) or (Bad > 0) then
  begin
    WriteLn;
    WriteLn('The chip would not initialise.  Re-run with /V to see which');
    WriteLn('register access failed and what the CH375 said about it.');
    Halt(6);
  end;

  WriteLn;
  WriteLn('MAC address: ', MacStr(Mac));

  if AxPhyRd(MII_PHYSID1, Id1) < 0 then Id1 := $FFFF;
  if AxPhyRd(MII_PHYSID2, Id2) < 0 then Id2 := $FFFF;
  WriteLn('PHY id     : ', Hex4(Id1), ' ', Hex4(Id2));
  if (Id1 = $FFFF) and (Id2 = $FFFF) then
  begin
    WriteLn('  All ones means MDIO is not answering -- the PHY is still in');
    WriteLn('  reset, or the settle after the reset line was not honoured.');
    Halt(6);
  end;

  WriteLn;
  if Giga then
    WriteLn('Leaving the PHY at gigabit (/G).  Expect overruns on a slow host.')
  else
    WriteLn('Restricting the PHY to 10BASE-T');
  AxNegotiate(not Giga);

  WriteLn;
  Write('Waiting up to ', WaitS, 's for a link');
  if not AxLinkWait(WaitS, Bmsr) then
  begin
    WriteLn;
    WriteLn;
    WriteLn('No link.  BMSR = ', Hex4(Bmsr));
    WriteLn('Check the cable and that the far end is up.  Everything');
    WriteLn('before this point worked, so the USB side is fine.');
    Halt(7);
  end;
  WriteLn(' up.');

  { The MAC does not learn the link speed by itself; the driver reads it
    off the PHY and writes the medium register to match.  Get this wrong
    and the link is up while no frame ever moves. }
  if AxPhyRd(MII_ANLPAR, Anlpar) < 0 then Anlpar := 0;
  ShowStep('set medium mode', AxSetMedium(Giga));

  WriteLn;
  WriteLn('Link is up.');
  if AxMacRd16(AX_MEDIUM_MODE, W) >= 0 then
  begin
    Write('  medium mode   : ', Hex4(W), '  ');
    if      (W and MED_GIGA) <> 0 then Write('1000')
    else if (W and MED_PS) <> 0   then Write('100')
    else                               Write('10');
    Write(' Mbps ');
    if (W and MED_FULL_DUPLEX) <> 0 then Write('full') else Write('half');
    WriteLn(' duplex');
    if (W and MED_RECEIVE_EN) = 0 then
      WriteLn('  RECEIVE IS NOT ENABLED -- the medium write did not stick');
  end;
  if AxMacRd16(AX_RX_CTL, W) >= 0 then
    WriteLn('  rx control    : ', Hex4(W));
  if AxMacRd(AX_PHYSICAL_LINK, 1, B) >= 0 then
    WriteLn('  usb link speed: ', Hex2(B), ' (bit0 full, bit1 high, bit2 super)');
  WriteLn('  link partner  : ', Hex4(Anlpar));

  WriteLn;
  WriteLn('The adapter is initialised and receiving.  USBRECV reads the');
  WriteLn('bulk endpoint and shows what actually arrives.');
  Halt(0);
end.
