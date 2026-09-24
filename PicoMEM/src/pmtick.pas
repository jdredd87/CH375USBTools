program pmtick;
{ PMTICK -- does the PC's clock keep running after a PicoMEM command?
  PicoMEM tools, StevenC & Claude.  Public domain (the Unlicense).

    PMTICK [/C-]       /C- : do NOT send the command (the control run)

  The USB watch and PMCMDT wedged the machine whenever they WAITED on the BIOS
  tick after a USB status query, and never when they did not wait.  So
  this sends one query and then watches the tick with a loop bounded by
  a COUNT, never by the clock, recording on the way:

    * the interrupt flag,
    * the 8259's mask (port 21h) and in-service register (OCW3 read),
    * how many ticks pass in a fixed number of loop turns.

  Before and after the command, so the two can be compared.  Nothing is
  printed until the end. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '0.1.0';
  TURNS = 60000;          { loop turns per measurement }

type
  TSnap = record
    Flags: Word;
    Mask, Isr, Irr: Byte;
    TickA, TickB: LongInt;
  end;

var
  Before, After, Later: TSnap;
  R: Byte;
  Res: Word;
  Send: Boolean;

function GetFlags: Word; assembler;
asm
  pushf
  pop ax
end;

function ReadIsr: Byte;
begin
  OutB($20, $0B);          { OCW3: read in-service register }
  ReadIsr := InB($20);
end;

function ReadIrr: Byte;
begin
  OutB($20, $0A);          { OCW3: read request register }
  ReadIrr := InB($20);
end;

procedure Snap(out S: TSnap);
var I, J: Word; X: Byte;
begin
  S.Flags := GetFlags;
  S.Mask := InB($21);
  S.Isr := ReadIsr;
  S.Irr := ReadIrr;
  S.TickA := Ticks;
  for I := 1 to TURNS do
    for J := 1 to 10 do X := InB($61);   { a slow, harmless read }
  S.TickB := Ticks;
end;

function Hex2(B: Byte): string;
const H: string[16] = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4 + 1] + H[B and 15 + 1];
end;

procedure Show(const Name: string; const S: TSnap);
begin
  Write(Name, ': IF=', (S.Flags shr 9) and 1, '  mask=', Hex2(S.Mask),
        '  in-service=', Hex2(S.Isr), '  requested=', Hex2(S.Irr),
        '  ticks passed=', S.TickB - S.TickA);
  if S.TickB = S.TickA then Write('   <-- CLOCK STOPPED');
  WriteLn;
end;

begin
  Send := not ((ParamCount >= 1) and (ParamStr(1) = '/C-'));
  if not AskBios then begin WriteLn('no PicoMEM BIOS'); Halt(1); end;
  if TestPort(PmBase, 100) <> 0 then begin WriteLn('no PicoMEM'); Halt(1); end;

  Snap(Before);
  if Send then R := Command(CMD_USB_STATUS, 0, 91, Res) else R := CR_OK;
  Snap(After);
  Snap(Later);

  { if the clock stopped, put interrupts back on before any DOS call --
    DOS would otherwise run with them off too }
  asm sti end;

  WriteLn('PMTICK ', VER, ' -- the PC clock around one PicoMEM command', ' -- StevenC & Claude');
  if Send then WriteLn('command 61h: ', ResultName(R), ', status ', Hex2(PmLastSt))
  else WriteLn('control run: no command sent');
  Show('before', Before);
  Show('after ', After);
  Show('later ', Later);
end.
