program hidrep;
{ HIDREP -- fetch and decode a HID report descriptor over a CH375.
  CH375USBTOOLS, StevenC & Claude.  Public domain (the Unlicense).

  USBINFO prints the report descriptor as bytes.  This one reads it as what
  it is -- a little stack program describing a bit layout -- and prints both
  the item stream and, at the end, the field map each report actually has.
  That map is the thing you need in order to write a driver: which byte,
  which bit, how many of them, and what the device calls it.

    HIDREP [/P=260] [/I=n] [/X] [/L=n] [/F=hh,hh,...]

      /P=hex   I/O base, default 260
      /I=n     interface number, default 0
      /X       also dump the raw bytes
      /L=n     ask for n bytes rather than the length the HID descriptor
               claims.  For a device that lies about it
      /F=list  decode this comma-separated hex byte list instead of asking
               a device at all.  No CH375 needed -- useful for a descriptor
               captured elsewhere, and it is how the decoder gets tested
               without hardware

  Exit codes: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,
              4 attached but silent, 5 no HID descriptor on that interface,
              6 the report descriptor would not read }

{$MODE OBJFPC}{$H-}

uses ch375, chtool;

const
  VER = '1.0.0';

const
  MAXFIELD = 96;

type
  TField = record
    RepId:   Byte;
    Kind:    Byte;        { 0 input, 1 output, 2 feature }
    BitOfs:  Word;
    BitSize: Byte;
    Count:   Byte;
    Flags:   Word;
    Page:    Word;
    UsgLo:   Word;        { first usage, or usage minimum }
    UsgHi:   Word;        { usage maximum, or the same as UsgLo }
    LogMin:  LongInt;
    LogMax:  LongInt;
  end;

var
  Cfg:    array[0..1023] of Byte;
  Rpt:    array[0..1023] of Byte;
  RLen:   Word = 0;
  IfWant: Byte = 0;
  RawToo: Boolean = False;
  ForceLen: Word = 0;
  FromFile: Boolean = False;

  Fields: array[0..MAXFIELD - 1] of TField;
  NField: Integer = 0;

  { parser state }
  GPage, GRepSize, GRepCount, GRepId: Word;
  GLogMin, GLogMax: LongInt;
  Locals: array[0..31] of Word;      { usages collected for the next main item }
  NLocal: Integer;
  UsgMin, UsgMax: Word;
  HaveRange: Boolean;
  Depth: Integer;
  { Input, Output and Feature are three separate reports that happen to be
    described by one item stream, so each needs its own bit cursor.  Share
    one and a keyboard's LED output byte lands in the middle of the key
    array, which is wrong in a way that looks plausible. }
  BitPos: array[0..7, 0..2] of Word;
  RepIds: array[0..7] of Byte;
  NRepId: Integer;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

function Pad(const S: ShortString; N: Integer): ShortString;
var R: ShortString;
begin
  R := S;
  while Length(R) < N do R := R + ' ';
  Pad := R;
end;

{ ----------------------------------------------------------------------
  Names.  Only the pages a DOS machine is plausibly going to meet are
  spelled out; the rest print as numbers, which beats a wrong guess.
  ---------------------------------------------------------------------- }

function PageName(P: Word): ShortString;
begin
  case P of
    $01: PageName := 'Generic Desktop';
    $02: PageName := 'Simulation';
    $03: PageName := 'VR';
    $04: PageName := 'Sport';
    $05: PageName := 'Game';
    $06: PageName := 'Generic Device';
    $07: PageName := 'Keyboard/Keypad';
    $08: PageName := 'LED';
    $09: PageName := 'Button';
    $0A: PageName := 'Ordinal';
    $0B: PageName := 'Telephony';
    $0C: PageName := 'Consumer';
    $0D: PageName := 'Digitizer';
    $0F: PageName := 'Physical Interface';
    $10: PageName := 'Unicode';
    $14: PageName := 'Alphanumeric Display';
    $40: PageName := 'Medical';
  else
    if P >= $FF00 then PageName := 'Vendor ' + Hex4(P)
                  else PageName := 'page ' + Hex4(P);
  end;
end;

function DesktopUsage(U: Word): ShortString;
begin
  case U of
    $01: DesktopUsage := 'Pointer';
    $02: DesktopUsage := 'Mouse';
    $04: DesktopUsage := 'Joystick';
    $05: DesktopUsage := 'Gamepad';
    $06: DesktopUsage := 'Keyboard';
    $07: DesktopUsage := 'Keypad';
    $08: DesktopUsage := 'Multi-axis Controller';
    $30: DesktopUsage := 'X';
    $31: DesktopUsage := 'Y';
    $32: DesktopUsage := 'Z';
    $33: DesktopUsage := 'Rx';
    $34: DesktopUsage := 'Ry';
    $35: DesktopUsage := 'Rz';
    $36: DesktopUsage := 'Slider';
    $37: DesktopUsage := 'Dial';
    $38: DesktopUsage := 'Wheel';
    $39: DesktopUsage := 'Hat Switch';
    $3A: DesktopUsage := 'Counted Buffer';
    $80: DesktopUsage := 'System Control';
    $81: DesktopUsage := 'System Power Down';
    $82: DesktopUsage := 'System Sleep';
    $83: DesktopUsage := 'System Wake Up';
    $85: DesktopUsage := 'System Menu';
  else
    DesktopUsage := '';
  end;
end;

function LedUsage(U: Word): ShortString;
begin
  case U of
    $01: LedUsage := 'Num Lock';
    $02: LedUsage := 'Caps Lock';
    $03: LedUsage := 'Scroll Lock';
    $04: LedUsage := 'Compose';
    $05: LedUsage := 'Kana';
    $06: LedUsage := 'Power';
    $07: LedUsage := 'Shift';
    $09: LedUsage := 'Mute';
  else
    LedUsage := '';
  end;
end;

function ConsumerUsage(U: Word): ShortString;
begin
  case U of
    $01:  ConsumerUsage := 'Consumer Control';
    $30:  ConsumerUsage := 'Power';
    $B5:  ConsumerUsage := 'Next Track';
    $B6:  ConsumerUsage := 'Previous Track';
    $B7:  ConsumerUsage := 'Stop';
    $CD:  ConsumerUsage := 'Play/Pause';
    $E2:  ConsumerUsage := 'Mute';
    $E9:  ConsumerUsage := 'Volume Up';
    $EA:  ConsumerUsage := 'Volume Down';
    $183: ConsumerUsage := 'AL Consumer Control Config';
    $18A: ConsumerUsage := 'AL Email Reader';
    $192: ConsumerUsage := 'AL Calculator';
    $194: ConsumerUsage := 'AL Local Browser';
    $221: ConsumerUsage := 'AC Search';
    $223: ConsumerUsage := 'AC Home';
    $224: ConsumerUsage := 'AC Back';
    $225: ConsumerUsage := 'AC Forward';
    $226: ConsumerUsage := 'AC Stop';
    $227: ConsumerUsage := 'AC Refresh';
    $22A: ConsumerUsage := 'AC Bookmarks';
  else
    ConsumerUsage := '';
  end;
end;

{ The keyboard page is dense and regular, so ranges beat a 200-entry table. }
function KeyUsage(U: Word): ShortString;
begin
  KeyUsage := '';
  if (U >= $04) and (U <= $1D) then
    KeyUsage := Chr(Ord('A') + U - $04)
  else if (U >= $1E) and (U <= $26) then
    KeyUsage := Chr(Ord('1') + U - $1E)
  else if (U >= $3A) and (U <= $45) then
    KeyUsage := 'F' + Dec1(U - $39)
  else
    case U of
      $00: KeyUsage := 'no event';
      $01: KeyUsage := 'rollover error';
      $03: KeyUsage := 'undefined error';
      $27: KeyUsage := '0';
      $28: KeyUsage := 'Enter';
      $29: KeyUsage := 'Escape';
      $2A: KeyUsage := 'Backspace';
      $2B: KeyUsage := 'Tab';
      $2C: KeyUsage := 'Space';
      $2D: KeyUsage := '- _';
      $2E: KeyUsage := '= +';
      $2F: KeyUsage := '[ {';
      $30: KeyUsage := '] }';
      $31: KeyUsage := '\ |';
      $33: KeyUsage := '; :';
      $34: KeyUsage := 'quote';
      $35: KeyUsage := 'grave';
      $36: KeyUsage := ', <';
      $37: KeyUsage := '. >';
      $38: KeyUsage := '/ ?';
      $39: KeyUsage := 'Caps Lock';
      $46: KeyUsage := 'PrintScreen';
      $47: KeyUsage := 'Scroll Lock';
      $48: KeyUsage := 'Pause';
      $49: KeyUsage := 'Insert';
      $4A: KeyUsage := 'Home';
      $4B: KeyUsage := 'PageUp';
      $4C: KeyUsage := 'Delete';
      $4D: KeyUsage := 'End';
      $4E: KeyUsage := 'PageDown';
      $4F: KeyUsage := 'Right';
      $50: KeyUsage := 'Left';
      $51: KeyUsage := 'Down';
      $52: KeyUsage := 'Up';
      $53: KeyUsage := 'Num Lock';
      $E0: KeyUsage := 'LeftCtrl';
      $E1: KeyUsage := 'LeftShift';
      $E2: KeyUsage := 'LeftAlt';
      $E3: KeyUsage := 'LeftGUI';
      $E4: KeyUsage := 'RightCtrl';
      $E5: KeyUsage := 'RightShift';
      $E6: KeyUsage := 'RightAlt';
      $E7: KeyUsage := 'RightGUI';
    end;
end;

function UsageName(P, U: Word): ShortString;
var S: ShortString;
begin
  S := '';
  case P of
    $01: S := DesktopUsage(U);
    $07: S := KeyUsage(U);
    $08: S := LedUsage(U);
    $09: if U = 0 then S := 'no button' else S := 'Button ' + Dec1(U);
    $0C: S := ConsumerUsage(U);
  end;
  if S = '' then UsageName := Hex4(U) else UsageName := S;
end;

function CollName(C: Byte): ShortString;
begin
  case C of
    0: CollName := 'Physical';
    1: CollName := 'Application';
    2: CollName := 'Logical';
    3: CollName := 'Report';
    4: CollName := 'Named Array';
    5: CollName := 'Usage Switch';
    6: CollName := 'Usage Modifier';
  else
    CollName := 'vendor ' + Hex2(C);
  end;
end;

{ The Input/Output/Feature data bits, in the order the spec lists them. }
function MainFlags(F: Word; IsOutput: Boolean): ShortString;
var S: ShortString;
begin
  S := '';
  if (F and $01) <> 0 then S := S + 'Constant '   else S := S + 'Data ';
  if (F and $02) <> 0 then S := S + 'Variable '   else S := S + 'Array ';
  if (F and $04) <> 0 then S := S + 'Relative '   else S := S + 'Absolute ';
  if (F and $08) <> 0 then S := S + 'Wrap ';
  if (F and $10) <> 0 then S := S + 'NonLinear ';
  if (F and $20) <> 0 then S := S + 'NoPreferred ';
  if (F and $40) <> 0 then S := S + 'NullState ';
  if IsOutput and ((F and $80) <> 0) then S := S + 'Volatile ';
  if (F and $100) <> 0 then S := S + 'BufferedBytes ';
  MainFlags := S;
end;

{ ----------------------------------------------------------------------
  Report-id bookkeeping.  A descriptor with no Report ID item has one
  nameless report; one with them has a separate bit cursor per id.
  ---------------------------------------------------------------------- }

function IdSlot(Id: Byte): Integer;
var I: Integer;
begin
  for I := 0 to NRepId - 1 do
    if RepIds[I] = Id then begin IdSlot := I; Exit; end;
  if NRepId >= 8 then begin IdSlot := 0; Exit; end;
  RepIds[NRepId] := Id;
  BitPos[NRepId, 0] := 0; BitPos[NRepId, 1] := 0; BitPos[NRepId, 2] := 0;
  IdSlot := NRepId; Inc(NRepId);
end;

procedure AddField(Kind: Byte; Flags: Word);
var
  Slot: Integer;
  F: Integer;
begin
  Slot := IdSlot(Byte(GRepId));
  if NField < MAXFIELD then
  begin
    F := NField; Inc(NField);
    Fields[F].RepId   := Byte(GRepId);
    Fields[F].Kind    := Kind;
    Fields[F].BitOfs  := BitPos[Slot, Kind];
    Fields[F].BitSize := Byte(GRepSize);
    Fields[F].Count   := Byte(GRepCount);
    Fields[F].Flags   := Flags;
    Fields[F].Page    := GPage;
    Fields[F].LogMin  := GLogMin;
    Fields[F].LogMax  := GLogMax;
    if HaveRange then
    begin
      Fields[F].UsgLo := UsgMin; Fields[F].UsgHi := UsgMax;
    end
    else if NLocal > 0 then
    begin
      Fields[F].UsgLo := Locals[0];
      Fields[F].UsgHi := Locals[NLocal - 1];
    end
    else
    begin
      Fields[F].UsgLo := 0; Fields[F].UsgHi := 0;
    end;
  end;
  Inc(BitPos[Slot, Kind], GRepSize * GRepCount);
  { Locals are consumed by the main item that follows them, always. }
  NLocal := 0; HaveRange := False;
end;

{ ----------------------------------------------------------------------
  The item stream
  ---------------------------------------------------------------------- }

procedure Decode(var B: array of Byte; Len: Word);
var
  P: Word;
  Tag, Typ, Sz: Byte;
  Bytes: Byte;
  U: LongInt;
  SU: LongInt;
  I: Integer;
  Ind: ShortString;
  Head: ShortString;
begin
  GPage := 0; GRepSize := 0; GRepCount := 0; GRepId := 0;
  GLogMin := 0; GLogMax := 0;
  NLocal := 0; HaveRange := False; Depth := 0;
  NField := 0; NRepId := 0;
  UsgMin := 0; UsgMax := 0;

  P := 0;
  while P < Len do
  begin
    Tag := B[P] shr 4;
    Typ := (B[P] shr 2) and 3;
    Sz  := B[P] and 3;
    Bytes := Sz;
    if Sz = 3 then Bytes := 4;

    { A long item -- tag 1111, type 11 -- carries its own length.  Nothing
      in the wild uses one, but skipping it correctly costs three lines and
      stops the walk derailing if one turns up. }
    if (Tag = $F) and (Typ = 3) then
    begin
      if P + 1 >= Len then Break;
      WriteLn('  long item, ', B[P + 1], ' bytes, tag ', Hex2(B[P + 2]));
      Inc(P, 3 + B[P + 1]);
      Continue;
    end;

    if P + 1 + Bytes > Len then
    begin
      WriteLn('  -- truncated item at offset ', P);
      Break;
    end;

    U := 0;
    for I := Bytes - 1 downto 0 do U := (U shl 8) or B[P + 1 + I];
    { Logical minimum and friends are signed; usages and counts are not.
      Sign-extending everything would turn usage FFh into -1. }
    SU := U;
    if (Bytes = 1) and (U >= $80) then SU := U - $100
    else if (Bytes = 2) and (U >= $8000) then SU := U - $10000;

    Ind := '';
    for I := 1 to Depth do Ind := Ind + '  ';
    Head := '  ' + Pad(Hex4(P), 6) + Pad(Hex2(B[P]), 4) + Ind;

    case Typ of
      0: { ---- Main ---- }
        case Tag of
          8: begin
               WriteLn(Head, 'Input        ', MainFlags(Word(U), False));
               AddField(0, Word(U));
             end;
          9: begin
               WriteLn(Head, 'Output       ', MainFlags(Word(U), True));
               AddField(1, Word(U));
             end;
          $B: begin
               WriteLn(Head, 'Feature      ', MainFlags(Word(U), True));
               AddField(2, Word(U));
             end;
          $A: begin
               WriteLn(Head, 'Collection   ', CollName(Byte(U)));
               Inc(Depth);
               NLocal := 0; HaveRange := False;
             end;
          $C: begin
               if Depth > 0 then Dec(Depth);
               Ind := '';
               for I := 1 to Depth do Ind := Ind + '  ';
               WriteLn('  ', Pad(Hex4(P), 6), Pad(Hex2(B[P]), 4), Ind,
                       'End Collection');
               NLocal := 0; HaveRange := False;
             end;
        else
          WriteLn(Head, 'main tag ', Hex1(Tag));
        end;

      1: { ---- Global ---- }
        case Tag of
          0: begin GPage := Word(U);
               WriteLn(Head, 'Usage Page   ', PageName(GPage)); end;
          1: begin GLogMin := SU;
               WriteLn(Head, 'Logical Min  ', SU); end;
          2: begin
               { Logical maximum is signed only if the minimum was.  A
                 keyboard's "Logical Maximum FF" means 255, not -1, and a
                 blanket sign-extend gets that wrong every time. }
               if GLogMin < 0 then GLogMax := SU else GLogMax := U;
               WriteLn(Head, 'Logical Max  ', GLogMax); end;
          3: WriteLn(Head, 'Physical Min ', SU);
          4: WriteLn(Head, 'Physical Max ', SU);
          5: WriteLn(Head, 'Unit Exponent ', SU);
          6: WriteLn(Head, 'Unit         ', Hex4(Word(U)));
          7: begin GRepSize := Word(U);
               WriteLn(Head, 'Report Size  ', U, ' bits'); end;
          8: begin GRepId := Word(U);
               WriteLn(Head, 'Report ID    ', U); end;
          9: begin GRepCount := Word(U);
               WriteLn(Head, 'Report Count ', U); end;
          $A: WriteLn(Head, 'Push');
          $B: WriteLn(Head, 'Pop');
        else
          WriteLn(Head, 'global tag ', Hex1(Tag));
        end;

      2: { ---- Local ---- }
        case Tag of
          0: begin
               { A 4-byte usage carries its page in the top half. }
               if Bytes = 4 then
                 WriteLn(Head, 'Usage        ',
                         PageName(Word(U shr 16)), ' ',
                         UsageName(Word(U shr 16), Word(U)))
               else
                 WriteLn(Head, 'Usage        ', UsageName(GPage, Word(U)));
               if NLocal < 32 then begin Locals[NLocal] := Word(U); Inc(NLocal); end;
             end;
          1: begin UsgMin := Word(U); HaveRange := True;
               WriteLn(Head, 'Usage Min    ', UsageName(GPage, Word(U))); end;
          2: begin UsgMax := Word(U); HaveRange := True;
               WriteLn(Head, 'Usage Max    ', UsageName(GPage, Word(U))); end;
          3: WriteLn(Head, 'Designator Index ', U);
          4: WriteLn(Head, 'Designator Min ', U);
          5: WriteLn(Head, 'Designator Max ', U);
          7: WriteLn(Head, 'String Index ', U);
          8: WriteLn(Head, 'String Min   ', U);
          9: WriteLn(Head, 'String Max   ', U);
          $A: WriteLn(Head, 'Delimiter    ', U);
        else
          WriteLn(Head, 'local tag ', Hex1(Tag));
        end;
    else
      WriteLn(Head, 'reserved');
    end;

    Inc(P, 1 + Bytes);
  end;
end;

{ ----------------------------------------------------------------------
  The field map.  This is the part you copy into a driver.
  ---------------------------------------------------------------------- }

procedure ShowMap;
var
  I, K, J: Integer;
  Kind: ShortString;
  S: ShortString;
  Bits: Word;
  AnyId: Boolean;
begin
  if NField = 0 then Exit;
  AnyId := (NRepId > 1) or ((NRepId = 1) and (RepIds[0] <> 0));

  WriteLn;
  WriteLn('REPORT FIELD MAP');
  WriteLn('----------------------------------------------------------------');
  if AnyId then
    WriteLn('  This descriptor uses report IDs, so every report on the wire')
  else
    WriteLn('  No report IDs, so the report starts at bit 0 of byte 0.');
  if AnyId then
    WriteLn('  begins with the ID byte and the offsets below follow it.');
  WriteLn;
  WriteLn('  ', Pad('id', 4), Pad('kind', 9), Pad('byte.bit', 10),
          Pad('size', 6), Pad('count', 7), 'usage');
  WriteLn('  ', Pad('--', 4), Pad('----', 9), Pad('--------', 10),
          Pad('----', 6), Pad('-----', 7), '-----');

  for I := 0 to NField - 1 do
  begin
    case Fields[I].Kind of
      0: Kind := 'Input';
      1: Kind := 'Output';
    else
      Kind := 'Feature';
    end;
    S := '  ' + Pad(Dec1(Fields[I].RepId), 4) + Pad(Kind, 9);
    S := S + Pad(Dec1(Fields[I].BitOfs div 8) + '.' +
                 Dec1(Fields[I].BitOfs mod 8), 10);
    S := S + Pad(Dec1(Fields[I].BitSize), 6);
    S := S + Pad(Dec1(Fields[I].Count), 7);
    if (Fields[I].Flags and $01) <> 0 then
      S := S + '(padding)'
    else if Fields[I].UsgLo = Fields[I].UsgHi then
      S := S + UsageName(Fields[I].Page, Fields[I].UsgLo)
    else
      S := S + UsageName(Fields[I].Page, Fields[I].UsgLo) + ' .. ' +
               UsageName(Fields[I].Page, Fields[I].UsgHi);
    WriteLn(S);
  end;

  WriteLn;
  for K := 0 to NRepId - 1 do
    for J := 0 to 2 do
    begin
      Bits := BitPos[K, J];
      if Bits = 0 then Continue;
      case J of
        0: Kind := 'input';
        1: Kind := 'output';
      else
        Kind := 'feature';
      end;
      S := '  ' + Pad(Kind, 8) + 'report';
      if AnyId then S := S + ' id ' + Dec1(RepIds[K]);
      S := S + ': ' + Dec1((Bits + 7) div 8) + ' bytes';
      if AnyId then S := S + ' plus the leading ID byte';
      WriteLn(S, '  (', Bits, ' bits)');
    end;
end;

{ ----------------------------------------------------------------------
  Finding the HID descriptor, so we know how long the report descriptor is
  ---------------------------------------------------------------------- }

function FindReportLen(var B: array of Byte; Len: Word; Want: Byte): Word;
var
  P, L: Word;
  T, CurIf, I, N: Byte;
begin
  FindReportLen := 0;
  P := 0; CurIf := $FF;
  while P + 2 <= Len do
  begin
    L := B[P]; T := B[P + 1];
    if (L < 2) or (P + L > Len) then Break;
    if (T = DT_INTERFACE) and (L >= 9) then CurIf := B[P + 2];
    if (T = DT_HID) and (L >= 9) and (CurIf = Want) then
    begin
      N := B[P + 5];
      for I := 0 to N - 1 do
        if P + 7 + I * 3 + 1 <= Len then
          if B[P + 6 + I * 3] = DT_HID_REPORT then
          begin
            FindReportLen := B[P + 7 + I * 3] or
                             (Word(B[P + 8 + I * 3]) shl 8);
            Exit;
          end;
    end;
    Inc(P, L);
  end;
end;

procedure ParseHexList(const S: ShortString);
var
  I: Integer;
  T: ShortString;
  V: LongInt;
  Code: Integer;
begin
  RLen := 0; T := '';
  for I := 1 to Length(S) + 1 do
  begin
    if (I > Length(S)) or (S[I] = ',') or (S[I] = ' ') then
    begin
      if T <> '' then
      begin
        Val('$' + T, V, Code);
        if (Code = 0) and (RLen < SizeOf(Rpt)) then
        begin
          Rpt[RLen] := Byte(V); Inc(RLen);
        end;
        T := '';
      end;
    end
    else
      T := T + S[I];
  end;
  FromFile := True;
end;

procedure ParseArgs;
var I, Code: Integer; A, K: ShortString; V: LongInt;
begin
  for I := 1 to ParamCount do
  begin
    A := ParamStr(I);
    for Code := 1 to Length(A) do A[Code] := UpCase(A[Code]);
    if (A = '/X') or (A = '-X') then begin RawToo := True; Continue; end;
    if Length(A) < 4 then Continue;
    K := Copy(A, 1, 3); A := Copy(A, 4, 250);
    if      K = '/P=' then begin Val('$' + A, V, Code); if Code = 0 then Base := Word(V); end
    else if K = '/I=' then begin Val(A, V, Code); if Code = 0 then IfWant := Byte(V); end
    else if K = '/L=' then begin Val(A, V, Code); if Code = 0 then ForceLen := Word(V); end
    else if K = '/F=' then ParseHexList(A);
  end;
end;

procedure Usage;
begin
  Banner('HIDREP', VER, 'fetch and decode a HID report descriptor');
  WriteLn;
  WriteLn('  HIDREP [/P=260] [/I=n] [/X] [/L=n] [/F=hh,hh,...]');
  WriteLn;
  HelpBaseLine;
  WriteLn('  /I=n     interface number, default 0');
  WriteLn('  /X       also dump the raw bytes');
  WriteLn('  /L=n     ask for n bytes rather than the length the HID');
  WriteLn('           descriptor claims.  For a device that lies about it');
  WriteLn('  /F=list  decode this comma-separated hex byte list instead of');
  WriteLn('           asking a device at all.  No CH375 needed -- for a');
  WriteLn('           descriptor captured elsewhere, and it is how the');
  WriteLn('           decoder gets tested without hardware');
  WriteLn('  /?       this screen');
  WriteLn;
  WriteLn('USBINFO prints a report descriptor as bytes.  This reads it as');
  WriteLn('what it is -- a little stack program describing a bit layout --');
  WriteLn('and ends with the field map each report actually has: which');
  WriteLn('byte, which bit, how many, and what the device calls it.  That');
  WriteLn('map is the thing you need in order to write a driver.');
  WriteLn;
  WriteLn('Exit: 0 ok, 1 no chip, 2 chip too old, 3 nothing attached,');
  WriteLn('      4 attached but silent, 5 no HID descriptor on that');
  WriteLn('      interface, 6 the report descriptor would not read');
  HelpTail;
end;

var
  Rc, St: Integer;
  Got, Want, Total: Word;
  QLen: Byte;

begin
  if HelpWanted then begin Usage; Halt(0); end;
  ParseArgs;
  Banner('HIDREP', VER, 'HID report descriptor decoder');

  if FromFile then
  begin
    WriteLn('decoding ', RLen, ' supplied bytes; no device involved');
    WriteLn;
    if RawToo then begin HexDump(Rpt, RLen, '  '); WriteLn; end;
    Decode(Rpt, RLen);
    ShowMap;
    Halt(0);
  end;

  Rc := BusUp;
  if Rc <> BU_OK then
  begin
    WriteLn(BusUpReason(Rc));
    if Rc = BU_NO_ANSWER then WhyNoAnswer;
    Halt(Rc);
  end;

  { The configuration descriptor is where the report length is written
    down.  Fetch it in full -- the chip shortcut caps at its own buffer. }
  St := GetDescr(DT_CONFIG, 0, 0, Cfg, 9, Got);
  Total := 9;
  if Got >= 4 then Total := Cfg[2] or (Word(Cfg[3]) shl 8);
  if Total > SizeOf(Cfg) then Total := SizeOf(Cfg);
  St := GetDescr(DT_CONFIG, 0, 0, Cfg, Total, Got);
  if Got < 9 then
  begin
    St := GetDescrQuick(DT_CONFIG, Cfg, SizeOf(Cfg), QLen);
    Got := QLen;
  end;

  Want := FindReportLen(Cfg, Got, IfWant);
  if ForceLen > 0 then Want := ForceLen;
  if Want = 0 then
  begin
    WriteLn('Interface ', IfWant, ' has no HID report descriptor.');
    WriteLn('USBINFO lists the interfaces this device has.');
    Halt(5);
  end;

  WriteLn('device ', Hex4(DevDesc[8] or (Word(DevDesc[9]) shl 8)), ':',
          Hex4(DevDesc[10] or (Word(DevDesc[11]) shl 8)),
          '  interface ', IfWant, '  report descriptor ', Want, ' bytes');
  WriteLn;

  if Want > SizeOf(Rpt) then Want := SizeOf(Rpt);
  St := CtrlIn($81, REQ_GET_DESCR, Word(DT_HID_REPORT) shl 8, IfWant,
               Want, Rpt, SizeOf(Rpt), Got);
  if Got = 0 then
  begin
    WriteLn('The report descriptor would not read (', StatusName(St), ').');
    Halt(6);
  end;
  if Got < Want then
    WriteLn('  -- short: ', Got, ' of ', Want, ' bytes; decoding what came');

  if RawToo then begin HexDump(Rpt, Got, '  '); WriteLn; end;
  Decode(Rpt, Got);
  ShowMap;
  Halt(0);
end.
