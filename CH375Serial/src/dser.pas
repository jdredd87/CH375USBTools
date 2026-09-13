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
    { Data toggles, kept with the device so a caller cannot get them out
      of step by holding its own copies. }
    TogIn    : Byte;
    TogOut   : Byte;
    TogCtl   : Byte;
    TogStat  : Byte;
    Opened   : Boolean;
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

{ ---- the driver interface: one shape, several chipsets ----

  Everything above identifies a device; these four actually drive it, and
  each dispatches on D.Family.  The split matters because only CDC-ACM is a
  standard -- the rest are private vendor protocols that agree about
  nothing -- so the ONLY thing they can share is this interface.

  SerOpen configures and enables the port.  SerSend and SerRecv move bytes
  and hide the per-packet header that some parts put in front of received
  data (FTDI two bytes, Keyspan one).  SerClose releases the line.

  A family that is recognised but not implemented returns False from
  SerOpen rather than pretending, and SerSupported says so in advance. }

{ Bits is 5..8, Par is 0 none / 1 odd / 2 even, Stop is 1 or 2.

  RxBatch is how many characters the adapter should gather before sending
  a USB packet, and it is exposed rather than hidden because on this
  hardware it is the difference between working and not: one character per
  packet is 960 packets/second at 9600 baud and this CH375 manages a few
  hundred.  SerBatchFor computes a sensible value from the baud rate. }
function SerOpen(var D: TSerDev; Baud: LongInt;
                 Bits, Par, Stop, RxBatch: Byte): Boolean;
function SerSend(var D: TSerDev; const Buf; Len: Byte): Boolean;
function SerRecv(var D: TSerDev; var Buf; Max: Word; var Got: Byte): Boolean;
procedure SerClose(var D: TSerDev);

{ Characters per USB packet that keeps the packet rate near 110/s, which
  is inside what this chip sustains. }
function SerBatchFor(Baud: LongInt): Byte;

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
  SerSupported := F in [sfCdcAcm, sfFtdi, sfCp210x, sfKeyspan];
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

function SerBatchFor(Baud: LongInt): Byte;
var N: LongInt;
begin
  { bytes/s is baud/10; aim for about 110 packets/s, which is inside what
    this chip sustains. }
  N := Baud div 1000;
  if N < 4 then N := 4;
  if N > 48 then N := 48;
  SerBatchFor := Byte(N);
end;

{ ---------------------------------------------------------------- }
{  Keyspan usa90.  The layout is reconstructed rather than          }
{  documented, and the device confirmed it: the status message it   }
{  returns is exactly the 14 bytes the struct predicts, the port    }
{  reports ENABLED, and an adapter loopback returns what was sent.  }
{ ---------------------------------------------------------------- }

const
  KEYSPAN_BAUDCLK = 14769231;
  KS_LEN = 34;
  KS_SETCLOCK = 0;  KS_BAUDLO = 1;   KS_BAUDHI = 2;
  KS_SETLCR = 3;    KS_LCR = 4;
  KS_SETRXMODE = 5; KS_SETTXMODE = 7;
  KS_SETTXFLOW = 9; KS_SETRXFLOW = 11;
  KS_SETRTS = 19;   KS_RTS = 20;
  KS_SETDTR = 21;   KS_DTR = 22;
  KS_RXFWDLEN = 23; KS_RXFWDTMO = 24; KS_TXACK = 25;
  KS_PORTENABLED = 26;
  KS_RXFLUSH = 30;  KS_RETSTATUS = 33;

function KeyspanOpen(var D: TSerDev; Baud: LongInt;
                     Bits, Par, Stop, RxBatch, Enable: Byte): Boolean;
var
  M   : array[0..KS_LEN - 1] of Byte;
  Dv  : LongInt;
  K   : Integer;
  Lcr : Byte;
begin
  for K := 0 to KS_LEN - 1 do M[K] := 0;
  Dv := KEYSPAN_BAUDCLK div (Baud * 16);
  if Dv < 1 then Dv := 1;

  { The 16550 LCR everyone uses: data bits in 0-1, stop bit in 2, parity
    above that. }
  Lcr := (Bits - 5) and $03;
  if Stop >= 2 then Lcr := Lcr or $04;
  if Par = 1 then Lcr := Lcr or $08
  else if Par = 2 then Lcr := Lcr or $18;

  M[KS_SETCLOCK] := 1;
  M[KS_BAUDLO]   := Byte(Dv and $FF);
  M[KS_BAUDHI]   := Byte((Dv shr 8) and $FF);
  M[KS_SETLCR]   := 1;
  M[KS_LCR]      := Lcr;
  M[KS_SETRXMODE] := 1;
  M[KS_SETTXMODE] := 1;
  M[KS_SETTXFLOW] := 1;
  M[KS_SETRXFLOW] := 1;
  M[KS_SETRTS]   := 1;  M[KS_RTS] := Enable;
  M[KS_SETDTR]   := 1;  M[KS_DTR] := Enable;
  M[KS_RXFWDLEN] := RxBatch;
  M[KS_RXFWDTMO] := 16;
  M[KS_TXACK]    := 1;
  M[KS_PORTENABLED] := Enable;
  M[KS_RXFLUSH]  := 1;
  M[KS_RETSTATUS] := 1;

  KeyspanOpen := EpOut(D.EpCtrlOut, D.TogCtl, M, KS_LEN) = INT_SUCCESS;
end;

{ ---------------------------------------------------------------- }
{  CDC-ACM.  The only one of these that is a published standard,    }
{  and the only one where the baud rate is simply the baud rate     }
{  rather than a divisor somebody has to reverse out.               }
{ ---------------------------------------------------------------- }

function CdcOpen(var D: TSerDev; Baud: LongInt;
                 Bits, Par, Stop, Enable: Byte): Boolean;
var
  B: array[0..7] of Byte;
  R: Integer;
begin
  B[0] := Byte(Baud and $FF);
  B[1] := Byte((Baud shr 8) and $FF);
  B[2] := Byte((Baud shr 16) and $FF);
  B[3] := Byte((Baud shr 24) and $FF);
  if Stop >= 2 then B[4] := 2 else B[4] := 0;
  B[5] := Par;
  B[6] := Bits;
  R := CtrlOut($21, CDC_SET_LINE_CODING, 0, Word(D.CtrlIf), B, 7);
  if R <> INT_SUCCESS then
  begin
    CdcOpen := False;
    Exit;
  end;
  { SET_CONTROL_LINE_STATE: bit 0 is DTR, bit 1 is RTS. }
  if Enable <> 0 then
    R := CtrlNoData($21, CDC_SET_CTRL_LINE, $0003, Word(D.CtrlIf))
  else
    R := CtrlNoData($21, CDC_SET_CTRL_LINE, $0000, Word(D.CtrlIf));
  CdcOpen := R = INT_SUCCESS;
end;

{ ---------------------------------------------------------------- }
{  FTDI.  Vendor requests on endpoint 0, and a divisor carrying a   }
{  three-bit fraction encoded into the top of wIndex.               }
{ ---------------------------------------------------------------- }

const
  FtdiFrac: array[0..7] of Word = (0, 3, 2, 4, 1, 5, 6, 7);

function FtdiOpen(var D: TSerDev; Baud: LongInt;
                  Bits, Par, Stop, Enable: Byte): Boolean;
var
  Dv, Fr: LongInt;
  V, Idx, Lcr: Word;
  R: Integer;
begin
  FtdiOpen := False;
  if CtrlNoData($40, $00, 0, 0) <> INT_SUCCESS then Exit;   { reset }

  { 3,000,000 / baud, held in eighths so the fraction survives. }
  Dv := (3000000 * 8) div Baud;
  Fr := Dv and 7;
  Dv := Dv shr 3;
  V := Word(Dv and $3FFF);
  Idx := FtdiFrac[Fr] shl 14;
  if (Dv shr 14) <> 0 then Idx := Idx or 1;
  if CtrlNoData($40, $03, V, Idx) <> INT_SUCCESS then Exit;

  { data characteristics: length in 0-7, parity in 8-10, stop in 11-13 }
  Lcr := Bits or (Word(Par) shl 8);
  if Stop >= 2 then Lcr := Lcr or (Word(2) shl 11);
  if CtrlNoData($40, $04, Lcr, 0) <> INT_SUCCESS then Exit;

  { modem control: each line has a value bit and a "change me" mask bit }
  if Enable <> 0 then
    R := CtrlNoData($40, $01, $0303, 0)
  else
    R := CtrlNoData($40, $01, $0300, 0);
  FtdiOpen := R = INT_SUCCESS;
end;

{ ---------------------------------------------------------------- }
{  Silicon Labs CP210x.                                             }
{ ---------------------------------------------------------------- }

function Cp210xOpen(var D: TSerDev; Baud: LongInt;
                    Bits, Par, Stop, Enable: Byte): Boolean;
var
  B: array[0..3] of Byte;
  Lcr: Word;
  R: Integer;
begin
  Cp210xOpen := False;
  if CtrlNoData($41, $00, 1, Word(D.DataIf)) <> INT_SUCCESS then Exit;
  B[0] := Byte(Baud and $FF);
  B[1] := Byte((Baud shr 8) and $FF);
  B[2] := Byte((Baud shr 16) and $FF);
  B[3] := Byte((Baud shr 24) and $FF);
  if CtrlOut($41, $1E, 0, Word(D.DataIf), B, 4) <> INT_SUCCESS then Exit;
  { SET_LINE_CTL: stop bits in 0-3, parity in 4-7, data bits in 8-15 }
  Lcr := Word(Bits) shl 8;
  Lcr := Lcr or (Word(Par) shl 4);
  if Stop >= 2 then Lcr := Lcr or 2;
  if CtrlNoData($41, $03, Lcr, Word(D.DataIf)) <> INT_SUCCESS then Exit;
  if Enable <> 0 then
    R := CtrlNoData($41, $07, $0303, Word(D.DataIf))
  else
    R := CtrlNoData($41, $07, $0300, Word(D.DataIf));
  Cp210xOpen := R = INT_SUCCESS;
end;

{ ---------------------------------------------------------------- }

function SerOpen(var D: TSerDev; Baud: LongInt;
                 Bits, Par, Stop, RxBatch: Byte): Boolean;
var Ok: Boolean;
begin
  D.TogIn := $80; D.TogOut := $80; D.TogCtl := $80; D.TogStat := $80;
  if (Bits < 5) or (Bits > 8) then Bits := 8;
  if Stop < 1 then Stop := 1;
  if RxBatch < 1 then RxBatch := 1;
  case D.Family of
    sfKeyspan: Ok := KeyspanOpen(D, Baud, Bits, Par, Stop, RxBatch, 1);
    sfCdcAcm:  Ok := CdcOpen(D, Baud, Bits, Par, Stop, 1);
    sfFtdi:    Ok := FtdiOpen(D, Baud, Bits, Par, Stop, 1);
    sfCp210x:  Ok := Cp210xOpen(D, Baud, Bits, Par, Stop, 1);
  else
    Ok := False;
  end;
  D.Opened := Ok;
  SerOpen := Ok;
end;

{ Release the line.  Dropping DTR and RTS is what tells a modem the call
  is over, and leaving them up is how a program that exits badly leaves a
  line seized. }
procedure SerClose(var D: TSerDev);
begin
  if not D.Opened then Exit;
  case D.Family of
    sfKeyspan: KeyspanOpen(D, 9600, 8, 0, 1, 16, 0);
    sfCdcAcm:  CdcOpen(D, 9600, 8, 0, 1, 0);
    sfFtdi:    FtdiOpen(D, 9600, 8, 0, 1, 0);
    sfCp210x:  Cp210xOpen(D, 9600, 8, 0, 1, 0);
  end;
  D.Opened := False;
end;

function SerSend(var D: TSerDev; const Buf; Len: Byte): Boolean;
begin
  SerSend := EpOut(D.EpOut, D.TogOut, Buf, Len) = INT_SUCCESS;
end;

{ Receive, with the per-packet header stripped.

  FTDI puts two status bytes at the head of EVERY bulk IN packet and
  Keyspan puts one, so an idle FTDI answers with a two-byte packet
  carrying no data at all rather than NAKing.  Got comes back as the count
  of real DATA bytes, which is what every caller wants; a packet that is
  nothing but header reads as Got = 0 and True -- nothing wrong, nothing
  to say.  A reader that skips this gets rubbish interleaved with its
  data and blames the baud rate. }
function SerRecv(var D: TSerDev; var Buf; Max: Word; var Got: Byte): Boolean;
var
  P : PByte;
  N : Byte;
  R : Integer;
  K : Integer;
begin
  Got := 0;
  P := @Buf;
  R := EpIn(D.EpIn, D.TogIn, Buf, Max, N);
  if R <> INT_SUCCESS then
  begin
    SerRecv := False;
    Exit;
  end;
  if N > D.StatusHdr then
  begin
    for K := 0 to N - 1 - D.StatusHdr do
      P[K] := P[K + D.StatusHdr];
    Got := N - D.StatusHdr;
  end;
  SerRecv := True;
end;

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
