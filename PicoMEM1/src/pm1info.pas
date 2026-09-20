program pm1info;
{ PM1INFO -- what is this PicoMEM 1, and how did it come up?
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1INFO [/Q] [/X] [/P=2A0]

  Read-only apart from ONE command: the disk-status query, which is how
  the parameter area is located (pm1card.pas says why it has to be).

    /Q   do not send anything at all -- then the answers area is not
         located, and everything printed comes from memory reads
    /X   also hex dump the 32 BIOS variables
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  Exit code: 0 the card answered, 1 no card, 3 no shared memory. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.0.0';

var
  Quiet, DoHex: Boolean;
  ForceBase: Word;
  Rc: Integer;

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
  Quiet := False; DoHex := False; ForceBase := $2A0;
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

{ An init byte: 00 done, FC skipped or failed, FD in progress or a
  failure reported later, FF disabled.  Anything else is the firmware
  using the byte for something of its own. }
function InitName(B: Byte): string;
begin
  case B of
    $00: InitName := 'ok';
    $FC: InitName := 'SKIPPED or error';
    $FD: InitName := 'FAILED (or still in progress)';
    $FF: InitName := 'disabled';
  else
    InitName := 'code ' + Hex2(B);
  end;
end;

{ The card BIOS carries its build date as "(Date yyyy-mm-dd)" in the
  first part of the ROM.  Found rather than assumed: the offset differs
  between builds. }
function RomDate: string;
var I, J: Word; S: string; C: Char;
begin
  RomDate := '';
  if PmRomSeg = 0 then Exit;
  for I := 0 to 1023 do
    if (Mem[PmRomSeg : I] = Ord('(')) and
       (Mem[PmRomSeg : I + 1] = Ord('D')) and
       (Mem[PmRomSeg : I + 2] = Ord('a')) and
       (Mem[PmRomSeg : I + 3] = Ord('t')) and
       (Mem[PmRomSeg : I + 4] = Ord('e')) then begin
      S := '';
      for J := I + 6 to I + 15 do begin
        C := Chr(Mem[PmRomSeg : J]);
        if (C < ' ') or (C > '~') or (C = ')') then Break;
        S := S + C;
      end;
      RomDate := S;
      Exit;
    end;
end;

function RomName: string;
var I: Word; S: string; C: Char;
begin
  S := '';
  if PmRomSeg <> 0 then
    for I := 4 to 20 do begin
      C := Chr(Mem[PmRomSeg : I]);
      if (C >= 'A') and (C <= 'Z') then S := S + C
      else if S <> '' then Break;
    end;
  RomName := S;
end;

procedure ShowIds;
var B, P: Byte; W: Word;
begin
  B := SharedB(27); P := SharedB(28); W := SharedW(30);
  if (B = 0) and (P = 0) and (W = 0) then begin
    WriteLn('  board       : not reported by this firmware (all three id',
            ' bytes are 0)');
    WriteLn('                a PicoMEM 1 with a BIOS older than the ids;',
            ' see README');
  end else begin
    Write('  board       : id ', B);
    case B of
      0: Write(' (prototype)');
      1: Write(' (PicoMEM 1)');
      2: Write(' (PicoMEM 1.0 to 1.14)');
      3: Write(' (PicoMEM 1.3)');
      4: Write(' (PicoMEM 1.4)');
      9: Write(' (PicoMEM 1.5)');
     10: Write(' (PicoMEM 2)');
    end;
    WriteLn(', pico id ', P);
    WriteLn('  firmware    : revision ', Hex4(W));
  end;
end;

procedure ShowVars;
begin
  ShowIds;
  WriteLn('  BIOS starts : ', SharedB(2), '   boot straps : ', SharedB(3));
  WriteLn('  PSRAM       : ', InitName(SharedB(4)),
          '   SD card : ', InitName(SharedB(5)));
  WriteLn('  USB host    : ', InitName(SharedB(6)),
          '   config file : ', InitName(SharedB(7)));
  WriteLn('  WiFi        : ', InitName(SharedB(8)),
          '   base port : ', InitName(SharedB(9)));
  WriteLn('  USB devices : ', Hex2(SharedB(10)),
          '  (bit 0 mouse, 1 keyboard, 3 joystick)');
  WriteLn('  IRQ         : ', SharedB(11), '   bytes 12-16: ',
          Hex2(SharedB(12)), ' ', Hex2(SharedB(13)), ' ', Hex2(SharedB(14)),
          ' ', Hex2(SharedB(15)), ' ', Hex2(SharedB(16)));
  WriteLn('  disks       : ', SharedB(17), ' at boot -> ', SharedB(21),
          ' mounted;  floppies ', SharedB(18), ' -> ', SharedB(22));
  WriteLn('  PC memory   : ', SharedW(19), ' KB');
  WriteLn('  Tandy       : mode ', SharedB(23), ', ', SharedB(24),
          ' blocks of 16 KB');
  WriteLn('  running cmd : ', Hex2(SharedB(25)), ', source ',
          Hex2(SharedB(26)));
end;

procedure HexVars;
var I: Word; S: string;
begin
  WriteLn;
  WriteLn('BIOS variables, raw:');
  S := '';
  for I := 0 to 31 do begin
    S := S + Hex2(SharedB(I)) + ' ';
    if (I and 15) = 15 then begin
      WriteLn('  +', I - 15:2, '  ', S);
      S := '';
    end;
  end;
end;

var
  Bad: Word;
  S: string;
begin
  Args;
  WriteLn('PM1INFO ', VER, ' -- a PicoMEM 1 card, as DOS can see it');

  if AskBios then
    WriteLn('BIOS      : answered -- base ', Hex4(PmBase), 'h, ROM ',
            Hex4(PmRomSeg), 'h, devices ', Hex4(PmMask), 'h')
  else begin
    PmBase := ForceBase;
    WriteLn('BIOS      : no answer to INT 13h AH=60h; trying base ',
            Hex4(PmBase), 'h');
  end;

  Bad := TestPort(PmBase, 100);
  if Bad = 0 then
    WriteLn('test port : 100 of 100 reads in sequence -- a PicoMEM is at ',
            Hex4(PmBase), 'h')
  else begin
    WriteLn('test port : ', Bad, ' of 100 reads out of sequence at ',
            Hex4(PmBase), 'h -- NOT a PicoMEM');
    Halt(1);
  end;

  WriteLn('status    : ', Hex2(Status), ' (', StatusName(PmLastSt), ')');

  if PmRomSeg <> 0 then begin
    Write('ROM       : ');
    if MemW[PmRomSeg : 0] = $AA55 then
      Write(Mem[PmRomSeg : 2] * 512 div 1024, ' KB, signature ok')
    else
      Write('no 55 AA signature');
    S := RomName;
    if S <> '' then Write(', "', S, '"');
    WriteLn;
    S := RomDate;
    if S <> '' then WriteLn('BIOS date : ', S, '  (from the ROM itself)');
  end;

  Rc := 0;
  if not SharedOK then begin
    WriteLn;
    WriteLn('shared memory: NOT readable at ', Hex4(PmRomSeg),
            ':4000 (first byte is not 12h)');
    Halt(3);
  end;

  WriteLn;
  WriteLn('shared memory at ', Hex4(PmRomSeg), ':4000:');
  ShowVars;
  if DoHex then HexVars;

  WriteLn;
  if Quiet then
    WriteLn('answers   : not looked for (/Q -- nothing was sent to the card)')
  else if FindParam then begin
    Write('answers   : the parameter area is at +', PmParam);
    if PmParam = PARAM_2025 then Write('  (the 2025-11-02 firmware)')
    else if PmParam = PARAM_2026 then Write('  (the 2026-06-16 firmware)');
    WriteLn;
    if PmParamN > 1 then
      WriteLn('            ', PmParamN, ' candidates seen; the lowest is ',
              'the live one, the rest are stale');
  end else begin
    WriteLn('answers   : the parameter area was NOT found.  The disk query',
            ' either');
    WriteLn('            failed or this firmware lays the answer out some',
            'other way.');
    Rc := 2;
  end;

  Halt(Rc);
end.
