program serterm;
{ SERTERM -- an ANSI terminal on a USB-to-serial adapter, driven by a CH375.
  CH375Serial, StevenC.  Public domain (the Unlicense).

    SERTERM [/P=260] [/C=n] [/B=9600] [/8|/7] [/E|/O] [/2] [/F=n]
            [/L] [/D=num] [/Q] [/T]

      /P=hex   I/O base, default 260
      /C=dec   configuration INDEX, default 1 (see below)
      /B=dec   baud rate, default 9600
      /7 /8    data bits, default 8
      /E /O    even or odd parity, default none
      /2       two stop bits, default one
      /F=dec   characters the adapter batches per USB packet. Default is
               computed from the baud rate and should be left alone
      /L       local echo, for a device that does not echo
      /D=num   dial this number as soon as the port opens
      /Q       quiet: no status line
      /T       trace every control-transfer stage

    ALT-X quits.  ALT-H hangs up (ATH).  ALT-C clears the screen.

  WHY A TERMINAL RATHER THAN A ONE-SHOT

  SERTALK sends one command per run, which is right for an experiment and
  useless for anything else -- every run re-enumerates the bus, so a modem
  conversation is impossible.  This holds the port open and puts the
  keyboard at one end and the screen at the other, which is what makes the
  adapter a usable thing rather than a proven one.

  THIS IS THE ONE PROGRAM HERE THAT WRITES STRAIGHT TO VIDEO MEMORY

  Everything else in this collection prints through DOS so the bridge can
  capture it.  A terminal cannot: it needs the cursor anywhere on the
  screen, in any colour, without scrolling the whole display.  So it
  writes to B800 (or B000) directly and the bridge sees nothing, which is
  why it prints a DOS summary on the way out -- otherwise a run over the
  bridge would report an empty log and look like a program that did not
  start.

  MONO IS PROBED, NOT ASSUMED.  The video card in the machine this was
  written for boots to mono on some power cycles and colour on others,
  with no configuration change, so the segment and the attributes are
  decided at run time from INT 10h AH=1Ah.  A terminal that hardcodes
  B800 writes into nothing on those boots and looks hung.

  WHICH CONFIGURATION.  The reference adapter has two, and only the second
  has bulk IN endpoints; see the README.  /C=1 is the default here because
  of that, which is the wrong default for a device with only one
  configuration -- pass /C=0 for those.  SERPROBE reports which is which.

  ANSI SUPPORT is the part a BBS actually uses: cursor movement, cursor
  save and restore, erase in line and display, and SGR colour including
  bold as bright.  Sequences it does not know are swallowed rather than
  printed, because a terminal that prints the escape codes it cannot
  handle destroys the screen it is trying to draw.

  Exit codes: 0 normal, 1 no chip, 3 nothing attached, 5 device stopped
              answering, 6 not a serial adapter this can drive }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, dser;

const
  VER = '0.2.0';
  COLS = 80;
  ROWS = 25;

  { ANSI colour order is not the PC's. Black, red, green, yellow, blue,
    magenta, cyan, white becomes 0,4,2,6,1,5,3,7 in CGA attribute bits --
    red and blue are swapped. Getting this wrong is the classic "the BBS
    looks wrong but readable" bug. }
  AnsiToPc: array[0..7] of Byte = (0, 4, 2, 6, 1, 5, 3, 7);

var
  Big     : TBigCfg;
  BigLen  : Word;
  Why     : ShortString;
  Dev     : TSerDev;
  VID, PID: Word;
  Rc      : Integer;
  I       : Integer;
  S       : ShortString;

  { settings }
  WantCfg : Integer;
  Baud    : LongInt;
  Bits    : Byte;
  Par     : Byte;
  Stop    : Byte;
  Batch   : Byte;
  Echo    : Boolean;
  Quiet   : Boolean;
  DialNum : ShortString;
  InitCmd : ShortString;
  RunSecs : Integer;

  { screen }
  VSeg    : Word;
  Mono    : Boolean;
  CurX, CurY : Integer;
  SaveX, SaveY : Integer;
  Attr    : Byte;
  FgA, BgA: Byte;
  Bold, Rev: Boolean;

  { ANSI parser }
  EscState: Byte;              { 0 normal, 1 saw ESC, 2 in CSI }
  Prm     : array[0..7] of Integer;
  NPrm    : Integer;
  PrmDig  : Boolean;

  { counters, for the summary that DOS can see }
  NRx, NTx: LongInt;
  Running : Boolean;

function Dec1(V: LongInt): ShortString;
var T: ShortString;
begin
  Str(V, T);
  Dec1 := T;
end;

function NumArg(const A: ShortString; From: Integer): LongInt;
var V: LongInt; I: Integer;
begin
  V := 0; I := From;
  while (I <= Length(A)) and (A[I] >= '0') and (A[I] <= '9') do
  begin
    V := V * 10 + (Ord(A[I]) - 48);
    Inc(I);
  end;
  NumArg := V;
end;

function HexArg(const A: ShortString; From: Integer): Word;
var V, I: Integer; C: Char;
begin
  V := 0;
  for I := From to Length(A) do
  begin
    C := UpCase(A[I]);
    if (C >= '0') and (C <= '9') then V := V * 16 + (Ord(C) - 48)
    else if (C >= 'A') and (C <= 'F') then V := V * 16 + (Ord(C) - 55)
    else Break;
  end;
  HexArg := V;
end;

{ ---- screen ------------------------------------------------------ }

{ Mono or colour, asked of the BIOS rather than assumed. AL = 1Ah means
  the call is supported and BL holds the code; 1, 5, 7 and 0Bh are the
  monochrome ones. }
procedure ProbeVideo;
var Code: Byte; Ok: Boolean;
begin
  Code := 0; Ok := False;
  asm
    mov ax, $1A00
    int $10
    cmp al, $1A
    jne @@no
    mov Ok, 1
    mov Code, bl
  @@no:
  end;
  if Ok and ((Code = 1) or (Code = 5) or (Code = 7) or (Code = $0B)) then
    Mono := True
  else
    Mono := False;
  if Mono then VSeg := $B000 else VSeg := $B800;
end;

procedure SetHwCursor;
var P: Word;
begin
  P := Word(CurY) * COLS + Word(CurX);
  asm
    mov ah, $02
    mov bh, 0
    mov dh, byte ptr CurY
    mov dl, byte ptr CurX
    int $10
  end;
end;

procedure Recolour;
var F, B: Byte;
begin
  F := FgA; B := BgA;
  if Rev then begin F := BgA; B := FgA; end;
  if Mono then
  begin
    { A colour ramp is not safe on mono: the monitor sums the guns, so two
      different colours land on the same grey. Mono gets underline and
      bright instead. }
    if Rev then Attr := $70 else Attr := $07;
    if Bold then Attr := Attr or $08;
  end
  else
  begin
    Attr := (B shl 4) or F;
    if Bold then Attr := Attr or $08;
  end;
end;

procedure ScrollUp;
var
  Src, Dst: Word;
  K: Word;
begin
  for K := 0 to (COLS * (ROWS - 1)) - 1 do
  begin
    Dst := K * 2;
    Src := Dst + COLS * 2;
    MemW[VSeg : Dst] := MemW[VSeg : Src];
  end;
  for K := 0 to COLS - 1 do
    MemW[VSeg : (COLS * (ROWS - 1) + K) * 2] :=
      (Word(Attr) shl 8) or 32;
end;

procedure NewLine;
begin
  CurX := 0;
  Inc(CurY);
  if CurY >= ROWS then
  begin
    CurY := ROWS - 1;
    ScrollUp;
  end;
end;

procedure PutRaw(C: Char);
begin
  MemW[VSeg : (CurY * COLS + CurX) * 2] := (Word(Attr) shl 8) or Ord(C);
  Inc(CurX);
  if CurX >= COLS then NewLine;
end;

procedure ClearScreen;
var K: Word;
begin
  for K := 0 to COLS * ROWS - 1 do
    MemW[VSeg : K * 2] := (Word(Attr) shl 8) or 32;
  CurX := 0; CurY := 0;
end;

procedure EraseLine(Mode: Integer);
var A, B, K: Integer;
begin
  case Mode of
    1: begin A := 0; B := CurX; end;
    2: begin A := 0; B := COLS - 1; end;
  else
    begin A := CurX; B := COLS - 1; end;
  end;
  for K := A to B do
    MemW[VSeg : (CurY * COLS + K) * 2] := (Word(Attr) shl 8) or 32;
end;

procedure EraseDisplay(Mode: Integer);
var A, B, K: Integer;
begin
  case Mode of
    1: begin A := 0; B := CurY * COLS + CurX; end;
    2: begin A := 0; B := COLS * ROWS - 1; end;
  else
    begin A := CurY * COLS + CurX; B := COLS * ROWS - 1; end;
  end;
  for K := A to B do
    MemW[VSeg : K * 2] := (Word(Attr) shl 8) or 32;
  if Mode = 2 then begin CurX := 0; CurY := 0; end;
end;

{ ---- the ANSI state machine -------------------------------------- }

procedure ApplySgr;
var K, V: Integer;
begin
  if NPrm = 0 then
  begin
    NPrm := 1; Prm[0] := 0;
  end;
  for K := 0 to NPrm - 1 do
  begin
    V := Prm[K];
    if V = 0 then
    begin
      FgA := 7; BgA := 0; Bold := False; Rev := False;
    end
    else if V = 1 then Bold := True
    else if V = 7 then Rev := True
    else if V = 22 then Bold := False
    else if V = 27 then Rev := False
    else if (V >= 30) and (V <= 37) then FgA := AnsiToPc[V - 30]
    else if (V >= 40) and (V <= 47) then BgA := AnsiToPc[V - 40];
  end;
  Recolour;
end;

procedure RunCsi(Final: Char);
var N, M: Integer;
begin
  if NPrm = 0 then begin Prm[0] := 0; NPrm := 1; end;
  N := Prm[0];
  case Final of
    'A': begin if N < 1 then N := 1; Dec(CurY, N); if CurY < 0 then CurY := 0; end;
    'B': begin if N < 1 then N := 1; Inc(CurY, N); if CurY >= ROWS then CurY := ROWS - 1; end;
    'C': begin if N < 1 then N := 1; Inc(CurX, N); if CurX >= COLS then CurX := COLS - 1; end;
    'D': begin if N < 1 then N := 1; Dec(CurX, N); if CurX < 0 then CurX := 0; end;
    'H', 'f':
      begin
        if NPrm >= 2 then M := Prm[1] else M := 1;
        if N < 1 then N := 1;
        if M < 1 then M := 1;
        CurY := N - 1; CurX := M - 1;
        if CurY >= ROWS then CurY := ROWS - 1;
        if CurX >= COLS then CurX := COLS - 1;
      end;
    'J': EraseDisplay(N);
    'K': EraseLine(N);
    'm': ApplySgr;
    's': begin SaveX := CurX; SaveY := CurY; end;
    'u': begin CurX := SaveX; CurY := SaveY; end;
  end;
end;

{ One received byte through the terminal. }
procedure Emit(B: Byte);
var C: Char;
begin
  C := Chr(B);
  case EscState of
    0:
      begin
        if B = 27 then EscState := 1
        else if B = 13 then CurX := 0
        else if B = 10 then NewLine
        else if B = 8 then
        begin
          if CurX > 0 then Dec(CurX);
        end
        else if B = 9 then
        begin
          repeat PutRaw(' ') until (CurX mod 8) = 0;
        end
        else if B = 7 then
        else if B >= 32 then PutRaw(C);
      end;
    1:
      begin
        if C = '[' then
        begin
          EscState := 2;
          NPrm := 0; PrmDig := False;
          for I := 0 to 7 do Prm[I] := 0;
        end
        else
          { Anything else after ESC is a sequence this does not implement.
            Swallow it rather than print it: a terminal that echoes the
            codes it cannot handle wrecks the screen it is drawing. }
          EscState := 0;
      end;
    2:
      begin
        if (B >= Ord('0')) and (B <= Ord('9')) then
        begin
          if not PrmDig then
          begin
            if NPrm < 8 then Inc(NPrm);
            PrmDig := True;
          end;
          if NPrm > 0 then
            Prm[NPrm - 1] := Prm[NPrm - 1] * 10 + (B - 48);
        end
        else if C = ';' then
        begin
          if not PrmDig then if NPrm < 8 then Inc(NPrm);
          PrmDig := False;
        end
        else if (B >= 64) and (B <= 126) then
        begin
          RunCsi(C);
          EscState := 0;
        end
        else if C = '?' then
        else
          EscState := 0;
      end;
  end;
end;

{ ---- status line ------------------------------------------------- }

procedure Status;
var
  T: ShortString;
  K: Integer;
  A: Byte;
begin
  if Quiet then Exit;
  T := ' ' + SerFamilyName(Dev.Family) + '  ' + Dec1(Baud) + ' ';
  case Par of
    1: T := T + '8O1';
    2: T := T + '8E1';
  else
    T := T + Dec1(Bits) + 'N' + Dec1(Stop);
  end;
  T := T + '   rx ' + Dec1(NRx) + '  tx ' + Dec1(NTx)
         + '   ALT-X quit  ALT-H hangup ';
  while Length(T) < COLS do T := T + ' ';
  if Mono then A := $70 else A := $1F;
  for K := 0 to COLS - 1 do
    MemW[VSeg : ((ROWS - 1) * COLS + K) * 2] :=
      (Word(A) shl 8) or Ord(T[K + 1]);
end;

{ ---- keyboard ---------------------------------------------------- }

function KeyReady: Boolean; assembler;
asm
  mov ah, 1
  int $16
  mov al, 0
  jz @@no
  mov al, 1
@@no:
end;

function KeyRead: Word; assembler;
asm
  mov ah, 0
  int $16
end;

var
  OutB : array[0..79] of Byte;
  OutN : Byte;

procedure Flush;
begin
  if OutN = 0 then Exit;
  if SerSend(Dev, OutB, OutN) then Inc(NTx, OutN);
  OutN := 0;
end;

procedure Push(B: Byte);
begin
  OutB[OutN] := B;
  Inc(OutN);
  if OutN >= 60 then Flush;
  if Echo then Emit(B);
end;

procedure PushStr(const T: ShortString);
var K: Integer;
begin
  for K := 1 to Length(T) do Push(Ord(T[K]));
  Flush;
end;

{ Arrow keys and the like become the ANSI sequences a host expects. }
procedure SendExtended(Scan: Byte);
begin
  case Scan of
    $48: PushStr(#27'[A');
    $50: PushStr(#27'[B');
    $4D: PushStr(#27'[C');
    $4B: PushStr(#27'[D');
    $47: PushStr(#27'[H');
    $4F: PushStr(#27'[K');
    $52: PushStr(#27'[L');
    $53: PushStr(#127);
  end;
end;

procedure Terminal;
var
  K   : Word;
  Lo, Hi: Byte;
  Buf : array[0..95] of Byte;
  Got : Byte;
  J   : Integer;
  Tick, LastTick, T0, Elapsed: LongInt;
begin
  Running := True;
  LastTick := Ticks;
  T0 := Ticks;
  while Running do
  begin
    { An automatic exit, so the thing can be tested at all.

      A terminal quits on a keystroke, and the bridge has no keyboard --
      a run without this blocks until somebody walks over to the machine.
      It is also the only way to take a screenshot of a terminal session
      from here, since everything it draws goes to video memory and never
      reaches the captured output. }
    if RunSecs > 0 then
    begin
      Elapsed := Ticks - T0;
      if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
      if Elapsed >= LongInt(RunSecs) * 182 div 10 then Running := False;
    end;
    { keyboard }
    while KeyReady do
    begin
      K := KeyRead;
      Lo := Byte(K and $FF);
      Hi := Byte((K shr 8) and $FF);
      if Lo = 0 then
      begin
        case Hi of
          $2D: begin Running := False; end;          { ALT-X }
          $23: begin PushStr('ATH'); Push(13); Flush; end;  { ALT-H }
          $2E: begin ClearScreen; end;               { ALT-C }
        else
          SendExtended(Hi);
        end;
      end
      else
        Push(Lo);
    end;
    Flush;

    { serial }
    if SerRecv(Dev, Buf, SizeOf(Buf), Got) then
      if Got > 0 then
      begin
        for J := 0 to Got - 1 do Emit(Buf[J]);
        Inc(NRx, Got);
      end;

    { The status line is redrawn on the CLOCK rather than per byte: at
      38400 a per-byte redraw would spend more time painting the counters
      than reading the port. }
    Tick := Ticks;
    if (Tick <> LastTick) or (Tick < LastTick) then
    begin
      LastTick := Tick;
      Status;
      SetHwCursor;
    end;
  end;
end;

begin
  Banner('SERTERM', VER, 'ANSI terminal on a USB serial adapter');
  if HelpWanted then
  begin
    WriteLn('  SERTERM [/P=260] [/C=n] [/B=9600] [/7|/8] [/E|/O] [/2]');
    WriteLn('          [/F=n] [/L] [/D=num] [/Q] [/T]');
    WriteLn;
    WriteLn('    /B=n   baud, default 9600      /7 /8  data bits');
    WriteLn('    /E /O  even or odd parity      /2     two stop bits');
    WriteLn('    /L     local echo              /D=n   dial on open');
    WriteLn('    /C=n   configuration index, default 1');
    WriteLn('    /Q     no status line');
    WriteLn('    /I=cmd send this command as soon as the port opens');
    WriteLn('    /S=n   quit after n seconds (for unattended testing)');
    WriteLn;
    WriteLn('    ALT-X quit   ALT-H hang up   ALT-C clear');
    HelpTail;
    Halt(0);
  end;

  WantCfg := 1; Baud := 9600; Bits := 8; Par := 0; Stop := 1;
  Batch := 0; Echo := False; Quiet := False; DialNum := '';
  InitCmd := ''; RunSecs := 0;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base := HexArg(S, 4);
      'C': WantCfg := NumArg(S, 4);
      'B': Baud := NumArg(S, 4);
      '7': Bits := 7;
      '8': Bits := 8;
      'E': Par := 2;
      'O': Par := 1;
      '2': Stop := 2;
      'F': Batch := Byte(NumArg(S, 4));
      'L': Echo := True;
      'Q': Quiet := True;
      'D': DialNum := Copy(S, 4, 40);
      'I': InitCmd := Copy(S, 4, 60);
      'S': RunSecs := NumArg(S, 4);
      'T': CtrlTrace := True;
    end;
  end;
  if Baud < 50 then Baud := 9600;
  if Batch = 0 then Batch := SerBatchFor(Baud);

  WriteLn('I/O base ', Hex4(Base), 'h');

  ExitProc := @Quieten;
  Rc := BringUpCfg(Byte(WantCfg), Big, BigLen, Why);
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Why <> '' then WriteLn('  ', Why);
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  PID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  if not SerDetect(Big, BigLen, VID, PID, Dev) then
  begin
    WriteLn('  no bulk endpoint pair; not a serial adapter.');
    Halt(6);
  end;

  WriteLn('  ', Hex4(VID), ':', Hex4(PID), '  ', SerFamilyName(Dev.Family));
  if not SerSupported(Dev.Family) then
  begin
    WriteLn;
    WriteLn('  That family is recognised but has no line-setting path in');
    WriteLn('  dser yet, so its baud rate cannot be configured. SERPROBE');
    WriteLn('  prints what is known about it.');
    Halt(6);
  end;

  WriteLn('  ', Baud, ' baud, batching ', Batch, ' char(s) per packet');
  if not SerOpen(Dev, Baud, Bits, Par, Stop, Batch) then
  begin
    WriteLn('  the adapter would not accept the line settings.');
    Halt(5);
  end;

  ProbeVideo;
  FgA := 7; BgA := 0; Bold := False; Rev := False;
  Recolour;
  CurX := 0; CurY := 0; SaveX := 0; SaveY := 0;
  EscState := 0; NRx := 0; NTx := 0; OutN := 0;
  ClearScreen;
  Status;
  SetHwCursor;

  if InitCmd <> '' then
  begin
    PushStr(InitCmd); Push(13); Flush;
  end;

  if DialNum <> '' then
  begin
    PushStr('ATX3');  Push(13); Flush;
    PushStr('ATDT' + DialNum); Push(13); Flush;
  end;

  Terminal;

  { Release the line on the way out, always. A modem left off-hook stays
    off-hook, and a terminal is precisely the program somebody quits in a
    hurry. }
  SerClose(Dev);

  { Back to DOS output, so a run over the bridge has something to show.
    Everything above this point went straight to video memory and was
    invisible to the capture. }
  asm
    mov ax, $0003
    int $10
  end;
  WriteLn;
  WriteLn('SERTERM: ', NRx, ' bytes received, ', NTx, ' sent, at ',
          Baud, ' baud.');
  WriteLn('=== done ===');
  Halt(0);
end.
