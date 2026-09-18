unit camfile;
{ CAMFILE -- saving the camera's picture.  CH375Camera, StevenC.
  Public domain (the Unlicense).

  BMP because anything opens it, bottom-up as the format wants: 8-bit with
  a grey palette, or 24-bit colour.  Every width the camera has is a
  multiple of 4 bytes a row in both, so no padding.  RAW is the camera's
  own bytes: the Bayer mosaic, or the Y, U and V planes one after another. }

{$MODE OBJFPC}{$H-}

interface

procedure WriteBmp(const Name: ShortString; Grey: Boolean);
procedure WriteRaw(const Name: ShortString);

{ Called once a row while writing, for a heartbeat.  Nil for none. }
var
  FileIdle: procedure = nil;

implementation

uses camgrab;

procedure Put32(var H: array of Byte; P: Integer; V: LongInt);
begin
  H[P] := V and $FF; H[P + 1] := (V shr 8) and $FF;
  H[P + 2] := (V shr 16) and $FF; H[P + 3] := (V shr 24) and $FF;
end;

procedure WriteBmp(const Name: ShortString; Grey: Boolean);
var
  F: File;
  Hdr: array[0..53] of Byte;
  Pal: array[0..1023] of Byte;
  Line: array[0..MAXW * 3 - 1] of Byte;
  R, G, B: array[0..MAXW - 1] of Byte;
  X, Y, I, Bpp, RowB: Integer;
  Off: LongInt;
begin
  if Grey then Bpp := 8 else Bpp := 24;
  RowB := Mode.W * (Bpp div 8);
  FillChar(Hdr, SizeOf(Hdr), 0);
  Off := 54;
  if Bpp = 8 then Off := 54 + 1024;
  Hdr[0] := Ord('B'); Hdr[1] := Ord('M');
  Put32(Hdr, 2, Off + LongInt(RowB) * Mode.H);
  Put32(Hdr, 10, Off);
  Put32(Hdr, 14, 40);
  Put32(Hdr, 18, Mode.W);
  Put32(Hdr, 22, Mode.H);
  Hdr[26] := 1;
  Hdr[28] := Bpp;
  Put32(Hdr, 34, LongInt(RowB) * Mode.H);
  if Bpp = 8 then Put32(Hdr, 46, 256);
  Assign(F, Name);
  Rewrite(F, 1);
  BlockWrite(F, Hdr, SizeOf(Hdr));
  if Bpp = 8 then
  begin
    for I := 0 to 255 do
    begin
      Pal[I * 4] := I; Pal[I * 4 + 1] := I; Pal[I * 4 + 2] := I;
      Pal[I * 4 + 3] := 0;
    end;
    BlockWrite(F, Pal, SizeOf(Pal));
  end;
  for Y := Mode.H - 1 downto 0 do
  begin
    if Assigned(FileIdle) then FileIdle;
    if Bpp = 8 then RowGrey(Y, 0, Mode.W, @Line)
    else
    begin
      RowRGB(Y, 0, Mode.W, @R, @G, @B);
      for X := 0 to Mode.W - 1 do
      begin
        Line[X * 3] := B[X]; Line[X * 3 + 1] := G[X]; Line[X * 3 + 2] := R[X];
      end;
    end;
    BlockWrite(F, Line, RowB);
  end;
  Close(F);
end;

procedure WriteRaw(const Name: ShortString);
var
  F: File;
  Y: Integer;
begin
  Assign(F, Name);
  Rewrite(F, 1);
  for Y := 0 to Mode.H - 1 do BlockWrite(F, Pix[Y]^, Mode.W);
  if Mode.Fmt = fmtYUV then
  begin
    for Y := 0 to Mode.H div 2 - 1 do BlockWrite(F, UPix[Y]^, Mode.W div 2);
    for Y := 0 to Mode.H div 2 - 1 do BlockWrite(F, VPix[Y]^, Mode.W div 2);
  end;
  Close(F);
end;

end.
