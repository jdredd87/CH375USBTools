unit fosapi;

{ FOSAPI -- the reporting half of CH375Fossil's test programs.

  These programs began life in DOSBridge's projects/ tree and leaned on two
  of its units: About for the banner and Tester for pass/fail counting. A
  project inside this collection should not need another repository to
  compile, so both are replaced here -- the banner by chtool, which every
  tool in this collection already uses, and the counting by the few lines
  below.

  The interface is deliberately identical to DOSBridge's Tester, so the
  programs moved across unchanged apart from their uses clause and one
  Banner call. There is nothing clever in it and there should not be.

  Everything prints through DOS calls. Direct video writes would be faster
  and would also be invisible to DOSBridge, which captures stdout and
  nothing else -- a program that only draws to the screen comes back as an
  empty log. The exit code is the failure count, capped at 20 to match the
  IF ERRORLEVEL ladder DOS 6.22 can actually express.

  StevenC -- https://github.com/jdredd87/CH375USBTools
  Public domain (the Unlicense). }

{$MODE OBJFPC}{$H-}

interface

procedure Check(const Name: ShortString; Passed: Boolean);
procedure Note(const S: ShortString);
procedure Note(const S: ShortString; V: LongInt);
procedure Finish;

function Failures: Integer;
function Passed: Integer;

implementation

var
  Passes: Integer = 0;
  Fails : Integer = 0;

procedure Check(const Name: ShortString; Passed: Boolean);
begin
  if Passed then
  begin
    Inc(Passes);
    WriteLn('PASS  ', Name);
  end
  else
  begin
    Inc(Fails);
    WriteLn('FAIL  ', Name);
  end;
end;

procedure Note(const S: ShortString);
begin
  WriteLn('      ', S);
end;

{ The LongInt overload exists so a caller never has to reach for SysUtils.
  IntToStr and its friends link a great deal of dead weight into a 16-bit
  real-mode binary. }
procedure Note(const S: ShortString; V: LongInt);
begin
  WriteLn('      ', S, V);
end;

function Failures: Integer;
begin
  Failures := Fails;
end;

function Passed: Integer;
begin
  Passed := Passes;
end;

procedure Finish;
var
  Code: Integer;
begin
  WriteLn;
  WriteLn('--- ', Passes, ' passed, ', Fails, ' failed ---');
  Code := Fails;
  if Code > 20 then Code := 20;
  Halt(Code);
end;

end.
