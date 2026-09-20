program pmirq;
{ PMIRQ -- can we hook an interrupt, chain it, and come back alive?
  PicoMEM tools, StevenC.  Public domain (the Unlicense).

    PMIRQ /A [/S=n]      phase A: hook INT 1Ch and count ticks
    PMIRQ /B [/S=n]      phase B: hook the card's IRQ and count mouse events

  The groundwork for an INT 33h driver, and nothing more than that: it
  goes resident for a few seconds, counts, puts the vector back and
  exits.  Nothing here stays in memory.

  PHASE A FIRST, ALWAYS.  It hooks INT 1Ch -- the timer hook the BIOS
  provides for exactly this purpose, whose default handler is an IRET --
  chains to the previous handler, counts for n seconds and expects about
  18.2 per second.  That proves three things at once, on an interrupt
  where a mistake costs nothing: that FPC's `interrupt` procedures set
  DS up the way this code assumes, that the chain back to the old
  handler works, and that the vector is restored.  Only then is it worth
  pointing the same machinery at the card.

  PHASE B hooks the card's own IRQ, which `BV_IRQ` names -- 7 on this
  machine, so INT 0Fh.  The card's BIOS already owns that vector
  (D000:2C1E here) and does the acknowledge, so this reads the three
  mouse bytes out of the IRQ variables FIRST and then chains to it.
  Getting the chain wrong there is a machine that stops: the card's
  interrupt would never be acknowledged and the 8259 would stay in
  service, taking the timer and the network down with it.  Hence phase A.

  Exit code: 0 the hook worked and events arrived, 1 no card, 2 nothing
  was counted, 3 no shared memory, 4 the answers area was not found. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix, Dos;

const
  VER = '0.1.0';

var
  Secs: Word;
  PhaseA, PhaseB, DoBeep: Boolean;
  OldVec: Pointer;
  VecNum: Byte;
  Hits: Word;              { touched by the ISR }
  AccX, AccY: LongInt;     { touched by the ISR }
  BtnSeen: Byte;           { touched by the ISR }
  LastX, LastY, LastB: Byte;
  MSeg, MOfs: Word;        { where mouse_x lives }

function ParseNum(const S: string; var W: Word): Boolean;
var I: Integer; V: LongInt;
begin
  V := 0; ParseNum := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    if (S[I] < '0') or (S[I] > '9') then Exit;
    V := V * 10 + Ord(S[I]) - 48;
    if V > 600 then Exit;
  end;
  W := V; ParseNum := True;
end;

procedure Args;
var I: Integer; S: string; W: Word;
begin
  Secs := 10; PhaseA := False; PhaseB := False; DoBeep := True;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'A': PhaseA := True;
        'B': PhaseB := True;
        'Q': DoBeep := False;
        'S': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 9), W) then Secs := W;
      end;
  end;
  if Secs < 2 then Secs := 2;
end;

procedure Tone(Freq: Word; Dur: Word);
var D: Word; Old: Byte; T0: LongInt;
begin
  D := Word(LongInt(1193180) div LongInt(Freq));
  OutB($43, $B6);
  OutB($42, Lo(D));
  OutB($42, Hi(D));
  Old := InB($61);
  OutB($61, Old or 3);
  T0 := Ticks;
  while (Ticks - T0 < Dur) and (Ticks >= T0) do ;
  OutB($61, Old and $FC);
end;

procedure CueGo;
var I: Integer;
begin
  if not DoBeep then Exit;
  for I := 1 to 8 do begin Tone(880, 3); Tone(1320, 3); end;
end;

procedure CueEnd;
begin
  if DoBeep then begin Tone(1320, 3); Tone(880, 3); Tone(660, 6); end;
end;

{ *** the two handlers ***

  Both end the same way: PUSHF then a far indirect CALL through the
  saved vector.  That pair is what makes chaining safe -- the old
  handler finishes with IRET, which pops IP, CS *and* the flags, so the
  flags have to be on the stack for it or the return unbalances and the
  machine goes somewhere random.  A plain far call would do exactly
  that.  It is one asm block so nothing the compiler emits can come
  between the PUSHF and the CALL. }

procedure IsrTick; interrupt;
begin
  Inc(Hits);
  asm
    pushf
    call dword ptr [OldVec]
  end;
end;

procedure IsrMouse; interrupt;
var X, Y, B: Byte;
begin
  X := Mem[MSeg : MOfs];
  Y := Mem[MSeg : MOfs + 1];
  B := Mem[MSeg : MOfs + 2];
  if (X <> LastX) or (Y <> LastY) or (B <> LastB) then begin
    Inc(Hits);
    if X > 127 then AccX := AccX + LongInt(X) - 256 else AccX := AccX + X;
    if Y > 127 then AccY := AccY + LongInt(Y) - 256 else AccY := AccY + Y;
    BtnSeen := BtnSeen or B;
    LastX := X; LastY := Y; LastB := B;
  end;
  asm
    pushf
    call dword ptr [OldVec]
  end;
end;

procedure Wait(N: Word);
var T0, TEnd: LongInt;
begin
  T0 := Ticks;
  TEnd := T0 + LongInt(N) * 91 div 5;
  while (Ticks < TEnd) and (Ticks >= T0) do ;
end;

var
  Bad: Word;
  R: Byte;
  Res: Word;
  Rc: Integer;
begin
  Args;
  WriteLn('PMIRQ ', VER, ' -- hook an interrupt, chain it, come back');
  Rc := 0;
  Hits := 0; AccX := 0; AccY := 0; BtnSeen := 0;

  if not (PhaseA or PhaseB) then begin
    WriteLn('say /A (the safe one, INT 1Ch) or /B (the card IRQ).');
    WriteLn('Run /A first on any machine this has not run on.');
    Halt(0);
  end;

  if PhaseA then begin
    VecNum := $1C;
    WriteLn('phase A: INT 1Ch, the BIOS timer hook, for ', Secs, ' seconds');
    GetIntVec(VecNum, OldVec);
    WriteLn('  previous handler ', Hex4(Seg(OldVec^)), ':',
            Hex4(Ofs(OldVec^)));
    SetIntVec(VecNum, @IsrTick);
    Wait(Secs);
    SetIntVec(VecNum, OldVec);
    WriteLn('  vector restored');
    WriteLn('  ticks counted : ', Hits, '   expected about ',
            (LongInt(Secs) * 91) div 5);
    if Hits = 0 then begin
      WriteLn('  NOTHING was counted -- the handler never ran, or DS was');
      WriteLn('  not what this code assumes.  Do not run /B.');
      Rc := 2;
    end else
      WriteLn('  the hook, the chain and the restore all work.');
    Halt(Rc);
  end;

  { phase B }
  if not AskBios then begin WriteLn('no PicoMEM BIOS'); Halt(1); end;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin WriteLn('no PicoMEM at ', Hex4(PmBase), 'h'); Halt(1); end;
  if not SharedOK then begin WriteLn('no shared memory'); Halt(3); end;
  if not FindParam then begin WriteLn('no answers area'); Halt(4); end;

  MSeg := PmRomSeg;
  MOfs := SHARED_OFS + (PmParam - 32) + 11;
  VecNum := 8 + SharedB(11);          { IRQ 0-7 live at INT 08h-0Fh }

  WriteLn('phase B: the card says its IRQ is ', SharedB(11),
          ', so interrupt ', Hex2(VecNum), 'h');
  WriteLn('  mouse bytes at ', Hex4(MSeg), ':', Hex4(MOfs));
  if SharedB(11) > 7 then begin
    WriteLn('  that is not IRQ 0-7; this tool only knows the first PIC.');
    Halt(1);
  end;

  GetIntVec(VecNum, OldVec);
  WriteLn('  previous handler ', Hex4(Seg(OldVec^)), ':', Hex4(Ofs(OldVec^)));
  if Seg(OldVec^) < $C000 then begin
    WriteLn('  that is not the card BIOS (expected C000h or above).');
    WriteLn('  Chaining into RAM that may not be a handler is not worth');
    WriteLn('  the risk -- stopping.');
    Halt(1);
  end;

  LastX := Mem[MSeg : MOfs];
  LastY := Mem[MSeg : MOfs + 1];
  LastB := Mem[MSeg : MOfs + 2];

  Res := 0;
  R := Command(CMD_MOUSE_ON, 0, 91, Res);
  WriteLn('  mouse reporting on (52h): ', ResultName(R));
  if R <> CR_OK then Halt(1);

  SetIntVec(VecNum, @IsrMouse);
  WriteLn('  hooked; move the mouse for ', Secs, ' seconds');
  CueGo;
  Wait(Secs);
  SetIntVec(VecNum, OldVec);
  CueEnd;

  Res := 0;
  Command(CMD_MOUSE_OFF, 0, 91, Res);
  WriteLn('  vector restored, reporting off');
  WriteLn;
  WriteLn('  interrupts that carried new data: ', Hits);
  WriteLn('  summed movement : x ', AccX, ', y ', AccY);
  WriteLn('  buttons seen    : ', Hex2(BtnSeen));
  if Hits = 0 then begin
    WriteLn;
    WriteLn('  Nothing arrived.  Either the mouse was not moved, or the');
    WriteLn('  card raises its interrupt for something other than this.');
    Rc := 2;
  end else begin
    WriteLn;
    WriteLn('  So an interrupt-driven driver is possible: every event');
    WriteLn('  arrives, instead of whatever polling happens to catch.');
  end;
  Halt(Rc);
end.
