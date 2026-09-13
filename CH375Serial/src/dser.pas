unit dser;
{ dser -- USB-to-serial adapters over a CH375: the bring-up, and telling one
  chipset from another.
  CH375Serial, StevenC.  Public domain (the Unlicense).

  WHY THIS ONE SHOULD ACTUALLY WORK

  CH375Audio ended in a measured impossibility, and the reason is worth
  restating here because it is exactly what this project does NOT hit.
  Audio is isochronous, wants 192-byte packets, and must be fed
  continuously at 192 KB/s.  A USB-to-serial adapter is the opposite on all
  three counts:

    * BULK endpoints, which is one of the three transfer types a CH375
      does, and the one it does best.
    * 64-byte packets or smaller, which is exactly the chip's buffer.
    * Rates that are trivial.  115200 baud is 11.5 KB/s and 9600 baud is
      960 bytes/s, against the ~19 KB/s this collection has measured.  And
      unlike audio there is no deadline: a serial byte that arrives late is
      a byte that arrives late, not a click.

  Both ends buffer, which is the property that decides everything on this
  bus -- see the rule in the collection's top-level README.

  THE AWKWARD PART IS THAT THERE IS NO SINGLE PROTOCOL

  Only CDC-ACM is a real standard.  Everything else -- FTDI, Prolific,
  WCH, Silicon Labs -- is a private vendor protocol reached through control
  transfers, and they disagree about everything: how a baud rate is
  encoded, whether line settings are one request or three, and in FTDI's
  case whether the data stream even contains only data.  So the shape of
  this unit is: identify the family first, then dispatch.

  FTDI IS THE ONE THAT BITES.  Every bulk IN packet from an FTDI part
  begins with TWO STATUS BYTES -- modem lines and line status -- and the
  data follows them.  A reader that does not strip those gets two bytes of
  rubbish at the head of every 64-byte packet, which looks like a baud rate
  mismatch and is not.  It is this project's equivalent of DisplayLink's
  LFSR: obvious once known, invisible until then. }

{$MODE OBJFPC}{$H-}

interface

uses ch375;

const
  { Standard classes that matter here. }
  CLASS_COMM     = $02;         { CDC control interface }
  CLASS_CDCDATA  = $0A;         { CDC data interface }
  CLASS_VENDOR   = $FF;

  CDC_SUBCLASS_ACM = $02;

  { CDC class-specific descriptors, inside the control interface. }
  CS_INTERFACE   = $24;
  CDC_HEADER     = $00;
  CDC_CALLMGMT   = $01;
  CDC_ACM        = $02;
  CDC_UNION      = $06;

  { CDC-ACM class requests (bmRequestType 21h out, A1h in). }
  CDC_SET_LINE_CODING   = $20;
  CDC_GET_LINE_CODING   = $21;
  CDC_SET_CTRL_LINE     = $22;

  { Vendor IDs this unit knows how to talk to, or knows it cannot. }
  VID_FTDI       = $0403;
  VID_PROLIFIC   = $067B;
  VID_CP210X     = $10C4;
  VID_WCH        = $1A86;
  VID_KEYSPAN    = $06CD;

type
  TSerFamily = (sfUnknown, sfCdcAcm, sfFtdi, sfPl2303, sfCh34x, sfCp210x,
                sfKeyspan);

  TBigCfg = array[0..1023] of Byte;

  { Everything a driver needs once the device has been identified. }
  TSerDev = record
    Family   : TSerFamily;
    VID, PID : Word;
    CtrlIf   : Byte;            { CDC control interface, 0 for vendor parts }
    DataIf   : Byte;            { the interface carrying the bulk endpoints }
    EpIn     : Byte;            { bulk IN  endpoint number }
    EpOut    : Byte;            { bulk OUT endpoint number }
    EpInMax  : Word;
    EpOutMax : Word;
    EpNotify : Byte;            { interrupt IN for line state, 0 if none }
    { Keyspan parts split the job across FOUR endpoints rather than two:
      data in/out, plus a separate control OUT and status IN. Recorded
      here because a driver that assumes the two-endpoint shape silently
      sends its line settings down the data pipe. }
    EpCtrlOut: Byte;
    EpStatIn : Byte;
    NBulkIn  : Byte;            { how many bulk INs the config declares }
    NBulkOut : Byte;
    HasNotify: Boolean;
    StatusHdr: Byte;            { bytes of status at the head of each IN }
  end;

function SerFamilyName(F: TSerFamily): ShortString;

{ True if this unit can actually drive that family today, as opposed to
  merely recognising it. Kept separate on purpose: "I know what you are"
  and "I can talk to you" are different answers and a probe should not
  blur them. }
function SerSupported(F: TSerFamily): Boolean;

{ Identify from the device and configuration descriptors already fetched. }
function SerDetect(const Cfg: TBigCfg; Len: Word;
                   VID, PID: Word; var D: TSerDev): Boolean;

{ ---- the pieces every tool here needs, proven in CH375Audio ---- }

function ChipThere: Boolean;
procedure Quieten;
procedure Stage(const S: ShortString);
function GetConfigFull(Index: Byte; var Buf: TBigCfg; var Len: Word;
                       var Why: ShortString): Boolean;

{ Bring the device up on a CHOSEN configuration.

  CfgIndex is the descriptor INDEX to fetch (0-based); the value actually
  sent in SET_CONFIGURATION is bConfigurationValue out of that descriptor,
  which is NOT the same number and is a classic way to select nothing at
  all. This device makes the distinction visible: its two configurations
  are index 0 / value 1 and index 1 / value 2. }
function BringUpCfg(CfgIndex: Byte; var Cfg: TBigCfg; var Len: Word;
                    var Why: ShortString): Integer;
function BringUp(var Cfg: TBigCfg; var Len: Word;
                 var Why: ShortString): Integer;

implementation

function SerFamilyName(F: TSerFamily): ShortString;
begin
  case F of
    sfCdcAcm: SerFamilyName := 'CDC-ACM (the standard one)';
    sfFtdi:   SerFamilyName := 'FTDI';
    sfPl2303: SerFamilyName := 'Prolific PL2303';
    sfCh34x:  SerFamilyName := 'WCH CH340/CH341';
    sfCp210x: SerFamilyName := 'Silicon Labs CP210x';
    sfKeyspan: SerFamilyName := 'Keyspan (InnoSys)';
  else
    SerFamilyName := 'unknown';
  end;
end;

function SerSupported(F: TSerFamily): Boolean;
begin
  SerSupported := F in [sfCdcAcm, sfFtdi, sfCh34x, sfCp210x];
end;

{ Identification is by VENDOR ID first and class second, and that order is
  deliberate.

  A CDC-ACM device says so in its interface class and can be believed. A
  vendor part says class FFh, which tells you only that the class means
  nothing -- so the VID is the whole identification, exactly as it was for
  DisplayLink in CH375Video. Doing it the other way round would classify
  every FTDI cable as "unknown vendor device" and stop there.

  The exception that makes the order matter: some CH340 variants and a few
  Prolific clones ALSO present a CDC-ACM interface. Those are better driven
  as CDC-ACM -- it is the documented path -- so a device that looks like
  both is taken as CDC. }
function SerDetect(const Cfg: TBigCfg; Len: Word;
                   VID, PID: Word; var D: TSerDev): Boolean;
var
  P      : Word;
  L, T   : Byte;
  CurIf  : Integer;
  CurCls : Byte;
  CurSub : Byte;
  SawCdc : Boolean;
  SawData: Boolean;
  EpAddr : Byte;
  EpAttr : Byte;
  EpMax  : Word;
begin
  D.Family := sfUnknown;
  D.VID := VID; D.PID := PID;
  D.CtrlIf := 0; D.DataIf := 0;
  D.EpIn := 0; D.EpOut := 0; D.EpNotify := 0;
  D.EpInMax := 0; D.EpOutMax := 0;
  D.HasNotify := False;
  D.StatusHdr := 0;
  D.EpCtrlOut := 0; D.EpStatIn := 0;
  D.NBulkIn := 0; D.NBulkOut := 0;
  SawCdc := False; SawData := False;
  CurIf := -1; CurCls := 0; CurSub := 0;

  P := 0;
  while P + 2 <= Len do
  begin
    L := Cfg[P];
    T := Cfg[P + 1];
    if (L = 0) or (P + L > Len) then Break;

    if T = $04 then                       { INTERFACE }
    begin
      CurIf  := Cfg[P + 2];
      CurCls := Cfg[P + 5];
      CurSub := Cfg[P + 6];
      if (CurCls = CLASS_COMM) and (CurSub = CDC_SUBCLASS_ACM) then
      begin
        SawCdc := True;
        D.CtrlIf := Byte(CurIf);
      end
      else if CurCls = CLASS_CDCDATA then
      begin
        SawData := True;
        D.DataIf := Byte(CurIf);
      end;
    end
    else if T = $05 then                  { ENDPOINT }
    begin
      EpAddr := Cfg[P + 2];
      EpAttr := Cfg[P + 3] and $03;
      EpMax  := Cfg[P + 4] or (Word(Cfg[P + 5]) shl 8);
      if EpAttr = 2 then                  { bulk }
      begin
        if (EpAddr and $80) <> 0 then
        begin
          Inc(D.NBulkIn);
          { The SECOND bulk IN, on a part that has more than one, is the
            status pipe on every layout met so far. }
          if (D.EpIn <> 0) and (D.EpStatIn = 0) then
            D.EpStatIn := EpAddr and $0F;
          if D.EpIn = 0 then
          begin
            D.EpIn := EpAddr and $0F;
            D.EpInMax := EpMax;
            if not SawData then D.DataIf := Byte(CurIf);
          end;
        end
        else
        begin
          Inc(D.NBulkOut);
          if (D.EpOut <> 0) and (D.EpCtrlOut = 0) then
            D.EpCtrlOut := EpAddr and $0F;
          if D.EpOut = 0 then
          begin
            D.EpOut := EpAddr and $0F;
            D.EpOutMax := EpMax;
            if not SawData then D.DataIf := Byte(CurIf);
          end;
        end;
      end
      else if (EpAttr = 3) and ((EpAddr and $80) <> 0) then
      begin
        Inc(D.NBulkIn);            { counted so the two configs compare }
        { Interrupt IN: CDC's notification endpoint, or FTDI's unused one.
          Only the FIRST is kept -- a composite part can have several and
          the line-state one is always on the control interface. }
        if D.EpNotify = 0 then
        begin
          D.EpNotify := EpAddr and $0F;
          D.HasNotify := True;
        end;
      end;
    end;

    Inc(P, L);
  end;

  { Now decide the family. }
  if SawCdc and SawData then
    D.Family := sfCdcAcm
  else
    case VID of
      VID_FTDI:     D.Family := sfFtdi;
      VID_PROLIFIC: D.Family := sfPl2303;
      VID_WCH:      D.Family := sfCh34x;
      VID_CP210X:   D.Family := sfCp210x;
      VID_KEYSPAN:  D.Family := sfKeyspan;
    else
      if SawCdc then D.Family := sfCdcAcm;
    end;

  { FTDI puts two status bytes at the head of EVERY bulk IN packet. It is
    not optional and it is not a header on the first packet only -- it is
    on all of them, including the ones carrying no data at all, which is
    how an idle FTDI part answers with 2 bytes rather than NAKing. }
  if D.Family = sfFtdi then D.StatusHdr := 2;

  { Keyspan puts ONE byte in front of the data on every bulk IN packet.
    This is MEASURED, not recalled: an adapter loopback of "AT"+CR came
    back as three packets of two bytes -- 00 41, 00 54, 00 0D -- so the
    leading byte is a per-packet flag and the data follows it. A reader
    that does not strip it gets a NUL between every character, which looks
    like a framing or baud error and is not. Same shape of trap as FTDI's
    two bytes, and the reason that one is documented here too. }
  if D.Family = sfKeyspan then D.StatusHdr := 1;

  SerDetect := (D.EpIn <> 0) and (D.EpOut <> 0);
end;

{ ------------------------------------------------------------------ }
{  Bring-up.  Lifted from CH375Audio's daudio.pas, where each of these
   was learned the hard way; the comments there have the full story and
   are not repeated at length.                                        }
{ ------------------------------------------------------------------ }

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

procedure Quieten;
begin
  WrCmd(CMD_ABORT_NAK);
  SetRetry($00);
end;

procedure Stage(const S: ShortString);
begin
  Write(StdErr, '  [', S, ']'#13#10);
end;

function GetConfigFull(Index: Byte; var Buf: TBigCfg; var Len: Word;
                       var Why: ShortString): Boolean;
var
  R, Total: Integer;
  S: ShortString;
begin
  GetConfigFull := False;
  Why := '';
  R := GetDescr(DT_CONFIG, Index, 0, Buf, 9, Len);
  if Len < 9 then
  begin
    Why := 'cannot read the configuration header (' + StatusName(R) + ')';
    Exit;
  end;
  Total := Buf[2] or (Integer(Buf[3]) shl 8);
  if Total > SizeOf(Buf) then Total := SizeOf(Buf);
  R := GetDescr(DT_CONFIG, Index, 0, Buf, Total, Len);
  if Len < Word(Total) then
  begin
    Str(Len, S);
    Why := 'only ' + S + ' of ';
    Str(Total, S);
    Why := Why + S + ' bytes of the configuration descriptor arrived ('
           + StatusName(R) + '); refusing to decode a partial device';
    Exit;
  end;
  GetConfigFull := True;
end;

function BringUp(var Cfg: TBigCfg; var Len: Word;
                 var Why: ShortString): Integer;
begin
  BringUp := BringUpCfg(0, Cfg, Len, Why);
end;

function BringUpCfg(CfgIndex: Byte; var Cfg: TBigCfg; var Len: Word;
                    var Why: ShortString): Integer;
var R: Integer;
begin
  Why := '';
  Stage('chip');
  if not ChipThere then begin BringUpCfg := BU_NO_CHIP; Exit; end;

  Stage('enumerate');
  R := BusUp;
  if R <> BU_OK then begin BringUpCfg := R; Exit; end;

  Stage('descriptors');
  if not GetConfigFull(CfgIndex, Cfg, Len, Why) then
  begin
    BringUpCfg := BU_NO_CONFIG;
    Exit;
  end;

  Stage('set config');
  R := SetConfig(Cfg[5]);
  if R <> INT_SUCCESS then
  begin
    Why := 'SET_CONFIGURATION ' + StatusName(R);
    BringUpCfg := BU_NO_CONFIG;
    Exit;
  end;

  { SET_RETRY 00 GOES HERE -- after every control transfer of the
    bring-up, and before any endpoint is polled.

    BusUp arms SET_RETRY 8F (retry NAKs forever), which is right while
    enumerating and catastrophic afterwards: an idle serial adapter NAKs
    its bulk IN constantly, so leaving it armed makes the chip grind on a
    NAK until it stops answering anything at all, CHECK_EXIST included.
    That froze a machine in CH375Audio.

    But it must not be done EARLY either, which is the half CH375Audio got
    wrong and got away with. Put it before the descriptor fetch and a
    device that NAKs a control transfer once -- entirely normal while it
    prepares a response -- fails on the first ask. This adapter has an
    8-byte control endpoint, so its descriptors take many round trips and
    it NAKs during them; it failed instantly with "cannot read the
    configuration header (NAK)" until this moved down here. The speaker in
    CH375Audio answered fast enough never to show it. }
  SetRetry($00);

  Stage('ready');
  BringUpCfg := BU_OK;
end;

end.
