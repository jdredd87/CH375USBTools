unit hidkey;
{ HID usage -> PC scancode and ASCII  --  CH375Keyboard, StevenC & Claude
  Public domain (the Unlicense).

  A USB keyboard does not send scancodes.  It sends HID usage numbers from
  the Keyboard/Keypad page, and it sends the whole set of keys currently
  held down, every time anything changes.  DOS wants the opposite: one
  scancode/ASCII pair per key event, in a ring buffer, with the shift state
  kept in a byte at 0040:0017.  This unit is the translation between them,
  and USBKBD.COM carries the same tables in assembly.

  THE THREE THINGS THAT ARE NOT OBVIOUS

  1. The report is a state, not an event.  Byte 0 is the modifier bitmap,
     byte 1 is reserved, bytes 2..7 are up to six usages held down right
     now, in no particular order.  A key that appears in this report and
     not the last one is a press; one in the last and not this one is a
     release.  Comparing position by position would report a press and a
     release every time the device reordered the list, which some do.

  2. Usage 01h in the key slots is not a key.  It is a rollover error: the
     keyboard is saying "more keys are down than I can report".  Treating
     it as a keypress produces a burst of garbage exactly when someone is
     typing fast, so the whole report is discarded when it appears.

  3. E0-prefixed scancodes.  The keys the original PC keyboard did not have
     -- the arrow cluster, the right-hand modifiers, the numeric-keypad
     divide -- are reported to DOS as a two-byte sequence, E0 then the
     code.  In the BIOS buffer that becomes a word with a zero ASCII byte
     and the scancode in the high half, which is what INT 16h hands back. }

{$MODE OBJFPC}{$H-}

interface

const
  { Modifier bits in byte 0 of the report. }
  MOD_LCTRL  = $01;
  MOD_LSHIFT = $02;
  MOD_LALT   = $04;
  MOD_LGUI   = $08;
  MOD_RCTRL  = $10;
  MOD_RSHIFT = $20;
  MOD_RALT   = $40;
  MOD_RGUI   = $80;

  { BIOS shift-flag bits at 0040:0017. }
  KF_RSHIFT  = $01;
  KF_LSHIFT  = $02;
  KF_CTRL    = $04;
  KF_ALT     = $08;
  KF_SCROLL  = $10;
  KF_NUM     = $20;
  KF_CAPS    = $40;
  KF_INSERT  = $80;

  { LED bits in the one-byte output report. }
  LED_NUM    = $01;
  LED_CAPS   = $02;
  LED_SCROLL = $04;

  USG_ROLLOVER = $01;

type
  TKeyEvent = record
    Scan:  Byte;        { PC scancode, set 1 }
    Ascii: Byte;        { 0 if the key has no character }
    Ext:   Boolean;     { needs the E0 prefix }
    Ok:    Boolean;     { False = this usage produces nothing }
  end;

{ The base scancode for a usage, ignoring shift state.  0 = no such key. }
function ScanOf(Usage: Byte): Byte;
function IsExtended(Usage: Byte): Boolean;

{ The full translation.  Shift, Ctrl, Alt and Caps come from the modifier
  byte and the lock state; NumLock affects the keypad only. }
function Translate(Usage, Modifiers: Byte; Caps, Num: Boolean): TKeyEvent;

function UsageName(U: Byte): ShortString;
function ModifierNames(M: Byte): ShortString;

{ The BIOS shift-flag byte a modifier bitmap and lock state correspond to. }
function BiosFlags(Modifiers: Byte; Caps, Num, Scroll: Boolean): Byte;

implementation

{ Usage -> scancode, and usage -> character.  These are case statements
  rather than the literal arrays they obviously want to be, for one dull
  but decisive reason: a literal array has to be counted by hand, and
  miscounting it by one silently shifts every key after the mistake -- the
  first draft of this unit did exactly that.  A case statement cannot be
  off by one.  USBKBD.COM does use a real table, because assembly gives no
  choice, and KBDTST exists partly to check the two agree. }

{ The character a printable key produces, unshifted and shifted.  Only the
  04h..38h run has one; every other usage is handled by the caller. }
function PlainChar(U: Byte): Char;
begin
  case U of
    $04..$1D: PlainChar := Chr(Ord('a') + U - $04);
    $1E..$26: PlainChar := Chr(Ord('1') + U - $1E);
    $27: PlainChar := '0';
    $28: PlainChar := #13;   $29: PlainChar := #27;
    $2A: PlainChar := #8;    $2B: PlainChar := #9;
    $2C: PlainChar := ' ';
    $2D: PlainChar := '-';  $2E: PlainChar := '=';
    $2F: PlainChar := '[';    $30: PlainChar := ']';
    $31: PlainChar := '\';    $32: PlainChar := '\';
    $33: PlainChar := ';';  $34: PlainChar := #39;
    $35: PlainChar := '`'; $36: PlainChar := ',';
    $37: PlainChar := '.';   $38: PlainChar := '/';
  else
    PlainChar := #0;
  end;
end;

function ShiftedChar(U: Byte): Char;
begin
  case U of
    $04..$1D: ShiftedChar := Chr(Ord('A') + U - $04);
    $1E: ShiftedChar := '!';   $1F: ShiftedChar := '@';
    $20: ShiftedChar := '#';   $21: ShiftedChar := '$';
    $22: ShiftedChar := '%';    $23: ShiftedChar := '^';
    $24: ShiftedChar := '&';    $25: ShiftedChar := '*';
    $26: ShiftedChar := '(';     $27: ShiftedChar := ')';
    $28: ShiftedChar := #13;     $29: ShiftedChar := #27;
    $2A: ShiftedChar := #8;      $2B: ShiftedChar := #9;
    $2C: ShiftedChar := ' ';
    $2D: ShiftedChar := '_';    $2E: ShiftedChar := '+';
    $2F: ShiftedChar := '{';    $30: ShiftedChar := '}';
    $31: ShiftedChar := '|';   $32: ShiftedChar := '|';
    $33: ShiftedChar := ':';  $34: ShiftedChar := '"';
    $35: ShiftedChar := '~';  $36: ShiftedChar := '<';
    $37: ShiftedChar := '>';     $38: ShiftedChar := '?';
  else
    ShiftedChar := #0;
  end;
end;

function ScanOf(Usage: Byte): Byte;
begin
  case Usage of
    $04: ScanOf := $1E;  $05: ScanOf := $30;  $06: ScanOf := $2E;
    $07: ScanOf := $20;  $08: ScanOf := $12;  $09: ScanOf := $21;
    $0A: ScanOf := $22;  $0B: ScanOf := $23;  $0C: ScanOf := $17;
    $0D: ScanOf := $24;  $0E: ScanOf := $25;  $0F: ScanOf := $26;
    $10: ScanOf := $32;  $11: ScanOf := $31;  $12: ScanOf := $18;
    $13: ScanOf := $19;  $14: ScanOf := $10;  $15: ScanOf := $13;
    $16: ScanOf := $1F;  $17: ScanOf := $14;  $18: ScanOf := $16;
    $19: ScanOf := $2F;  $1A: ScanOf := $11;  $1B: ScanOf := $2D;
    $1C: ScanOf := $15;  $1D: ScanOf := $2C;
    $1E: ScanOf := $02;  $1F: ScanOf := $03;  $20: ScanOf := $04;
    $21: ScanOf := $05;  $22: ScanOf := $06;  $23: ScanOf := $07;
    $24: ScanOf := $08;  $25: ScanOf := $09;  $26: ScanOf := $0A;
    $27: ScanOf := $0B;
    $28: ScanOf := $1C;
    $29: ScanOf := $01;
    $2A: ScanOf := $0E;
    $2B: ScanOf := $0F;
    $2C: ScanOf := $39;
    $2D: ScanOf := $0C;  $2E: ScanOf := $0D;
    $2F: ScanOf := $1A;  $30: ScanOf := $1B;
    $31: ScanOf := $2B;  $32: ScanOf := $2B;
    $33: ScanOf := $27;  $34: ScanOf := $28;  $35: ScanOf := $29;
    $36: ScanOf := $33;  $37: ScanOf := $34;  $38: ScanOf := $35;
    $39: ScanOf := $3A;
    $3A: ScanOf := $3B;  $3B: ScanOf := $3C;  $3C: ScanOf := $3D;
    $3D: ScanOf := $3E;  $3E: ScanOf := $3F;  $3F: ScanOf := $40;
    $40: ScanOf := $41;  $41: ScanOf := $42;  $42: ScanOf := $43;
    $43: ScanOf := $44;
    $44: ScanOf := $57;  $45: ScanOf := $58;
    $46: ScanOf := $37;
    $47: ScanOf := $46;
    $48: ScanOf := $45;
    $49: ScanOf := $52;  $4A: ScanOf := $47;  $4B: ScanOf := $49;
    $4C: ScanOf := $53;  $4D: ScanOf := $4F;  $4E: ScanOf := $51;
    $4F: ScanOf := $4D;  $50: ScanOf := $4B;  $51: ScanOf := $50;
    $52: ScanOf := $48;
    $53: ScanOf := $45;
    $54: ScanOf := $35;
    $55: ScanOf := $37;
    $56: ScanOf := $4A;
    $57: ScanOf := $4E;
    $58: ScanOf := $1C;
    $59: ScanOf := $4F;  $5A: ScanOf := $50;  $5B: ScanOf := $51;
    $5C: ScanOf := $4B;  $5D: ScanOf := $4C;  $5E: ScanOf := $4D;
    $5F: ScanOf := $47;  $60: ScanOf := $48;  $61: ScanOf := $49;
    $62: ScanOf := $52;
    $63: ScanOf := $53;
    $64: ScanOf := $56;
    $65: ScanOf := $5D;
    $E0: ScanOf := $1D;
    $E1: ScanOf := $2A;
    $E2: ScanOf := $38;
    $E3: ScanOf := $5B;
    $E4: ScanOf := $1D;
    $E5: ScanOf := $36;
    $E6: ScanOf := $38;
    $E7: ScanOf := $5C;
  else
    ScanOf := 0;
  end;
end;

function IsExtended(Usage: Byte): Boolean;
begin
  case Usage of
    $46,                              { PrintScreen }
    $49, $4A, $4B, $4C, $4D, $4E,     { Insert..PageDown }
    $4F, $50, $51, $52,               { arrows }
    $54,                              { keypad / }
    $58,                              { keypad Enter }
    $65,                              { Application }
    $E3, $E4, $E6, $E7:               { LGui, RCtrl, RAlt, RGui }
      IsExtended := True;
  else
    IsExtended := False;
  end;
end;

function Translate(Usage, Modifiers: Byte; Caps, Num: Boolean): TKeyEvent;
var
  Shift, Ctrl, Alt: Boolean;
  C: Char;
  R: TKeyEvent;
begin
  R.Scan := ScanOf(Usage);
  R.Ext  := IsExtended(Usage);
  R.Ascii := 0;
  R.Ok := R.Scan <> 0;
  if not R.Ok then begin Translate := R; Exit; end;

  Shift := (Modifiers and (MOD_LSHIFT or MOD_RSHIFT)) <> 0;
  Ctrl  := (Modifiers and (MOD_LCTRL  or MOD_RCTRL))  <> 0;
  Alt   := (Modifiers and (MOD_LALT   or MOD_RALT))   <> 0;

  { An extended key never carries a character; DOS identifies it by the
    scancode alone, with a zero ASCII byte. }
  if R.Ext then begin Translate := R; Exit; end;

  if (Usage >= $04) and (Usage <= $38) then
  begin
    if Shift then C := ShiftedChar(Usage) else C := PlainChar(Usage);

    { Caps Lock swaps the case of letters only -- not of the digit row.
      Getting that wrong turns Caps Lock into a second Shift, which is a
      surprisingly common bug and very annoying to type through. }
    if Caps and (Usage >= $04) and (Usage <= $1D) then
    begin
      if Shift then C := PlainChar(Usage) else C := ShiftedChar(Usage);
    end;

    { Ctrl-A..Ctrl-Z are 01..1A.  Everything else with Ctrl held has no
      character, and DOS reads the scancode instead. }
    if Ctrl then
    begin
      if (Usage >= $04) and (Usage <= $1D) then
        R.Ascii := Usage - $04 + 1
      else
        R.Ascii := 0;
    end
    else
      R.Ascii := Ord(C);
  end
  else if (Usage >= $59) and (Usage <= $63) then
  begin
    { The keypad produces digits only with NumLock on; with it off these
      are the arrow and navigation keys, which carry no character. }
    if Num and (not Shift) then
      case Usage of
        $59..$61: R.Ascii := Ord('1') + Usage - $59;
        $62:      R.Ascii := Ord('0');
        $63:      R.Ascii := Ord('.');
      end;
  end
  else
    case Usage of
      $54: R.Ascii := Ord('/');
      $55: R.Ascii := Ord('*');
      $56: R.Ascii := Ord('-');
      $57: R.Ascii := Ord('+');
      $58: R.Ascii := 13;
    end;

  { Alt suppresses the character everywhere: DOS expects Alt-key to arrive
    as a scancode with a zero ASCII byte, which is how menu accelerators
    and Alt-nnn entry are told apart from ordinary typing. }
  if Alt then R.Ascii := 0;

  Translate := R;
end;

function BiosFlags(Modifiers: Byte; Caps, Num, Scroll: Boolean): Byte;
var F: Byte;
begin
  F := 0;
  if (Modifiers and MOD_RSHIFT) <> 0 then F := F or KF_RSHIFT;
  if (Modifiers and MOD_LSHIFT) <> 0 then F := F or KF_LSHIFT;
  if (Modifiers and (MOD_LCTRL or MOD_RCTRL)) <> 0 then F := F or KF_CTRL;
  if (Modifiers and (MOD_LALT  or MOD_RALT))  <> 0 then F := F or KF_ALT;
  if Scroll then F := F or KF_SCROLL;
  if Num    then F := F or KF_NUM;
  if Caps   then F := F or KF_CAPS;
  BiosFlags := F;
end;

function ModifierNames(M: Byte): ShortString;
var S: ShortString;
begin
  S := '';
  if (M and MOD_LCTRL)  <> 0 then S := S + 'LCtrl ';
  if (M and MOD_LSHIFT) <> 0 then S := S + 'LShift ';
  if (M and MOD_LALT)   <> 0 then S := S + 'LAlt ';
  if (M and MOD_LGUI)   <> 0 then S := S + 'LGui ';
  if (M and MOD_RCTRL)  <> 0 then S := S + 'RCtrl ';
  if (M and MOD_RSHIFT) <> 0 then S := S + 'RShift ';
  if (M and MOD_RALT)   <> 0 then S := S + 'RAlt ';
  if (M and MOD_RGUI)   <> 0 then S := S + 'RGui ';
  if S = '' then S := '-';
  ModifierNames := S;
end;

function Dec1(V: LongInt): ShortString;
var S: ShortString;
begin
  Str(V, S); Dec1 := S;
end;

function UsageName(U: Byte): ShortString;
begin
  UsageName := '';
  if (U >= $04) and (U <= $1D) then UsageName := Chr(Ord('A') + U - $04)
  else if (U >= $1E) and (U <= $26) then UsageName := Chr(Ord('1') + U - $1E)
  else if (U >= $3A) and (U <= $45) then UsageName := 'F' + Dec1(U - $39)
  else if (U >= $59) and (U <= $61) then UsageName := 'KP' + Dec1(U - $58)
  else case U of
    $01: UsageName := 'ROLLOVER';
    $27: UsageName := '0';
    $28: UsageName := 'Enter';    $29: UsageName := 'Esc';
    $2A: UsageName := 'BkSp';     $2B: UsageName := 'Tab';
    $2C: UsageName := 'Space';    $2D: UsageName := '-';
    $2E: UsageName := '=';        $2F: UsageName := '[';
    $30: UsageName := ']';        $31: UsageName := '\';
    $32: UsageName := '#';        $33: UsageName := ';';
    $34: UsageName := '''';       $35: UsageName := '`';
    $36: UsageName := ',';        $37: UsageName := '.';
    $38: UsageName := '/';        $39: UsageName := 'CapsLk';
    $46: UsageName := 'PrtSc';    $47: UsageName := 'ScrLk';
    $48: UsageName := 'Pause';    $49: UsageName := 'Ins';
    $4A: UsageName := 'Home';     $4B: UsageName := 'PgUp';
    $4C: UsageName := 'Del';      $4D: UsageName := 'End';
    $4E: UsageName := 'PgDn';     $4F: UsageName := 'Right';
    $50: UsageName := 'Left';     $51: UsageName := 'Down';
    $52: UsageName := 'Up';       $53: UsageName := 'NumLk';
    $54: UsageName := 'KP/';      $55: UsageName := 'KP*';
    $56: UsageName := 'KP-';      $57: UsageName := 'KP+';
    $58: UsageName := 'KPEnter';  $62: UsageName := 'KP0';
    $63: UsageName := 'KP.';      $64: UsageName := 'nonUS\';
    $65: UsageName := 'App';
    $E0: UsageName := 'LCtrl';    $E1: UsageName := 'LShift';
    $E2: UsageName := 'LAlt';     $E3: UsageName := 'LGui';
    $E4: UsageName := 'RCtrl';    $E5: UsageName := 'RShift';
    $E6: UsageName := 'RAlt';     $E7: UsageName := 'RGui';
  else
    if U <> 0 then UsageName := '?' + Dec1(U);
  end;
end;

end.
