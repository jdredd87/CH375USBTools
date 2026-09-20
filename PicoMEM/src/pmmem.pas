program pmmem;
{ PMMEM -- what the card has mapped over each 16 KB of the first
  megabyte, LIVE, next to what it was configured to map.
  PicoMEM tools, StevenC.  Public domain (the Unlicense).

    PMMEM [/1] [/W] [/P=2A0]

  The card answers command 05h with the type of memory it is emulating
  over a 16 KB block.  Its handler reads a table and returns: it writes
  nothing, mounts nothing and opens no file, which is why it is the one
  command this collection allows beyond the three status queries (see
  pmcard.pas).  The configured map in the shared memory is what the
  card was TOLD to do; this is what it is doing.

    /1   send one command only, for block 52 (D000h, the card's own
         BIOS), and stop.  The careful first run on a new firmware
    /W   also test each block from the PC side by writing one byte and
         putting it straight back, to tell RAM from ROM from nothing.
         Only C000h and above, and never the card's own window:
         below C000h is the PC's own RAM with DOS and this program in
         it, block 0 is the interrupt vector table, and the card's
         shared memory starts with the marker its BIOS checks. In all
         three a byte wrong for a microsecond is a machine that stops
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  Exit code: 0 read, 1 no card, 2 the command failed, 3 no shared
  memory. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '1.0.0';
  C_MEMMAP = 138;        { the configured map, inside the config block }
  BIOSBLK  = 52;         { D0000h: where this card's own BIOS sits }

var
  One, DoWrite: Boolean;
  ForceBase: Word;
  Live: array[0..63] of Byte;
  Got:  array[0..63] of Boolean;
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
  One := False; DoWrite := False; ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        '1': One := True;
        'W': DoWrite := True;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
end;

function BlockSeg(B: Byte): Word;
begin
  BlockSeg := Word(B) * $400;      { 16 KB is 400h paragraphs }
end;

{ What does the PC see at this block?  Read-only unless /W: a ROM
  signature is conclusive on its own, and everything else needs a
  write to tell RAM from a dead address. }
function PcSees(B: Byte): Char;
var Sg: Word; Old, T: Byte; Same: Boolean;
begin
  Sg := BlockSeg(B);
  if MemW[Sg : 0] = $AA55 then begin PcSees := 'R'; Exit; end;

  if not DoWrite then begin PcSees := '?'; Exit; end;
  { never write below C000h: that is the PC's own RAM, this program is
    in it, and block 0 holds the interrupt vectors }
  if B < 48 then begin PcSees := '-'; Exit; end;
  { and never into the card's own 32 KB window.  Its second half is the
    shared memory, whose first byte is the validity marker its BIOS
    checks -- putting it back a microsecond later is not good enough on
    the card this machine boots from }
  if (PmRomSeg <> 0) and (Sg >= PmRomSeg) and (Sg < PmRomSeg + $800) then
    begin PcSees := 'B'; Exit; end;

  Old := Mem[Sg : 0];
  Mem[Sg : 0] := Old xor $FF;
  T := Mem[Sg : 0];
  Same := T = Old xor $FF;
  Mem[Sg : 0] := Old;
  if Same and (Mem[Sg : 0] = Old) then PcSees := 'w'      { writable }
  else if Old = $FF then PcSees := '.'                    { nothing there }
  else PcSees := 'o';                                     { reads, will not take a write }
end;

function AskBlock(B: Byte; out T: Byte): Byte;
var Res: Word; R: Byte;
begin
  Res := 0;
  R := Command(CMD_MEMTYPE, B, 91, Res);
  T := Hi(Res);
  AskBlock := R;
end;

var
  Bad: Word;
  I: Integer;
  B, T: Byte;
  R: Byte;
  Row: string;
  Diff: Integer;
begin
  Args;
  WriteLn('PMMEM ', VER, ' -- the card''s memory map, live and configured');
  Rc := 0;

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h (', Bad,
            ' of 100 test-port reads out of sequence)');
    Halt(1);
  end;

  { The careful first question: one block whose answer is known.  This
    card's own BIOS is at D000h, so block 52 must come back as the card
    BIOS -- if command 05h means something else on a firmware, this is
    where it shows, with one command sent instead of sixty-four. }
  R := AskBlock(BIOSBLK, T);
  WriteLn('block ', BIOSBLK, ' (', Hex4(BlockSeg(BIOSBLK)), 'h, where this ',
          'card''s BIOS is): ', ResultName(R));
  if R <> CR_OK then begin
    WriteLn('  the card would not answer command 05h -- stopping here.');
    Halt(2);
  end;
  WriteLn('  type ', T, ' = ', MemTypeName(T));
  if (T <> MT_BIOS) and (T <> MT_BIOSX) then begin
    WriteLn('  THAT IS NOT THE CARD BIOS.  Command 05h does not mean what');
    WriteLn('  this tool thinks on this firmware; nothing else will be sent.');
    Halt(2);
  end;
  if One then Halt(0);

  for I := 0 to 63 do begin
    R := AskBlock(I, T);
    Got[I] := R = CR_OK;
    if Got[I] then Live[I] := T else begin Live[I] := 0; Rc := 2; end;
  end;

  WriteLn;
  WriteLn('             0   1   2   3   4   5   6   7   8   9   A   B   ',
          'C   D   E   F');
  Row := '';
  for I := 0 to 63 do
    if Got[I] then Row := Row + MemTypeChar(Live[I]) else Row := Row + '!';
  WriteLn('  live       ', Row);
  Row := '';
  for I := 0 to 63 do Row := Row + MemTypeChar(SharedB(CFG_OFS + C_MEMMAP + I));
  WriteLn('  configured ', Row);
  if DoWrite then begin
    Row := '';
    for I := 0 to 63 do Row := Row + PcSees(I);
    WriteLn('  the PC sees', Row);
  end;
  WriteLn('  each cell is 16 KB; the column heading is the high nibble of',
          ' the segment');
  WriteLn('  . nothing   r card RAM   d card BIOS RAM   B card BIOS   p PSRAM');
  WriteLn('  e EMS   s the PC own RAM   v video   o the PC own ROM');
  if DoWrite then
    WriteLn('  the PC sees: R option ROM  w writable  o reads, will not take',
            ' a write');
  if DoWrite then
    WriteLn('               . reads as FFh   - not written to   B the card',
            ' itself');

  WriteLn;
  Diff := 0;
  for I := 0 to 63 do
    if Got[I] and (Live[I] <> MT_NULL) then Inc(Diff);
  WriteLn('the card emulates ', Diff, ' of the 64 blocks:');
  for I := 0 to 63 do
    if Got[I] and (Live[I] <> MT_NULL) then
      WriteLn('  ', Hex4(BlockSeg(I)), 'h  ', MemTypeName(Live[I]));
  WriteLn('everything else in that megabyte is the PC''s own, which is why');
  WriteLn('the two rows look so unlike each other: the configured map holds');
  WriteLn('s, v and o for the PC''s RAM, video and ROM -- a description of');
  WriteLn('the machine, not a request to the card.');

  { Only the blocks the card was ASKED to emulate can be said to
    disagree.  Codes 32 and up in the configured map describe the PC. }
  WriteLn;
  Diff := 0;
  for I := 0 to 63 do begin
    B := SharedB(CFG_OFS + C_MEMMAP + I);
    if B >= MT_SRAM then B := MT_NULL;
    if Got[I] and (Live[I] <> B) then begin
      if Diff = 0 then
        WriteLn('blocks where the card is not doing what it was configured to:');
      WriteLn('  ', Hex4(BlockSeg(I)), 'h  live ', MemTypeName(Live[I]),
              ' / configured ', MemTypeName(SharedB(CFG_OFS + C_MEMMAP + I)));
      Inc(Diff);
    end;
  end;
  if Diff = 0 then
    WriteLn('the card is doing exactly what it was configured to do.');

  Halt(Rc);
end.
