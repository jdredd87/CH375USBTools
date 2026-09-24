program chdiag;
{ CH375 host-mode diagnostic  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  What USBMOUSE.COM does at load time, but printing every step, so a failure
  says which step failed rather than just "no mouse".  It follows the order
  WCH's own examples use:

      SET_USB_MODE 5      host enabled, no SOF -- the idle state
      wait for USB_INT_CONNECT
      SET_USB_MODE 7      hold the bus in reset
      SET_USB_MODE 6      host enabled, auto SOF
      wait for USB_INT_CONNECT
      GET_DESCR 1 / SET_ADDRESS / GET_DESCR 2 / SET_CONFIG
      SET_PROTOCOL boot, SET_IDLE 0
      poll the interrupt IN endpoint

  It also dumps the chip's internal registers, which command 0Ah reads.  The
  CH375 datasheet documents 0Ah only as GET_MAX_LUN, but the vendor's own
  DOS driver and CH375CHK.C both use it as a general "read internal byte",
  and the map is the only view there is of what the chip thinks the USB bus
  is doing.  Register 07h behaves as this chip family's USB misc-status:

      bit0 device attached      bit1 D- line level (1 = low-speed device)
      bit2 suspend              bit3 bus reset
      bit4 ready                bit5 SIE free
      bit6 SOF active           bit7 SOF present

  so 31h means "attached, D- low" -- a device pulling up D+, i.e. full speed
  -- and register 1Ch reading 40h means the SOF generator really is running.

    CHDIAG [/P=260] [/N=200] [/R]

      /P=hex   I/O base, default 260
      /N=n     poll the endpoint n times once enumerated (default 200)
      /R       dump registers at each stage

  Exit codes: 0 ok, 1 no chip, 2 nothing attached, 3 enumeration failed,
              4 attached device is not a HID mouse, 5 no reports seen      }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses chtool;

const
  VER             = '1.0.0';
  CMD_GET_IC_VER  = $01;
  CMD_SET_SPEED   = $04;
  CMD_RESET_ALL   = $05;
  CMD_CHECK_EXIST = $06;
  CMD_READ_REG    = $0A;
  CMD_SET_RETRY   = $0B;
  CMD_SET_USB_ADDR= $13;
  CMD_SET_USB_MODE= $15;
  CMD_TEST_CONNECT= $16;
  CMD_SET_ENDP6   = $1C;
  CMD_GET_STATUS  = $22;
  CMD_RD_USB_DATA = $28;
  CMD_WR_USB_DATA7= $2B;
  CMD_CLR_STALL   = $41;
  CMD_SET_ADDRESS = $45;
  CMD_GET_DESCR   = $46;
  CMD_SET_CONFIG  = $49;
  CMD_ISSUE_TOKEN = $4F;

  INT_SUCCESS     = $14;
  INT_CONNECT     = $15;
  INT_DISCONNECT  = $16;

  PID_OUT         = $01;
  PID_IN          = $09;
  PID_SETUP       = $0D;

  USB_ADDR        = 2;

var
  Base, PortDat, PortCmd: Word;
  NPoll: Word;
  WantRegs: Boolean;
  Dev: array[0..63] of Byte;
  Cfg: array[0..95] of Byte;
  Rep: array[0..63] of Byte;
  DevLen, CfgLen: Byte;
  HidIf, EpNum: Integer;
  HidSub, HidProto, EpMax, EpIval, CfgVal: Byte;

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
  for I := 1 to N do for J := 1 to 700 do InB($61);
end;

function Hex1(B: Byte): Char;
begin
  if B < 10 then Hex1 := Chr(Ord('0') + B) else Hex1 := Chr(Ord('A') + B - 10);
end;

function Hex2(B: Byte): ShortString;
begin
  Hex2 := Hex1(B shr 4) + Hex1(B and 15);
end;

function Sgn(B: Byte): Integer;
begin
  if B >= $80 then Sgn := Integer(B) - 256 else Sgn := B;
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

function StName(St: Integer): ShortString;
begin
  case St of
    -1            : StName := 'no interrupt';
    INT_SUCCESS   : StName := 'success';
    INT_CONNECT   : StName := 'device connected';
    INT_DISCONNECT: StName := 'device disconnected';
    $17           : StName := 'buffer overflow';
    $18           : StName := 'usb ready';
    $20, $24, $28, $2C : StName := 'device did not answer (timeout)';
    $22           : StName := 'device returned ACK';
    $23           : StName := 'device returned DATA0';
    $2A           : StName := 'device returned NAK';
    $2B           : StName := 'device returned DATA1';
    $2E           : StName := 'device returned STALL';
  else
    StName := 'error';
  end;
end;

function StS(St: Integer): ShortString;
begin
  if St < 0 then StS := '--  ' + StName(St)
            else StS := Hex2(Byte(St)) + '  ' + StName(St);
end;

procedure Dump(const Buf; Len: Byte);
var P: PByte; I: Byte; S: ShortString;
begin
  P := @Buf; I := 0; S := '   ';
  while I < Len do
  begin
    S := S + Hex2(P[I]) + ' ';
    Inc(I);
    if (I and 15) = 0 then begin WriteLn(S); S := '   '; end;
  end;
  if Length(S) > 3 then WriteLn(S);
end;

function RdUsb(var Buf; Max: Byte): Byte;
var P: PByte; L, I: Byte;
begin
  P := @Buf;
  WrCmd(CMD_RD_USB_DATA);
  L := RdDat;
  for I := 1 to L do
    if I <= Max then P[I - 1] := RdDat else RdDat;
  RdUsb := L;
end;

function GetReg(A: Byte): Byte;
begin
  WrCmd(CMD_READ_REG); WrDat(A); GetReg := RdDat;
end;

procedure ShowBus(const Tag: ShortString);
var S, I: Byte;
begin
  S := GetReg($07);
  Write('  bus [', Tag, '] reg07=', Hex2(S),
        ' attach=', S and 1, ' Dminus=', (S shr 1) and 1,
        ' suspend=', (S shr 2) and 1, ' ready=', (S shr 4) and 1);
  WriteLn('   reg1C=', Hex2(GetReg($1C)), ' (40 = SOF running)',
          '   reg20=', Hex2(GetReg($20)));
  if WantRegs then
  begin
    for I := 0 to 63 do
    begin
      if (I and 15) = 0 then Write('   ', Hex2(I), ': ');
      Write(Hex2(GetReg(I)), ' ');
      if (I and 15) = 15 then WriteLn;
    end;
  end;
end;

procedure SetMode(M: Byte);
begin
  WrCmd(CMD_SET_USB_MODE); WrDat(M); DelayMs(20); RdDat;
end;

procedure SetRetry(V: Byte);
begin
  WrCmd(CMD_SET_RETRY); WrDat($25); WrDat(V);
end;

function WaitFor(Want: Byte; Ms: Word; const Tag: ShortString): Boolean;
var St, N: Integer;
begin
  WaitFor := False;
  for N := 1 to 12 do
  begin
    St := WaitInt(Ms);
    if St < 0 then begin WriteLn('  ', Tag, ': ', StS(St)); Exit; end;
    WriteLn('  ', Tag, ': ', StS(St));
    if St = Want then begin WaitFor := True; Exit; end;
  end;
end;

function CtrlNoData(RType, Req: Byte; Val, Idx: Word): Integer;
var R: Integer;
begin
  WrCmd(CMD_WR_USB_DATA7); WrDat(8);
  WrDat(RType); WrDat(Req);
  WrDat(Lo(Val)); WrDat(Hi(Val));
  WrDat(Lo(Idx)); WrDat(Hi(Idx));
  WrDat(0); WrDat(0);
  WrCmd(CMD_SET_ENDP6); WrDat($80);
  WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_SETUP);
  R := WaitInt(400);
  if R <> INT_SUCCESS then begin CtrlNoData := R; Exit; end;
  { The status stage carries DATA1.  Without saying so the chip reports a
    toggle mismatch, 2Bh, instead of success -- harmless here but it makes
    the diagnostic look like it failed when it did not. }
  WrCmd(CMD_SET_ENDP6); WrDat($C0);
  WrCmd(CMD_ISSUE_TOKEN); WrDat(PID_IN);
  CtrlNoData := WaitInt(400);
end;

procedure ParseConfig;
var P, L, T: Byte; InHid: Boolean;
begin
  HidIf := -1; EpNum := -1; EpMax := 0; EpIval := 0; HidSub := 0; HidProto := 0;
  CfgVal := 1;
  if CfgLen >= 6 then CfgVal := Cfg[5];
  InHid := False;
  P := 0;
  while P + 2 <= CfgLen do
  begin
    L := Cfg[P]; T := Cfg[P + 1];
    if L < 2 then Break;
    if (T = 4) and (P + 9 <= CfgLen) then
    begin
      InHid := Cfg[P + 5] = 3;
      if InHid and (HidIf < 0) then
      begin
        HidIf := Cfg[P + 2]; HidSub := Cfg[P + 6]; HidProto := Cfg[P + 7];
      end;
    end
    else if (T = 5) and (P + 7 <= CfgLen) then
    begin
      if InHid and (EpNum < 0) and ((Cfg[P + 2] and $80) <> 0)
         and ((Cfg[P + 3] and 3) = 3) then
      begin
        EpNum := Cfg[P + 2] and $0F; EpMax := Cfg[P + 4]; EpIval := Cfg[P + 6];
      end;
    end;
    Inc(P, L);
  end;
end;

var
  I, St, Code: Integer;
  A: ShortString;
  V: LongInt;
  B, Tog, L, Btn, LastBtn: Byte;
  NGot, NNak, NErr, Shown: Word;
  MX, MY: LongInt;

procedure Usage;
begin
  Banner('CHDIAG', VER, 'CH375 host-mode diagnostic');
  WriteLn;
  WriteLn('  CHDIAG [/P=260] [/N=count] [/R]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /N=dec   polls of the interrupt endpoint, default 200');
  WriteLn('  /R       dump the chip register map at each step');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('The same bring-up USBMOUSE.COM does, printing every command,');
  WriteLn('status and chip register on the way through, and nothing goes');
  WriteLn('resident.  It stops at "this is not a mouse" -- which is the');
  WriteLn('right thing for a mouse diagnostic and a useless one for');
  WriteLn('finding out what an unknown dongle is.  USBINFO, in');
  WriteLn('CH375USBTOOLS, does not care what class the device is.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Base := DEF_BASE; NPoll := 200; WantRegs := False;
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/R') or (A = '-R') then WantRegs := True
    else if Copy(A, 1, 3) = '/P=' then
    begin
      Val('$' + Copy(A, 4, 4), V, Code);
      if Code = 0 then Base := Word(V);
    end
    else if Copy(A, 1, 3) = '/N=' then
    begin
      Val(Copy(A, 4, 5), V, Code);
      if Code = 0 then NPoll := Word(V);
    end;
  end;
  PortDat := Base; PortCmd := Base + 1;

  Banner('CHDIAG', VER, 'CH375 host-mode diagnostic');
  WriteLn('I/O base ', Hex2(Hi(Base)) + Hex2(Lo(Base)), 'h  ',
          '(data ', Hex2(Hi(PortDat)) + Hex2(Lo(PortDat)),
          ', command ', Hex2(Hi(PortCmd)) + Hex2(Lo(PortCmd)), ')');

  WrCmd(CMD_CHECK_EXIST); WrDat($55); B := RdDat;
  WriteLn('CHECK_EXIST 55 -> ', Hex2(B), '   (want AA)');
  if B <> $AA then
  begin
    WriteLn('No CH375 at this address.');
    Halt(1);
  end;
  WrCmd(CMD_RESET_ALL); DelayMs(60);
  WrCmd(CMD_GET_IC_VER); B := RdDat;
  WriteLn('IC version ', Hex2(B));
  if (B < $B5) or (B >= $C0) then
    WriteLn('  note: USBMOUSE requires B5 or later for the command-port',
            ' ready flag');

  { ---- idle host mode ---- }
  SetMode(5);
  if not WaitFor(INT_CONNECT, 300, 'mode 5') then
  begin
    WrCmd(CMD_TEST_CONNECT); B := RdDat;
    WriteLn('  TEST_CONNECT -> ', StS(B));
    if B <> INT_CONNECT then
    begin
      WriteLn('Nothing is plugged into the CH375.');
      Halt(2);
    end;
  end;
  ShowBus('mode 5');

  { ---- bus reset, then the second connect ---- }
  SetMode(7);
  DelayMs(20);
  ShowBus('reset held');
  SetMode(6);
  if not WaitFor(INT_CONNECT, 400, 'after reset') then
    WriteLn('  (no second connect; carrying on)');
  DelayMs(100);
  ShowBus('mode 6');
  SetRetry($8F);

  { ---- drop the bus to 1.5 Mbps if the device is a low-speed one ----
    Command 0Ah sub-address 07h is GET_DEV_RATE: bit 4 set means 1.5 Mbps.
    Command 04h is SET_USB_SPEED, data 02h = low speed.  Neither is in the
    CH375 part-I datasheet -- both are documented for the CH376 -- but this
    B7 firmware implements them.

    WHERE this goes is the whole trick.  SET_USB_MODE puts the bus back to
    12 Mbps, so the speed has to be set after the last mode change; but
    issuing it immediately after SET_USB_MODE 6 is silently ignored, and
    that is what made this look for a long time like the chip had no
    low-speed support at all.  It only takes once the connect interrupt
    raised by the bus reset has been read and cleared. }
  B := GetReg($07);
  Write('device rate: reg07=', Hex2(B), ' bit4=', (B shr 4) and 1, '  ');
  if (B and $10) <> 0 then
  begin
    WriteLn('LOW SPEED (1.5 Mbps)');
    WrCmd(CMD_SET_SPEED); WrDat(2);
    DelayMs(20);
    WriteLn('  SET_USB_SPEED 2 issued; reg17 now ', Hex2(GetReg($17)));
  end
  else
    WriteLn('full speed (12 Mbps)');

  { ---- device descriptor ---- }
  St := 0;
  for I := 1 to 6 do
  begin
    WrCmd(CMD_GET_DESCR); WrDat(1);
    St := WaitInt(600);
    WriteLn('GET_DESCR device, try ', I, ' -> ', StS(St));
    if St = INT_SUCCESS then Break;
    if St = INT_DISCONNECT then
    begin
      WriteLn('The device went away.');
      Halt(2);
    end;
    DelayMs(150);
  end;
  if St <> INT_SUCCESS then
  begin
    WriteLn;
    WriteLn('The CH375 sees a device attached, and the bring-up above got as');
    WriteLn('far as it can, but nothing on the USB bus answers.  In order of');
    WriteLn('how often it turns out to be the cause:');
    WriteLn;
    WriteLn(' 1. Another driver owns the chip.  CH375R9.SYS or CH375DOS.SYS');
    WriteLn('    in CONFIG.SYS resets it into disk mode; the two cannot');
    WriteLn('    share one CH375.  Check MEM /C and comment the line out.');
    WriteLn(' 2. The device is wedged.  Unplug it and plug it back in --');
    WriteLn('    a chip reset does not cut its power, so nothing this');
    WriteLn('    program does will clear a confused device.');
    WriteLn(' 3. The cable carries power but not both data lines.  That');
    WriteLn('    still powers the pull-up, which is all an attach needs,');
    WriteLn('    so it looks exactly like this.');
    WriteLn;
    WriteLn('It is not the bring-up sequence: the chip''s own AUTO_SETUP and');
    WriteLn('DISK_INIT fail the same way when this happens.');
    Halt(3);
  end;

  DevLen := RdUsb(Dev, SizeOf(Dev));
  WriteLn('device descriptor, ', DevLen, ' bytes');
  Dump(Dev, DevLen);
  if DevLen >= 12 then
    WriteLn('  VID ', Hex2(Dev[9]) + Hex2(Dev[8]),
            '  PID ', Hex2(Dev[11]) + Hex2(Dev[10]),
            '  ep0 max packet ', Dev[7]);

  { ---- address ---- }
  WrCmd(CMD_SET_ADDRESS); WrDat(USB_ADDR);
  St := WaitInt(600);
  WriteLn('SET_ADDRESS ', USB_ADDR, ' -> ', StS(St));
  if St <> INT_SUCCESS then Halt(3);
  WrCmd(CMD_SET_USB_ADDR); WrDat(USB_ADDR);
  DelayMs(20);

  { ---- configuration ---- }
  WrCmd(CMD_GET_DESCR); WrDat(2);
  St := WaitInt(600);
  WriteLn('GET_DESCR config -> ', StS(St));
  if St <> INT_SUCCESS then Halt(3);
  CfgLen := RdUsb(Cfg, SizeOf(Cfg));
  WriteLn('configuration descriptor, ', CfgLen, ' bytes');
  Dump(Cfg, CfgLen);

  ParseConfig;
  WriteLn('configuration value ', CfgVal);
  if HidIf < 0 then
  begin
    WriteLn('No HID interface here -- this is not a mouse.');
    Halt(4);
  end;
  WriteLn('HID interface ', HidIf, ', subclass ', HidSub,
          ' (1 = boot), protocol ', HidProto, ' (2 = mouse)');
  if EpNum < 0 then
  begin
    WriteLn('The HID interface has no interrupt IN endpoint.');
    Halt(4);
  end;
  WriteLn('interrupt IN endpoint ', EpNum, ', max packet ', EpMax,
          ', interval ', EpIval, ' ms');

  WrCmd(CMD_SET_CONFIG); WrDat(CfgVal);
  St := WaitInt(600);
  WriteLn('SET_CONFIGURATION -> ', StS(St));
  if St <> INT_SUCCESS then Halt(3);
  DelayMs(50);

  WriteLn('SET_PROTOCOL boot -> ', StS(CtrlNoData($21, $0B, 0, Word(HidIf))));
  WriteLn('SET_IDLE 0        -> ', StS(CtrlNoData($21, $0A, 0, Word(HidIf))));

  { ---- poll ---- }
  SetRetry($00);                { no retry: a NAK must return immediately }
  WriteLn;
  WriteLn('polling endpoint ', EpNum, ', ', NPoll, ' times');
  Tog := $80; NGot := 0; NNak := 0; NErr := 0; Shown := 0;
  MX := 0; MY := 0; LastBtn := 0;
  for I := 1 to NPoll do
  begin
    WrCmd(CMD_SET_ENDP6); WrDat(Tog);
    WrCmd(CMD_ISSUE_TOKEN); WrDat((Byte(EpNum) shl 4) or PID_IN);
    St := WaitInt(60);
    if St = INT_SUCCESS then
    begin
      L := RdUsb(Rep, SizeOf(Rep));
      Tog := Tog xor $40;
      Inc(NGot);
      if L >= 3 then
      begin
        Btn := Rep[0] and 7;
        MX := MX + Sgn(Rep[1]);
        MY := MY + Sgn(Rep[2]);
        if ((Rep[1] <> 0) or (Rep[2] <> 0) or (Btn <> LastBtn))
           and (Shown < 30) then
        begin
          Inc(Shown);
          WriteLn('  ', Hex2(Rep[0]), ' ', Hex2(Rep[1]), ' ', Hex2(Rep[2]),
                  '   dx=', Sgn(Rep[1]), ' dy=', Sgn(Rep[2]), ' btn=', Btn,
                  '   x=', MX, ' y=', MY);
        end;
        LastBtn := Btn;
      end;
    end
    else if St = $2A then Inc(NNak)
    else
    begin
      Inc(NErr);
      if NErr <= 5 then WriteLn('  poll -> ', StS(St));
      if St = $2E then
      begin
        WrCmd(CMD_CLR_STALL); WrDat(Byte(EpNum) or $80);
        WaitInt(200);
        Tog := $80;
      end;
    end;
    DelayMs(8);
  end;

  WriteLn;
  WriteLn('reports ', NGot, ', NAK ', NNak, ', errors ', NErr);
  WriteLn('accumulated movement x=', MX, ' y=', MY);
  if NGot = 0 then
  begin
    WriteLn('The endpoint never returned data.');
    Halt(5);
  end;
  WriteLn('OK: the mouse is talking.  USBMOUSE should work.');
  Halt(0);
end.
