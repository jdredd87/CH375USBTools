program EcmLink;

{ ECMLINK -- bring a CDC-ECM adapter up and prove it can actually talk.

  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

      ECMLINK [@260] [/M=our-ip] [/T=target-ip]

  NEITHER ADDRESS IS BUILT IN, and the first version of this got that
  wrong: it carried this bench's own 192.168.50.222 and .46 as defaults,
  so a copy built anywhere else would quietly ARP a stranger's network
  and report a failure that meant nothing. `our-ip` now comes from
  IPADDR in the config %MTCPCFG% names -- the same place every mTCP tool
  looks, and the same thing arp.pas does -- and the target has to be
  named. /M= and /T= override and supply them.

  With no /T= it brings the adapter up, reports what it read, and says
  outright that transmit was NOT tested. A tool that claims less than it
  proved is worth more than one that assumes an address.

  The AX88179A on this bench enumerates, reads its MAC, reports link up and
  receives frames through the ASIX vendor path -- and nothing it transmits
  is ever answered. So a test that only brings the device up and prints
  what it found would have declared that adapter working.

  This sends an ARP request and waits for the reply. ARP is the right probe:
  42 bytes, no IP stack needed, and an answer proves the whole path in both
  directions at once -- our frame reached the wire, some other machine
  parsed it, and its reply came back up through the chip. Nothing short of
  that distinguishes "brought up" from "working". }

{$MODE OBJFPC}{$H-}

uses Ch375, Ecm, Dos, vidfix;             { Dos for GetEnv }

const
  VER = '1.0.0';

var
  E        : TEcm;
  HaveOur  : Boolean;
  HaveTgt  : Boolean;
  CfgFrom  : ShortString;
  Frame    : array[0..1535] of Byte;
  OurIp    : array[0..3] of Byte;
  TgtIp    : array[0..3] of Byte;
  Base     : Word;
  I, J     : Integer;
  Got      : Word;
  Tries    : Integer;
  Answered : Boolean;
  NKind    : Byte;
  NVal     : Word;
  Found    : Boolean;
  K        : Byte;
  V        : Word;
  Seen     : Integer;
  S        : ShortString;

function Hex2(B: Byte): ShortString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4] + H[B and 15];
end;

function ParseIp(S: ShortString; var A: array of Byte): Boolean;
var I, P, V, N: Integer;
begin
  ParseIp := False;
  P := 1; N := 0; V := 0;
  for I := 0 to 3 do A[I] := 0;
  while (P <= Length(S)) and (N < 4) do
  begin
    if (S[P] >= '0') and (S[P] <= '9') then
    begin
      V := V * 10 + (Ord(S[P]) - 48);
      if V > 255 then Exit;
    end
    else if S[P] = '.' then
    begin
      A[N] := Byte(V); Inc(N); V := 0;
    end
    else Exit;
    Inc(P);
  end;
  if N <> 3 then Exit;
  A[3] := Byte(V);
  ParseIp := True;
end;

{ Sender protocol address == the host we asked about. }
function IsTarget: Boolean;
var I: Integer;
begin
  IsTarget := False;
  for I := 0 to 3 do
    if Frame[28 + I] <> TgtIp[I] then Exit;
  IsTarget := True;
end;

{ Target hardware address == us. An ARP reply is unicast to the requester,
  so this is what makes it an answer rather than an overheard one. }
function ToUs: Boolean;
var I: Integer;
begin
  ToUs := False;
  for I := 0 to 5 do
    if Frame[32 + I] <> E.Mac[I] then Exit;
  ToUs := True;
end;

{ IPADDR out of an mTCP-style config: KEY value, one per line, '#' for a
  comment. Only IPADDR is wanted here -- there is no routing to do, because
  ARP is a layer-2 question and the target is on the segment or it is not. }
function ReadOurIp(const Path: ShortString): Boolean;
var
  F: Text;
  L: ShortString;
  I, J: Integer;
  Key: ShortString;
begin
  ReadOurIp := False;
  if Path = '' then Exit;
  Assign(F, Path);
  {$I-} Reset(F); {$I+}
  if IOResult <> 0 then Exit;
  while not Eof(F) do
  begin
    {$I-} ReadLn(F, L); {$I+}
    if IOResult <> 0 then Break;
    I := 1;
    while (I <= Length(L)) and (L[I] = ' ') do Inc(I);
    if (I > Length(L)) or (L[I] = '#') then Continue;
    J := I;
    while (J <= Length(L)) and (L[J] <> ' ') do Inc(J);
    Key := '';
    while I < J do
    begin
      Key := Key + UpCase(L[I]);
      Inc(I);
    end;
    if Key <> 'IPADDR' then Continue;
    while (I <= Length(L)) and (L[I] = ' ') do Inc(I);
    L := Copy(L, I, Length(L) - I + 1);
    { trim anything trailing -- a comment, or the CR of a CRLF file }
    I := 1;
    while (I <= Length(L)) and (((L[I] >= '0') and (L[I] <= '9'))
                                or (L[I] = '.')) do Inc(I);
    L := Copy(L, 1, I - 1);
    if ParseIp(L, OurIp) then
    begin
      ReadOurIp := True;
      CfgFrom := Path;
    end;
    Break;
  end;
  Close(F);
end;

procedure BuildArp;
var I: Integer;
begin
  for I := 0 to 59 do Frame[I] := 0;
  for I := 0 to 5 do Frame[I] := $FF;            { to everybody }
  for I := 0 to 5 do Frame[6 + I] := E.Mac[I];   { from us }
  Frame[12] := $08; Frame[13] := $06;            { ethertype ARP }
  Frame[14] := $00; Frame[15] := $01;            { Ethernet }
  Frame[16] := $08; Frame[17] := $00;            { IPv4 }
  Frame[18] := 6;   Frame[19] := 4;
  Frame[20] := $00; Frame[21] := $01;            { request }
  for I := 0 to 5 do Frame[22 + I] := E.Mac[I];
  for I := 0 to 3 do Frame[28 + I] := OurIp[I];
  { target hardware address stays zero -- that is what we are asking }
  for I := 0 to 3 do Frame[38 + I] := TgtIp[I];
end;

{ Leave the chip the way we would like to find it.

  BusUp sets CMD_SET_RETRY to 8F so the chip absorbs NAKs while enumerating.
  Walking away from a chip still on 8F leaves it retrying a transaction in
  the background, and the NEXT program to open it gets no answer to
  CHECK_EXIST at all. That is not theory: it happened on this tool's first
  hardware run, and two subsequent runs reported no CH375 at an address with
  a card in it. An exit hook, not a line at the end of the program, because
  the paths that need it are the ones that Halt early. }
procedure Quieten;
begin
  SetRetry($00);
end;

begin
  ExitProc := @Quieten;
  WriteLn('ECMLINK ', VER, ' -- CDC-ECM bring-up over a CH375 -- StevenC & Claude');

  Base := $260;
  HaveOur := False;
  HaveTgt := False;
  CfgFrom := '';
  for I := 0 to 3 do begin OurIp[I] := 0; TgtIp[I] := 0; end;

  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (Length(S) > 1) and (S[1] = '@') then
    begin
      Base := 0;
      for J := 2 to Length(S) do
        case UpCase(S[J]) of
          '0'..'9': Base := Base * 16 + (Ord(S[J]) - 48);
          'A'..'F': Base := Base * 16 + (Ord(UpCase(S[J])) - 55);
        end;
    end
    else if (Length(S) > 3) and (UpCase(S[1]) = 'M') and (S[2] = '=') then
      HaveOur := ParseIp(Copy(S, 3, Length(S) - 2), OurIp)
    else if (Length(S) > 3) and (UpCase(S[1]) = 'T') and (S[2] = '=') then
      HaveTgt := ParseIp(Copy(S, 3, Length(S) - 2), TgtIp)
    else if (Length(S) > 4) and (UpCase(S[2]) = 'M') and (S[3] = '=') then
      HaveOur := ParseIp(Copy(S, 4, Length(S) - 3), OurIp)
    else if (Length(S) > 4) and (UpCase(S[2]) = 'T') and (S[3] = '=') then
      HaveTgt := ParseIp(Copy(S, 4, Length(S) - 3), TgtIp);
  end;

  { Not given one? Read it from wherever mTCP is configured, which is where
    this machine's own address actually lives. }
  if not HaveOur then
  begin
    HaveOur := ReadOurIp(GetEnv('MTCPCFG'));
    if not HaveOur then HaveOur := ReadOurIp('C:\CH375\MTCPAX.CFG');
  end;

  { Settled BEFORE the chip is touched.  A missing address is a mistake in
    the command line, and reporting it only after a ten-second bring-up --
    or worse, after disturbing a driver that already owns the chip -- makes
    the user pay for USB work that was never going to be used. }
  if not HaveOur then
  begin
    WriteLn('No address to speak as.  Set MTCPCFG to a config carrying an');
    WriteLn('IPADDR line, or pass /M=a.b.c.d .  Nothing is assumed: a');
    WriteLn('built-in address would ARP somebody else''s network.');
    Halt(6);
  end;
  if CfgFrom <> '' then
  begin
    Write('address  : ');
    for I := 0 to 3 do
    begin
      Write(OurIp[I]);
      if I < 3 then Write('.');
    end;
    WriteLn('  from IPADDR in ', CfgFrom);
  end;

  { CHECK_EXIST is answered by a chip that is idle. One left mid-transaction
    by a previous program does not answer it, and the honest-looking report
    is then "no CH375 at 0260h" for a card that is plainly fitted -- which
    is what this tool printed after its own first run wedged the chip. So a
    failed check is followed by a reset and asked again, rather than
    believed. }
  Found := ChipHere(Base);
  if not Found then
  begin
    WriteLn('chip     : no answer -- resetting it and asking again');
    for I := 1 to 3 do
    begin
      ChipReset;
      Found := ChipHere(Base);
      if Found then Break;
    end;
  end;
  if not Found then
  begin
    WriteLn('No CH375 at ', Hex2(Hi(Base)), Hex2(Lo(Base)), 'h.');
    Halt(1);
  end;
  I := BusUp;
  if I <> 0 then
  begin
    WriteLn('bus      : ', BusUpReason(I));
    WhyNoAnswer;
    Halt(2);
  end;
  { IcVer is printed HERE and not before BusUp, for two reasons. GetReg($01)
    was the first version and reported "rev 255" for a chip BusUp then went
    on to accept -- it is not the version register. And IcVer is only filled
    in by ChipReset, which BusUp performs: reading it any earlier printed
    "IC version 00" on the run where the recovery reset did not have to fire. }
  WriteLn('chip     : CH375 IC version ', Hex2(IcVer));
  WriteLn('bus      : up');

  if not EcmFind(E) then
  begin
    WriteLn('ECM      : ', E.Err);
    WriteLn;
    WriteLn('This adapter does not offer a CDC-ECM configuration. That is');
    WriteLn('normal for vendor-specific parts -- try USBLINK instead.');
    Halt(3);
  end;

  WriteLn('ECM found, and every one of these was READ, not assumed:');
  WriteLn('  configuration  : ', E.CfgValue);
  WriteLn('  control iface  : ', E.CtrlIf);
  WriteLn('  data iface     : ', E.DataIf, '  alt ', E.DataAlt);
  WriteLn('  bulk in / out  : ', E.EpIn, ' / ', E.EpOut);
  WriteLn('  interrupt in   : ', E.EpInt);
  WriteLn('  max segment    : ', E.MaxSeg);
  WriteLn('  MAC string idx : ', E.MacIdx);

  if not EcmBringUp(E) then
  begin
    WriteLn('bring-up : FAILED -- ', E.Err);
    Halt(4);
  end;
  if E.Err <> '' then WriteLn('note     : ', E.Err);
  WriteLn('MAC      : ', EcmMacStr(E));

  { Ask the link before blaming the driver. A down link NAKs every bulk OUT
    forever, which is indistinguishable from a transmit path that does not
    work -- and this adapter's vendor path really does not transmit, so the
    two explanations are both live here. }
  { Drain the WHOLE queue and believe the LAST one.

    The first hardware run read a single notification, printed "link: DOWN",
    and then transmitted a frame that was answered. Both readings were
    correct: an ECM device queues NETWORK_CONNECTION = 0 as it comes up and
    another with 1 when the PHY has finished negotiating, and taking the
    first of those reports the link as down for as long as the device has
    been alive. Reading one notification is worse than reading none, because
    it is confidently stale. }
  NKind := $FF; NVal := 0;
  Seen := 0;
  for I := 1 to 16 do
  begin
    if not EcmNotify(E, K, V) then Break;
    Inc(Seen);
    if K = $00 then begin NKind := K; NVal := V; end
    else WriteLn('notify   : type ', K, ' value ', V);
  end;
  if NKind = $00 then
  begin
    if NVal <> 0 then WriteLn('link     : UP  (device said so)')
    else
    begin
      WriteLn('link     : DOWN  (device said so, this early)');
      WriteLn('           Normal: the device queues NETWORK_CONNECTION = 0');
      WriteLn('           as it comes up and only reports 1 once the PHY has');
      WriteLn('           negotiated, seconds later. Read again at the end.');
    end;
  end
  else
  begin
    WriteLn('link     : not stated in ', Seen, ' notification(s).');
    WriteLn('           These are sent on CHANGE, so silence says nothing');
    WriteLn('           either way -- the ARP below is the real test.');
  end;

  if not HaveTgt then
  begin
    WriteLn;
    WriteLn('  Brought up, and TRANSMIT WAS NOT TESTED -- no /T= given.');
    WriteLn('  Everything above was read from the device, which proves the');
    WriteLn('  bring-up and nothing about the wire.  Run it again with');
    WriteLn('  /T=<a live host on this segment> for that.');
    Halt(0);
  end;

  Write('ARP      : who has ');
  for I := 0 to 3 do
  begin
    Write(TgtIp[I]);
    if I < 3 then Write('.');
  end;
  Write('?  tell ');
  for I := 0 to 3 do
  begin
    Write(OurIp[I]);
    if I < 3 then Write('.');
  end;
  WriteLn;

  Answered := False;
  for Tries := 1 to 8 do
  begin
    BuildArp;
    if not EcmSend(E, Frame, 60) then
    begin
      WriteLn('           send FAILED -- ', E.Err);
      Break;
    end;

    { Anything may arrive on a live segment, so read a few frames and look
      for the reply rather than assuming the next one is it. }
    for I := 1 to 40 do
    begin
      if not EcmRecv(E, Frame, SizeOf(Frame), Got, 200) then Continue;
      { It must be an ARP REPLY, from the address we asked about, addressed
        to OUR hardware address. All three, because a live segment carries
        other people's ARP traffic: the second hardware run accepted a reply
        from 192.168.50.249 to a request for .46 and declared the transmit
        path proven on the strength of it. That reading proves the RECEIVE
        path and nothing else -- which is precisely the half that was never
        in doubt on this adapter. }
      if (Got >= 42) and (Frame[12] = $08) and (Frame[13] = $06)
         and (Frame[20] = $00) and (Frame[21] = $02)
         and IsTarget and ToUs then
      begin
        Write('           REPLY from ');
        for J := 0 to 3 do
        begin
          Write(Frame[28 + J]);
          if J < 3 then Write('.');
        end;
        Write('  is at ');
        for J := 0 to 5 do
        begin
          Write(Hex2(Frame[22 + J]));
          if J < 5 then Write(':');
        end;
        WriteLn;
        Answered := True;
        Break;
      end;
    end;
    if Answered then Break;
    WriteLn('           no reply yet (attempt ', Tries, ')');
    if E.Err <> '' then WriteLn('           last receive: ', E.Err);
  end;

  { Ask the link again. It was read seconds ago, before the PHY could have
    finished negotiating, and the answer then is not the answer now. }
  NKind := $FF;
  for I := 1 to 16 do
  begin
    if not EcmNotify(E, K, V) then Break;
    if K = $00 then begin NKind := K; NVal := V; end;
  end;
  if NKind = $00 then
  begin
    if NVal <> 0 then WriteLn('link     : UP, now that the PHY has settled')
                 else WriteLn('link     : still DOWN');
  end;

  WriteLn;
  if Answered then
  begin
    WriteLn('  VERDICT: the adapter TRANSMITS and RECEIVES over CDC-ECM.');
    WriteLn('  A frame left this machine, another host parsed it, and the');
    WriteLn('  answer came back. That is the whole path.');
    Halt(0);
  end;
  WriteLn('  VERDICT: brought up, but nothing answered the ARP.');
  WriteLn('  Receive may still be fine -- this says the round trip is not.');
  WriteLn('  Check the cable, and that ', '', 'the target address is live.');
  Halt(5);
end.
