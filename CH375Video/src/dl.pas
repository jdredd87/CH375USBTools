unit dl;
{ DisplayLink over a CH375 -- the shared half.
  CH375Video, StevenC & Claude.  Public domain (the Unlicense).

  DLPROBE and DLTEST each grew their own copy of the bring-up and the
  command framing, and a third tool would have made three. This is that
  code once: open the adapter, set a mode, and get pixels into it.

  WHAT IS WORTH KNOWING BEFORE CHANGING ANY OF IT

  * Commands are a byte stream on the bulk OUT endpoint, each starting AF.
    A register write is "AF 20 <reg> <val>".

  * Most timing registers do NOT take the number you want. Registers 01
    through 15 take it pushed through a 16-bit LFSR; 0F and 17 take a
    plain big-endian word; 1B takes a byte-swapped one. Raw values give a
    dead screen and nothing to diagnose. From Linux's udlfb, which is the
    readable record of this protocol.

  * EVERY transfer must be padded with AF. The parser does not act on the
    final command until more bytes follow it, so an unpadded transfer
    silently drops its last command -- 256 pixels, which showed up as a
    strip of the previous picture surviving in the bottom-right corner.
    It reads as a drawing bug and is a framing one.

  * A bulk endpoint here is 64 bytes a packet and that is a USB limit, not
    a tunable. So throughput is transaction-bound: the only way to go
    faster is to SEND FEWER BYTES, which is what the RLE encoder and the
    dirty-rectangle helpers are for. CH375Net measured the same shape --
    inlining REP INSB there "moved 1 MB by 2 seconds in 73".

  DlBytes and DlPackets are kept so that claim stays measurable rather
  than becoming folklore. }

{$MODE OBJFPC}{$H-}
{$BOOLEVAL OFF}
{$ASMMODE INTEL}

interface

uses ch375;

type
  { Timings as Linux fb states them, because that is the form udlfb's
    register arithmetic is written against and translating twice is how
    sign errors get in. Margins are the porches; PixClk is picoseconds. }
  TDlTiming = record
    Name:   ShortString;
    XRes:   Word;
    YRes:   Word;
    LeftM:  Word;      { h back porch }
    RightM: Word;      { h front porch }
    HSync:  Word;
    UpperM: Word;      { v back porch }
    LowerM: Word;      { v front porch }
    VSync:  Word;
    PixClk: LongInt;   { picoseconds per pixel }
  end;

const
  DL_VID = $17E9;

  { DlOpen results, all <= 20 so they can be exit codes. }
  DL_OK      = 0;
  DL_NO_CHIP = 1;
  DL_OLD     = 2;
  DL_NOTHING = 3;
  DL_SILENT  = 4;
  DL_NODESC  = 5;
  DL_NOTDL   = 6;
  DL_REFUSED = 7;

  { WIDESCREEN, and what the clock cap does to it. 1280x720@60 needs
    74.25 MHz and even CVT reduced blanking wants 64 MHz, so 720p is not
    reachable on this adapter at any blanking -- the 40 MHz cap decides it,
    not the pixel count. 848x480@60 is the VESA 16:9 mode that does fit, at
    33.75 MHz, and 1024x576 does not (46.5 MHz).

    A modern 16:9 panel will usually letterbox or stretch 640x480 and
    800x600 quite happily, so those stay the dependable choices; 848x480
    is the one worth trying for a native-aspect picture. DLPROBE's
    intersection will say whether a given monitor lists it. }
  NDLMODES = 11;
  DlModes: array[0..NDLMODES - 1] of TDlTiming = (
    (Name: '640x480@60';  XRes: 640; YRes: 480;
     LeftM: 48;  RightM: 16; HSync: 96;
     UpperM: 33; LowerM: 10; VSync: 2;  PixClk: 39721),
    (Name: '640x480@75';  XRes: 640; YRes: 480;
     LeftM: 120; RightM: 16; HSync: 64;
     UpperM: 16; LowerM: 1;  VSync: 3;  PixClk: 31746),
    (Name: '800x600@56';  XRes: 800; YRes: 600;
     LeftM: 128; RightM: 24; HSync: 72;
     UpperM: 22; LowerM: 1;  VSync: 2;  PixClk: 27778),
    (Name: '800x600@60';  XRes: 800; YRes: 600;
     LeftM: 88;  RightM: 40; HSync: 128;
     UpperM: 23; LowerM: 1;  VSync: 4;  PixClk: 25000),
    { 16:9 at 33.75 MHz -- total 1088x517, which is 60.0 Hz exactly. }
    (Name: '848x480@60 (16:9)'; XRes: 848; YRes: 480;
     LeftM: 112; RightM: 16; HSync: 112;
     UpperM: 23; LowerM: 6;  VSync: 8;  PixClk: 29630),

    { 640x400@70 -- the VGA text-mode frame, and a real VESA timing.
      449 total lines at 70 Hz is 31.5 kHz of hsync, comfortably inside
      every monitor's range.  A fifth fewer pixels than 640x480. }
    (Name: '640x400@70'; XRes: 640; YRes: 400;
     LeftM: 48;  RightM: 16;  HSync: 96;
     UpperM: 35; LowerM: 12;  VSync: 2;  PixClk: 39721),

    { 320x200@70 -- LOW RES, and the reason it looks odd on paper.

      Hsync is vtotal x refresh, and a monitor wants at least 30 kHz. A
      genuine 320x200 frame is about 225 total lines, which at 70 Hz is
      15.7 kHz -- half the minimum. That is exactly why real VGA does not
      send 320x200 at all: it line-doubles it into a 400-line frame.

      There is no line doubler here, so the frame is padded instead: 200
      active lines inside a 449-line total, which keeps hsync at 31.5 kHz
      where the monitor wants it. The active picture is then less than
      half the height of the frame, and what a display does with that --
      centre it, stretch it, or letterbox it -- is the monitor's decision
      and not ours. Try it and look.

      The prize if it syncs is 64,000 pixels against 307,200. }
    (Name: '320x200@70 padded'; XRes: 320; YRes: 200;
     LeftM: 24;  RightM: 8;   HSync: 48;
     UpperM: 137; LowerM: 110; VSync: 2;  PixClk: 79542),

    { 320x240@60 -- VGA's 640x480 timings halved in BOTH axes, which is
      the principled way to do this and the one that actually looks right.

      The padded mode above carries 200 picture lines in a 449-line frame,
      so 55% of every frame is blanking and the display letterboxes the
      result into a band. Here the frame is 262 lines for 240 of picture:
      92% of it is the image, the aspect is 4:3, and it fills the screen.

      The cost is hsync. 400 x 262 x 60 is 15.7 kHz, which is CGA/TV
      territory -- fine for a capture card (this one says 14-76 kHz) or a
      multisync CRT, and REFUSED by most LCD panels, which want 30 kHz and
      up. That is the whole trade: the padded mode syncs anywhere and
      looks poor, this one looks right and syncs in fewer places. }
    (Name: '320x240@60 (half VGA)'; XRes: 320; YRes: 240;
     LeftM: 24;  RightM: 8;  HSync: 48;
     UpperM: 17; LowerM: 3;  VSync: 2;  PixClk: 159033),

    { 400x300@60 -- 800x600 halved, same idea, a little more detail.
      528 x 314 x 60 is 18.9 kHz of hsync. }
    (Name: '400x300@60 (half SVGA)'; XRes: 400; YRes: 300;
     LeftM: 44;  RightM: 20; HSync: 64;
     UpperM: 11; LowerM: 1;  VSync: 2;  PixClk: 100502),

    { 1024x768@60 at 65 MHz -- out of reach of an adapter that caps its
      pixel clock at 40 MHz, which is why it was not here before. The
      USB-to-DVI part advertises NO clock limit at all and a 2,360,000
      pixel area against 786,432 needed, so it is reachable there.
      DLPROBE's adapter column is what says which. }
    (Name: '1024x768@60'; XRes: 1024; YRes: 768;
     LeftM: 160; RightM: 24; HSync: 136;
     UpperM: 29; LowerM: 3;  VSync: 6;  PixClk: 15385),

    { 1280x1024@60 at 108 MHz -- 1,310,720 pixels against the DVI part's
      2,360,000 area limit, and it states no clock limit at all.  This is
      what DLPROBE's intersection recommends against a television that
      advertises it: the largest mode BOTH ends accept.  A frame is
      2,621,440 bytes, so nothing full-screen is quick here -- it is a
      mode for a dashboard that changes a little, not for animation. }
    (Name: '1280x1024@60'; XRes: 1280; YRes: 1024;
     LeftM: 248; RightM: 48; HSync: 112;
     UpperM: 38; LowerM: 1;  VSync: 3;  PixClk: 9259));

var
  DlEpBulk:  Byte = 0;
  DlBytes:   LongInt = 0;    { payload bytes handed to the chip }
  DlPackets: LongInt = 0;    { bulk OUT transactions issued }
  DlNaks:    LongInt = 0;    { NAKs retried in software }
  DlPad:     LongInt = 0;    { of DlBytes, how much was AF padding }
  { Use ch375's EpOut instead of the inlined packet writer. Exists so the
    two can be measured against each other rather than argued about --
    DLBENCH /O turns it on. }
  DlSlow:    Boolean = False;
  { Why the last send gave up, for callers to report rather than leaving
    somebody guessing at a stopped picture. }
  DlStuck:   Boolean = False;   { gave up on unending NAKs }
  DlLastErr: Integer = 0;       { the status that ended it, if not a NAK }

{ ---- which chip is this, and can it ever work here ----

  One table, in the shared unit, because every tool needs the same answer
  and a second copy of it would start disagreeing the first time one was
  updated.

  DlOpen identifies before it does anything else and leaves the answer in
  DlDevFamily, so a tool can branch on the family rather than on a vendor
  ID it has to know about itself. That is the dispatch point a second
  backend would hook into.

  There is exactly one backend behind it today, and the honest reason is
  worth stating: a USB display chip is usable over a link this slow ONLY
  if it has a framebuffer of its own and takes a compressed stream.
  DisplayLink does. Fresco Logic's FL2000 does neither and is out by three
  orders of magnitude -- so it is not an unwritten driver, it is an
  impossible one. See DlFamilyVerdict. }
const
  DLF_UNKNOWN     = 0;
  DLF_DISPLAYLINK = 1;
  DLF_FRESCO      = 2;
  DLF_MCT         = 3;
  DLF_SMSC        = 4;

var
  DlDevFamily: Integer = DLF_UNKNOWN;
  DlDevVID:    Word = 0;
  DlDevPID:    Word = 0;

function  DlFamily(VID: Word): Integer;
function  DlFamilyName(F: Integer): ShortString;
{ Prints why, at length, for the families where "no" needs a reason. }
procedure DlFamilyVerdict(F: Integer);

function  DlOpen: Integer;
function  DlWhy(Code: Integer): ShortString;
{ What stopped the last transfer, in words. }
function  DlWhyStuck: ShortString;
procedure DlZeroStats;

procedure DlEmit(B: Byte);
function  DlSend: Boolean;
procedure DlReg(R, V: Byte);
function  DlSetMode(const T: TDlTiming): Boolean;
function  DlBlank(On_: Boolean): Boolean;

{ 16bpp 5-6-5 from 8-bit components. }
function  DlRgb(R, G, B: Byte): Word;

{ A solid run of pixels at a byte address in the adapter's framebuffer. }
function  DlFillRun(Addr: LongInt; Colour: Word; Pixels: LongInt): Boolean;

{ A rectangle, which is just one run per row. }
function  DlFillRect(const T: TDlTiming; X, Y, W, H: Word;
                     Colour: Word): Boolean;

{ Arbitrary pixels, RLE-encoded -- the general primitive. P points at NPix
  16bpp values; Addr is where the first one goes. }
function  DlRleRun(Addr: LongInt; P: PWord; NPix: Word): Boolean;

{ Address of a pixel, for callers building their own runs. }
function  DlAddr(const T: TDlTiming; X, Y: Word): LongInt;

{ ---- a mode the MONITOR asked for, rather than one of ours ----

  DlModes above is a table of standard timings, and a table can only ever
  contain what somebody thought to put in it. A display states its own
  preferred timing in its EDID, in full -- pixel clock, actives, blanking,
  sync offsets and widths -- which is everything TDlTiming needs.

  So this builds a mode from an EDID detailed timing descriptor. Blk is 0
  to 3; block 0 is by definition the monitor's PREFERRED mode.

  The porches have to be derived rather than read, and that is the only
  subtle part. EDID gives total blanking, the sync OFFSET (which is the
  front porch) and the sync WIDTH; the back porch is what is left:

      front porch = sync offset
      sync        = sync pulse width
      back porch  = blanking - offset - width

  Getting that subtraction backwards shifts the picture sideways and still
  syncs, which is the kind of wrong that looks like a monitor needing its
  auto-adjust. False is returned for a block that is not a timing at all
  (pixel clock zero means it is a text or range descriptor) or one whose
  numbers do not add up. }
{ Results, because "it did not work" covers three different facts and
  only one of them is a problem with the descriptor. }
const
  DLT_OK       = 0;   { decoded, and T is usable }
  DLT_NOTIMING = 1;   { a text or range block, not a timing at all }
  DLT_BAD      = 2;   { a timing whose numbers do not add up }
  DLT_TOOBIG   = 3;   { decoded perfectly, and far beyond this hardware }

function  DlTimingFromEdid(const Edid; Blk: Integer;
                           var T: TDlTiming): Integer;
function  DlTimingWhy(Code: Integer): ShortString;

{ ---- proving the machine is alive, and letting somebody out ----

  CLAUDE.md's rule, and every tool here broke it: a program that runs for
  more than a few seconds must prove it is alive, and the proof has to be
  driven by the CLOCK.

  Run from the bridge, a silent 45-second tool is merely unhelpful. Run
  from the machine's own prompt it is indistinguishable from a lockup, and
  DLDASH cost a power cycle for exactly that reason -- nothing printed,
  and nothing answered the keyboard either, because a loop doing port I/O
  never calls DOS so Ctrl-Break is never seen.

  DlTick writes to STDERR, because a job's stdout is redirected into a
  file and reaches nobody until the job ends, while DOS cannot redirect
  handle 2 at all -- so this lands on the real screen where somebody is
  looking. It writes in place and scrolls nothing, and it takes its phase
  from the BIOS tick rather than from the work, so it stops when the
  MACHINE stops and not when the work merely pauses.

  DlEscaped is the way out: Esc, checked cheaply, every loop. }
procedure DlTick;
function  DlEscaped: Boolean;

{ ---- a breadcrumb that survives a hang ----

  When a program stops dead, the only evidence left is what it managed to
  get onto DISK before it stopped. Console output is gone the moment the
  machine is power-cycled, and a job's captured stdout never arrives at
  all -- so a tool that freezes tells you nothing about WHERE it froze.

  The agent loop already solves this for boot phases with
  C:\AGENT\PHASE.LOG. This is the same trick for the display tools.

  The file is opened, written and CLOSED for every line. That is slow, and
  it is the entire point: a line still sitting in a DOS buffer when the
  machine stops is a line that was never written, and this exists only for
  the case where the next thing to happen is a power cycle.

  Set DlMarkTo to a filename to turn it on; empty is off and costs
  nothing. }
var
  DlMarkTo: ShortString;

procedure DlSay(const S: ShortString);
procedure DlMark(const S: ShortString);

implementation

const
  DL_REQ_CHANNEL = $12;
  { Two seconds of NAKs is not a busy endpoint, it is a broken one. }
  DL_GIVEUP      = 36;          { ticks, about 2 s at 18.2 Hz }
  DL_ACKWAIT     = 10;          { per attempt; a bulk OUT ACKs at once }
  DL_CMDMAX      = 2048;
  { Flush this far short of the end: one RLE command can reach ~775 bytes
    in the worst case, and PadTail still has to fit after it. }
  DL_FLUSHAT     = 1100;

  ChanKey: array[0..15] of Byte = (
    $57, $CD, $DC, $A7, $1C, $88, $5E, $15,
    $60, $FE, $C6, $97, $16, $3D, $47, $F2);

var
  Cmd:    array[0..DL_CMDMAX - 1] of Byte;
  CmdLen: Word = 0;
  TogOut: Byte = $80;
  Cfg:    array[0..511] of Byte;
  CfgGot: Word = 0;

procedure DlZeroStats;
begin
  DlBytes := 0; DlPackets := 0; DlNaks := 0; DlPad := 0;
end;

const
  { #92 is a backslash.  Written as a code because Pascal has no
    escape character, so a literal one inside quotes is fine in
    Pascal and a minefield in every tool that edits this file. }
  Spin: array[0..3] of Char = ('|', '/', '-', #92);

var
  LastSpin: LongInt = -1;

{ Says what is happening, on STDERR so it lands on the real screen
  whether or not stdout has been redirected into a job's capture file.
  Unconditional: the cost is a few lines and the benefit is that a tool
  which stops is a tool you can see the last step of. }
procedure DlSay(const S: ShortString);
begin
  WriteLn(ErrOutput, S);
end;

procedure DlMark(const S: ShortString);
var F: Text;
begin
  if DlMarkTo = '' then Exit;
  Assign(F, DlMarkTo);
  {$I-}
  Append(F);
  if IOResult <> 0 then Rewrite(F);
  if IOResult <> 0 then Exit;
  WriteLn(F, S);
  Close(F);
  {$I+}
  if IOResult <> 0 then ;
end;

procedure DlTick;
var T: LongInt;
begin
  T := Ticks shr 2;                    { about four a second }
  if T = LastSpin then Exit;
  LastSpin := T;
  Write(ErrOutput, Spin[T and 3], #8);
end;

function GetKeyRaw: Char; assembler;
asm
  mov ah, 0
  int 16h
end;

{ Drains whatever is waiting, so a held key cannot build a backlog that
  outlives the loop.  Esc anywhere in it means stop. }
function DlEscaped: Boolean;
var Hit: Boolean;
begin
  Hit := False;
  while KeyWaiting do
    if GetKeyRaw = #27 then Hit := True;
  DlEscaped := Hit;
end;

function DlRgb(R, G, B: Byte): Word;
begin
  DlRgb := (Word(R and $F8) shl 8) or (Word(G and $FC) shl 3) or (B shr 3);
end;

function DlAddr(const T: TDlTiming; X, Y: Word): LongInt;
begin
  DlAddr := (LongInt(Y) * T.XRes + X) * 2;
end;

{ EDID detailed timing descriptors are 18 bytes each, starting at 54. }
function DlTimingWhy(Code: Integer): ShortString;
begin
  case Code of
    DLT_OK:       DlTimingWhy := 'ok';
    DLT_NOTIMING: DlTimingWhy := 'not a timing block';
    DLT_BAD:      DlTimingWhy := 'the numbers do not add up';
    DLT_TOOBIG:   DlTimingWhy := 'decoded, but far beyond this hardware';
  else
    DlTimingWhy := 'unknown';
  end;
end;

function DlTimingFromEdid(const Edid; Blk: Integer;
                          var T: TDlTiming): Integer;
var
  E: PByte;
  O: Integer;
  Clk: LongInt;
  HA, HB, VA, VB: Word;
  HFp, HSy, VFp, VSy: Word;
  Up: Byte;
  S: ShortString;
begin
  DlTimingFromEdid := DLT_BAD;
  if (Blk < 0) or (Blk > 3) then Exit;
  E := @Edid;
  O := 54 + Blk * 18;

  Clk := LongInt(E[O]) or (LongInt(E[O + 1]) shl 8);
  if Clk = 0 then
  begin
    DlTimingFromEdid := DLT_NOTIMING;
    Exit;
  end;

  HA := E[O + 2] or ((Word(E[O + 4] and $F0)) shl 4);
  HB := E[O + 3] or ((Word(E[O + 4] and $0F)) shl 8);
  VA := E[O + 5] or ((Word(E[O + 7] and $F0)) shl 4);
  VB := E[O + 6] or ((Word(E[O + 7] and $0F)) shl 8);

  Up  := E[O + 11];
  HFp := E[O + 8] or ((Word(Up and $C0)) shl 2);
  HSy := E[O + 9] or ((Word(Up and $30)) shl 4);
  VFp := (E[O + 10] shr 4) or ((Word(Up and $0C)) shl 2);
  VSy := (E[O + 10] and $0F) or ((Word(Up and $03)) shl 4);

  { Everything has to add up, or the descriptor is not one we understand
    and guessing at it would produce a mode that syncs and looks wrong. }
  if (HA = 0) or (VA = 0) then Exit;
  if HB <= HFp + HSy then Exit;
  if VB <= VFp + VSy then Exit;

  { Out of range is NOT a decode failure, and saying so matters: a 4K
    television states 3840x2160 as its preferred mode, which parses
    perfectly and is simply beyond anything reachable here. Reporting that
    as "did not decode" blames the descriptor for a limit of ours, which
    is the same mistake the CH375's GET_DESCR shortcut made. }
  if (HA > 2048) or (VA > 1536) then
  begin
    T.XRes := HA;
    T.YRes := VA;
    T.PixClk := 100000000 div Clk;
    DlTimingFromEdid := DLT_TOOBIG;
    Exit;
  end;

  T.XRes   := HA;
  T.YRes   := VA;
  T.RightM := HFp;                      { front porch }
  T.HSync  := HSy;
  T.LeftM  := HB - HFp - HSy;           { back porch is the remainder }
  T.LowerM := VFp;
  T.VSync  := VSy;
  T.UpperM := VB - VFp - VSy;

  { EDID states the clock in units of 10 kHz; TDlTiming wants picoseconds
    per pixel. }
  T.PixClk := 100000000 div Clk;
  if T.PixClk <= 0 then Exit;

  Str(HA, S);      T.Name := S + 'x';
  Str(VA, S);      T.Name := T.Name + S + ' (from EDID)';
  DlTimingFromEdid := DLT_OK;
end;

{ ------------------------------------------------------------ the stream }

procedure DlEmit(B: Byte);
begin
  if CmdLen < DL_CMDMAX then
  begin
    Cmd[CmdLen] := B;
    Inc(CmdLen);
  end;
end;

{ Load the chip's OUT buffer straight from the command buffer, as ONE
  assembler block with no procedure calls in it.

  This is the whole speed story on this path, and the benchmark is what
  found it rather than a guess. The first measurement was 72 packets a
  second, which is 13.9 ms for a 64-byte packet -- and a USB bulk
  transaction takes microseconds, so the time was never on the wire. It
  was 64 iterations of ch375's WrDat, each of which is three nested
  procedure calls: WrDat, OutB, and IoDelay's two InB. In a Large-model
  binary every one of those reloads a far pointer, and BENCH measures a
  procedure call on this machine at 46,501 a second. 64 x 3 of them is
  about 4 ms spent before a single byte reaches a port.

  Deliberately NOT using REP OUTSB. That is an 80186 instruction which a
  plain 8086 does not have, so it would need a run-time CPU gate and an
  8086 fallback kept working beside it -- and the portable loop
  below already collapses the per-byte cost from three calls to three
  instructions. CLAUDE.md's rule applies: do not write a gated fast path
  when the gate costs more to maintain than the win buys. One path, runs
  everywhere, and the same code will be correct on the 486 this is
  eventually meant for.

  The two IN 61h reads are ch375's standard ISA settling delay and are
  kept where they matter -- after a COMMAND byte -- and dropped between
  payload bytes, which is what USBPKT's REP OUTSB already proved safe on
  this machine. }
procedure WrPacket(Ofs: Word; Len: Byte); assembler;
asm
    push  si
    mov   dx, [PortCmd]
    in    al, $61
    in    al, $61
    mov   al, $2B                  { CMD_WR_USB_DATA7 }
    out   dx, al
    in    al, $61
    in    al, $61
    mov   dx, [PortDat]
    mov   al, [Len]
    out   dx, al
    in    al, $61
    in    al, $61
    mov   cl, [Len]
    xor   ch, ch
    jcxz  @done
    lea   si, [Cmd]
    add   si, [Ofs]
    cld
@lp:
    lodsb
    out   dx, al
    loop  @lp
@done:
    pop   si
end;

{ A bulk OUT that retries its own NAKs, which is right for a data endpoint:
  a NAK there means "busy, ask again", and the data toggle only advances on
  success, so re-issuing the identical token is correct rather than merely
  harmless. The payload is re-loaded on a retry because the chip's buffer
  is not guaranteed to have survived the failed attempt. }
{ BOUNDED BY THE CLOCK, not by a retry count -- and the difference is the
  whole reason this is written out at length.

  A count is not a bound. The first version retried a NAK 600 times, and
  each attempt calls WaitInt, which polls 24,000 times before giving up
  when the device has stopped answering at all -- about a second. Six
  hundred of those is TEN MINUTES for one 64-byte packet, and a dashboard
  frame is some three hundred packets.

  That is not a slow program, it is one indistinguishable from a hung
  machine, which is precisely the failure CLAUDE.md keeps warning about:
  DLDASH run from the keyboard looked frozen and cost a power cycle.

  So the retry is limited by elapsed TICKS. A bulk endpoint that is
  working ACKs in microseconds; one that is merely busy clears in
  milliseconds; anything still NAKing after two seconds is not busy, it is
  broken, and saying so immediately is worth far more than continuing to
  hope. The timeout per attempt comes down too -- 60 was inherited from
  the control path, where a device is entitled to think about it. }
function SendPacket(Ofs: Word; Len: Byte): Boolean;
var
  R: Integer;
  T0: LongInt;
begin
  SendPacket := False;
  T0 := Ticks;
  while True do
  begin
    if DlSlow then
      R := EpOut(DlEpBulk, TogOut, Cmd[Ofs], Len)
    else
    begin
      WrPacket(Ofs, Len);
      WrCmd(CMD_SET_ENDP7);   WrDat(TogOut);
      WrCmd(CMD_ISSUE_TOKEN); WrDat((DlEpBulk shl 4) or PID_OUT);
      R := WaitInt(DL_ACKWAIT);
      if R = INT_SUCCESS then TogOut := TogOut xor $40;
    end;
    Inc(DlPackets);
    if R = INT_SUCCESS then
    begin
      DlBytes := DlBytes + Len;
      SendPacket := True;
      Exit;
    end;

    if R = INT_RET_NAK then
    begin
      Inc(DlNaks);
      if Ticks < T0 then Exit;                { midnight rollover }
      if Ticks - T0 > DL_GIVEUP then
      begin
        DlStuck := True;
        Exit;
      end;
      Continue;
    end;

    if R = INT_RET_STALL then ClrStall(DlEpBulk);
    DlLastErr := R;
    Exit;
  end;
end;

{ Pad the tail with AF.  Not tidiness: the parser does not act on the final
  command until more bytes follow it, so without this the last command of
  every transfer is silently dropped.  AF is the byte every command starts
  with, so a run of them is filler the parser resynchronises on. }
procedure PadTail;
var I: Integer;
begin
  for I := 1 to 16 do begin DlEmit($AF); Inc(DlPad); end;
  while (CmdLen mod 64) <> 0 do begin DlEmit($AF); Inc(DlPad); end;
end;

{ Sent straight out of the command buffer at an offset -- there is no
  intermediate 64-byte copy, which was another 128 far-pointer array
  accesses per packet for nothing. }
function DlSend: Boolean;
var
  I: Word;
  N: Byte;
begin
  DlSend := True;
  if CmdLen = 0 then Exit;

  { The heartbeat lives HERE, not in each tool's main loop, and that
    placement is the fix rather than a tidy-up.

    Put in the loops, it proved the tool alive only once the loop was
    running -- so DLOPEN, the mode set and the first full-screen clear,
    several seconds between the banner and any output, showed nothing at
    all. That is precisely the window somebody reported as a freeze.

    Every tool reaches the adapter through this one function, so one call
    covers all of them and every phase of them, start-up included. It is
    gated on the BIOS tick, so it costs a comparison per flush. }
  DlTick;
  PadTail;
  I := 0;
  while I < CmdLen do
  begin
    if CmdLen - I < 64 then N := Byte(CmdLen - I) else N := 64;
    if not SendPacket(I, N) then
    begin
      DlSend := False;
      CmdLen := 0;
      Exit;
    end;
    Inc(I, N);
  end;
  CmdLen := 0;
end;

procedure DlReg(R, V: Byte);
begin
  DlEmit($AF); DlEmit($20); DlEmit(R); DlEmit(V);
end;

procedure Reg16(R: Byte; V: Word);          { high byte first }
begin
  DlReg(R, Hi(V)); DlReg(R + 1, Lo(V));
end;

procedure Reg16Sw(R: Byte; V: Word);        { udlfb's _16be: low first }
begin
  DlReg(R, Lo(V)); DlReg(R + 1, Hi(V));
end;

{ THE part that cannot be guessed.  Registers 01..15 want their value
  pushed through this LFSR rather than written as a number. }
function Lfsr16(V: Word): Word;
var
  Lv: LongInt;
  I:  Word;
begin
  Lv := $FFFF;
  for I := 1 to V do
    Lv := ((Lv shl 1)
           or (((Lv shr 15) xor (Lv shr 4) xor (Lv shr 2) xor (Lv shr 1))
               and 1)) and $FFFF;
  Lfsr16 := Word(Lv);
end;

procedure RegL16(R: Byte; V: Word);
begin
  Reg16(R, Lfsr16(V));
end;

{ ------------------------------------------------------------- the mode }

function DlSetMode(const T: TDlTiming): Boolean;
var
  Xds, Xde, Yds, Yde, Yec: Word;
  Fb: LongInt;
begin
  CmdLen := 0;

  DlReg($FF, $00);                      { lock the video registers }
  DlReg($00, $00);                      { colour depth: the 16bpp segment }
  DlReg($20, 0); DlReg($21, 0); DlReg($22, 0);      { 16bpp base = 0 }

  { The 8bpp segment is parked past the end of the 16bpp framebuffer so
    the two cannot overlap.  Nothing here draws through it. }
  Fb := LongInt(T.XRes) * T.YRes * 2;
  DlReg($26, Byte(Fb shr 16));
  DlReg($27, Byte(Fb shr 8));
  DlReg($28, Byte(Fb));

  Xds := T.LeftM + T.HSync;             RegL16($01, Xds);
  Xde := Xds + T.XRes;                  RegL16($03, Xde);
  Yds := T.UpperM + T.VSync;            RegL16($05, Yds);
  Yde := Yds + T.YRes;                  RegL16($07, Yde);
  RegL16($09, Xde + T.RightM - 1);
  RegL16($0B, 1);
  RegL16($0D, T.HSync + 1);
  Reg16 ($0F, T.XRes);
  Yec := T.YRes + T.UpperM + T.LowerM + T.VSync;
  RegL16($11, Yec);
  RegL16($13, 0);
  RegL16($15, T.VSync);
  Reg16 ($17, T.YRes);
  Reg16Sw($1B, Word(200000000 div T.PixClk));

  DlReg($1F, $00);                      { unblank }
  DlReg($FF, $FF);                      { and release the registers }

  DlSetMode := DlSend;
end;

function DlBlank(On_: Boolean): Boolean;
begin
  CmdLen := 0;
  DlReg($FF, $00);
  if On_ then DlReg($1F, $01) else DlReg($1F, $00);
  DlReg($FF, $FF);
  DlBlank := DlSend;
end;

{ ------------------------------------------------------------- the pixels }

{ A solid run.  This is why a full screen is affordable at all: 256
  identical pixels -- 512 bytes of framebuffer -- encode in TEN bytes.
  A run of exactly one carries NO repeat byte, which is a genuine shape
  difference rather than a count of zero. }
function DlFillRun(Addr: LongInt; Colour: Word; Pixels: LongInt): Boolean;
var N: Word;
begin
  DlFillRun := False;
  while Pixels > 0 do
  begin
    if Pixels >= 256 then N := 256 else N := Word(Pixels);
    if CmdLen > DL_FLUSHAT then
      if not DlSend then Exit;

    DlEmit($AF); DlEmit($6B);
    DlEmit(Byte(Addr shr 16)); DlEmit(Byte(Addr shr 8)); DlEmit(Byte(Addr));
    DlEmit(Byte(N and $FF));                   { 256 encodes as 0 }
    DlEmit(1);                                 { one literal pixel ... }
    DlEmit(Hi(Colour)); DlEmit(Lo(Colour));
    if N > 1 then DlEmit(Byte(N - 1));         { ... repeated N-1 times }

    Addr := Addr + LongInt(N) * 2;
    Pixels := Pixels - N;
  end;
  DlFillRun := True;
end;

function DlFillRect(const T: TDlTiming; X, Y, W, H: Word;
                    Colour: Word): Boolean;
var I: Word;
begin
  DlFillRect := False;
  for I := 0 to H - 1 do
    if not DlFillRun(DlAddr(T, X, Y + I), Colour, W) then Exit;
  DlFillRect := True;
end;

{ udlfb's compress_hline, faithfully: a mixed raw/repeat encoding over an
  arbitrary run of pixels.  This is what makes text and line art cheap --
  both are mostly background, which collapses into repeats -- and what
  leaves photographs expensive, since nothing in them repeats.

  The counts are patched in after the fact because neither is known until
  the run has been walked, which is why this works on buffer indices
  rather than the pointer arithmetic the C uses. }
function DlRleRun(Addr: LongInt; P: PWord; NPix: Word): Boolean;
var
  I, Stop:            Word;
  CmdCountAt, RawAt:  Word;
  CmdStart, RawStart: Word;
  RepStart:           Word;
  V:                  Word;
begin
  DlRleRun := False;
  I := 0;
  while I < NPix do
  begin
    if CmdLen > DL_FLUSHAT then
      if not DlSend then Exit;

    DlEmit($AF); DlEmit($6B);
    DlEmit(Byte(Addr shr 16)); DlEmit(Byte(Addr shr 8)); DlEmit(Byte(Addr));
    CmdCountAt := CmdLen; DlEmit(0);
    CmdStart := I;
    RawAt := CmdLen; DlEmit(0);
    RawStart := I;

    Stop := I + 256;
    if Stop > NPix then Stop := NPix;

    while I < Stop do
    begin
      RepStart := I;
      V := P[I];
      DlEmit(Hi(V)); DlEmit(Lo(V));
      Inc(I);
      if I >= Stop then Break;
      if P[I] <> V then Continue;

      { A repeat: close the raw count, skip the run, state its length,
        and open a fresh raw count after it. }
      Cmd[RawAt] := Byte((RepStart - RawStart + 1) and $FF);
      repeat
        Inc(I);
        if I >= Stop then Break;
      until P[I] <> V;
      DlEmit(Byte((I - RepStart - 1) and $FF));
      RawStart := I;
      RawAt := CmdLen; DlEmit(0);
    end;

    if I > RawStart then
      Cmd[RawAt] := Byte((I - RawStart) and $FF)
    else
      Dec(CmdLen);                  { the raw count opened and unused }

    Cmd[CmdCountAt] := Byte((I - CmdStart) and $FF);
    Addr := Addr + LongInt(I - CmdStart) * 2;
  end;
  DlRleRun := True;
end;

{ ------------------------------------------------------------- bring-up }

function DlFamily(VID: Word): Integer;
begin
  case VID of
    $17E9: DlFamily := DLF_DISPLAYLINK;
    $1D5C: DlFamily := DLF_FRESCO;
    $0711: DlFamily := DLF_MCT;
    $0424: DlFamily := DLF_SMSC;
  else
    DlFamily := DLF_UNKNOWN;
  end;
end;

function DlFamilyName(F: Integer): ShortString;
begin
  case F of
    DLF_DISPLAYLINK: DlFamilyName := 'DisplayLink';
    DLF_FRESCO:      DlFamilyName := 'Fresco Logic (FL2000 family)';
    DLF_MCT:         DlFamilyName := 'Magic Control Technology (Trigger)';
    DLF_SMSC:        DlFamilyName := 'Microchip / SMSC';
  else
    DlFamilyName := 'unrecognised';
  end;
end;

procedure DlFamilyVerdict(F: Integer);
begin
  case F of
    DLF_DISPLAYLINK:
      WriteLn('  Driven by this code.');

    DLF_FRESCO:
      begin
        WriteLn('  An FL2000 or FL2000DX -- a USB-to-VGA/HDMI bridge,');
        WriteLn('  usually paired with an ITE IT66121 HDMI transmitter.');
        WriteLn;
        WriteLn('  IT CANNOT WORK ON A CH375, and that is architecture');
        WriteLn('  rather than a driver nobody has written yet.');
        WriteLn;
        WriteLn('    DisplayLink has a framebuffer in the chip and takes a');
        WriteLn('    COMPRESSED command stream: send a change once and the');
        WriteLn('    picture holds indefinitely.');
        WriteLn;
        WriteLn('    FL2000 has no framebuffer at all.  It bridges USB to');
        WriteLn('    parallel RGB, so the whole frame must arrive RAW and');
        WriteLn('    keep arriving, at the pixel clock, forever.');
        WriteLn;
        WriteLn('  640x480 at 16bpp and 60 Hz is 36.9 MB a second.  This');
        WriteLn('  path measures 19 KB/s: short by about 1,900 times, and');
        WriteLn('  still 25 times short of what full-speed USB could carry');
        WriteLn('  at its theoretical best.  There is no slow path either,');
        WriteLn('  because a slow path presumes something holding the');
        WriteLn('  picture between frames, and nothing does.');
      end;

    DLF_MCT, DLF_SMSC:
      begin
        WriteLn('  A display chip family this code does not drive.');
        WriteLn('  UNTRIED rather than ruled out: both are said to');
        WriteLn('  compress, which is the property that decides whether');
        WriteLn('  anything is possible over a link this slow.  Whether');
        WriteLn('  either holds a framebuffer is the question to answer');
        WriteLn('  first, and USBINFO is where to start.');
      end;
  else
    begin
      WriteLn('  Not a display chip family this code knows about.');
      WriteLn('  USBINFO dumps every descriptor the device will give up.');
      WriteLn;
      WriteLn('  What makes one of these usable here is narrow: it needs a');
      WriteLn('  FRAMEBUFFER of its own, so a picture holds once sent, and');
      WriteLn('  a COMPRESSED command stream, so sending it is affordable.');
      WriteLn('  A chip missing either is not a driver away from working.');
    end;
  end;
end;

function DlWhy(Code: Integer): ShortString;
begin
  case Code of
    DL_OK:      DlWhy := 'ok';
    DL_NO_CHIP: DlWhy := 'no CH375 responds at that I/O address';
    DL_OLD:     DlWhy := 'CH375 firmware too old for host mode';
    DL_NOTHING: DlWhy := 'nothing attached to the card';
    DL_SILENT:  DlWhy := 'attached, but nothing answers on the bus';
    DL_NODESC:  DlWhy := 'the device stopped answering mid-enumeration';
    DL_NOTDL:   DlWhy := 'not a DisplayLink device';
    DL_REFUSED: DlWhy := 'the adapter refused the channel unlock';
  else
    DlWhy := 'unknown';
  end;
end;

function DlWhyStuck: ShortString;
begin
  if DlStuck then
    DlWhyStuck := 'the adapter NAKed every attempt for two seconds -- it '
                + 'is not busy, it has stopped accepting the stream'
  else if DlLastErr <> 0 then
    DlWhyStuck := 'the adapter answered ' + StatusStr(DlLastErr)
  else
    DlWhyStuck := 'no fault recorded';
end;

{ A chip left wedged by an earlier program fails CHECK_EXIST, and BusUp
  gives up on that before it reaches its own ChipReset -- so the wedge is
  sticky across runs and reads as an empty slot.  Reset and ask again. }
function ChipThere: Boolean;
begin
  ChipThere := ChipHere(Base);
  if ChipThere then Exit;
  ChipReset;
  DelayMs(200);
  ChipThere := ChipHere(Base);
end;

function DlOpen: Integer;
var
  Rc, St, I: Integer;
  VID: Word;
  L: Byte;
begin
  if not ChipThere then begin DlOpen := DL_NO_CHIP; Exit; end;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    case Rc of
      BU_OLD_CHIP: DlOpen := DL_OLD;
      BU_NOTHING:  DlOpen := DL_NOTHING;
      BU_NO_ANSWER: DlOpen := DL_SILENT;
    else
      DlOpen := DL_NODESC;
    end;
    Exit;
  end;

  VID := DevDesc[8] or (Word(DevDesc[9]) shl 8);
  DlDevVID := VID;
  DlDevPID := DevDesc[10] or (Word(DevDesc[11]) shl 8);
  DlDevFamily := DlFamily(VID);
  if DlDevFamily <> DLF_DISPLAYLINK then begin DlOpen := DL_NOTDL; Exit; end;

  St := CtrlIn($80, REQ_GET_DESCR, Word(DT_CONFIG) shl 8, 0,
               CfgWant, Cfg, SizeOf(Cfg), CfgGot);
  if (St <> INT_SUCCESS) or (CfgGot < 9) then
  begin
    DlOpen := DL_NODESC; Exit;
  end;

  { Nothing is assumed about the endpoint number: this adapter answers 01,
    another need not. }
  DlEpBulk := 0;
  I := 0;
  while I + 1 < CfgGot do
  begin
    L := Cfg[I];
    if L < 2 then Break;
    { The FIRST bulk OUT, not the last.  A device may offer more than
      one -- the USB-to-DVI part here has both 01 and 0A -- and udlfb
      renders to endpoint 1, so taking whichever came last picked the
      wrong pipe and would have sent a command stream into silence. }
    if (Cfg[I + 1] = DT_ENDPOINT) and (L >= 6) and (DlEpBulk = 0) then
      if ((Cfg[I + 3] and $03) = $02) and ((Cfg[I + 2] and $80) = 0) then
        DlEpBulk := Cfg[I + 2] and $0F;
    Inc(I, L);
  end;
  if DlEpBulk = 0 then begin DlOpen := DL_NODESC; Exit; end;

  SetConfig(CfgDesc[5]);

  St := CtrlOut($40, DL_REQ_CHANNEL, 0, 0, ChanKey, 16);
  if St <> INT_SUCCESS then begin DlOpen := DL_REFUSED; Exit; end;

  { A data endpoint from here on, so NAKs are reported rather than
    absorbed in hardware for the whole timeout. }
  SetRetry($00);
  DlZeroStats;
  DlOpen := DL_OK;
end;

end.
