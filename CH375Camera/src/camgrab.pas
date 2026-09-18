unit camgrab;
{ CAMGRAB -- getting whole pictures out of an IBM PC Camera that streams far
  faster than a CH375 can listen.  CH375Camera, StevenC.  Public domain.

  WHAT THE CAMERA DOES WITH WHAT WE DO NOT READ.  Measured with CAMPROBE
  and CAMCAL, not taken from anywhere:

    * it packs each frame into a byte stream and sends it as 64-byte
      isochronous packets -- 64 because register 0106/0107 says so;
    * it has a FIFO of 33 packets.  When that is full, it drops;
    * during vertical blanking it has nothing, and answers every IN with a
      zero-length packet; the FIFO drains to empty if we keep reading;
    * a frame starts with 00 FF, and after the picture it sends 00 FF
      filler until the next blanking.

  So the part of a frame that arrives whole is whatever the FIFO can
  absorb after the blanking, plus whatever we drain while it arrives.  The
  camera also has a WINDOW -- four registers giving the part of the sensor
  it reads out -- so the trick is to make the window small enough that all
  of it arrives, and move it around the picture a frame at a time.

      0102   first column / 8, plus 1
      0103   last column / 8, exclusive
      0104   first line / 8
      0105   last line / 8, exclusive

  measured against each other with overlapping windows: one step is
  exactly 8 pixels or 8 lines, origin 0.  Those are SENSOR units; in the
  176x144 mode, which scales the whole sensor down by two, one step is 4
  output pixels.

  A window 64 wide and the full height delivers ~213 lines per frame from
  the Pascal loop CAMLIVE began with, reading a packet every ~1.1 ms
  against a line every ~1.14 ms.  GrabWindow's packet loop is assembly for
  that reason.

  LINES ARE CUT BY LENGTH.  The stream after the header is just bytes; a
  window W pixels wide gives W-byte lines in the Bayer modes, and in the
  YUV mode alternating W-byte (Y) and 2W-byte (V Y U Y) lines.  Nothing in
  the stream marks where a line ends, so nothing here assumes packets and
  lines line up -- they do for W = 64 and not otherwise. }

{$MODE OBJFPC}{$H-}{$ASMMODE INTEL}

interface

uses ch375, cit;

type
  TFormat = (fmtBayer, fmtYUV);

  TCamMode = record
    W, H:    Word;            { output picture size }
    Fmt:     TFormat;
    RegW:    Word;            { the width M2Start is given }
    Unit_:   Byte;            { output pixels per window step }
    StripW:  Word;            { widest window that keeps up, output px }
    Lead:    Byte;            { bytes before the picture in a frame that
                                arrives WITHOUT its 00 FF header }
    Hdr:     Byte;            { ...and in one that arrives with it }
    Overlap: Byte;            { output px each strip overlaps the next }
  end;

const
  NMODES = 3;
  Modes: array[1..NMODES] of TCamMode = (
    (W: 176; H: 144; Fmt: fmtYUV;   RegW: 176; Unit_: 4; StripW: 64;
     Lead: 1; Hdr: 3; Overlap: 4),
    (W: 320; H: 240; Fmt: fmtBayer; RegW: 320; Unit_: 8; StripW: 64;
     Lead: 0; Hdr: 2; Overlap: 0),
    (W: 352; H: 288; Fmt: fmtBayer; RegW: 352; Unit_: 8; StripW: 64;
     Lead: 0; Hdr: 2; Overlap: 0));

  { Overlap: at 176x144 the last column of every window comes out dark --
    Y 42 against 71 either side of it, measured -- which looks like the
    camera's 2:1 scaler averaging in a sensor pixel from outside the
    window.  So those strips overlap by one window step and each one's bad
    column is painted over by the next strip's good one.  The Bayer modes
    have no such column. }

  { Lead and Hdr were found by trying every offset against a recorded
    stream (CAMCAL, rawcal.py): the right one makes the Y samples inside a
    V Y U Y line agree with the Y line above them and leaves the chroma
    flat in grey areas.  At 176x144 every whole frame measured was 13834
    bytes -- 13824 of picture and ten of header, which is the sof_len of
    10 Linux's driver carries with a note that it "does not seem right":
    one byte leads the picture and the rest sit with the 00 FF filler. }

  MAXW = 352;
  MAXH = 288;

type
  PRow = ^TRow;
  TRow = array[0..MAXW - 1] of Byte;

var
  Mode: TCamMode;

  { The picture.  Bayer: Pix[y] is the raw mosaic row.  YUV: Pix[y] is
    luma, UPix/VPix[y div 2] are the half-width chroma rows.  Heap rows,
    because a 352x288 frame is more than one 64 KB segment. }
  Pix:  array[0..MAXH - 1] of PRow;
  UPix: array[0..MAXH div 2 - 1] of PRow;
  VPix: array[0..MAXH div 2 - 1] of PRow;

  { Called every 64 IN tokens so a program can keep a heartbeat going
    without paying for it on every packet. }
  Idle: procedure = nil;

  { Diagnostics from the last GrabWindow. }
  GWTokens:  LongInt;      { IN tokens spent }
  GWFrames:  Word;         { frames tried }
  GWBest:    Word;         { most lines any one frame delivered }
  GWBreak:   Byte;         { how the last short frame ended: 0 blanking,
                             1 00 FF, 2 failed token }
  GWFails:   LongInt;      { tokens that did not come back success }
  GWRevive:  Word;         { times the stream had to be restarted }
  PktStatus: Byte;         { the chip's status for the last token; FFh
                             if its interrupt never came }

{ Pick a mode (1..NMODES), start the camera in it and put the stream up.
  Returns 0 or an exit code, having said why. }
function CamStart(M: Integer; ClockDiv: Byte): Integer;
procedure CamStop;

{ One IN token at the video endpoint.  -1 = not a success; otherwise the
  length.  Assembly: this is the loop everything else waits on. }
function Pkt(var Buf): Integer;

{ Set the window in OUTPUT pixels -- X, W a multiple of Mode.Unit_ and Y,
  H of Mode.Unit_ too -- and take one whole frame of it into the picture.
  Tries = frames to wait.  True if every line arrived. }
function GrabWindow(X, Y, W, H: Word; Tries: Integer): Boolean;

{ The whole picture, as vertical strips.  PerStrip is called after each
  strip lands (nil for none) with the strip's X and W, so a display can
  paint as it goes.  Returns the number of strips that failed. }
type TStripProc = procedure(X, W: Word);
function GrabPicture(PerStrip: TStripProc; Tries: Integer): Integer;

{ Strip I of the picture (0..StripCount-1): where it starts, how wide. }
function StripCount: Integer;
procedure StripAt(I: Integer; var X, W: Word);

{ Height a window of width W can be in one frame without the FIFO
  overflowing.  Measured per mode; see Modes. }
function StripHeight(W: Word): Word;

{ ---- the picture as colour or grey ----
  Each works on output coordinates and is safe on the last row and
  column.  Bayer: the 2x2 block at (X, Y) always holds one red, two greens
  and one blue, so every pixel gets a full colour at full resolution;
  BayerOrder says which is where.  YUV: the usual conversion. }
var
  BayerOrder: array[0..3] of Byte = (1, 0, 2, 1);  { GRBG: 0 R, 1 G, 2 B }

procedure GetRGB(X, Y: Word; var R, G, B: Byte);
function  GetGrey(X, Y: Word): Byte;

{ The same for N pixels of row Y from column X0, into arrays -- for
  drawing, where a call per pixel costs more than the arithmetic. }
procedure RowRGB(Y, X0, N: Word; R, G, B: PByte);
procedure RowGrey(Y, X0, N: Word; G: PByte);

procedure SetBayerOrder(const S: ShortString);

implementation

var
  RPos, BPos: array[0..3] of Byte;

procedure BuildPos;
var P, Y, X, K, Cor: Integer;
begin
  for P := 0 to 3 do
  begin
    Y := P shr 1; X := P and 1;
    for K := 0 to 3 do
    begin
      Cor := BayerOrder[(((Y + (K shr 1)) and 1) shl 1) or ((X + (K and 1)) and 1)];
      if Cor = 0 then RPos[P] := K;
      if Cor = 2 then BPos[P] := K;
    end;
  end;
end;

procedure SetBayerOrder(const S: ShortString);
var I: Integer;
begin
  if Length(S) <> 4 then Exit;
  for I := 1 to 4 do
    case UpCase(S[I]) of
      'R': BayerOrder[I - 1] := 0;
      'G': BayerOrder[I - 1] := 1;
      'B': BayerOrder[I - 1] := 2;
    end;
  BuildPos;
end;

function CamStart(M: Integer; ClockDiv: Byte): Integer;
var R, Y: Integer;
begin
  Mode := Modes[M];
  for Y := 0 to Mode.H - 1 do
  begin
    if Pix[Y] = nil then GetMem(Pix[Y], MAXW);
    FillChar(Pix[Y]^, MAXW, 0);
  end;
  if Mode.Fmt = fmtYUV then
    for Y := 0 to Mode.H div 2 - 1 do
    begin
      if UPix[Y] = nil then GetMem(UPix[Y], MAXW div 2);
      if VPix[Y] = nil then GetMem(VPix[Y], MAXW div 2);
      FillChar(UPix[Y]^, MAXW div 2, 128);
      FillChar(VPix[Y]^, MAXW div 2, 128);
    end;
  BuildPos;

  R := CamUp;
  if R <> 0 then begin CamStart := R; Exit; end;
  M2Start(Mode.RegW, ClockDiv, 64);
  R := SetAlt(1);
  if R <> INT_SUCCESS then
  begin
    WriteLn('SET_INTERFACE 0 alt 1 -> ', StatusStr(R));
    CamStart := 11;
    Exit;
  end;
  SetRetry($00);
  StreamGo;
  Drain(300);                  { let auto-exposure settle }
  CamStart := 0;
end;

procedure CamStop;
begin
  SetRetry($8F);
  StreamStop;
  SetAlt(0);
  M2Off;
end;

{ ---- the packet loop ----

  The same conversation as ch375.EpIn, without the calls: SET_ENDP6 80h
  (isochronous is always DATA0), ISSUE_TOKEN 19h (IN, endpoint 1), wait
  for the chip's interrupt line -- bit 7 of the command port going low --
  then GET_STATUS, and on 14h RD_USB_DATA and the bytes.

  Commands keep the port 61h settling reads either side, as ch375.pas
  does; only the payload loop drops them, as CH375Net's driver does, for
  the reason given in cit.FastRead.  The wait is bounded: 30000 polls is
  some tens of milliseconds on this machine, far past any answer. }
function Pkt(var Buf): Integer;
var
  Dat, Cmd: Word;
  P: Pointer;
  R: Integer;
begin
  Dat := PortDat; Cmd := PortCmd; P := @Buf;
  asm
    push es
    push di
    mov  PktStatus, 0FFh
    mov  bx, -1                      { result: failure until shown otherwise }
    mov  dx, Cmd
    in   al, 61h
    mov  al, 1Ch                     { SET_ENDP6 }
    out  dx, al
    in   al, 61h
    in   al, 61h
    mov  dx, Dat
    mov  al, 80h
    out  dx, al
    in   al, 61h
    in   al, 61h
    mov  dx, Cmd
    mov  al, 4Fh                     { ISSUE_TOKEN }
    out  dx, al
    in   al, 61h
    in   al, 61h
    mov  dx, Dat
    mov  al, 19h                     { IN, endpoint 1 }
    out  dx, al
    in   al, 61h
    in   al, 61h
    { wait for the interrupt line }
    mov  dx, Cmd
    mov  cx, 30000
  @wait:
    in   al, dx
    test al, 80h
    jz   @got
    loop @wait
    jmp  @done
  @got:
    in   al, 61h
    mov  al, 22h                     { GET_STATUS }
    out  dx, al
    in   al, 61h
    in   al, 61h
    mov  dx, Dat
    in   al, 61h
    in   al, 61h
    in   al, dx
    mov  PktStatus, al
    cmp  al, 14h
    jne  @done
    { RD_USB_DATA }
    mov  dx, Cmd
    in   al, 61h
    mov  al, 28h
    out  dx, al
    in   al, 61h
    in   al, 61h
    mov  dx, Dat
    in   al, 61h
    in   al, 61h
    in   al, dx                      { the length }
    xor  ah, ah
    mov  bx, ax
    mov  cx, ax
    jcxz @done
    cmp  cx, 64
    ja   @drain
    les  di, P
    cld
  @rd:
    in   al, dx
    stosb
    loop @rd
    jmp  @done
  @drain:                            { chip not driving the bus: FF }
    in   al, dx
    loop @drain
    mov  bx, -1
  @done:
    mov  R, bx
    pop  di
    pop  es
  end;
  Pkt := R;
end;

{ ---- windows ---- }

function StripHeight(W: Word): Word;
begin
  StripHeight := Mode.H;
end;

var
  Tick64: Byte = 0;

const
  { Empty packets in a row that count as vertical blanking rather than a
    gap between lines.  A line takes about 1.1 ms and a packet about 1 ms,
    so a gap is one or two; blanking is dozens. }
  BLANK_RUN = 8;
  TAIL_SLACK = 8;

{ The frame's bytes are only COPIED while it arrives, into StripBuf, and
  sorted into lines and planes once it is complete.  Unpacking as it came
  was measured to lose the race in the YUV mode, which needs one and a
  half packets a line: the camera's FIFO overflowed, and when it does the
  camera abandons the rest of the frame and sends 00 FF filler -- frames
  that stopped at 73 of 144 lines, every time. }
const
  STRIPMAX = 64 * MAXH + 64;
var
  StripBuf: PByte = nil;

procedure Unpack(X, Y, W, H: Word);
var
  Line, K, CX, XX, Row: Word;
  P: PByte;
begin
  P := StripBuf;
  for Line := 0 to H - 1 do
  begin
    Row := Y + Line;
    if (Mode.Fmt = fmtYUV) and (Line and 1 = 1) then
    begin
      { V Y U Y, twice as long }
      CX := X shr 1; XX := X; K := 0;
      while K < 2 * W do
      begin
        VPix[Row shr 1]^[CX] := P[K];
        Pix[Row]^[XX]        := P[K + 1];
        UPix[Row shr 1]^[CX] := P[K + 2];
        Pix[Row]^[XX + 1]    := P[K + 3];
        Inc(K, 4); Inc(CX); Inc(XX, 2);
      end;
      Inc(P, 2 * W);
    end
    else
    begin
      Move(P^, Pix[Row]^[X], W);
      Inc(P, W);
    end;
  end;
end;

function GrabWindow(X, Y, W, H: Word; Tries: Integer): Boolean;
var
  Buf: array[0..63] of Byte;
  L, From, Take: Integer;
  Got, Need: Word;
  Started, Blank, IsHdr: Boolean;
  Frames, Zeros, FailRun: Integer;
  Budget: LongInt;
  U: Word;

  procedure FrameLost(Why: Byte);
  var Lines: Word;
  begin
    if Mode.Fmt = fmtYUV then Lines := (Got div (3 * W)) * 2
                         else Lines := Got div W;
    if Lines > GWBest then GWBest := Lines;
    GWBreak := Why;
    Inc(Frames);
    GWFrames := Frames;
    Started := False;
  end;

begin
  GrabWindow := False;
  if StripBuf = nil then GetMem(StripBuf, STRIPMAX);
  if Mode.Fmt = fmtYUV then Need := (H div 2) * 3 * W
                       else Need := H * W;
  U := Mode.Unit_;
  StreamStop;
  RegW(X div U + 1,   $0102);
  RegW((X + W) div U, $0103);
  RegW(Y div U,       $0104);
  RegW((Y + H) div U, $0105);
  StreamGo;

  GWTokens := 0; GWFrames := 0; GWBest := 0; GWBreak := 0;
  GWFails := 0; GWRevive := 0;
  Frames := 0;
  Blank := False;
  Started := False;
  Zeros := 0;
  FailRun := 0;
  Got := 0;
  Budget := LongInt(Tries) * 1000;
  while (Budget > 0) and (Frames < Tries) do
  begin
    Dec(Budget);
    Inc(GWTokens);
    Inc(Tick64);
    if (Tick64 and 63 = 0) and Assigned(Idle) then Idle;
    L := Pkt(Buf);

    if L < 0 then
    begin
      if Started then FrameLost(2);
      Blank := False;
      Zeros := 0;
      Inc(GWFails);
      Inc(FailRun);
      { A camera that answers nothing at all for a few hundred tokens has
        dropped out of streaming -- seen straight after a run that ended
        badly.  Re-arming the interface and the stream brings it back. }
      if FailRun >= 300 then
      begin
        FailRun := 0;
        Inc(GWRevive);
        SetRetry($8F);
        StreamStop;
        SetAlt(0);
        SetAlt(1);
        StreamGo;
        SetRetry($00);
      end;
      Continue;
    end;
    FailRun := 0;
    { An empty packet means the camera had nothing ready.  Between lines
      that happens for a packet or two once this loop is faster than the
      sensor -- it is -- so only a RUN of them is the vertical blanking. }
    if L = 0 then
    begin
      Inc(Zeros);
      if Zeros >= BLANK_RUN then
      begin
        if Started then FrameLost(0);
        Blank := True;
      end;
      Continue;
    end;
    Zeros := 0;
    IsHdr := (L >= 2) and (Buf[0] = 0) and (Buf[1] = $FF);

    From := 0;
    if not Started then
    begin
      { The first data after blanking starts a frame, with or without the
        00 FF header in front of it -- both happen, and a frame without
        one still begins at the window's first line (CAMCAL, measured
        against a full-height strip). }
      if not Blank then Continue;
      Blank := False;
      Started := True;
      Got := 0;
      if IsHdr then From := Mode.Hdr else From := Mode.Lead;
    end
    else if IsHdr then
    begin
      { 00 FF filler.  A frame a few bytes short of the end is complete in
        every way that matters -- at 176x144 some whole frames measured
        13824 bytes before the filler, one short once the lead byte is
        skipped -- so the tail is filled from the bytes before it and the
        frame kept.  Anything shorter really did end early. }
      if (Got > 0) and (Need - Got <= TAIL_SLACK) then
      begin
        while Got < Need do
        begin
          StripBuf[Got] := StripBuf[Got - 1];
          Inc(Got);
        end;
        Unpack(X, Y, W, H);
        GWFrames := Frames + 1;
        GWBest := H;
        GrabWindow := True;
        Exit;
      end;
      FrameLost(1);
      Continue;
    end;

    Take := L - From;
    if Take > Need - Got then Take := Need - Got;
    if Take > 0 then Move(Buf[From], StripBuf[Got], Take);
    Inc(Got, Take);
    if Got = Need then
    begin
      Unpack(X, Y, W, H);
      GWFrames := Frames + 1;
      GWBest := H;
      GrabWindow := True;
      Exit;
    end;
  end;
end;

function StripCount: Integer;
var Step: Word;
begin
  Step := Mode.StripW - Mode.Overlap;
  StripCount := (Mode.W - Mode.Overlap + Step - 1) div Step;
end;

procedure StripAt(I: Integer; var X, W: Word);
begin
  X := I * (Mode.StripW - Mode.Overlap);
  W := Mode.StripW;
  if X + W > Mode.W then W := Mode.W - X;
end;

function GrabPicture(PerStrip: TStripProc; Tries: Integer): Integer;
var
  X, W, Y, H, Bad: Word;
  I: Integer;
  Ok: Boolean;
begin
  Bad := 0;
  for I := 0 to StripCount - 1 do
  begin
    StripAt(I, X, W);
    Y := 0;
    Ok := True;
    while Y < Mode.H do
    begin
      H := StripHeight(W);
      if Y + H > Mode.H then H := Mode.H - Y;
      if not GrabWindow(X, Y, W, H, Tries) then Ok := False;
      Inc(Y, H);
    end;
    if not Ok then Inc(Bad);
    if Assigned(PerStrip) then PerStrip(X, W);
  end;
  GrabPicture := Bad;
end;

{ ---- colour ---- }

procedure GetRGB(X, Y: Word; var R, G, B: Byte);
var
  XS, YS, P: Word;
  Q: array[0..3] of Byte;
  Yv, Uv, Vv: Integer;
  T: Integer;
begin
  if Mode.Fmt = fmtBayer then
  begin
    XS := X; YS := Y;
    if XS = Mode.W - 1 then Dec(XS);
    if YS = Mode.H - 1 then Dec(YS);
    Q[0] := Pix[YS]^[XS];     Q[1] := Pix[YS]^[XS + 1];
    Q[2] := Pix[YS + 1]^[XS]; Q[3] := Pix[YS + 1]^[XS + 1];
    P := ((YS and 1) shl 1) or (XS and 1);
    R := Q[RPos[P]];
    B := Q[BPos[P]];
    G := (Word(Q[0]) + Q[1] + Q[2] + Q[3] - R - B) shr 1;
  end
  else
  begin
    Yv := Pix[Y]^[X];
    Uv := Integer(UPix[Y shr 1]^[X shr 1]) - 128;
    Vv := Integer(VPix[Y shr 1]^[X shr 1]) - 128;
    T := Yv + (Vv * 359) div 256;           R := T;
    if T < 0 then R := 0 else if T > 255 then R := 255;
    T := Yv - (Uv * 88 + Vv * 183) div 256; G := T;
    if T < 0 then G := 0 else if T > 255 then G := 255;
    T := Yv + (Uv * 454) div 256;           B := T;
    if T < 0 then B := 0 else if T > 255 then B := 255;
  end;
end;

function GetGrey(X, Y: Word): Byte;
var XS, YS: Word;
begin
  if Mode.Fmt = fmtYUV then begin GetGrey := Pix[Y]^[X]; Exit; end;
  XS := X + 1; YS := Y + 1;
  if XS = Mode.W then XS := X - 1;
  if YS = Mode.H then YS := Y - 1;
  GetGrey := (Word(Pix[Y]^[X]) + Pix[Y]^[XS] + Pix[YS]^[X] + Pix[YS]^[XS]) shr 2;
end;

var
  YRV, YBU: array[0..255] of Integer;       { V to red, U to blue }
  YGU, YGV: array[0..255] of Integer;       { U and V to green }

procedure BuildYUV;
var I: Integer;
begin
  for I := 0 to 255 do
  begin
    YRV[I] := ((I - 128) * 359) div 256;
    YBU[I] := ((I - 128) * 454) div 256;
    YGU[I] := ((I - 128) * 88) div 256;
    YGV[I] := ((I - 128) * 183) div 256;
  end;
end;

function Clip(V: Integer): Byte; inline;
begin
  if V < 0 then Clip := 0 else if V > 255 then Clip := 255 else Clip := V;
end;

procedure RowRGB(Y, X0, N: Word; R, G, B: PByte);
var
  A, C, U, V: PByte;
  X, XS, YS, K, Last: Word;
  Q: array[0..3] of Byte;
  RI, BI: array[0..1] of Byte;
  P: Word;
  Yv: Integer;
  Rr, Bb: Byte;
begin
  if Mode.Fmt = fmtYUV then
  begin
    A := PByte(Pix[Y]);
    U := PByte(UPix[Y shr 1]);
    V := PByte(VPix[Y shr 1]);
    for K := 0 to N - 1 do
    begin
      X := X0 + K;
      Yv := A[X];
      R[K] := Clip(Yv + YRV[V[X shr 1]]);
      G[K] := Clip(Yv - YGU[U[X shr 1]] - YGV[V[X shr 1]]);
      B[K] := Clip(Yv + YBU[U[X shr 1]]);
    end;
    Exit;
  end;
  YS := Y;
  if YS = Mode.H - 1 then Dec(YS);
  A := PByte(Pix[YS]);
  C := PByte(Pix[YS + 1]);
  { which corner is red and which blue, for a block starting on an even
    and on an odd column of this row }
  for K := 0 to 1 do
  begin
    P := ((YS and 1) shl 1) or K;
    RI[K] := RPos[P]; BI[K] := BPos[P];
  end;
  Last := Mode.W - 1;
  for K := 0 to N - 1 do
  begin
    XS := X0 + K;
    if XS = Last then Dec(XS);
    Q[0] := A[XS]; Q[1] := A[XS + 1]; Q[2] := C[XS]; Q[3] := C[XS + 1];
    P := XS and 1;
    Rr := Q[RI[P]]; Bb := Q[BI[P]];
    R[K] := Rr; B[K] := Bb;
    G[K] := (Word(Q[0]) + Q[1] + Q[2] + Q[3] - Rr - Bb) shr 1;
  end;
end;

procedure RowGrey(Y, X0, N: Word; G: PByte);
var
  A, C: PByte;
  K, XS, YS, Last: Word;
begin
  if Mode.Fmt = fmtYUV then
  begin
    Move(Pix[Y]^[X0], G^, N);
    Exit;
  end;
  YS := Y;
  if YS = Mode.H - 1 then Dec(YS);
  A := PByte(Pix[YS]);
  C := PByte(Pix[YS + 1]);
  Last := Mode.W - 1;
  for K := 0 to N - 1 do
  begin
    XS := X0 + K;
    if XS = Last then Dec(XS);
    G[K] := (Word(A[XS]) + A[XS + 1] + C[XS] + C[XS + 1]) shr 2;
  end;
end;

begin
  BuildYUV;
  FillChar(Pix, SizeOf(Pix), 0);
  FillChar(UPix, SizeOf(UPix), 0);
  FillChar(VPix, SizeOf(VPix), 0);
  BuildPos;
end.
