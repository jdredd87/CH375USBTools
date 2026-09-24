unit ch375;
{ CH375 USB host-mode support  --  CH375USBTOOLS, StevenC & Claude
  Public domain (the Unlicense).

  Everything the probe tools and the keyboard driver need in order to talk
  to a WCH CH375 running as a USB host: the port handshake, the bring-up
  sequence, control transfers with a real data stage, and endpoint I/O.

  This is deliberately class-agnostic.  CHDIAG in the mouse project stops at
  "not a mouse"; nothing here cares what is plugged in.

  THE CARD.  The WCH CH375 ISA board's PLD decodes

      base+0   data port
      base+1   command port -- reading it, bit 7 clear = interrupt pending
      base+2   bit 0 = readback of the chip's INT# pin

  Only the first two are used.  Revisions from B5 up report readiness in bit
  7 of the command port, which is one IN rather than two, and that is what
  WaitInt uses.  Anything older needs the two-port dance and is refused.

  CONTROL TRANSFERS.  The chip has a GET_DESCR shortcut (command 46h) but it
  only knows descriptor types 1 and 2 -- device and configuration.  String
  descriptors, HID report descriptors, hub descriptors and every class
  request therefore have to be driven by hand, SETUP / data / status, which
  is what CtrlIn and CtrlOut do.  Two details there are not optional:

    * the data stage starts on DATA1, not DATA0, and alternates from there;
    * the status stage carries DATA1 as well.  Without saying so the chip
      answers 2Bh (toggle mismatch) instead of 14h and the transfer looks
      like it failed when the data already arrived intact.

  Short-packet detection needs the real endpoint-0 max packet size, so the
  device descriptor's byte 7 is remembered in Ep0Max as soon as it is read.

  LOW SPEED.  Most mice, and some keyboards, are 1.5 Mbps devices.  The bus
  has to be told, with command 04h, and WHERE that goes is the whole trick:
  SET_USB_MODE puts the bus back to 12 Mbps, so the speed must be set after
  the last mode change -- but issued straight after SET_USB_MODE 6 it is
  silently ignored, and every transaction then times out exactly as though
  the chip had no low-speed support at all.  It only takes once the connect
  interrupt raised by the bus reset has been read and cleared.  BusUp does
  those in that order.  Move one and this stops working while looking for
  all the world like a hardware fault. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

const
  { ---- CH375 commands ---- }
  CMD_GET_IC_VER   = $01;
  CMD_SET_SPEED    = $04;      { CH376-documented; B7 firmware has it }
  CMD_RESET_ALL    = $05;
  CMD_CHECK_EXIST  = $06;
  CMD_READ_REG     = $0A;      { "GET_MAX_LUN" in the datasheet; really a
                                 general read of an internal byte }
  CMD_SET_RETRY    = $0B;
  CMD_SET_USB_ADDR = $13;
  CMD_SET_USB_MODE = $15;
  CMD_TEST_CONNECT = $16;
  CMD_ABORT_NAK    = $17;
  CMD_SET_ENDP6    = $1C;      { receive endpoint: bit 6 = data toggle }
  CMD_SET_ENDP7    = $1D;      { transmit endpoint: bit 6 = data toggle }
  CMD_GET_STATUS   = $22;
  CMD_RD_USB_DATA  = $28;
  CMD_WR_USB_DATA7 = $2B;
  CMD_CLR_STALL    = $41;
  CMD_SET_ADDRESS  = $45;
  CMD_GET_DESCR    = $46;
  CMD_SET_CONFIG   = $49;
  CMD_ISSUE_TOKEN  = $4F;

  { ---- interrupt status ---- }
  INT_SUCCESS      = $14;
  INT_CONNECT      = $15;
  INT_DISCONNECT   = $16;
  INT_BUF_OVER     = $17;
  INT_USB_READY    = $18;
  INT_RET_NAK      = $2A;
  INT_RET_STALL    = $2E;

  { ---- token PIDs ---- }
  PID_OUT          = $01;
  PID_IN           = $09;
  PID_SETUP        = $0D;

  { ---- descriptor types ---- }
  DT_DEVICE        = 1;
  DT_CONFIG        = 2;
  DT_STRING        = 3;
  DT_INTERFACE     = 4;
  DT_ENDPOINT      = 5;
  DT_QUALIFIER     = 6;
  DT_OTHERSPEED    = 7;
  DT_IF_POWER      = 8;
  DT_OTG           = 9;
  DT_DEBUG         = 10;
  DT_IF_ASSOC      = 11;
  DT_BOS           = 15;
  DT_HID           = $21;
  DT_HID_REPORT    = $22;
  DT_HID_PHYS      = $23;
  DT_HUB           = $29;

  { ---- standard requests ---- }
  REQ_GET_STATUS   = 0;
  REQ_CLEAR_FEAT   = 1;
  REQ_SET_FEAT     = 3;
  REQ_SET_ADDRESS  = 5;
  REQ_GET_DESCR    = 6;
  REQ_SET_DESCR    = 7;
  REQ_GET_CONFIG   = 8;
  REQ_SET_CONFIG   = 9;
  REQ_GET_IFACE    = 10;
  REQ_SET_IFACE    = 11;

  { ---- HID class requests ---- }
  HID_GET_REPORT   = $01;
  HID_GET_IDLE     = $02;
  HID_GET_PROTOCOL = $03;
  HID_SET_REPORT   = $09;
  HID_SET_IDLE     = $0A;
  HID_SET_PROTOCOL = $0B;

  USB_ADDR         = 2;        { the address we hand the device }

  { ---- BusUp result codes.  Also the tools' exit codes, so all <= 20. ---- }
  BU_OK            = 0;
  BU_NO_CHIP       = 1;
  BU_OLD_CHIP      = 2;
  BU_NOTHING       = 3;        { nothing plugged in }
  BU_NO_ANSWER     = 4;        { attached, but nothing answers on the bus }
  BU_NO_CONFIG     = 5;        { device descriptor came back, config did not }

type
  TBuf256 = array[0..255] of Byte;
  TTraceProc = procedure(const Line: ShortString);

var
  Base:     Word = $260;       { I/O base, /P= overrides }
  PortDat:  Word = $260;
  PortCmd:  Word = $261;
  IcVer:    Byte = 0;          { chip revision, from GET_IC_VER }
  Ep0Max:   Byte = 8;          { endpoint 0 max packet; 8 until we know }
  LowSpeed: Boolean = False;   { bus was dropped to 1.5 Mbps }
  DevDesc:  TBuf256;           { device descriptor as fetched }
  DevLen:   Byte = 0;
  CfgDesc:  TBuf256;           { configuration 0's descriptor, truncated to
                                 256 bytes -- CfgWant says how long it really
                                 is, CfgLen how much we hold }
  CfgLen:   Byte = 0;
  CfgWant:  Word = 0;
  Trace:    TTraceProc = nil;  { set to have BusUp narrate itself }
  CtrlTrace: Boolean = False;  { and every control-transfer stage }
  CtrlGap:  Word = 0;          { ms of settle after each transfer }
  { The data stage of a control transfer starts on DATA1 by spec.  This is
    settable only so USBCTL can prove that on a device that argues. }
  CtrlFirstTog: Byte = $C0;

{ ---- raw port layer ---- }
function  InB(P: Word): Byte;
procedure OutB(P: Word; V: Byte);
procedure WrCmd(C: Byte);
procedure WrDat(D: Byte);
function  RdDat: Byte;
procedure DelayMs(N: Word);

{ ---- chip ---- }
function  ChipHere(B: Word): Boolean;   { CHECK_EXIST at base B; sets ports }
procedure ChipReset;
function  GetReg(A: Byte): Byte;
procedure SetMode(M: Byte);
procedure SetRetry(V: Byte);
function  Ready: Boolean;
function  WaitInt(Ms: Word): Integer;   { -1 = no interrupt within Ms }
function  ReadUsb(var Buf; Max: Word): Byte;
function  StatusName(St: Integer): ShortString;
function  StatusStr(St: Integer): ShortString;

{ ---- bring-up ---- }
function  BusUp: Integer;
function  BusUpReason(Code: Integer): ShortString;
procedure WhyNoAnswer;                  { the three usual causes, printed }

{ ---- transfers ---- }
function  CtrlIn(RType, Req: Byte; Val, Idx, Len: Word;
                 var Buf; Max: Word; var Got: Word): Integer;
function  CtrlOut(RType, Req: Byte; Val, Idx: Word;
                  const Buf; Len: Byte): Integer;
function  CtrlNoData(RType, Req: Byte; Val, Idx: Word): Integer;
function  GetDescrQuick(DType: Byte; var Buf; Max: Word; var Got: Byte): Integer;
function  GetDescr(DType, DIndex: Byte; LangId: Word;
                   var Buf; Max: Word; var Got: Word): Integer;
function  SetAddress(A: Byte): Integer;
function  SetConfig(V: Byte): Integer;
function  EpIn(Ep: Byte; var Tog: Byte; var Buf; Max: Word;
               var Got: Byte): Integer;
function  EpOut(Ep: Byte; var Tog: Byte; const Buf; Len: Byte): Integer;
procedure ClrStall(Ep: Byte);

{ ---- the host machine ----
  KeyWaiting is BIOS INT 16h, deliberately, and not CRT's KeyPressed.  The
  CRT unit takes over the screen and writes straight to video memory, which
  means its output never reaches the redirected stdout the bridge captures
  -- a tool that uses it runs perfectly and appears to print nothing at
  all.  Two lines of INT 16h avoid pulling CRT in for the sake of one
  keyboard poll. }
function  KeyWaiting: Boolean;
procedure EatKey;
function  Ticks: LongInt;         { BIOS tick counter at 0040:006C, 18.2 Hz }

{ ---- formatting ---- }
function  Hex1(B: Byte): Char;
function  Hex2(B: Byte): ShortString;
function  Hex4(W: Word): ShortString;
function  Sgn(B: Byte): Integer;
procedure HexDump(const Buf; Len: Word; const Indent: ShortString);
procedure HexDumpAt(const Buf; Ofs, Len: Word; const Indent: ShortString);

{ ---- USB vocabulary ---- }
function  ClassName(C, S, P: Byte): ShortString;
function  DescrTypeName(T: Byte): ShortString;
function  EpTypeName(A: Byte): ShortString;
function  LangName(L: Word): ShortString;
function  VendorName(V: Word): ShortString;

implementation

{ ------------------------------------------------------------------------
  Port layer.  The two IN $61 reads are the standard ISA settling delay --
  port 61h is the keyboard controller's port B, harmless to read, and on an
  8 MHz bus two of them are comfortably longer than the CH375 needs between
  a command byte and the data byte that follows it.
  ------------------------------------------------------------------------ }

function InB(P: Word): Byte; assembler;
asm
  mov dx, P
  in  al, dx
end;

procedure OutB(P: Word; V: Byte); assembler;
asm
  mov dx, P
  mov al, V
  out dx, al
end;

procedure IoDelay; begin InB($61); InB($61); end;

procedure WrCmd(C: Byte); begin IoDelay; OutB(PortCmd, C); IoDelay; end;
procedure WrDat(D: Byte); begin OutB(PortDat, D); IoDelay; end;
function  RdDat: Byte;    begin IoDelay; RdDat := InB(PortDat); end;

procedure DelayMs(N: Word);
var I, J: Word;
begin
  for I := 1 to N do
    for J := 1 to 700 do InB($61);
end;

{ ------------------------------------------------------------------------
  Chip
  ------------------------------------------------------------------------ }

function ChipHere(B: Word): Boolean;
var R: Byte;
begin
  Base := B; PortDat := B; PortCmd := B + 1;
  WrCmd(CMD_CHECK_EXIST); WrDat($55);
  R := RdDat;
  { CHECK_EXIST answers with the ones-complement of what it was sent, so
    55h -> AAh.  An empty ISA slot floats to FFh or 00h and fails this. }
  ChipHere := R = $AA;
end;

procedure ChipReset;
begin
  WrCmd(CMD_RESET_ALL);
  DelayMs(60);
  WrCmd(CMD_GET_IC_VER);
  IcVer := RdDat;
end;

function GetReg(A: Byte): Byte;
begin
  WrCmd(CMD_READ_REG); WrDat(A); GetReg := RdDat;
end;

procedure SetMode(M: Byte);
begin
  WrCmd(CMD_SET_USB_MODE); WrDat(M); DelayMs(20); RdDat;
end;

procedure SetRetry(V: Byte);
begin
  WrCmd(CMD_SET_RETRY); WrDat($25); WrDat(V);
end;

function Ready: Boolean;
begin
  Ready := (InB(PortCmd) and $80) = 0;
end;

function WaitInt(Ms: Word): Integer;
var O, I: Word; R: Boolean;
begin
  R := False;
  for O := 1 to Ms do
  begin
    for I := 1 to 400 do begin R := Ready; if R then Break; end;
    if R then Break;
  end;
  if not R then begin WaitInt := -1; Exit; end;
  WrCmd(CMD_GET_STATUS);
  WaitInt := RdDat;
end;

function ReadUsb(var Buf; Max: Word): Byte;
var P: PByte; L, I: Byte;
begin
  P := @Buf;
  WrCmd(CMD_RD_USB_DATA);
  L := RdDat;
  { The count has to be drained from the chip whether or not we have room
    for it -- leaving bytes behind desynchronises every later read. }
  for I := 1 to L do
    if I <= Max then P[I - 1] := RdDat else RdDat;
  ReadUsb := L;
end;

function StatusName(St: Integer): ShortString;
begin
  case St of
    -1             : StatusName := 'no interrupt';
    INT_SUCCESS    : StatusName := 'success';
    INT_CONNECT    : StatusName := 'device connected';
    INT_DISCONNECT : StatusName := 'device disconnected';
    INT_BUF_OVER   : StatusName := 'buffer overflow';
    INT_USB_READY  : StatusName := 'usb ready';
    $20, $24, $28, $2C : StatusName := 'device did not answer (timeout)';
    $22            : StatusName := 'device returned ACK';
    $23            : StatusName := 'device returned DATA0';
    INT_RET_NAK    : StatusName := 'device returned NAK';
    $2B            : StatusName := 'device returned DATA1 (toggle mismatch)';
    INT_RET_STALL  : StatusName := 'device returned STALL';
  else
    StatusName := 'error';
  end;
end;

function StatusStr(St: Integer): ShortString;
begin
  if St < 0 then StatusStr := '--  ' + StatusName(St)
            else StatusStr := Hex2(Byte(St)) + '  ' + StatusName(St);
end;

procedure Say(const S: ShortString);
begin
  if Trace <> nil then Trace(S);
end;

{ ------------------------------------------------------------------------
  Control transfers
  ------------------------------------------------------------------------ }

{ Every control transfer starts by clearing endpoint 0.
  This is not defensive tidying, it is required, and it took a tally to see
  why.  CLR_STALL on the CH375 does more than clear a stall: it resets the
  endpoint's data toggle inside the chip.  Without it a control transfer
  that SUCCEEDS leaves endpoint 0 advanced, and the NEXT transfer's data
  stage is stalled by the device -- while a transfer that FAILED cleared
  the stall on its way out and so left the endpoint fit for the one after.
  The result is that control transfers work every other time, which reads
  as a flaky device or a bad cable and is neither.  USBCTL /N=6 shows it as
  [X.X.X.]; with this, [......]. }
procedure Setup8(RType, Req: Byte; Val, Idx, Len: Word);
begin
  ClrStall(0);
  WrCmd(CMD_WR_USB_DATA7); WrDat(8);
  WrDat(RType);      WrDat(Req);
  WrDat(Lo(Val));    WrDat(Hi(Val));
  WrDat(Lo(Idx));    WrDat(Hi(Idx));
  WrDat(Lo(Len));    WrDat(Hi(Len));
  WrCmd(CMD_SET_ENDP6); WrDat($80);        { SETUP is always DATA0 }
  WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_SETUP);
end;

{ Zero-length IN, DATA1: the status stage of a control-OUT transfer. }
function StatusIn: Integer;
begin
  WrCmd(CMD_SET_ENDP6); WrDat($C0);
  WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_IN);
  StatusIn := WaitInt(400);
end;

{ Zero-length OUT, DATA1: the status stage of a control-IN transfer. }
function StatusOut: Integer;
begin
  WrCmd(CMD_WR_USB_DATA7); WrDat(0);
  WrCmd(CMD_SET_ENDP7); WrDat($C0);
  WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_OUT);
  StatusOut := WaitInt(400);
end;

function CtrlIn(RType, Req: Byte; Val, Idx, Len: Word;
                var Buf; Max: Word; var Got: Word): Integer;
var
  P: PByte;
  R: Integer;
  Tog, N, I: Byte;
  Left: Word;
  Tmp: array[0..63] of Byte;
begin
  P := @Buf; Got := 0;
  R := 0;
  Setup8(RType, Req, Val, Idx, Len);
  R := WaitInt(400);
  if CtrlTrace then
    Say('    SETUP ' + Hex2(RType) + ' ' + Hex2(Req) + ' ' + Hex4(Val) +
        ' ' + Hex4(Idx) + ' ' + Hex4(Len) + ' -> ' + StatusStr(R));
  if R <> INT_SUCCESS then begin CtrlIn := R; Exit; end;

  { Data stage.  First packet is DATA1; the toggle alternates after that.
    A packet shorter than the endpoint's maximum ends the transfer, and so
    does satisfying wLength -- a device is entitled to send neither more
    nor a terminating zero-length packet once it has sent what was asked. }
  Tog := CtrlFirstTog;
  Left := Len;
  while Left > 0 do
  begin
    WrCmd(CMD_SET_ENDP6); WrDat(Tog);
    WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_IN);
    R := WaitInt(400);
    if CtrlTrace then
      Say('    IN  tog=' + Hex2(Tog) + ' -> ' + StatusStr(R));
    if R <> INT_SUCCESS then Break;
    N := ReadUsb(Tmp, SizeOf(Tmp));
    if CtrlTrace then Say('        ' + Hex2(N) + ' bytes');
    Tog := Tog xor $40;
    for I := 1 to N do
      if Got < Max then begin P[Got] := Tmp[I - 1]; Inc(Got); end;
    { Three ways a device says "that is all": a packet shorter than the
      endpoint maximum, a zero-length packet, or simply having sent what
      wLength asked for.  Asking for one more packet than the device has
      is how you earn a STALL, and that stall then poisons the NEXT
      transfer as well -- which shows up as every second control request
      failing, and looks for all the world like a flaky device. }
    if N = 0 then Break;
    if N < Ep0Max then Break;
    if N >= Left then Break;
    Dec(Left, N);
  end;

  { The status stage is reported, but a device that answers the data and
    then sulks on the handshake has still given us the data, so a failure
    here does not lose it -- Got stands either way. }
  if (R = INT_SUCCESS) or (Got > 0) then
  begin
    R := StatusOut;
    if CtrlTrace then Say('    STATUS OUT -> ' + StatusStr(R));
  end;
  if R = INT_RET_STALL then
  begin
    ClrStall(0);
    if CtrlTrace then Say('    CLEAR STALL on endpoint 0');
  end;
  if CtrlGap > 0 then DelayMs(CtrlGap);
  { Data that arrived is data, whatever the handshake afterwards did.  A
    device that over-runs and stalls the tail has still told us what it
    knows, so the caller sees success and Got bytes rather than an error
    and a buffer it is told to distrust. }
  if (R <> INT_SUCCESS) and (Got > 0) then R := INT_SUCCESS;
  CtrlIn := R;
end;

function CtrlOut(RType, Req: Byte; Val, Idx: Word;
                 const Buf; Len: Byte): Integer;
var
  P: PByte;
  R: Integer;
  I: Byte;
begin
  P := @Buf;
  Setup8(RType, Req, Val, Idx, Len);
  R := WaitInt(400);
  if R <> INT_SUCCESS then begin CtrlOut := R; Exit; end;

  if Len > 0 then
  begin
    WrCmd(CMD_WR_USB_DATA7); WrDat(Len);
    for I := 0 to Len - 1 do WrDat(P[I]);
    WrCmd(CMD_SET_ENDP7); WrDat($C0);      { data stage starts DATA1 }
    WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_OUT);
    R := WaitInt(400);
    if R <> INT_SUCCESS then
    begin
      if R = INT_RET_STALL then ClrStall(0);
      CtrlOut := R; Exit;
    end;
  end;

  R := StatusIn;
  if R = INT_RET_STALL then ClrStall(0);
  CtrlOut := R;
end;

function CtrlNoData(RType, Req: Byte; Val, Idx: Word): Integer;
var R: Integer;
begin
  Setup8(RType, Req, Val, Idx, 0);
  R := WaitInt(400);
  if R <> INT_SUCCESS then begin CtrlNoData := R; Exit; end;
  R := StatusIn;
  { A device that does not implement the request stalls endpoint 0, and a
    stall left set fails every later control transfer.  Clearing it costs
    two commands and makes the request genuinely optional. }
  if R = INT_RET_STALL then ClrStall(0);
  CtrlNoData := R;
end;

{ The chip's own shortcut.  It knows types 1 and 2 only, but it handles the
  whole transfer itself, which is what makes enumeration work before Ep0Max
  is known. }
function GetDescrQuick(DType: Byte; var Buf; Max: Word; var Got: Byte): Integer;
var R: Integer;
begin
  Got := 0;
  WrCmd(CMD_GET_DESCR); WrDat(DType);
  R := WaitInt(600);
  if R = INT_SUCCESS then Got := ReadUsb(Buf, Max);
  GetDescrQuick := R;
end;

function GetDescr(DType, DIndex: Byte; LangId: Word;
                  var Buf; Max: Word; var Got: Word): Integer;
begin
  GetDescr := CtrlIn($80, REQ_GET_DESCR,
                     (Word(DType) shl 8) or DIndex, LangId,
                     Max, Buf, Max, Got);
end;

function SetAddress(A: Byte): Integer;
var R: Integer;
begin
  WrCmd(CMD_SET_ADDRESS); WrDat(A);
  R := WaitInt(600);
  if R = INT_SUCCESS then
  begin
    WrCmd(CMD_SET_USB_ADDR); WrDat(A);   { and the host side follows }
    DelayMs(20);
  end;
  SetAddress := R;
end;

function SetConfig(V: Byte): Integer;
var R: Integer;
begin
  WrCmd(CMD_SET_CONFIG); WrDat(V);
  R := WaitInt(600);
  if R = INT_SUCCESS then DelayMs(50);
  SetConfig := R;
end;

procedure ClrStall(Ep: Byte);
begin
  WrCmd(CMD_CLR_STALL); WrDat(Ep);
  WaitInt(200);
end;

function EpIn(Ep: Byte; var Tog: Byte; var Buf; Max: Word;
              var Got: Byte): Integer;
var R: Integer;
begin
  Got := 0;
  WrCmd(CMD_SET_ENDP6); WrDat(Tog);
  WrCmd(CMD_ISSUE_TOKEN); WrDat((Ep shl 4) or PID_IN);
  R := WaitInt(60);
  if R = INT_SUCCESS then
  begin
    Got := ReadUsb(Buf, Max);
    Tog := Tog xor $40;
  end;
  EpIn := R;
end;

function EpOut(Ep: Byte; var Tog: Byte; const Buf; Len: Byte): Integer;
var
  P: PByte;
  R: Integer;
  I: Byte;
begin
  P := @Buf;
  WrCmd(CMD_WR_USB_DATA7); WrDat(Len);
  for I := 0 to Len - 1 do WrDat(P[I]);
  WrCmd(CMD_SET_ENDP7); WrDat(Tog);
  WrCmd(CMD_ISSUE_TOKEN); WrDat((Ep shl 4) or PID_OUT);
  R := WaitInt(60);
  if R = INT_SUCCESS then Tog := Tog xor $40;
  EpOut := R;
end;

{ ------------------------------------------------------------------------
  Bring-up.  The order is WCH's own, and every step of it earns its place;
  see the header for the low-speed trap in particular.
  ------------------------------------------------------------------------ }

function WaitFor(Want: Byte; Ms: Word; const Tag: ShortString): Boolean;
var St, N: Integer;
begin
  WaitFor := False;
  for N := 1 to 12 do
  begin
    St := WaitInt(Ms);
    Say('  ' + Tag + ': ' + StatusStr(St));
    if St < 0 then Exit;
    if St = Want then begin WaitFor := True; Exit; end;
  end;
end;

function BusUp: Integer;
var
  B: Byte;
  St, I: Integer;
  G: Byte;
  GotW: Word;
begin
  if not ChipHere(Base) then begin BusUp := BU_NO_CHIP; Exit; end;
  ChipReset;
  Say('IC version ' + Hex2(IcVer));
  if (IcVer < $B5) or (IcVer >= $C0) then
  begin
    BusUp := BU_OLD_CHIP; Exit;
  end;

  { ---- idle host mode, and the first connect ---- }
  SetMode(5);
  if not WaitFor(INT_CONNECT, 300, 'mode 5') then
  begin
    WrCmd(CMD_TEST_CONNECT); B := RdDat;
    Say('  TEST_CONNECT -> ' + StatusStr(B));
    if B <> INT_CONNECT then begin BusUp := BU_NOTHING; Exit; end;
  end;

  { ---- hold the bus in reset, then let it go ---- }
  DelayMs(100);
  SetMode(7);
  DelayMs(40);
  SetMode(6);
  if not WaitFor(INT_CONNECT, 400, 'after reset') then
    Say('  (no second connect; carrying on)');
  DelayMs(200);
  SetRetry($8F);                 { retry NAKs while enumerating }

  { ---- speed.  Only now, and only after the connect above was read. ---- }
  B := GetReg($07);
  LowSpeed := (B and $10) <> 0;
  if LowSpeed then
  begin
    Say('  low-speed device; dropping the bus to 1.5 Mbps');
    WrCmd(CMD_SET_SPEED); WrDat(2);
    RdDat;
    DelayMs(400);                { let the bus settle at the new rate }
  end
  else
    Say('  full-speed device (12 Mbps)');

  { ---- device descriptor, still at address 0 ---- }
  St := 0;
  for I := 1 to 6 do
  begin
    St := GetDescrQuick(DT_DEVICE, DevDesc, SizeOf(DevDesc), G);
    Say('  GET_DESCR device, try ' + Chr(Ord('0') + I) + ' -> ' + StatusStr(St));
    if St = INT_SUCCESS then Break;
    if St = INT_DISCONNECT then begin BusUp := BU_NOTHING; Exit; end;
    DelayMs(150);
  end;
  if St <> INT_SUCCESS then begin BusUp := BU_NO_ANSWER; Exit; end;
  DevLen := G;
  if DevLen >= 8 then Ep0Max := DevDesc[7];
  if Ep0Max = 0 then Ep0Max := 8;

  { ---- address, then the configuration ---- }
  St := SetAddress(USB_ADDR);
  Say('  SET_ADDRESS -> ' + StatusStr(St));
  if St <> INT_SUCCESS then begin BusUp := BU_NO_CONFIG; Exit; end;

  St := GetDescrQuick(DT_CONFIG, CfgDesc, SizeOf(CfgDesc), G);
  Say('  GET_DESCR config -> ' + StatusStr(St));

  { The chip's GET_DESCR shortcut reads into the CHIP's own buffer, and
    that buffer is 64 bytes.  A device whose configuration descriptor is
    longer than that overflows it and reports 17 -- and this used to end
    enumeration outright, which reads as "the device answered, then
    stopped" and blames the device for a limit of ours.

    It is not rare.  A USB-to-DVI adapter met here has one, and anything
    with several interfaces or a long class-specific block will too.

    So ask again as a real control transfer.  That is possible HERE and
    was not possible earlier: the device descriptor has already come back
    and told us Ep0Max, which is what CtrlIn needs in order to know when a
    data stage has ended.  Nine bytes is all that is wanted at this point
    -- bConfigurationValue and wTotalLength -- and callers fetch the whole
    descriptor themselves once wTotalLength has told them how long it is. }
  if St <> INT_SUCCESS then
  begin
    St := CtrlIn($80, REQ_GET_DESCR, Word(DT_CONFIG) shl 8, 0, 9,
                 CfgDesc, SizeOf(CfgDesc), GotW);
    Say('  config retried as a control transfer -> ' + StatusStr(St));
    if (St = INT_SUCCESS) and (GotW >= 4) then
      G := Byte(GotW)
    else
    begin
      BusUp := BU_NO_CONFIG;
      Exit;
    end;
  end;
  CfgLen := G;
  CfgWant := G;
  if G >= 4 then CfgWant := CfgDesc[2] or (Word(CfgDesc[3]) shl 8);

  BusUp := BU_OK;
end;

function BusUpReason(Code: Integer): ShortString;
begin
  case Code of
    BU_OK        : BusUpReason := 'ok';
    BU_NO_CHIP   : BusUpReason := 'no CH375 responds at that I/O address';
    BU_OLD_CHIP  : BusUpReason := 'CH375 revision is older than B5';
    BU_NOTHING   : BusUpReason := 'nothing is plugged into the CH375';
    BU_NO_ANSWER : BusUpReason := 'a device is attached but nothing answers';
    BU_NO_CONFIG : BusUpReason := 'the device answered, then stopped';
  else
    BusUpReason := 'unknown';
  end;
end;

procedure WhyNoAnswer;
begin
  WriteLn;
  WriteLn('The CH375 sees a device attached, and the bring-up got as far as');
  WriteLn('it can, but nothing on the USB bus answers.  In order of how often');
  WriteLn('it turns out to be the cause:');
  WriteLn;
  WriteLn(' 1. Another driver owns the chip.  CH375R9.SYS or CH375DOS.SYS in');
  WriteLn('    CONFIG.SYS resets it into disk mode; the two cannot share one');
  WriteLn('    CH375.  Check MEM /C and comment the line out.');
  WriteLn(' 2. The device is wedged.  Unplug it and plug it back in -- a chip');
  WriteLn('    reset does not cut its power, so nothing this program does');
  WriteLn('    will clear a confused device.');
  WriteLn(' 3. The cable carries power but not both data lines.  That still');
  WriteLn('    powers the pull-up, which is all an attach needs, so it looks');
  WriteLn('    exactly like this.');
end;

{ ------------------------------------------------------------------------
  Formatting
  ------------------------------------------------------------------------ }

function KeyWaiting: Boolean; assembler;
asm
  mov ah, 1
  int 16h
  mov al, 0
  jz  @none
  mov al, 1
@none:
end;

procedure EatKey; assembler;
asm
  mov ah, 0
  int 16h
end;

function Ticks: LongInt;
var P: ^LongInt;
begin
  P := Ptr($40, $6C);
  Ticks := P^;
end;

function Hex1(B: Byte): Char;
begin
  if B < 10 then Hex1 := Chr(Ord('0') + B) else Hex1 := Chr(Ord('A') + B - 10);
end;

function Hex2(B: Byte): ShortString;
begin
  Hex2 := Hex1(B shr 4) + Hex1(B and 15);
end;

function Hex4(W: Word): ShortString;
begin
  Hex4 := Hex2(Hi(W)) + Hex2(Lo(W));
end;

function Sgn(B: Byte): Integer;
begin
  if B >= $80 then Sgn := Integer(B) - 256 else Sgn := B;
end;

procedure HexDumpAt(const Buf; Ofs, Len: Word; const Indent: ShortString);
var
  P: PByte;
  I, J: Word;
  S, A: ShortString;
  C: Char;
begin
  P := @Buf;
  I := 0;
  while I < Len do
  begin
    S := Indent + Hex4(Ofs + I) + '  ';
    A := '';
    for J := 0 to 15 do
    begin
      if I + J < Len then
      begin
        S := S + Hex2(P[I + J]) + ' ';
        C := Chr(P[I + J]);
        if (P[I + J] < 32) or (P[I + J] > 126) then C := '.';
        A := A + C;
      end
      else
        S := S + '   ';
      if J = 7 then S := S + ' ';
    end;
    WriteLn(S + ' |' + A + '|');
    Inc(I, 16);
  end;
end;

procedure HexDump(const Buf; Len: Word; const Indent: ShortString);
begin
  HexDumpAt(Buf, 0, Len, Indent);
end;

{ ------------------------------------------------------------------------
  USB vocabulary.  Enough of it to read a descriptor without the spec open.
  ------------------------------------------------------------------------ }

function ClassName(C, S, P: Byte): ShortString;
begin
  case C of
    $00: ClassName := 'per-interface';
    $01: ClassName := 'audio';
    $02: ClassName := 'communications';
    $03: begin
           ClassName := 'HID';
           if S = 1 then ClassName := 'HID boot';
           case P of
             1: ClassName := ClassName + ' keyboard';
             2: ClassName := ClassName + ' mouse';
           end;
         end;
    $05: ClassName := 'physical';
    $06: ClassName := 'still imaging';
    $07: ClassName := 'printer';
    $08: begin
           ClassName := 'mass storage';
           case S of
             1: ClassName := ClassName + '/RBC';
             2: ClassName := ClassName + '/CD';
             6: ClassName := ClassName + '/SCSI';
           end;
           if P = $50 then ClassName := ClassName + ' bulk-only';
         end;
    $09: ClassName := 'hub';
    $0A: ClassName := 'CDC data';
    $0B: ClassName := 'smart card';
    $0D: ClassName := 'content security';
    $0E: ClassName := 'video';
    $0F: ClassName := 'personal healthcare';
    $10: ClassName := 'audio/video';
    $DC: ClassName := 'diagnostic';
    $E0: begin
           ClassName := 'wireless';
           if (S = 1) and (P = 1) then ClassName := 'Bluetooth';
         end;
    $EF: ClassName := 'miscellaneous';
    $FE: ClassName := 'application specific';
    $FF: ClassName := 'vendor specific';
  else
    ClassName := 'class ' + Hex2(C);
  end;
end;

function DescrTypeName(T: Byte): ShortString;
begin
  case T of
    DT_DEVICE     : DescrTypeName := 'DEVICE';
    DT_CONFIG     : DescrTypeName := 'CONFIGURATION';
    DT_STRING     : DescrTypeName := 'STRING';
    DT_INTERFACE  : DescrTypeName := 'INTERFACE';
    DT_ENDPOINT   : DescrTypeName := 'ENDPOINT';
    DT_QUALIFIER  : DescrTypeName := 'DEVICE QUALIFIER';
    DT_OTHERSPEED : DescrTypeName := 'OTHER SPEED CONFIG';
    DT_IF_POWER   : DescrTypeName := 'INTERFACE POWER';
    DT_OTG        : DescrTypeName := 'OTG';
    DT_DEBUG      : DescrTypeName := 'DEBUG';
    DT_IF_ASSOC   : DescrTypeName := 'INTERFACE ASSOCIATION';
    DT_BOS        : DescrTypeName := 'BOS';
    $24           : DescrTypeName := 'CS_INTERFACE';
    $25           : DescrTypeName := 'CS_ENDPOINT';
    DT_HID        : DescrTypeName := 'HID';
    DT_HID_REPORT : DescrTypeName := 'HID REPORT';
    DT_HID_PHYS   : DescrTypeName := 'HID PHYSICAL';
    DT_HUB        : DescrTypeName := 'HUB';
  else
    DescrTypeName := 'type ' + Hex2(T);
  end;
end;

function EpTypeName(A: Byte): ShortString;
begin
  case A and 3 of
    0: EpTypeName := 'control';
    1: EpTypeName := 'isochronous';
    2: EpTypeName := 'bulk';
    3: EpTypeName := 'interrupt';
  end;
end;

function LangName(L: Word): ShortString;
begin
  case L of
    $0409: LangName := 'English (US)';
    $0809: LangName := 'English (UK)';
    $040C: LangName := 'French';
    $0407: LangName := 'German';
    $0410: LangName := 'Italian';
    $0411: LangName := 'Japanese';
    $0412: LangName := 'Korean';
    $040A: LangName := 'Spanish';
    $0416: LangName := 'Portuguese (Brazil)';
    $0419: LangName := 'Russian';
    $0804: LangName := 'Chinese (PRC)';
    $0404: LangName := 'Chinese (Taiwan)';
  else
    LangName := 'language ' + Hex4(L);
  end;
end;

{ A short list, and deliberately so: it covers what turns up on a bench and
  nothing more.  An unknown VID prints as its number, which is no worse than
  what a full table would give for a vendor not in it. }
function VendorName(V: Word): ShortString;
begin
  case V of
    $03EB: VendorName := 'Atmel';
    $0424: VendorName := 'Microchip/SMSC';
    $0451: VendorName := 'Texas Instruments';
    $045E: VendorName := 'Microsoft';
    $046D: VendorName := 'Logitech';
    $04B3: VendorName := 'IBM';
    $04B4: VendorName := 'Cypress';
    $04CA: VendorName := 'Lite-On';
    $04D9: VendorName := 'Holtek';
    $04E8: VendorName := 'Samsung';
    $04F2: VendorName := 'Chicony';
    $04F3: VendorName := 'Elan';
    $0518: VendorName := 'EzKEY';
    $0525: VendorName := 'Netchip';
    $054C: VendorName := 'Sony';
    $056A: VendorName := 'Wacom';
    $0557: VendorName := 'ATEN';
    $057E: VendorName := 'Nintendo';
    $058F: VendorName := 'Alcor Micro';
    $05AC: VendorName := 'Apple';
    $05E3: VendorName := 'Genesys Logic';
    $062A: VendorName := 'MosArt';
    $0644: VendorName := 'TEAC';
    $066F: VendorName := 'SigmaTel';
    $06CD: VendorName := 'Keyspan / InnoSys';
    $067B: VendorName := 'Prolific';
    $0781: VendorName := 'SanDisk';
    $0787: VendorName := 'Kingston';
    $07CA: VendorName := 'AVerMedia';
    $0930: VendorName := 'Toshiba';
    $093A: VendorName := 'Pixart';
    $0951: VendorName := 'Kingston';
    $09DA: VendorName := 'A4Tech';
    $0A12: VendorName := 'Cambridge Silicon Radio';
    $0A5C: VendorName := 'Broadcom';
    $0B05: VendorName := 'ASUSTek';
    $0B95: VendorName := 'ASIX';
    $0BDA: VendorName := 'Realtek';
    $0C45: VendorName := 'Microdia';
    $0CF3: VendorName := 'Atheros';
    $0D8C: VendorName := 'C-Media';
    $1004: VendorName := 'LG';
    $1005: VendorName := 'Apacer';
    $1058: VendorName := 'Western Digital';
    $10C4: VendorName := 'Silicon Labs';
    $1131: VendorName := 'Integrated System Solution';
    $1234: VendorName := 'Brain Actuated Technologies';
    $12D1: VendorName := 'Huawei';
    $1307: VendorName := 'Transcend';
    $13FE: VendorName := 'Kingston/Phison';
    $1415: VendorName := 'Nam Tai';
    $14CD: VendorName := 'Super Top';
    $152D: VendorName := 'JMicron';
    $1532: VendorName := 'Razer';
    $1546: VendorName := 'u-blox';
    $15A9: VendorName := 'Gemtek';
    $1690: VendorName := 'Askey';
    $16C0: VendorName := 'Van Ooijen/Voti';
    $1725: VendorName := 'Vitesse';
    $174C: VendorName := 'ASMedia';
    $17EF: VendorName := 'Lenovo';
    $1A40: VendorName := 'Terminus (hub)';
    $1A86: VendorName := 'WCH (QinHeng)';
    $1B1C: VendorName := 'Corsair';
    $1BCF: VendorName := 'Sunplus';
    $1D6B: VendorName := 'Linux Foundation';
    $2109: VendorName := 'VIA Labs (hub)';
    $2717: VendorName := 'Xiaomi';
    $8087: VendorName := 'Intel';
  else
    VendorName := '';
  end;
end;

end.
