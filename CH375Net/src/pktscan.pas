program pktscan;
{ PKTSCAN -- which interrupt vectors hold a packet driver, and which are free.
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  A Crynwr packet driver announces itself by putting the string "PKT DRVR"
  three bytes into its interrupt handler.  That is the whole discovery
  mechanism the standard defines: an application walks 60h to 80h looking
  for the signature and uses the first vector that has one.

  This exists for two reasons, and the second one matters more.

  FINDING A FREE VECTOR.  A second packet driver cannot share a vector with
  the first.  Before installing one you need to know what is already there.

  NOT LOSING THE MACHINE.  On the box this was written for, the working
  network -- the one the remote bridge itself runs over -- is a packet
  driver at 60h loaded from AUTOEXEC.BAT.  Install something on top of that
  vector and the machine goes silent, with no way in to undo it.  Run this
  first, and run it again afterwards: if 60h still answers, the way back is
  still there.

    PKTSCAN [/F=hex] [/T=hex] [/V]

      /F=hex   first vector, default 60
      /T=hex   last vector, default 80
      /V       show the handler address of every vector, not just the ones
               with a driver behind them

  Reading a vector has no side effects whatsoever -- this never writes
  anything, and is safe to run at any time, including with a live network
  connection going through the driver it is looking at.

  Exit codes: 0 at least one packet driver found, 1 none }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';
  SIG = 'PKT DRVR';

var
  First:   Byte = $60;
  Last:    Byte = $80;
  Verbose: Boolean = False;

{ The vector's own segment:offset, straight out of the interrupt table at
  the bottom of memory. }
procedure GetVec(N: Byte; var Seg, Ofs: Word);
begin
  Ofs := MemW[0 : LongInt(N) * 4];
  Seg := MemW[0 : LongInt(N) * 4 + 2];
end;

function HasSig(Seg, Ofs: Word): Boolean;
var I: Integer;
begin
  HasSig := False;
  { Nothing is installed at 0000:0000, and a vector pointing there is the
    normal "unused" state rather than a driver worth reading. }
  if (Seg = 0) and (Ofs = 0) then Exit;
  for I := 1 to Length(SIG) do
    if Chr(Mem[Seg : Ofs + 2 + I]) <> SIG[I] then Exit;
  HasSig := True;
end;

{ A driver that answers the signature will also answer driver_info, which
  is function 1 with AH=1FFh... in practice the useful part without making
  any call at all is the class and type bytes the standard puts right after
  the signature in most implementations.  Making a real call means running
  somebody else's code, and this program's whole promise is that it only
  reads.  So it reports what it can see and no more. }

procedure Usage;
begin
  Banner('PKTSCAN', VER, 'which vectors hold a packet driver');
  WriteLn;
  WriteLn('  PKTSCAN [/F=hex] [/T=hex] [/V]');
  WriteLn;
  WriteLn('  /F=hex   first vector, default 60');
  WriteLn('  /T=hex   last vector, default 80');
  WriteLn('  /V       show every vector, not just the ones with a driver');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('A Crynwr packet driver announces itself by putting the string');
  WriteLn('"PKT DRVR" three bytes into its interrupt handler.  That is the');
  WriteLn('whole discovery mechanism the standard defines.');
  WriteLn;
  WriteLn('Two uses.  Finding a free vector before installing a driver --');
  WriteLn('two cannot share one.  And, more importantly, not losing the');
  WriteLn('machine: if the network you administer this box over is itself');
  WriteLn('a packet driver, installing something on top of its vector');
  WriteLn('takes the box off the air with no way in to undo it.  Run this');
  WriteLn('before and after.  If the vector you depend on still answers,');
  WriteLn('the way back is still there.');
  WriteLn;
  WriteLn('This only ever READS the interrupt table.  It is safe to run at');
  WriteLn('any time, including over a live connection through the very');
  WriteLn('driver it is reporting on.');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/V') or (A = '-V') then Verbose := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      Val('$' + A, V, Code);
      if Code <> 0 then Continue;
      if      K = '/F=' then First := Byte(V)
      else if K = '/T=' then Last  := Byte(V);
    end;
  end;
end;

var
  N: Byte;
  Seg, Ofs: Word;
  Found, Free1: Integer;
  FreeList: ShortString;
  S: ShortString;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('PKTSCAN', VER, 'packet drivers in the interrupt table');
  WriteLn;

  Found := 0;
  Free1 := 0;
  FreeList := '';

  for N := First to Last do
  begin
    GetVec(N, Seg, Ofs);
    if HasSig(Seg, Ofs) then
    begin
      Inc(Found);
      WriteLn('  ', Hex2(N), 'h  ', Hex4(Seg), ':', Hex4(Ofs),
              '   PACKET DRIVER');
    end
    else if (Seg = 0) and (Ofs = 0) then
    begin
      Inc(Free1);
      if Length(FreeList) < 60 then FreeList := FreeList + Hex2(N) + ' ';
      if Verbose then
        WriteLn('  ', Hex2(N), 'h  ', Hex4(Seg), ':', Hex4(Ofs), '   free');
    end
    else
    begin
      if Verbose then
        WriteLn('  ', Hex2(N), 'h  ', Hex4(Seg), ':', Hex4(Ofs),
                '   in use, not a packet driver');
    end;
    if N = $FF then Break;          { Byte would wrap round for ever }
  end;

  WriteLn;
  Str(Found, S);
  WriteLn(S, ' packet driver(s) between ', Hex2(First), 'h and ',
          Hex2(Last), 'h.');
  if FreeList <> '' then
    WriteLn('Vectors reading 0000:0000: ', FreeList);

  if Found = 0 then
  begin
    WriteLn;
    WriteLn('No packet driver is loaded.  If this machine is supposed to');
    WriteLn('have a network, that is the thing to fix before anything');
    WriteLn('else -- and if you are reading this remotely, you are not.');
    Halt(1);
  end;
  Halt(0);
end.
