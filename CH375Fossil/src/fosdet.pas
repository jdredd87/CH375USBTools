program fosdet;

{ FOSDET -- is a FOSSIL driver installed, and what does it say about itself?

  Safe to run with NO driver installed, and that is the point: this is the
  negative control for the whole project, and it is worth having working
  before there is anything to detect.

  It makes ZERO INT 14h calls unless the in-memory signature is already
  there, and that order is deliberate rather than cautious. The BIOS INT 14h
  defines AH=00h..03h and nothing else, so calling AH=04h to ask "is a
  FOSSIL present?" on a machine that has none is a call into undefined
  territory in somebody else's ROM. FSC-0015 puts a signature in memory
  precisely so the question can be asked without making the call: the word
  1954h at offset 6 of the handler, with the highest supported function
  number in the byte after it.

  So: read the vector, look at +6, and only then talk to it. }

uses Dos, chtool, fosapi;

const
  VER = '0.1.0';

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

const
  HexDig : array[0..15] of Char = '0123456789ABCDEF';

  { Top three bits of the AH=00h baud byte. }
  BaudName : array[0..7] of ShortString =
    ('19200', '38400', '300', '600', '1200', '2400', '4800', '9600');

var
  VecSeg, VecOfs : Word;
  Sig            : Word;
  MaxFunc        : Byte;
  HaveSig        : Boolean;
  R              : Registers;
  Info           : TFosInfo;
  Ident          : ShortString;
  I              : Word;
  B              : Byte;

function HexW(W: Word): ShortString;
begin
  HexW := HexDig[(W shr 12) and 15] + HexDig[(W shr 8) and 15] +
          HexDig[(W shr 4) and 15] + HexDig[W and 15];
end;

function HexB(V: Byte): ShortString;
begin
  HexB := HexDig[(V shr 4) and 15] + HexDig[V and 15];
end;

begin
  Banner('FOSDET', VER, 'is a FOSSIL driver installed?');

  { The IVT entry for INT 14h lives at 0000:0050. Read it directly rather
    than through GetIntVec, so the segment and offset stay separate words. }
  VecOfs := MemW[0 : $14 * 4];
  VecSeg := MemW[0 : $14 * 4 + 2];
  Note('INT 14h vector: ' + HexW(VecSeg) + ':' + HexW(VecOfs) + 'h');

  Check('INT 14h vector is not null', (VecSeg <> 0) or (VecOfs <> 0));

  Sig     := MemW[VecSeg : VecOfs + 6];
  MaxFunc := Mem [VecSeg : VecOfs + 8];
  HaveSig := (Sig = $1954);

  Note('signature at handler+6: ' + HexW(Sig) + 'h  (a FOSSIL says 1954h)');

  if not HaveSig then
  begin
    { The negative control. Nothing is wrong here -- no driver is loaded,
      we spotted that from memory alone, and we did not call AH=04h to
      find out. }
    Note('no FOSSIL driver is installed');
    Check('detection declined to call INT 14h AH=04h with no driver present',
          True);
    Note('load the driver, then run FOSDET again');
    Finish;
    Halt(Failures);
  end;

  Note('highest function supported, from the signature: ' +
       HexB(MaxFunc) + 'h');

  { Now it is safe to ask properly. AH=04h, DX = port. }
  FillChar(R, SizeOf(R), 0);
  R.AH := $04;
  R.DX := 0;
  R.BX := $4F50;
  Intr($14, R);

  Note('AH=04h returned AX=' + HexW(R.AX) + 'h  BL=' + HexB(R.BL) +
       'h  BH=' + HexB(R.BH) + 'h');
  Check('AH=04h identifies as a FOSSIL (AX=1954h)', R.AX = $1954);
  Check('the two maximum-function reports agree', R.BL = MaxFunc);
  Check('block read/write (18h/19h) are supported', MaxFunc >= $19);
  Check('driver information (1Bh) is supported', MaxFunc >= $1B);

  if MaxFunc >= $1B then
  begin
    FillChar(Info, SizeOf(Info), 0);
    FillChar(R, SizeOf(R), 0);
    R.AH := $1B;
    R.CX := SizeOf(Info);
    R.DX := 0;
    R.ES := Seg(Info);
    R.DI := Ofs(Info);
    Intr($14, R);

    Note('AH=1Bh transferred bytes:', R.AX);
    Check('AH=1Bh returned a whole structure', R.AX >= 19);

    if R.AX >= 19 then
    begin
      Note('spec level:', Info.MajVer);
      Note('driver revision:', Info.MinVer);
      Note('input buffer, bytes:', Info.IBufr);
      Note('  free:', Info.IFree);
      Note('output buffer, bytes:', Info.OBufr);
      Note('  free:', Info.OFree);
      Note('baud: ' + BaudName[(Info.Baud shr 5) and 7]);

      Check('input buffer is big enough to cover a missed poll',
            Info.IBufr >= 1024);
      Check('free never exceeds total, input', Info.IFree <= Info.IBufr);
      Check('free never exceeds total, output', Info.OFree <= Info.OBufr);

      { The identifier is an asciiz string somewhere else entirely. }
      Ident := '';
      I := 0;
      while I < 64 do
      begin
        B := Mem[Info.IdSeg : Info.IdOfs + I];
        if B = 0 then I := 64
        else
        begin
          if (B >= 32) and (B < 127) then Ident := Ident + Chr(B);
          Inc(I);
        end;
      end;
      Note('identifier: ' + Ident);
      Check('the driver names itself', Length(Ident) > 0);
    end;
  end;

  Finish;
end.
