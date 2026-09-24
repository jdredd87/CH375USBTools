unit pmcard;
{ PMCARD -- talking to a PicoMEM card from real-mode DOS.
  PicoMEM tools, StevenC & Claude.  Public domain (the Unlicense).

  ONE unit for both cards.  It began as two -- a PicoMEM 2 project and
  a PicoMEM 1 one -- and they were merged once every tool had been run
  on both cards unchanged.  The split had stopped describing anything
  real and the "1" in the old names was, by then, a claim about
  compatibility that was not true.

  Two things the older card forced, which the first version did not do:

  * THE PARAMETER AREA MOVED.  Text answers land in a 2 KB area in the
    card's shared memory, and where it starts depends on the FIRMWARE,
    not the board: the PicoMEM 2's BIOS of 2026-06-16 puts it at +886,
    the PicoMEM 1 read here (BIOS of 2025-11-02) at +374, because the
    configuration block between them grew from 256 to 768 bytes.  Every
    first version of these tools assumed 886, so on a card with the
    older BIOS it read a count byte the firmware had never written and
    reported "USB: 0 line(s)" whatever was plugged in -- a successful
    command, a healthy status, and a wrong conclusion.  FindParam below
    finds the area instead of assuming it, and both offsets are
    confirmed on hardware.
  * ONE MORE COMMAND is allowed: 05h, which returns the type of memory
    the card has mapped over a 16 KB block.  Its handler reads a table
    and returns; it writes nothing, mounts nothing and touches no file.

  Everything else is as pmcard.pas, and for the same reasons:

  FINDING IT.  The card's BIOS answers INT 13h with AH=60h, AL=0,
  DX=1234h by returning DX=AA55h, AX = the I/O base, BX = the segment
  of its ROM, CX = a device mask.  Without its BIOS the base defaults
  to 2A0h.  base+3 is a test port: every read returns one more than the
  last, which no other card does.

  THE BOOT DISK GOES THROUGH THIS SAME PORT.  This machine boots from a
  disk image on the card's SD card, and every sector DOS reads is a
  command on base+0.  A command left stuck is a disk that no longer
  answers.  So only the commands in the whitelist below can be sent at
  all -- refused in the one routine that writes base+0, not by
  convention -- every wait has a deadline, an error is cleared the way
  the card's own BIOS does, and nothing here calls DOS while a command
  is in flight, because a WriteLn to a redirected stdout IS a disk
  write.  Callers copy the answer out first and print afterwards.

  Written from reading the card's published firmware and BIOS sources
  (github.com/FreddyVRetro/ISA-PicoMEM, GPLv2); no code is taken from
  them. }

{$MODE OBJFPC}{$H-}

interface

const
  { status values at base+0 }
  ST_READY    = $00;
  ST_BUSY     = $01;
  ST_ERROR    = $02;
  ST_NOCMD    = $03;
  ST_INIT     = $04;
  ST_WAITCOM  = $05;

  { the only commands this unit will send }
  CMD_RESET      = $00;   { clears an error; the card BIOS does the same }
  CMD_MEMTYPE    = $05;   { what is mapped over a 16 KB block -- read-only }
  CMD_WIFI_INFO  = $60;   { WiFi state -- may RETRY the connection }
  CMD_USB_STATUS = $61;   { USB device list, as text }
  CMD_DISK_STAT  = $62;   { mounted images, as text -- reads config only }

  { The only two that are NOT queries.  Their handlers are three lines
    each -- set a boolean, clear the result, return ready -- and that is
    the whole reason they are here: they write no file, mount nothing,
    move no memory and save no configuration, so neither can reach the
    SD card this machine boots from.  Enabling makes the card copy an X
    delta, a Y delta and a button mask into its IRQ variables on every
    mouse movement, and raise its multiplexed interrupt; disabling stops
    it.  PMMTEST sends the disable on every exit path.  Do not add a
    third without reading its handler the same way. }
  CMD_MOUSE_ON   = $52;
  CMD_MOUSE_OFF  = $53;

  { Keyboard reporting on and off, the same three-line shape.  Allowed
    so that PMWATCH can demonstrate the negative WITH the switch turned
    on rather than argue it from reading alone: in the published
    firmware nothing ever reads the flag this sets, and
    IRQ_R_KEYBOARD -- the interrupt source reserved for keystrokes -- is
    defined in a header and raised nowhere.  Compare IRQ_R_MOUSE, which
    is raised and does work. }
  CMD_KEYB_ONOFF = $54;

  SHARED_OFS = $4000;     { shared memory = ROM segment + 16 KB }
  SHARED_LEN = 8192;
  CFG_OFS    = 82;        { the configuration block }
  PARAM_2026 = 886;       { where a PicoMEM 2 of 2026-06-16 puts answers }
  PARAM_2025 = 374;       { where the PicoMEM 1 of 2025-11-02 puts them }

  { how a command ended }
  CR_OK       = 0;
  CR_REFUSED  = 1;        { not on the whitelist; nothing was sent }
  CR_NOTREADY = 2;        { the card was not ready to take it }
  CR_TIMEOUT  = 3;        { no answer within the deadline }
  CR_ERROR    = 4;        { status 02 }
  CR_NOCMD    = 5;        { status 03: this firmware has no such command }
  CR_ODD      = 6;        { some other status }

  { memory types the card reports for a block (05h, and the config map) }
  MT_NULL  = 0;   MT_RAM   = 1;   MT_DISK  = 2;
  MT_BIOS  = 8;   MT_ROM0  = 9;   MT_ROM1  = 10;  MT_BIOSX = 12;
  MT_PSRAM = 16;  MT_EMS   = 17;
  { the CONFIGURED map uses three more codes for what the PC itself has }
  MT_SRAM  = 32;  MT_SVID  = 33;  MT_SROM  = 34;

var
  PmBase    : Word;       { I/O base }
  PmRomSeg  : Word;       { segment of the card ROM; 0 if its BIOS was silent }
  PmMask    : Word;       { device mask the BIOS returned }
  PmBiosHit : Boolean;    { INT 13h AH=60h answered }
  PmLastSt  : Byte;       { last status read }
  PmParam   : Word;       { parameter area, once found; 0 if not }
  PmParamN  : Byte;       { how many candidate areas the search saw }

function InB(P: Word): Byte;
procedure OutB(P: Word; V: Byte);
function Ticks: LongInt;

function AskBios: Boolean;
function TestPort(Base: Word; N: Word): Word;   { mismatches in N reads }
function Status: Byte;
function WaitReady(TickLimit: Word): Byte;      { returns the last status }
function Command(Cmd: Byte; Arg: Word; TickLimit: Word; out Res: Word): Byte;
function CmdName(Cmd: Byte): string;
function StatusName(S: Byte): string;
function ResultName(R: Byte): string;
function MemTypeName(T: Byte): string;
function MemTypeChar(T: Byte): Char;

function SharedB(Ofs: Word): Byte;
function SharedW(Ofs: Word): Word;
function SharedOK: Boolean;
function CfgB(Ofs: Word): Byte;
function CfgW(Ofs: Word): Word;
function CfgName(Ofs: Word): string;            { the 14 chars of an image name }

function FindParam: Boolean;                    { sends 62h, then searches }
procedure CopyParam(var Buf; Len: Word);        { the parameter area, raw }
function ParamLine(var Buf; Len: Word; N: Byte; out S: string): Boolean;

function Hex2(B: Byte): string;
function Hex4(W: Word): string;

implementation

uses Dos;

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

function Ticks: LongInt;
begin
  Ticks := MemL[$0040 : $006C];
end;

function GetFlags: Word; assembler;
asm
  pushf
  pop ax
end;

{ FPC's Intr LOADS Registers.Flags into the CPU before the INT, and the
  card's handler returns with IRET -- so a record cleared with FillChar
  makes the call with interrupts OFF, and they stay off afterwards.  The
  BIOS tick then stops and anything waiting on it waits for ever.  That
  wedged these tools three times before it was understood. }
function AskBios: Boolean;
var R: Registers; F: Word;
begin
  F := GetFlags;
  FillChar(R, SizeOf(R), 0);
  R.Flags := F;
  R.AH := $60; R.AL := 0; R.DX := $1234;
  Intr($13, R);
  if F and $0200 <> 0 then asm sti end;
  PmBiosHit := R.DX = $AA55;
  if PmBiosHit then begin
    PmBase := R.AX; PmRomSeg := R.BX; PmMask := R.CX;
  end;
  AskBios := PmBiosHit;
end;

function TestPort(Base: Word; N: Word): Word;
var Prev, Cur: Byte; I, Bad: Word;
begin
  Bad := 0;
  Prev := InB(Base + 3);
  for I := 1 to N do begin
    Cur := InB(Base + 3);
    if Cur <> Byte(Prev + 1) then Inc(Bad);
    Prev := Cur;
  end;
  TestPort := Bad;
end;

function Status: Byte;
begin
  PmLastSt := InB(PmBase);
  Status := PmLastSt;
end;

function WaitReady(TickLimit: Word): Byte;
var T0: LongInt; S: Byte;
begin
  T0 := Ticks;
  repeat
    S := Status;
    { FF: the firmware notes the status can read FFh while it is busy
      on the SD card -- so it counts as busy until the deadline }
    if (S <> ST_BUSY) and (S <> $FF) then Break;
  until (Ticks - T0 > TickLimit) or (Ticks < T0);
  WaitReady := S;
end;

function Allowed(Cmd: Byte): Boolean;
begin
  case Cmd of
    CMD_RESET, CMD_MEMTYPE, CMD_WIFI_INFO,
    CMD_USB_STATUS, CMD_DISK_STAT,
    CMD_MOUSE_ON, CMD_MOUSE_OFF, CMD_KEYB_ONOFF: Allowed := True;
  else
    Allowed := False;
  end;
end;

procedure ClearError;
begin
  OutB(PmBase, CMD_RESET);
  WaitReady(18);
end;

function Command(Cmd: Byte; Arg: Word; TickLimit: Word; out Res: Word): Byte;
var S: Byte;
begin
  Res := 0;
  if not Allowed(Cmd) then begin Command := CR_REFUSED; Exit; end;

  S := WaitReady(18);
  if (S = ST_ERROR) or (S = ST_NOCMD) then begin ClearError; S := Status; end;
  if S <> ST_READY then begin Command := CR_NOTREADY; Exit; end;

  { argument then command, with nothing able to come between them }
  asm pushf; cli end;
  OutB(PmBase + 1, Lo(Arg));
  OutB(PmBase + 2, Hi(Arg));
  OutB(PmBase, Cmd);
  asm popf end;

  S := WaitReady(TickLimit);
  case S of
    ST_READY: begin
        Res := InB(PmBase + 1) or (Word(InB(PmBase + 2)) shl 8);
        Command := CR_OK;
      end;
    ST_BUSY:  Command := CR_TIMEOUT;
    ST_ERROR: begin Res := InB(PmBase + 1); ClearError; Command := CR_ERROR; end;
    ST_NOCMD: begin ClearError; Command := CR_NOCMD; end;
  else
    Command := CR_ODD;
  end;
end;

function CmdName(Cmd: Byte): string;
begin
  case Cmd of
    CMD_RESET:      CmdName := 'reset status';
    CMD_MEMTYPE:    CmdName := 'memory type of a block';
    CMD_WIFI_INFO:  CmdName := 'WiFi info';
    CMD_USB_STATUS: CmdName := 'USB status';
    CMD_DISK_STAT:  CmdName := 'disk status';
    CMD_MOUSE_ON:   CmdName := 'mouse reporting on';
    CMD_MOUSE_OFF:  CmdName := 'mouse reporting off';
    CMD_KEYB_ONOFF: CmdName := 'keyboard reporting on/off';
  else
    CmdName := '?';
  end;
end;

function StatusName(S: Byte): string;
begin
  case S of
    ST_READY:   StatusName := 'ready';
    ST_BUSY:    StatusName := 'busy';
    ST_ERROR:   StatusName := 'error';
    ST_NOCMD:   StatusName := 'no such command';
    ST_INIT:    StatusName := 'initialising';
    ST_WAITCOM: StatusName := 'waiting for USB serial';
    $10..$13:   StatusName := 'mid-transfer';
    $FF:        StatusName := 'nothing answering (FF)';
  else
    StatusName := 'unknown';
  end;
end;

function ResultName(R: Byte): string;
begin
  case R of
    CR_OK:       ResultName := 'ok';
    CR_REFUSED:  ResultName := 'refused by PMCARD (not whitelisted)';
    CR_NOTREADY: ResultName := 'card not ready';
    CR_TIMEOUT:  ResultName := 'TIMED OUT, card still busy';
    CR_ERROR:    ResultName := 'card reported an error';
    CR_NOCMD:    ResultName := 'firmware has no such command';
  else
    ResultName := 'odd status';
  end;
end;

function MemTypeName(T: Byte): string;
begin
  case T of
    MT_NULL:  MemTypeName := 'nothing from the card';
    MT_RAM:   MemTypeName := 'RAM inside the Pico';
    MT_DISK:  MemTypeName := 'card BIOS RAM and disk buffer';
    MT_BIOS:  MemTypeName := 'card BIOS ROM';
    MT_ROM0:  MemTypeName := 'ROM image, segment C';
    MT_ROM1:  MemTypeName := 'ROM image, segment D';
    MT_BIOSX: MemTypeName := 'card BIOS, extended';
    MT_PSRAM: MemTypeName := 'RAM in the PSRAM';
    MT_EMS:   MemTypeName := 'EMS window in the PSRAM';
    MT_SRAM:  MemTypeName := 'the PC own RAM';
    MT_SVID:  MemTypeName := 'the PC video RAM';
    MT_SROM:  MemTypeName := 'the PC own ROM';
  else
    MemTypeName := 'unknown';
  end;
end;

function MemTypeChar(T: Byte): Char;
begin
  case T of
    MT_NULL:  MemTypeChar := '.';
    MT_RAM:   MemTypeChar := 'r';
    MT_DISK:  MemTypeChar := 'd';
    MT_BIOS:  MemTypeChar := 'B';
    MT_ROM0:  MemTypeChar := 'C';
    MT_ROM1:  MemTypeChar := 'D';
    MT_BIOSX: MemTypeChar := 'b';
    MT_PSRAM: MemTypeChar := 'p';
    MT_EMS:   MemTypeChar := 'e';
    MT_SRAM:  MemTypeChar := 's';
    MT_SVID:  MemTypeChar := 'v';
    MT_SROM:  MemTypeChar := 'o';
  else
    MemTypeChar := '?';
  end;
end;

function SharedB(Ofs: Word): Byte;
begin
  SharedB := Mem[PmRomSeg : SHARED_OFS + Ofs];
end;

function SharedW(Ofs: Word): Word;
begin
  SharedW := MemW[PmRomSeg : SHARED_OFS + Ofs];
end;

{ The firmware writes 12h into the first byte of the shared memory. }
function SharedOK: Boolean;
begin
  SharedOK := (PmRomSeg <> 0) and (SharedB(0) = $12);
end;

function CfgB(Ofs: Word): Byte;
begin
  CfgB := SharedB(CFG_OFS + Ofs);
end;

function CfgW(Ofs: Word): Word;
begin
  CfgW := SharedW(CFG_OFS + Ofs);
end;

function CfgName(Ofs: Word): string;
var S: string; I: Integer; C: Char;
begin
  S := '';
  for I := 0 to 13 do begin
    C := Chr(CfgB(Ofs + I));
    if C = #0 then Break;
    if (C < ' ') or (C > '~') then C := '?';
    S := S + C;
  end;
  CfgName := S;
end;

{ *** the parameter area ***

  The disk-status answer has a shape nothing else in the shared memory
  has: a count byte, then that many strings, each of which the firmware
  builds as "   FDDn : ..." or "   HDDn : ..." and then overwrites the
  SECOND character of with FEh, a marker for its own menu.  So a line
  starts  20 FE 20 "HDD"  or  20 FE 20 "FDD".  Find the first of those
  and the count byte is the byte before it.

  Leftovers -- from the card's own boot-time menu, or from a firmware
  that used a different offset -- can leave a second copy further up,
  so the number of candidates is reported too. }
function FindParam: Boolean;
var Res: Word; R: Byte; I, First: Word; B0, B3: Byte;
begin
  PmParam := 0; PmParamN := 0;
  FindParam := False;
  Res := 0;
  R := Command(CMD_DISK_STAT, 0, 91, Res);
  if R <> CR_OK then Exit;

  First := 0;
  I := 33;
  while I < SHARED_LEN - 8 do begin
    if (SharedB(I) = $20) and (SharedB(I + 1) = $FE) and
       (SharedB(I + 2) = $20) then begin
      B3 := SharedB(I + 3);
      if ((B3 = Ord('H')) or (B3 = Ord('F'))) and
         (SharedB(I + 4) = Ord('D')) and (SharedB(I + 5) = Ord('D')) then begin
        B0 := SharedB(I - 1);
        if (B0 >= 1) and (B0 <= 6) then begin
          if First = 0 then First := I - 1;
          Inc(PmParamN);
        end;
      end;
    end;
    Inc(I);
  end;

  if First <> 0 then begin
    PmParam := First;
    FindParam := True;
  end;
end;

procedure CopyParam(var Buf; Len: Word);
var P: PByte; I: Word;
begin
  P := @Buf;
  for I := 0 to Len - 1 do begin
    if LongInt(PmParam) + I < SHARED_LEN then P[I] := SharedB(PmParam + I)
      else P[I] := 0;
  end;
end;

{ Line N (1..count) out of a copied parameter area: a count byte, then
  that many NUL-terminated strings.  FEh, the firmware's own marker, is
  put back to a space. }
function ParamLine(var Buf; Len: Word; N: Byte; out S: string): Boolean;
var P: PByte; I: Word; K: Byte; C: Char;
begin
  S := ''; ParamLine := False;
  P := @Buf;
  if (N = 0) or (N > P[0]) then Exit;
  I := 1;
  for K := 1 to N - 1 do begin
    while (I < Len) and (P[I] <> 0) do Inc(I);
    Inc(I);
    if I >= Len then Exit;
  end;
  while (I < Len) and (P[I] <> 0) and (Length(S) < 76) do begin
    C := Chr(P[I]);
    if C = #$FE then C := ' ';
    if (C < ' ') or (C > '~') then C := '.';
    S := S + C;
    Inc(I);
  end;
  ParamLine := True;
end;

function Hex2(B: Byte): string;
const H: string[16] = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4 + 1] + H[B and 15 + 1];
end;

function Hex4(W: Word): string;
begin
  Hex4 := Hex2(Hi(W)) + Hex2(Lo(W));
end;

end.
