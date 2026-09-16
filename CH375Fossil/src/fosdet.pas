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

const
  { Top three bits of the AH=00h baud byte. }
  BaudName : array[0..7] of ShortString =
    ('19200', '38400', '300', '600', '1200', '2400', '4800', '9600');

var
  Top            : Byte;
  R              : Registers;
  Blk            : TFosInfo;
  Ident          : ShortString;
  I              : Word;
  B              : Byte;

begin
  Banner('FOSDET', VER, 'is a FOSSIL driver installed?');

  Note('INT 14h vector: ' + HexW(VecSeg) + ':' + HexW(VecOfs) + 'h');
  Check('INT 14h vector is not null', (VecSeg <> 0) or (VecOfs <> 0));

  Note('signature at handler+6: ' +
       HexW(MemW[VecSeg : VecOfs + 6]) + 'h  (a FOSSIL says 1954h)');

  if not Present then
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

  Top := MaxFunc;
  Note('highest function supported, from the signature: ' +
       HexB(Top) + 'h');

  { Now it is safe to ask properly. AH=04h, DX = port. }
  InitRegs(R);

  Note('AH=04h returned AX=' + HexW(R.AX) + 'h  BL=' + HexB(R.BL) +
       'h  BH=' + HexB(R.BH) + 'h');
  Check('AH=04h identifies as a FOSSIL (AX=1954h)', R.AX = $1954);
  Check('the two maximum-function reports agree', R.BL = Top);
  Check('block read/write (18h/19h) are supported', Top >= $19);
  Check('driver information (1Bh) is supported', Top >= $1B);

  if Top >= $1B then
  begin
    Info(Blk);
    Note('AH=1Bh structure size:', Blk.StrSiz);
    Check('AH=1Bh returned a whole structure', Blk.StrSiz >= 19);

    if Blk.StrSiz >= 19 then
    begin
      Note('spec level:', Blk.MajVer);
      Note('driver revision:', Blk.MinVer);
      Note('input buffer, bytes:', Blk.IBufr);
      Note('  free:', Blk.IFree);
      Note('output buffer, bytes:', Blk.OBufr);
      Note('  free:', Blk.OFree);
      Note('baud: ' + BaudName[(Blk.Baud shr 5) and 7]);

      Check('input buffer is big enough to cover a missed poll',
            Blk.IBufr >= 1024);
      Check('free never exceeds total, input', Blk.IFree <= Blk.IBufr);
      Check('free never exceeds total, output', Blk.OFree <= Blk.OBufr);

      { The identifier is an asciiz string somewhere else entirely. }
      Ident := '';
      I := 0;
      while I < 64 do
      begin
        B := Mem[Blk.IdSeg : Blk.IdOfs + I];
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
