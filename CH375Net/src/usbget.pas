program UsbGet;

{ USBGET -- fetch a file over the USB adapter with mTCP nowhere in the path.

  CH375Net, StevenC.  Public domain (the Unlicense).

      USBGET <server-ip> <remote-name> <local-file> [/I=nn] [/C=path] [/V]

  THIS EXISTS TO ANSWER ONE QUESTION.

  A 5 MB download over USBPKT comes back corrupt about one time in eleven:
  a region of the file overwritten with payload duplicated from elsewhere in
  the stream, everything else in step.  The burst parser has been ruled out
  by measurement -- the tiling counter reads zero on the runs that corrupt
  and has fired on a run that did not -- so what reaches the stack is
  believed correct and what lands on disk is not.

  But the same mTCP and the same HTGET over the same disk are clean across
  15 MB through the NE2000, so it cannot be a plain bug in either.  What
  differs is the REGIME: the NE2000 moves 5 MB in 63 seconds and this
  adapter takes 312, which is a completely different world for a TCP
  connection -- a receive window that actually fills, retransmission timers
  that actually fire, overlapping segments a fast path may never produce.

  So: take mTCP out and keep everything else.  This fetches over TFTP on
  DOSBridge's own IPv4/UDP stack, through the SAME CH375 adapter, to the
  same disk.  Stop-and-wait, one packet in flight, no window and no
  retransmission overlap.

    corrupts here  -> the driver's data path is at fault, definitively,
                      because there is no TCP left to blame.
    clean here     -> suggestive only.  TFTP never creates the conditions
                      TCP does, so this cannot convict mTCP -- it can only
                      fail to convict the driver.  Say so if it comes back
                      clean; the asymmetry is the whole point.

  WHY IT NEEDS TWO OVERRIDES IN net.pas

  The Net unit scans vectors 60h..80h and takes the first packet driver it
  finds, which on this box is always the NE2000 the machine is administered
  over -- so without NetVecWant this would test the wrong adapter and look
  reassuringly clean.  And NET_CFG names that same interface, so NetCfgWant
  points at the USB adapter's own address instead.  Both default to the old
  behaviour, so UGET and UPUT are unaffected.

  Never aim this at vector 60h.  It would take an IP handle on the network
  the bridge runs over, and the bridge is how this machine is reachable. }

{$MODE OBJFPC}{$H-}

uses Net, Tftp, vidfix;

const
  VER       = '1.0.0';
  TFTP_PORT = 8069;
  DEF_VEC   = $65;
  DEF_CFG   = 'C:\CH375\MTCPAX.CFG';

var
  Server: TIP;
  Remote, Local, A: ShortString;
  I, J: Integer;
  Verbose: Boolean;
  Vec: Byte;
  Cfg: ShortString;
  N: Integer;

procedure Usage;
begin
  WriteLn('USBGET ', VER, ' -- TFTP over the USB adapter, no mTCP involved');
  WriteLn;
  WriteLn('  USBGET <server-ip> <remote> <local> [/I=nn] [/C=path] [/V]');
  WriteLn;
  WriteLn('  /I=nn  packet driver vector in hex, default ', DEF_VEC, ' (65h)');
  WriteLn('  /C=p   network config to read, default ', DEF_CFG);
  WriteLn('  /V     report the transfer counters');
  WriteLn;
  WriteLn('Fetches over DOSBridge''s own IPv4/UDP through the CH375');
  WriteLn('adapter, so a corrupt result accuses the driver with no TCP');
  WriteLn('left to blame.  A clean result proves much less -- TFTP is');
  WriteLn('stop-and-wait and never builds the conditions TCP does.');
end;

function HexByte(S: ShortString; var B: Byte): Boolean;
var K: Integer; V, D: Integer;
begin
  HexByte := False;
  V := 0;
  if Length(S) = 0 then Exit;
  for K := 1 to Length(S) do
  begin
    case UpCase(S[K]) of
      '0'..'9': D := Ord(S[K]) - 48;
      'A'..'F': D := Ord(UpCase(S[K])) - 55;
    else
      Exit;
    end;
    V := V * 16 + D;
    if V > 255 then Exit;
  end;
  B := Byte(V);
  HexByte := True;
end;

begin
  Verbose := False;
  Vec := DEF_VEC;
  Cfg := DEF_CFG;

  if ParamCount < 3 then begin Usage; Halt(2); end;

  if not ParseIP(ParamStr(1), Server) then
  begin
    WriteLn('USBGET: "', ParamStr(1), '" is not an IP address (no DNS here)');
    Halt(2);
  end;
  Remote := ParamStr(2);
  Local  := ParamStr(3);

  for I := 4 to ParamCount do
  begin
    A := ParamStr(I);
    for J := 1 to Length(A) do A[J] := UpCase(A[J]);
    if (A = '-V') or (A = '/V') then Verbose := True
    else if (Length(A) > 3) and (Copy(A, 1, 3) = '/I=') then
    begin
      if not HexByte(Copy(A, 4, Length(A) - 3), Vec) then
      begin
        WriteLn('USBGET: /I= wants a hex vector');
        Halt(2);
      end;
    end
    else if (Length(A) > 3) and (Copy(A, 1, 3) = '/C=') then
      Cfg := Copy(ParamStr(I), 4, Length(ParamStr(I)) - 3);
  end;

  { The one refusal, and it is not overridable.  60h carries the network
    this machine is administered over; taking an IP handle there is how you
    lose the box with no way in to undo it. }
  if Vec = $60 then
  begin
    WriteLn('USBGET: vector 60h is the bridge''s own network.  Refused.');
    Halt(4);
  end;

  NetVecWant := Vec;
  NetCfgWant := Cfg;

  if not NetReadConfig then
  begin
    WriteLn('USBGET: ', NetErr);
    Halt(2);
  end;
  if not NetOpen(Server) then
  begin
    WriteLn('USBGET: ', NetErr);
    Halt(2);
  end;

  { Say what was actually resolved, because getting this wrong is silent
    and looks exactly like a network fault.  If the config override does
    not take, NetMyIP falls back to the BRIDGE's address -- and then the
    server's reply is sent to the NE2000's MAC, the USB-side listener never
    sees it, and the failure reads as "no reply" with nothing to suggest
    the cause was local. }
  Write('USBGET: vector ', Vec, '  addr ');
  for I := 0 to 3 do
  begin
    Write(NetMyIP[I]);
    if I < 3 then Write('.');
  end;
  WriteLn('  cfg ', Cfg);

  { Ask for big blocks, exactly as UGET does for a file fetch: 1400 is the
    ceiling because Net drops fragments rather than reassembling them. }
  TftpWantBlk := 1400;

  { 36 ticks, which is what UGET passes for a fetch -- about two seconds.
    Passing 0 here was the first version's bug: the first-reply wait became
    zero ticks, so it gave up in 1.3 seconds across three attempts and
    reported "no reply after 3 requests", which reads as a dead network
    rather than as a timeout that was never given a chance.  A driver
    polled at 18.2 Hz cannot answer inside no time at all. }
  if TftpGet(TFTP_PORT, Remote, Local, 36, True) then
  begin
    WriteLn('USBGET: ', TftpBytes, ' bytes on vector ', Vec, ' (no mTCP)');
    if Verbose then
      WriteLn('  blocks ', TftpBlocks, ' of ', TftpBlkSize,
              '  resends ', TftpResends, '  dups ', TftpDups,
              '  restarts ', TftpRestarts);
    NetClose;
    Halt(0);
  end;

  WriteLn('USBGET FAILED: ', TftpErr);
  WriteLn('  blocks ', TftpBlocks, '  resends ', TftpResends,
          '  restarts ', TftpRestarts);
  NetClose;
  Halt(1);
end.
