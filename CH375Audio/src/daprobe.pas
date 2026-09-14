program daprobe;
{ DAPROBE -- identify a USB audio device over a CH375 and decode its Audio
  Class descriptors.
  CH375Audio, StevenC.  Public domain (the Unlicense).

    DAPROBE [/P=260] [/V] [/T]

      /P=hex   I/O base, default 260
      /V       narrate the bring-up
      /T       trace every control-transfer stage

  WHY THIS TOOL EXISTS BEFORE ANY PLAYBACK TOOL

  USB audio is the opposite case to the display adapters in CH375Video.
  There a class did not exist and every device was a private protocol; here
  the class is excellent -- Audio Class 1.0 describes the whole device in
  standard descriptors, so one decoder covers every speaker ever made.

  The trouble is somewhere else entirely, and it is worth stating before
  anyone spends a night on it: THE AUDIO ITSELF CANNOT BE PLAYED FROM A
  CH375.  Not slowly, not at a reduced rate, not with cleverness.  Three
  independent limits each rule it out on their own, and this tool measures
  all three against the device actually attached rather than asserting them.

    1. ISOCHRONOUS.  Audio streams over isochronous endpoints, which have
       no handshake -- the host sends a packet per frame and nothing is
       acknowledged.  The CH375 issues a token and then WAITS for a
       handshake (EpOut calls WaitInt), and its data-toggle handling is a
       bulk/interrupt concept that isochronous does not have.  The chip
       has no isochronous mode to put it in.

    2. PACKET SIZE.  A 48 kHz 16-bit stereo stream is 192 bytes per frame,
       and the endpoint says so in wMaxPacketSize.  The CH375 transmits
       out of its own 64-byte buffer and EpOut takes a BYTE length.  A
       192-byte packet cannot be expressed, let alone sent.

    3. RATE.  192 bytes every millisecond is 192,000 bytes/second, and it
       is a hard real-time deadline rather than an average -- a late frame
       is a dropout, not a delay.  The fastest this project has ever driven
       a CH375 is 19,055 bytes/second, measured by DLBENCH on a period host.
       That is an order of magnitude short.

  Any ONE of those ends it.  So this project does what it can actually do,
  and that turns out to be more than nothing:

    * READ the device out completely, which is this tool.
    * SET VOLUME AND MUTE.  Audio Class puts those on the Feature Unit and
      they are reached with CONTROL transfers, which the CH375 does well.
      DAVOL.
    * READ THE BUTTONS.  Most speakers carry a HID interface for their
      play/volume keys on an INTERRUPT endpoint, which the CH375 also
      does.  DAKEYS.

  So the speaker becomes a control surface and a mixer that DOS can drive,
  which is a real thing to have, and the sound keeps coming from whatever
  the speaker is plugged into.  DAISO exists to demonstrate the negative
  rather than to be believed on my say-so.

  WHAT IT DECODES

  The configuration descriptor carries the whole story, so nothing here
  needs a second fetch.  Inside it are three kinds of block:

    * Standard interface and endpoint descriptors, which say how many
      AudioStreaming interfaces there are and what their alternate
      settings cost in bandwidth.  Alt 0 of a streaming interface always
      has ZERO endpoints -- that is the class's way of saying "idle", and
      it is why a speaker that is doing nothing consumes no bus time.

    * Class-specific AudioControl blocks: the topology.  Input and Output
      Terminals are where audio enters and leaves the device, and Feature
      Units sit between them holding the controls.  A Feature Unit's
      bmaControls bitmap is the only trustworthy statement of what can be
      adjusted, which is what DAVOL needs and why it is printed per
      channel rather than summarised.

    * Class-specific AudioStreaming blocks: the format.  bSamFreqType is
      the field that decides whether a slow host has any hope -- a device
      offering a CONTINUOUS range, or a discrete list including something
      like 8 kHz mono, would at least be arguable.  One discrete entry at
      48 kHz stereo is not.  It is reported prominently for that reason.

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering,
              6 attached but it is not an audio device }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, daudio;

const
  VER = '1.0.2';

  { Audio Class 1.0, from the spec's Appendix A. }
  AC_SUBCLASS   = $01;          { bInterfaceSubClass: AudioControl }
  AS_SUBCLASS   = $02;          { bInterfaceSubClass: AudioStreaming }
  MS_SUBCLASS   = $03;          { MIDIStreaming -- seen on some devices }
  CLASS_AUDIO   = $01;
  CLASS_HID     = $03;

  CS_INTERFACE  = $24;
  CS_ENDPOINT   = $25;

  { AC interface descriptor subtypes }
  AC_HEADER     = $01;
  AC_INPUT_TERM = $02;
  AC_OUTPUT_TERM= $03;
  AC_MIXER      = $04;
  AC_SELECTOR   = $05;
  AC_FEATURE    = $06;

  { AS interface descriptor subtypes }
  AS_GENERAL    = $01;
  AS_FORMAT     = $02;

type
  TFeature = record
    Unit_   : Byte;             { bUnitID, for DAVOL's wIndex }
    Source  : Byte;
    Chans   : Byte;             { channels beyond master }
    Master  : Word;             { bmaControls[0] }
    Valid   : Boolean;
  end;

var
  I, J    : Integer;
  S       : ShortString;
  Rc      : Integer;
  Why     : ShortString;
  VID, PID: Word;
  Verbose : Boolean;
  { Our OWN copy of the configuration descriptor, in full.

    BusUp keeps only what its bring-up needed, which on this device is the
    nine-byte header -- it reads that, learns wTotalLength is 232, and has
    no reason to fetch the rest. Walking CfgDesc therefore finds one
    descriptor and concludes the device has no audio interfaces, which is
    exactly what the first run of this tool reported. The truncation
    warning caught it; the fix is to go and get the whole thing. }
  Big     : TBigCfg;
  BigLen  : Word;
  Feat    : array[0..7] of TFeature;
  NFeat   : Integer;
  AudioIfs: Integer;
  PlayEp  : Byte;               { isochronous OUT endpoint, 0 if none }
  PlayMax : Word;
  PlayRate: LongInt;
  PlayCh  : Byte;
  PlayBits: Byte;
  PlayRates: Integer;           { how many discrete rates were offered }
  PlayCont: Boolean;            { continuous range rather than a list }
  { The format block currently in hand, not yet tied to an endpoint. }
  PendCh  : Byte;
  PendBits: Byte;
  PendRate: LongInt;
  PendRates: Integer;
  PendCont: Boolean;
  HidIf   : Integer;
  HidEp   : Byte;

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
  while Length(T) < 22 do T := T + ' ';
  WriteLn(T, ': ', V);
end;

procedure Narrate(const Line: ShortString);
begin
  WriteLn(Line);
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

{ A terminal type is the only place the device says what a stream is FOR.
  0x0101 means "this is the USB side"; anything else is a real transducer,
  and which one decides whether the stream is playback or capture. }
function TermName(T: Word): ShortString;
begin
  case T of
    $0100: TermName := 'USB undefined';
    $0101: TermName := 'USB streaming';
    $0200: TermName := 'input undefined';
    $0201: TermName := 'microphone';
    $0202: TermName := 'desktop microphone';
    $0205: TermName := 'microphone array';
    $0300: TermName := 'output undefined';
    $0301: TermName := 'SPEAKER';
    $0302: TermName := 'headphones';
    $0304: TermName := 'desktop speaker';
    $0306: TermName := 'line connector';
    $0307: TermName := 'legacy audio connector';
    $0602: TermName := 'digital audio interface';
    $0603: TermName := 'line connector';
    $0605: TermName := 'SPDIF';
  else
    TermName := 'type ' + Hex4(T);
  end;
end;

{ The Feature Unit bitmap. Printed as names rather than a hex value because
  the whole point of reading it is to know what DAVOL may attempt, and a
  bitmap nobody expands is a bitmap nobody checks. }
procedure ShowControls(const Pfx: ShortString; B: Word);
var S: ShortString;
begin
  S := '';
  if (B and $0001) <> 0 then S := S + 'mute ';
  if (B and $0002) <> 0 then S := S + 'volume ';
  if (B and $0004) <> 0 then S := S + 'bass ';
  if (B and $0008) <> 0 then S := S + 'mid ';
  if (B and $0010) <> 0 then S := S + 'treble ';
  if (B and $0020) <> 0 then S := S + 'graphic-eq ';
  if (B and $0040) <> 0 then S := S + 'auto-gain ';
  if (B and $0080) <> 0 then S := S + 'delay ';
  if (B and $0100) <> 0 then S := S + 'bass-boost ';
  if (B and $0200) <> 0 then S := S + 'loudness ';
  if S = '' then S := '(none)';
  WriteLn(Pfx, S);
end;

{ Walk the configuration descriptor.

  Every descriptor carries its own length in byte 0, which is what makes a
  single forward walk safe even across blocks this tool does not understand
  -- and there are always some.  A zero length would spin forever, so it is
  treated as the end rather than trusted. }
procedure WalkConfig;
var
  P       : Word;
  L, T, U : Byte;
  IfNum   : Integer;
  IfAlt   : Integer;
  IfCls   : Byte;
  IfSub   : Byte;
  W       : Word;
  R       : LongInt;
  N, K    : Integer;
begin
  P := 0;
  IfNum := -1;
  IfAlt := 0;
  IfCls := 0;
  IfSub := 0;
  NFeat := 0;
  AudioIfs := 0;
  PlayEp := 0;
  HidIf := -1;
  HidEp := 0;
  PlayRates := 0;
  PlayCont := False;

  while P + 2 <= BigLen do
  begin
    L := Big[P];
    T := Big[P + 1];
    if L = 0 then Break;
    if P + L > BigLen then Break;

    case T of
      $04:                       { INTERFACE }
        begin
          IfNum := Big[P + 2];
          IfAlt := Big[P + 3];
          IfCls := Big[P + 5];
          IfSub := Big[P + 6];
          WriteLn;
          Write('  INTERFACE ', IfNum, ' alt ', IfAlt, '  class ',
                Hex2(IfCls), '/', Hex2(IfSub), '  ');
          if IfCls = CLASS_AUDIO then
          begin
            Inc(AudioIfs);
            case IfSub of
              AC_SUBCLASS: WriteLn('AudioControl');
              AS_SUBCLASS: WriteLn('AudioStreaming');
              MS_SUBCLASS: WriteLn('MIDIStreaming');
            else
              WriteLn('audio, subclass ', Hex2(IfSub));
            end;
          end
          else if IfCls = CLASS_HID then
          begin
            WriteLn('HID  <- the buttons, DAKEYS reads this');
            HidIf := IfNum;
          end
          else
            WriteLn(ClassName(IfCls, IfSub, Big[P + 7]));
          if Big[P + 4] = 0 then
            WriteLn('      no endpoints -- this alt setting is the IDLE one');
        end;

      $05:                       { ENDPOINT }
        begin
          W := Big[P + 4] or (Word(Big[P + 5]) shl 8);
          Write('      EP ', Hex2(Big[P + 2]), '  ',
                EpTypeName(Big[P + 3]),
                '  max ', W, '  interval ', Big[P + 6]);
          if (Big[P + 3] and $03) = 1 then
          begin
            { Isochronous. Direction bit 7 of bEndpointAddress. }
            if (Big[P + 2] and $80) = 0 then
            begin
              WriteLn('   <- PLAYBACK');
              PlayEp := Big[P + 2] and $0F;
              PlayMax := W;
              PlayCh    := PendCh;
              PlayBits  := PendBits;
              PlayRate  := PendRate;
              PlayRates := PendRates;
              PlayCont  := PendCont;
            end
            else
              WriteLn('   <- capture');
          end
          else if (Big[P + 3] and $03) = 3 then
          begin
            WriteLn;
            if (IfCls = CLASS_HID) and ((Big[P + 2] and $80) <> 0) then
              HidEp := Big[P + 2] and $0F;
          end
          else
            WriteLn;
        end;

      CS_INTERFACE:
        begin
          U := Big[P + 2];
          if IfSub = AC_SUBCLASS then
            case U of
              AC_HEADER:
                WriteLn('      AC header, adc ', Hex2(Big[P + 4]),
                        '.', Hex2(Big[P + 3]),
                        ', ', Big[P + 7], ' streaming interface(s)');
              AC_INPUT_TERM:
                begin
                  W := Big[P + 4] or (Word(Big[P + 5]) shl 8);
                  WriteLn('      INPUT  terminal id ', Big[P + 3],
                          '  ', TermName(W),
                          '  ', Big[P + 7], ' channel(s)');
                end;
              AC_OUTPUT_TERM:
                begin
                  W := Big[P + 4] or (Word(Big[P + 5]) shl 8);
                  WriteLn('      OUTPUT terminal id ', Big[P + 3],
                          '  ', TermName(W),
                          '  from unit ', Big[P + 7]);
                end;
              AC_SELECTOR:
                WriteLn('      selector unit id ', Big[P + 3]);
              AC_MIXER:
                WriteLn('      mixer unit id ', Big[P + 3]);
              AC_FEATURE:
                begin
                  WriteLn('      FEATURE unit id ', Big[P + 3],
                          '  source ', Big[P + 4],
                          '  control size ', Big[P + 5]);
                  if NFeat <= High(Feat) then
                  begin
                    Feat[NFeat].Unit_  := Big[P + 3];
                    Feat[NFeat].Source := Big[P + 4];
                    Feat[NFeat].Valid  := True;
                    { bmaControls starts at offset 6, bControlSize bytes
                      each, master first then one per channel. }
                    K := Big[P + 5];
                    if K < 1 then K := 1;
                    N := 0;
                    J := P + 6;
                    while (J + K <= P + L - 1) and (N < 8) do
                    begin
                      W := Big[J];
                      if K > 1 then W := W or (Word(Big[J + 1]) shl 8);
                      if N = 0 then
                      begin
                        Feat[NFeat].Master := W;
                        ShowControls('        master : ', W);
                      end
                      else
                        ShowControls('        ch ' + Dec1(N) + '    : ', W);
                      Inc(N);
                      Inc(J, K);
                    end;
                    Feat[NFeat].Chans := N - 1;
                    Inc(NFeat);
                  end;
                end;
            else
              WriteLn('      AC block, subtype ', Hex2(U), ', ', L, ' bytes');
            end
          else if IfSub = AS_SUBCLASS then
            case U of
              AS_GENERAL:
                begin
                  W := Big[P + 5] or (Word(Big[P + 6]) shl 8);
                  Write('      AS general, terminal ', Big[P + 3],
                        ', delay ', Big[P + 4], ', format ');
                  if W = 1 then WriteLn('PCM') else WriteLn(Hex4(W));
                end;
              AS_FORMAT:
                begin
                  if Big[P + 3] = 1 then    { FORMAT_TYPE_I }
                  begin
                    WriteLn('      FORMAT type I: ', Big[P + 4],
                            ' channel(s), ', Big[P + 5],
                            ' byte(s)/sample, ', Big[P + 6], ' bits');
                    N := Big[P + 7];        { bSamFreqType }
                    if N = 0 then
                    begin
                      { A continuous range: lower then upper, 3 bytes each. }
                      R := LongInt(Big[P + 8])
                           or (LongInt(Big[P + 9]) shl 8)
                           or (LongInt(Big[P + 10]) shl 16);
                      WriteLn('        continuous from ', R, ' Hz');
                      R := LongInt(Big[P + 11])
                           or (LongInt(Big[P + 12]) shl 8)
                           or (LongInt(Big[P + 13]) shl 16);
                      WriteLn('                   to   ', R, ' Hz');

                    end
                    else
                    begin
                      for K := 0 to N - 1 do
                      begin
                        J := P + 8 + K * 3;
                        if J + 2 > P + L - 1 then Break;
                        R := LongInt(Big[J])
                             or (LongInt(Big[J + 1]) shl 8)
                             or (LongInt(Big[J + 2]) shl 16);
                        WriteLn('        rate ', K + 1, ': ', R, ' Hz');
                      end;
                    end;
                    { HOLD this format rather than claiming it.

                      A format block describes the alt setting it sits in,
                      and the endpoint that follows it is the one it
                      belongs to. Assigning straight to Play* took whatever
                      came LAST -- which on any speaker with a microphone
                      is the capture format -- and reported this stereo
                      playback stream as 1 channel. The endpoint case
                      below commits these once it knows the direction. }
                    PendCh   := Big[P + 4];
                    PendBits := Big[P + 6];
                    PendRates := N;
                    PendCont := (N = 0);
                    R := LongInt(Big[P + 8])
                         or (LongInt(Big[P + 9]) shl 8)
                         or (LongInt(Big[P + 10]) shl 16);
                    PendRate := R;
                  end
                  else
                    WriteLn('      FORMAT type ', Big[P + 3]);
                end;
            else
              WriteLn('      AS block, subtype ', Hex2(U), ', ', L, ' bytes');
            end
          else
            WriteLn('      CS_INTERFACE, ', L, ' bytes');
        end;

      CS_ENDPOINT:
        WriteLn('      CS_ENDPOINT, attributes ', Hex2(Big[P + 3]));

      $21:                       { HID descriptor }
        { bcdHID is at offset 2, little-endian. Reading it at 3 picks up
          bCountryCode as the major and printed 00.01 for a 1.00 device. }
        WriteLn('      HID descriptor, version ', Hex2(Big[P + 3]),
                '.', Hex2(Big[P + 2]));
    end;

    Inc(P, L);
  end;
end;

{ The verdict. Stated from what was just read, not from a table, because a
  device that DID offer something slow enough deserves to be noticed rather
  than refused on the strength of the last one. }
procedure Verdict;
var
  Need : LongInt;
begin
  WriteLn;
  WriteLn('VERDICT');
  WriteLn('----------------------------------------------------------------');

  if PlayEp = 0 then
  begin
    WriteLn('  No isochronous OUT endpoint was found, so this device has no');
    WriteLn('  playback stream for a host to feed. Nothing to attempt.');
  end
  else
  begin
    Need := LongInt(PlayMax) * 1000;
    Fld('playback endpoint', Hex2(PlayEp) + '  isochronous');
    Fld('packet', Dec1(PlayMax) + ' bytes every 1 ms');
    Fld('format', Dec1(PlayCh) + ' ch, ' + Dec1(PlayBits) + '-bit, '
                  + Dec1(PlayRate) + ' Hz');
    if PlayCont then
      Fld('rates offered', 'a continuous range')
    else
      Fld('rates offered', Dec1(PlayRates) + ' discrete');
    Fld('stream needs', Dec1(Need) + ' bytes/s, hard 1 ms deadlines');
    Fld('this CH375 does', '19055 bytes/s measured (DLBENCH)');
    WriteLn;
    WriteLn('  PLAYBACK IS NOT POSSIBLE, for three separate reasons and any');
    WriteLn('  one of them is enough:');
    WriteLn;
    WriteLn('    isochronous  the CH375 issues a token then waits for a');
    WriteLn('                 handshake. Isochronous has none. There is no');
    WriteLn('                 isochronous mode on the chip to select.');
    Write  ('    packet size  the endpoint wants ', PlayMax, '-byte packets; ');
    WriteLn('the chip sends');
    WriteLn('                 from a 64-byte buffer and EpOut takes a Byte.');
    Write  ('    rate         ', Need, ' bytes/s against 19055 measured');
    WriteLn(', and a');
    WriteLn('                 late frame is a dropout rather than a delay.');
    WriteLn;
    if (PlayRates = 1) and (not PlayCont) then
    begin
      WriteLn('  This device offers exactly ONE rate, so there is not even a');
      WriteLn('  slower format to argue about. See README.md.');
    end
    else
    begin
      WriteLn('  It does offer more than one rate. That changes nothing --');
      WriteLn('  the first two reasons do not care about the rate -- but it');
      WriteLn('  is worth recording that the device was not the limit.');
    end;
  end;

  WriteLn;
  WriteLn('  WHAT THIS PROJECT CAN DO WITH IT:');
  if NFeat > 0 then
  begin
    WriteLn('    DAVOL   volume and mute, over control transfers.');
    for I := 0 to NFeat - 1 do
      WriteLn('            feature unit ', Feat[I].Unit_, ', ',
              Feat[I].Chans, ' channel(s) past master');
  end
  else
    WriteLn('    (no Feature Unit found, so there is nothing to adjust)');
  if HidIf >= 0 then
    WriteLn('    DAKEYS  the buttons, on HID interface ', HidIf,
            ' endpoint ', Hex2(HidEp))
  else
    WriteLn('    (no HID interface, so this speaker has no buttons to read)');
end;

begin
  Banner('DAPROBE', VER, 'USB audio device probe');
  if HelpWanted then
  begin
    WriteLn('  DAPROBE [/P=260] [/V] [/T]');
    WriteLn;
    WriteLn('    /P=hex  I/O base, default 260');
    WriteLn('    /V      narrate the bring-up');
    WriteLn('    /T      trace every control-transfer stage');
    HelpTail;
    Halt(0);
  end;

  Verbose := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if Length(S) < 2 then Continue;
    if (S[1] = '/') or (S[1] = '-') then
      case UpCase(S[2]) of
        'P': Base := HexArg(S, 4);
        'V': Verbose := True;
        'T': CtrlTrace := True;
      end;
  end;
  if Verbose or CtrlTrace then Trace := @Narrate;

  WriteLn('I/O base ', Hex4(Base), 'h');
  WriteLn;

  ExitProc := @Quieten;
  Rc := BringUp(Big, BigLen, Why);
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Why <> '' then WriteLn('  ', Why);
    if Rc >= BU_NOTHING then WhyNoAnswer;
    Halt(Rc);
  end;

  WriteLn;
  WriteLn('AUDIO CLASS DESCRIPTORS');
  WriteLn('----------------------------------------------------------------');
  WalkConfig;

  if AudioIfs = 0 then
  begin
    WriteLn;
    WriteLn('  No interface declares class 01 (audio). This is not a USB');
    WriteLn('  audio device, so nothing in CH375Audio applies to it.');
    Halt(6);
  end;

  Verdict;
  WriteLn;
  WriteLn('=== done ===');
  Halt(0);
end.
