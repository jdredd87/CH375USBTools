program pm1mouse;
{ PM1MOUSE -- does a USB mouse on the card reach the PC at all?
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1MOUSE [/S=n] [/E-] [/L] [/P=2A0]

  The card's HID driver claims a USB mouse and reports it, but nothing
  arrives on the PC side until something turns the reporting on.  Then
  every movement makes the firmware write three bytes -- an X delta, a
  Y delta and the button mask -- into the IRQ variable structure in its
  shared memory, and raise its multiplexed interrupt.  This enables
  reporting, watches those bytes while you move the mouse, and turns it
  off again.

    /S=n seconds to watch (default 15)
    /B-  do not beep.  By default the PC speaker sounds a rising pair
         when the watch window opens and a falling pair when it shuts,
         because this is a test that needs a hand on the mouse and the
         person with the hand is not reading the screen over the bridge
    /E-  do NOT enable: watch the bytes without sending anything, which
         is the control run -- they should never change
    /L   log each phase to C:\WORK\PM1MOUSE.LOG, closed after every
         line, so a machine that dies still says where it got to
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  THIS IS THE FIRST COMMAND IN THESE TWO PROJECTS THAT IS NOT A QUERY,
  and the reason it is allowed is that its handler is three lines long:
  it sets a boolean, clears the result and returns ready.  It writes no
  file, mounts nothing, moves no memory and saves no configuration --
  in particular it cannot touch the SD card this machine boots from,
  which is the constraint everything else here is shaped around.  The
  matching disable is sent on every exit path, so the card is left as
  it was found.

  What it CANNOT do is give DOS a mouse.  That needs an interrupt
  handler presenting INT 33h, which is a driver and not a probe; the
  card's own distribution has one (its firmware calls it PMMOUSE).
  This only answers whether the data arrives, which is the question
  that has to be answered first.

  Polling cannot catch every event -- the card overwrites the three
  bytes each time and a steady movement writes the same deltas twice --
  so the counts below are a floor, not a total.

  Exit code: 0 movement was seen, 1 no card, 2 the enable was refused,
  3 no shared memory, 4 the answers area was not found, 5 nothing
  moved. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.0.0';

  { pm_irq_svar_t, the IRQ mux's shared variables.  It sits 32 bytes
    below the parameter area: the firmware puts the PC command block at
    the end of the configuration, the IRQ variables 4 bytes after that
    and the parameter area 36 bytes after that.  Deriving it from the
    area PM1CARD found keeps it right on either firmware. }
  V_IRRLIST = 0;    { 6 bytes, one per request source }
  V_ISR     = 6;    { word }
  V_PMIRR   = 8;
  V_PMISR   = 9;
  V_CNT     = 10;
  V_MOUSEX  = 11;   { signed delta }
  V_MOUSEY  = 12;   { signed delta }
  V_MOUSEB  = 13;   { button mask }
  V_LEN     = 14;

  IRQ_R_MOUSE = 3;  { which entry of IRR_list is the mouse }

  CMD_MOUSE_ON  = $52;
  CMD_MOUSE_OFF = $53;

var
  Secs: Word;
  DoEnable, DoLog, DoBeep: Boolean;
  ForceBase: Word;
  VarOfs: Word;
  Rc: Integer;

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
  Secs := 15; DoEnable := True; DoLog := False; DoBeep := True;
  ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'B': DoBeep := not ((Length(S) > 2) and (S[3] = '-'));
        'E': DoEnable := not ((Length(S) > 2) and (S[3] = '-'));
        'L': DoLog := True;
        'S': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 9), W) then Secs := W;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
  if Secs < 1 then Secs := 1;
end;

{ Each line opened, written and closed.  A program that wedges the
  machine leaves nothing in a buffer, so the only account that survives
  is one already on the disk. }
procedure Log(const S: string);
var F: Text;
begin
  if not DoLog then Exit;
  {$I-}
  Assign(F, 'C:\WORK\PM1MOUSE.LOG');
  Append(F);
  if IOResult <> 0 then Rewrite(F);
  if IOResult <> 0 then Exit;
  WriteLn(F, S);
  Close(F);
  {$I+}
  if IOResult <> 0 then ;
end;

{ The PC speaker, straight at the 8253 and port 61h.  Nothing here uses
  Crt: its unit initialisation takes over the output driver and every
  WriteLn after it stops being captured by the bridge.  The wait is on
  the BIOS tick, bounded, and the speaker is put back the way it was. }
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

procedure Quiet(Dur: Word);
var T0: LongInt;
begin
  T0 := Ticks;
  while (Ticks - T0 < Dur) and (Ticks >= T0) do ;
end;

{ Rising: your turn.  Falling: done, stop moving it. }
procedure BeepStart;
begin
  if not DoBeep then Exit;
  Tone(660, 3); Quiet(1); Tone(990, 4);
end;

procedure BeepEnd;
begin
  if not DoBeep then Exit;
  Tone(990, 3); Quiet(1); Tone(660, 4);
end;

function Sgn8(B: Byte): Integer;
begin
  if B > 127 then Sgn8 := Integer(B) - 256 else Sgn8 := B;
end;

function VarB(Ofs: Word): Byte;
begin
  VarB := SharedB(VarOfs + Ofs);
end;

procedure ShowVars(const Lead: string);
var I: Integer; S: string;
begin
  S := '';
  for I := 0 to V_LEN - 1 do S := S + Hex2(VarB(I)) + ' ';
  WriteLn(Lead, S);
end;

function Enable(On_: Boolean): Byte;
var Res: Word; C: Byte;
begin
  if On_ then C := CMD_MOUSE_ON else C := CMD_MOUSE_OFF;
  Res := 0;
  Enable := Command(C, 0, 91, Res);
end;

const
  SPIN: string[4] = '-\|/';

var
  Bad: Word;
  R: Byte;
  T0, TEnd, Spun: LongInt;
  X, Y, B, LX, LY, LB: Byte;
  Events, Req: Word;
  AccX, AccY: LongInt;
  MinX, MaxX, MinY, MaxY: Integer;
  Btns: Byte;
begin
  Args;
  WriteLn('PM1MOUSE ', VER, ' -- does a USB mouse on the card reach the PC?');
  Log('--- PM1MOUSE start');
  Rc := 0;

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h');
    Log('no card'); Halt(1);
  end;
  if not SharedOK then begin
    WriteLn('no shared memory at ', Hex4(PmRomSeg), ':4000');
    Log('no shared memory'); Halt(3);
  end;
  Log('card found');

  if not FindParam then begin
    WriteLn('the answers area was not found, so the IRQ variables cannot');
    WriteLn('be located either -- see PM1INFO.');
    Log('no param area'); Halt(4);
  end;
  VarOfs := PmParam - 32;
  WriteLn('answers at +', PmParam, ', so the IRQ variables are at +', VarOfs);
  Log('param area found');

  WriteLn;
  ShowVars('before : ');

  if DoEnable then begin
    R := Enable(True);
    WriteLn('enable mouse reporting (52h): ', ResultName(R));
    Log('enable sent');
    if R <> CR_OK then begin
      WriteLn('the card would not take it -- nothing to watch.');
      Halt(2);
    end;
  end else
    WriteLn('NOT enabling (/E-): the control run, and nothing should move');

  WriteLn;
  WriteLn('move the mouse for ', Secs, ' seconds -- the speaker says when');
  Log('watch start');
  BeepStart;

  LX := VarB(V_MOUSEX); LY := VarB(V_MOUSEY); LB := VarB(V_MOUSEB);
  Events := 0; Req := 0; AccX := 0; AccY := 0; Btns := 0;
  MinX := 0; MaxX := 0; MinY := 0; MaxY := 0;
  T0 := Ticks;
  TEnd := T0 + LongInt(Secs) * 91 div 5;
  Spun := -1;

  while (Ticks < TEnd) and (Ticks >= T0) do begin
    if VarB(V_IRRLIST + IRQ_R_MOUSE) <> 0 then Inc(Req);
    X := VarB(V_MOUSEX); Y := VarB(V_MOUSEY); B := VarB(V_MOUSEB);
    if (X <> LX) or (Y <> LY) or (B <> LB) then begin
      Inc(Events);
      AccX := AccX + Sgn8(X);
      AccY := AccY + Sgn8(Y);
      if Sgn8(X) < MinX then MinX := Sgn8(X);
      if Sgn8(X) > MaxX then MaxX := Sgn8(X);
      if Sgn8(Y) < MinY then MinY := Sgn8(Y);
      if Sgn8(Y) > MaxY then MaxY := Sgn8(Y);
      Btns := Btns or B;
      if Events <= 12 then
        WriteLn('  ', (Ticks - T0) * 5 div 91:3, 's  dx ', Sgn8(X):4,
                '  dy ', Sgn8(Y):4, '  buttons ', Hex2(B));
      LX := X; LY := Y; LB := B;
    end;
    if Ticks shr 2 <> Spun then begin
      Spun := Ticks shr 2;
      Write(StdErr, SPIN[1 + (Spun and 3)], #8);
    end;
  end;
  Write(StdErr, ' ', #8);
  BeepEnd;
  Log('watch done');

  if Events > 12 then
    WriteLn('  ... ', Events - 12, ' more not printed');

  WriteLn;
  ShowVars('after  : ');

  if DoEnable then begin
    R := Enable(False);
    WriteLn('disable mouse reporting (53h): ', ResultName(R));
    Log('disable sent');
  end;

  WriteLn;
  WriteLn('changes seen   : ', Events);
  WriteLn('mouse IRQ asked: ', Req, ' polls found the request flag set');
  if Events > 0 then begin
    WriteLn('deltas         : x ', MinX, ' to ', MaxX, ', y ', MinY, ' to ',
            MaxY);
    WriteLn('summed movement: x ', AccX, ', y ', AccY,
            '  (a floor -- polling misses events)');
    WriteLn('buttons seen   : ', Hex2(Btns));
    WriteLn;
    WriteLn('So the card does deliver mouse movement to the PC side.  Giving');
    WriteLn('DOS a pointer from it needs an INT 33h driver, which is a');
    WriteLn('different piece of work -- see NEXT.md.');
  end else begin
    WriteLn;
    if DoEnable then begin
      WriteLn('Nothing moved.  Either the mouse was not moved, the card did');
      WriteLn('not claim it (PM1STAT says), or reporting needs more than the');
      WriteLn('enable command.');
      Rc := 5;
    end else
      WriteLn('Nothing moved, which is what the control run should show.');
  end;
  Log('end');
  Halt(Rc);
end.
