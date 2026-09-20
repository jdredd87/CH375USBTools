program pmusb;
{ PMUSB -- watch the PicoMEM's USB host: what is plugged in, and when
  it changes.
  PicoMEM2 tools, StevenC.  Public domain (the Unlicense).

    PMUSB [/S=secs] [/Q]   default: one look, then exit
                           /Q: no spinner on the screen

  Asks the card for its USB status (command 61h, read-only) once a
  second and prints the device list whenever it differs from the last
  one, with the time.  Plug and unplug things during a /S run to see
  what the card makes of them.

  Only what the card's firmware knows is visible: a device count, and a
  line for each device one of its class drivers (HID, mass storage,
  MIDI, game pads) claimed.  A device nothing claimed -- a network
  adapter, a camera -- is counted and has an empty line.  Its USB ID is
  not available through the stock firmware at all.

  While /S runs, a spinner on the screen (stderr) turns with the clock,
  so a live run and a locked machine look different.

  Exit code: the device count at the end (capped at 20), or 20 if the
  card could not be asked. }

{$MODE OBJFPC}{$H-}

uses pmcard, vidfix;

const
  VER = '0.1.0';

var
  Last, Now_: string;
  Secs, Count: Word;
  T0, TNext: LongInt;
  Quiet: Boolean;

{ One USB status query, returned as one line per device joined with '|'.
  The answer is copied out of the card's memory before anything else. }
function Look(out N: Word; out Ok: Boolean): string;
var Res: Word; R: Byte; Buf: array[0..511] of Byte; I, P, L, Lines: Integer;
    S: string; B: Byte;
begin
  N := 0; Ok := False; Look := '';
  R := Command(CMD_USB_STATUS, 0, 91, Res);
  if R <> CR_OK then begin Look := 'query failed: ' + ResultName(R); Exit; end;
  for I := 0 to High(Buf) do Buf[I] := SharedB(PmParam + I);
  Ok := True;
  Lines := Buf[0];
  if Lines = 0 then begin Look := 'USB host disabled in the card''s configuration'; Exit; end;
  N := Lines - 1;
  S := '';
  P := 1;
  for L := 1 to Lines do begin
    while (P <= High(Buf)) and (Buf[P] <> 0) do begin
      B := Buf[P];
      if (B >= 32) and (B <= 126) then S := S + Chr(B);
      Inc(P);
    end;
    Inc(P);
    if L < Lines then S := S + ' |';
    if P > High(Buf) then Break;
  end;
  Look := S;
end;

procedure Show(const S: string; Elapsed: LongInt);
var I: Integer;
begin
  Write('[', Elapsed div 18: 4, ' s] ');
  for I := 1 to Length(S) do
    if S[I] = '|' then begin WriteLn; Write('         ') end
    else Write(S[I]);
  WriteLn;
end;

function ParseSecs: Word;
var I, Code: Integer; S: string; V: Word;
begin
  ParseSecs := 0;
  Quiet := False;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if UpCase(Copy(S, 2, 1)) = 'Q' then Quiet := True;
    if (Length(S) > 3) and (UpCase(S[2]) = 'S') and (S[3] = '=') then begin
      Val(Copy(S, 4, 5), V, Code);
      if Code = 0 then ParseSecs := V;
    end;
  end;
end;

var
  Ok: Boolean;

begin
  WriteLn('PMUSB ', VER, ' -- the PicoMEM''s USB host, watched -- StevenC');
  if not AskBios then begin WriteLn('No PicoMEM BIOS answered INT 13h AH=60h.'); Halt(20); end;
  if TestPort(PmBase, 100) <> 0 then begin WriteLn('No PicoMEM on the test port.'); Halt(20); end;
  Secs := ParseSecs;

  { Find where this firmware writes its answers before reading any.
    It costs one disk-status query, and without it a card with the
    2025-11-02 BIOS reports nothing at all. }
  if FindParam then begin
    if PmParam <> PARAM_OFS then
      WriteLn('answers are at +', PmParam, ' on this firmware, not +',
              PARAM_OFS);
  end else
    WriteLn('could not find the answers area; assuming +', PmParam);

  T0 := Ticks;
  Last := Look(Count, Ok);
  if not Ok then begin WriteLn(Last); Halt(20); end;
  Show(Last, 0);

  if Secs > 0 then begin
    TNext := T0 + 18;
    while Ticks - T0 < LongInt(Secs) * 18 do begin
      if Ticks >= TNext then begin
        TNext := TNext + 18;
        Now_ := Look(Count, Ok);
        if Now_ <> Last then begin
          Write(StdErr, ' '#8);
          Show(Now_, Ticks - T0);
          Last := Now_;
        end;
      end;
      if (not Quiet) and (Ticks and 3 = 0) then begin
        Write(StdErr, Copy('|/-\', (Ticks shr 2) and 3 + 1, 1), #8);
      end;
      if Ticks < T0 then Break;   { midnight }
    end;
    Write(StdErr, ' '#8);
    WriteLn('watched ', Secs, ' s; ', Count, ' device(s) at the end');
  end;
  if Count > 20 then Count := 20;
  Halt(Count);
end.
