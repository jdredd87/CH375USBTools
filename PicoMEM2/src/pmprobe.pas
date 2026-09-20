program pmprobe;
{ PMPROBE -- what is this PicoMEM card, and what does it see?
  PicoMEM2 tools, StevenC.  Public domain (the Unlicense).

    PMPROBE [/U] [/D] [/W] [/X] [/P=2A0]

  With no switches it is READ-ONLY apart from one query command:
  finds the card through its BIOS, proves it with the test port, reads
  the shared memory (init states, board, firmware, configuration) and
  asks for the USB device list.

    /U-  skip the USB query (then nothing at all is sent to the card)
    /D   also ask for the disk-image status (a text summary built from
         the configuration; it does not touch the SD card)
    /W   also ask for the WiFi state.  CAUTION: the firmware RETRIES the
         WiFi connection if it thinks the signal is gone -- and on a
         machine administered over that WiFi, a retry is a dropped link
    /X   hex dump of the shared memory's first 256 bytes and of the
         parameter area
    /P=  I/O base to try when the card's BIOS does not answer (2A0)

  Exit code: 0 found and answered, 1 no card, 2 a command failed,
  3 no shared memory.  See pmcard.pas for why only four commands can be
  sent at all. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '0.1.0';
  CFG = 82;               { configuration, offset in the shared memory }

var
  DoUsb, DoDisk, DoWifi, DoHex: Boolean;
  ForceBase: Word;
  Buf: array[0..2047] of Byte;   { a copy of the parameter area, taken
                                   BEFORE anything is printed }
  Rc: Integer;

function Hex2(B: Byte): string;
const H: string[16] = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4 + 1] + H[B and 15 + 1];
end;

function Hex4(W: Word): string;
begin
  Hex4 := Hex2(Hi(W)) + Hex2(Lo(W));
end;

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
var I: Integer; S: string;
begin
  DoUsb := True; DoDisk := False; DoWifi := False; DoHex := False;
  ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then begin
      case UpCase(S[2]) of
        'U': DoUsb := not ((Length(S) > 2) and (S[3] = '-'));
        'D': DoDisk := True;
        'W': DoWifi := True;
        'X': DoHex := True;
        'P': if not ParseHex(Copy(S, 4, 4), ForceBase) then begin
               WriteLn('bad /P= value: ', S); Halt(1);
             end;
      else
        WriteLn('unknown switch ', S); Halt(1);
      end;
    end;
  end;
end;

function InitName(B: Byte): string;
begin
  case B of
    $00: InitName := 'ok';
    $FC: InitName := 'skipped';
    $FD: InitName := 'FAILED';
    $FE: InitName := 'in progress / disabled';
    $FF: InitName := 'disabled';
  else
    InitName := 'code ' + Hex2(B);
  end;
end;

function BoardName(B: Byte): string;
begin
  case B of
    0: BoardName := 'PicoMEM prototype';
    1: BoardName := 'PicoMEM 1';
    2: BoardName := 'PicoMEM LP';
    3: BoardName := 'PicoMEM 1.3';
    4: BoardName := 'PicoMEM 1.4';
    9: BoardName := 'PicoMEM 1.5';
    10: BoardName := 'PicoMEM 2';
    11: BoardName := 'PicoMEM 2, a later id than the published list';
  else
    BoardName := 'unknown';
  end;
end;

{ A NUL-terminated name out of the shared memory, at most Max chars. }
function SharedStr(Ofs: Word; Max: Integer): string;
var S: string; I: Integer; B: Byte;
begin
  S := '';
  for I := 0 to Max - 1 do begin
    B := SharedB(Ofs + I);
    if B = 0 then Break;
    if (B < 32) or (B > 126) then S := S + '.' else S := S + Chr(B);
  end;
  SharedStr := S;
end;

procedure Dump(Ofs, Len: Word; FromBuf: Boolean);
var I, J: Word; B: Byte; A: string;
begin
  I := 0;
  while I < Len do begin
    Write('  ', Hex4(Ofs + I), ': ');
    A := '';
    for J := 0 to 15 do begin
      if FromBuf then B := Buf[I + J] else B := SharedB(Ofs + I + J);
      Write(Hex2(B), ' ');
      if (B < 32) or (B > 126) then A := A + '.' else A := A + Chr(B);
    end;
    WriteLn(' ', A);
    Inc(I, 16);
  end;
end;

{ Copy the parameter area out of the card's memory into Buf. }
procedure TakeParams;
var I: Word;
begin
  for I := 0 to High(Buf) do Buf[I] := SharedB(PmParam + I);
end;

{ The status commands answer with: a line count byte, then that many
  NUL-terminated lines.  The first line's second character is FEh, a
  marker for the BIOS menu -- shown here as a space. }
procedure PrintLines(const Title: string);
var N, L, P: Integer; S: string; B: Byte;
begin
  N := Buf[0];
  WriteLn(Title, ': ', N, ' line(s)');
  P := 1;
  for L := 1 to N do begin
    S := '';
    while (P <= High(Buf)) and (Buf[P] <> 0) do begin
      B := Buf[P];
      if (B < 32) or (B > 126) then S := S + ' ' else S := S + Chr(B);
      Inc(P);
    end;
    Inc(P);
    WriteLn('  |', S);
    if P > High(Buf) then Break;
  end;
end;

procedure Ask(Cmd: Byte; const Title: string);
var R: Byte; Res: Word; T0, T1: LongInt; P: Integer;
begin
  T0 := Ticks;
  R := Command(Cmd, 0, 91, Res);          { 5 s }
  T1 := Ticks;
  if R = CR_OK then TakeParams;           { before any DOS call }
  WriteLn;
  WriteLn('command ', Hex2(Cmd), ' (', CmdName(Cmd), '): ', ResultName(R),
          ', status ', Hex2(PmLastSt), ', result ', Hex4(Res),
          ', ', (T1 - T0) * 55, ' ms');
  if R <> CR_OK then begin Rc := 2; Exit; end;
  if Cmd = CMD_WIFI_INFO then begin
    { the firmware copies its WiFi structure in: SSID at +6, a status
      line at +102 -- the offsets the card's own BIOS menu prints }
    Write('  SSID   : ');
    P := 6; while (P < 100) and (Buf[P] <> 0) do begin Write(Chr(Buf[P])); Inc(P); end;
    WriteLn;
    Write('  status : ');
    P := 102; while (P < 200) and (Buf[P] <> 0) do begin Write(Chr(Buf[P])); Inc(P); end;
    WriteLn;
  end else begin
    PrintLines(Title);
    if Cmd = CMD_USB_STATUS then
    begin
      WriteLn('  (a device line is empty when no driver in the card''s firmware');
      WriteLn('   claimed it -- only HID, mass storage, MIDI and game pads are)');
    end;
  end;
  if DoHex then begin
    WriteLn('  parameter area after it:');
    Dump(PmParam, 128, True);
  end;
end;

{ PMCFG_t.MEM_Map: one byte per 16 KB of the first megabyte, saying what
  the card puts there.  Types from the firmware's dev_memory.h. }
procedure MemMap;
var I: Integer; B: Byte; C: Char;
begin
  WriteLn('  memory map : 0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F');
  Write('               ');     { 15 + 64 = 79: an 80th column would wrap }
  for I := 0 to 63 do begin
    B := SharedB(CFG + 138 + I);
    case B of
      0:  C := '.';     { the card does nothing here }
      1:  C := 'r';     { RAM in the Pico's own SRAM }
      2:  C := 'd';     { the card's BIOS RAM / disk buffer }
      8:  C := 'B';     { the card's BIOS ROM }
      9, 10, 12: C := 'O';  { an option ROM the card serves }
      16: C := 'p';     { RAM in the card's PSRAM }
      17: C := 'e';     { EMS window }
      32: C := 's';     { the PC's own RAM, as the BIOS found it }
      33: C := 'v';     { video RAM }
      34: C := 'o';     { the PC's own ROM }
    else C := '?';
    end;
    Write(C);
  end;
  WriteLn;
  WriteLn('               per 16 KB: s PC RAM  v video  o PC ROM  B card BIOS');
  WriteLn('               d card RAM  r/p RAM the card adds  e EMS');
  WriteLn('               O card option ROM  . nothing');
end;

procedure Config;
var I: Integer; A: Byte;
begin
  WriteLn;
  WriteLn('configuration (as the card holds it):');
  { offsets into the firmware's PMCFG_t }
  WriteLn('  USB host    : ', SharedB(CFG + 210), '   (1 = enabled)');
  WriteLn('  WiFi        : ', SharedB(CFG + 214), '   NE2000 at ', Hex4(SharedW(CFG + 216)),
          'h IRQ ', SharedB(CFG + 215));
  WriteLn('  joystick    : ', SharedB(CFG + 218));
  MemMap;
  for I := 0 to 1 do begin
    A := SharedB(CFG + 96 + I);
    if A >= $80 then
      WriteLn('  floppy ', I, '    : ', SharedStr(CFG + 2 + I * 16, 13),
              '  (', SharedW(CFG + I * 16), ' KB, attr ', Hex2(A), ')');
  end;
  for I := 0 to 3 do begin
    A := SharedB(CFG + 98 + I);
    if A >= $80 then
      WriteLn('  disk ', I, '      : ', SharedStr(CFG + 32 + 2 + I * 16, 13),
              '  (', SharedW(CFG + 32 + I * 16), ' MB, attr ', Hex2(A), ')');
  end;
end;

var
  Bad: Word; P: Integer;

begin
  WriteLn('PMPROBE ', VER, ' -- PicoMEM card probe -- StevenC');
  Rc := 0;
  Args;

  if AskBios then
    WriteLn('BIOS     : answered INT 13h AH=60h -- base ', Hex4(PmBase),
            'h, ROM at ', Hex4(PmRomSeg), 'h, device mask ', Hex4(PmMask), 'h')
  else begin
    WriteLn('BIOS     : no answer to INT 13h AH=60h; trying port ', Hex4(ForceBase), 'h');
    PmBase := ForceBase; PmRomSeg := 0;
  end;

  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('test port: ', Bad, ' of 100 reads out of sequence -- no PicoMEM at ',
            Hex4(PmBase), 'h');
    Halt(1);
  end;
  WriteLn('test port: 100 of 100 reads in sequence -- a PicoMEM is at ', Hex4(PmBase), 'h');
  WriteLn('status   : ', Hex2(Status), ' (', StatusName(PmLastSt), ')');

  if PmRomSeg <> 0 then begin
    Write('ROM      : ', Hex2(Mem[PmRomSeg:0]), ' ', Hex2(Mem[PmRomSeg:1]),
          ', ', Mem[PmRomSeg:2] div 2, ' KB, id "');
    for P := 5 to 10 do Write(Chr(Mem[PmRomSeg:P]));
    WriteLn('"');
  end;

  if not SharedOK then begin
    WriteLn('shared memory: not found (first byte ',
            Hex2(SharedB(0)), ', expected 12)');
    Rc := 3;
  end else begin
    WriteLn('shared memory at ', Hex4(PmRomSeg), ':', Hex4(SHARED_OFS), ':');
    WriteLn('  board       : ', BoardName(SharedB(27)), ' (id ', SharedB(27),
            ', pico id ', SharedB(28), ')');
    WriteLn('  firmware    : revision ', Hex4(SharedW(30)));
    WriteLn('  BIOS starts : ', SharedB(2), ', boot straps ', SharedB(3));
    WriteLn('  PSRAM       : ', InitName(SharedB(4)));
    WriteLn('  SD card     : ', InitName(SharedB(5)));
    WriteLn('  USB host    : ', InitName(SharedB(6)));
    WriteLn('  config file : ', InitName(SharedB(7)));
    WriteLn('  WiFi        : ', InitName(SharedB(8)));
    WriteLn('  base port   : ', InitName(SharedB(9)));
    WriteLn('  USB devices : ', Hex2(SharedB(10)), ' (bit 0 mouse, 1 keyboard, 3 joystick)');
    WriteLn('  IRQ         : ', SharedB(11), ' (mask ', Hex2(SharedB(12)), ')');
    WriteLn('  disks       : ', SharedB(17), ' at boot, ', SharedB(21), ' after mounting; floppies ',
            SharedB(18), ' -> ', SharedB(22));
    WriteLn('  PC memory   : ', SharedW(19), ' KB');
    WriteLn('  running cmd : ', Hex2(SharedB(25)));
    Config;
    if DoHex then begin
      WriteLn;
      WriteLn('shared memory, first 256 bytes:');
      Dump(0, 256, False);
    end;
  end;

  if SharedOK then begin
    if DoUsb or DoDisk or DoWifi then begin
      { where the text answers land moved between firmwares -- find it
        rather than assume, or a PicoMEM 1 reports nothing at all }
      if FindParam then begin
        if PmParam <> PARAM_OFS then
          WriteLn('answers at +', PmParam, ' on this firmware, not +',
                  PARAM_OFS)
      end else
        WriteLn('could not find the answers area; assuming +', PmParam);
    end;
    if DoUsb then Ask(CMD_USB_STATUS, 'USB');
    if DoDisk then Ask(CMD_DISK_STAT, 'disks');
    if DoWifi then Ask(CMD_WIFI_INFO, 'WiFi');
  end;

  WriteLn;
  WriteLn('status now: ', Hex2(Status), ' (', StatusName(PmLastSt), ')');
  Halt(Rc);
end.
