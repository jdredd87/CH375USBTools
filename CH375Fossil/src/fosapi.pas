unit fosapi;

{ FOSAPI -- the FOSSIL side of INT 14h, and a small pass/fail harness, for
  CH375Fossil's test programs.

  All six of them used to carry their own copies of this: five had their own
  Ticks, four their own HexW, and the two big ones had a whole INT 14h layer
  each under slightly different names -- one called it Status and GetCh, the
  other FosStatus and FosRecv. Same code, same bugs available twice.

  The names are deliberately unambiguous about which call blocks, because
  that is the distinction that matters here and the one the duplicate
  versions had already started to blur:

      SendWait    function 01h -- blocks until there is room
      TxNoWait    function 0Bh -- returns False if there is none
      PutCh       0Bh in a bounded retry, which is what a program wants
      GetCh       function 02h -- blocks FOR EVER, by design and by spec

  GetCh is the one to be careful with. Function 02h is specified to block
  and real BBS software depends on it, so the driver does not bound it.
  Check RxReady first if a hang would cost you a trip to the machine.

  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
  Public domain (the Unlicense). }

{$MODE OBJFPC}{$H-}

interface

uses Dos;

type
  { The AH=1Bh driver information block, FSC-0015. }
  TFosInfo = record
    StrSiz  : Word;      { size of this structure }
    MajVer  : Byte;      { FOSSIL spec level }
    MinVer  : Byte;      { driver revision }
    IdOfs   : Word;      { FAR pointer to an asciiz identifier }
    IdSeg   : Word;
    IBufr   : Word;      { input buffer size }
    IFree   : Word;      { and how much of it is free }
    OBufr   : Word;      { output buffer size }
    OFree   : Word;
    SWidth  : Byte;
    SHeight : Byte;
    Baud    : Byte;      { in the AH=00h encoding }
  end;

{ ---- odds and ends every one of these programs wanted ---- }
function Ticks: Word;                            { the BIOS tick, 0040:006C }
function HexW(W: Word): ShortString;
function HexB(B: Byte): ShortString;

{ ---- detection ----
  Present() reads the signature out of memory and makes NO INT 14h call. The
  BIOS INT 14h defines AH=00h..03h and nothing else, so a blind AH=04h on a
  machine with no driver is a call into undefined ROM. FSC-0015 puts the
  word 1954h at offset 6 of the handler precisely so the question can be
  asked without asking it. }
function Present: Boolean;
function MaxFunc: Byte;                          { the byte after the signature }
function VecSeg: Word;
function VecOfs: Word;

{ ---- opening and closing the line ---- }
function Init: Boolean;                          { 04h, True if it answers 1954h }
function InitRegs(var Regs: Registers): Boolean; { ...when the caller wants BX too }
procedure Deinit;                                { 05h }

{ ---- status, 03h ---- }
function Status: Word;
function Carrier: Boolean;                       { AL bit 7, DCD }
function RxReady: Boolean;                       { AH bit 0, RDA }
function TxRoom: Boolean;                        { AH bit 5, THRE }
function TxEmpty: Boolean;                       { AH bit 6, TSRE }
function Overrun: Boolean;                       { AH bit 1, OVRN }

{ ---- moving bytes ---- }
procedure SendWait(B: Byte);                     { 01h, blocks for room }
function  TxNoWait(B: Byte): Boolean;            { 0Bh }
procedure PutCh(B: Byte);                        { 0Bh, bounded retry }
function  GetCh: Byte;                           { 02h, BLOCKS -- see above }
function  Peek: Word;                            { 0Ch, FFFFh when empty }
function  WriteBlock(var B; Len: Word): Word;    { 19h }
function  ReadBlock(var B; Max: Word): Word;     { 18h }
procedure Send(const S: ShortString);
procedure SendLn(const S: ShortString);

{ ---- control ---- }
procedure Flush;                                 { 08h }
procedure PurgeIn;                               { 0Ah }
procedure PurgeOut;                              { 09h }
procedure Dtr(Raised: Boolean);                  { 06h -- lowering it hangs up }
procedure SetBaud(Code: Byte);                   { 00h }

{ ---- the buffer report a caller throttles on, 1Bh ---- }
procedure Info(var I: TFosInfo);
function RxAvail: Word;
function TxPending: Word;
function TxFree: Word;

{ ---- the function 16h tick chain ----
  A routine handed to 16h is called from inside a hardware interrupt with
  the DRIVER's DS, so a Pascal procedure is the wrong shape: touching any
  global would write into the driver. BuildTickStub lays down a few bytes of
  machine code that keep their counter in the same array and reach it
  through CS, which during the call is that array's own segment. Nothing to
  set up and nothing to get wrong.

  Whatever is registered MUST be removed before the owning program exits. A
  stale entry is a far call into memory DOS has since handed to something
  else, so the fault lands on whatever runs NEXT. }
procedure BuildTickStub(var Buf; CodeOfs, CountOfs: Word);
procedure BuildAppStub(var Buf; CodeOfs, CountOfs, Magic: Word);
function  StubCount(var Buf; CountOfs: Word): Word;
function  TickChain(TurnOn: Boolean; SegV, OfsV: Word): Boolean;

{ ---- the harness ----
  Interface identical to DOSBridge's Tester, which is where these programs
  came from. Everything prints through DOS calls: direct video writes are
  faster and also invisible to DOSBridge, which captures stdout and nothing
  else, so a program that only draws to the screen comes back as an empty
  log. The exit code is the failure count, capped at 20 to match the
  IF ERRORLEVEL ladder DOS 6.22 can express. }
procedure Check(const Name: ShortString; Passed: Boolean);
procedure Note(const S: ShortString);
procedure Note(const S: ShortString; V: LongInt);
procedure Finish;
function Failures: Integer;
function Passed: Integer;

{ Clear a register record for an INT 14h call WITHOUT clearing the flags.
  Exported because the test programs build their own calls; see the
  implementation for why the flags must survive. }
procedure ClearRegs(var Rg: Registers);

implementation

const
  HexDig : array[0..15] of Char = '0123456789ABCDEF';

var
  R      : Registers;
  Passes : Integer = 0;
  Fails  : Integer = 0;

{ ------------------------------------------------------------------ }

{ Clear a register record for an INT 14h call, WITHOUT clearing the flags.

  FPC's Intr LOADS Registers.Flags into the CPU before the interrupt, so a
  record cleared with FillChar calls the handler with interrupts DISABLED,
  and a handler that ends in IRET hands them back that way: the BIOS tick
  at 0040:006C stops, and anything that then waits on the clock waits for
  ever.  That is not theory -- it wedged a 386 three times in PicoMEM2's
  AskBios before it was understood, and it looked exactly like the hardware
  hanging.

  FOSSIL.COM re-enables them itself, which is why nothing here has ever
  shown it, but a FOSSIL driver is not required to: FSC-0015 says nothing
  about the interrupt flag, and any driver that simply IRETs would freeze
  the clock of every program in this unit.  So the live flags go in. }
function CpuFlags: Word; assembler;
asm
  pushf
  pop ax
end;

procedure ClearRegs(var Rg: Registers);
var F: Word;
begin
  F := CpuFlags;
  FillChar(Rg, SizeOf(Rg), 0);
  Rg.Flags := F;
end;

{ ------------------------------------------------------------------ }

function Ticks: Word;
begin
  Ticks := MemW[$0040:$006C];
end;

function HexW(W: Word): ShortString;
begin
  HexW := HexDig[(W shr 12) and 15] + HexDig[(W shr 8) and 15] +
          HexDig[(W shr 4) and 15] + HexDig[W and 15];
end;

function HexB(B: Byte): ShortString;
begin
  HexB := HexDig[(B shr 4) and 15] + HexDig[B and 15];
end;

function VecOfs: Word;
begin
  VecOfs := MemW[0 : $14 * 4];
end;

function VecSeg: Word;
begin
  VecSeg := MemW[0 : $14 * 4 + 2];
end;

function Present: Boolean;
begin
  Present := MemW[VecSeg : VecOfs + 6] = $1954;
end;

function MaxFunc: Byte;
begin
  MaxFunc := Mem[VecSeg : VecOfs + 8];
end;

{ ------------------------------------------------------------------ }

function InitRegs(var Regs: Registers): Boolean;
begin
  ClearRegs(Regs);
  Regs.AH := $04; Regs.DX := 0; Regs.BX := $4F50;
  Intr($14, Regs);
  InitRegs := Regs.AX = $1954;
end;

function Init: Boolean;
begin
  Init := InitRegs(R);
end;

procedure Deinit;
begin
  ClearRegs(R);
  R.AH := $05; R.DX := 0;
  Intr($14, R);
end;

function Status: Word;
begin
  ClearRegs(R);
  R.AH := $03; R.DX := 0;
  Intr($14, R);
  Status := R.AX;
end;

function Carrier: Boolean;  begin Carrier := (Status and $0080) <> 0; end;
function RxReady: Boolean;  begin RxReady := (Status and $0100) <> 0; end;
function Overrun: Boolean;  begin Overrun := (Status and $0200) <> 0; end;
function TxRoom: Boolean;   begin TxRoom  := (Status and $2000) <> 0; end;
function TxEmpty: Boolean;  begin TxEmpty := (Status and $4000) <> 0; end;

procedure SendWait(B: Byte);
begin
  ClearRegs(R);
  R.AH := $01; R.AL := B; R.DX := 0;
  Intr($14, R);
end;

function TxNoWait(B: Byte): Boolean;
begin
  ClearRegs(R);
  R.AH := $0B; R.AL := B; R.DX := 0;
  Intr($14, R);
  TxNoWait := R.AX = 1;
end;

{ Bounded, and it gives up if the carrier goes: a caller who has hung up
  mid-sentence must not leave us spinning on a buffer nobody is draining. }
procedure PutCh(B: Byte);
var Dead: Word;
begin
  Dead := Ticks + 36;
  repeat
    if TxNoWait(B) then Exit;
  until (Integer(Ticks - Dead) >= 0) or (not Carrier);
end;

function GetCh: Byte;
begin
  ClearRegs(R);
  R.AH := $02; R.DX := 0;
  Intr($14, R);
  GetCh := R.AL;
end;

function Peek: Word;
begin
  ClearRegs(R);
  R.AH := $0C; R.DX := 0;
  Intr($14, R);
  Peek := R.AX;
end;

function WriteBlock(var B; Len: Word): Word;
begin
  ClearRegs(R);
  R.AH := $19; R.CX := Len; R.DX := 0;
  R.ES := Seg(B); R.DI := Ofs(B);
  Intr($14, R);
  WriteBlock := R.AX;
end;

function ReadBlock(var B; Max: Word): Word;
begin
  ClearRegs(R);
  R.AH := $18; R.CX := Max; R.DX := 0;
  R.ES := Seg(B); R.DI := Ofs(B);
  Intr($14, R);
  ReadBlock := R.AX;
end;

procedure Send(const S: ShortString);
var I: Integer;
begin
  for I := 1 to Length(S) do PutCh(Ord(S[I]));
end;

procedure SendLn(const S: ShortString);
begin
  Send(S);
  PutCh(13);
  PutCh(10);
end;

procedure Flush;
begin
  ClearRegs(R);
  R.AH := $08; R.DX := 0;
  Intr($14, R);
end;

procedure PurgeIn;
begin
  ClearRegs(R);
  R.AH := $0A; R.DX := 0;
  Intr($14, R);
end;

procedure PurgeOut;
begin
  ClearRegs(R);
  R.AH := $09; R.DX := 0;
  Intr($14, R);
end;

procedure Dtr(Raised: Boolean);
begin
  ClearRegs(R);
  R.AH := $06; R.DX := 0;
  if Raised then R.AL := 1 else R.AL := 0;
  Intr($14, R);
end;

procedure SetBaud(Code: Byte);
begin
  ClearRegs(R);
  R.AH := $00; R.AL := Code; R.DX := 0;
  Intr($14, R);
end;

procedure Info(var I: TFosInfo);
begin
  FillChar(I, SizeOf(I), 0);
  ClearRegs(R);
  R.AH := $1B; R.CX := SizeOf(I); R.DX := 0;
  R.ES := Seg(I); R.DI := Ofs(I);
  Intr($14, R);
end;

function RxAvail: Word;
var I: TFosInfo;
begin
  Info(I);
  if I.IBufr = 0 then RxAvail := 0
  else RxAvail := I.IBufr - 1 - I.IFree;
end;

function TxPending: Word;
var I: TFosInfo;
begin
  Info(I);
  if I.OBufr = 0 then TxPending := 0
  else TxPending := I.OBufr - 1 - I.OFree;
end;

function TxFree: Word;
var I: TFosInfo;
begin
  Info(I);
  TxFree := I.OFree;
end;

{ ------------------------------------------------------------------ }

type
  TStub = array[0..255] of Byte;

{ inc word [cs:CountOfs] / retf }
procedure BuildTickStub(var Buf; CodeOfs, CountOfs: Word);
var S: ^TStub;
begin
  S := @Buf;
  S^[CodeOfs + 0] := $2E;                        { CS: }
  S^[CodeOfs + 1] := $FF;                        { inc word [disp16] }
  S^[CodeOfs + 2] := $06;
  S^[CodeOfs + 3] := Lo(Ofs(Buf) + CountOfs);
  S^[CodeOfs + 4] := Hi(Ofs(Buf) + CountOfs);
  S^[CodeOfs + 5] := $CB;                        { retf }
end;

{ mov ax,Magic / inc word [cs:CountOfs] / retf }
procedure BuildAppStub(var Buf; CodeOfs, CountOfs, Magic: Word);
var S: ^TStub;
begin
  S := @Buf;
  S^[CodeOfs + 0] := $B8;                        { mov ax, imm16 }
  S^[CodeOfs + 1] := Lo(Magic);
  S^[CodeOfs + 2] := Hi(Magic);
  S^[CodeOfs + 3] := $2E;
  S^[CodeOfs + 4] := $FF;
  S^[CodeOfs + 5] := $06;
  S^[CodeOfs + 6] := Lo(Ofs(Buf) + CountOfs);
  S^[CodeOfs + 7] := Hi(Ofs(Buf) + CountOfs);
  S^[CodeOfs + 8] := $CB;                        { retf }
end;

function StubCount(var Buf; CountOfs: Word): Word;
var S: ^TStub;
begin
  S := @Buf;
  StubCount := S^[CountOfs] or (Word(S^[CountOfs + 1]) shl 8);
end;

function TickChain(TurnOn: Boolean; SegV, OfsV: Word): Boolean;
begin
  ClearRegs(R);
  R.AH := $16;
  if TurnOn then R.AL := 1 else R.AL := 0;
  R.ES := SegV; R.DX := OfsV;
  Intr($14, R);
  TickChain := R.AX = 0;
end;

{ ------------------------------------------------------------------ }

procedure Check(const Name: ShortString; Passed: Boolean);
begin
  if Passed then
  begin
    Inc(Passes);
    WriteLn('PASS  ', Name);
  end
  else
  begin
    Inc(Fails);
    WriteLn('FAIL  ', Name);
  end;
end;

procedure Note(const S: ShortString);
begin
  WriteLn('      ', S);
end;

{ The LongInt overload exists so a caller never has to reach for SysUtils:
  IntToStr and friends link a great deal of dead weight into a 16-bit
  real-mode binary. }
procedure Note(const S: ShortString; V: LongInt);
begin
  WriteLn('      ', S, V);
end;

function Failures: Integer;
begin
  Failures := Fails;
end;

function Passed: Integer;
begin
  Passed := Passes;
end;

procedure Finish;
var Code: Integer;
begin
  WriteLn;
  WriteLn('--- ', Passes, ' passed, ', Fails, ' failed ---');
  Code := Fails;
  if Code > 20 then Code := 20;
  Halt(Code);
end;

end.
