program UsbVfy;

{ USBVFY -- verify the CH375 receive path with nothing else in it.

  CH375Net, StevenC & Claude.  Public domain (the Unlicense).

      USBVFY <sender-ip> [/P=nnnn] [/I=nn] [/C=path] [/S=secs] [/V]

  WHY THIS EXISTS

  The corruption hunt had reached the point where every layer above the
  driver was excluded by measurement -- the disk, the burst parser, the
  server, and finally mTCP and HTGET together across 165 MB of clean
  NE2000 -- leaving the CH375 read itself.  But every test so far had run
  through a whole stack to reach it: HTTP over mTCP, to a file, checked
  afterwards.  That is a long way round for a question about one chip, and
  it costs 45 minutes per expected event.

  There is no need for any of it.  FPC is right here, DOSBridge's own
  IPv4/UDP is a unit we can call, and the packet driver takes a vector.  So
  this listens for UDP datagrams whose payload is a known function of their
  position in the stream, checks every byte as it arrives, and reports the
  EXACT displacement of anything wrong.  No TCP, no mTCP, no file system,
  no checksum filtering anywhere -- our stack does not verify receive
  checksums, so whatever the chip hands up is what gets tested.

  Two things it buys beyond convenience:

    * about twice the bytes per minute.  A blasting sender needs no
      acknowledgement, so the box collects bursts as fast as it can poll --
      the driver's ceiling is 31 reads of 64 bytes a tick, near 36 KB/s,
      against 16.8 measured over HTTP.  Events arrive twice as often.
    * the payload is a 32-bit counter of the absolute stream position, so a
      displacement is read off the bytes directly rather than inferred
      modulo 256.  That is the one measurement the whole hypothesis turns
      on: -64 means the chip's 64-byte packet buffer, -320 means the 64 was
      a coincidence twice over.

  THE WIRE FORMAT, which mkblast.py on the Windows side produces

    bytes 0..3    datagram sequence number, little endian
    bytes 4..N    payload[i] = byte ((G mod 4)) of (G div 4)
                  where G = seq * PAYLOAD + (i - 4)

  Each datagram is self-describing, so loss costs nothing: a dropped one is
  simply not checked, and there is no ordering requirement at all. }

{$MODE OBJFPC}{$H-}

uses Net, vidfix;

const
  VER      = '1.0.0';
  DEF_PORT = 9999;
  DEF_VEC  = $65;
  DEF_CFG  = 'C:\CH375\MTCPAX.CFG';
  DEF_SECS = 120;
  MAXDG    = 1400;
  HDR      = 8;              { magic, then the sequence number }
  SEQMAX   = 256;            { the sender cycles a window this size }
  MAXBAD   = 6;              { events reported in full before summarising }

{ Send something back every ACKEVY datagrams, and this is about FIDELITY
  rather than politeness.

  During an HTTP download the box transmits all the time -- a TCP ACK every
  couple of segments -- so pkt_send and rx_poll are continuously interleaved
  on the same CH375, arbitrated by the chip_busy flag.  A pure listener
  never transmits at all, so it does not exercise that interleaving, and a
  clean result from one would have said nothing about it while looking like
  it had exonerated the chip.

  Two segments per ACK is roughly what a TCP receiver does, so 2 it is.
  /A=0 turns it off, which makes the difference measurable rather than
  assumed: if corruption appears with transmit interleaved and not without,
  that is the answer. }
  ACK_EVERY = 2;      { Pascal is case-insensitive: this cannot be
                        ACKEVY, because AckEvy is the variable that
                        holds it.  CLAUDE.md records this trap twice
                        already -- InC is Inc, DdX is DDX -- and this
                        is the third name it has cost. }

var
  Sender  : TIP;
  Buf     : array[0..MAXDG - 1] of Byte;
  { What this datagram's payload MUST contain, built once per datagram and
    compared in one go.  See the note above the loop. }
  Exp     : array[0..MAXDG - 1] of Byte;
  ExpL    : array[0..(MAXDG div 4) - 1] of LongInt absolute Exp;
  Port    : Word;
  Vec     : Byte;
  Cfg     : ShortString;
  Secs    : Word;
  Verbose : Boolean;
  A       : ShortString;
  I, J    : Integer;
  Got     : Word;
  Seq     : LongInt;
  Bytes   : LongInt;
  Datas   : LongInt;
  BadD    : LongInt;
  BadB    : LongInt;
  Shown   : Integer;
  Deadline: LongInt;
  G       : LongInt;
  Want    : Byte;
  FirstBad: Integer;
  SrcW    : LongInt;
  Base    : LongInt;
  W0      : LongInt;
  Al      : Integer;
  Foreign : LongInt;
  BadHdr  : LongInt;
  Beat    : LongInt;     { when the heartbeat line was last redrawn }
  Spin    : Byte;
  AckEvy  : Word;
  Acks    : LongInt;
  AckBuf  : array[0..15] of Byte;

procedure Usage;
begin
  WriteLn('USBVFY ', VER, ' -- check the CH375 receive path, nothing above it', ' -- StevenC & Claude');
  WriteLn;
  WriteLn('  USBVFY <sender-ip> [/P=nnnn] [/I=nn] [/C=path] [/S=secs] [/V]');
  WriteLn;
  WriteLn('  /P=n   UDP port to listen on, default ', DEF_PORT);
  WriteLn('  /I=nn  packet driver vector in hex, default 65');
  WriteLn('  /S=n   seconds to listen, default ', DEF_SECS);
  WriteLn('  /A=n   transmit back every n datagrams, default ', ACK_EVERY,
          '; 0 = never.');
  WriteLn('         Not politeness -- during a real download the box ACKs');
  WriteLn('         constantly, so transmit and receive interleave on the');
  WriteLn('         chip.  A pure listener never tests that.');
  WriteLn;
  WriteLn('Run mkblast.py on the sender first.  Every datagram carries its');
  WriteLn('own sequence number and a payload that is a function of absolute');
  WriteLn('stream position, so loss costs nothing and a displacement is');
  WriteLn('read straight off the bytes instead of inferred modulo 256.');
end;

function Hex2(B: Byte): ShortString;
const H: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := H[B shr 4] + H[B and 15];
end;

{ A LIVE heartbeat, on stderr, driven by the CLOCK and not by traffic.

  A program that prints nothing for 45 minutes is indistinguishable from a
  hard-locked machine, and this one runs unattended for hours at a stretch.
  Driving the indicator from the datagram count would not fix that: it
  would freeze both when the program dies AND when traffic merely stops,
  which are the two cases most worth telling apart.  Driven by the tick:

    line advancing, counts rising    receiving normally
    line advancing, counts static    alive, nothing arriving
    line frozen                      the machine is locked

  Stderr because a job's stdout is redirected into OUT.TXT and reaches
  nobody until the job ends, while COMMAND.COM 6.22 has no stderr
  redirection at all -- so handle 2 lands on the real screen where doscap
  can photograph it, and the captured output stays clean.

  A carriage return and no newline, so it repaints one line in place and
  scrolls nothing.  The screen is a status display, not a scrollback. }
procedure HeartBeat;
const SPINCH = '|/-';
begin
  if NetTicks - Beat < 18 then Exit;      { about once a second }
  Beat := NetTicks;
  Spin := (Spin + 1) and 3;
  Write(StdErr, #13, 'USBVFY ', SPINCH[Spin + 1], ' ', Datas, ' dg  ',
        BadD, ' bad  ', BadHdr, ' badhdr  ', Foreign, ' foreign   ');
end;

{ The expected byte at absolute stream position G. }
function WantAt(G: LongInt): Byte;
var W: LongInt;
begin
  W := G shr 2;
  case Byte(G and 3) of
    0: WantAt := Byte(W and 255);
    1: WantAt := Byte((W shr 8) and 255);
    2: WantAt := Byte((W shr 16) and 255);
  else WantAt := Byte((W shr 24) and 255);
  end;
end;

function HexByte(S: ShortString; var B: Byte): Boolean;
var K, V, D: Integer;
begin
  HexByte := False; V := 0;
  if Length(S) = 0 then Exit;
  for K := 1 to Length(S) do
  begin
    case UpCase(S[K]) of
      '0'..'9': D := Ord(S[K]) - 48;
      'A'..'F': D := Ord(UpCase(S[K])) - 55;
    else Exit;
    end;
    V := V * 16 + D;
    if V > 255 then Exit;
  end;
  B := Byte(V); HexByte := True;
end;

function DecNum(S: ShortString): LongInt;
var K: Integer; V: LongInt;
begin
  V := 0;
  for K := 1 to Length(S) do
    if (S[K] >= '0') and (S[K] <= '9') then V := V * 10 + (Ord(S[K]) - 48);
  DecNum := V;
end;

begin
  Port := DEF_PORT; Vec := DEF_VEC; Cfg := DEF_CFG;
  Secs := DEF_SECS; Verbose := False; AckEvy := ACK_EVERY;

  if ParamCount < 1 then begin Usage; Halt(2); end;
  if not ParseIP(ParamStr(1), Sender) then
  begin
    WriteLn('USBVFY: "', ParamStr(1), '" is not an IP address');
    Halt(2);
  end;

  for I := 2 to ParamCount do
  begin
    A := ParamStr(I);
    for J := 1 to Length(A) do A[J] := UpCase(A[J]);
    if (A = '-V') or (A = '/V') then Verbose := True
    else if Copy(A, 1, 3) = '/P=' then Port := Word(DecNum(Copy(A, 4, 9)))
    else if Copy(A, 1, 3) = '/S=' then Secs := Word(DecNum(Copy(A, 4, 9)))
    else if Copy(A, 1, 3) = '/I=' then
    begin
      if not HexByte(Copy(A, 4, 9), Vec) then
      begin WriteLn('USBVFY: /I= wants a hex vector'); Halt(2); end;
    end
    else if Copy(A, 1, 3) = '/A=' then AckEvy := Word(DecNum(Copy(A, 4, 9)))
    else if Copy(A, 1, 3) = '/C=' then
      Cfg := Copy(ParamStr(I), 4, Length(ParamStr(I)) - 3);
  end;

  { Same refusal as USBGET, same reason: 60h is the network this machine is
    administered over, and taking an IP handle there loses the box. }
  if Vec = $60 then
  begin
    WriteLn('USBVFY: vector 60h is the bridge''s own network.  Refused.');
    Halt(4);
  end;

  NetVecWant := Vec;
  NetCfgWant := Cfg;

  { Take broadcast as well as unicast, and this is essential rather than
    permissive.  Nothing on this box answers ARP while our stack holds only
    the 0800 handle, so a sender's cache entry for us lapses in a couple of
    minutes and it stops delivering unicast entirely.  Measured before this
    line existed: NINE datagrams arrived in fifteen minutes out of roughly
    forty thousand sent.  Broadcast needs no resolution and does not lapse. }
  NetRxBcast := True;

  if not NetReadConfig then begin WriteLn('USBVFY: ', NetErr); Halt(2); end;
  if not NetOpen(Sender) then begin WriteLn('USBVFY: ', NetErr); Halt(2); end;

  WriteLn('USBVFY: vector ', Vec, '  addr ', IPStr(NetMyIP),
          '  port ', Port, '  for ', Secs, 's');
  WriteLn('  listening -- run the blaster now');

  Bytes := 0; Datas := 0; BadD := 0; BadB := 0; Shown := 0;
  Foreign := 0; BadHdr := 0; Acks := 0;
  Beat := NetTicks; Spin := 0;
  for I := 0 to 15 do AckBuf[I] := Byte(I);
  Deadline := NetTicks + LongInt(Secs) * 18;

  while NetTicks < Deadline do
  begin
    HeartBeat;
    if not NetUdpRecv(Port, Buf, MAXDG, Got, 18) then Continue;
    if Got < HDR + 4 then Continue;

    { Ours at all?  Without this a datagram whose header arrived corrupt
      cannot be told from one that was never ours, and 84 foreign
      datagrams appeared on this port in a single run. }
    if (Buf[0] <> Ord('U')) or (Buf[1] <> Ord('V'))
       or (Buf[2] <> Ord('F')) or (Buf[3] <> Ord('Y')) then
    begin
      Inc(Foreign);
      Continue;
    end;

    Seq := LongInt(Buf[4]) + LongInt(Buf[5]) * 256
         + LongInt(Buf[6]) * 65536 + LongInt(Buf[7]) * 16777216;
    Inc(Datas);
    Inc(Bytes, Got - HDR);

    { A sequence number out of range means the header itself was damaged.
      Report the raw bytes and stop -- computing a stream position from it
      overflows LongInt and prints confident nonsense, which is exactly
      what the first real event produced: "seq 2037260, displacement
      1450952336", from 2037260 * 1396 wrapping past 2^31. }
    if (Seq < 0) or (Seq >= SEQMAX) then
    begin
      Inc(BadHdr);
      if Shown < MAXBAD then
      begin
        Inc(Shown);
        WriteLn;
        WriteLn('  BAD HEADER: sequence ', Seq, ' is outside 0..',
                SEQMAX - 1, ' -- the header was corrupted in flight');
        Write('    first 16 bytes:');
        for I := 0 to 15 do Write(' ', Hex2(Buf[I]));
        WriteLn;
      end;
      Continue;
    end;

    { Interleave a transmit, so the chip is doing both jobs at once as it
      is during a real transfer. }
    if (AckEvy > 0) and (Datas mod AckEvy = 0) then
      if NetUdpSend(Port, Port, AckBuf, 16) then Inc(Acks);

    { Build the expected payload and compare it in ONE operation.

      The first version computed `Seq * PAYLOAD + i` inside the per-byte
      loop -- a 32-bit MULTIPLY for every byte, which BENCH prices at 91 us.
      1392 of those is 127 ms per datagram, so the tool topped out near 8
      datagrams a second and measured 4.9 KB/s while the wire was offering
      16.8.  It was three times slower than an HTTP download, which is
      absurd for a test whose whole purpose is to find a rare event faster,
      and it would have turned a 2.5 hour experiment into 9 hours.

      PAYLOAD is 1392 -- 1400 less the 8-byte header -- which is exactly
      348 longwords, and the payload always begins on a word boundary
      because Seq * 1392 is a multiple of 4.  So the expected contents are 349 consecutive longwords: build
      them with an increment and let CompareByte do the rest.  No multiply
      anywhere, and the per-byte walk is paid only by datagrams that
      actually differ -- which on a healthy run is none of them.

      This is the hoisting lesson from the raycaster notes, arrived at the
      hard way for a second time: moving work out of the inner loop beat
      every micro-optimisation, and the constant to check is the one being
      recomputed. }
    Base := Seq * (MAXDG - HDR);
    W0 := Base shr 2;
    for I := 0 to ((Got - HDR) div 4) do
      if I <= (MAXDG div 4) - 1 then ExpL[I] := W0 + I;

    FirstBad := -1;
    if CompareByte(Buf[HDR], Exp, Got - HDR) <> 0 then
      for I := HDR to Got - 1 do
      begin
        G := Base + (I - HDR);
        Want := WantAt(G);
        if Buf[I] <> Want then
        begin
          Inc(BadB);
          if FirstBad < 0 then FirstBad := I;
        end;
      end;

    if FirstBad >= 0 then
    begin
      Inc(BadD);
      if Shown < MAXBAD then
      begin
        Inc(Shown);
        G := Seq * (MAXDG - HDR) + (FirstBad - HDR);
        WriteLn;
        WriteLn('  BAD datagram seq ', Seq, ' at payload offset ',
                FirstBad - HDR, '  (stream ', G, ')');

        { Decode the misplaced word.  Its index IS the position the data
          actually came from, so the displacement is exact -- which is the
          whole reason the payload is a counter and not a ramp. }
        Al := FirstBad;
        while ((Al - HDR + (Seq * (MAXDG - HDR))) and 3) <> 0 do Inc(Al);
        J := 0;
        while (Al + 3 <= Got - 1) and (J < 4) do
        begin
          SrcW := LongInt(Buf[Al]) + LongInt(Buf[Al + 1]) * 256
                + LongInt(Buf[Al + 2]) * 65536
                + LongInt(Buf[Al + 3]) * 16777216;
          G := Seq * (MAXDG - HDR) + (Al - HDR);
          WriteLn('    +', Al - FirstBad, ' came from ', SrcW * 4,
                  '  displacement ', SrcW * 4 - G);
          Inc(Al, 4); Inc(J);
        end;
      end;
    end;
  end;

  NetClose;
  Write(StdErr, #13, '                                                     ',
        #13);

  WriteLn;
  WriteLn('  datagrams  : ', Datas, '  (', Bytes, ' payload bytes)');
  WriteLn('  bad        : ', BadD, ' datagram(s), ', BadB, ' byte(s)');
  WriteLn('  bad headers: ', BadHdr, '   foreign: ', Foreign);
  WriteLn('  transmits  : ', Acks, ' (every ', AckEvy, ' datagrams)');
  if Verbose then
    WriteLn('  driver rx  : ', NetRxFrames, ' accepted, ', NetRxWrong,
            ' not ours, ', NetRxDrop, ' dropped');
  if Datas = 0 then
  begin
    WriteLn('  nothing arrived -- is the blaster running, and pointed here?');
    Halt(3);
  end;
  if (BadD = 0) and (BadHdr = 0) then
  begin
    WriteLn('  VERDICT: every byte of every datagram was correct.');
    Halt(0);
  end;
  WriteLn('  VERDICT: the receive path altered data.  Nothing above the');
  WriteLn('  driver is in this test, so the displacement above is the');
  WriteLn('  chip or the code reading it, and nothing else.');
  Halt(1);
end.
