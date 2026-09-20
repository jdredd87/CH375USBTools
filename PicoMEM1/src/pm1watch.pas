program pm1watch;
{ PM1WATCH -- watch the WHOLE of the card's shared memory for changes.
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1WATCH [/S=n] [/K] [/T] [/B-] [/P=2A0]

  Every other tool here reads a place it already knows about.  This one
  reads all 8 KB, twenty times a second, and reports every byte that
  moved -- which is the question to ask when you do not know where an
  answer is supposed to land, or whether there is one at all.

    /S=n seconds to watch (default 20)
    /K   turn the card's KEYBOARD reporting on for the watch (command
         54h), and off again afterwards.  See the note below
    /T   self-test: ask for the USB list before the snapshot and the
         DISK list in the middle of the watch, so the parameter area
         genuinely changes content and the watch must see it.  An
         instrument that reports nothing is worth nothing until it has
         reported something.

         The first version of this sent the SAME query both times, and
         reported nothing at all: re-asking rewrites byte-for-byte
         identical text, and a watcher looking for changed VALUES
         cannot see a write that changes none.  It would have called
         the keyboard result below a true negative
    /B-  no beeps.  By default the speaker sounds a rising pair when the
         window opens and a falling pair when it shuts, because whoever
         is typing or moving a mouse is not reading this over a bridge
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  ON /K, AND WHY THE ANSWER IS PROBABLY NO.  The card claims a USB
  keyboard and says so -- PM1STAT shows "1: USB keyboard" -- but in the
  published firmware the flag that command 54h sets is never read by
  anything, and IRQ_R_KEYBOARD, the interrupt source reserved for
  keystrokes, is defined in a header and raised nowhere.  Compare the
  mouse, which is wired up end to end and does work.  The sources are
  also NEWER than the BIOS on this card, so a feature missing there is
  certainly missing here.  /K exists so the negative can be demonstrated
  with the switch turned on rather than argued from reading alone.

  Exit code: 0 something changed, 1 no card, 3 no shared memory,
  5 nothing changed at all. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.0.0';
  MAXCHG = 96;           { distinct offsets remembered }

type
  TChange = record
    Ofs: Word;
    First, Last: Byte;
    Count: Word;
  end;

var
  Secs: Word;
  DoKeyb, SelfTest, DoBeep: Boolean;
  ForceBase: Word;
  Snap: array[0..SHARED_LEN - 1] of Byte;
  Chg: array[0..MAXCHG - 1] of TChange;
  NChg: Integer;
  Overflow: LongInt;

function ParseNum(const S: string; var W: Word): Boolean;
var I: Integer; V: LongInt;
begin
  V := 0; ParseNum := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    if (S[I] < '0') or (S[I] > '9') then Exit;
    V := V * 10 + Ord(S[I]) - 48;
    if V > 3600 then Exit;
  end;
  W := V; ParseNum := True;
end;

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
  Secs := 20; DoKeyb := False; SelfTest := False; DoBeep := True;
  ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'K': DoKeyb := True;
        'T': SelfTest := True;
        'B': DoBeep := not ((Length(S) > 2) and (S[3] = '-'));
        'S': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 9), W) then Secs := W;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
  if Secs < 2 then Secs := 2;
end;

{ Straight at the 8253 and port 61h -- never Crt, whose initialisation
  takes the output driver away from the bridge. }
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

procedure Gap(Dur: Word);
var T0: LongInt;
begin
  T0 := Ticks;
  while (Ticks - T0 < Dur) and (Ticks >= T0) do ;
end;

procedure BeepStart;
begin
  if DoBeep then begin Tone(660, 3); Gap(1); Tone(990, 4); end;
end;

procedure BeepEnd;
begin
  if DoBeep then begin Tone(990, 3); Gap(1); Tone(660, 4); end;
end;

procedure Note(Ofs: Word; Was, Now_: Byte);
var I: Integer;
begin
  for I := 0 to NChg - 1 do
    if Chg[I].Ofs = Ofs then begin
      Chg[I].Last := Now_;
      Inc(Chg[I].Count);
      Exit;
    end;
  if NChg >= MAXCHG then begin Inc(Overflow); Exit; end;
  Chg[NChg].Ofs := Ofs;
  Chg[NChg].First := Was;
  Chg[NChg].Last := Now_;
  Chg[NChg].Count := 1;
  Inc(NChg);
end;

{ What is this offset part of?  The layout is anchored on the parameter
  area PM1CARD found, which is the only fixed point that holds on both
  firmwares. }
function Region(Ofs: Word): string;
var Pccmd, IrqV: Word;
begin
  Pccmd := PmParam - 36;
  IrqV  := PmParam - 32;
  if Ofs < 32 then Region := 'BIOS variables'
  else if Ofs < 64 then Region := 'disk parameter table'
  else if Ofs < 82 then Region := 'saved registers'
  else if Ofs < Pccmd then Region := 'configuration'
  else if Ofs < IrqV then Region := 'PC command block'
  else if Ofs < PmParam then begin
    case Ofs - IrqV of
      11: Region := 'IRQ vars: mouse X';
      12: Region := 'IRQ vars: mouse Y';
      13: Region := 'IRQ vars: mouse buttons';
    else
      Region := 'IRQ variables';
    end;
  end
  else if Ofs < PmParam + 2048 then Region := 'parameter area (answers)'
  else if Ofs < 4096 then Region := 'BIOS internal'
  else if Ofs < 6144 then Region := 'disk buffer'
  else Region := 'DMA buffer';
end;

var
  Bad: Word;
  I: Integer;
  O: Word;
  B: Byte;
  T0, TEnd, TMid, Spun: LongInt;
  Sweeps: LongInt;
  Res: Word;
  R: Byte;
  Fired: Boolean;
  Rc: Integer;
const
  SPIN: string[4] = '-\|/';
begin
  Args;
  WriteLn('PM1WATCH ', VER, ' -- every byte of the card''s shared memory');
  Rc := 0;

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h');
    Halt(1);
  end;
  if not SharedOK then begin
    WriteLn('no shared memory at ', Hex4(PmRomSeg), ':4000');
    Halt(3);
  end;
  if not FindParam then
    WriteLn('the parameter area was not found; regions below are guesses')
  else
    WriteLn('answers at +', PmParam, ', IRQ variables at +', PmParam - 32);

  if DoKeyb then begin
    Res := 0;
    R := Command(CMD_KEYB_ONOFF, 1, 91, Res);
    WriteLn('keyboard reporting on (54h): ', ResultName(R));
  end;

  { For the self-test, leave the parameter area holding the USB answer,
    so that the disk answer sent mid-watch overwrites it with different
    text.  Two different answers, not the same one twice. }
  if SelfTest then begin
    Res := 0;
    R := Command(CMD_USB_STATUS, 0, 91, Res);
    WriteLn('self-test: USB list asked first (', ResultName(R),
            '), disk list will follow mid-watch');
  end;

  { the snapshot is taken AFTER anything we send, so our own writes are
    not reported as the card's }
  for O := 0 to SHARED_LEN - 1 do Snap[O] := SharedB(O);
  NChg := 0; Overflow := 0; Sweeps := 0; Fired := False;

  WriteLn;
  if DoKeyb then WriteLn('type on the USB keyboard for ', Secs, ' seconds')
    else WriteLn('do whatever you want watched, for ', Secs, ' seconds');
  WriteLn('(the speaker says when)');
  BeepStart;

  T0 := Ticks;
  TEnd := T0 + LongInt(Secs) * 91 div 5;
  TMid := T0 + (TEnd - T0) div 2;
  Spun := -1;

  while (Ticks < TEnd) and (Ticks >= T0) do begin
    if SelfTest and (not Fired) and (Ticks >= TMid) then begin
      Fired := True;
      Res := 0;
      Command(CMD_DISK_STAT, 0, 91, Res);
    end;
    for O := 0 to SHARED_LEN - 1 do begin
      B := SharedB(O);
      if B <> Snap[O] then begin
        Note(O, Snap[O], B);
        Snap[O] := B;
      end;
    end;
    Inc(Sweeps);
    if Ticks shr 2 <> Spun then begin
      Spun := Ticks shr 2;
      Write(StdErr, SPIN[1 + (Spun and 3)], #8);
    end;
  end;
  Write(StdErr, ' ', #8);
  BeepEnd;

  if DoKeyb then begin
    Res := 0;
    R := Command(CMD_KEYB_ONOFF, 0, 91, Res);
    WriteLn;
    WriteLn('keyboard reporting off (54h): ', ResultName(R));
  end;

  WriteLn;
  WriteLn(Sweeps, ' sweeps of 8192 bytes in ', Secs, ' seconds');
  if NChg = 0 then begin
    WriteLn('NOT ONE BYTE of the card''s shared memory changed.');
    Rc := 5;
  end else begin
    WriteLn(NChg, ' offset(s) changed:');
    WriteLn('   offset  first  last  times  what it is');
    for I := 0 to NChg - 1 do
      WriteLn('   +', Chg[I].Ofs:5, '     ', Hex2(Chg[I].First), '    ',
              Hex2(Chg[I].Last), ' ', Chg[I].Count:6, '  ', Region(Chg[I].Ofs));
    if Overflow > 0 then
      WriteLn('   ... and ', Overflow, ' change(s) at further offsets',
              ' beyond the ', MAXCHG, ' remembered');
  end;

  if SelfTest then begin
    WriteLn;
    if Fired then begin
      Write('self-test: the disk query was sent mid-watch, and the');
      if NChg > 0 then WriteLn(' watch saw bytes move.')
        else WriteLn(' watch SAW NOTHING -- do not trust the result above.');
    end else
      WriteLn('self-test: the query never fired (the window was too short).');
  end;

  Halt(Rc);
end.
