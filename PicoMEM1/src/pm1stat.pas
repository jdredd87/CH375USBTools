program pm1stat;
{ PM1STAT -- the answers a PicoMEM 1 will actually give you.
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1STAT [/U-] [/D-] [/W] [/S=n] [/P=2A0]

  The card answers three queries with TEXT, written into a parameter
  area in its shared memory.  Where that area starts depends on the
  firmware, so this finds it first (see pm1card.pas) rather than
  assuming -- which is why PicoMEM2's PMPROBE and PMUSB report nothing
  at all on a card with the 2025-11-02 BIOS.

    /D-  skip the disk list.  It cannot be skipped entirely: the disk
         query is how the parameter area is located
    /U-  skip the USB device list
    /S=n watch the USB list for n seconds and print every change, for
         plugging things in and out with nobody at the keyboard
    /W   also ask for the WiFi state.  CAUTION: the firmware RETRIES
         the connection if it thinks the signal has gone, and on a
         machine administered over that WiFi a retry is a dropped link.
         The network key sits in the same structure; this never reads
         the bytes it occupies
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  Exit code: 0 answered, 1 no card, 2 a query failed, 3 no shared
  memory, 4 the parameter area was not found. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.0.0';
  PLEN = 640;            { enough for any answer this firmware writes }

  { wifi_infos_t, as the firmware lays it out }
  W_MAC    = 0;          { 6 bytes }
  W_SSID   = 6;          { 33 }
  W_KEY    = 39;         { 63 -- NEVER READ }
  W_STATUS = 102;        { 32, text }
  W_STATE  = 134;        { int16 }
  W_RSSI   = 136;        { int32 }
  W_RATE   = 140;        { int16 }

var
  DoUsb, DoDisk, DoWifi: Boolean;
  Watch: Word;
  ForceBase: Word;
  Buf: array[0..PLEN - 1] of Byte;
  Rc: Integer;

function ParseNum(const S: string; var W: Word): Boolean;
var I: Integer; V: LongInt;
begin
  V := 0; ParseNum := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    if (S[I] < '0') or (S[I] > '9') then Exit;
    V := V * 10 + Ord(S[I]) - 48;
    if V > 32000 then Exit;
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
  DoUsb := True; DoDisk := True; DoWifi := False;
  Watch := 0; ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'U': DoUsb := not ((Length(S) > 2) and (S[3] = '-'));
        'D': DoDisk := not ((Length(S) > 2) and (S[3] = '-'));
        'W': DoWifi := True;
        'S': if (Length(S) > 3) and (S[3] = '=') then
               if ParseNum(Copy(S, 4, 9), W) then Watch := W;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end;
  end;
end;

{ Print however many lines the answer in Buf holds. }
procedure ShowLines(const Lead: string);
var N, I: Byte; S: string;
begin
  N := Buf[0];
  if N = 0 then begin
    WriteLn(Lead, '(the card wrote no lines)');
    Exit;
  end;
  for I := 1 to N do
    if ParamLine(Buf, PLEN, I, S) then WriteLn(Lead, S);
end;

function AskAndCopy(Cmd: Byte): Byte;
var Res: Word; R: Byte;
begin
  Res := 0;
  R := Command(Cmd, 0, 91, Res);
  if R = CR_OK then CopyParam(Buf, PLEN);
  AskAndCopy := R;
end;

{ The USB answer's first line is the device count, so it is enough to
  compare for a watch. }
function UsbLine: string;
var S: string;
begin
  if not ParamLine(Buf, PLEN, 1, S) then S := '(nothing)';
  UsbLine := S;
end;

procedure Wifi;
var I: Integer; SSID, St: string; C: Char; State: Integer; Rssi: LongInt;
begin
  WriteLn;
  WriteLn('WiFi  (the card retries the connection when it answers this)');
  if AskAndCopy(CMD_WIFI_INFO) <> CR_OK then begin
    WriteLn('  the query failed');
    Rc := 2;
    Exit;
  end;
  SSID := '';
  for I := 0 to 32 do begin
    C := Chr(Buf[W_SSID + I]);
    if C = #0 then Break;
    if (C < ' ') or (C > '~') then C := '.';
    SSID := SSID + C;
  end;
  St := '';
  for I := 0 to 31 do begin
    C := Chr(Buf[W_STATUS + I]);
    if C = #0 then Break;
    if (C < ' ') or (C > '~') then C := '.';
    St := St + C;
  end;
  State := Buf[W_STATE] or (Integer(Buf[W_STATE + 1]) shl 8);
  Rssi := LongInt(Buf[W_RSSI]) or (LongInt(Buf[W_RSSI + 1]) shl 8) or
          (LongInt(Buf[W_RSSI + 2]) shl 16) or (LongInt(Buf[W_RSSI + 3]) shl 24);
  Write('  MAC    : ');
  for I := 0 to 5 do begin
    Write(Hex2(Buf[W_MAC + I]));
    if I < 5 then Write(':');
  end;
  WriteLn;
  WriteLn('  SSID   : ', SSID);
  WriteLn('  status : ', St);
  Write('  state  : ', State);
  case State of
    0: Write(' (link down)');
    1: Write(' (joined)');
    2: Write(' (joined, no address)');
    3: Write(' (up)');
   -1: Write(' (failed)');
   -2: Write(' (no such network)');
   -3: Write(' (wrong key)');
  end;
  WriteLn('   signal ', Rssi, ' dB   rate ',
          Buf[W_RATE] or (Word(Buf[W_RATE + 1]) shl 8));
  WriteLn('  the network key is in the same structure, 63 bytes at +',
          W_KEY, ';');
  WriteLn('  this tool never reads them, and PM1DUMP /K blanks them.');
end;

const
  SPIN: string[4] = '-\|/';

var
  Bad: Word;
  R: Byte;
  Prev, Now_: string;
  T0, TEnd, Last, Spun: LongInt;
  Changes: Word;
begin
  Args;
  WriteLn('PM1STAT ', VER, ' -- what the card answers when you ask it');
  Rc := 0;

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h (', Bad,
            ' of 100 test-port reads out of sequence)');
    Halt(1);
  end;
  if not SharedOK then begin
    WriteLn('no shared memory at ', Hex4(PmRomSeg), ':4000');
    Halt(3);
  end;

  { this sends the disk query, which is also how the area is found }
  if not FindParam then begin
    WriteLn('the parameter area was not found -- the disk query failed,');
    WriteLn('or this firmware writes its answers some other way.');
    Halt(4);
  end;
  CopyParam(Buf, PLEN);
  WriteLn('answers at +', PmParam, ' in the shared memory');

  if DoDisk then begin
    WriteLn;
    WriteLn('disk images the card is presenting');
    ShowLines('  ');
  end;

  if DoUsb then begin
    WriteLn;
    WriteLn('USB');
    R := AskAndCopy(CMD_USB_STATUS);
    if R <> CR_OK then begin
      WriteLn('  the query failed: ', ResultName(R));
      Rc := 2;
    end else begin
      ShowLines('  ');
      WriteLn('  (a device line is blank unless one of the firmware''s own');
      WriteLn('   drivers claimed it -- HID, mass storage, MIDI, game pads)');
    end;
  end;

  if (Watch > 0) and DoUsb then begin
    WriteLn;
    WriteLn('watching the USB list for ', Watch, ' seconds');
    Prev := UsbLine;
    WriteLn('  0s  ', Prev);
    Changes := 0;
    T0 := Ticks;
    TEnd := T0 + LongInt(Watch) * 91 div 5;
    Last := T0; Spun := -1;
    while (Ticks < TEnd) and (Ticks >= T0) do begin
      { a heartbeat on stderr, driven by the CLOCK and not by the work,
        so a watch with nothing happening still looks alive.  stderr is
        not redirected by the bridge, so it lands on the real screen }
      if Ticks shr 2 <> Spun then begin
        Spun := Ticks shr 2;
        Write(StdErr, SPIN[1 + (Spun and 3)], #8);
      end;
      if Ticks - Last >= 9 then begin        { about twice a second }
        Last := Ticks;
        if AskAndCopy(CMD_USB_STATUS) = CR_OK then begin
          Now_ := UsbLine;
          if Now_ <> Prev then begin
            WriteLn('  ', (Ticks - T0) * 5 div 91:3, 's  ', Now_);
            Prev := Now_;
            Inc(Changes);
          end;
        end;
      end;
    end;
    Write(StdErr, ' ', #8);
    WriteLn('  ', Changes, ' change(s) in ', Watch, ' seconds');
  end;

  if DoWifi then Wifi;

  WriteLn;
  WriteLn('status now: ', Hex2(Status), ' (', StatusName(PmLastSt), ')');
  Halt(Rc);
end.
