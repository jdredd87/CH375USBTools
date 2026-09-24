program pmcfg;
{ PMCFG -- the whole configuration a PicoMEM is running.
  PicoMEM tools, StevenC & Claude.  Public domain (the Unlicense).

    PMCFG [/Q] [/X] [/P=2A0]

  Every line comes from reading the configuration block the card keeps
  in its shared memory -- the copy of its PM.CFG that the firmware
  loaded at boot.  Changing any of it means the card's own setup screen
  (hold a key at boot); nothing here writes, and pmcard.pas would
  refuse the commands that could.

  ONE read-only command is sent, and only to decide which layout this
  is: the disk-list query, whose answer lands in the parameter area, and
  where that area sits is what tells 256 bytes of configuration from
  768.  /Q skips it and assumes the older, smaller block.

    /Q   send nothing at all; assume the 256-byte block
    /X   also hex dump the configuration block
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  The layout is the firmware's PMCFG_t.  On the BIOS of 2025-11-02 the
  block is 256 bytes and ends after the menu colour and the RTC flag; a
  newer firmware grows it to 768 and adds a CD-ROM image name and the
  image directories.  Which one is running is told by where the answers
  area sits -- see PMINFO -- so the extra fields are printed only when
  there is room for them.

  Exit code: 0 read, 1 no card, 3 no shared memory. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '1.0.0';

  { offsets inside the configuration block }
  C_FDD0     = 0;    C_HDD0     = 32;
  C_FDDATTR  = 96;   C_HDDATTR  = 98;
  C_ROM0     = 102;  C_ROMADDR  = 134;  C_ROMBLK  = 136;
  C_MEMMAP   = 138;
  C_EMSPORT  = 202;  C_EMSADDR  = 203;
  C_PMRAMEXT = 204;  C_PSRAMEXT = 205;  C_MAXCONV = 206;
  C_FASTBOOT = 207;  C_PMBOOT   = 208;  C_IGNOREAB = 209;
  C_ENABLEUSB = 210; C_SDSPEED  = 211;  C_RAMSPEED = 212;
  C_BOOTHDD  = 213;  C_ENABLEWIFI = 214; C_NEIRQ  = 215;  C_NEPORT = 216;
  C_ENABLEJOY = 218; C_MAXPMRAM = 220;  C_MAXROM  = 221;
  C_PREBOOT  = 222;  C_BIOSBOOT = 223;
  C_AUDIOOUT = 224;  C_AUDIOBUF = 225;  C_AUDIO1  = 226;
  C_ADLIB    = 229;  C_TDYPORT  = 230;  C_CMSPORT = 232;  C_SBPORT = 234;
  C_SBIRQ    = 236;  C_AUDIO4   = 237;  C_MMBPORT = 238;
  C_COLOURPR = 240;  C_USERTC   = 241;
  C_CDROM    = 244;  C_FDDPATH  = 260;  C_HDDPATH = 388;

var
  DoHex, Quiet: Boolean;
  ForceBase: Word;
  Big: Boolean;        { does this firmware have the 768-byte block? }

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
  DoHex := False; Quiet := False; ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'Q': Quiet := True;
        'X': DoHex := True;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
end;

function YesNo(B: Byte): string;
begin
  if B = 0 then YesNo := 'no' else YesNo := 'yes';
end;

function OnOff(B: Byte): string;
begin
  if B = 0 then OnOff := 'off' else OnOff := 'on';
end;

function Pad(const S: string; N: Integer): string;
var R: string;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

procedure Disks;
var I: Integer; A: Byte; N: string;
begin
  WriteLn('disk images the card presents to the BIOS');
  for I := 0 to 1 do begin
    A := CfgB(C_FDDATTR + I);
    N := CfgName(C_FDD0 + 16 * I + 2);
    if (A >= $80) and (N <> '') then
      WriteLn('  FDD', I, ' : ', Pad(N, 14), CfgW(C_FDD0 + 16 * I):5, ' KB',
              '  attr ', Hex2(A))
    else
      WriteLn('  FDD', I, ' : -');
  end;
  for I := 0 to 3 do begin
    A := CfgB(C_HDDATTR + I);
    N := CfgName(C_HDD0 + 16 * I + 2);
    Write('  HDD', I, ' : ');
    if (A >= $80) and (N <> '') then begin
      Write(Pad(N, 14), CfgW(C_HDD0 + 16 * I):5, ' MB', '  attr ', Hex2(A));
      if A and $40 <> 0 then Write('  (USB)') else Write('  (SD card)');
      if CfgB(C_BOOTHDD) = I then Write('  <- boots from this one');
      WriteLn;
    end else
      WriteLn('-');
  end;
end;

procedure Roms;
var I: Integer; N: string;
begin
  WriteLn('option ROM images');
  for I := 0 to 1 do begin
    N := CfgName(C_ROM0 + 16 * I + 2);
    if N <> '' then
      WriteLn('  ROM', I, ' : ', Pad(N, 14), ' at ',
              Hex2(CfgB(C_ROMADDR + I)), '000h, ',
              CfgB(C_ROMBLK + I), ' block(s) of 16 KB')
    else
      WriteLn('  ROM', I, ' : -');
  end;
end;

procedure MemMap;
var I: Integer; Row: string;
begin
  WriteLn('memory, as the card was configured to map it');
  WriteLn('             0   1   2   3   4   5   6   7   8   9   A   B   ',
          'C   D   E   F');
  Row := '';
  for I := 0 to 63 do Row := Row + MemTypeChar(CfgB(C_MEMMAP + I));
  WriteLn('  16 KB each ', Row);
  WriteLn('  s the PC own RAM   v video RAM   o the PC own ROM');
  WriteLn('  B card BIOS   r card RAM   p PSRAM   e EMS   . nothing');
end;

procedure Memory;
const
  EmsPort: array[0..4] of Word = (0, $268, $288, $298, $2A8);
var P, A: Byte;
begin
  WriteLn('memory options');
  WriteLn('  extend with card RAM : ', Pad(YesNo(CfgB(C_PMRAMEXT)), 6),
          '   with PSRAM : ', YesNo(CfgB(C_PSRAMEXT)));
  WriteLn('  maximise conventional: ', Pad(YesNo(CfgB(C_MAXCONV)), 6),
          '   ignore A and B segments: ', YesNo(CfgB(C_IGNOREAB)));
  WriteLn('  card RAM the BIOS may use: ', CfgB(C_MAXPMRAM),
          ' blocks of 16 KB;  ROM: ', CfgB(C_MAXROM));
  P := CfgB(C_EMSPORT); A := CfgB(C_EMSADDR);
  Write('  EMS                  : ');
  if (P = 0) or (P > 4) then WriteLn('off')
  else begin
    Write('port ', Hex4(EmsPort[P]), 'h-', Hex4(EmsPort[P] + 3), 'h, window ');
    if A = 0 then WriteLn('D000h') else WriteLn('E000h');
  end;
end;

procedure Boot;
begin
  WriteLn('boot');
  WriteLn('  card boot strap : ', Pad(YesNo(CfgB(C_PMBOOT)), 6),
          '   setup before boot: ', YesNo(CfgB(C_PREBOOT)));
  WriteLn('  fast boot       : ', Pad(YesNo(CfgB(C_FASTBOOT)), 6),
          '   BIOS boot flag  : ', CfgB(C_BIOSBOOT));
end;

procedure Network;
var P: Word;
begin
  WriteLn('network');
  P := CfgW(C_NEPORT);
  if P = 0 then WriteLn('  NE2000          : off')
  else
    WriteLn('  NE2000          : ', Hex4(P), 'h-', Hex4(P + $1F), 'h, IRQ ',
            CfgB(C_NEIRQ));
  WriteLn('  WiFi enable flag: ', CfgB(C_ENABLEWIFI),
          '   (PMINFO reports whether it actually came up)');
end;

procedure Hardware;
begin
  WriteLn('hardware');
  WriteLn('  SD card : ', CfgB(C_SDSPEED), ' MHz     emulated RAM : ',
          CfgB(C_RAMSPEED), ' MHz');
  WriteLn('  USB host: ', Pad(OnOff(CfgB(C_ENABLEUSB)), 4),
          '        joystick at 201h: ', OnOff(CfgB(C_ENABLEJOY)));
  WriteLn('  RTC at 2C0h-2C7h: ', Pad(OnOff(CfgB(C_USERTC)), 4),
          '  menu colour profile: ', CfgB(C_COLOURPR));
end;

procedure Audio;
var W: Word;
begin
  WriteLn('audio the card emulates');
  WriteLn('  rendering : ', OnOff(CfgB(C_AUDIOOUT)),
          '   (with it off, none of the rest sounds)');
  WriteLn('  AdLib     : ', Pad(OnOff(CfgB(C_ADLIB)), 4), '  388h-389h');
  W := CfgW(C_TDYPORT);
  if W = 0 then WriteLn('  Tandy     : off')
    else WriteLn('  Tandy     : on    ', Hex4(W), 'h-', Hex4(W + 7), 'h');
  W := CfgW(C_CMSPORT);
  if W = 0 then WriteLn('  CMS       : off')
    else WriteLn('  CMS       : on    ', Hex4(W), 'h-', Hex4(W + $F), 'h');
  W := CfgW(C_SBPORT);
  if W = 0 then WriteLn('  SoundBlast: off')
    else WriteLn('  SoundBlast: on    ', Hex4(W), 'h, IRQ ', CfgB(C_SBIRQ));
  W := CfgW(C_MMBPORT);
  if W = 0 then WriteLn('  Mindscape : off')
    else WriteLn('  Mindscape : on    ', Hex4(W), 'h-', Hex4(W + $F), 'h');
  WriteLn('  other audio bytes: ', Hex2(CfgB(C_AUDIOBUF)), ' ',
          Hex2(CfgB(C_AUDIO1)), ' ', Hex2(CfgB(C_AUDIO1 + 1)), ' ',
          Hex2(CfgB(C_AUDIO1 + 2)), ' ', Hex2(CfgB(C_AUDIO4)));
end;

procedure Extras;
var N: string;
begin
  if not Big then begin
    WriteLn('CD-ROM image and image directories: not in this firmware',
            ' (256-byte block)');
    Exit;
  end;
  N := CfgName(C_CDROM + 2);
  if N = '' then WriteLn('CD-ROM image : -')
    else WriteLn('CD-ROM image : ', N);
end;

procedure HexCfg;
var I, N: Word; S: string;
begin
  WriteLn;
  if Big then N := 768 else N := 256;
  WriteLn('configuration block, raw, ', N, ' bytes from +', CFG_OFS, ':');
  S := '';
  for I := 0 to N - 1 do begin
    S := S + Hex2(CfgB(I)) + ' ';
    if (I and 15) = 15 then begin
      WriteLn('  +', I - 15:3, '  ', S);
      S := '';
    end;
  end;
end;

var
  Bad: Word;
begin
  Args;
  WriteLn('PMCFG ', VER, ' -- the configuration this PicoMEM is running', ' -- StevenC & Claude');

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h (', Bad,
            ' of 100 test-port reads out of sequence)');
    Halt(1);
  end;
  if not SharedOK then begin
    WriteLn('no shared memory at ', Hex4(PmRomSeg), ':4000');
    Halt(3);
  end;

  { The 2025-11-02 firmware keeps 256 bytes of configuration and puts
    its answers at +374; a 768-byte block pushes them to +886. }
  Big := False;
  if not Quiet then
    if FindParam then Big := PmParam >= PARAM_2026;

  Write('read from ', Hex4(PmRomSeg), ':4000+', CFG_OFS, ', ');
  if Quiet then WriteLn('256-byte block assumed (/Q)')
  else if Big then WriteLn('768-byte block (a newer firmware)')
    else WriteLn('256-byte block (the 2025-11-02 firmware)');
  WriteLn;

  Disks;    WriteLn;
  Roms;     WriteLn;
  MemMap;   WriteLn;
  Memory;   WriteLn;
  Boot;     WriteLn;
  Network;  WriteLn;
  Hardware; WriteLn;
  Audio;    WriteLn;
  Extras;
  if DoHex then HexCfg;
end.
