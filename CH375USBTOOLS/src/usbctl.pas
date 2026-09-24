program usbctl;
{ USBCTL -- issue an arbitrary USB control transfer over a CH375.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  The poking tool.  Everything else in the suite decides for you what to
  ask a device; this asks exactly what you type and shows every stage of
  what came back, so a device that misbehaves can be characterised instead
  of guessed at.

    USBCTL [/P=260] [/R=bm] [/Q=req] [/V=val] [/I=idx] [/L=len]
           [/D=hh,hh,...] [/N=count] [/G=ms] [/T] [/Q0]

      /P=hex   I/O base, default 260
      /R=hex   bmRequestType, default 80 (IN, standard, device)
      /Q=hex   bRequest, default 06 (GET_DESCRIPTOR)
      /V=hex   wValue, default 0100 (device descriptor)
      /I=hex   wIndex, default 0
      /L=dec   wLength, default 18
      /D=list  data for an OUT transfer, comma-separated hex bytes.
               Supplying it makes the transfer a control-OUT regardless of
               the direction bit in /R.
      /N=dec   repeat the whole transfer this many times and tally the
               results.  A device that answers every other request -- and
               they exist -- shows up here and nowhere else.
      /G=dec   settle delay in ms after each transfer, default 0
      /K=hex   first data-stage toggle, default C0 (DATA1, which is what
               the spec says).  A diagnostic knob, not a setting
      /T       trace every stage: SETUP, each IN packet, the status stage

  Examples

      USBCTL                                 device descriptor
      USBCTL /V=0300 /L=255                  the LANGID list
      USBCTL /V=0301 /I=0409 /L=255          string 1 in English
      USBCTL /R=81 /V=2200 /I=0 /L=65        HID report descriptor, iface 0
      USBCTL /R=21 /Q=0A /V=0000 /I=0 /L=0   HID SET_IDLE, no data stage
      USBCTL /R=21 /Q=09 /V=0200 /I=0 /D=02  HID SET_REPORT: NumLock LED
      USBCTL /L=255 /N=10 /T                 ten identical reads, traced

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 device stopped answering,
              6 the transfer itself failed }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

var
  Buf:    array[0..1023] of Byte;
  OutBuf: array[0..63] of Byte;
  OutLen: Byte = 0;
  HaveOut: Boolean = False;
  RType:  Byte = $80;
  Req:    Byte = $06;
  WVal:   Word = $0100;
  WIdx:   Word = 0;
  WLen:   Word = 18;
  Count:  Word = 1;
  DoTrace: Boolean = False;

procedure Narrate(const S: ShortString);
begin
  WriteLn(S);
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

function HexVal(const S: ShortString; var Ok: Boolean): LongInt;
var V: LongInt; Code: Integer;
begin
  Val('$' + S, V, Code);
  Ok := (Code = 0) and (Length(S) > 0);
  HexVal := V;
end;

function DecVal(const S: ShortString; var Ok: Boolean): LongInt;
var V: LongInt; Code: Integer;
begin
  Val(S, V, Code);
  Ok := (Code = 0) and (Length(S) > 0);
  DecVal := V;
end;

{ /D=01,02,ff -- comma or space separated, "0x" and "$" tolerated. }
procedure ParseData(const S: ShortString);
var
  I: Integer;
  T: ShortString;
  V: LongInt;
  Ok: Boolean;
begin
  OutLen := 0; T := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = ',') or (S[I] = ' ') then
    begin
      if T <> '' then
      begin
        if Copy(T, 1, 2) = '0X' then T := Copy(T, 3, 250);
        if Copy(T, 1, 1) = '$'  then T := Copy(T, 2, 250);
        V := HexVal(T, Ok);
        if Ok and (OutLen < SizeOf(OutBuf)) then
        begin
          OutBuf[OutLen] := Byte(V); Inc(OutLen);
        end;
        T := '';
      end;
    end
    else
      T := T + S[I];
  end;
  HaveOut := True;
end;

{ A bmRequestType in English, because the bit layout is the one thing
  nobody remembers. }
function TypeName(B: Byte): ShortString;
var S: ShortString;
begin
  if (B and $80) <> 0 then S := 'IN ' else S := 'OUT';
  case (B shr 5) and 3 of
    0: S := S + ', standard';
    1: S := S + ', class';
    2: S := S + ', vendor';
    3: S := S + ', reserved';
  end;
  case B and $1F of
    0: S := S + ', device';
    1: S := S + ', interface';
    2: S := S + ', endpoint';
    3: S := S + ', other';
  else
    S := S + ', recipient ' + Dec1(B and $1F);
  end;
  TypeName := S;
end;

function ReqName(B: Byte; T: Byte): ShortString;
begin
  { A class request shares its numbers with the standard set, so the two
    tables must not be mixed.  Only HID is decoded; anything else prints
    its number, which is honest. }
  if ((T shr 5) and 3) = 1 then
  begin
    case B of
      HID_GET_REPORT  : ReqName := 'HID GET_REPORT';
      HID_GET_IDLE    : ReqName := 'HID GET_IDLE';
      HID_GET_PROTOCOL: ReqName := 'HID GET_PROTOCOL';
      HID_SET_REPORT  : ReqName := 'HID SET_REPORT';
      HID_SET_IDLE    : ReqName := 'HID SET_IDLE';
      HID_SET_PROTOCOL: ReqName := 'HID SET_PROTOCOL';
    else
      ReqName := 'class request ' + Hex2(B);
    end;
    Exit;
  end;
  case B of
    REQ_GET_STATUS : ReqName := 'GET_STATUS';
    REQ_CLEAR_FEAT : ReqName := 'CLEAR_FEATURE';
    REQ_SET_FEAT   : ReqName := 'SET_FEATURE';
    REQ_SET_ADDRESS: ReqName := 'SET_ADDRESS';
    REQ_GET_DESCR  : ReqName := 'GET_DESCRIPTOR';
    REQ_SET_DESCR  : ReqName := 'SET_DESCRIPTOR';
    REQ_GET_CONFIG : ReqName := 'GET_CONFIGURATION';
    REQ_SET_CONFIG : ReqName := 'SET_CONFIGURATION';
    REQ_GET_IFACE  : ReqName := 'GET_INTERFACE';
    REQ_SET_IFACE  : ReqName := 'SET_INTERFACE';
  else
    ReqName := 'request ' + Hex2(B);
  end;
end;

procedure ParseArgs;
var
  I, Code: Integer;
  A, K: ShortString;
  V: LongInt;
  Ok: Boolean;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/T') or (A = '-T') then begin DoTrace := True; Continue; end;
    if Length(A) < 4 then Continue;
    K := Copy(A, 1, 3);
    A := Copy(A, 4, 250);
    if      K = '/P=' then begin V := HexVal(A, Ok); if Ok then Base  := Word(V); end
    else if K = '/R=' then begin V := HexVal(A, Ok); if Ok then RType := Byte(V); end
    else if K = '/Q=' then begin V := HexVal(A, Ok); if Ok then Req   := Byte(V); end
    else if K = '/V=' then begin V := HexVal(A, Ok); if Ok then WVal  := Word(V); end
    else if K = '/I=' then begin V := HexVal(A, Ok); if Ok then WIdx  := Word(V); end
    else if K = '/L=' then begin V := DecVal(A, Ok); if Ok then WLen  := Word(V); end
    else if K = '/N=' then begin V := DecVal(A, Ok); if Ok then Count := Word(V); end
    else if K = '/G=' then begin V := DecVal(A, Ok); if Ok then CtrlGap := Word(V); end
    else if K = '/K=' then begin V := HexVal(A, Ok); if Ok then CtrlFirstTog := Byte(V); end
    else if K = '/D=' then ParseData(A);
  end;
end;

var
  Rc, St: Integer;
  Got: Word;
  N: Word;
  NOk, NFail: Word;
  Tally: ShortString;

procedure Usage;
begin
  Banner('USBCTL', VER, 'issue an arbitrary USB control transfer');
  WriteLn;
  WriteLn('  USBCTL [/P=260] [/R=bm] [/Q=req] [/V=val] [/I=idx] [/L=len]');
  WriteLn('         [/D=hh,hh,...] [/N=count] [/G=ms] [/K=hex] [/T]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /R=hex   bmRequestType, default 80 (IN, standard, device)');
  WriteLn('  /Q=hex   bRequest, default 06 (GET_DESCRIPTOR)');
  WriteLn('  /V=hex   wValue, default 0100 (device descriptor)');
  WriteLn('  /I=hex   wIndex, default 0');
  WriteLn('  /L=dec   wLength, default 18');
  WriteLn('  /D=list  data for an OUT transfer, comma-separated hex bytes.');
  WriteLn('           Supplying it makes the transfer a control-OUT');
  WriteLn('           whatever the direction bit in /R says');
  WriteLn('  /N=dec   repeat the transfer this many times and tally the');
  WriteLn('           results.  A device that answers every other request');
  WriteLn('           -- and they exist -- shows up here and nowhere else');
  WriteLn('  /G=dec   settle delay in ms after each transfer, default 0');
  WriteLn('  /K=hex   first data-stage toggle, default C0 (DATA1, which is');
  WriteLn('           what the spec says).  A knob, not a setting');
  WriteLn('  /T       trace every stage: SETUP, each IN packet, the status');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('Examples');
  WriteLn('  USBCTL                                device descriptor');
  WriteLn('  USBCTL /V=0300 /L=255                 the LANGID list');
  WriteLn('  USBCTL /V=0301 /I=0409 /L=255         string 1 in English');
  WriteLn('  USBCTL /R=81 /V=2200 /I=0 /L=65       HID report descr iface 0');
  WriteLn('  USBCTL /R=21 /Q=0A /V=0000 /I=0 /L=0  HID SET_IDLE, no data');
  WriteLn('  USBCTL /R=21 /Q=09 /V=0200 /I=0 /D=02 HID SET_REPORT: NumLock');
  WriteLn('  USBCTL /L=255 /N=10 /T                ten identical reads');
  WriteLn;
  WriteLn('The poking tool.  Everything else in the suite decides for you');
  WriteLn('what to ask a device; this asks exactly what you type and shows');
  WriteLn('every stage of what came back.');
  HelpTail;
end;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('USBCTL', VER, 'CH375 control transfer');

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;
  if DoTrace then begin Trace := @Narrate; CtrlTrace := True; end;

  WriteLn('chip ', Hex2(IcVer), ' at ', Hex4(Base), 'h, ep0 max ', Ep0Max,
          ', device ', Hex4(DevDesc[8] or (Word(DevDesc[9]) shl 8)), ':',
          Hex4(DevDesc[10] or (Word(DevDesc[11]) shl 8)));
  WriteLn;
  WriteLn('bmRequestType ', Hex2(RType), '  ', TypeName(RType));
  WriteLn('bRequest      ', Hex2(Req), '  ', ReqName(Req, RType));
  WriteLn('wValue        ', Hex4(WVal));
  WriteLn('wIndex        ', Hex4(WIdx));
  if HaveOut then
  begin
    WriteLn('wLength       ', OutLen, '  (OUT, data below)');
    HexDump(OutBuf, OutLen, '  ');
  end
  else
    WriteLn('wLength       ', WLen);
  if CtrlGap > 0 then WriteLn('settle        ', CtrlGap, ' ms after each');
  if CtrlFirstTog <> $C0 then
    WriteLn('first toggle  ', Hex2(CtrlFirstTog), '  (default is C0)');
  WriteLn;

  NOk := 0; NFail := 0; Tally := '';
  for N := 1 to Count do
  begin
    if Count > 1 then WriteLn('--- attempt ', N, ' of ', Count);
    Got := 0;
    if HaveOut then
      St := CtrlOut(RType, Req, WVal, WIdx, OutBuf, OutLen)
    else if WLen = 0 then
      St := CtrlNoData(RType, Req, WVal, WIdx)
    else
      St := CtrlIn(RType, Req, WVal, WIdx, WLen, Buf, SizeOf(Buf), Got);

    WriteLn('  result ', StatusStr(St), ', ', Got, ' bytes');
    if Got > 0 then HexDump(Buf, Got, '  ');

    { "Worked" means data came back, or -- for a transfer that has no data
      stage -- that the handshake succeeded.  A tally of those across /N
      attempts is what exposes a device that alternates. }
    if (Got > 0) or ((Got = 0) and (St = INT_SUCCESS)) then
    begin
      Inc(NOk); Tally := Tally + '.';
    end
    else
    begin
      Inc(NFail); Tally := Tally + 'X';
    end;
  end;

  if Count > 1 then
  begin
    WriteLn;
    WriteLn('  ', NOk, ' ok, ', NFail, ' failed   [', Tally, ']');
    WriteLn('  (. = data or success, X = nothing came back)');
  end;

  if NOk = 0 then Halt(6);
  Halt(0);
end.
