program chreg;
{ CHREG -- dump the CH375's internal register map.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  Command 0Ah is documented as GET_MAX_LUN and nothing else.  WCH's own DOS
  driver and CH375CHK.C both use it as a general "read one internal byte",
  and it is the only view there is of what the chip believes the USB bus is
  doing.  This reads all 256 of them and annotates the ones whose meaning is
  established by behaviour.

    CHREG [/P=260] [/U] [/W=n] [/D=ms] [/A]

      /P=hex   I/O base, default 260
      /U       bring the USB bus up first.  Without it the chip is read
               exactly as found, which is what you want when another
               program has left it in some state worth looking at
      /W=n     watch: re-read n times and print only what changed
      /D=ms    delay between watch passes, default 250
      /A       annotate every known register, not just the interesting ones

  Reading a register has no side effects, so this is safe to run against a
  chip another program is using -- which is the point of /W.

  Exit codes: 0 ok, 1 no chip }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

var
  Cur, Old: array[0..255] of Byte;
  DoUp:  Boolean = False;
  Watch: Word = 0;
  Gap:   Word = 250;
  AllAnn: Boolean = False;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

{ The names that are established, and only those.  A register whose meaning
  is a guess is better left blank than labelled wrongly -- a wrong label
  outlives the guess. }
function RegName(A: Byte): ShortString;
begin
  case A of
    $07: RegName := 'USB misc status / device rate';
    $17: RegName := 'bus speed control';
    $1C: RegName := 'SOF generator (40 = running)';
    $20: RegName := 'USB status mirror';
    $25: RegName := 'retry setting';
  else
    RegName := '';
  end;
end;

{ Register 07h is the one worth spelling out in full: it is how you tell an
  attached low-speed device from an attached full-speed one, and it is what
  the low-speed switch in the driver keys off. }
procedure Explain07(V: Byte);
begin
  WriteLn('  reg 07 = ', Hex2(V), '  USB misc status');
  WriteLn('    bit0 device attached  : ', V and 1);
  WriteLn('    bit1 D- line level    : ', (V shr 1) and 1);
  WriteLn('    bit2 suspend          : ', (V shr 2) and 1);
  WriteLn('    bit3 bus reset        : ', (V shr 3) and 1);
  WriteLn('    bit4 low speed device : ', (V shr 4) and 1,
          '   (1 = 1.5 Mbps)');
  WriteLn('    bit5 SIE free         : ', (V shr 5) and 1);
  WriteLn('    bit6 SOF active       : ', (V shr 6) and 1);
  WriteLn('    bit7 SOF present      : ', (V shr 7) and 1);
end;

procedure ReadAll(var B: array of Byte);
var I: Integer;
begin
  for I := 0 to 255 do B[I] := GetReg(Byte(I));
end;

procedure DumpAll(var B: array of Byte);
var
  I, J: Integer;
  S, A: ShortString;
  C: Char;
begin
  WriteLn('       00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F');
  I := 0;
  while I < 256 do
  begin
    S := '  ' + Hex2(Byte(I)) + '   ';
    A := '';
    for J := 0 to 15 do
    begin
      S := S + Hex2(B[I + J]) + ' ';
      if J = 7 then S := S + ' ';
      C := Chr(B[I + J]);
      if (B[I + J] < 32) or (B[I + J] > 126) then C := '.';
      A := A + C;
    end;
    WriteLn(S, '|', A, '|');
    Inc(I, 16);
  end;
end;

procedure ShowNamed(var B: array of Byte);
var I: Integer;
begin
  WriteLn;
  WriteLn('named registers');
  for I := 0 to 255 do
    if RegName(Byte(I)) <> '' then
      if AllAnn or (B[I] <> 0) then
        WriteLn('  ', Hex2(Byte(I)), ' = ', Hex2(B[I]), '  ', RegName(Byte(I)));
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/U') or (A = '-U') then DoUp := True
    else if (A = '/A') or (A = '-A') then AllAnn := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/W=' then begin Val(A, V, Code); if Code = 0 then Watch := Word(V); end
      else if K = '/D=' then begin Val(A, V, Code); if Code = 0 then Gap := Word(V); end;
    end;
  end;
end;

procedure Usage;
begin
  Banner('CHREG', VER, 'dump the CH375 internal register map');
  WriteLn;
  WriteLn('  CHREG [/P=260] [/U] [/W=n] [/D=ms] [/A]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /U       bring the USB bus up first.  Without it the chip is');
  WriteLn('           read exactly as found, which is what you want when');
  WriteLn('           another program has left it somewhere interesting');
  WriteLn('  /W=n     watch: re-read n times and print only what changed');
  WriteLn('  /D=ms    delay between watch passes, default 250');
  WriteLn('  /A       annotate every known register, not just interesting');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Command 0Ah is documented only as GET_MAX_LUN.  WCH''s own DOS');
  WriteLn('driver uses it as a general "read one internal byte", and it is');
  WriteLn('the only view there is of what the chip believes the USB bus is');
  WriteLn('doing.  Registers C0-FF are the chip''s 64-byte data buffer:');
  WriteLn('run CHREG after a transfer and the descriptor is still in it.');
  WriteLn;
  WriteLn('Reading a register has no side effects, so this is safe against');
  WriteLn('a chip another program is using -- which is the point of /W.');
  HelpTail;
end;

var
  Rc, I, N: Integer;
  Changed: Integer;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('CHREG', VER, 'CH375 internal register map');

  if DoUp then
  begin
    Rc := BusUp;
    WriteLn('bring-up: ', BusUpReason(Rc));
    if Rc = BU_NO_CHIP then Halt(1);
  end
  else
  begin
    if not ChipHere(Base) then
    begin
      WriteLn('No CH375 responds at ', Hex4(Base), 'h.');
      WriteLn('USBSCAN finds the card if it is somewhere else.');
      Halt(1);
    end;
    WrCmd(CMD_GET_IC_VER); IcVer := RdDat;
  end;

  WriteLn('chip ', Hex2(IcVer), ' at ', Hex4(Base), 'h');
  WriteLn;
  ReadAll(Cur);
  DumpAll(Cur);
  ShowNamed(Cur);
  WriteLn;
  Explain07(Cur[$07]);

  if Watch = 0 then Halt(0);

  WriteLn;
  WriteLn('watching for changes, ', Watch, ' passes ', Gap, ' ms apart');
  for N := 1 to Watch do
  begin
    for I := 0 to 255 do Old[I] := Cur[I];
    DelayMs(Gap);
    ReadAll(Cur);
    Changed := 0;
    for I := 0 to 255 do
      if Cur[I] <> Old[I] then
      begin
        if Changed = 0 then Write('  pass ', N, ':');
        Inc(Changed);
        Write('  ', Hex2(Byte(I)), ' ', Hex2(Old[I]), '->', Hex2(Cur[I]));
      end;
    if Changed > 0 then WriteLn;
  end;
  WriteLn('done.');
  Halt(0);
end.
