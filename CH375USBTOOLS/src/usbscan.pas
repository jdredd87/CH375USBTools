program usbscan;
{ USBSCAN -- find CH375 boards in the ISA I/O space.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  Answers "what address is the card at", which is the question every other
  tool in the suite assumes you already know.  CHECK_EXIST sends 55h and a
  CH375 answers with the ones-complement, AAh; nothing else does, so the
  test is specific enough to sweep with.

    USBSCAN [/P=hex] [/D] [/A] [/F=hex] [/T=hex] [/S=hex] [/FORCE]

      /P=hex   test ONLY this address and stop.  For when the jumpers are
               already known, or the board sits somewhere the default list
               does not cover
      /D       also say what is attached to each card found
      /A       try every 16-byte boundary in the sweep range, not just the
               addresses a CH375 board is normally jumpered to
      /F=hex   first base of the /A sweep, default 200
      /T=hex   last base, default 380
      /S=hex   step, default 10
      /FORCE   do not skip the addresses in the reserved list below.
               Read the next paragraph before using it

  READ THIS BEFORE WIDENING THE SWEEP.  Probing an address means WRITING a
  byte to it: CHECK_EXIST sends 55h to base+1 and reads base+0.  On a real
  ISA machine most addresses belong to something, and a stray write to the
  wrong one does not politely return an error -- it hangs the machine.  That
  is not hypothetical; it is what the first version of this program did, by
  sweeping 200h to 3F0h blind and writing into the floppy controller at
  3F0h on the way past.

  So the default is a short list of addresses a CH375 ISA board is actually
  jumpered to, and even /A skips a reserved list:

      1F0 170  IDE            2F8 3F8  COM2, COM1
      278 378  LPT2, LPT1     3F0      floppy controller
      320 330  disk, MPU-401  300 310  network cards

  260h -- the CH375's own default -- is on nobody's reserved list here, but
  it is a common NE2000 address too.  There is no way to test for a CH375
  without writing, so if this machine has a card there, that is the one
  risk the suite cannot design away.

  Exit codes: 0 at least one card found, 1 none }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

const
  { Where a CH375 ISA board is normally jumpered.  Short, and every one of
    them chosen because a board can actually sit there. }
  NCAND = 8;
  Cand: array[0..NCAND - 1] of Word =
    ($260, $250, $240, $230, $220, $210, $200, $290);

  { Addresses a probe write must not touch.  Each is the base of a device
    whose registers react to being written to. }
  NRES = 12;
  Reserved: array[0..NRES - 1] of Word =
    ($1F0, $170, $278, $378, $2F8, $3F8, $3F0, $320, $330, $300, $310, $370);

var
  First: Word = $200;
  Last:  Word = $380;
  Step:  Word = $10;
  { /P=hex: test this one address instead of sweeping anything.  Zero means
    no /P was given -- 0000h is not a base a board can sit at, so it makes
    a safe "unset". }
  Only:  Word = 0;
  Deep:  Boolean = False;
  Sweep: Boolean = False;
  Force: Boolean = False;

{ True if a 16-byte window starting at P overlaps anything on the reserved
  list.  The window matters, not just the base: CHECK_EXIST writes base+1,
  so a base of 3F0 reaches into the floppy controller's registers. }
function IsReserved(P: Word): Boolean;
var I: Integer;
begin
  IsReserved := False;
  for I := 0 to NRES - 1 do
    if (Reserved[I] >= P) and (Reserved[I] < P + 8) then
    begin
      IsReserved := True; Exit;
    end;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/D') or (A = '-D') then Deep := True
    else if (A = '/A') or (A = '-A') then Sweep := True
    else if (A = '/FORCE') or (A = '-FORCE') then Force := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      Val('$' + A, V, Code);
      if Code <> 0 then Continue;
      if      K = '/P=' then Only  := Word(V)
      else if K = '/F=' then First := Word(V)
      else if K = '/T=' then Last  := Word(V)
      else if K = '/S=' then Step  := Word(V);
    end;
  end;
  if Step = 0 then Step := $10;
end;

procedure Usage;
begin
  Banner('USBSCAN', VER, 'find CH375 boards in the ISA I/O space');
  WriteLn;
  WriteLn('  USBSCAN [/P=hex] [/D] [/A] [/F=hex] [/T=hex] [/S=hex] [/FORCE]');
  WriteLn;
  WriteLn('  /P=hex   test ONLY this address and stop.  For when the');
  WriteLn('           jumpers are already known, or the board sits');
  WriteLn('           somewhere the default list does not cover');
  WriteLn('  /D       also say what is attached to each card found');
  WriteLn('  /A       try every 16-byte boundary in the sweep range, not');
  WriteLn('           just the addresses a board is normally jumpered to');
  WriteLn('  /F=hex   first base of the /A sweep, default 200');
  WriteLn('  /T=hex   last base, default 380');
  WriteLn('  /S=hex   step, default 10');
  WriteLn('  /FORCE   do not skip the reserved addresses.  Read below');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('READ THIS BEFORE WIDENING THE SWEEP.  Probing an address means');
  WriteLn('WRITING to it: CHECK_EXIST sends 55h to base+1 and reads base.');
  WriteLn('On a real ISA machine most addresses belong to something, and a');
  WriteLn('stray write does not politely return an error -- it hangs the');
  WriteLn('machine.  That is not hypothetical: it is what the first version');
  WriteLn('of this program did, writing into the floppy controller at 3F0h.');
  WriteLn;
  WriteLn('So the default is a short list of addresses a CH375 board is');
  WriteLn('actually jumpered to, and even /A skips a reserved list:');
  WriteLn('  1F0 170 IDE   2F8 3F8 COM   278 378 LPT   3F0 floppy');
  WriteLn('  320 330 disk, MPU-401       300 310 network');
  WriteLn;
  WriteLn('Every other tool in the suite takes /P=hex for the base, and');
  WriteLn('the three drivers take @hex.  This is the program that tells');
  WriteLn('you what to put there.');
  HelpTail;
end;

var
  P: LongInt;
  Found: Integer = 0;
  Skipped: Integer = 0;
  Rc, Idx: Integer;
  V: Byte;
  AtPort: Word;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('USBSCAN', VER, 'looking for CH375 boards');
  if Only <> 0 then
    WriteLn('testing ', Hex4(Only), 'h only')
  else if Sweep then
    WriteLn('sweeping ', Hex4(First), 'h to ', Hex4(Last), 'h step ',
            Hex4(Step), 'h')
  else
    WriteLn('trying the ', NCAND, ' addresses a CH375 board is normally',
            ' jumpered to');
  if Force then WriteLn('/FORCE: the reserved list is being ignored');
  WriteLn;

  Idx := 0;
  P := First;
  while True do
  begin
    { /P= is one address and then done.  Idx doubles as the "have I already
      done it" flag, which is why it is still incremented here. }
    if Only <> 0 then
    begin
      if Idx > 0 then Break;
      AtPort := Only;
      Inc(Idx);
    end
    else if Sweep then
    begin
      if P > LongInt(Last) then Break;
      AtPort := Word(P);
      Inc(P, Step);
    end
    else
    begin
      if Idx >= NCAND then Break;
      AtPort := Cand[Idx];
      Inc(Idx);
    end;

    if (not Force) and IsReserved(AtPort) then
    begin
      WriteLn('  ', Hex4(AtPort), 'h  skipped -- reserved for another device');
      Inc(Skipped);
      Continue;
    end;

    if ChipHere(AtPort) then
    begin
      Inc(Found);
      WrCmd(CMD_GET_IC_VER); V := RdDat;
      Write('  ', Hex4(AtPort), 'h  CH375 rev ', Hex2(V));
      if (V < $B5) or (V >= $C0) then
        Write('  -- older than B5; this suite needs B5 or later')
      else
        Write('  -- usable');
      WriteLn;

      if Deep then
      begin
        Base := AtPort;
        Rc := BusUp;
        if Rc = BU_OK then
        begin
          WriteLn('            attached: ',
                  Hex4(DevDesc[8] or (Word(DevDesc[9]) shl 8)), ':',
                  Hex4(DevDesc[10] or (Word(DevDesc[11]) shl 8)),
                  '  ', ClassName(DevDesc[4], DevDesc[5], DevDesc[6]));
          if LowSpeed then WriteLn('            low speed (1.5 Mbps)')
                      else WriteLn('            full speed (12 Mbps)');
        end
        else
          WriteLn('            ', BusUpReason(Rc));
      end;
    end;
  end;

  WriteLn;
  if Skipped > 0 then
    WriteLn(Skipped, ' address(es) skipped as reserved.');
  if Found = 0 then
  begin
    if Only <> 0 then
    begin
      WriteLn('No CH375 at ', Hex4(Only), 'h.');
      WriteLn('Run USBSCAN with no switches to try the usual addresses.');
    end
    else
    begin
      WriteLn('No CH375 found.');
      WriteLn('The board''s address is set by jumpers, and 260h is only');
      WriteLn('the usual choice.  If you know where yours is, USBSCAN');
      WriteLn('/P=hex tests just that one address.  /A sweeps every');
      WriteLn('16-byte boundary instead -- but read /? first: probing an');
      WriteLn('address means writing to it, and most addresses on an ISA');
      WriteLn('bus belong to something that will not enjoy it.');
    end;
    Halt(1);
  end;
  WriteLn(Found, ' board(s) found.  Every other tool takes /P=hex.');
  Halt(0);
end.
