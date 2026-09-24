program evtest;
{ INT 33h event-handler test  --  CH375Mouse, StevenC & Claude
  Public domain (the Unlicense); see LICENSE.

  Function 0Ch installs a callback plus a mask of the events an application
  wants.  The driver must call it only for events in that mask, and must
  tell it in AX which ones happened:

      bit0 moved   bit1/2 left press/release
      bit3/4 right press/release   bit5/6 middle press/release

  The first version of this driver passed AX=1 -- "the pointer moved" -- for
  every report whatever the mask said, so an application subscribed to
  button presses alone was called constantly and never once told a button
  had been pressed.  Movement worked; clicks did not.  This is the test that
  would have caught it.

  Everything is driven through the driver's report-injection hook with
  polling suspended, so each case is exact.

      EVTEST

  Exit code is the number of failed checks.                               }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

uses Dos, chtool;

const
  VER = '1.0.0';

var
  Fails, Checks: Integer;

  { The driver calls the handler with DS set to its own data segment, so the
    handler has to restore ours before it can touch any of this. }
  EvCount: Word;
  EvSeen : Word;                  { OR of every condition mask we were given }
  EvAX, EvBX, EvCX, EvDX: Word;

procedure MouseHandler; assembler; far;
asm
  push ds
  push ax
  mov  ax, seg EvCount
  mov  ds, ax
  pop  ax
  mov  [EvAX], ax
  mov  [EvBX], bx
  mov  [EvCX], cx
  mov  [EvDX], dx
  or   [EvSeen], ax
  inc  word [EvCount]
  pop  ds
end;

procedure M(var R: Registers);
begin
  Intr($33, R);
end;

procedure Check(const What: ShortString; Ok: Boolean);
begin
  Inc(Checks);
  if Ok then WriteLn('  ok    ', What)
  else begin WriteLn('  FAIL  ', What); Inc(Fails); end;
end;

procedure CheckEq(const What: ShortString; Got, Want: LongInt);
begin
  Inc(Checks);
  if Got = Want then WriteLn('  ok    ', What, ' = ', Got)
  else
  begin
    WriteLn('  FAIL  ', What, ' = ', Got, ', expected ', Want);
    Inc(Fails);
  end;
end;

procedure Inject(Btn: Byte; Dx, Dy: Integer);
var R: Registers;
begin
  R.AX := $7F01;
  R.BX := Btn;
  R.CX := (Word(Dy and $FF) shl 8) or Word(Dx and $FF);
  M(R);
end;

procedure PausePoll(Off: Word);
var R: Registers;
begin
  R.AX := $7F02;
  R.BX := Off;
  M(R);
end;

{ Install our handler with the given event mask. }
procedure Subscribe(Mask: Word);
var R: Registers;
begin
  R.AX := $0C;
  R.CX := Mask;
  R.DX := Ofs(MouseHandler);
  R.ES := Seg(MouseHandler);
  M(R);
  EvCount := 0; EvSeen := 0;
end;

var
  R: Registers;

procedure Usage;
begin
  Banner('EVTEST', VER, 'INT 33h function 0Ch event-handler test');
  WriteLn;
  WriteLn('  EVTEST');
  WriteLn;
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('It takes no other switches, and needs USBMOUSE loaded.');
  WriteLn;
  WriteLn('Function 0Ch installs a callback plus a mask of the events an');
  WriteLn('application wants.  The driver must call it only for events in');
  WriteLn('that mask, and must say in AX which ones happened:');
  WriteLn('  bit0 moved   bit1/2 left press/release');
  WriteLn('  bit3/4 right press/release   bit5/6 middle press/release');
  WriteLn;
  WriteLn('The first version of this driver passed AX=1 -- "the pointer');
  WriteLn('moved" -- for every report whatever the mask said, so an');
  WriteLn('application subscribed to button presses alone was called');
  WriteLn('constantly and never once told a button had been pressed.');
  WriteLn('Movement worked; clicks did not.  This is the test that would');
  WriteLn('have caught it.');
  WriteLn;
  WriteLn('Everything is driven through the driver''s report-injection');
  WriteLn('hook with polling suspended, so each case is exact.');
  WriteLn;
  WriteLn('Exit code is the number of failed checks.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  Fails := 0; Checks := 0;
  Banner('EVTEST', VER, 'USBMOUSE INT 33h event-handler test');

  R.AX := 0; M(R);
  if R.AX <> $FFFF then
  begin
    WriteLn('No INT 33h driver.  Load USBMOUSE first.');
    Halt(20);
  end;
  PausePoll(1);

  { ---- every event, so we can see what each report reports ---- }
  WriteLn;
  WriteLn('subscribed to every event (mask 7F)');
  R.AX := 4; R.CX := 320; R.DX := 100; M(R);
  Subscribe($7F);

  Inject(0, 5, 0);
  CheckEq('movement calls the handler', EvCount, 1);
  CheckEq('  condition = moved', EvAX and $7F, 1);
  CheckEq('  handler got x', EvCX, 325);

  Subscribe($7F);
  Inject(1, 0, 0);
  CheckEq('left press calls the handler', EvCount, 1);
  CheckEq('  condition = left press', EvAX and $7F, 2);
  CheckEq('  handler got the button mask', EvBX, 1);

  Subscribe($7F);
  Inject(0, 0, 0);
  CheckEq('  condition = left release', EvAX and $7F, 4);

  Subscribe($7F);
  Inject(2, 0, 0);
  CheckEq('  condition = right press', EvAX and $7F, 8);
  Subscribe($7F);
  Inject(0, 0, 0);
  CheckEq('  condition = right release', EvAX and $7F, 16);

  Subscribe($7F);
  Inject(4, 0, 0);
  CheckEq('  condition = middle press', EvAX and $7F, 32);
  Subscribe($7F);
  Inject(0, 0, 0);
  CheckEq('  condition = middle release', EvAX and $7F, 64);

  { a press while moving reports both }
  Subscribe($7F);
  Inject(1, 3, 3);
  CheckEq('move and press together', EvAX and $7F, 1 + 2);
  Subscribe($7F);
  Inject(0, 0, 0);

  { ---- the mask must actually be honoured ---- }
  WriteLn;
  WriteLn('subscribed to left press only (mask 02)');
  Subscribe($02);
  Inject(0, 10, 10);
  CheckEq('movement does not call it', EvCount, 0);
  Inject(1, 0, 0);
  CheckEq('left press does call it', EvCount, 1);
  CheckEq('  condition = left press', EvAX and $7F, 2);
  Inject(0, 0, 0);
  CheckEq('left release does not call it', EvCount, 1);

  WriteLn;
  WriteLn('subscribed to movement only (mask 01)');
  Subscribe($01);
  Inject(1, 0, 0);
  CheckEq('a press alone does not call it', EvCount, 0);
  Inject(0, 4, 0);
  CheckEq('movement does', EvCount, 1);

  { ---- unsubscribe ---- }
  WriteLn;
  Subscribe($00);
  Inject(1, 5, 5);
  Inject(0, 0, 0);
  CheckEq('mask 0 stops the callbacks', EvCount, 0);

  R.AX := 0; M(R);                 { reset clears the handler for good }
  PausePoll(0);

  WriteLn;
  WriteLn(Checks - Fails, '/', Checks, ' checks passed.');
  if Fails > 20 then Fails := 20;
  Halt(Fails);
end.
