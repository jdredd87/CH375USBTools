unit chtool;
{ CHTOOL -- the banner, the version and the /? convention every program in
  CH375USBTools shares.  CH375USBTools, StevenC.  Public domain.

  Every tool in every one of the four projects starts the same way:

      Banner('USBINFO', VER, 'what it is for');
      if HelpWanted then begin Usage; Halt(0); end;

  and every /? screen ends with HelpTail.  Keeping those three in one unit
  is the only way twenty-odd separate programs stay consistent about who
  wrote them and which build is running -- the alternative is twenty-odd
  copies of the same three lines drifting apart, which is what was here
  before.

  Each program carries its own VER constant rather than sharing one from
  here.  They are released together but they do not change together, and a
  shared number would claim otherwise: a tool reporting 1.4.0 because
  something else in the repository moved tells you nothing.

  NO crt UNIT, here or anywhere in this repository.  crt writes straight to
  video memory and bypasses stdout, so anything capturing the output -- a
  pipe, DOSBridge, `> FILE` -- captures nothing at all and the tool looks
  dead.  Plain WriteLn only. }

{$MODE OBJFPC}{$H-}

interface

const
  AUTHOR  = 'StevenC';
  PROJECT = 'CH375USBTools';
  REPO    = 'https://github.com/jdredd87/CH375USBTools';

  { The default CH375 I/O base, in one place so no tool invents its own.
    The board's address is set by jumpers and this is only the usual
    choice; every tool that reaches the chip takes /P=hex to override it. }
  DEF_BASE = $260;

{ The first line of output from every tool:
    USBINFO 1.0.0 -- dump everything a USB device will tell you -- StevenC
  Prog is upper case because that is how it is typed at the DOS prompt, and
  the author is on this line rather than only in the /? footer so that a
  program run WITHOUT /? still says who wrote it -- which is how the three
  assembly drivers have always announced themselves.  The longest purpose
  in the repository puts this at 75 columns, inside the 79 a DOS line has. }
procedure Banner(const Prog, Ver, Purpose: ShortString);

{ True when the command line is asking for the help screen rather than for
  work: /? -? ? /HELP -HELP --HELP, in any case.

  Bare /H is deliberately NOT accepted.  USBKBD and USBCOMBO already use
  /H for the INT 16h hook, and a switch that means "help" in one program
  and something else in the next is worse than no shorthand at all. }
function HelpWanted: Boolean;

{ The last lines of every /? screen: who wrote it and where it lives. }
procedure HelpTail;

{ Prints the one line about /P= that belongs on every chip-touching tool's
  help screen, so the wording is identical across all of them. }
procedure HelpBaseLine;

implementation

{ VidFix is pulled in here rather than added to every program's uses
  clause, the way DOSBridge's About unit does it, because it has to run
  BEFORE the program body. FPC's runtime can hook INT 10h with a
  coprocessor stub, and on a 386 with no 387 the first video BIOS call
  then wedges the machine; vidfix.pas puts the vector back, and is inert
  on a V30 and on anything with an FPU.
  FPC initializes a unit's dependencies first, so this is early enough. }
uses vidfix;


procedure Banner(const Prog, Ver, Purpose: ShortString);
begin
  WriteLn(Prog, ' ', Ver, ' -- ', Purpose, ' -- ', AUTHOR);
end;

function UpStr(const S: ShortString): ShortString;
var
  I: Integer;
  T: ShortString;
begin
  T := S;
  for I := 1 to Length(T) do T[I] := UpCase(T[I]);
  UpStr := T;
end;

function HelpWanted: Boolean;
var
  I: Integer;
  A: ShortString;
begin
  HelpWanted := False;
  for I := 1 to ParamCount do
  begin
    A := UpStr(ParamStr(I));
    if (A = '/?')    or (A = '-?')    or (A = '?') or
       (A = '/HELP') or (A = '-HELP') or (A = '--HELP') then
    begin
      HelpWanted := True;
      Exit;
    end;
  end;
end;

procedure HelpBaseLine;
begin
  WriteLn('  /P=hex   CH375 I/O base, default 260.  The board''s address is');
  WriteLn('           set by jumpers; USBSCAN finds it');
end;

procedure HelpTail;
begin
  WriteLn;
  WriteLn(PROJECT, ' -- ', AUTHOR);
  WriteLn(REPO);
  WriteLn('Public domain (the Unlicense).  No warranty of any kind.');
end;

end.
