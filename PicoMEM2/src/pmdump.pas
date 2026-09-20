program pmdump;
{ PMDUMP -- save the PicoMEM's ROM and shared memory to a file.
  PicoMEM2 tools, StevenC.  Public domain (the Unlicense).

    PMDUMP [file]          default PMDUMP.BIN

  24 KB: the card's 16 KB BIOS ROM, then its 8 KB of shared memory,
  exactly as the PC sees them.  Nothing is sent to the card.

  The copy is taken into our own memory FIRST and written afterwards,
  because the file write is itself a disk access through the card, and
  the card's disk buffer sits inside that same shared memory. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '0.1.0';
  TOTAL = 16384 + SHARED_LEN;

var
  Buf: PByte;
  F: file;
  Name: string;
  I: Word;

begin
  WriteLn('PMDUMP ', VER, ' -- PicoMEM ROM and shared memory to a file -- StevenC');
  if ParamCount >= 1 then Name := ParamStr(1) else Name := 'PMDUMP.BIN';
  if not AskBios then begin
    WriteLn('The PicoMEM BIOS did not answer INT 13h AH=60h; nothing to dump.');
    Halt(1);
  end;
  if TestPort(PmBase, 100) <> 0 then begin
    WriteLn('No PicoMEM answers the test port at ', PmBase, '.');
    Halt(1);
  end;
  GetMem(Buf, TOTAL);
  for I := 0 to TOTAL - 1 do Buf[I] := Mem[PmRomSeg : I];
  Assign(F, Name);
  {$I-} Rewrite(F, 1); {$I+}
  if IOResult <> 0 then begin WriteLn('cannot create ', Name); Halt(2); end;
  BlockWrite(F, Buf^, TOTAL);
  Close(F);
  WriteLn('ROM segment ', PmRomSeg, ', ', TOTAL, ' bytes to ', Name);
end.
