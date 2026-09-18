program camcal;
{ CAMCAL -- record the camera's raw stream with the fast packet loop, for
  working out what it is sending.  CH375Camera, StevenC.  Public domain.

    CAMCAL [/P=260] [/M=320] [/N=4000] [/O=CAL.DAT] [s,e,t,b]

  Starts the camera in mode /M (176, 320 or 352), optionally sets the
  window registers 0102..0105 to s,e,t,b (hex), and records /N IN tokens
  as fast as camgrab's loop can issue them -- which is faster than the
  camera fills its FIFO, so the gaps show.  Nothing is interpreted: the
  file is, per token,

      1 byte    length, or FFh for a failed token
      then that many bytes

  camcal.py on the Windows side splits it into frames and lines.  This is
  how the geometry of each mode was measured rather than assumed. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, cit, camgrab;

const
  VER  = '0.2.0';
  BUFK = 60;                      { KB of recording }

var
  OutName: ShortString = 'CAL.DAT';
  ModeNo:  Integer = 2;
  NTok:    LongInt = 4000;
  Win:     array[0..3] of Word;
  HaveWin: Boolean = False;
  Rec:     PByte;
  RecLen:  Word = 0;

function HexW(const S: ShortString; var V: Word): Boolean;
var N: LongInt; C: Integer;
begin
  Val('$' + S, N, C);
  V := N;
  HexW := (C = 0) and (N >= 0) and (N < 256);
end;

procedure ParseArgs;
var
  I, K, C, P: Integer;
  A, T: ShortString;
  N: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if A[1] in ['/', '-'] then
    begin
      Val(Copy(A, 4, 20), N, C);
      case UpCase(A[2]) of
        'P': begin Val('$' + Copy(A, 4, 9), N, C); Base := N; end;
        'O': OutName := Copy(A, 4, 255);
        'N': NTok := N;
        'M': case N of 176: ModeNo := 1; 320: ModeNo := 2; 352: ModeNo := 3; end;
      end;
      Continue;
    end;
    for K := 0 to 3 do
    begin
      P := Pos(',', A);
      if P = 0 then P := Length(A) + 1;
      T := Copy(A, 1, P - 1);
      Delete(A, 1, P);
      if not HexW(T, Win[K]) then begin WriteLn('bad window'); Halt(2); end;
    end;
    HaveWin := True;
  end;
end;

var
  F: File;
  I: LongInt;
  L, R: Integer;
  Buf: array[0..63] of Byte;
  Full: Boolean;
begin
  Banner('CAMCAL', VER, 'record the camera''s raw stream');
  if HelpWanted then
  begin
    WriteLn('CAMCAL [/P=hex] [/M=n] [/N=n] [/O=file] [s,e,t,b]');
    HelpTail;
    Halt(0);
  end;
  ParseArgs;
  PortDat := Base; PortCmd := Base + 1;
  GetMem(Rec, BUFK * 1024);

  R := CamStart(ModeNo, 0);
  if R <> 0 then Halt(R);
  if HaveWin then
  begin
    StreamStop;
    RegW(Win[0], $0102); RegW(Win[1], $0103);
    RegW(Win[2], $0104); RegW(Win[3], $0105);
    StreamGo;
  end;

  Full := False;
  for I := 1 to NTok do
  begin
    L := Pkt(Buf);
    if RecLen + 65 > BUFK * 1024 then begin Full := True; Break; end;
    if L < 0 then begin Rec[RecLen] := $FF; Inc(RecLen); Continue; end;
    Rec[RecLen] := L; Inc(RecLen);
    if L > 0 then Move(Buf, Rec[RecLen], L);
    Inc(RecLen, L);
  end;

  CamStop;
  Assign(F, OutName);
  Rewrite(F, 1);
  BlockWrite(F, Rec^, RecLen);
  Close(F);
  WriteLn('mode ', Mode.W, 'x', Mode.H, '  ', I, ' tokens, ', RecLen,
          ' bytes recorded', Copy(' (buffer full)', 1, 14 * Ord(Full)));
  Halt(0);
end.
