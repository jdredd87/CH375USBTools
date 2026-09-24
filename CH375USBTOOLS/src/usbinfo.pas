program usbinfo;
{ USBINFO -- dump everything a USB device will tell you, over a CH375.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  Enumerates whatever is plugged into the card and prints every descriptor
  it can reach, decoded field by field and with the raw bytes alongside.
  It does not care what class the device is -- that is the whole point.
  CHDIAG in the mouse project stops at "not a mouse"; this stops at nothing.

    USBINFO [/P=260] [/N] [/X] [/1] [/V]

      /P=hex   I/O base, default 260
      /N       skip string descriptors (some devices are slow about them)
      /X       raw hex only, no decode
      /1       configuration 1 only; normally every one is fetched
      /V       narrate the bring-up as it happens

  What it reaches, in order: device descriptor, the LANGID list and every
  string the device names an index for, every configuration in full with
  its interfaces, alternate settings and endpoints, any class-specific
  descriptor embedded in a configuration, the device qualifier and
  other-speed configuration if the device is USB 2.0, and the HID report
  descriptor of every HID interface as raw bytes.  HIDREP decodes those.

  Two of those need a real control transfer with a data stage, which the
  chip's own GET_DESCR shortcut cannot do -- see ch375.pas.

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

var
  Big:      array[0..1023] of Byte;   { a configuration, in full }
  SBuf:     array[0..255] of Byte;    { one string descriptor }
  Rpt:      array[0..511] of Byte;    { one HID report descriptor }
  LangId:   Word = 0;
  NoStrings: Boolean = False;
  RawOnly:  Boolean = False;
  OneCfg:   Boolean = False;
  Verbose:  Boolean = False;
  HidIfs:   array[0..15] of Byte;     { interfaces with a HID descriptor }
  HidLens:  array[0..15] of Word;     { and the report-descriptor length }
  NHid:     Integer = 0;

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

{ A field line: name padded to a column, then the value.  Everything lines
  up, which is most of what makes a descriptor dump readable. }
procedure Fld(const Name: ShortString; const Value: ShortString);
var S: ShortString;
begin
  S := '  ' + Name;
  while Length(S) < 24 do S := S + ' ';
  WriteLn(S + Value);
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ BCD as USB writes versions: 0200h is "2.00". }
function Bcd(W: Word): ShortString;
begin
  Bcd := '';
  if (Hi(W) shr 4) <> 0 then Bcd := Hex1(Hi(W) shr 4);
  Bcd := Bcd + Hex1(Hi(W) and 15) + '.' +
         Hex1(Lo(W) shr 4) + Hex1(Lo(W) and 15);
end;

function W16(const B: array of Byte; I: Word): Word;
begin
  W16 := B[I] or (Word(B[I + 1]) shl 8);
end;

{ ----------------------------------------------------------------------
  Strings.  Index 0 is the LANGID list, not text; everything else is
  UTF-16LE.  This is a DOS code page 437 screen, so a character above 7Eh
  is printed as a dot rather than guessed at.
  ---------------------------------------------------------------------- }

function GetString(Idx: Byte): ShortString;
var
  St: Integer;
  Got, I, Want: Word;
  R: ShortString;
  C: Word;
begin
  GetString := '';
  if (Idx = 0) or NoStrings then Exit;
  St := GetDescr(DT_STRING, Idx, LangId, SBuf, 2, Got);
  if (Got < 2) or (SBuf[1] <> DT_STRING) then
  begin
    GetString := '<' + StatusName(St) + '>';
    Exit;
  end;
  Want := SBuf[0];
  if Want < 2 then Exit;
  if Want > SizeOf(SBuf) then Want := SizeOf(SBuf);
  St := GetDescr(DT_STRING, Idx, LangId, SBuf, Want, Got);
  if Got < 2 then begin GetString := '<' + StatusName(St) + '>'; Exit; end;
  if SBuf[1] <> DT_STRING then Exit;
  if Got > Want then Got := Want;
  R := '';
  I := 2;
  while (I + 1 < Got) and (Length(R) < 200) do
  begin
    C := W16(SBuf, I);
    if (C >= 32) and (C <= 126) then R := R + Chr(C)
    else if C <> 0 then R := R + '.';
    Inc(I, 2);
  end;
  GetString := R;
end;

procedure ShowString(const Name: ShortString; Idx: Byte);
var S: ShortString;
begin
  if Idx = 0 then begin Fld(Name, '00  (none)'); Exit; end;
  S := GetString(Idx);
  if S = '' then Fld(Name, Hex2(Idx))
            else Fld(Name, Hex2(Idx) + '  "' + S + '"');
end;

procedure ShowLangIds;
var
  St: Integer;
  Got, I, Want: Word;
  L: Word;
begin
  Head('STRING LANGUAGES');
  St := GetDescr(DT_STRING, 0, 0, SBuf, 2, Got);
  if (Got >= 2) and (SBuf[1] = DT_STRING) and (SBuf[0] >= 4) then
  begin
    Want := SBuf[0];
    if Want > SizeOf(SBuf) then Want := SizeOf(SBuf);
    St := GetDescr(DT_STRING, 0, 0, SBuf, Want, Got);
    if Got > Want then Got := Want;
  end;
  if (Got < 4) or (SBuf[1] <> DT_STRING) then
  begin
    WriteLn('  index 0 will not read (', StatusName(St), ')');
    WriteLn('  -- assuming ', LangName($0409), '; the strings themselves');
    WriteLn('     are often readable even when the language list is not');
    LangId := $0409;
    Exit;
  end;
  HexDump(SBuf, Got, '  ');
  I := 2;
  while I + 1 < Got do
  begin
    L := W16(SBuf, I);
    if LangId = 0 then LangId := L;
    Fld('LANGID ' + Hex4(L), LangName(L));
    Inc(I, 2);
  end;
  if LangId = 0 then LangId := $0409;
end;

{ ----------------------------------------------------------------------
  Device descriptor
  ---------------------------------------------------------------------- }

procedure ShowDevice;
begin
  Head('DEVICE DESCRIPTOR  (' + Dec1(DevLen) + ' bytes)');
  HexDump(DevDesc, DevLen, '  ');
  if RawOnly or (DevLen < 18) then
  begin
    if DevLen < 18 then WriteLn('  short -- ', DevLen, ' bytes, expected 18');
    Exit;
  end;
  WriteLn;
  Fld('bLength',            Dec1(DevDesc[0]));
  Fld('bDescriptorType',    Hex2(DevDesc[1]) + '  ' + DescrTypeName(DevDesc[1]));
  Fld('bcdUSB',             Bcd(W16(DevDesc, 2)));
  Fld('bDeviceClass',       Hex2(DevDesc[4]) + '  ' +
                            ClassName(DevDesc[4], DevDesc[5], DevDesc[6]));
  Fld('bDeviceSubClass',    Hex2(DevDesc[5]));
  Fld('bDeviceProtocol',    Hex2(DevDesc[6]));
  Fld('bMaxPacketSize0',    Dec1(DevDesc[7]));
  if VendorName(W16(DevDesc, 8)) <> '' then
    Fld('idVendor',         Hex4(W16(DevDesc, 8)) + '  ' +
                            VendorName(W16(DevDesc, 8)))
  else
    Fld('idVendor',         Hex4(W16(DevDesc, 8)));
  Fld('idProduct',          Hex4(W16(DevDesc, 10)));
  Fld('bcdDevice',          Bcd(W16(DevDesc, 12)));
  ShowString('iManufacturer',  DevDesc[14]);
  ShowString('iProduct',       DevDesc[15]);
  ShowString('iSerialNumber',  DevDesc[16]);
  Fld('bNumConfigurations', Dec1(DevDesc[17]));
end;

{ ----------------------------------------------------------------------
  Endpoint, interface and the class-specific descriptors that sit between
  them.  A configuration descriptor is a flat byte stream of length/type
  records; walking it is the whole job.
  ---------------------------------------------------------------------- }

procedure ShowEndpoint(const B: array of Byte; P: Word);
var
  A, Att: Byte;
  MP: Word;
  S: ShortString;
begin
  A := B[P + 2]; Att := B[P + 3]; MP := W16(B, P + 4);
  S := 'EP ' + Hex2(A) + '  ';
  if (A and $80) <> 0 then S := S + 'IN   ' else S := S + 'OUT  ';
  S := S + EpTypeName(Att);
  while Length(S) < 26 do S := S + ' ';
  S := S + 'max ' + Dec1(MP and $7FF);
  { Bits 11..12 of wMaxPacketSize are the high-bandwidth multiplier, and
    only mean anything for high-speed isochronous and interrupt endpoints.
    The CH375 is a full-speed host, so they should always be zero here --
    printed anyway, because a device that sets them is worth knowing about. }
  if ((MP shr 11) and 3) <> 0 then
    S := S + ' x' + Dec1(((MP shr 11) and 3) + 1);
  S := S + '  interval ' + Dec1(B[P + 6]);
  if (Att and 3) = 1 then
    S := S + '  sync ' + Dec1((Att shr 2) and 3) +
             ' usage ' + Dec1((Att shr 4) and 3);
  WriteLn('      ', S);
end;

procedure ShowInterface(const B: array of Byte; P: Word);
var S: ShortString;
begin
  S := 'INTERFACE ' + Dec1(B[P + 2]);
  if B[P + 3] <> 0 then S := S + ' alt ' + Dec1(B[P + 3]);
  WriteLn('    ', S);
  Fld('  bInterfaceClass',  Hex2(B[P + 5]) + '/' + Hex2(B[P + 6]) + '/' +
                            Hex2(B[P + 7]) + '  ' +
                            ClassName(B[P + 5], B[P + 6], B[P + 7]));
  Fld('  bNumEndpoints',    Dec1(B[P + 4]));
  ShowString('  iInterface', B[P + 8]);
end;

procedure ShowHidDesc(const B: array of Byte; P: Word; IfNum: Byte);
var
  I, N: Byte;
  L: Word;
begin
  WriteLn('      HID descriptor  version ', Bcd(W16(B, P + 2)),
          '  country ', B[P + 4]);
  N := B[P + 5];
  for I := 0 to N - 1 do
  begin
    if P + 7 + I * 3 + 1 > High(B) then Break;
    L := W16(B, P + 7 + I * 3);
    WriteLn('        subordinate: ', DescrTypeName(B[P + 6 + I * 3]),
            ', ', L, ' bytes');
    if (B[P + 6 + I * 3] = DT_HID_REPORT) and (NHid < 16) then
    begin
      HidIfs[NHid] := IfNum; HidLens[NHid] := L; Inc(NHid);
    end;
  end;
end;

procedure ShowHubDesc(const B: array of Byte; P: Word);
begin
  WriteLn('      HUB descriptor  ', B[P + 2], ' ports, ',
          'power-on delay ', B[P + 5] * 2, ' ms, ',
          'max current ', B[P + 6], ' mA');
end;

procedure ShowIfAssoc(const B: array of Byte; P: Word);
begin
  WriteLn('    INTERFACE ASSOCIATION  first ', B[P + 2],
          ', count ', B[P + 3], '  ',
          ClassName(B[P + 4], B[P + 5], B[P + 6]));
end;

procedure WalkConfig(var B: array of Byte; Len: Word);
var
  P, L: Word;
  T, CurIf: Byte;
begin
  P := 0; CurIf := 0;
  while P + 2 <= Len do
  begin
    L := B[P]; T := B[P + 1];
    { A zero or one-byte record cannot advance the walk, and a length that
      runs past the end means the descriptor is truncated or corrupt.  Stop
      rather than loop forever or read someone else's memory. }
    if L < 2 then
    begin
      WriteLn('    -- malformed: length ', L, ' at offset ', P, ', stopping');
      Break;
    end;
    if P + L > Len then
    begin
      WriteLn('    -- truncated: record at ', P, ' claims ', L,
              ' bytes, only ', Len - P, ' left');
      Break;
    end;
    case T of
      DT_CONFIG: ;                       { already printed by the caller }
      DT_INTERFACE:
        if L >= 9 then
        begin
          CurIf := B[P + 2];
          WriteLn;
          ShowInterface(B, P);
        end;
      DT_ENDPOINT:
        if L >= 7 then ShowEndpoint(B, P);
      DT_IF_ASSOC:
        if L >= 8 then ShowIfAssoc(B, P);
      DT_HID:
        if L >= 9 then ShowHidDesc(B, P, CurIf);
      DT_HUB:
        if L >= 7 then ShowHubDesc(B, P);
    else
      WriteLn('      ', DescrTypeName(T), '  (', L, ' bytes)');
    end;
    Inc(P, L);
  end;
end;

procedure ShowConfig(Index: Byte);
var
  St: Integer;
  Got: Word;
  Total: Word;
  Att, Quick: Byte;
  S: ShortString;
begin
  { Two fetches: the first nine bytes give wTotalLength, the second asks
    for exactly that.  Asking for a fixed large number instead works on
    most devices and hangs a few, so it is not worth the one saved round
    trip. }
  St := GetDescr(DT_CONFIG, Index, LangId, Big, 9, Got);
  if (Got < 9) then
  begin
    WriteLn;
    WriteLn('CONFIGURATION ', Index, ': cannot read (', StatusName(St), ')');
    Exit;
  end;
  Total := W16(Big, 2);
  if Total > SizeOf(Big) then Total := SizeOf(Big);
  St := GetDescr(DT_CONFIG, Index, LangId, Big, Total, Got);
  if Got < 9 then
  begin
    { The manual transfer came back empty but the chip's own GET_DESCR
      shortcut drives the whole thing in firmware.  It only knows types 1
      and 2 and only reaches configuration 0, but this is type 2 and often
      that is exactly the configuration wanted, so it is worth one try
      before giving up. }
    WriteLn;
    WriteLn('  control transfer returned ', Got, ' bytes (',
            StatusName(St), '); falling back to the chip shortcut');
    if Index = 0 then
    begin
      St := GetDescrQuick(DT_CONFIG, Big, SizeOf(Big), Quick);
      Got := Quick;
    end;
  end;

  Head('CONFIGURATION index ' + Dec1(Index) + '  (' + Dec1(Got) + ' of ' +
       Dec1(Total) + ' bytes)');
  HexDump(Big, Got, '  ');
  if RawOnly then Exit;
  if Got < 9 then Exit;
  WriteLn;
  Fld('wTotalLength',        Dec1(W16(Big, 2)));
  Fld('bNumInterfaces',      Dec1(Big[4]));
  Fld('bConfigurationValue', Dec1(Big[5]));
  ShowString('iConfiguration', Big[6]);
  Att := Big[7];
  S := Hex2(Att) + '  ';
  if (Att and $40) <> 0 then S := S + 'self powered' else S := S + 'bus powered';
  if (Att and $20) <> 0 then S := S + ', remote wakeup';
  Fld('bmAttributes',        S);
  Fld('bMaxPower',           Dec1(Big[8] * 2) + ' mA');
  if Got < W16(Big, 2) then
    WriteLn('  -- short read; the decode below covers what arrived');
  WalkConfig(Big, Got);
end;

{ ----------------------------------------------------------------------
  USB 2.0 extras.  A 1.x device stalls both of these, which is not an
  error -- it is the answer.
  ---------------------------------------------------------------------- }

procedure ShowQualifier;
var St: Integer; Got: Word;
begin
  if W16(DevDesc, 2) < $0200 then Exit;
  Head('DEVICE QUALIFIER');
  St := GetDescr(DT_QUALIFIER, 0, LangId, Big, 10, Got);
  if (St <> INT_SUCCESS) or (Got < 10) then
  begin
    WriteLn('  not supported (', StatusName(St), ') -- normal for a device');
    WriteLn('  that has no high-speed personality');
    Exit;
  end;
  HexDump(Big, Got, '  ');
  Fld('bcdUSB',            Bcd(W16(Big, 2)));
  Fld('bDeviceClass',      Hex2(Big[4]) + '  ' +
                           ClassName(Big[4], Big[5], Big[6]));
  Fld('bMaxPacketSize0',   Dec1(Big[7]));
  Fld('bNumConfigurations', Dec1(Big[8]));
end;

procedure ShowHidReports;
var
  I: Integer;
  St: Integer;
  Got, Want: Word;
begin
  if NHid = 0 then Exit;
  for I := 0 to NHid - 1 do
  begin
    Head('HID REPORT DESCRIPTOR  interface ' + Dec1(HidIfs[I]) +
         '  (' + Dec1(HidLens[I]) + ' bytes)');
    Want := HidLens[I];
    if Want > SizeOf(Rpt) then Want := SizeOf(Rpt);
    { Interface-targeted GET_DESCRIPTOR: recipient is the interface, so
      wIndex is the interface number, not a language. }
    St := CtrlIn($81, REQ_GET_DESCR, (Word(DT_HID_REPORT) shl 8) or 0,
                 HidIfs[I], Want, Rpt, SizeOf(Rpt), Got);
    if Got = 0 then
    begin
      WriteLn('  cannot read (', StatusName(St), ')');
      Continue;
    end;
    HexDump(Rpt, Got, '  ');
    if Got < HidLens[I] then
      WriteLn('  -- short: ', Got, ' of ', HidLens[I], ' bytes');
    WriteLn;
    WriteLn('  HIDREP /I=', HidIfs[I], ' decodes this.');
  end;
end;

{ ---------------------------------------------------------------------- }

procedure ParseArgs;
var I, Code: Integer; A: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/N') or (A = '-N') then NoStrings := True
    else if (A = '/X') or (A = '-X') then RawOnly := True
    else if (A = '/1') or (A = '-1') then OneCfg := True
    else if (A = '/V') or (A = '-V') then Verbose := True
    else if Copy(A, 1, 3) = '/P=' then
    begin
      Val('$' + Copy(A, 4, 4), V, Code);
      if Code = 0 then Base := Word(V);
    end;
  end;
end;

procedure Usage;
begin
  Banner('USBINFO', VER, 'dump everything a USB device will tell you');
  WriteLn;
  WriteLn('  USBINFO [/P=260] [/N] [/X] [/1] [/V]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /N       skip string descriptors; some devices are slow');
  WriteLn('  /X       raw hex only, no decode');
  WriteLn('  /1       configuration 1 only; normally every one is fetched');
  WriteLn('  /V       narrate the bring-up as it happens');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Prints, in order: the device descriptor, every string the');
  WriteLn('device names an index for, every configuration in full with its');
  WriteLn('interfaces and endpoints, the device qualifier if it is USB 2.0,');
  WriteLn('and the raw HID report descriptor of each HID interface.');
  WriteLn('HIDREP decodes those.  It does not care what class the device');
  WriteLn('is -- that is the whole point of it.');
  WriteLn;
  WriteLn('Exit: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,');
  WriteLn('      4 attached but silent, 5 device stopped answering');
  HelpTail;
end;

var
  Rc: Integer;
  NCfg, C: Byte;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  if Verbose then Trace := @Narrate;

  Banner('USBINFO', VER, 'CH375 USB device probe');
  WriteLn('I/O base ', Hex4(Base), 'h  (data ', Hex4(Base),
          ', command ', Hex4(Base + 1), ')');
  WriteLn;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;

  WriteLn('chip     : CH375 rev ', Hex2(IcVer));
  if LowSpeed then WriteLn('bus      : low speed (1.5 Mbps)')
              else WriteLn('bus      : full speed (12 Mbps)');
  WriteLn('bus regs : 07=', Hex2(GetReg($07)),
          '  1C=', Hex2(GetReg($1C)), ' (40 = SOF running)',
          '  20=', Hex2(GetReg($20)));
  WriteLn('ep0 max  : ', Ep0Max, ' bytes');

  if not NoStrings then ShowLangIds;
  ShowDevice;

  NCfg := 1;
  if DevLen >= 18 then NCfg := DevDesc[17];
  if NCfg = 0 then NCfg := 1;
  if OneCfg then NCfg := 1;
  for C := 0 to NCfg - 1 do ShowConfig(C);

  ShowQualifier;
  ShowHidReports;

  WriteLn;
  WriteLn('=== done ===');
  Halt(0);
end.
