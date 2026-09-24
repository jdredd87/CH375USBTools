program usbrecv;
{ USBRECV -- watch Ethernet frames arrive through an AX88179 on a CH375.
  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

  Step two.  USBLINK proved the control path; this proves the data path,
  and works out what the receive buffer actually looks like.

    USBRECV [/P=260] [/S=secs] [/N=count] [/A] [/X] [/G] [/V] [/R]

      /P=hex   CH375 I/O base, default 260
      /S=dec   how long to watch, default 20 seconds
      /N=dec   stop after this many bursts, default 20
      /A       accept everything: promiscuous, all multicast.  Without it
               only broadcast and frames addressed to this adapter arrive
      /X       hex dump every burst in full
      /G       leave the PHY in gigabit mode -- see USBLINK
      /V       print every register access
      /R       raw: do not try to interpret the buffer at all

  WHY THIS IS AN INVESTIGATION AND NOT A PARSER.  The AX88179 does not put
  a bare frame on its bulk endpoint.  A transfer ends with a 32-bit word
  giving a packet count and an offset, and that offset points back into
  the same buffer at an array of per-packet entries; the frames themselves
  sit at the front, padded to 8-byte boundaries.  That much is documented
  in the Linux driver.  The exact widths are the part worth checking
  rather than assuming -- the count and the entry stride have to agree
  with the buffer length, and if they do not, the recollection is wrong
  and not the chip.

  So this prints what it sees BEFORE what it concludes: the tail word, the
  arithmetic, and then the frames.  Every check that has to hold is
  printed with a tick or a cross next to it.  A driver written from a
  guess that happened to be wrong is exactly how this project lost a day
  to a mouse.

  It also measures throughput, which is the number that decides whether
  any of this is useful on an 8086.

  Exit codes: 0 frames seen and the layout held together, 1 no chip,
              3 nothing attached, 5 not an ASIX adapter,
              6 would not initialise, 7 no link, 8 no frames arrived,
              9 frames arrived but the layout did not make sense }

{$MODE OBJFPC}{$H-}

uses ch375, chtool, ax179;

const
  VER    = '1.0.0';
  { Linux gives this chip a 20 KB receive buffer.  It aggregates whether
    or not the queue-control register is zeroed -- the first run of this
    program filled a 2 KB buffer solidly and the trailer it then read was
    a slice of frame data.  16 KB fits comfortably in a real-mode data
    segment and has held every burst since. }
  BUFSZ  = 16384;

var
  Secs:    Word    = 20;
  { /D -- milliseconds to wait between polls, to imitate a driver that
    can only look at the endpoint on a timer tick.  USBRECV normally
    polls flat out, several hundred times a second, and never sees the
    state USBPKT falls into.  This is here to answer whether that rate
    is the reason or merely a coincidence. }
  PollGap: Word    = 0;
  MaxN:    Word    = 20;
  DumpAll: Boolean = False;
  Promisc: Boolean = False;
  Giga:    Boolean = False;
  Raw:     Boolean = False;
  Buf:     array[0..BUFSZ - 1] of Byte;
  Bursts:  Word    = 0;
  Frames:  Word    = 0;
  BadFmt:  Word    = 0;
  Naks:    LongInt = 0;
  Bytes:   LongInt = 0;
  Errs:    Word    = 0;

function Dw(Ofs: Word): LongInt;
begin
  { Little-endian 32-bit read.  Built by hand because the buffer is a byte
    array and an 8086 does not care about alignment anyway. }
  Dw := LongInt(Buf[Ofs]) or (LongInt(Buf[Ofs+1]) shl 8) or
        (LongInt(Buf[Ofs+2]) shl 16) or (LongInt(Buf[Ofs+3]) shl 24);
end;

function Hex8(V: LongInt): ShortString;
begin
  Hex8 := Hex4(Word(V shr 16)) + Hex4(Word(V and $FFFF));
end;

function EtherType(Ofs: Word): ShortString;
var T: Word;
begin
  T := (Word(Buf[Ofs + 12]) shl 8) or Buf[Ofs + 13];
  case T of
    $0800: EtherType := 'IPv4';
    $0806: EtherType := 'ARP';
    $86DD: EtherType := 'IPv6';
    $8100: EtherType := 'VLAN';
    $88CC: EtherType := 'LLDP';
  else
    if T <= 1500 then EtherType := 'len ' + Hex4(T)
                 else EtherType := 'type ' + Hex4(T);
  end;
end;

function MacAt(Ofs: Word): ShortString;
var M: TMac; I: Integer;
begin
  for I := 0 to 5 do M[I] := Buf[Ofs + I];
  MacAt := MacStr(M);
end;

function IsBroadcast(Ofs: Word): Boolean;
var I: Integer;
begin
  IsBroadcast := True;
  for I := 0 to 5 do
    if Buf[Ofs + I] <> $FF then begin IsBroadcast := False; Exit; end;
end;

function IsOurs(Ofs: Word): Boolean;
var I: Integer;
begin
  IsOurs := True;
  for I := 0 to 5 do
    if Buf[Ofs + I] <> Mac[I] then begin IsOurs := False; Exit; end;
end;

procedure Tick(const What: ShortString; Ok: Boolean);
begin
  if Ok then Write('  [ok] ') else Write('  [??] ');
  WriteLn(What);
end;

{ Pull one burst apart and say what it looks like.  Returns True if the
  layout held together. }
function Explain(Len: Word; Loud: Boolean): Boolean;
var
  RxHdr:   LongInt;
  PktCnt, HdrOff: Word;
  I, Ofs, PktLen, Padded, Ent: Word;
  H:       LongInt;
  Ok:      Boolean;
  Shown:   Word;
begin
  Ok := True;
  if Len < 8 then
  begin
    WriteLn('  burst of ', Len, ' bytes -- too short to hold a trailer');
    Explain := False;
    Exit;
  end;

  RxHdr  := Dw(Len - 4);
  PktCnt := Word(RxHdr and $FFFF);
  HdrOff := Word((RxHdr shr 16) and $FFFF);

  if Loud then
  begin
    WriteLn('  trailer at +', Len - 4, ' = ', Hex8(RxHdr),
            '   count=', PktCnt, '  hdr_off=', HdrOff);
  end;

  { The three things that have to be true if the layout is what the Linux
    driver describes.  Printed rather than assumed. }
  if Loud then
  begin
    Tick('count is sane (1..32)', (PktCnt >= 1) and (PktCnt <= 32));
    Tick('metadata offset inside the buffer', HdrOff + 4 <= Len - 4);
  end;
  if (PktCnt < 1) or (PktCnt > 32) then Ok := False;
  if HdrOff + 4 > Len - 4 then Ok := False;
  if not Ok then
  begin
    Explain := False;
    Exit;
  end;

  { How wide is one metadata entry?  The space between the array and the
    trailer, divided by the count, answers it from the data instead of
    from memory.  4 and 8 are both plausible -- the Linux driver's comment
    describes an entry followed by a dummy header. }
  Ent := 0;
  if PktCnt > 0 then Ent := (Len - 4 - HdrOff) div PktCnt;
  if Loud then
    WriteLn('  metadata area ', Len - 4 - HdrOff, ' bytes over ', PktCnt,
            ' packet(s) = ', Ent, ' bytes each');

  Ofs := 0;
  Shown := 0;
  for I := 0 to PktCnt - 1 do
  begin
    if HdrOff + I * Ent + 4 > Len then Break;
    H := Dw(HdrOff + I * Ent);
    PktLen := Word((H shr 16) and $1FFF);

    if Loud then
      Write('  packet ', I + 1, '/', PktCnt, '  entry=', Hex8(H),
            '  len=', PktLen);

    if (PktLen < 14) or (Word(Ofs) + PktLen > Len) then
    begin
      if Loud then WriteLn('   <- does not fit; layout wrong');
      Ok := False;
      Break;
    end;

    if Loud then
    begin
      WriteLn;
      WriteLn('      ', MacAt(Ofs + 6), ' -> ', MacAt(Ofs), '  ',
              EtherType(Ofs));
      Write('      addressed to us: ');
      if IsBroadcast(Ofs) then WriteLn('broadcast')
      else if IsOurs(Ofs) then WriteLn('yes')
      else WriteLn('no -- ', MacAt(Ofs), ' is somebody else');
      Inc(Shown);
    end;

    Inc(Frames);
    { Frames are padded out to an 8-byte boundary before the next one. }
    Padded := (PktLen + 7) and $FFF8;
    Ofs := Ofs + Padded;
  end;

  { The frames must stop before the metadata array starts, or they would
    be overwriting it. }
  if Loud then Tick('frames end before the metadata (' +
                    Hex4(Ofs) + ' <= ' + Hex4(HdrOff) + ')', Ofs <= HdrOff);
  if Ofs > HdrOff then Ok := False;

  Explain := Ok;
end;

procedure Usage;
begin
  Banner('USBRECV', VER, 'watch Ethernet frames arrive through an AX88179');
  WriteLn;
  WriteLn('  USBRECV [/P=260] [/S=secs] [/N=count] [/A] [/X] [/G] [/V] [/R]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /S=dec   how long to watch, default 20 seconds');
  WriteLn('  /D=dec   ms between polls (default 0, flat out).  Imitates');
  WriteLn('           a driver that can only poll on a timer tick.');
  WriteLn('  /N=dec   stop after this many bursts, default 20');
  WriteLn('  /A       accept everything: promiscuous and all multicast.');
  WriteLn('           Without it only broadcast and frames addressed to');
  WriteLn('           this adapter arrive');
  WriteLn('  /X       hex dump every burst in full');
  WriteLn('  /G       leave the PHY in gigabit mode -- see USBLINK /?');
  WriteLn('  /V       print every register access');
  WriteLn('  /R       raw: do not try to interpret the buffer at all');
  WriteLn('  /B=hex   bulk-in burst size, default 02.  How much the chip');
  WriteLn('           piles into one transfer before ending it');
  WriteLn('  /C=hex   bulk-in queue control, default 07 = all three limits');
  WriteLn('           enabled.  00 means NO limit, not no aggregation --');
  WriteLn('           the transfer then never ends while traffic arrives');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('The AX88179 does not put a bare frame on its bulk endpoint.  A');
  WriteLn('transfer ends with a 32-bit word giving a packet count and an');
  WriteLn('offset; that offset points back into the same buffer at an');
  WriteLn('array of per-packet entries, and the frames sit at the front');
  WriteLn('padded to 8-byte boundaries.');
  WriteLn;
  WriteLn('So this prints what it SEES before what it concludes -- the');
  WriteLn('tail word, the arithmetic, then the frames -- with a tick or a');
  WriteLn('cross beside every check that has to hold.  A driver written');
  WriteLn('from a guess that happened to be wrong is exactly how this');
  WriteLn('project once lost a day to a mouse.');
  WriteLn;
  WriteLn('If nothing arrives, try /A: a quiet network may be sending');
  WriteLn('nothing this adapter is allowed to hear.  A broadcast ping');
  WriteLn('from another machine is the easiest thing to catch.');
  HelpTail;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if      (A = '/X') or (A = '-X') then DumpAll := True
    else if (A = '/A') or (A = '-A') then Promisc := True
    else if (A = '/G') or (A = '-G') then Giga := True
    else if (A = '/R') or (A = '-R') then Raw := True
    else if (A = '/V') or (A = '-V') then AxTrace := True
    else if Length(A) >= 4 then
    begin
      K := Copy(A, 1, 3); A := Copy(A, 4, 250);
      if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
      else if K = '/S=' then begin Val(A, V, Code); if Code = 0 then Secs := Word(V); end
      else if K = '/D=' then begin Val(A, V, Code); if Code = 0 then PollGap := Word(V); end
      else if K = '/N=' then begin Val(A, V, Code); if Code = 0 then MaxN := Word(V); end
      else if K = '/B=' then begin Val('$' + A, V, Code); if Code = 0 then AxBulkSize := Byte(V); end
      else if K = '/C=' then begin Val('$' + A, V, Code); if Code = 0 then AxBulkCtrl := Byte(V); end;
    end;
  end;
end;

var
  Steps: Integer = 0;

procedure ShowStep(const What: ShortString; St: Integer);
var I: Integer;
begin
  Write('  ', What);
  for I := Length(What) + 2 to 33 do Write('.');
  if St >= 0 then WriteLn(' ok') else WriteLn(' FAILED (', StatusStr(St), ')');
  if St < 0 then Inc(Steps);
end;

var
  Rc:    Integer;
  Vid:   Word;
  Bmsr:  Word;
  Len:   Word;
  T0, TEnd, Elapsed: LongInt;
  St:    Integer;
  Rate:  LongInt;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('USBRECV', VER, 'AX88179 receive path');

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;

  Vid := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  if Vid <> AX_VENDOR then
  begin
    WriteLn('Not an ASIX adapter.  USBINFO will say what you have.');
    Halt(5);
  end;

  AxStep := @ShowStep;
  WriteLn('Bringing the chip up');
  if (not AxInit(Promisc)) or (Steps > 0) then
  begin
    WriteLn;
    WriteLn('The chip would not initialise.  /V shows which access failed.');
    Halt(6);
  end;
  WriteLn;
  WriteLn('MAC address: ', MacStr(Mac));
  if Promisc then WriteLn('Filter     : promiscuous (/A)')
             else WriteLn('Filter     : broadcast + our own MAC');
  WriteLn;

  AxNegotiate(not Giga);
  Write('Waiting for a link');
  if not AxLinkWait(15, Bmsr) then
  begin
    WriteLn;
    WriteLn('No link.  BMSR = ', Hex4(Bmsr), '.  Check the cable.');
    Halt(7);
  end;
  WriteLn(' up.');
  AxSetMedium(Giga);
  AxStep := nil;

  WriteLn;
  WriteLn('Watching for ', Secs, 's or ', MaxN, ' bursts.  Press a key to stop.');
  WriteLn('A broadcast ping from another machine is the easiest thing to');
  WriteLn('catch if nothing shows up.');
  WriteLn;

  T0 := Ticks;
  TEnd := T0 + LongInt(Secs) * 18;
  AxRxReset;

  while (Ticks < TEnd) and (Bursts < MaxN) do
  begin
    if KeyWaiting then begin EatKey; Break; end;
    if PollGap > 0 then DelayMs(PollGap);

    St := AxRxBurst(Buf, BUFSZ, Len);

    if St = INT_RET_NAK then
    begin
      Inc(Naks);
      Continue;                        { idle: nothing waiting, not an error }
    end;

    if St <> INT_SUCCESS then
    begin
      Inc(Errs);
      { Capped deliberately.  An error that repeats every poll would
        otherwise print thousands of identical lines and the run would
        spend all its time on output rather than on the wire. }
      if Errs <= 8 then WriteLn('burst ', Bursts + 1, ': ', StatusStr(St))
      else if Errs = 9 then WriteLn('(further errors counted, not printed)');
      if St = INT_RET_STALL then
      begin
        ClrStall(AX_EP_BULK_IN);
        AxRxReset;
      end;
      Continue;
    end;

    if Len = 0 then Continue;          { zero-length packet, nothing in it }

    Inc(Bursts);
    Bytes := Bytes + Len;
    Write('burst ', Bursts, ': ', Len, ' bytes');
    if AxRxOver > 0 then
      WriteLn('  + ', AxRxOver, ' DISCARDED, buffer too small')
    else
      WriteLn;
    if DumpAll then HexDump(Buf, Len, '    ');
    if AxRxOver > 0 then
      { No point interpreting a fragment: its trailer went in the bin. }
      Inc(BadFmt)
    else if not Raw then
      if not Explain(Len, True) then Inc(BadFmt);
    WriteLn;
  end;

  Elapsed := Ticks - T0;
  if Elapsed < 1 then Elapsed := 1;

  WriteLn('--- done ---');
  WriteLn('  bursts        : ', Bursts);
  WriteLn('  frames        : ', Frames);
  WriteLn('  bytes         : ', Bytes);
  WriteLn('  idle polls    : ', Naks);
  WriteLn('  errors        : ', Errs);
  if not Raw then
    WriteLn('  layout wrong  : ', BadFmt);
  WriteLn('  elapsed       : ', (Elapsed * 10) div 18, ' tenths of a second');

  { Throughput, which is the number this whole project turns on.  It is
    measured over the watch window including the idle polling, so it is a
    floor rather than a peak -- a busier network would give a higher one. }
  if Bytes > 0 then
  begin
    Rate := (Bytes * 18) div Elapsed;
    WriteLn('  about ', Rate, ' bytes/sec over the window');
    WriteLn('  (that includes time spent idle, so it is a floor)');
  end;

  WriteLn;
  if Bursts = 0 then
  begin
    WriteLn('Nothing arrived.  ', Naks, ' polls, every one of them a NAK --');
    WriteLn('which means the endpoint is healthy and had nothing to give.');
    WriteLn('Try /A for promiscuous, and have another machine broadcast.');
    Halt(8);
  end;
  if BadFmt > 0 then
  begin
    WriteLn(BadFmt, ' of ', Bursts, ' bursts did not fit the expected');
    WriteLn('layout.  The bytes above are the truth; the interpretation is');
    WriteLn('what needs correcting.  /X /R shows them raw.');
    Halt(9);
  end;
  WriteLn('The receive path works and the buffer layout holds together.');
  Halt(0);
end.
