program dlprobe;
{ DLPROBE -- identify a DisplayLink USB display adapter over a CH375, read
  its capability limits and the attached monitor's EDID.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

  A USB display adapter has no class to stand on.  CDC-ECM worked out
  because Ethernet has one: the device describes itself, and a single
  bring-up covers adapters from vendors nobody here has bought.  There is
  no USB display class at all -- the Video class is for cameras -- so every
  one of these is a private protocol, and the only question worth asking
  first is WHICH private protocol this is.  That is what this tool answers,
  and it answers it from the device rather than from the box it came in.

    DLPROBE [/P=260] [/E=n] [/K] [/I=n] [/V] [/T]

      /P=hex   I/O base, default 260
      /E=dec   EDID bytes to read, default 128.  0 skips it
      /K       skip the channel unlock (it is the only WRITE this makes)
      /I=dec   also poll the interrupt endpoint this many times
      /V       narrate the bring-up
      /T       trace every control-transfer stage

  WHAT IT READS, AND WHY EACH PART IS KEPT SEPARATE

  * The device descriptor, for the vendor ID.  17E9 is DisplayLink, and
    that is the whole identification -- the product ID varies per OEM and
    the strings are whatever the reseller asked for, so neither is
    evidence of anything.

  * The 5Fh VENDOR DESCRIPTOR, which is DisplayLink's capability list and
    the reason this is worth doing at all.  It is a five-byte header then
    key/length/value triples, and it states the two limits that decide
    which video modes the chip will accept: a pixel-AREA cap and a pixel
    CLOCK cap.  Both bind, and the clock is usually the tighter of the
    two -- a chip that allows 1.5 million pixels of area may still refuse
    1024x768, because that mode needs 65 MHz.  Reading the area alone gets
    this wrong in the optimistic direction, which is the worst direction.

    The descriptor is embedded in the configuration descriptor, so that is
    the copy the numbers are taken from; it always exists.  Fetching it
    standalone with GET_DESCRIPTOR 5F is tried as well, because that is
    how the Linux udlfb driver asks for it, and a device that refuses is
    worth knowing about before anyone writes code that depends on it.

  * The monitor's EDID, read through the adapter.  This is the useful
    milestone: it is a vendor control transfer with a real data stage, so
    it proves the private protocol answers us at all, and what comes back
    is the monitor's own name and preferred timing.  It is read TWO BYTES
    AT A TIME -- the device returns two bytes per EDID byte and only the
    second is the data.  128 transfers for 128 bytes is not a
    misunderstanding of the protocol; it is the protocol.

  * The channel unlock, which is the one thing here that writes anything.
    It is a fixed 16-byte key on a vendor request, and the hardware
    ignores rendering commands until it has been sent.  Nothing here
    renders, so /K turns it off and the tool stays strictly read-only.

  EDID IS READ BEFORE THE UNLOCK ON PURPOSE.  The unlock is the step most
  likely to be refused by a chip revision nobody here has seen, and done
  first a refusal would cost us the monitor report as well.  Ordered this
  way, a device that rejects the key still yields everything else.

  WHAT THIS TOOL DELIBERATELY DOES NOT DO.  It sets no video mode and
  sends no pixels.  Those need the register table, and a tool that half
  set a mode would leave the adapter in a state the next run would have to
  guess at.  Identify first, and separately.

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering,
              6 not a DisplayLink device }

{$MODE OBJFPC}{$H-}

{ dl is used only for TDlTiming and DlTimingFromEdid -- the timing
  derivation belongs beside the code that drives it, not duplicated
  here. DLPROBE still sends no pixels. }
uses ch375, chtool, dl;

const
  VER = '1.0.0';

  DL_VID         = $17E9;      { DisplayLink }
  DT_VENDOR      = $5F;        { their capability descriptor }
  DL_REQ_EDID    = $02;        { vendor IN,  two bytes per EDID byte }
  DL_REQ_CHANNEL = $12;        { vendor OUT, the 16-byte unlock key }
  EDID_IDX       = $A1;        { the wIndex the EDID request wants }

  { The fixed key that enables the rendering channel.  It is the same
    constant in every driver that speaks to these chips: not derived from
    anything, not a secret, just a magic number the hardware wants to see
    before it will accept a command stream. }
  ChanKey: array[0..15] of Byte = (
    $57, $CD, $DC, $A7, $1C, $88, $5E, $15,
    $60, $FE, $C6, $97, $16, $3D, $47, $F2);

type
  TMode = record
    W, H, Hz: Word;
    Clk:      LongInt;         { dot clock in kHz }
    EstB:     Byte;            { EDID established-timings byte, 0 = none }
    EstBit:   Byte;
  end;

const
  { VESA DMT dot clocks, each tied to its bit in the EDID established-
    timings bitmap where it has one -- that is what lets the two ends be
    intersected rather than compared by eye.  Not an exhaustive list, and
    it does not pretend to be. }
  NMODES = 15;
  Modes: array[0..NMODES - 1] of TMode = (
    (W: 640;  H: 400;  Hz: 70; Clk: 25175;  EstB: 0;  EstBit: 0),
    (W: 720;  H: 400;  Hz: 70; Clk: 28322;  EstB: 35; EstBit: 7),
    (W: 640;  H: 480;  Hz: 60; Clk: 25175;  EstB: 35; EstBit: 5),
    (W: 640;  H: 480;  Hz: 72; Clk: 31500;  EstB: 35; EstBit: 3),
    (W: 640;  H: 480;  Hz: 75; Clk: 31500;  EstB: 35; EstBit: 2),
    (W: 800;  H: 600;  Hz: 56; Clk: 36000;  EstB: 35; EstBit: 1),
    (W: 800;  H: 600;  Hz: 60; Clk: 40000;  EstB: 35; EstBit: 0),
    (W: 800;  H: 600;  Hz: 72; Clk: 50000;  EstB: 36; EstBit: 7),
    (W: 800;  H: 600;  Hz: 75; Clk: 49500;  EstB: 36; EstBit: 6),
    (W: 1024; H: 768;  Hz: 60; Clk: 65000;  EstB: 36; EstBit: 3),
    (W: 1024; H: 768;  Hz: 70; Clk: 75000;  EstB: 36; EstBit: 2),
    (W: 1024; H: 768;  Hz: 75; Clk: 78750;  EstB: 36; EstBit: 1),
    (W: 1280; H: 1024; Hz: 60; Clk: 108000; EstB: 0;  EstBit: 0),
    (W: 1280; H: 1024; Hz: 75; Clk: 135000; EstB: 36; EstBit: 0),
    { 16:9, for a modern panel. Not an established-timings bit, so it is
      only reported as accepted if the monitor lists it in a detailed or
      standard entry -- which most widescreens do not, even though they
      will happily sync it. }
    (W: 848;  H: 480;  Hz: 60; Clk: 33750;  EstB: 0;  EstBit: 0));

var
  Cfg:      array[0..1023] of Byte;   { the configuration, in full }
  CfgGot:   Word = 0;
  Vend:     array[0..255] of Byte;    { the 5Fh descriptor }
  VendLen:  Integer = 0;
  Edid:     array[0..255] of Byte;
  EdidGot:  Integer = 0;
  Tmp:      array[0..63] of Byte;
  EdidWant: Integer = 128;
  NoKey:    Boolean = False;
  IntPolls: Integer = 0;
  Verbose:  Boolean = False;
  PixLimit: LongInt = 0;              { key 0200, in pixels }
  ClkLimit: LongInt = 0;              { key 0204, in Hz }
  EpInt:    Byte = 0;
  EpBulk:   Byte = 0;
  EdidValid: Boolean = False;         { a real EDID was read and decoded }

{ ---------------------------------------------------------------- output }

procedure Narrate(const S: ShortString);
begin
  WriteLn(S);
end;

procedure Head(const S: ShortString);
begin
  WriteLn;
  WriteLn(S);
  WriteLn('----------------------------------------------------------------');
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var R: ShortString;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

procedure Fld(const Name, Value: ShortString);
begin
  WriteLn(Pad('  ' + Name, 24) + Value);
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ kHz printed as MHz with one decimal, without linking Real support in.
  ROUNDED, not truncated, and that is not cosmetic here: this chip
  advertises its clock cap as 39,999,999 Hz, and truncating printed that
  as "39.9 MHz" -- which reads as a limit below 40 and invites exactly the
  wrong conclusion about an 800x600 mode that needs precisely 40. }
function Mhz(KHz: LongInt): ShortString;
var T: LongInt;
begin
  T := (KHz + 50) div 100;                  { tenths of a MHz, rounded }
  Mhz := Dec1(T div 10) + '.' + Chr(48 + (T mod 10)) + ' MHz';
end;

{ ------------------------------------------------------ the 5Fh descriptor }

{ DisplayLink's capability list: a five-byte header, then key/length/value
  triples.  Two things are checked rather than assumed.  The header
  self-describes twice -- bLength appears whole and again as bLength-2 --
  and the triples must consume the descriptor EXACTLY.  The second check is
  the one that matters: a wrong guess at the layout will still produce
  plausible-looking keys and values, and the only thing that catches it is
  insisting the walk land on the final byte. }
function ParseVendor: Boolean;
var
  I, J: Integer;
  Key:  Word;
  Ln:   Byte;
  Val:  LongInt;
  Raw:  ShortString;
  Note: ShortString;
begin
  ParseVendor := False;
  if VendLen < 5 then Exit;
  if (Vend[0] <> VendLen) or (Vend[1] <> DT_VENDOR)
     or (Vend[2] <> $01) or (Vend[3] <> $00)
     or (Vend[4] <> VendLen - 2) then
  begin
    WriteLn('  The header does not match the DisplayLink layout, so the');
    WriteLn('  triples are not walked -- the raw bytes above are all this');
    WriteLn('  run can honestly claim.');
    Exit;
  end;
  Fld('header', 'ok  (version 1.0, ' + Dec1(VendLen) + ' bytes)');
  WriteLn;

  I := 5;
  while I + 2 < VendLen do
  begin
    Key := Vend[I] or (Word(Vend[I + 1]) shl 8);
    Ln  := Vend[I + 2];
    if I + 3 + Ln > VendLen then
    begin
      WriteLn('  key ', Hex4(Key), ' runs off the end -- the layout is wrong');
      Exit;
    end;

    Val := 0;
    for J := Ln - 1 downto 0 do
      Val := (Val shl 8) or Vend[I + 3 + J];
    Raw := '';
    for J := 0 to Ln - 1 do Raw := Raw + Hex2(Vend[I + 3 + J]) + ' ';

    Note := '';
    case Key of
      $0200: begin Note := 'pixel-area limit'; PixLimit := Val; end;
      $0204: begin Note := 'pixel-clock limit, Hz'; ClkLimit := Val; end;
    end;

    { Printed as hex when the top bit is set: these are unsigned fields
      and Dec1 takes a LongInt, so key 0400 came out as -1073545215,
      which is a plausible-looking number and the wrong one. }
    if (Ln = 4) and (Val < 0) then
      WriteLn('  key ', Hex4(Key), '  len ', Ln, '  ', Pad(Raw, 13),
              '= ', Pad('$' + Hex4(Word(Val shr 16)) + Hex4(Word(Val)), 11),
              Note)
    else
      WriteLn('  key ', Hex4(Key), '  len ', Ln, '  ', Pad(Raw, 13),
              '= ', Pad(Dec1(Val), 11), Note);
    Inc(I, 3 + Ln);
  end;

  if I <> VendLen then
  begin
    WriteLn;
    WriteLn('  The triples ended at ', I, ' of ', VendLen, ' bytes, so they');
    WriteLn('  did NOT tile the descriptor.  Treat every value above as');
    WriteLn('  unreliable: a mis-framed walk still yields numbers.');
    Exit;
  end;
  ParseVendor := True;
end;

{ Walk the configuration for the 5Fh block and the endpoints.  The 5Fh copy
  in here always exists, which is why it is the one trusted. }
procedure WalkConfig;
var
  I, J: Integer;
  L, T: Byte;
begin
  I := 0;
  while I + 1 < CfgGot do
  begin
    L := Cfg[I];
    T := Cfg[I + 1];
    if L < 2 then Break;
    if I + L > CfgGot then Break;
    case T of
      DT_VENDOR:
        if VendLen = 0 then
        begin
          for J := 0 to L - 1 do Vend[J] := Cfg[I + J];
          VendLen := L;
        end;
      DT_ENDPOINT:
        if L >= 6 then
        begin
          { First bulk OUT wins -- see dl.pas.  A device with two of them
            renders to the first. }
          if (Cfg[I + 3] and $03) = $02 then
            if ((Cfg[I + 2] and $80) = 0) and (EpBulk = 0) then
              EpBulk := Cfg[I + 2] and $0F;
          if (Cfg[I + 3] and $03) = $03 then            { interrupt }
            if (Cfg[I + 2] and $80) <> 0 then
              EpInt := Cfg[I + 2] and $0F;
        end;
    end;
    Inc(I, L);
  end;
end;

{ ------------------------------------------------------------------- EDID }

{ One EDID byte costs one control transfer, and the reply is two bytes of
  which the second is the data.  A device that answers fewer than two has
  not given us the byte, so the read STOPS rather than storing a zero: a
  short EDID is honest, an EDID padded out with invented zeroes would pass
  its own header check and lie about the monitor. }
function ReadEdid(Want: Integer): Integer;
var
  I, R: Integer;
  Got:  Word;
begin
  ReadEdid := 0;
  for I := 0 to Want - 1 do
  begin
    R := CtrlIn($C0, DL_REQ_EDID, Word(I) shl 8, EDID_IDX, 2,
                Tmp, SizeOf(Tmp), Got);
    if (R <> INT_SUCCESS) or (Got < 2) then
    begin
      if I = 0 then
        Fld('first byte', StatusStr(R) + ', ' + Dec1(Got) + ' byte(s) back');
      Break;
    end;
    Edid[I] := Tmp[1];
    ReadEdid := I + 1;
  end;
end;

{ The three-letter PnP ID is three 5-bit letters in a big-endian word. }
function EdidMaker: ShortString;
var W: Word;
begin
  W := (Word(Edid[8]) shl 8) or Edid[9];
  EdidMaker := Chr(64 + ((W shr 10) and $1F))
             + Chr(64 + ((W shr 5) and $1F))
             + Chr(64 + (W and $1F));
end;

function EdidSum: Byte;
var I: Integer; S: Byte;
begin
  S := 0;
  for I := 0 to 127 do S := Byte(S + Edid[I]);
  EdidSum := S;
end;

procedure ShowEstablished;
var Any: Boolean;

  procedure E(B, Bit: Byte; const Name: ShortString);
  begin
    if (Edid[B] and (Byte(1) shl Bit)) <> 0 then
    begin
      if not Any then Write(Pad('  established', 24));
      Write(Name, ' ');
      Any := True;
    end;
  end;

begin
  Any := False;
  E(35, 7, '720x400@70');   E(35, 6, '720x400@88');
  E(35, 5, '640x480@60');   E(35, 4, '640x480@67');
  E(35, 3, '640x480@72');   E(35, 2, '640x480@75');
  E(35, 1, '800x600@56');   E(35, 0, '800x600@60');
  E(36, 7, '800x600@72');   E(36, 6, '800x600@75');
  E(36, 5, '832x624@75');   E(36, 4, '1024x768@87i');
  E(36, 3, '1024x768@60');  E(36, 2, '1024x768@70');
  E(36, 1, '1024x768@75');  E(36, 0, '1280x1024@75');
  E(37, 7, '1152x870@75');
  if Any then WriteLn
         else Fld('established', '(none flagged)');
end;

procedure ShowStandard;
var
  I, O:  Integer;
  W, Hz: Word;
  Asp:   ShortString;
  Any:   Boolean;
begin
  Any := False;
  for I := 0 to 7 do
  begin
    O := 38 + I * 2;
    if (Edid[O] = $01) and (Edid[O + 1] = $01) then Continue;
    if Edid[O] = 0 then Continue;
    W  := (Word(Edid[O]) + 31) * 8;
    Hz := (Edid[O + 1] and $3F) + 60;
    case (Edid[O + 1] shr 6) and 3 of
      0: Asp := '16:10';
      1: Asp := '4:3';
      2: Asp := '5:4';
    else
      Asp := '16:9';
    end;
    Fld('standard timing', Dec1(W) + ' wide @ ' + Dec1(Hz) + ' Hz, ' + Asp);
    Any := True;
  end;
  if not Any then Fld('standard timings', '(none)');
end;

{ The four 18-byte blocks are each either a detailed timing or, when the
  first two bytes are zero, a text or range block named by a tag. }
procedure ShowDescriptors;
var
  I, O, J: Integer;
  Clk:     LongInt;
  HA, VA:  Word;
  S:       ShortString;
  ET:      TDlTiming;
  HzWhole: LongInt;
  TRc:     Integer;
begin
  for I := 0 to 3 do
  begin
    O := 54 + I * 18;
    Clk := (LongInt(Edid[O + 1]) shl 8) or Edid[O];
    if Clk <> 0 then
    begin
      HA := Edid[O + 2] or ((Word(Edid[O + 4] and $F0)) shl 4);
      VA := Edid[O + 5] or ((Word(Edid[O + 7] and $F0)) shl 4);
      Fld('detailed timing', Dec1(HA) + 'x' + Dec1(VA) + '   '
          + Mhz(Clk * 10) + ' dot clock   '
          + Dec1(LongInt(HA) * VA) + ' px');
      if I = 0 then
        Fld('', 'that first one is the monitor''s PREFERRED mode');

      { The full timing, derived rather than matched against a table --
        so a display nobody here has seen still gets its own mode.  The
        porches are what makes this worth printing: EDID gives total
        blanking and the sync OFFSET, and the back porch is the
        remainder, which is easy to get backwards in a way that still
        syncs and looks wrong. }
      TRc := DlTimingFromEdid(Edid, I, ET);
      if TRc = DLT_TOOBIG then
      begin
        Fld('', 'beyond this hardware -- ' + Dec1(ET.XRes) + 'x'
            + Dec1(ET.YRes) + ' needs '
            + Mhz(1000000 div ET.PixClk * 1000) + ', and the encoder');
        Fld('', 'would be sending ' + Dec1(LongInt(ET.XRes) * ET.YRes)
            + ' pixels a frame.  The descriptor is fine;');
        Fld('', 'it is simply asking for more than this can do.');
      end
      else if TRc = DLT_OK then
      begin
        Fld('', 'h: ' + Dec1(ET.LeftM) + ' back, ' + Dec1(ET.HSync)
            + ' sync, ' + Dec1(ET.RightM) + ' front   total '
            + Dec1(LongInt(ET.XRes) + ET.LeftM + ET.HSync + ET.RightM));
        Fld('', 'v: ' + Dec1(ET.UpperM) + ' back, ' + Dec1(ET.VSync)
            + ' sync, ' + Dec1(ET.LowerM) + ' front   total '
            + Dec1(LongInt(ET.YRes) + ET.UpperM + ET.VSync + ET.LowerM));
        HzWhole := (LongInt(1000000) * 1000)
                   div ((LongInt(ET.XRes) + ET.LeftM + ET.HSync + ET.RightM)
                        * (LongInt(ET.YRes) + ET.UpperM + ET.VSync
                           + ET.LowerM) * ET.PixClk div 1000);
        Fld('', 'that works out at ' + Dec1(HzWhole) + ' Hz -- '
            + 'DLTEST /M=E and DLDASH /M=E drive it');
      end
      else if I = 0 then
        Fld('', 'timing not usable: ' + DlTimingWhy(TRc));
    end
    else
    begin
      S := '';
      for J := 5 to 17 do
        if (Edid[O + J] >= 32) and (Edid[O + J] < 127) then
          S := S + Chr(Edid[O + J]);
      case Edid[O + 3] of
        $FC: Fld('monitor name', S);
        $FF: Fld('monitor serial', S);
        $FE: Fld('monitor text', S);
        $FD: Fld('range limits', 'V ' + Dec1(Edid[O + 5]) + '-'
                  + Dec1(Edid[O + 6]) + ' Hz, H ' + Dec1(Edid[O + 7]) + '-'
                  + Dec1(Edid[O + 8]) + ' kHz, clock up to '
                  + Dec1(LongInt(Edid[O + 9]) * 10) + ' MHz');
      end;
    end;
  end;
end;

{ ------------------------------------------------------------ what fits }

{ Does the MONITOR accept this mode?  Three places say so, and all three
  are consulted because a display need not use the same one: the
  established-timings bitmap, the four detailed timing blocks, and the
  eight standard timing entries.  Resolution is matched on the detailed
  blocks without the refresh rate, because a detailed block states its own
  timing and a monitor that lists a resolution there will sync it. }
function MonitorOk(const M: TMode): Boolean;
var
  I, O:  Integer;
  HA, VA: Word;
begin
  MonitorOk := True;
  if M.EstB <> 0 then
    if (Edid[M.EstB] and (Byte(1) shl M.EstBit)) <> 0 then Exit;

  for I := 0 to 3 do
  begin
    O := 54 + I * 18;
    if (Edid[O] = 0) and (Edid[O + 1] = 0) then Continue;
    HA := Edid[O + 2] or ((Word(Edid[O + 4] and $F0)) shl 4);
    VA := Edid[O + 5] or ((Word(Edid[O + 7] and $F0)) shl 4);
    if (HA = M.W) and (VA = M.H) then Exit;
  end;

  for I := 0 to 7 do
  begin
    O := 38 + I * 2;
    if (Edid[O] = $01) and (Edid[O + 1] = $01) then Continue;
    if Edid[O] = 0 then Continue;
    if ((Word(Edid[O]) + 31) * 8 = M.W)
       and ((Edid[O + 1] and $3F) + 60 = M.Hz) then Exit;
  end;

  MonitorOk := False;
end;

procedure ShowReachable;
var
  I, NOk, NMarg, NBoth: Integer;
  Px, Need:             LongInt;
  Why, MonSay:          ShortString;
  Best:                 Integer;
  MOk:                  Boolean;
begin
  if (PixLimit = 0) and (ClkLimit = 0) then
  begin
    WriteLn('  No limits were read, so nothing can be said about modes.');
    Exit;
  end;
  WriteLn('  Both of the adapter''s caps bind: a mode has to pass the AREA');
  WriteLn('  and the CLOCK.  The clock is the tighter one here, and that is');
  WriteLn('  exactly the part a glance at the pixel count alone gets wrong.');
  if EdidValid then
  begin
    WriteLn;
    WriteLn('  The monitor column says whether the display ADVERTISES the');
    WriteLn('  mode, which is not the same as whether it will accept it --');
    WriteLn('  and the difference has been measured here rather than');
    WriteLn('  assumed.  A capture card on this bench advertises no');
    WriteLn('  established timings at all and a 61 Hz vertical maximum, and');
    WriteLn('  syncs 320x200@70 and 848x480@60 perfectly well.');
    WriteLn;
    WriteLn('  So read "not listed" as "the display did not claim it", and');
    WriteLn('  try it anyway.  The ADAPTER column is the hard one: that is');
    WriteLn('  a limit the chip states about itself.');
  end;
  WriteLn;
  WriteLn('    ', Pad('mode', 16), Pad('dot clock', 12), Pad('pixels', 12),
          Pad('adapter', 30), 'monitor');
  WriteLn('    ', Pad('----', 16), Pad('---------', 12), Pad('------', 12),
          Pad('-------', 30), '-------');

  NOk := 0;
  NMarg := 0;
  NBoth := 0;
  Best := -1;
  for I := 0 to NMODES - 1 do
  begin
    Px := LongInt(Modes[I].W) * Modes[I].H;
    Why := '';

    { The cap comes back as 39,999,999 Hz -- one hertz under a round 40
      MHz -- so a mode landing within a per cent of it is called MARGINAL
      rather than refused.

      THE HARDWARE HAS NOW SETTLED THIS. 800x600@60 needs exactly
      40,000,000 Hz, one hertz over the advertised cap, and it drives this
      adapter perfectly: clean picture, no artefacts, verified by capture.
      So the cap really is a fencepost in whoever programmed the
      descriptor, and refusing the mode over one hertz would have been
      precisely, confidently wrong.

      MARGINAL still stands as the verdict, because one adapter agreeing
      is not every adapter agreeing and the honest report is "try it". }
    if ClkLimit > 0 then
    begin
      Need := Modes[I].Clk * 1000;
      if Need > ClkLimit + (ClkLimit div 100) then Why := 'no -- clock'
      else if Need > ClkLimit then Why := 'MARGINAL -- 1% over cap';
    end;
    if (PixLimit > 0) and (Px > PixLimit) then
      if Why = '' then Why := 'no -- area'
                  else Why := Why + ' + area';
    if Why = '' then begin Why := 'ok'; Inc(NOk); end
    else if Why[1] = 'M' then Inc(NMarg);

    MOk := False;
    MonSay := '?';
    if EdidValid then
    begin
      MOk := MonitorOk(Modes[I]);
      if MOk then MonSay := 'listed' else MonSay := 'not listed';
    end;

    Write('    ',
          Pad(Dec1(Modes[I].W) + 'x' + Dec1(Modes[I].H)
              + '@' + Dec1(Modes[I].Hz), 16),
          Pad(Mhz(Modes[I].Clk), 12),
          Pad(Dec1(Px) + ' px', 12),
          Pad(Why, 30), MonSay);

    { Both ends happy, and not relying on the fencepost.  Track the
      largest such mode by area -- that is the one worth trying first. }
    if (Why = 'ok') and MOk then
    begin
      Inc(NBoth);
      if (Best < 0)
         or (Px > LongInt(Modes[Best].W) * Modes[Best].H) then Best := I;
      Write('   <--');
    end;
    WriteLn;
  end;

  WriteLn;
  WriteLn('  ', NOk, ' of ', NMODES,
          ' modes are comfortably within the adapter''s caps.');
  if NMarg > 0 then
    WriteLn('  ', NMarg, ' more sit within 1% of the clock cap -- try those,',
            ' do not assume them.');

  if not EdidValid then
  begin
    WriteLn;
    WriteLn('  No EDID was read, so the monitor column is unknown and the');
    WriteLn('  adapter''s caps are only half the answer.');
    Exit;
  end;

  WriteLn('  ', NBoth, ' of those are also advertised by this display.');
  if Best >= 0 then
  begin
    WriteLn;
    WriteLn('  >> START WITH ', Dec1(Modes[Best].W), 'x', Dec1(Modes[Best].H),
            '@', Dec1(Modes[Best].Hz), ' -- the largest mode the adapter');
    WriteLn('  >> allows outright AND the display actually advertises.');
    WriteLn('  >> That is ', Dec1(LongInt(Modes[Best].W) * Modes[Best].H * 2),
            ' bytes a frame at 16bpp.');
  end
  else
  begin
    WriteLn;
    WriteLn('  >> The display advertises none of the modes the adapter');
    WriteLn('  >> allows.  That is NOT the same as nothing working -- a');
    WriteLn('  >> display will often sync a mode it never claimed.  Take');
    WriteLn('  >> the largest row marked ok in the adapter column and try');
    WriteLn('  >> it; DLTEST /M= is there for exactly this.');
  end;
end;

{ ------------------------------------------------------------------- EDID }

{ One pass at the monitor: read, report, and say whether anything usable
  came back.  This is a function rather than inline code because the read
  is worth doing TWICE -- see the second ask in the main body. }
function EdidPass: Boolean;
var
  I:       Integer;
  AllZero: Boolean;
  HdrOk:   Boolean;
begin
  EdidPass := False;
  EdidGot := ReadEdid(EdidWant);
  Fld('bytes read', Dec1(EdidGot));

  if EdidGot < 128 then
  begin
    WriteLn;
    if EdidGot = 0 then
    begin
      WriteLn('  Zero bytes means the vendor request itself failed -- see');
      WriteLn('  the status above.  That is a protocol fault, and a');
      WriteLn('  different problem from an empty VGA socket.');
    end
    else
    begin
      WriteLn('  Short: the read stopped early.  The control path is proven');
      WriteLn('  regardless, by that count being more than zero.');
    end;
    Exit;
  end;

  AllZero := True;
  for I := 0 to 127 do
    if Edid[I] <> 0 then AllZero := False;
  HdrOk := (Edid[0] = $00) and (Edid[1] = $FF) and (Edid[2] = $FF)
           and (Edid[3] = $FF) and (Edid[4] = $FF) and (Edid[5] = $FF)
           and (Edid[6] = $FF) and (Edid[7] = $00);

  { Every transfer succeeding and every byte coming back zero is a real
    outcome, and it is TWO findings rather than one failure: the vendor
    control path works, and the adapter has no monitor data to hand over.
    Keeping them apart matters, because the first is the milestone and the
    second is a cable, a sleeping monitor, or an ordering mistake of ours.

    Nothing is decoded from a zero block.  It would pass the EDID checksum
    test trivially -- 128 zeroes sum to zero -- so printing "checksum ok"
    next to a failed header is worse than printing nothing at all. }
  if AllZero then
  begin
    WriteLn;
    WriteLn('  All ', EdidGot, ' transfers SUCCEEDED and every byte came back');
    WriteLn('  zero.  That is two facts, not one failure: the vendor');
    WriteLn('  control path WORKS, and the adapter handed over no monitor');
    WriteLn('  data.  Nothing below is decoded -- a zero block passes the');
    WriteLn('  checksum test trivially and would answer every question');
    WriteLn('  with a confident lie.');
    Exit;
  end;

  WriteLn;
  HexDump(Edid, 128, '  ');
  WriteLn;
  if not HdrOk then
  begin
    Fld('header', 'BAD -- this is not EDID');
    WriteLn;
    WriteLn('  The fields are not decoded.  A block that fails its own');
    WriteLn('  header check still yields a manufacturer and a version');
    WriteLn('  number, and they are meaningless -- which is harder to');
    WriteLn('  notice than a blank.');
    Exit;
  end;

  Fld('header', 'ok');
  if EdidSum = 0 then Fld('checksum', 'ok')
                 else Fld('checksum', 'BAD (sums to ' + Dec1(EdidSum) + ')');
  Fld('manufacturer', EdidMaker);
  Fld('product code', Hex4(Edid[10] or (Word(Edid[11]) shl 8)));
  Fld('EDID version', Dec1(Edid[18]) + '.' + Dec1(Edid[19]));
  if Edid[17] > 0 then
    Fld('made', 'week ' + Dec1(Edid[16]) + ' of '
        + Dec1(1990 + LongInt(Edid[17])));
  if (Edid[21] > 0) and (Edid[22] > 0) then
    Fld('screen size', Dec1(Edid[21]) + ' x ' + Dec1(Edid[22]) + ' cm');
  ShowDescriptors;
  ShowEstablished;
  ShowStandard;
  EdidValid := True;
  EdidPass := True;
end;

{ ------------------------------------------------------------------ main }

procedure Usage;
begin
  WriteLn('  DLPROBE [/P=260] [/E=n] [/K] [/I=n] [/V] [/T]');
  WriteLn;
  WriteLn('    /P=hex  I/O base, default 260');
  WriteLn('    /E=dec  EDID bytes to read, default 128.  0 skips it');
  WriteLn('    /K      skip the channel unlock (the only write it makes)');
  WriteLn('    /I=dec  also poll the interrupt endpoint this many times');
  WriteLn('    /V      narrate the bring-up');
  WriteLn('    /T      trace every control-transfer stage');
  HelpTail;
end;

function HexArg(const S: ShortString; From: Integer): Word;
var I: Integer; V: Word;
begin
  V := 0;
  for I := From to Length(S) do
    case UpCase(S[I]) of
      '0'..'9': V := V * 16 + (Ord(S[I]) - 48);
      'A'..'F': V := V * 16 + (Ord(UpCase(S[I])) - 55);
    end;
  HexArg := V;
end;

function DecArg(const S: ShortString; From: Integer): Integer;
var I, V: Integer;
begin
  V := 0;
  for I := From to Length(S) do
    if (S[I] >= '0') and (S[I] <= '9') then V := V * 10 + (Ord(S[I]) - 48);
  DecArg := V;
end;

{ Leave the chip fit for the next program to find, which takes more than
  restoring the retry policy.

  Polling an endpoint that never answers leaves a token PENDING inside the
  chip: WaitInt gives up after its timeout, but the chip does not, and a
  program that exits at that moment strands the transaction.  The next tool
  along then asks CHECK_EXIST, gets nothing, and reports "no CH375 at
  0260" on a card that is plainly fitted -- which reads as a hardware
  fault and is entirely self-inflicted.  This cost two runs during the
  Ethernet work and one here, from the interrupt poll below.

  ABORT_NAK retires the stranded token; the retry policy then goes back to
  reporting NAKs rather than absorbing them. }
procedure Quieten;
begin
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

{ A chip left wedged by an earlier program fails CHECK_EXIST, and BusUp
  gives up on that before it ever reaches its own ChipReset -- so the
  wedge is sticky across runs and looks like an empty slot.  Reset and ask
  again before believing the card is absent.  ECMLINK learned this the
  same way. }
function ChipThere: Boolean;
begin
  ChipThere := ChipHere(Base);
  if ChipThere then Exit;
  WriteLn('CHECK_EXIST found nothing -- resetting the chip and re-asking,');
  WriteLn('because a chip left mid-transaction by an earlier program');
  WriteLn('fails this test on a card that is fitted.');
  ChipReset;
  DelayMs(200);
  ChipThere := ChipHere(Base);
  if ChipThere then WriteLn('  ...answered on the second ask.');
end;

var
  Rc, I, St: Integer;
  S:         ShortString;
  Got:       Word;
  GotB, Tog: Byte;
  J:         Byte;
  VID, PID:  Word;
  GotEdid:   Boolean;
  Unlocked:  Boolean = False;

begin
  Banner('DLPROBE', VER, 'DisplayLink USB display probe');
  if HelpWanted then begin Usage; Halt(0); end;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'E': EdidWant := DecArg(S, 4);
        'I': IntPolls := DecArg(S, 4);
        'K': NoKey := True;
        'V': Verbose := True;
        'T': CtrlTrace := True;
      end;
  end;
  if EdidWant > 128 then EdidWant := 128;
  if Verbose or CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');
  WriteLn;

  { Recover a wedged chip before BusUp can mistake it for an empty slot,
    and arm the exit hook first so even a failure here leaves things tidy. }
  ExitProc := @Quieten;
  if not ChipThere then
  begin
    WriteLn(BusUpReason(BU_NO_CHIP));
    Halt(BU_NO_CHIP);
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

  Fld('chip', 'CH375 rev ' + Hex2(IcVer));
  Fld('ep0 max', Dec1(Ep0Max) + ' bytes');
  Fld('device', Hex4(VID) + ':' + Hex4(PID));

  if VID <> DL_VID then
  begin
    WriteLn;
    WriteLn('idVendor ', Hex4(VID), ' is not DisplayLink (', Hex4(DL_VID),
            '), so none of');
    WriteLn('the command stream below applies and none of it is attempted.');
    WriteLn;
    WriteLn('  ', DlFamilyName(DlFamily(VID)));
    WriteLn;
    DlFamilyVerdict(DlFamily(VID));
    Halt(6);
  end;
  Fld('', 'DisplayLink (idVendor 17E9)');

  { ---- the configuration in full, for the 5Fh block and the endpoints ---- }
  St := CtrlIn($80, REQ_GET_DESCR, Word(DT_CONFIG) shl 8, 0,
               CfgWant, Cfg, SizeOf(Cfg), CfgGot);
  if (St <> INT_SUCCESS) or (CfgGot < 9) then
  begin
    WriteLn;
    WriteLn('The configuration descriptor would not come back: ',
            StatusStr(St));
    Halt(5);
  end;
  WalkConfig;

  St := SetConfig(CfgDesc[5]);
  Fld('SET_CONFIGURATION', Dec1(CfgDesc[5]) + ' -> ' + StatusStr(St));
  if EpBulk <> 0 then
    Fld('bulk OUT endpoint', Hex2(EpBulk)
        + '   (where commands and pixels would go)');
  if EpInt <> 0 then
    Fld('interrupt IN endpoint', Hex2(EpInt));

  { ---- capabilities ---- }
  Head('CAPABILITIES  (vendor descriptor 5Fh)');
  if VendLen = 0 then
    WriteLn('  No 5Fh block in the configuration descriptor.')
  else
  begin
    Fld('source', 'embedded in the configuration descriptor');
    HexDump(Vend, VendLen, '  ');
    WriteLn;
    if not ParseVendor then
      WriteLn('  (the decode did not hold together -- raw bytes above stand)');
  end;

  { And standalone, the way udlfb asks for it.  Diagnostic only: the copy
    above is where the numbers came from. }
  St := CtrlIn($80, REQ_GET_DESCR, Word(DT_VENDOR) shl 8, 0,
               255, Tmp, SizeOf(Tmp), Got);
  WriteLn;
  Fld('GET_DESCRIPTOR 5F', StatusStr(St) + ', ' + Dec1(Got)
      + ' bytes   (udlfb fetches it this way)');

  { ---- the monitor, first ask: before the unlock ---- }
  GotEdid := False;
  if EdidWant > 0 then
  begin
    Head('MONITOR, FIRST ASK  (before the channel unlock)');
    GotEdid := EdidPass;
  end;

  { ---- the one write ---- }
  Head('RENDERING CHANNEL');
  if NoKey then
    WriteLn('  /K given -- the unlock was not sent, so this run wrote nothing.')
  else
  begin
    St := CtrlOut($40, DL_REQ_CHANNEL, 0, 0, ChanKey, 16);
    Fld('unlock key', StatusStr(St));
    WriteLn;
    if St = INT_SUCCESS then
    begin
      WriteLn('  Accepted.  The chip will take rendering commands on bulk');
      WriteLn('  endpoint ', Hex2(EpBulk), ' from here.  Nothing sends any yet.');
      Unlocked := True;
    end
    else
    begin
      WriteLn('  Refused.  Rendering cannot work until this does, so that');
      WriteLn('  is the next thing to understand -- ahead of the pixel');
      WriteLn('  format, which is useless without it.');
    end;
  end;

  { ---- the monitor, second ask: after the unlock ----

    The first ask deliberately comes before the unlock, so that a chip
    revision which REFUSED the key would still yield a monitor report.
    That ordering costs nothing when it works -- and when it does not, it
    leaves an obvious hypothesis untested: that this chip will not read the
    monitor's DDC until its channel is open.

    So ask again.  Which ask succeeds is itself the finding, and it is
    cheap: 128 control transfers.  If the second one works where the first
    did not, the ordering rationale above is wrong for this hardware and
    the header should say so. }
  if (EdidWant > 0) and (not GotEdid) and Unlocked then
  begin
    Head('MONITOR, SECOND ASK  (after the channel unlock)');
    WriteLn('  The first ask came back with nothing.  Testing whether this');
    WriteLn('  chip simply will not read the monitor until its channel is');
    WriteLn('  open -- if this one works, the ordering above is wrong.');
    WriteLn;
    if EdidPass then
    begin
      WriteLn;
      WriteLn('  >> SO THE UNLOCK IS A PREREQUISITE FOR READING THE');
      WriteLn('  >> MONITOR on this hardware.  Worth recording: the first');
      WriteLn('  >> ask is not merely cautious, it is useless.');
      GotEdid := True;
    end;
  end;

  { ---- the interrupt endpoint, if asked ---- }
  if (IntPolls > 0) and (EpInt <> 0) then
  begin
    Head('INTERRUPT ENDPOINT ' + Hex2(EpInt));

    { The retry policy is OPPOSITE for the two transfer types, and this is
      the second time the project has had to learn it.  BusUp leaves the
      chip on 8F -- retry NAKs in hardware -- which is right while
      enumerating, because a control transfer's data stage must be retried
      inside the transfer.  On a DATA endpoint it is exactly wrong: a NAK
      there means "nothing for you yet", which is an ANSWER, and absorbing
      it in hardware turns every quiet poll into a 60 ms timeout reported
      as "no interrupt" -- indistinguishable from a dead endpoint.
      So report NAKs here, and say so in the output. }
    SetRetry($00);
    WriteLn('  NAKs are reported rather than retried in hardware, so a');
    WriteLn('  "NAK" below means the endpoint answered and had nothing to');
    WriteLn('  say.  That is a different finding from silence.');
    WriteLn;
    Tog := $80;
    for I := 1 to IntPolls do
    begin
      St := EpIn(EpInt, Tog, Tmp, SizeOf(Tmp), GotB);
      Write('  poll ', I, ' -> ', StatusStr(St));
      if (St = INT_SUCCESS) and (GotB > 0) then
      begin
        Write('   ');
        for J := 0 to GotB - 1 do Write(Hex2(Tmp[J]), ' ');
      end;
      WriteLn;
      DelayMs(50);
    end;
  end;

  { ---- what this thing can actually be asked to display ---- }
  Head('MODES WITHIN THE CHIP''S OWN LIMITS');
  if PixLimit > 0 then Fld('pixel-area limit', Dec1(PixLimit) + ' px');
  if ClkLimit > 0 then Fld('pixel-clock limit', Mhz(ClkLimit div 1000));
  WriteLn;
  ShowReachable;

  WriteLn;
  WriteLn('=== done ===');
  Halt(0);
end.
