unit pmcard;
{ PMCARD -- talking to a PicoMEM 2 (or 1.x) card from real-mode DOS.
  PicoMEM2 tools, StevenC.  Public domain (the Unlicense).

  Written from reading the card's published firmware and BIOS sources
  (github.com/FreddyVRetro/ISA-PicoMEM, GPLv2); no code is taken from
  them.  What this unit relies on, all of it checked against that source:

  FINDING IT.  The card's BIOS answers INT 13h with AH=60h, AL=0,
  DX=1234h by returning DX=AA55h, AX = the I/O base, BX = the segment of
  its ROM, CX = a device mask.  Without its BIOS the base defaults to
  2A0h.  base+3 is a test port: every read returns one more than the
  last, which no other card does, so it identifies the card for certain.

  COMMANDS.  base+0 reads the status (00 ready, 01 busy, 02 error,
  03 no such command, 04 initialising, 05 waiting for USB serial) and
  takes a command byte; base+1/+2 carry a 16-bit argument in and a 16-bit
  result out.  Bulkier answers land in the card's SHARED MEMORY: 8 KB of
  RAM the card emulates at ROM segment + 16 KB, the first 32 bytes of
  which are the BIOS variables (init states, board and firmware IDs), then
  the card's configuration, then a 2 KB parameter area.

  THE BOOT DISK GOES THROUGH THIS SAME PORT.  The machine this was
  written on boots from a disk image on the card's SD card, and every
  sector DOS reads is a command on base+0.  A command left stuck -- in
  progress or in error -- is a disk that no longer answers.  So:

    * Only the commands in the whitelist below can be sent at all.  Disk,
      image, memory, configuration, audio and lock commands are refused
      here, in the one routine that writes base+0, not by convention.
    * Every wait has a deadline, from the BIOS tick.  Their own library
      spins forever.
    * An error is cleared with command 00 before returning, which is what
      the card's own BIOS does.
    * Nothing here calls DOS while a command is in flight: a WriteLn to a
      redirected stdout IS a disk write.  Callers copy the answer out first
      and print afterwards. }

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
  CMD_RESET      = $00;   { clears an error; the BIOS does the same }
  CMD_WIFI_INFO  = $60;   { WiFi state -- may RETRY the connection, see pmprobe }
  CMD_USB_STATUS = $61;   { USB device list, as text, into shared memory }
  CMD_DISK_STAT  = $62;   { mounted images, as text -- reads config only }

  SHARED_OFS = $4000;     { shared memory = ROM segment + 16 KB }
  SHARED_LEN = 8192;
  PARAM_OFS  = 886;       { the parameter area, from the firmware's layout }

  { how a command ended }
  CR_OK       = 0;
  CR_REFUSED  = 1;        { not on the whitelist; nothing was sent }
  CR_NOTREADY = 2;        { the card was not ready to take it }
  CR_TIMEOUT  = 3;        { no answer within the deadline }
  CR_ERROR    = 4;        { status 02 }
  CR_NOCMD    = 5;        { status 03: this firmware has no such command }
  CR_ODD      = 6;        { some other status }

var
  PmBase    : Word;       { I/O base }
  PmRomSeg  : Word;       { segment of the card's ROM; 0 if its BIOS did not answer }
  PmMask    : Word;       { device mask the BIOS returned }
  PmBiosHit : Boolean;    { INT 13h AH=60h answered }
  PmLastSt  : Byte;       { last status read }

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

function SharedB(Ofs: Word): Byte;
function SharedW(Ofs: Word): Word;
function SharedOK: Boolean;

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
  BIOS tick then stops, and anything that waits on it waits for ever:
  that is how PMUSB's first version wedged the machine, three times,
  looking every time like the card had hung.  PMTICK is the proof.  So
  the flags go in as they are, and interrupts are put back on regardless
  if they were on to begin with. }
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
    CMD_RESET, CMD_WIFI_INFO, CMD_USB_STATUS, CMD_DISK_STAT: Allowed := True;
  else
    Allowed := False;
  end;
end;

{ Put an error or unknown-command status back to ready, the way the
  card's BIOS does.  Only ever called when the status is not "busy". }
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
    CMD_WIFI_INFO:  CmdName := 'WiFi info';
    CMD_USB_STATUS: CmdName := 'USB status';
    CMD_DISK_STAT:  CmdName := 'disk status';
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

end.
