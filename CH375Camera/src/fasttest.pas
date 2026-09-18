program fasttest;
{ FASTTEST -- check camfast's assembly against the Pascal it replaced, on
  the machine itself, and time it.  CH375Camera, StevenC.  Public domain.

  Random inputs, every routine, every output byte compared.  Exit code is
  the number of routines with any mismatch (0 = all agree). }

{$MODE OBJFPC}{$H-}

uses ch375, camfast;

const
  N = 320;

var
  I, K, Bad, Rep: Integer;
  RR, GG, BB, QQ: array[0..FMAX] of Byte;
  RI, BI: array[0..1] of Byte;
  Q: array[0..3] of Byte;
  S: Word;
  T0: LongInt;
  Y, U, V: Integer;

procedure Check(const Name: ShortString; const A, B: array of Byte; Cnt: Integer);
var J, E: Integer;
begin
  E := 0;
  for J := 0 to Cnt - 1 do if A[J] <> B[J] then Inc(E);
  WriteLn(Name:12, '  mismatches ', E);
  if E > 0 then Inc(Bad);
end;

function Clip(V: Integer): Byte;
begin
  if V < 0 then Clip := 0 else if V > 255 then Clip := 255 else Clip := V;
end;

begin
  WriteLn('FASTTEST -- camfast against the Pascal it replaced');
  Bad := 0;
  RandSeed := 7;
  for I := 0 to FMAX + 1 do begin FA[I] := Random(256); FC[I] := Random(256); end;
  for I := 0 to FMAX div 2 + 1 do begin FU[I] := Random(256); FV[I] := Random(256); end;
  for I := 0 to 255 do
  begin
    SLutR[I] := 255 - I; SLutG[I] := I div 2 + 60; SLutB[I] := (I * 3) and 255;
    for K := 0 to 3 do
    begin
      CubeR[K, I] := (I + K * 13) div 52 * 42;
      CubeG[K, I] := (I + K * 11) div 44 * 6;
      CubeB[K, I] := (I + K * 13) div 52;
      GQt[K, I] := ((I + K) shr 2) and 63;
    end;
    YRV[I] := ((I - 128) * 359) div 256; YBU[I] := ((I - 128) * 454) div 256;
    YGU[I] := ((I - 128) * 88) div 256;  YGV[I] := ((I - 128) * 183) div 256;
  end;
  for I := 0 to 4095 do N16t[I] := (I * 7 + I shr 5) and 15;

  BayerGrey(N);
  for K := 0 to N - 1 do
    GG[K] := (Word(FA[K]) + FA[K + 1] + FC[K] + FC[K + 1]) shr 2;
  Check('BayerGrey', FG, GG, N);

  { GRBG on an even row: even column R = a+1, B = c; odd R = a, B = c+1 }
  RI[0] := 1; BI[0] := 2; RI[1] := 0; BI[1] := 3;
  BayerRGB(N, RI[0], BI[0], RI[1], BI[1]);
  for K := 0 to N - 1 do
  begin
    Q[0] := FA[K]; Q[1] := FA[K + 1]; Q[2] := FC[K]; Q[3] := FC[K + 1];
    RR[K] := Q[RI[K and 1]]; BB[K] := Q[BI[K and 1]];
    S := Word(Q[0]) + Q[1] + Q[2] + Q[3];
    GG[K] := (S - RR[K] - BB[K]) shr 1;
  end;
  Check('BayerRGB R', FR, RR, N);
  Check('BayerRGB G', FG, GG, N);
  Check('BayerRGB B', FB, BB, N);

  for Rep := 0 to 1 do
  begin
    QuantCube(N, Rep);
    for K := 0 to N - 1 do
      QQ[K] := CubeR[Rep * 2 + K and 1, SLutR[FR[K]]] +
               CubeG[Rep * 2 + K and 1, SLutG[FG[K]]] +
               CubeB[Rep * 2 + K and 1, SLutB[FB[K]]];
    Check('QuantCube', FQ, QQ, N);
  end;

  Quant16(N);
  for K := 0 to N - 1 do
    QQ[K] := N16t[((Word(SLutR[FR[K]]) and $F0) shl 4) or
                  (SLutG[FG[K]] and $F0) or (SLutB[FB[K]] shr 4)];
  Check('Quant16', FQ, QQ, N);

  for Rep := 0 to 1 do
  begin
    QuantGrey(N, Rep);
    for K := 0 to N - 1 do QQ[K] := GQt[Rep * 2 + K and 1, SLutG[FG[K]]];
    Check('QuantGrey', FQ, QQ, N);
  end;

  YuvRGB(N);
  for K := 0 to N - 1 do
  begin
    Y := FA[K]; U := FU[K shr 1]; V := FV[K shr 1];
    RR[K] := Clip(Y + YRV[V]);
    GG[K] := Clip(Y - YGU[U] - YGV[V]);
    BB[K] := Clip(Y + YBU[U]);
  end;
  Check('YuvRGB R', FR, RR, N);
  Check('YuvRGB G', FG, GG, N);
  Check('YuvRGB B', FB, BB, N);

  Expand(N, 2);
  for K := 0 to N - 1 do begin QQ[2 * K mod N] := 0; end;
  I := 0;
  for K := 0 to N - 1 do
    if (FL[2 * K] <> FQ[K]) or (FL[2 * K + 1] <> FQ[K]) then Inc(I);
  WriteLn('Expand x2':12, '  mismatches ', I);
  if I > 0 then Inc(Bad);

  BayerCellGrey(N div 2, 2);
  for K := 0 to N div 2 - 1 do
    GG[K] := (Word(FA[2*K]) + FA[2*K + 1] + FC[2*K] + FC[2*K + 1]) shr 2;
  Check('CellGrey/2', FG, GG, N div 2);
  BayerCellRGB(N div 4, 4, 1, 2);
  for K := 0 to N div 4 - 1 do
  begin
    Q[0] := FA[4*K]; Q[1] := FA[4*K + 1]; Q[2] := FC[4*K]; Q[3] := FC[4*K + 1];
    RR[K] := Q[1]; BB[K] := Q[2];
    GG[K] := (Word(Q[0]) + Q[3]) shr 1;
  end;
  Check('CellRGB/4 R', FR, RR, N div 4);
  Check('CellRGB/4 G', FG, GG, N div 4);
  Check('CellRGB/4 B', FB, BB, N div 4);

  QuantCubeP(N, 1, 2, True);
  for K := 0 to N - 1 do
    if K and 1 = 0 then
      QQ[K] := CubeR[1, SLutR[FR[K]]] + CubeG[1, SLutG[FG[K]]] + CubeB[1, SLutB[FB[K]]]
    else
      QQ[K] := CubeR[2, SLutR[FR[K]]] + CubeG[2, SLutG[FG[K]]] + CubeB[2, SLutB[FB[K]]];
  Check('QuantCubeP', FQ2, QQ, N);
  QuantGreyP(N, 3, 3, False);
  for K := 0 to N - 1 do QQ[K] := GQt[3, SLutG[FG[K]]];
  Check('QuantGreyP', FQ, QQ, N);
  Expand2(100, 3, True);
  I := 0;
  for K := 0 to 299 do
    if ((K and 1 = 1) and (FL[K] <> FQ[K div 3])) or
       ((K and 1 = 0) and (FL[K] <> FQ2[K div 3])) then Inc(I);
  WriteLn('Expand2 x3':12, '  mismatches ', I);
  if I > 0 then Inc(Bad);
  Expand2(100, 4, False, True);
  I := 0;
  for K := 0 to 399 do
    if ((K and 1 = 0) and (FL2[K] <> FQ[K div 4])) or
       ((K and 1 = 1) and (FL2[K] <> FQ2[K div 4])) then Inc(I);
  WriteLn('Expand2 x4':12, '  mismatches ', I);
  if I > 0 then Inc(Bad);

  { timing: 240 rows of 320 -- one whole picture }
  T0 := Ticks;
  for Rep := 1 to 240 do begin BayerRGB(N, 1, 2, 0, 3); QuantCube(N, Rep and 1); end;
  WriteLn('colour 320x240 : ', (Ticks - T0) * 55, ' ms');
  T0 := Ticks;
  for Rep := 1 to 240 do begin BayerGrey(N); QuantGrey(N, Rep and 1); end;
  WriteLn('grey   320x240 : ', (Ticks - T0) * 55, ' ms');
  T0 := Ticks;
  for Rep := 1 to 240 do begin YuvRGB(N); QuantCube(N, Rep and 1); end;
  WriteLn('yuv    320x240 : ', (Ticks - T0) * 55, ' ms');
  T0 := Ticks;
  for Rep := 1 to 240 do begin BayerRGB(N, 1, 2, 0, 3); Quant16(N); end;
  WriteLn('text16 320x240 : ', (Ticks - T0) * 55, ' ms');
  T0 := Ticks;
  for Rep := 1 to 120 do begin BayerCellRGB(160, 2, 1, 2); QuantCube(160, Rep and 1); end;
  WriteLn('colour cells /2: ', (Ticks - T0) * 55, ' ms');
  T0 := Ticks;
  for Rep := 1 to 120 do begin BayerCellGrey(160, 2); QuantGrey(160, Rep and 1); end;
  WriteLn('grey cells /2  : ', (Ticks - T0) * 55, ' ms');
  WriteLn('routines with mismatches: ', Bad);
  Halt(Bad);
end.
