program dakeys;
{ DAKEYS -- read the transport and volume buttons on a USB audio device
  over a CH375, from its HID interrupt endpoint.
  CH375Audio, StevenC & Claude.  Public domain (the Unlicense).

    DAKEYS [/P=260] [/I=n] [/S=secs] [/X] [/T]

      /P=hex   I/O base, default 260
      /I=dec   HID interface to use. Default: the first one found
      /S=dec   how long to watch, in seconds. Default 30
      /X       print the raw report bytes as well as the names
      /T       trace every control-transfer stage

  WHY THIS ONE WORKS

  The speaker's buttons are not part of the audio at all.  They sit on a
  separate HID interface with an INTERRUPT IN endpoint, and interrupt is
  one of the three transfer types a CH375 does.  So while the audio stream
  is out of reach (DAPROBE explains why at length), the control surface is
  not: a DOS program can watch somebody press play or turn the volume knob
  and do whatever it likes about it.

  That is more useful than it first sounds.  A speaker like this is a
  cheap, standard, hot-pluggable set of buttons -- and on a machine whose
  only input is a keyboard, an eight-button panel that needs no driver and
  no interrupt line is worth having on its own terms.

  THE REPORT IS DECODED FROM THE DEVICE, NOT FROM A TABLE

  A consumer-control report is a bitmap, and which bit means which button
  is decided by the order the usages appear in the HID report descriptor.
  That order is not standard, it is per-device, and guessing it produces a
  tool that works on exactly one speaker.  So DAKEYS fetches the report
  descriptor and reads the usages out of it in order: the Nth usage is bit
  N.  Any consumer-control device then decodes correctly, including ones
  with buttons this author has never seen.

  Only single-bit fields are handled that way, which is what consumer
  controls almost always are (Report Size 1, Report Count n).  A device
  that packs multi-bit fields is reported as raw bytes rather than decoded
  wrongly -- /X shows those anyway.

  SET_IDLE IS SENT AND ITS FAILURE IS IGNORED, deliberately.  It asks the
  device to report only on CHANGE rather than re-sending the same state
  forever, which keeps the poll loop quiet.  Plenty of devices do not
  implement it and answer with a stall; that is not an error worth
  stopping for, and treating it as one would reject working hardware.

  NAK IS THE NORMAL ANSWER.  An interrupt endpoint with nothing to say
  NAKs, and the CH375 reports that as a timeout. A tool that prints
  something on every NAK prints several lines a second and buries the one
  line that matters, so silence is the default and /X is how to see the
  traffic.

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering,
              6 no HID interface on this device }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, daudio;

const
  VER = '1.0.2';
  CLASS_HID = $03;
  MAXUSE    = 64;

var
  Big     : TBigCfg;
  BigLen  : Word;
  Rep     : array[0..511] of Byte;
  RepLen  : Word;
  Usage   : array[0..MAXUSE - 1] of Word;    { bit N -> this usage }
  NUsage  : Integer;
  HidIf   : Integer;
  HidEp   : Byte;
  HidRepLen: Word;
  WantIf  : Integer;
  Secs    : Integer;
  Raw     : Boolean;
  I       : Integer;
  S       : ShortString;
  Rc      : Integer;
  Why     : ShortString;

function Dec1(V: LongInt): ShortString;
var T: ShortString;
begin
  Str(V, T);
  Dec1 := T;
end;

procedure Fld(const N, V: ShortString);
var T: ShortString;
begin
  T := '  ' + N;
  while Length(T) < 20 do T := T + ' ';
  WriteLn(T, ': ', V);
end;

procedure Narrate(const Line: ShortString);
begin
  WriteLn(Line);
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

{ HID Usage Table 1.12, Consumer Page (0x0C). Only the ones that turn up
  on audio hardware; anything else prints as a number, which is still
  useful -- a button with an unknown usage is a button you can see press. }
function UsageName(U: Word): ShortString;
begin
  case U of
    $00B0: UsageName := 'Play';
    $00B1: UsageName := 'Pause';
    $00B2: UsageName := 'Record';
    $00B3: UsageName := 'Fast Forward';
    $00B4: UsageName := 'Rewind';
    $00B5: UsageName := 'Next Track';
    $00B6: UsageName := 'Previous Track';
    $00B7: UsageName := 'Stop';
    $00B8: UsageName := 'Eject';
    $00CD: UsageName := 'Play/Pause';
    $00CA: UsageName := 'Tracking';
    $00CB: UsageName := 'Tracking Increment';
    $00CC: UsageName := 'Stop/Eject';
    $00E0: UsageName := 'Volume';
    $00E2: UsageName := 'Mute';
    $00E5: UsageName := 'Bass Boost';
    $00E9: UsageName := 'Volume Up';
    $00EA: UsageName := 'Volume Down';
    $0150: UsageName := 'Balance Right';
    $0151: UsageName := 'Balance Left';
    $0183: UsageName := 'Media Select';
    $018A: UsageName := 'Mail';
    $0192: UsageName := 'Calculator';
    $0221: UsageName := 'Search';
    $0223: UsageName := 'Home';
    $0224: UsageName := 'Back';
    $0225: UsageName := 'Forward';
  else
    UsageName := 'usage ' + Hex4(U);
  end;
end;

{ Pull the ordered usage list out of a HID report descriptor.

  A report descriptor is a stream of items: one byte of tag/type/size then
  that many bytes of data. Only three tags matter here -- Usage (local,
  tag 8) which names a control, Report Size (global, tag 7) and Report
  Count (global, tag 9), which together say how the named controls are
  packed. Everything else is stepped over by its own length, which is what
  makes walking an unknown descriptor safe.

  The mapping "Nth usage is bit N" holds when Report Size is 1. If it is
  not, ReportBits is left 0 and the caller falls back to raw bytes rather
  than inventing a decode. }
procedure ParseReport(var ReportBits: Integer);
var
  P       : Word;
  B       : Byte;
  Size, Tg: Byte;
  V       : LongInt;
  RSize, RCount: Integer;
  Pend    : array[0..MAXUSE - 1] of Word;
  NPend   : Integer;
  K       : Integer;
begin
  NUsage := 0;
  NPend := 0;
  RSize := 0; RCount := 0;
  ReportBits := 0;
  P := 0;
  while P < RepLen do
  begin
    B := Rep[P];
    Size := B and $03;
    if Size = 3 then Size := 4;
    Tg := B and $FC;
    V := 0;
    if (Size >= 1) and (P + 1 < RepLen) then V := Rep[P + 1];
    if (Size >= 2) and (P + 2 < RepLen) then
      V := V or (LongInt(Rep[P + 2]) shl 8);

    { LOCAL items are consumed by the next MAIN item, which is the whole
      reason usages have to be buffered rather than appended straight to
      the map. The Usage just before a Collection names the COLLECTION --
      here "Consumer Control" -- and is not a field in any report. Counting
      it shifted every button by one bit, so Volume Up read as whatever
      came before it. }
    case Tg of
      $08:                       { Usage (local) }
        if NPend < MAXUSE then
        begin
          Pend[NPend] := Word(V);
          Inc(NPend);
        end;
      $74: RSize  := Integer(V);  { Report Size  (global) }
      $94: RCount := Integer(V);  { Report Count (global) }
      $80:                        { Input: these usages ARE the fields }
        begin
          if (RSize = 1) and (RCount > 0) and (ReportBits = 0) then
          begin
            ReportBits := RCount;
            for K := 0 to NPend - 1 do
              if NUsage < MAXUSE then
              begin
                Usage[NUsage] := Pend[K];
                Inc(NUsage);
              end;
          end;
          NPend := 0;
        end;
      $90, $A0, $B0, $C0:         { Output, Collection, Feature, End }
        NPend := 0;
    end;

    Inc(P, 1 + Size);
  end;
end;

{ Find the HID interface, its IN interrupt endpoint, and that endpoint's
  max packet -- all from the configuration descriptor we already hold. }
procedure FindHid;
var
  P    : Word;
  L, T : Byte;
  Cls  : Byte;
  CurIf: Integer;
  Taken: Boolean;
begin
  HidIf := -1; HidEp := 0; HidRepLen := 0;
  P := 0; Cls := 0; CurIf := -1; Taken := False;
  while P + 2 <= BigLen do
  begin
    L := Big[P];
    T := Big[P + 1];
    if (L = 0) or (P + L > BigLen) then Break;
    if T = $04 then
    begin
      CurIf := Big[P + 2];
      Cls := Big[P + 5];
      if (Cls = CLASS_HID) and (not Taken)
         and ((WantIf < 0) or (CurIf = WantIf)) then
      begin
        HidIf := CurIf;
        Taken := True;
      end;
    end
    else if (T = $21) and (CurIf = HidIf) and (HidIf >= 0) then
      HidRepLen := Big[P + 7] or (Word(Big[P + 8]) shl 8)
    else if (T = $05) and (CurIf = HidIf) and (HidIf >= 0) then
    begin
      { interrupt IN }
      if ((Big[P + 3] and $03) = 3) and ((Big[P + 2] and $80) <> 0) then
        HidEp := Big[P + 2] and $0F;
    end;
    Inc(P, L);
  end;
end;

procedure Watch(Bits: Integer);
var
  Tog   : Byte;
  Buf   : array[0..63] of Byte;
  Got    : Byte;
  R      : Integer;
  Prev   : array[0..7] of Byte;
  T0, Elapsed: LongInt;
  Spins  : LongInt;
  B, K   : Integer;
  Now, Was: Byte;
  Changed: Boolean;
  Any    : Boolean;
begin
  { $80, not 0 -- chdiag, kbdraw and usbpoll all start the toggle here and
    they are the tools that work. }
  Tog := $80;
  Any := False;
  for K := 0 to 7 do Prev[K] := 0;
  T0 := Ticks;
  WriteLn;
  WriteLn('  watching for ', Secs, 's -- press the speaker''s buttons.');
  WriteLn('  (a key on the DOS keyboard stops early)');
  WriteLn;

  { Elapsed, with the BIOS counter's midnight wrap RESET rather than
    treated as "time is up" -- the way every other poll loop here does it.
    Spins is a second, independent bound: if the tick counter ever stops
    advancing, a purely time-based loop never ends, and "the machine is
    frozen" is exactly the report this is being fixed for. }
  { Drain anything already in the BIOS keyboard buffer BEFORE watching.

    A keystroke left over from the command line -- or from whatever ran
    before -- makes the very first KeyWaiting true, so the loop announces
    that it stopped at the keyboard and exits before it has looked at
    anything once. That is indistinguishable from a watch that ran and saw
    nothing, which is the one answer this is meant to produce. }
  while KeyWaiting do EatKey;
  Spins := 0;
  while True do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
    if Elapsed >= LongInt(Secs) * 182 div 10 then Break;
    Inc(Spins);
    if Spins > 400000 then
    begin
      WriteLn('  stopping: ', Spins, ' polls without the clock advancing.');
      Break;
    end;
    if KeyWaiting then
    begin
      EatKey;
      WriteLn('  stopped at the keyboard.');
      Break;
    end;

    R := EpIn(HidEp, Tog, Buf, SizeOf(Buf), Got);
    { A NAK is the endpoint saying "nothing new", which is most of the
      time. Only a real transfer is worth looking at. }
    if (R <> INT_SUCCESS) or (Got = 0) then Continue;

    if Raw then
    begin
      Write('  raw:');
      for K := 0 to Got - 1 do Write(' ', Hex2(Buf[K]));
      WriteLn;
    end;

    Changed := False;
    for K := 0 to Got - 1 do
      if K <= 7 then
        if Buf[K] <> Prev[K] then Changed := True;
    if not Changed then Continue;

    if Bits > 0 then
    begin
      for B := 0 to Bits - 1 do
      begin
        K := B div 8;
        if K >= Got then Break;
        Now := (Buf[K] shr (B mod 8)) and 1;
        if K <= 7 then Was := (Prev[K] shr (B mod 8)) and 1 else Was := 0;
        if (Now = 1) and (Was = 0) then
        begin
          if B < NUsage then
            WriteLn('  DOWN  ', UsageName(Usage[B]))
          else
            WriteLn('  DOWN  bit ', B, ' (no usage named for it)');
          Any := True;
        end
        else if (Now = 0) and (Was = 1) then
          if B < NUsage then
            WriteLn('  up    ', UsageName(Usage[B]));
      end;
    end;

    for K := 0 to Got - 1 do
      if K <= 7 then Prev[K] := Buf[K];
  end;

  WriteLn;
  if not Any then
  begin
    WriteLn('  no button was pressed.');
    WriteLn('  Nothing here can tell that apart from a device that does not');
    WriteLn('  report, so this is not by itself evidence of a fault.');
  end;
end;

var
  Bits: Integer;
  Got : Word;

begin
  Banner('DAKEYS', VER, 'USB audio transport buttons');
  if HelpWanted then
  begin
    WriteLn('  DAKEYS [/P=260] [/I=n] [/S=secs] [/X] [/T]');
    WriteLn;
    WriteLn('    /I=n     HID interface, default the first found');
    WriteLn('    /S=secs  how long to watch, default 30');
    WriteLn('    /X       also print the raw report bytes');
    HelpTail;
    Halt(0);
  end;

  WantIf := -1; Secs := 30; Raw := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    case UpCase(S[2]) of
      'P': Base := HexArg(S, 4);
      'I': WantIf := NumArg(S, 4);
      'S': Secs := NumArg(S, 4);
      'X': Raw := True;
      'T': CtrlTrace := True;
    end;
  end;
  if Secs < 1 then Secs := 1;
  if CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');

  ExitProc := @Quieten;
  Rc := BringUp(Big, BigLen, Why);
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Why <> '' then WriteLn('  ', Why);
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  FindHid;
  if (HidIf < 0) or (HidEp = 0) then
  begin
    WriteLn;
    WriteLn('  no HID interface with an interrupt IN endpoint.');
    WriteLn('  This device has no buttons to read. DAPROBE lists what it');
    WriteLn('  does have.');
    Halt(6);
  end;

  Fld('HID interface', Dec1(HidIf));
  Fld('interrupt EP', Hex2(HidEp) + ' IN');
  Fld('report descriptor', Dec1(HidRepLen) + ' bytes');

  if (HidRepLen = 0) or (HidRepLen > SizeOf(Rep)) then
  begin
    WriteLn('  implausible report descriptor length; not decoding names.');
    Bits := 0;
    NUsage := 0;
  end
  else
  begin
    Rc := CtrlIn($81, REQ_GET_DESCR, Word(DT_HID_REPORT) shl 8,
                 Word(HidIf), HidRepLen, Rep, SizeOf(Rep), Got);
    RepLen := Got;
    if (Rc <> INT_SUCCESS) or (RepLen = 0) then
    begin
      WriteLn('  could not read the report descriptor (', StatusName(Rc),
              '); raw bytes only.');
      Bits := 0;
      NUsage := 0;
    end
    else
    begin
      ParseReport(Bits);
      Fld('usages named', Dec1(NUsage));
      if Bits > 0 then
        Fld('report', Dec1(Bits) + ' single-bit field(s)')
      else
        Fld('report', 'not a plain bitmap; raw bytes only');
      WriteLn;
      WriteLn('  BUTTON MAP (bit -> usage, as this device orders them)');
      for I := 0 to NUsage - 1 do
        WriteLn('    bit ', I:2, '  ', UsageName(Usage[I]));
    end;
  end;

  { Report on change rather than forever. A stall here is common and is
    not a reason to stop -- see the header. }
  Rc := CtrlNoData($21, HID_SET_IDLE, 0, Word(HidIf));
  if Rc <> INT_SUCCESS then
    WriteLn('  (SET_IDLE -> ', StatusName(Rc),
            '; harmless, the device just repeats itself)');

  Watch(Bits);
  WriteLn('=== done ===');
  Halt(0);
end.
