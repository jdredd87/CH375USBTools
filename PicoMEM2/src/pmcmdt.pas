program pmcmdt;
{ PMCMDT -- how many status queries in a row does the card take?
  PicoMEM2 tools, StevenC.  Public domain (the Unlicense).

    PMCMDT [/N=2] [/D=0] [/W]

  Sends the USB status query (61h) N times, D ticks apart, with NO DOS
  call of any kind in between -- no output, no file, nothing that turns
  into a disk command on the card.  Each outcome is kept in memory and
  printed only at the end.  /W puts one DOS write (to stdout) between
  queries instead, to reproduce what PMUSB does.

  Why it exists: PMUSB wedged the machine on its second query, one
  second after the first, with its output write in between.  This
  separates the two suspects.

  Before printing, the card's status is checked.  If it is not ready,
  nothing is written -- a write would be a disk command into a card that
  is not taking them -- and the result is beeped instead: one beep per
  query that completed.

  Exit code: queries that completed (capped at 20). }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '0.1.0';
  MAXN = 20;

var
  N, D, I: Word;
  Wr: Boolean;
  R: array[1..MAXN] of Byte;
  St: array[1..MAXN] of Byte;
  Ms: array[1..MAXN] of LongInt;
  Res: Word;
  T0: LongInt;
  Done: Word;

procedure Args;
var I, Code: Integer; S: string; V: Word;
begin
  N := 2; D := 0; Wr := False;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    case UpCase(S[2]) of
      'N': begin Val(Copy(S, 4, 5), V, Code); if Code = 0 then N := V; end;
      'D': begin Val(Copy(S, 4, 5), V, Code); if Code = 0 then D := V; end;
      'W': Wr := True;
    end;
  end;
  if N < 1 then N := 1;
  if N > MAXN then N := MAXN;
end;

procedure Beep(Hz, Tk: Word);
var Div_: Word; T: LongInt;
begin
  Div_ := 1193180 div Hz;
  OutB($43, $B6); OutB($42, Lo(Div_)); OutB($42, Hi(Div_));
  OutB($61, InB($61) or 3);
  T := Ticks; while Ticks - T < Tk do ;
  OutB($61, InB($61) and $FC);
  T := Ticks; while Ticks - T < Tk do ;
end;

begin
  Args;
  if not AskBios then Halt(0);
  if TestPort(PmBase, 100) <> 0 then Halt(0);
  if Wr then WriteLn('PMCMDT ', VER, ' -- ', N, ' queries, ', D, ' ticks apart, a DOS write between');

  Done := 0;
  for I := 1 to N do begin
    if (I > 1) and (D > 0) then begin
      T0 := Ticks; while Ticks - T0 < D do ;
    end;
    if (I > 1) and Wr then WriteLn('query ', I);
    T0 := Ticks;
    R[I] := Command(CMD_USB_STATUS, 0, 91, Res);
    St[I] := PmLastSt;
    Ms[I] := (Ticks - T0) * 55;
    if R[I] = CR_OK then Inc(Done);
  end;

  if WaitReady(36) <> ST_READY then begin
    { a write now would go to a card that is not taking commands }
    for I := 1 to Done do Beep(880, 3);
    Beep(220, 18);
    Halt(Done);
  end;

  WriteLn('PMCMDT ', VER, ' -- ', N, ' queries, ', D, ' ticks apart',
          '; card ready afterwards');
  for I := 1 to N do
    WriteLn('  ', I:2, ': ', ResultName(R[I]), ', status ', St[I], ', ', Ms[I], ' ms');
  if Done > 20 then Done := 20;
  Halt(Done);
end.
