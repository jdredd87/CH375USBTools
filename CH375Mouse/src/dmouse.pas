unit dmouse;
{ dmouse -- serial mouse protocols.
  CH375Mouse, StevenC.  Public domain (the Unlicense).

  NOTHING IN THIS UNIT KNOWS WHAT A USB ADAPTER IS, and that is the whole
  point of it existing separately.  It takes bytes that arrived from a
  serial port -- any serial port -- and turns them into movement and
  button state.  Everything that differs between one USB-to-serial chip
  and the next lives in dser.pas, behind SerOpen/SerSend/SerRecv/SerClose.

  So a mouse driver written against this unit works on whatever adapters
  dser can drive today, and on whatever it learns tomorrow, without a line
  changing here.  The alternative -- a driver that reaches into the
  adapter for its line settings -- is how a project ends up with one mouse
  driver per adapter, each subtly different.

  THE TWO PROTOCOLS, AND WHY BOTH ARE HERE

  Microsoft is 1200 7N1 and three bytes; Mouse Systems is 1200 8N1 and
  five.  They are not variations on a theme, they disagree about the frame
  size, the data bits and the sense of the button bits, so a decoder has
  to know which one it is holding.

  Guessing wrong is not a subtle failure but it IS a quiet one.  The DOS
  bridge's own notes record exactly this: CuteMouse probed the machine's
  own mouse, settled on Microsoft, and INT 33h then reported no movement
  at all -- a working mouse and a working port reading as dead hardware.
  That is why Identify below prefers evidence over assumption, and why a
  caller is expected to try the other framing rather than conclude the
  mouse is broken. }

{$MODE OBJFPC}{$H-}

interface

type
  TMouseProto = (mpUnknown,
                 mpMicrosoft,     { 7N1, 3 bytes, 2 buttons }
                 mpLogitech,      { Microsoft plus a 4th byte for the middle }
                 mpMouseSys);     { 8N1, 5 bytes, 3 buttons, active low }

  { One decoded report.  DX/DY are relative counts, positive right and
    DOWN -- screen order, not maths order, because every consumer of this
    is a screen. }
  TMouseEvent = record
    DX, DY  : Integer;
    Buttons : Byte;              { bit0 left, bit1 right, bit2 middle }
  end;

  TMouseDec = record
    Proto   : TMouseProto;
    Buf     : array[0..7] of Byte;
    N       : Byte;
    Buttons : Byte;              { held, so a report with no change is still
                                   able to say what is pressed }
    Reports : LongInt;
    Resyncs : LongInt;           { bytes thrown away looking for a header }
  end;

function  ProtoName(P: TMouseProto): ShortString;

{ Data bits the protocol needs on the wire: 7 for Microsoft, 8 for Mouse
  Systems.  A caller passes this straight to SerOpen, which is the only
  reason this unit knows the number at all. }
function  ProtoBits(P: TMouseProto): Byte;

{ What a mouse announced when its power lines were raised.  A Microsoft
  mouse sends 'M'; a three-button Logitech sends 'M' then '3'.  Mouse
  Systems mice announce NOTHING, so an empty answer is a real answer and
  not a failure -- see the note in Identify. }
function  IdentifyId(const Buf; Len: Word): TMouseProto;

{ Look at a run of bytes and say which protocol they are consistent with,
  without needing an identification byte.  Used when the mouse was already
  powered, or when it is one that never announces itself.

  WrongBits comes back True when the bytes are a Mouse Systems stream being
  read through SEVEN data bits.  That is not a hypothetical: it is what
  this project saw on its first run, and without a name for it the evidence
  is baffling.  A 7-bit line strips bit 7, so the 87h header reads as 07h
  and every negative delta reads as 7Fh, 7Eh, 7Ch -- a stream that looks
  like no protocol at all while being a perfectly good one behind a
  framing mistake.  Detecting it is worth more than detecting either
  protocol cleanly, because it is the case where the obvious conclusion
  ("not a mouse") is wrong. }
function  IdentifyStream(const Buf; Len: Word): TMouseProto;
function  IdentifyStreamEx(const Buf; Len: Word;
                           var WrongBits: Boolean): TMouseProto;

procedure MouseInit(var D: TMouseDec; P: TMouseProto);

{ Feed one byte.  True when a complete report came out, with E filled in. }
function  MouseFeed(var D: TMouseDec; B: Byte; var E: TMouseEvent): Boolean;

implementation

function ProtoName(P: TMouseProto): ShortString;
begin
  case P of
    mpMicrosoft: ProtoName := 'Microsoft (1200 7N1, 3 bytes, 2 buttons)';
    mpLogitech:  ProtoName := 'Logitech (Microsoft plus a middle button)';
    mpMouseSys:  ProtoName := 'Mouse Systems (1200 8N1, 5 bytes, 3 buttons)';
  else
    ProtoName := 'unknown';
  end;
end;

function ProtoBits(P: TMouseProto): Byte;
begin
  if P = mpMouseSys then ProtoBits := 8 else ProtoBits := 7;
end;

function IdentifyId(const Buf; Len: Word): TMouseProto;
var
  P : PByte;
  I : Word;
begin
  IdentifyId := mpUnknown;
  if Len = 0 then Exit;
  P := @Buf;
  { The announcement is 'M', possibly with junk around it: the first byte
    out of a mouse that has just been powered up is not always clean,
    because the line settles while the UART is already listening. }
  for I := 0 to Len - 1 do
    if P[I] = Ord('M') then
    begin
      { 'M3' is the three-button Logitech.  Checked before returning
        Microsoft, because a Logitech answers to the Microsoft decode as
        well and the middle button would simply never be seen. }
      if (I + 1 < Len) and (P[I + 1] = Ord('3')) then
        IdentifyId := mpLogitech
      else
        IdentifyId := mpMicrosoft;
      Exit;
    end;
end;

{ Score a candidate framing by CADENCE, and judge it by a rule that was
  arrived at from the data rather than guessed.

  Counting how many bytes in the whole stream look like a header is a weak
  test, and it was the first thing tried and the first thing to fail: small
  movement values pass a header mask perfectly well.  What a packet stream
  has that noise does not is PERIOD -- every Nth byte is a header and the
  ones between are not.

  The first version of this compared the best phase against the SUM of the
  others, which on a five-byte period means comparing one phase against
  four and is simply the wrong arithmetic.  On the real capture it scored
  13 against 30 and rejected a stream that was textbook.

  The rule that works, measured on captures of both protocols plus noise
  and an all-zero degenerate case: EXACTLY ONE PHASE IS ENTIRELY HEADERS.
  On a correct Mouse Systems capture that is 13 of 13 against 0; on the
  same mouse read through seven bits it is 13 of 13 against a next-best of
  9 of 13 -- so the ratio is uninformative and "all of them, and only
  here" is decisive.  Requiring uniqueness is what rejects a buffer of
  zeros, where every phase matches. }
procedure Cadence(P: PByte; Len: Word; Period, Mask, Value: Byte;
                  var FullPhases: Byte);
var
  Ph, I  : Word;
  Hits   : Word;
  Total  : Word;
begin
  FullPhases := 0;
  for Ph := 0 to Word(Period) - 1 do
  begin
    Hits := 0; Total := 0;
    I := Ph;
    while I < Len do
    begin
      Inc(Total);
      if (P[I] and Mask) = Value then Inc(Hits);
      Inc(I, Period);
    end;
    { Four packets is the least that means anything; below that a short
      burst of movement can look like whatever you ask it to. }
    if (Total >= 4) and (Hits = Total) then Inc(FullPhases);
  end;
end;

function IdentifyStreamEx(const Buf; Len: Word;
                          var WrongBits: Boolean): TMouseProto;
var
  P : PByte;
  N : Byte;
begin
  IdentifyStreamEx := mpUnknown;
  WrongBits := False;
  if Len < 20 then Exit;
  P := @Buf;

  { Mouse Systems, read correctly: 87h every fifth byte. }
  Cadence(P, Len, 5, $F8, $80, N);
  if N = 1 then
  begin
    IdentifyStreamEx := mpMouseSys;
    Exit;
  end;

  { The same mouse through SEVEN data bits, which strips bit 7 and turns
    every 87h header into 07h.  Checked second so a correct reading always
    wins, and reported through WrongBits so the caller can say "your line
    settings are wrong" instead of "this is not a mouse". }
  Cadence(P, Len, 5, $F8, $00, N);
  if N = 1 then
  begin
    IdentifyStreamEx := mpMouseSys;
    WrongBits := True;
    Exit;
  end;

  { Microsoft: bit 6 set on every third byte and clear on the other two. }
  Cadence(P, Len, 3, $C0, $40, N);
  if N = 1 then IdentifyStreamEx := mpMicrosoft;
end;

function IdentifyStream(const Buf; Len: Word): TMouseProto;
var Dummy: Boolean;
begin
  IdentifyStream := IdentifyStreamEx(Buf, Len, Dummy);
end;

procedure MouseInit(var D: TMouseDec; P: TMouseProto);
begin
  D.Proto   := P;
  D.N       := 0;
  D.Buttons := 0;
  D.Reports := 0;
  D.Resyncs := 0;
end;

{ Sign-extend an 8-bit two's complement value the 16-bit way. }
function Sign8(B: Byte): Integer;
begin
  if B >= $80 then Sign8 := Integer(B) - 256 else Sign8 := Integer(B);
end;

function MouseFeed(var D: TMouseDec; B: Byte; var E: TMouseEvent): Boolean;
var
  Need : Byte;
  X, Y : Integer;
begin
  MouseFeed := False;

  case D.Proto of
    mpMicrosoft, mpLogitech:
      begin
        { RESYNCHRONISE ON THE HEADER RATHER THAN COUNTING BLINDLY.  A
          byte lost anywhere -- and one will be, sooner or later, on a
          line nobody is flow-controlling -- puts a counting decoder
          permanently one byte out, and every report after it is built
          from the wrong three bytes.  It does not look like a lost byte;
          it looks like a mouse that jumps. }
        if (B and $40) <> 0 then
        begin
          if D.N <> 0 then Inc(D.Resyncs);
          D.N := 0;                      { a header always starts a report }
        end
        else if D.N = 0 then
        begin
          Inc(D.Resyncs);                { body byte with no header: drop }
          Exit;
        end;

        D.Buf[D.N] := B;
        Inc(D.N);
        if D.N < 3 then Exit;

        X := Integer(((D.Buf[0] and $03) shl 6) or (D.Buf[1] and $3F));
        Y := Integer((((D.Buf[0] shr 2) and $03) shl 6) or (D.Buf[2] and $3F));
        E.DX := Sign8(Byte(X));
        E.DY := Sign8(Byte(Y));

        D.Buttons := D.Buttons and $04;  { keep the middle, replace the rest }
        if (D.Buf[0] and $20) <> 0 then D.Buttons := D.Buttons or $01;
        if (D.Buf[0] and $10) <> 0 then D.Buttons := D.Buttons or $02;
        E.Buttons := D.Buttons;
        D.N := 0;
        Inc(D.Reports);
        MouseFeed := True;
      end;

    mpMouseSys:
      begin
        if D.N = 0 then
        begin
          if (B and $F8) <> $80 then
          begin
            Inc(D.Resyncs);
            Exit;
          end;
          { Buttons are ACTIVE LOW here, which is the single most common
            thing to get backwards: a 0 bit means pressed.  Left is bit 2,
            middle bit 1, right bit 0. }
          D.Buttons := 0;
          if (B and $04) = 0 then D.Buttons := D.Buttons or $01;
          if (B and $01) = 0 then D.Buttons := D.Buttons or $02;
          if (B and $02) = 0 then D.Buttons := D.Buttons or $04;
        end;
        D.Buf[D.N] := B;
        Inc(D.N);
        Need := 5;
        if D.N < Need then Exit;

        { Two movement pairs per report: the mouse samples twice between
          sends, and the second pair is NOT a duplicate.  Summing them is
          what the protocol asks for; taking only the first halves the
          reported speed and reads as a sluggish mouse. }
        E.DX := Sign8(D.Buf[1]) + Sign8(D.Buf[3]);
        { Y is inverted relative to the screen: this protocol counts up as
          positive and a screen counts down. }
        E.DY := -(Sign8(D.Buf[2]) + Sign8(D.Buf[4]));
        E.Buttons := D.Buttons;
        D.N := 0;
        Inc(D.Reports);
        MouseFeed := True;
      end;
  end;
end;

end.
