program serterm;
{ SERTERM -- an ANSI terminal on a USB-to-serial adapter, driven by a CH375.
  CH375Serial, StevenC & Claude.  Public domain (the Unlicense).

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

  MONO IS PROBED, NOT ASSUMED.  A video card can come up mono on one
  power cycle and colour on the next with no configuration change, so the
  segment and the attributes are decided at run time from INT 10h AH=1Ah.  A terminal that hardcodes
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

uses ch375, chtool, dser, vidfix;   { vidfix: FPC's runtime can hook INT 10h with a coprocessor stub,
                           which wedges a 386 that has no 387 on the first video
                           call. Inert on a V30 and on anything with an FPU. }

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
  CfgIdx  : Integer;
  Found   : Boolean;
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
  Repeats : Integer;
  DumpScr : Boolean;
  DR, DC  : Integer;
  DB      : Byte;
  DLine   : ShortString;
  Rep     : Integer;
  KickBuf : array[0..95] of Byte;
  KickGot : Byte;
  KickT0, KickEl : LongInt;
  SelfTest : Boolean;

  { screen }
  { TRows is the height of the TERMINAL AREA, which is not the height of
    the screen when a status line is showing.

    This was the whole of a real bug: the status line lives on the last
    row, and the terminal used all 25 rows for text. So the moment output
    reached the bottom, NewLine put the cursor on the status row, ScrollUp
    dragged the status line up into the text, and a clear-screen wiped it.
    The status line was being redrawn once a tick, so it flickered back and
    forth rather than simply vanishing, which made it look like a drawing
    fault rather than a geometry one. }
  TRows   : Integer;
  VSeg    : Word;
  Mono    : Boolean;
  CurX, CurY : Integer;
  SaveX, SaveY : Integer;
  Attr    : Byte;
  FgA, BgA: Byte;
  Bold, Rev: Boolean;

  { ANSI parser }
  EscState: Byte;              { 0 normal, 1 saw ESC, 2 in CSI }
  WrapPend: Boolean;           { the 80th column has been used }
  AutoWrap: Boolean;           { DECAWM, ESC[?7h / ESC[?7l }
  ParamQ  : Boolean;           { this CSI began with ? > or = }
  Blink   : Boolean;           { SGR 5 }
  NoBlink : Boolean;           { /K: bit 7 means bright background }
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
    if Blink then Attr := Attr or $80;
  end;
end;

{ Scroll the text area up one line, with REP MOVSW.

  This was a Pascal loop over MemW[] and it was dropping serial data.
  Every MemW[] access reloads a far pointer -- BENCH measures about 58,640
  of them a second on a period host -- and a scroll is 1920 reads plus 1920
  writes, so roughly 65 ms during which the program is not reading the USB
  port at all. At 9600 baud that is over sixty characters, more than a
  whole packet, and the symptom was lines overwriting each other because
  the lost bytes included the line feeds.

  REP MOVSW beats per-element MemW[] by about 7.4x, measured -- it is the
  same lesson that doubled the bouncing-ball frame rate in the graphics
  work, arriving here from a completely different direction. A terminal is
  a real-time program even though nothing about it looks like one: time
  spent painting is time not spent draining a buffer that keeps filling.

  CX and the fill word are loaded BEFORE DS is changed, because Pascal
  globals live in DS and reading them afterwards would read video memory
  instead. }
procedure ScrollUp;
var
  Cnt, Fill: Word;
begin
  Cnt := Word(TRows - 1) * COLS;
  Fill := (Word(Attr) shl 8) or 32;
  asm
    push ds
    push es
    push si
    push di
    mov cx, Cnt
    mov bx, Fill
    mov ax, VSeg
    mov es, ax
    mov ds, ax
    mov si, COLS * 2
    xor di, di
    cld
    rep movsw
    mov cx, COLS
    mov ax, bx
    rep stosw
    pop di
    pop si
    pop es
    pop ds
  end;
end;

procedure NewLine;
begin
  CurX := 0;
  Inc(CurY);
  if CurY >= TRows then
  begin
    CurY := TRows - 1;
    ScrollUp;
  end;
end;

{ DEFERRED WRAP, which is what ANSI art needs and what a naive terminal
  gets wrong.

  Writing the 80th character must NOT move to the next line. It leaves the
  cursor parked on column 79 with a wrap PENDING, and the line break only
  happens if another printable character actually arrives. Wrapping eagerly
  puts a blank line after every full row, so a picture drawn exactly 80
  columns wide comes out double-spaced and twice the height -- the single
  most common way ANSI art renders wrong.

  Anything that moves the cursor deliberately -- CR, LF, backspace, a
  cursor-positioning sequence -- cancels the pending wrap, because the
  question it answers is only "where does the NEXT character go if nothing
  else has happened". }
procedure PutRaw(C: Char);
begin
  if WrapPend then
  begin
    NewLine;
    WrapPend := False;
  end;
  MemW[VSeg : (CurY * COLS + CurX) * 2] := (Word(Attr) shl 8) or Ord(C);
  Inc(CurX);
  if CurX >= COLS then
  begin
    CurX := COLS - 1;
    WrapPend := AutoWrap;
  end;
end;

{ Same reasoning as ScrollUp: one string instruction rather than 2000
  far-pointer reloads. }
procedure ClearScreen;
var
  Cnt, Fill: Word;
begin
  Cnt := Word(TRows) * COLS;
  Fill := (Word(Attr) shl 8) or 32;
  asm
    push es
    push di
    mov cx, Cnt
    mov ax, Fill
    mov dx, VSeg
    mov es, dx
    xor di, di
    cld
    rep stosw
    pop di
    pop es
  end;
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
    2: begin A := 0; B := COLS * TRows - 1; end;
  else
    begin A := CurY * COLS + CurX; B := COLS * TRows - 1; end;
  end;
  for K := A to B do
    MemW[VSeg : K * 2] := (Word(Attr) shl 8) or 32;
  if Mode = 2 then begin CurX := 0; CurY := 0; end;
end;

{ Blank one row of the text area. }
procedure BlankRow(R: Integer);
var Fill, Off: Word;
begin
  if (R < 0) or (R >= TRows) then Exit;
  Fill := (Word(Attr) shl 8) or 32;
  Off := Word(R) * COLS * 2;
  asm
    push es
    push di
    mov cx, COLS
    mov ax, Fill
    mov dx, VSeg
    mov es, dx
    mov di, Off
    cld
    rep stosw
    pop di
    pop es
  end;
end;

{ Move a block of rows. Count rows starting at From land at Dest.
  Direction is handled by choosing forward or backward copy, so
  overlapping moves -- which is every insert and delete -- stay correct. }
procedure MoveRows(Dest, From, Count: Integer);
var
  K: Integer;
  SOff, DOff, Words: Word;
begin
  if (Count <= 0) or (Dest = From) then Exit;
  Words := COLS;
  if Dest < From then
    for K := 0 to Count - 1 do
    begin
      SOff := Word(From + K) * COLS * 2;
      DOff := Word(Dest + K) * COLS * 2;
      asm
        push ds
        push es
        push si
        push di
        mov cx, Words
        mov ax, VSeg
        mov es, ax
        mov ds, ax
        mov si, SOff
        mov di, DOff
        cld
        rep movsw
        pop di
        pop si
        pop es
        pop ds
      end;
    end
  else
    for K := Count - 1 downto 0 do
    begin
      SOff := Word(From + K) * COLS * 2;
      DOff := Word(Dest + K) * COLS * 2;
      asm
        push ds
        push es
        push si
        push di
        mov cx, Words
        mov ax, VSeg
        mov es, ax
        mov ds, ax
        mov si, SOff
        mov di, DOff
        cld
        rep movsw
        pop di
        pop si
        pop es
        pop ds
      end;
    end;
end;

{ IL / DL: insert or delete N lines at the cursor row, the rest of the
  text area shuffling down or up. A full-screen editor over a serial line
  is built almost entirely out of these two. }
procedure InsertLines(N: Integer);
var K: Integer;
begin
  if N < 1 then N := 1;
  if N > TRows - CurY then N := TRows - CurY;
  MoveRows(CurY + N, CurY, TRows - CurY - N);
  for K := 0 to N - 1 do BlankRow(CurY + K);
end;

procedure DeleteLines(N: Integer);
var K: Integer;
begin
  if N < 1 then N := 1;
  if N > TRows - CurY then N := TRows - CurY;
  MoveRows(CurY, CurY + N, TRows - CurY - N);
  for K := 0 to N - 1 do BlankRow(TRows - 1 - K);
end;

{ ICH / DCH / ECH: the same idea along a row rather than down the screen.
  Done a cell at a time because a row is only eighty words and the string
  instructions would need a segment reload per call for no gain. }
procedure InsertChars(N: Integer);
var K: Integer;
begin
  if N < 1 then N := 1;
  for K := COLS - 1 downto CurX + N do
    MemW[VSeg : (CurY * COLS + K) * 2] :=
      MemW[VSeg : (CurY * COLS + K - N) * 2];
  for K := CurX to CurX + N - 1 do
    if K < COLS then
      MemW[VSeg : (CurY * COLS + K) * 2] := (Word(Attr) shl 8) or 32;
end;

procedure DeleteChars(N: Integer);
var K: Integer;
begin
  if N < 1 then N := 1;
  for K := CurX to COLS - 1 - N do
    MemW[VSeg : (CurY * COLS + K) * 2] :=
      MemW[VSeg : (CurY * COLS + K + N) * 2];
  for K := COLS - N to COLS - 1 do
    if K >= 0 then
      MemW[VSeg : (CurY * COLS + K) * 2] := (Word(Attr) shl 8) or 32;
end;

procedure EraseChars(N: Integer);
var K: Integer;
begin
  if N < 1 then N := 1;
  for K := CurX to CurX + N - 1 do
    if K < COLS then
      MemW[VSeg : (CurY * COLS + K) * 2] := (Word(Attr) shl 8) or 32;
end;

{ Turn the hardware cursor on or off (DECTCEM). Hiding it is what stops a
  block flickering around the screen while a picture is being painted. }
procedure ShowCursor(On_: Boolean);
begin
  if On_ then
    asm
      mov ah, $01
      mov ch, 6
      mov cl, 7
      int $10
    end
  else
    asm
      mov ah, $01
      mov cx, $2000
      int $10
    end;
end;

{ Forward: the ANSI machine has to answer a device-status request, which
  means sending, and the transmit side is declared further down with the
  keyboard it normally serves. Named TxFlush rather than Flush because the
  RTL already has a Flush(var Text) and the collision is silent until the
  first call site fails to resolve. }
procedure TxFlush; forward;
procedure PushStr(const T: ShortString); forward;

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
      FgA := 7; BgA := 0; Bold := False; Rev := False; Blink := False;
    end
    else if V = 1 then Bold := True
    { SGR 5 is "blink", and on a PC that is attribute bit 7 -- which is the
      same bit that means BRIGHT BACKGROUND once blinking is turned off.
      ANSI artists used it for both, so it has to be carried either way and
      /K decides which the hardware does with it. }
    else if V = 5 then Blink := True
    else if V = 7 then Rev := True
    else if V = 22 then Bold := False
    else if V = 25 then Blink := False
    else if V = 27 then Rev := False
    else if (V >= 30) and (V <= 37) then FgA := AnsiToPc[V - 30]
    else if (V >= 40) and (V <= 47) then BgA := AnsiToPc[V - 40]
    { aixterm's bright pairs. Rare in classic art but free to support, and
      a modern host that sends them would otherwise be silently ignored. }
    else if (V >= 90) and (V <= 97) then
    begin
      FgA := AnsiToPc[V - 90]; Bold := True;
    end
    else if (V >= 100) and (V <= 107) then
    begin
      BgA := AnsiToPc[V - 100]; Blink := True;
    end;
  end;
  Recolour;
end;

procedure RunCsi(Final: Char);
var N, M: Integer;
begin
  if NPrm = 0 then begin Prm[0] := 0; NPrm := 1; end;
  N := Prm[0];
  { Any sequence that positions the cursor settles the question a pending
    wrap was waiting to answer. }
  if Final <> 'm' then WrapPend := False;
  case Final of
    'A': begin if N < 1 then N := 1; Dec(CurY, N); if CurY < 0 then CurY := 0; end;
    'B': begin if N < 1 then N := 1; Inc(CurY, N); if CurY >= TRows then CurY := TRows - 1; end;
    'C': begin if N < 1 then N := 1; Inc(CurX, N); if CurX >= COLS then CurX := COLS - 1; end;
    'D': begin if N < 1 then N := 1; Dec(CurX, N); if CurX < 0 then CurX := 0; end;
    'H', 'f':
      begin
        if NPrm >= 2 then M := Prm[1] else M := 1;
        if N < 1 then N := 1;
        if M < 1 then M := 1;
        CurY := N - 1; CurX := M - 1;
        if CurY >= TRows then CurY := TRows - 1;
        if CurX >= COLS then CurX := COLS - 1;
      end;
    'E':                                  { CNL }
      begin
        if N < 1 then N := 1;
        Inc(CurY, N); CurX := 0;
        if CurY >= TRows then CurY := TRows - 1;
      end;
    'F':                                  { CPL }
      begin
        if N < 1 then N := 1;
        Dec(CurY, N); CurX := 0;
        if CurY < 0 then CurY := 0;
      end;
    'G', '`':                             { CHA, absolute column }
      begin
        if N < 1 then N := 1;
        CurX := N - 1;
        if CurX >= COLS then CurX := COLS - 1;
      end;
    'd':                                  { VPA, absolute row }
      begin
        if N < 1 then N := 1;
        CurY := N - 1;
        if CurY >= TRows then CurY := TRows - 1;
      end;
    'J': EraseDisplay(N);
    'K': EraseLine(N);
    'L': InsertLines(N);
    'M': DeleteLines(N);
    '@': InsertChars(N);
    'P': DeleteChars(N);
    'X': EraseChars(N);
    'S':                                  { SU, scroll the area up }
      begin
        if N < 1 then N := 1;
        for M := 1 to N do ScrollUp;
      end;
    'T':                                  { SD, scroll the area down }
      begin
        if N < 1 then N := 1;
        for M := 1 to N do
        begin
          MoveRows(1, 0, TRows - 1);
          BlankRow(0);
        end;
      end;
    'm': ApplySgr;
    's': begin SaveX := CurX; SaveY := CurY; end;
    'u': begin CurX := SaveX; CurY := SaveY; end;
    'n':
      { DEVICE STATUS REPORT, and the reason it earns its place: a BBS
        asks ESC[6n to find out whether there is a terminal on the other
        end and how big it is, and sends plain ASCII to anything that does
        not answer. A terminal that ignores this one sequence never gets
        shown any ANSI art at all. The reply goes back up the wire as if
        it had been typed. }
      begin
        if N = 6 then
          PushStr(#27'[' + Dec1(CurY + 1) + ';' + Dec1(CurX + 1) + 'R')
        else if N = 5 then
          PushStr(#27'[0n');
        TxFlush;
      end;
    'c':
      { DEVICE ATTRIBUTES. Answer as a plain VT101 with no options. }
      begin
        PushStr(#27'[?1;0c');
        TxFlush;
      end;
    'h', 'l':
      { Private modes, which arrive with a '?' that ParamQ has recorded.
        Only two matter here: 7 is autowrap and 25 is cursor visibility. }
      if ParamQ then
      begin
        if N = 25 then ShowCursor(Final = 'h')
        else if N = 7 then
        begin
          AutoWrap := Final = 'h';
          WrapPend := False;
        end;
      end;
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
        else if B = 13 then begin CurX := 0; WrapPend := False; end
        else if B = 10 then begin NewLine; WrapPend := False; end
        else if B = 8 then
        begin
          if CurX > 0 then Dec(CurX);
          WrapPend := False;
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
          NPrm := 0; PrmDig := False; ParamQ := False;
          for I := 0 to 7 do Prm[I] := 0;
        end
        else if C = '7' then
        begin
          { DECSC, the non-CSI save. Some hosts use this instead of ESC[s. }
          SaveX := CurX; SaveY := CurY; EscState := 0;
        end
        else if C = '8' then
        begin
          CurX := SaveX; CurY := SaveY; WrapPend := False; EscState := 0;
        end
        else if (C = '(') or (C = ')') or (C = '#') then
          { A character-set select; the byte after it is part of the
            sequence and must not reach the screen. }
          EscState := 3
        else
          { Anything else after ESC is a sequence this does not implement.
            Swallow it rather than print it: a terminal that echoes the
            codes it cannot handle wrecks the screen it is drawing. }
          EscState := 0;
      end;
    3: EscState := 0;          { swallow the byte after ESC ( ) # }
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
        else if (C = '?') or (C = '>') or (C = '=') then ParamQ := True
        else if C = ' ' then
        else
          EscState := 0;
      end;
  end;
end;

{ Feed a whole string through the terminal, as if it had arrived on the
  wire. Used by the self test, which is the only caller that has bytes
  without a serial port to have produced them. }
procedure EmitStr(const T: ShortString);
var K: Integer;
begin
  for K := 1 to Length(T) do Emit(Ord(T[K]));
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

procedure TxFlush;
begin
  if OutN = 0 then Exit;
  if SerSend(Dev, OutB, OutN) then Inc(NTx, OutN);
  OutN := 0;
end;

procedure Push(B: Byte);
begin
  OutB[OutN] := B;
  Inc(OutN);
  if OutN >= 60 then TxFlush;
  if Echo then Emit(B);
end;

procedure PushStr(const T: ShortString);
var K: Integer;
begin
  for K := 1 to Length(T) do Push(Ord(T[K]));
  TxFlush;
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
          $23: begin PushStr('ATH'); Push(13); TxFlush; end;  { ALT-H }
          $2E: begin ClearScreen; end;               { ALT-C }
        else
          SendExtended(Hi);
        end;
      end
      else
        Push(Lo);
    end;
    TxFlush;

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
    WriteLn('    /R=n   send /I that many times, to force the screen to');
    WriteLn('           scroll when testing');
    WriteLn('    /V     print the finished screen through DOS, so a run');
    WriteLn('           over the bridge can be checked without a camera');
    WriteLn('    /K     blink bit becomes bright-background (ANSI art)');
    WriteLn('    /A     draw the built-in ANSI test pattern and stop');
    WriteLn;
    WriteLn('    ALT-X quit   ALT-H hang up   ALT-C clear');
    HelpTail;
    Halt(0);
  end;

  WantCfg := -1; Baud := 9600; Bits := 8; Par := 0; Stop := 1;
  Batch := 0; Echo := False; Quiet := False; DialNum := '';
  InitCmd := ''; RunSecs := 0; Repeats := 1; DumpScr := False;
  NoBlink := False; SelfTest := False;
  WrapPend := False; Blink := False; AutoWrap := True; ParamQ := False;
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
      'R': Repeats := NumArg(S, 4);
      'V': DumpScr := True;
      'K': NoBlink := True;
      'A': SelfTest := True;
      'T': CtrlTrace := True;
    end;
  end;
  if Baud < 50 then Baud := 9600;
  if Batch = 0 then Batch := SerBatchFor(Baud);
  if Repeats < 1 then Repeats := 1;

  WriteLn('I/O base ', Hex4(Base), 'h');

  ExitProc := @Quieten;
{ FIND THE CONFIGURATION RATHER THAN ASSUMING ONE.

  The default used to be index 1, which is right for the Keyspan on this
  bench -- it declares two configurations and only the second carries a
  bulk pair, its first putting interrupt endpoints where the data should be
  -- and wrong for everything with a single configuration.  An FTDI has
  only index 0, so the default asked for a configuration that does not
  exist and the tool failed before it reached the adapter it was pointed at.

  Trying each in turn and taking the first that yields a serial adapter
  this project can drive costs one descriptor read per miss and makes the
  switch a thing you reach for when a device is unusual, not a thing you
  must know in advance. /C= still forces one. }
  CfgIdx := WantCfg;
  if CfgIdx < 0 then CfgIdx := 0;
  Found := False;
  while CfgIdx <= 3 do
  begin
    Rc := BringUpCfg(Byte(CfgIdx), Big, BigLen, Why);
    if Rc = BU_OK then
    begin
      VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
      PID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
      if SerDetect(Big, BigLen, VID, PID, Dev) then
        if SerSupported(Dev.Family) and (Dev.EpIn <> 0) and (Dev.EpOut <> 0) then
        begin
          Found := True;
          Break;
        end;
    end;
    if WantCfg >= 0 then Break;
    Inc(CfgIdx);
  end;
  if Found then Rc := BU_OK;
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
  { INT 10h AX=1003h BL=0 switches the attribute's top bit from "blink" to
    "bright background", which is what most ANSI art was actually drawn
    for -- sixteen background colours rather than eight and a flash. It is
    off by default because it is a global video state that outlives this
    program, and a terminal that silently changes how the whole machine
    renders text afterwards is a rude thing to write. }
  if NoBlink then
    asm
      mov ax, $1003
      mov bl, 0
      int $10
    end;
  { One row is given up to the status line unless /Q asked for the whole
    screen. Decided here, before anything paints, so every clear, scroll
    and cursor clamp below agrees about where the text ends. }
  if Quiet then TRows := ROWS else TRows := ROWS - 1;
  FgA := 7; BgA := 0; Bold := False; Rev := False;
  Recolour;
  CurX := 0; CurY := 0; SaveX := 0; SaveY := 0;
  EscState := 0; NRx := 0; NTx := 0; OutN := 0;
  ClearScreen;
  Status;
  SetHwCursor;

  { /R sends the opening command more than once, which exists purely so
    the screen can be made to SCROLL on demand. A single ATI7 is sixteen
    lines and never reaches the bottom of a 24-row window, so it could
    never have shown the status line being overwritten -- the bug was
    found by a person watching the real screen, not by this program. }
  { THE ANSI SELF TEST.

    The renderer cannot be checked against a BBS that is not there, and it
    does not need to be: it is a pure function from a byte stream to a
    screen. Feeding it a known stream and dumping the result with /V tests
    exactly the code in question, with no modem, no line and no timing.

    It exercises the four things that separate a terminal from a printer:
    absolute cursor positioning, SGR colour, CP437 line-drawing and
    shading characters, and an EXACTLY 80-column row -- which is the one
    that catches eager wrapping. }
  if SelfTest then
  begin
    EmitStr(#27'[2J'#27'[1;1H');
    EmitStr(#27'[1;33m ANSI self test '#27'[0m');
    EmitStr(#27'[3;1H');
    { A double-line box in CP437: 201 205 187 / 186 / 200 205 188 }
    EmitStr(#27'[36m' + Chr(201));
    for Rep := 1 to 28 do EmitStr(Chr(205));
    EmitStr(Chr(187));
    EmitStr(#27'[4;1H' + Chr(186) + #27'[4;30H' + Chr(186));
    EmitStr(#27'[5;1H' + Chr(200));
    for Rep := 1 to 28 do EmitStr(Chr(205));
    EmitStr(Chr(188) + #27'[0m');
    EmitStr(#27'[4;3H' + #27'[1;37mboxed'#27'[0m');

    { Eight foreground colours, then eight backgrounds. }
    EmitStr(#27'[7;1Hfg:');
    for Rep := 0 to 7 do
    begin
      EmitStr(#27'[3' + Chr(48 + Rep) + 'm');
      EmitStr(Chr(219) + Chr(219));
    end;
    EmitStr(#27'[0m'#27'[8;1Hbg:');
    for Rep := 0 to 7 do
    begin
      EmitStr(#27'[4' + Chr(48 + Rep) + 'm  ');
    end;
    EmitStr(#27'[0m');

    { Shading blocks, the other half of ANSI art. }
    EmitStr(#27'[9;1Hshade:'#27'[37m');
    for Rep := 1 to 8 do EmitStr(Chr(176));
    for Rep := 1 to 8 do EmitStr(Chr(177));
    for Rep := 1 to 8 do EmitStr(Chr(178));
    for Rep := 1 to 8 do EmitStr(Chr(219));
    EmitStr(#27'[0m');

    { Exactly 80 columns. If the wrap is eager this leaves a blank row
      after it and everything below is pushed down by one. }
    EmitStr(#27'[11;1H');
    for Rep := 1 to 8 do EmitStr('1234567890');
    EmitStr(#27'[12;1Hthis line must sit directly under the 80 digits');
    TxFlush;
  end;

  if InitCmd <> '' then
    for Rep := 1 to Repeats do
    begin
      PushStr(InitCmd); Push(13); TxFlush;
      { Drain CONTINUOUSLY for the gap rather than sleeping and reading
        once. A single read after a delay collects one 64-byte packet and
        the rest of the reply backs up in the adapter until it is lost --
        three ATI7s came back as 203 bytes when a single one is about 400.
        The loop below is the same shape as the main terminal loop, which
        is the point: the only reason this is separate code is the repeat
        count. }
      KickT0 := Ticks;
      while True do
      begin
        KickEl := Ticks - KickT0;
        if KickEl < 0 then Break;
        if KickEl >= 27 then Break;          { about 1.5 seconds }
        if SerRecv(Dev, KickBuf, SizeOf(KickBuf), KickGot) then
          if KickGot > 0 then
          begin
            for Rc := 0 to KickGot - 1 do Emit(KickBuf[Rc]);
            Inc(NRx, KickGot);
            Status;
          end;
      end;
    end;

  if DialNum <> '' then
  begin
    PushStr('ATX3');  Push(13); TxFlush;
    PushStr('ATDT' + DialNum); Push(13); TxFlush;
  end;

  Terminal;

  { Release the line on the way out, always. A modem left off-hook stays
    off-hook, and a terminal is precisely the program somebody quits in a
    hurry. }
  SerClose(Dev);

  { /V: print the finished screen back through DOS.

    A terminal draws into video memory, which the bridge cannot capture,
    so the only way to check its output from here was to photograph the
    screen with a capture card and guess when to press the shutter. That
    is a poor test -- three attempts in a row caught the wrong moment and
    said nothing about the program. Dumping the text plane at exit is
    deterministic, needs no camera, and shows exactly what the ANSI
    handling and the scrolling actually produced, status line included. }
  if DumpScr then
  begin
    { READ THE SCREEN BEFORE RESETTING THE VIDEO MODE.

      The first version set mode 3 here to get a clean console and then
      read the text plane -- but setting the mode CLEARS it, so it
      faithfully dumped 25 blank rows after a session that had received
      2087 bytes. The mode reset still happens, just below, after the
      bytes have been read out. }
    WriteLn;
    WriteLn('--- screen as the terminal left it ---');
    for DR := 0 to ROWS - 1 do
    begin
      DLine := '';
      for DC := 0 to COLS - 1 do
      begin
        DB := Byte(MemW[VSeg : (DR * COLS + DC) * 2] and $FF);
        { CP437 graphics are the point of ANSI art, so they must not be
          filtered away by the very tool checking for them -- the first
          version mapped everything outside plain ASCII to a space and
          reported the box-drawing and shading rows as blank. Printable
          ASCII goes through as itself; anything above it becomes '#', so
          its PRESENCE and position are visible even though a captured
          text file cannot show the glyph. }
        if (DB >= 32) and (DB < 127) then
          DLine := DLine + Chr(DB)
        else if DB >= 127 then
          DLine := DLine + '#'
        else
          DLine := DLine + ' ';
      end;
      while (Length(DLine) > 0) and (DLine[Length(DLine)] = ' ') do
        Dec(DLine[0]);
      if DR = ROWS - 1 then
        WriteLn('status|', DLine, '|')
      else
        WriteLn(DR:2, '|', DLine);
    end;
    WriteLn('--- end of screen ---');
  end;

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
