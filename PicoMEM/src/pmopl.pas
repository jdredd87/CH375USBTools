program pmopl;
{ PMOPL -- play something through the AdLib the PicoMEM emulates.
  PicoMEM tools, StevenC.  Public domain (the Unlicense).

    PMOPL [/T] [/N=n] [/S]

  The card can present an OPL2 at 388h with no sound card in the
  machine at all, and on this one it does.  This proves it two ways:
  the chip's timers answer as an OPL2's do, which is checkable from
  here, and then it plays -- which is not, so the exit code reports the
  first and the loudspeaker reports the second.

    /T   test only: detect, print the status bytes, play nothing
    /N=n how many notes of the scale to play (default 8, maximum 16)
    /S   silent: set the registers up and key nothing on, for checking
         that the writes alone disturb nothing

  Everything written here is an OPL2 register.  The card's own audio
  rendering has to be on, and something has to be plugged into its
  audio output, before any of it is audible -- PMCFG says whether the
  first is true and only ears say whether the second is.

  Exit code: 0 an OPL2 answered, 1 nothing answered at 388h. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '1.0.0';
  OPL = $388;

  { A major scale, as OPL2 F-numbers at block 4.  fnum = f * 2^16 /
    49716, which is the chip's own arithmetic, worked out here rather
    than at run time because a 16-bit DOS program has no business
    doing floating point on a machine that may have no coprocessor. }
  NOTES: array[0..15] of Word =
    (345, 387, 434, 460, 516, 580, 651, 689,
     689, 651, 580, 516, 460, 434, 387, 345);
  NAMES: array[0..15] of string[3] =
    ('C4 ', 'D4 ', 'E4 ', 'F4 ', 'G4 ', 'A4 ', 'B4 ', 'C5 ',
     'C5 ', 'B4 ', 'A4 ', 'G4 ', 'F4 ', 'E4 ', 'D4 ', 'C4 ');

var
  TestOnly, Silent: Boolean;
  Count: Integer;

function ParseNum(const S: string; var N: Integer): Boolean;
var I: Integer; V: Integer;
begin
  V := 0; ParseNum := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    if (S[I] < '0') or (S[I] > '9') then Exit;
    V := V * 10 + Ord(S[I]) - 48;
    if V > 999 then Exit;
  end;
  N := V; ParseNum := True;
end;

procedure Args;
var I: Integer; S: string; N: Integer;
begin
  TestOnly := False; Silent := False; Count := 8;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'T': TestOnly := True;
        'S': Silent := True;
        'N': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 4), N) then Count := N;
      end;
  end;
  if Count < 1 then Count := 1;
  if Count > 16 then Count := 16;
end;

procedure OplWait(N: Integer);
var I: Integer; B: Byte;
begin
  for I := 1 to N do B := InB(OPL);
end;

procedure Reg(R, V: Byte);
begin
  OutB(OPL, R);     OplWait(6);
  OutB(OPL + 1, V); OplWait(35);
end;

function Detect(out S1, S2: Byte): Boolean;
begin
  Reg($04, $60);
  Reg($04, $80);
  S1 := InB(OPL);
  Reg($02, $FF);
  Reg($04, $21);
  OplWait(250);            { the timer wants about 80 us }
  S2 := InB(OPL);
  Reg($04, $60);
  Reg($04, $80);
  Detect := (S1 and $E0 = 0) and (S2 and $E0 = $C0);
end;

{ Channel 0 of an OPL2: operator 0 is the modulator, operator 3 the
  carrier.  One straightforward organ-ish voice; the point is that
  something comes out, not that it is beautiful. }
procedure Voice;
begin
  Reg($01, $20);        { allow the waveform-select registers }
  Reg($20, $01);        { modulator: multiplier 1, no tremolo }
  Reg($40, $10);        { modulator: output level }
  Reg($60, $F0);        { modulator: fast attack, medium decay }
  Reg($80, $77);        { modulator: sustain and release }
  Reg($23, $01);        { carrier: multiplier 1 }
  Reg($43, $00);        { carrier: loudest }
  Reg($63, $F0);        { carrier: fast attack, medium decay }
  Reg($83, $77);        { carrier: sustain and release }
  Reg($C0, $00);        { channel 0: no feedback, the two in series }
end;

procedure KeyOn(F: Word);
begin
  Reg($A0, Lo(F));
  Reg($B0, $20 or (4 shl 2) or Hi(F));      { key on, block 4 }
end;

procedure KeyOff;
begin
  Reg($B0, 0);
end;

procedure Hush;
var R: Byte;
begin
  KeyOff;
  for R := $40 to $55 do Reg(R, $3F);       { every operator silent }
  Reg($B0, 0);
end;

{ Wait n BIOS ticks, and draw a heartbeat on stderr while doing it so
  the machine does not look hung to somebody watching the screen. }
procedure Wait(N: Integer);
const SPIN: string[4] = '-\|/';
var T0: LongInt; Spun: LongInt;
begin
  T0 := Ticks;
  Spun := -1;
  while (Ticks - T0 < N) and (Ticks >= T0) do
    if Ticks shr 1 <> Spun then begin
      Spun := Ticks shr 1;
      Write(StdErr, SPIN[1 + (Spun and 3)], #8);
    end;
end;

var
  S1, S2: Byte;
  I: Integer;
begin
  Args;
  WriteLn('PMOPL ', VER, ' -- the AdLib a PicoMEM can be, at 388h');

  if AskBios and SharedOK then begin
    Write('the card says: AdLib ');
    if CfgB(229) <> 0 then Write('on') else Write('OFF');
    Write(', audio rendering ');
    if CfgB(224) <> 0 then WriteLn('on') else WriteLn('OFF');
  end else
    WriteLn('(no PicoMEM answered, so this is whatever is at 388h)');

  if Detect(S1, S2) then
    WriteLn('an OPL2 answers: status ', Hex2(S1), ' with the timers masked,',
            ' ', Hex2(S2), ' after one ran')
  else begin
    WriteLn('nothing answers at 388h: status ', Hex2(S1), ' then ', Hex2(S2));
    WriteLn('(an AdLib reads 00 then C0; FF twice means no card decodes it)');
    Halt(1);
  end;
  if TestOnly then Halt(0);

  Voice;
  if Silent then begin
    WriteLn('registers set, nothing keyed on (/S)');
    Hush;
    Halt(0);
  end;

  WriteLn('playing ', Count, ' notes; each is about a fifth of a second');
  Write('  ');
  for I := 0 to Count - 1 do begin
    KeyOn(NOTES[I]);
    Write(NAMES[I]);
    Wait(4);
    KeyOff;
    Wait(1);
  end;
  WriteLn;
  Hush;
  Write(StdErr, ' ', #8);
  WriteLn('done.  Whether any of it was audible depends on the card''s own');
  WriteLn('audio output, which nothing on this side can see.');
  Halt(0);
end.
