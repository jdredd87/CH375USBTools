program pmdev;
{ PMDEV -- which of the card's emulated devices are really there,
  checked from the PC side rather than believed from the configuration.
  PicoMEM tools, StevenC & Claude.  Public domain (the Unlicense).

    PMDEV [/A-] [/P=2A0]

  PMCFG says what the card was told to emulate.  This asks the PC:
  the PicoMEM's own port answers a counting test, an OPL2 answers its
  timers, a packet driver leaves a signature in the interrupt vector
  table, and an option ROM starts with 55 AA.  Where a device is
  configured off, nothing is sent to its ports at all.

    /A-  skip the AdLib test.  It is the only probe here that writes
         anything: two OPL2 timer registers, which is how every AdLib
         has been detected since 1987, and it puts them back
    /P=   I/O base to try if the card BIOS does not answer (default 2A0)

  THE NE2000 IS NEVER TOUCHED.  On this machine it carries the network
  the card is being administered over, and its registers are paged --
  a read is not harmless.  Its packet driver is looked for instead.

  Exit code: 0 the card is there and every device it says it emulates
  answered, 1 no card at all, 2 something configured did not answer --
  which is the only result here worth failing a script over. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '1.0.0';
  C_ENABLEJOY = 218; C_ADLIB = 229; C_AUDIOOUT = 224;
  C_NEPORT = 216; C_NEIRQ = 215; C_USERTC = 241;
  C_EMSPORT = 202;
  OPL = $388;

var
  DoAdlib: Boolean;
  ForceBase: Word;
  Found: Integer;      { devices that answered }
  Missing: Integer;    { configured, and did not }

function ParseHex(const S: string; var W: Word): Boolean;
var I: Integer; C: Char; V: Word;
begin
  V := 0; ParseHex := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    C := UpCase(S[I]);
    case C of
      '0'..'9': V := V * 16 + Ord(C) - 48;
      'A'..'F': V := V * 16 + Ord(C) - 55;
    else Exit;
    end;
  end;
  W := V; ParseHex := True;
end;

procedure Args;
var I: Integer; S: string; W: Word;
begin
  DoAdlib := True; ForceBase := $2A0;
  Found := 0; Missing := 0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'A': DoAdlib := not ((Length(S) > 2) and (S[3] = '-'));
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
end;

{ An OPL2 wants about 3 us after an address write and 23 us after a
  data write.  Reading its own status port is the portable delay:
  every read is an ISA cycle whatever the CPU is, which is the point
  on a machine that might be a V30 or a 386. }
procedure OplWait(N: Integer);
var I: Integer; B: Byte;
begin
  for I := 1 to N do B := InB(OPL);
end;

procedure OplReg(R, V: Byte);
begin
  OutB(OPL, R);     OplWait(6);
  OutB(OPL + 1, V); OplWait(35);
end;

{ The AdLib detection from the original manual: mask both timers, reset
  the interrupt, read the status (must be 0), then run timer 1 and read
  it again (must have bits 6 and 7 set).  Nothing else in a PC answers
  that way.  Everything it writes is put back at the end. }
function AdlibThere(out S1, S2: Byte): Boolean;
begin
  OplReg($04, $60);            { mask timer 1 and timer 2 }
  OplReg($04, $80);            { reset the interrupt flags }
  S1 := InB(OPL);
  OplReg($02, $FF);            { timer 1 preset: one step from overflow }
  OplReg($04, $21);            { unmask and start timer 1 }
  { the timer needs about 80 us.  Counted in ISA reads rather than in
    BIOS ticks: a read of the chip's own port costs a bus cycle whatever
    the CPU is, so this is the same wait on a V30 and on a 486, and it
    does not stop working if something has left interrupts off }
  OplWait(250);
  S2 := InB(OPL);
  OplReg($04, $60);            { put the timers back as they were }
  OplReg($04, $80);
  AdlibThere := (S1 and $E0 = 0) and (S2 and $E0 = $C0);
end;

procedure Adlib;
var S1, S2: Byte; Cfg: Boolean;
begin
  Cfg := (CfgB(C_ADLIB) <> 0) and (CfgB(C_AUDIOOUT) <> 0);
  Write('AdLib  388h-389h : ');
  if not DoAdlib then begin
    WriteLn('not tested (/A-); configured ', Ord(Cfg));
    Exit;
  end;
  if AdlibThere(S1, S2) then begin
    WriteLn('ANSWERS as an OPL2 (status ', Hex2(S1), ' then ', Hex2(S2), ')');
    if Cfg then
      WriteLn('                   and the card is configured to emulate one')
    else
      WriteLn('                   but the card says it is NOT emulating one');
    Inc(Found);
  end else begin
    WriteLn('nothing (status ', Hex2(S1), ' then ', Hex2(S2), ')');
    if Cfg then begin
      WriteLn('                   although the card is configured to be one!');
      Inc(Missing);
    end;
  end;
end;

{ A packet driver leaves "PKT DRVR" three bytes into its interrupt
  handler.  Reading the vector table and the ROM is as safe as it gets,
  and it is the only way to look at the NE2000 without touching it. }
procedure PacketDriver;
var V, Sg, Of_: Word; I: Integer; S: string; C: Char; Hit: Boolean;
begin
  Hit := False;
  for V := $60 to $80 do begin
    Sg := MemW[0 : V * 4 + 2];
    Of_ := MemW[0 : V * 4];
    if (Sg = 0) and (Of_ = 0) then Continue;
    S := '';
    for I := 3 to 10 do begin
      C := Chr(Mem[Sg : Word(Of_ + I)]);
      if (C < ' ') or (C > '~') then C := '.';
      S := S + C;
    end;
    if S = 'PKT DRVR' then begin
      WriteLn('packet driver    : at interrupt ', Hex2(V),
              'h -- the NE2000 is in use');
      Hit := True;
      Inc(Found);
    end;
  end;
  if not Hit then
    WriteLn('packet driver    : none loaded (interrupts 60h to 80h)');
end;

procedure Network;
var P: Word;
begin
  P := CfgW(C_NEPORT);
  if P = 0 then
    WriteLn('NE2000           : configured off')
  else
    WriteLn('NE2000           : configured at ', Hex4(P), 'h IRQ ',
            CfgB(C_NEIRQ), ' -- NOT probed, see the header');
  PacketDriver;
end;

procedure Joystick;
var B1, B2: Byte;
begin
  Write('joystick 201h    : ');
  if CfgB(C_ENABLEJOY) = 0 then begin
    WriteLn('configured off, not probed');
    Exit;
  end;
  B1 := InB($201);
  B2 := InB($201);
  if (B1 = $FF) and (B2 = $FF) then begin
    WriteLn('reads FF -- nothing there');
    Inc(Missing);
  end
  else begin
    WriteLn('reads ', Hex2(B1), ' then ', Hex2(B2), ' -- something answers');
    Inc(Found);
  end;
end;

procedure Rtc;
var B: Byte;
begin
  Write('RTC 2C0h-2C7h    : ');
  if CfgB(C_USERTC) = 0 then begin
    WriteLn('configured off, not probed');
    Exit;
  end;
  B := InB($2C0);
  if B = $FF then begin
    WriteLn('reads FF -- nothing there');
    Inc(Missing);
  end
  else begin
    WriteLn('reads ', Hex2(B), ' -- something answers');
    Inc(Found);
  end;
end;

procedure Ems;
const EmsPort: array[0..4] of Word = (0, $268, $288, $298, $2A8);
var P: Byte;
begin
  P := CfgB(C_EMSPORT);
  Write('EMS              : ');
  if (P = 0) or (P > 4) then WriteLn('configured off')
  else WriteLn('configured at ', Hex4(EmsPort[P]), 'h (write-only ports,',
               ' nothing to read)');
end;

{ Every option ROM in the upper memory area, from its 55 AA and its
  length byte.  Read-only, and the card's own BIOS is one of them. }
procedure OptionRoms;
var Sg: Word; Sz: Byte; N: Integer;
begin
  WriteLn;
  WriteLn('option ROMs between C000h and F000h');
  N := 0;
  Sg := $C000;
  while Sg < $F000 do begin
    if MemW[Sg : 0] = $AA55 then begin
      Sz := Mem[Sg : 2];
      Write('  ', Hex4(Sg), 'h  ', LongInt(Sz) * 512 div 1024, ' KB');
      if Sg = PmRomSeg then Write('   <- this PicoMEM');
      WriteLn;
      Inc(N);
      { length is in 512-byte blocks; ROMs start on 2 KB boundaries }
      if Sz >= 4 then Sg := Sg + (((Word(Sz) * 32) + $7F) and $FF80)
        else Inc(Sg, $80);
    end else
      Inc(Sg, $80);          { ROMs start on a 2 KB boundary }
  end;
  if N = 0 then WriteLn('  none');
end;

var
  Bad: Word;
begin
  Args;
  WriteLn('PMDEV ', VER, ' -- the card''s devices, asked from the PC side', ' -- StevenC & Claude');

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h (', Bad,
            ' of 100 test-port reads out of sequence)');
    Halt(1);
  end;
  WriteLn;
  WriteLn('PicoMEM ', Hex4(PmBase), 'h-', Hex4(PmBase + 7),
          'h: answers, 100 of 100 counting reads in sequence');
  Inc(Found);
  if SharedOK then
    WriteLn('  its IRQ is ', SharedB(11), ', its BIOS at ', Hex4(PmRomSeg),
            'h, its shared memory at ', Hex4(PmRomSeg), ':4000')
  else
    WriteLn('  no shared memory -- the configuration below cannot be read');

  WriteLn;
  Adlib;
  Network;
  Joystick;
  Rtc;
  Ems;
  OptionRoms;

  WriteLn;
  WriteLn(Found, ' device(s) answered, ', Missing,
          ' configured but silent.');
  if Missing > 0 then Halt(2) else Halt(0);
end.
