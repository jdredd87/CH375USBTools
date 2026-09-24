program cambtn;
{ CAMBTN -- find the IBM PC Camera's button.  CH375Camera, StevenC & Claude.
  Public domain (the Unlicense).

    CAMBTN [/P=260] [/S=30] [/F=100] [/L=135]

  The camera has a button on it, and nothing written down says how model
  2 reports it.  Linux's driver reads it on models 3 and the NetCam Pro as
  register 0113 -- 00 while held, and it writes 01 there to acknowledge --
  with a note that it is untested on the others.

  ANSWERED, 2026-09-18: it is 0113 on model 2 as well.  It reads 01 at
  rest, goes to 00 when the button is pressed, and stays 00 -- it latches
  -- until 01 is written back.  This tool now acknowledges each press and
  counts them; CAMLIVE saves a picture on each.

  It reads every register from /F to /L (hex, default 0100..0135),
  over and over for /S seconds, and prints each one whose value CHANGES,
  with the time.  It never writes a register.  Run it, and press the
  button a few times while it runs: whatever moves in step with your
  finger is the button.  Registers that drift on their own show up too,
  which is worth knowing -- the first pass prints every register once, as
  the baseline.

  The camera is not streaming while this runs; if the button only reports
  while it is, CAMLIVE's own poll (it watches 0113 between pictures) is
  the place to look instead. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, cit, camgrab;

const
  VER = '0.3.0';

var
  Secs:  Word = 30;
  First: Word = $0100;
  Last:  Word = $0135;
  Base0: array[0..255] of Byte;
  Cur:   array[0..255] of Byte;
  Seen:  array[0..255] of Boolean;
  Changes: Word = 0;
  Video:   Boolean = False;         { /V: watch with the camera streaming }
  Presses: Word = 0;

{ The PC speaker, straight through the timer ports -- channel 2 at Hz,
  for Ms of the BIOS clock -- so whoever is to press the button knows when.
  No Crt: it would take stdout away from DOSBridge. }
procedure Tone(Hz, Ms: Word);
var Div_: Word; T: LongInt;
begin
  Div_ := 1193182 div Hz;
  OutB($43, $B6);
  OutB($42, Lo(Div_)); OutB($42, Hi(Div_));
  OutB($61, InB($61) or 3);
  T := Ticks + (LongInt(Ms) * 182 + 9999) div 10000;
  while Ticks < T do ;
  OutB($61, InB($61) and $FC);
end;

procedure Pause(Ms: Word);
var T: LongInt;
begin
  T := Ticks + (LongInt(Ms) * 182 + 9999) div 10000;
  while Ticks < T do ;
end;

procedure ParseArgs;
var
  I, C: Integer;
  A, V: ShortString;
  N: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    if (Length(A) < 2) or not (A[1] in ['/', '-']) then Continue;
    V := Copy(A, 4, 255);
    case UpCase(A[2]) of
      'P': begin Val('$' + V, N, C); Base := N; end;
      'S': begin Val(V, N, C); if C = 0 then Secs := N; end;
      'F': begin Val('$' + V, N, C); if C = 0 then First := N; end;
      'L': begin Val('$' + V, N, C); if C = 0 then Last := N; end;
      'V': Video := True;
    end;
  end;
  if Last < First then Last := First;
  if Last - First > 255 then Last := First + 255;
end;

var
  R, I: Integer;
  V: Byte;
  PktBuf: array[0..63] of Byte;
  T0, TEnd, Now_: LongInt;
  Beat: Byte = 0;
const
  Spin: array[0..3] of Char = ('|', '/', '-', '\');
begin
  Banner('CAMBTN', VER, 'find the camera''s button');
  if HelpWanted then
  begin
    WriteLn;
    WriteLn('CAMBTN [/P=hex] [/S=secs] [/F=first] [/L=last]');
    WriteLn('Reads camera registers first..last (hex) for secs seconds and');
    WriteLn('prints every change.  Press the camera''s button while it runs.');
    HelpTail;
    Halt(0);
  end;
  ParseArgs;
  PortDat := Base; PortCmd := Base + 1;
  if Video then
  begin
    { exactly as CAMLIVE starts it: model 2 sequence, alt 1, streaming }
    R := CamStart(2, 0);
    if R <> 0 then Halt(R);
    WriteLn('camera streaming, as in CAMLIVE');
  end
  else
  begin
    R := CamUp;
    if R <> 0 then Halt(R);
    LedOn;
  end;

  { a press left latched by an earlier run would hide every new one }
  if RegR($0113, V) = INT_SUCCESS then
    WriteLn('0113 on arrival: ', Hex2(V), '   (00 = a press still latched; cleared)');
  RegW($0001, $0113);

  FillChar(Seen, SizeOf(Seen), 0);
  WriteLn('baseline:');
  for I := 0 to Last - First do
  begin
    if RegR(First + I, V) = INT_SUCCESS then
    begin
      Base0[I] := V; Cur[I] := V; Seen[I] := True;
      Write(' ', Hex4(First + I), '=', Hex2(V));
      if (I + 1) mod 8 = 0 then WriteLn;
    end;
  end;
  WriteLn;
  for I := 5 downto 1 do
  begin
    WriteLn(StdErr, 'get ready to press the camera button ... ', I);
    Tone(440, 100);
    Pause(900);
  end;
  WriteLn('watching for ', Secs, ' s -- press the button now');
  WriteLn(StdErr, '*** PRESS THE CAMERA BUTTON NOW -- ', Secs, ' seconds ***');
  for I := 1 to 3 do begin Tone(1200, 250); Pause(120); end;

  T0 := Ticks;
  TEnd := T0 + LongInt(Secs) * 182 div 10;
  while Ticks < TEnd do
  begin
    { while the button reads pressed, keep acknowledging: the camera
      ignores an acknowledgement while it is still HELD (Linux's note, and
      a press was missed here without this), so the latch only clears on
      an acknowledgement after release }
    if Cur[$0113 - First] = 0 then RegW($0001, $0113);
    for I := 0 to Last - First do
    begin
      if not Seen[I] then Continue;
      if RegR(First + I, V) <> INT_SUCCESS then Continue;
      if V <> Cur[I] then
      begin
        Now_ := (Ticks - T0) * 55;
        WriteLn('  ', Now_:6, ' ms   ', Hex4(First + I), ': ', Hex2(Cur[I]),
                ' -> ', Hex2(V));
        WriteLn(StdErr, '  seen: ', Hex4(First + I), ' ', Hex2(Cur[I]), ' -> ', Hex2(V));
        Cur[I] := V;
        Inc(Changes);
        { 0113 is the button: it goes to 00 when pressed and STAYS there
          -- measured, it latches -- until 01 is written back, which is
          what Linux does for models 3 and the NetCam Pro.  So each press
          is counted and acknowledged, and the next one can be seen. }
        if (First + I = $0113) and (V = 0) then
        begin
          Inc(Presses);
          WriteLn('           button press ', Presses);
          WriteLn(StdErr, '  BUTTON PRESS ', Presses);
          Tone(2000, 60);
        end;
      end;
    end;
    if Video then
      for R := 1 to 50 do Pkt(PktBuf);     { keep the stream drained }
    Inc(Beat);
    Write(StdErr, Spin[Beat and 3], #8);
    if KeyWaiting then begin EatKey; Break; end;
  end;
  Write(StdErr, ' '#8);
  WriteLn(StdErr, '*** done -- you can stop pressing ***');
  Tone(600, 600);
  if Video then CamStop else LedOff;
  WriteLn('changes seen: ', Changes, '   button presses: ', Presses);
  if Changes = 0 then
    WriteLn('nothing moved -- either the button was not pressed, or it does',
            ' not report through these registers while idle');
  { the exit code is the number of presses, so a batch file can tell --
    capped at 20, the most DOSBridge's ERRORLEVEL ladder reads }
  if Presses > 20 then Presses := 20;
  Halt(Presses);
end.
