program davol;
{ DAVOL -- read and set the volume and mute of a USB audio device over a
  CH375, using Audio Class control transfers.
  CH375Audio, StevenC & Claude.  Public domain (the Unlicense).

    DAVOL [/P=260] [/U=n] [/C=n] [actions...] [/T]

      /P=hex   I/O base, default 260
      /U=dec   feature unit to act on. Default: the first one that has a
               volume or mute control
      /C=dec   channel. 0 = master, 1 = left, 2 = right. Default 0 for
               mute and "every channel that has it" for volume
      /T       trace every control-transfer stage

    ACTIONS, applied strictly LEFT TO RIGHT so one command line can be a
    little script:

      /M=1     mute        /M=0  unmute      /M=T  toggle
      /V=pct   set volume to a percentage of the device's own min..max
      /DB=n    set volume to n dB (accepts negatives: /DB=-12)
      /W=secs  wait, so a change can be heard before the next one
      /RAMP    sweep min to max and back, in steps
      /R       re-read and print the mixer

    With no actions it prints the mixer and exits.

  WHY THIS WORKS WHEN PLAYBACK DOES NOT

  DAPROBE explains at length why audio cannot be streamed through a CH375:
  the endpoint is isochronous, it wants 192-byte packets, and it wants them
  at 192 kB/s.  None of that applies here.  Volume and mute are not on the
  streaming endpoint at all -- they live on a FEATURE UNIT inside the
  AudioControl interface, and they are reached with ordinary CONTROL
  transfers on endpoint 0, which is the one thing this chip does really
  well.  So the speaker is a mixer that DOS can drive even though it is not
  a speaker that DOS can feed.

  THE REQUEST SHAPE, because it is easy to get subtly wrong

    bmRequestType  21h to set, A1h to get.  Class request, recipient
                   INTERFACE -- not endpoint, and not device.
    bRequest       01h SET_CUR, 81h GET_CUR, 82h GET_MIN, 83h GET_MAX,
                   84h GET_RES.
    wValue         control selector in the HIGH byte, channel in the LOW.
                   Mute is selector 01h, volume 02h.
    wIndex         unit ID in the HIGH byte, AudioControl interface number
                   in the LOW.  The interface number is nearly always 0 and
                   is read from the descriptors anyway, because "nearly"
                   is not a thing to build on.
    data           mute is ONE byte; volume is TWO, signed, little-endian.

  VOLUME IS IN dB, NOT IN PERCENT, and that catches people out.  The unit
  is 1/256 dB, so 0000h is 0 dB and FF00h is -1 dB.  8000h is a reserved
  "silence" code rather than a very small number.  A device states its own
  usable range with GET_MIN and GET_MAX and they are NOT -127..0 in
  general, so /V= maps a percentage onto whatever this device actually
  reports rather than onto an assumed range.  That mapping is linear in dB,
  which is roughly linear in perceived loudness -- linear in amplitude
  would put everything useful in the top few percent.

  WHAT IT WILL NOT DO.  It does not set a control the Feature Unit does not
  claim in bmaControls.  A device that says it has no volume on the master
  channel means it, and writing there returns a stall that is easy to
  misread as a dead device. }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, daudio;

const
  VER = '1.0.2';

  CS_INTERFACE  = $24;
  AC_SUBCLASS   = $01;
  AC_FEATURE    = $06;
  CLASS_AUDIO   = $01;

  { Audio Class request codes. }
  SET_CUR = $01;
  GET_CUR = $81;
  GET_MIN = $82;
  GET_MAX = $83;
  GET_RES = $84;

  { Feature Unit control selectors. }
  FU_MUTE   = $01;
  FU_VOLUME = $02;

  RT_SET = $21;                 { host->device, class, interface }
  RT_GET = $A1;                 { device->host, class, interface }

  MAXFU = 8;

type
  TFeature = record
    Id     : Byte;
    Nch    : Byte;              { channels past master }
    Ctl    : array[0..8] of Word;   { [0] master, [1..] channels }
  end;

var
  Big     : TBigCfg;
  BigLen  : Word;
  Fu      : array[0..MAXFU - 1] of TFeature;
  NFu     : Integer;
  AcIf    : Byte;               { AudioControl interface number }
  UseFu   : Integer;            { index into Fu, not a unit ID }
  WantU   : Integer;            { /U=, -1 if not given }
  WantC   : Integer;            { /C=, -1 if not given }
  Acted   : Boolean;
  I       : Integer;
  Pct     : Integer;            { I is a for-loop variable in the arg pass }
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
var V: LongInt; I: Integer; Neg: Boolean;
begin
  V := 0; Neg := False;
  I := From;
  if (I <= Length(A)) and ((A[I] = '-') or (A[I] = '+')) then
  begin
    Neg := A[I] = '-';
    Inc(I);
  end;
  while (I <= Length(A)) and (A[I] >= '0') and (A[I] <= '9') do
  begin
    V := V * 10 + (Ord(A[I]) - 48);
    Inc(I);
  end;
  if Neg then V := -V;
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

{ 1/256 dB as a signed value, printed with one decimal.

  Done in integers on purpose: a coprocessor cannot be assumed -- the tools
  in this collection have to run on machines without one -- and a volume
  readout is not worth a floating-point dependency. }
function DbStr(Raw: Integer): ShortString;
var
  Whole, Frac: Integer;
  Sign: ShortString;
begin
  if Raw = Integer($8000) then
  begin
    DbStr := 'silence (8000h)';
    Exit;
  end;
  if Raw < 0 then Sign := '-' else Sign := '';
  Whole := Abs(Raw) div 256;
  Frac  := ((Abs(Raw) mod 256) * 10) div 256;
  DbStr := Sign + Dec1(Whole) + '.' + Dec1(Frac) + ' dB';
end;

{ ---- the class requests ------------------------------------------- }

function GetCtl(Req, Sel, Chan: Byte; UnitId: Byte;
                Len: Word; var Val: Integer): Boolean;
var
  B  : array[0..3] of Byte;
  Got: Word;
  R  : Integer;
begin
  GetCtl := False;
  Val := 0;
  B[0] := 0; B[1] := 0;
  R := CtrlIn(RT_GET, Req, (Word(Sel) shl 8) or Chan,
              (Word(UnitId) shl 8) or AcIf, Len, B, SizeOf(B), Got);
  if (R <> INT_SUCCESS) or (Got < Len) then Exit;
  if Len = 1 then
    Val := B[0]
  else
    Val := Integer(Word(B[0]) or (Word(B[1]) shl 8));
  GetCtl := True;
end;

function SetCtl(Sel, Chan: Byte; UnitId: Byte;
                Len: Word; Val: Integer): Boolean;
var
  B: array[0..3] of Byte;
  R: Integer;
begin
  B[0] := Lo(Word(Val));
  B[1] := Hi(Word(Val));
  R := CtrlOut(RT_SET, SET_CUR, (Word(Sel) shl 8) or Chan,
               (Word(UnitId) shl 8) or AcIf, B, Byte(Len));
  SetCtl := R = INT_SUCCESS;
end;

{ ---- descriptor scan ----------------------------------------------- }

{ Only what DAVOL needs: which interface carries AudioControl, and every
  Feature Unit with its per-channel control bitmap. DAPROBE prints the
  whole topology; duplicating that here would mean two decoders to keep
  in step, and the one that is wrong is always the one nobody ran. }
procedure ScanConfig;
var
  P    : Word;
  L, T : Byte;
  IfCls, IfSub: Byte;
  K, N : Integer;
  J    : Word;
  W    : Word;
begin
  P := 0; NFu := 0; AcIf := 0;
  IfCls := 0; IfSub := 0;
  while P + 2 <= BigLen do
  begin
    L := Big[P];
    T := Big[P + 1];
    if (L = 0) or (P + L > BigLen) then Break;
    if T = $04 then
    begin
      IfCls := Big[P + 5];
      IfSub := Big[P + 6];
      if (IfCls = CLASS_AUDIO) and (IfSub = AC_SUBCLASS) then
        AcIf := Big[P + 2];
    end
    else if (T = CS_INTERFACE) and (IfCls = CLASS_AUDIO)
            and (IfSub = AC_SUBCLASS) and (Big[P + 2] = AC_FEATURE) then
    begin
      if NFu < MAXFU then
      begin
        Fu[NFu].Id := Big[P + 3];
        K := Big[P + 5];                 { bControlSize }
        if K < 1 then K := 1;
        N := 0;
        J := P + 6;
        while (J + Word(K) <= P + L - 1) and (N <= 8) do
        begin
          W := Big[J];
          if K > 1 then W := W or (Word(Big[J + 1]) shl 8);
          Fu[NFu].Ctl[N] := W;
          Inc(N);
          Inc(J, K);
        end;
        { Channels present, from how many bmaControls entries the
          descriptor actually carries -- NOT from how many of them are
          non-zero. A channel with an all-zero bitmap is still a channel;
          it simply has no controls, and counting by non-zero reported
          this device's microphone unit as having no channels while
          DAPROBE, reading the length, said one. HasCtl already skips
          channels with nothing on them, so the count does not need to.

          Taken HERE, before the padding loop below runs N up to 9 --
          reading it afterwards reported every unit as having 8. }
        Fu[NFu].Nch := N - 1;
        while N <= 8 do
        begin
          Fu[NFu].Ctl[N] := 0;
          Inc(N);
        end;
        Inc(NFu);
      end;
    end;
    Inc(P, L);
  end;
end;

{ Which channel should a volume write go to?

  Master (0) when the unit claims volume there, otherwise every channel
  that does. On this class of device the master carries mute and the two
  audio channels carry volume, so "set the volume" has to mean both of
  them or it means half the stereo image. }
function HasCtl(F, Chan: Integer; Bit: Word): Boolean;
begin
  HasCtl := (Chan <= 8) and ((Fu[F].Ctl[Chan] and Bit) <> 0);
end;

procedure Report;
var
  F, C  : Integer;
  V, Mn, Mx, Rs: Integer;
  Any   : Boolean;
begin
  WriteLn;
  WriteLn('MIXER');
  WriteLn('----------------------------------------------------------------');
  Fld('AudioControl if', Dec1(AcIf));
  for F := 0 to NFu - 1 do
  begin
    WriteLn;
    WriteLn('  feature unit ', Fu[F].Id, '  (', Fu[F].Nch,
            ' channel(s) past master)');
    Any := False;
    for C := 0 to Fu[F].Nch do
    begin
      if HasCtl(F, C, FU_MUTE) then
      begin
        Any := True;
        if GetCtl(GET_CUR, FU_MUTE, C, Fu[F].Id, 1, V) then
          if V = 0 then
            WriteLn('    ch ', C, ' mute   : off')
          else
            WriteLn('    ch ', C, ' mute   : ON')
        else
          WriteLn('    ch ', C, ' mute   : unreadable');
      end;
      if HasCtl(F, C, FU_VOLUME) then
      begin
        Any := True;
        Write('    ch ', C, ' volume : ');
        if GetCtl(GET_CUR, FU_VOLUME, C, Fu[F].Id, 2, V) then
        begin
          Write(DbStr(V), '  (', Hex4(Word(V)), 'h)');
          if GetCtl(GET_MIN, FU_VOLUME, C, Fu[F].Id, 2, Mn)
             and GetCtl(GET_MAX, FU_VOLUME, C, Fu[F].Id, 2, Mx) then
          begin
            Write('  range ', DbStr(Mn), ' .. ', DbStr(Mx));
            if GetCtl(GET_RES, FU_VOLUME, C, Fu[F].Id, 2, Rs) then
              Write('  step ', DbStr(Rs));
          end;
          WriteLn;
        end
        else
          WriteLn('unreadable');
      end;
    end;
    if not Any then
      WriteLn('    nothing this tool can drive');
  end;
end;

{ Pick the unit to act on: the one named with /U=, else the first that
  claims a volume or a mute anywhere. }
procedure ChooseUnit;
var F, C: Integer;
begin
  UseFu := -1;
  if WantU >= 0 then
  begin
    for F := 0 to NFu - 1 do
      if Fu[F].Id = Byte(WantU) then UseFu := F;
    if UseFu < 0 then
      WriteLn('  no feature unit with id ', WantU, '; using the default');
  end;
  if UseFu < 0 then
    for F := 0 to NFu - 1 do
      if UseFu < 0 then
        for C := 0 to Fu[F].Nch do
          if (UseFu < 0)
             and (HasCtl(F, C, FU_VOLUME) or HasCtl(F, C, FU_MUTE)) then
            UseFu := F;
end;

procedure DoMute(Mode: Integer);
var C, V, Done: Integer;
begin
  if UseFu < 0 then Exit;
  Done := 0;
  for C := 0 to Fu[UseFu].Nch do
  begin
    if (WantC >= 0) and (C <> WantC) then Continue;
    if not HasCtl(UseFu, C, FU_MUTE) then Continue;
    V := Mode;
    if Mode = 2 then                      { toggle }
    begin
      if GetCtl(GET_CUR, FU_MUTE, C, Fu[UseFu].Id, 1, V) then
        V := 1 - (V and 1)
      else
        V := 1;
    end;
    if SetCtl(FU_MUTE, C, Fu[UseFu].Id, 1, V) then
    begin
      WriteLn('  unit ', Fu[UseFu].Id, ' ch ', C, ' mute -> ', V);
      Inc(Done);
    end
    else
      WriteLn('  unit ', Fu[UseFu].Id, ' ch ', C, ' mute REFUSED');
  end;
  if Done = 0 then
    WriteLn('  nothing accepted a mute (does any channel claim it?)');
end;

{ Set volume. Pct < 0 means Raw is already a dB value to write. }
procedure DoVol(Pct: Integer; Raw: Integer; UseRaw: Boolean);
var
  C, Mn, Mx, V, Done: Integer;
begin
  if UseFu < 0 then Exit;
  Done := 0;
  for C := 0 to Fu[UseFu].Nch do
  begin
    if (WantC >= 0) and (C <> WantC) then Continue;
    if not HasCtl(UseFu, C, FU_VOLUME) then Continue;
    if UseRaw then
      V := Raw
    else
    begin
      if not (GetCtl(GET_MIN, FU_VOLUME, C, Fu[UseFu].Id, 2, Mn)
              and GetCtl(GET_MAX, FU_VOLUME, C, Fu[UseFu].Id, 2, Mx)) then
      begin
        WriteLn('  ch ', C, ': cannot read the range, so a percentage',
                ' means nothing');
        Continue;
      end;
      { Linear in dB across the device's own stated range. }
      V := Integer(LongInt(Mn) + ((LongInt(Mx) - LongInt(Mn))
                                  * LongInt(Pct)) div 100);
    end;
    if SetCtl(FU_VOLUME, C, Fu[UseFu].Id, 2, V) then
    begin
      WriteLn('  unit ', Fu[UseFu].Id, ' ch ', C, ' volume -> ',
              DbStr(V), '  (', Hex4(Word(V)), 'h)');
      Inc(Done);
    end
    else
      WriteLn('  unit ', Fu[UseFu].Id, ' ch ', C, ' volume REFUSED');
  end;
  if Done = 0 then
    WriteLn('  nothing accepted a volume (does any channel claim it?)');
end;

{ Poll the mixer and report anything that moves.

  This exists because the speaker tested here turned out to have no
  buttons at all -- just a volume knob -- so DAKEYS has nothing to watch on
  it. A knob is either analogue (it moves the amplifier and USB never hears
  about it) or a digital encoder (it moves the Feature Unit, and the host
  can see it). Reading GET_CUR in a loop tells the two apart without
  needing the HID interface at all, and it is the only way to find out
  short of opening the case.

  Bounded by a spin count as well as by the clock, for the same reason
  DAKEYS is: a loop that can only end when the tick counter advances never
  ends if the tick counter stops. }
procedure WatchMixer(Secs: Integer);
var
  C, V, M: Integer;
  LastV, LastM: array[0..8] of Integer;
  T0, Elapsed, Spins: LongInt;
  F, Shown: Integer;
begin
  if UseFu < 0 then Exit;
  F := UseFu;
  for C := 0 to 8 do begin LastV[C] := $7FFF; LastM[C] := -1; end;
  WriteLn;
  WriteLn('  watching unit ', Fu[F].Id, ' for ', Secs,
          's -- turn the knob, press the buttons.');
  WriteLn('  (a key on the DOS keyboard stops early)');
  WriteLn;
  { Drain anything already in the BIOS keyboard buffer BEFORE watching.

    A keystroke left over from the command line -- or from whatever ran
    before -- makes the very first KeyWaiting true, so the loop announces
    that it stopped at the keyboard and exits before it has looked at
    anything once. That is indistinguishable from a watch that ran and saw
    nothing, which is the one answer this is meant to produce. }
  while KeyWaiting do EatKey;
  Shown := 0;
  T0 := Ticks; Spins := 0;
  while True do
  begin
    Elapsed := Ticks - T0;
    if Elapsed < 0 then begin T0 := Ticks; Elapsed := 0; end;
    if Elapsed >= LongInt(Secs) * 182 div 10 then Break;
    Inc(Spins);
    if Spins > 200000 then
    begin
      WriteLn('  stopping: the clock is not advancing.');
      Break;
    end;
    if KeyWaiting then begin EatKey; WriteLn('  stopped.'); Break; end;

    for C := 0 to Fu[F].Nch do
    begin
      if HasCtl(F, C, FU_VOLUME) then
        if GetCtl(GET_CUR, FU_VOLUME, C, Fu[F].Id, 2, V) then
          if V <> LastV[C] then
          begin
            if LastV[C] <> $7FFF then
            begin
              WriteLn('  ch ', C, ' volume now ', DbStr(V),
                      '  (', Hex4(Word(V)), 'h)');
              Inc(Shown);
            end;
            LastV[C] := V;
          end;
      if HasCtl(F, C, FU_MUTE) then
        if GetCtl(GET_CUR, FU_MUTE, C, Fu[F].Id, 1, M) then
          if M <> LastM[C] then
          begin
            if LastM[C] >= 0 then
            begin
              if M = 0 then WriteLn('  ch ', C, ' unmuted')
                       else WriteLn('  ch ', C, ' MUTED');
              Inc(Shown);
            end;
            LastM[C] := M;
          end;
    end;
  end;
  WriteLn;
  if Shown = 0 then
  begin
    WriteLn('  nothing moved.');
    WriteLn('  If the knob was turned during that, it is ANALOGUE: it');
    WriteLn('  changes the amplifier and the USB side never hears about');
    WriteLn('  it. That is not a fault, and nothing here can see it.');
  end
  else
    WriteLn('  ', Shown, ' change(s) seen -- the control IS reported over USB.');
end;

{ A sweep, so a change can be HEARD rather than only read back. The steps
  are coarse on purpose: each one is a pair of control transfers and the
  point is an audible staircase, not a smooth fade. }
procedure Ramp;
var
  Step: Integer;
begin
  WriteLn('  ramping 0 -> 100 -> 0 percent');
  Step := 0;
  while Step <= 100 do
  begin
    DoVol(Step, 0, False);
    DelayMs(400);
    Inc(Step, 20);
  end;
  Step := 80;
  while Step >= 0 do
  begin
    DoVol(Step, 0, False);
    DelayMs(400);
    Dec(Step, 20);
  end;
end;

begin
  Banner('DAVOL', VER, 'USB audio volume and mute');
  if HelpWanted then
  begin
    WriteLn('  DAVOL [/P=260] [/U=n] [/C=n] [actions...] [/T]');
    WriteLn;
    WriteLn('    /U=n    feature unit id      /C=n   channel, 0 = master');
    WriteLn('    /M=1    mute   /M=0 unmute   /M=T   toggle');
    WriteLn('    /V=pct  volume as a percent of the device''s own range');
    WriteLn('    /DB=n   volume in dB, negatives allowed');
    WriteLn('    /W=secs wait            /RAMP  sweep      /R  re-read');
    WriteLn('    /WATCH=secs  poll the mixer and report anything that moves');
    WriteLn;
    WriteLn('  Actions run left to right, so:');
    WriteLn('    DAVOL /V=100 /W=2 /M=1 /W=2 /M=0');
    HelpTail;
    Halt(0);
  end;

  WantU := -1; WantC := -1; Acted := False;

  { The base and the trace flag have to be known BEFORE the bus comes up,
    so they are picked out in their own pass. Everything else is an action
    and runs in order afterwards. }
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    S := UpCase(S[2]) + Copy(S, 3, 250);
    if S[1] = 'P' then Base := HexArg(S, 3)
    else if S = 'T' then CtrlTrace := True;
  end;
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

  ScanConfig;
  if NFu = 0 then
  begin
    WriteLn;
    WriteLn('  no Feature Unit in the descriptors, so this device exposes');
    WriteLn('  no volume or mute to set. DAPROBE prints the full topology.');
    Halt(6);
  end;

  { The selectors have to come before the actions that use them, whatever
    order they were typed in. }
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 3 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    S := UpCase(S[2]) + Copy(S, 3, 250);
    if S[1] = 'U' then WantU := NumArg(S, 3)
    else if S[1] = 'C' then WantC := NumArg(S, 3);
  end;
  ChooseUnit;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] <> '/') and (S[1] <> '-') then Continue;
    S := UpCase(S[2]) + Copy(S, 3, 250);
    { Longest first: DB= would otherwise be read as D. }
    if Copy(S, 1, 3) = 'DB=' then
    begin
      Acted := True;
      DoVol(0, Integer(NumArg(S, 4) * 256), True);
    end
    else if Copy(S, 1, 4) = 'RAMP' then
    begin
      Acted := True;
      Ramp;
    end
    else if S[1] = 'M' then
    begin
      Acted := True;
      if (Length(S) >= 3) and (UpCase(S[3]) = 'T') then DoMute(2)
      else DoMute(Integer(NumArg(S, 3)) and 1);
    end
    else if S[1] = 'V' then
    begin
      Acted := True;
      Pct := Integer(NumArg(S, 3));
      if Pct < 0 then Pct := 0;
      if Pct > 100 then Pct := 100;
      DoVol(Pct, 0, False);
    end
    else if Copy(S, 1, 6) = 'WATCH=' then
    begin
      Acted := True;
      WatchMixer(Integer(NumArg(S, 7)));
    end
    else if S[1] = 'W' then
    begin
      WriteLn('  waiting ', NumArg(S, 3), 's');
      DelayMs(Word(NumArg(S, 3)) * 1000);
    end
    else if S = 'R' then
    begin
      Acted := True;
      Report;
    end;
  end;

  if not Acted then Report;
  WriteLn;
  WriteLn('=== done ===');
  Halt(0);
end.
