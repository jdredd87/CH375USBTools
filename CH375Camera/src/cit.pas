unit cit;
{ CIT -- the Xirlink C-It camera chip behind the IBM PC Camera, over a CH375.
  CH375Camera, StevenC & Claude.  Public domain (the Unlicense).

  Everything the camera tools share: finding the camera, poking its
  registers, and the start and stop sequences.  The register sequences are
  taken from Linux's gspca xirlink_cit.c (itself from the older ibmcam
  driver), which learned them by watching the Windows driver on a bus
  analyser.  ref\xirlink_cit.c is a copy of it.  Nobody has a datasheet;
  where a comment below says what a register does, that is Linux's guess,
  and it is repeated here only so the two can be compared.

  WHICH CAMERA.  0545:8080 covers four different chips, told apart by
  bcdDevice.  Only model 2 (bcdDevice 030A) has been in front of this code,
  so only model 2 is started.  The others are recognised and refused by
  name rather than driven with the wrong sequence.

  REGISTER ACCESS is two vendor requests on endpoint 0, and nothing else:

      write   42 00 <value> <index> 0000      no data stage
      read    C2 01 0000    <index> 0008      8 bytes back, byte 0 is it

  Both are ordinary control transfers, which a CH375 does perfectly well.
  The recipient is ENDPOINT, not device -- that is what the camera wants,
  and it is copied rather than understood.

  MODEL 2 FORMATS, from Linux's model2_mode table:

      176x144   YUV 4:2:0, "YYVYUY"   38016 bytes a frame
      320x240   raw Bayer, GRBG, 8 bit 76800 bytes a frame
      352x288   raw Bayer, GRBG, 8 bit 101376 bytes a frame

  Frames begin with 00 FF.  The start-of-frame header is 2 bytes long at
  320 and 352, and Linux says 10 at 176 with a note that it does not look
  right.

  THE TWO REGISTERS THAT MAKE THIS POSSIBLE AT ALL.  The camera's streaming
  endpoint is isochronous with a 1022-byte packet, and the CH375 cannot
  hold more than 64 bytes of anything.  But the camera's own maximum packet
  size is a register pair, 0106/0107, and so is its frame rate, 0 to 31 on
  sensor register 1C with 0 the slowest.  Linux uses the first to squeeze
  the stream into less USB bandwidth.  Here it is used to squeeze it into
  the chip. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

const
  CIT_VID    = $0545;
  CIT_PID    = $8080;

  CIT_MODEL2 = $030A;          { bcdDevice }

  STREAM_IF  = 0;              { interface 0 carries the video }
  STREAM_EP  = 1;              { EP 81, isochronous IN }

var
  { Every register write that did not come back success, counted.  The
    camera answers nothing about whether a write MEANT anything, so a
    transfer failure is the only failure there is to see. }
  RegFails:  Word = 0;
  LastFail:  Integer = 0;
  Verbose:   Boolean = False;  { print every register write }
  Brightness: Byte = 32;       { 0..63, Linux's default 32 }
  Hue:        Byte = 63;       { 0..127, Linux's default 63 }

{ Bus up, SET_CONFIGURATION 1, and check that this is a camera we know.
  Returns 0 on success, otherwise a code <= 20 suitable for Halt, having
  already printed why. }
function CamUp: Integer;

function RegW(Val, Idx: Word): Integer;
function RegR(Idx: Word; var V: Byte): Integer;

{ Model 2's sensor goes through a small mailbox: five register writes to
  set one sensor value. }
procedure M2Packet1(V1, V2: Word);

{ SET_INTERFACE on the streaming interface.  Alt 1 is the only setting
  with a non-zero packet size. }
function SetAlt(Alt: Byte): Integer;

{ The whole model 2 start sequence for one frame size, at a frame rate of
  ClockDiv (0 slowest .. 31), with the camera's maximum isochronous packet
  set to PktSize.  Leaves the camera configured but NOT streaming. }
procedure M2Start(Width: Word; ClockDiv: Byte; PktSize: Word);

{ Start and stop the stream itself: register 010C. }
procedure StreamGo;
procedure StreamStop;

{ Linux's stop0 for model 2: sensor idle and the LED off. }
procedure M2Off;

procedure LedOn;
procedure LedOff;

{ Bytes in one frame at a given width, 0 if the width is not a model 2
  size. }
function FrameBytes(Width: Word): LongInt;

{ One IN token at the video endpoint.  Returns the length, or -1 if the
  chip reported anything but success.  camgrab.Pkt is the fast one, and
  what everything that takes pictures uses; this is for Drain. }
function VidPacket(var Buf): Integer;

{ Read and discard N packets: lets auto-exposure settle after a start, and
  drains the FIFO. }
procedure Drain(N: Word);

{ RD_USB_DATA with the payload read in a tight IN/STOSB loop and no port
  61h settling reads between bytes -- the arrangement CH375Net's packet
  driver uses in its receive path, for the same reason.  ch375.ReadUsb
  costs about 120 us a byte on this machine, which made reading a 64-byte
  packet take 7.6 ms against 0.8 ms for the USB transaction itself.  The
  loop alone is about 5 us between reads at 8 MHz, already longer than the
  chip needs.

  Returns the length the chip claimed.  Over 64 means the chip is not
  driving the bus (every read is FF); the bytes are drained and none
  stored. }
function FastRead(var Buf): Byte;

implementation

uses ch375;

{ WARM ATTACH.  After this camera has streamed, a USB bus reset kills it:
  it stays attached, draws power, and never answers another transaction
  until its power is cut.  Measured, not guessed -- CAMPROBE /E reads a
  register successfully straight after stopping, then bus-resets, and the
  enumeration that follows gets nothing.  With no stop sequence at all the
  result is the same, so it is the reset and not anything sent before it.

  So the first thing tried is to reset only the CH375, put it back in host
  mode WITHOUT driving a reset onto the bus, and talk to the camera at the
  address and configuration the last run left it with.  A camera fresh from
  power-up is still at address 0 and will not answer there; that falls
  through to the full enumeration, which is safe on a camera that has never
  streamed. }
function WarmUp: Boolean;
var
  I: Integer;
  Got: Word;
  R: Integer;
begin
  WarmUp := False;
  if not ChipHere(Base) then Exit;
  ChipReset;
  if (IcVer < $B5) or (IcVer >= $C0) then Exit;
  SetMode(6);
  for I := 1 to 4 do if WaitInt(50) < 0 then Break;   { drain connects }
  DelayMs(50);
  SetRetry($8F);
  WrCmd($13); WrDat(USB_ADDR);          { SET_USB_ADDR: host side only }
  DelayMs(20);
  Ep0Max := 8;
  R := CtrlIn($80, REQ_GET_DESCR, Word(DT_DEVICE) shl 8, 0, 18,
              DevDesc, 18, Got);
  if (R <> INT_SUCCESS) or (Got < 14) then Exit;
  DevLen := Got;
  WarmUp := True;
end;

const
  RT_VEN_OUT = $42;            { host->device, vendor, endpoint }
  RT_VEN_IN  = $C2;            { device->host, vendor, endpoint }
  RT_SET_IF  = $01;            { host->device, standard, interface }

function CamUp: Integer;
var
  R: Integer;
  Vid, Pid, Bcd: Word;
begin
  R := BU_OK;
  if WarmUp then
    WriteLn('attach : warm -- camera still configured from an earlier run')
  else
  begin
    R := BusUp;
    WriteLn('attach : cold -- bus reset and full enumeration');
  end;
  if R <> BU_OK then
  begin
    WriteLn('bus    : ', BusUpReason(R));
    if R = BU_NO_ANSWER then WhyNoAnswer;
    CamUp := R;
    Exit;
  end;

  Vid := DevDesc[8]  or (Word(DevDesc[9])  shl 8);
  Pid := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  Bcd := DevDesc[12] or (Word(DevDesc[13]) shl 8);
  WriteLn('device : ', Hex4(Vid), ':', Hex4(Pid), '  bcdDevice ', Hex4(Bcd));

  if (Vid <> CIT_VID) or (Pid <> CIT_PID) then
  begin
    WriteLn('         not an IBM PC Camera (0545:8080)');
    CamUp := 6;
    Exit;
  end;

  case Bcd of
    $0001: WriteLn('model  : 0 (Xirlink XVP-500) -- not supported here');
    $0002: WriteLn('model  : 1 -- not supported here');
    $030A: WriteLn('model  : 2  (IBM PC Camera, Xirlink C-It)');
    $0301: WriteLn('model  : 3 -- not supported here');
  else
    WriteLn('model  : unknown bcdDevice -- not supported here');
  end;
  if Bcd <> CIT_MODEL2 then begin CamUp := 7; Exit; end;

  R := SetConfig(1);
  if R <> INT_SUCCESS then
  begin
    WriteLn('SET_CONFIGURATION 1 -> ', StatusStr(R));
    CamUp := 8;
    Exit;
  end;
  CamUp := 0;
end;

function RegW(Val, Idx: Word): Integer;
var R: Integer;
begin
  R := CtrlNoData(RT_VEN_OUT, $00, Val, Idx);
  if R <> INT_SUCCESS then
  begin
    Inc(RegFails);
    LastFail := R;
  end;
  if Verbose then
    WriteLn('  W ', Hex4(Idx), ' <- ', Hex4(Val), '   ', StatusStr(R));
  RegW := R;
end;

function RegR(Idx: Word; var V: Byte): Integer;
var
  B: array[0..7] of Byte;
  Got: Word;
  R: Integer;
begin
  FillChar(B, SizeOf(B), 0);
  R := CtrlIn(RT_VEN_IN, $01, 0, Idx, 8, B, SizeOf(B), Got);
  V := B[0];
  if Verbose then
    WriteLn('  R ', Hex4(Idx), ' -> ', Hex2(V), '   (', Got, ' bytes) ',
            StatusStr(R));
  RegR := R;
end;

procedure M2Packet2;
begin
  RegW($00FF, $012D);
  RegW($FEA3, $0124);
end;

procedure M2Packet1(V1, V2: Word);
begin
  RegW($00AA, $012D);
  RegW($00FF, $012E);
  RegW(V1,    $012F);
  RegW($00FF, $0130);
  RegW($C719, $0124);
  RegW(V2,    $0127);
  M2Packet2;
end;

function SetAlt(Alt: Byte): Integer;
begin
  SetAlt := CtrlNoData(RT_SET_IF, REQ_SET_IFACE, Alt, STREAM_IF);
end;

procedure LedOn;  begin RegW($0000, $0100); end;
procedure LedOff; begin RegW($0080, $0100); end;

procedure M2Start(Width: Word; ClockDiv: Byte; PktSize: Word);
var V: Byte;
  Br: Word;
begin
  LedOn;
  RegR($0116, V);
  RegW($0060, $0116);
  RegW($0002, $0112);
  RegW($00BC, $012C);
  RegW($0008, $012B);
  RegW($0000, $0108);
  RegW($0001, $0133);
  RegW($0001, $0102);
  case Width of
    176: begin
           RegW($002C, $0103);
           RegW($0000, $0104);
           RegW($0024, $0105);
           RegW($00B9, $010A);
           RegW($0038, $0119);
         end;
    320: begin
           RegW($0028, $0103);
           RegW($0000, $0104);
           RegW($001E, $0105);
           RegW($0039, $010A);
           RegW($0070, $0119);
         end;
  else   { 352 }
         begin
           RegW($002C, $0103);
           RegW($0000, $0104);
           RegW($0024, $0105);
           RegW($0039, $010A);
           RegW($0070, $0119);
         end;
  end;

  LedOn;

  if Width = 176 then
  begin
    RegW($0050, $0111);
    RegW($00D0, $0111);
  end
  else
  begin
    RegW($0040, $0111);
    RegW($00C0, $0111);
  end;
  RegW($009B, $010F);
  RegW($00BB, $010F);

  { sensor hardware settings -- "not user controls", says Linux }
  M2Packet1($000A, $005C);
  M2Packet1($0004, $0000);
  M2Packet1($0006, $00FB);
  M2Packet1($0008, $0000);
  M2Packet1($000C, $0009);
  M2Packet1($0012, $000A);
  M2Packet1($002A, $0000);
  M2Packet1($002C, $0000);
  M2Packet1($002E, $0008);
  M2Packet1($0030, $0000);

  case Width of
    176: begin
           M2Packet1($0014, $0002);
           M2Packet1($0016, $0002);
           M2Packet1($0018, $004A);
         end;
    320: begin
           M2Packet1($0014, $0009);
           M2Packet1($0016, $0005);
           M2Packet1($0018, $0044);
         end;
  else   begin
           M2Packet1($0014, $0003);
           M2Packet1($0016, $0002);
           M2Packet1($0018, $004A);
         end;
  end;

  { frame rate: 0 is the slowest the sensor will go }
  M2Packet1($001C, ClockDiv);

  case Width of
    176: M2Packet1($0026, $00C2);
    320: M2Packet1($0026, $0044);
  else   M2Packet1($0026, $0048);
  end;

  M2Packet1($0028, $0001);     { lighting: Linux's default of 1 }
  M2Packet1($001E, $002F);     { colour balance rg2 }
  M2Packet1($0020, $0034);     { saturation }
  M2Packet1($0022, $00A0);     { colour balance yb }
  M2Packet1($0030, $0004);     { "hardware control command" }

  { The user controls.  Linux applies these from its control handler as
    the stream starts, so they are not in its start sequence -- and
    leaving them out gives a picture near black.  Brightness 0..63 maps to
    sensor values 60..EE; hue goes straight through. }
  Br := $60 + LongInt(Brightness) * 2254 div 1000;
  M2Packet1($001A, Br);
  M2Packet1($0024, Hue);

  { the camera's own maximum isochronous packet }
  RegW(Hi(PktSize), $0106);
  RegW(Lo(PktSize), $0107);
end;

procedure StreamGo;
begin
  RegW($00C0, $010C);
end;

procedure StreamStop;
begin
  RegW($0000, $010C);
end;

procedure M2Off;
begin
  M2Packet1($0030, $0004);
  RegW($0080, $0100);          { LED off }
  RegW($0020, $0111);
  RegW($00A0, $0111);
  M2Packet1($0030, $0002);
  RegW($0020, $0111);
  RegW($0000, $0112);
end;

function FrameBytes(Width: Word): LongInt;
begin
  case Width of
    176: FrameBytes := 176 * 144 * 3 div 2;
    320: FrameBytes := LongInt(320) * 240;
    352: FrameBytes := LongInt(352) * 288;
  else
    FrameBytes := 0;
  end;
end;

function FastRead(var Buf): Byte;
var
  L, I: Byte;
  P: Pointer;
  Dat: Word;
begin
  WrCmd(CMD_RD_USB_DATA);
  L := RdDat;
  FastRead := L;
  if L > 64 then
  begin
    for I := 1 to L do RdDat;
    Exit;
  end;
  if L = 0 then Exit;
  P := @Buf;
  Dat := PortDat;
  asm
    push es
    push di
    les  di, P
    mov  dx, Dat
    mov  cl, L
    xor  ch, ch
    cld
  @lp:
    in   al, dx
    stosb
    loop @lp
    pop  di
    pop  es
  end;
end;

function VidPacket(var Buf): Integer;
var R: Integer;
begin
  WrCmd(CMD_SET_ENDP6); WrDat($80);            { isochronous is DATA0 }
  WrCmd(CMD_ISSUE_TOKEN); WrDat((STREAM_EP shl 4) or PID_IN);
  R := WaitInt(60);
  if R <> INT_SUCCESS then begin VidPacket := -1; Exit; end;
  VidPacket := FastRead(Buf);
end;

procedure Drain(N: Word);
var
  Buf: array[0..63] of Byte;
  I: Word;
begin
  for I := 1 to N do VidPacket(Buf);
end;



end.
