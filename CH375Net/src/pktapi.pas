{ ==========================================================================
  PktApi -- a Crynwr packet driver client that talks to the vector YOU name.

  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
  Public domain (the Unlicense); see LICENSE.

  Why this exists rather than reusing something that already works: every
  other client on this machine finds its driver by scanning 60h..80h and
  taking the first one that answers.  On a machine with two adapters that
  is always the wrong one -- the NE2000 at 60h that the box is administered
  over, never the CH375 adapter under test.  Working around it by pointing
  a config file somewhere else for the duration of a test, and pointing it
  back afterwards, is how you eventually forget to point it back.

  So: the vector is an argument, there is no scan, and there is no config
  file.  A tool built on this cannot reach the wrong adapter by accident,
  which means mTCP can stay pinned to the NE2000 permanently and nothing
  ever has to be bounced between the two.

  This deliberately stops at frames.  It is ARP and raw Ethernet, enough to
  prove a driver transmits and receives; it is not a TCP stack and is not
  trying to become one.
  ========================================================================== }
unit PktApi;

interface

const
  PKT_MAXFRAME = 1514;

type
  TMac   = array[0..5] of Byte;
  TIp    = array[0..3] of Byte;
  TFrame = array[0..PKT_MAXFRAME - 1] of Byte;

var
  PktErr     : ShortString;
  PktMyMac   : TMac;
  PktRxCount : Word;      { frames the upcall accepted }
  PktRxDrop  : Word;      { refused: busy, or too big }
  PktTxOk    : Word;
  PktTxFail  : Word;      { driver said carry -- nothing went out }

{ Signature check only -- does not open anything. }
function PktSigAt(Vec: Byte): Boolean;

{ access_type for one ethertype on one vector.  0FFFFh in EtherType asks
  for every protocol, which is what a promiscuous look at the wire wants. }
function PktOpen(Vec: Byte; EtherType: Word): Boolean;
procedure PktClose;

function PktSend(const Buf; Len: Word): Boolean;

{ Non-blocking.  True and Got>0 when a frame was waiting. }
function PktPoll(var Buf; Max: Word; var Got: Word): Boolean;

function MacStr(const M: TMac): ShortString;
function IpStr(const I: TIp): ShortString;
function ParseIp(const S: ShortString; var I: TIp): Boolean;
function Ticks: LongInt;

implementation

{ The shared block the interrupt-time receiver writes into.  Laid out by
  hand because PktRecv addresses it by byte offset:
      +0  Busy       0 = free, 1 = a frame is waiting
      +2  Len
      +4  Count
      +6  Drops
      +8  Data
  Anything moved here must be moved in PktRecv too. }
type
  TShared = packed record
    Busy  : Word;
    Len   : Word;
    Count : Word;
    Drops : Word;
    Data  : TFrame;
  end;

var
  Shared  : TShared;
  Filt    : packed array[0..1] of Byte;
  Handler : packed record O, S: Word; end;
  Handle  : Word;
  CarryB  : Byte;
  ErrDH   : Byte;
  IsOpen  : Boolean;
  AllProt : Boolean;

function Ticks: LongInt;
begin
  Ticks := MemL[$0040 : $006C];
end;

{ --------------------------------------------------------------------------
  The interrupt-time receiver.

  Modelled on the one in DOSBridge's net.pas, which is verified on hardware,
  and for the same reason: the first bytes are hand-assembled db/dw because
  two words are patched at run time and they have to sit at offsets this
  code can know.  +7 is our data segment, +12 is Ofs(Shared).  Change the
  prologue and those offsets stop being knowable from Pascal -- check them
  against the linked binary before running it.

  The driver calls twice per frame: AX=0 asks for somewhere to put CX bytes
  (answer ES:DI, or 0:0 to refuse it), AX=1 says the copy is done.  Busy is
  what makes the second call safe to read from the main loop -- while it is
  set we refuse and count a drop rather than overwrite a frame that is
  still being looked at.
  -------------------------------------------------------------------------- }
procedure PktRecv; assembler; nostackframe;
asm
  db  01Eh              { push ds                       +0 }
  db  053h              { push bx                       +1 }
  db  051h              { push cx                       +2 }
  db  056h              { push si                       +3 }
  db  08Bh, 0F0h        { mov si, ax                 +4,+5 }
  db  0B8h              { mov ax, imm16                 +6 }
  dw  0                 {   patched: data segment       +7 }
  db  08Eh, 0D8h        { mov ds, ax                 +9,+10 }
  db  0BBh              { mov bx, imm16                +11 }
  dw  0                 {   patched: Ofs(Shared)       +12 }

  cmp  si, 0
  jne  @@second

  cmp  word ptr [bx], 0
  jne  @@refuse
  cmp  cx, PKT_MAXFRAME
  ja   @@refuse
  mov  ax, ds
  mov  es, ax
  mov  di, bx
  add  di, 8
  jmp  @@out

@@refuse:
  inc  word ptr [bx + 6]
  xor  ax, ax
  mov  es, ax
  xor  di, di
  jmp  @@out

@@second:
  inc  word ptr [bx + 4]
  mov  word ptr [bx + 2], cx
  mov  word ptr [bx], 1

@@out:
  pop  si
  pop  cx
  pop  bx
  pop  ds
  retf
end;

procedure PatchRecv;
begin
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 7)]  := Seg(Shared);
  MemW[Seg(PktRecv) : Word(Ofs(PktRecv) + 12)] := Ofs(Shared);
end;

function Hex2(B: Byte): ShortString;
const D: array[0..15] of Char = '0123456789ABCDEF';
begin
  Hex2 := D[B shr 4] + D[B and 15];
end;

function Num(L: LongInt): ShortString;
var S: ShortString;
begin
  Str(L, S); Num := S;
end;

function MacStr(const M: TMac): ShortString;
var S: ShortString; I: Integer;
begin
  S := '';
  for I := 0 to 5 do
  begin
    if I > 0 then S := S + ':';
    S := S + Hex2(M[I]);
  end;
  MacStr := S;
end;

function IpStr(const I: TIp): ShortString;
begin
  IpStr := Num(I[0]) + '.' + Num(I[1]) + '.' + Num(I[2]) + '.' + Num(I[3]);
end;

function ParseIp(const S: ShortString; var I: TIp): Boolean;
var P, N, Part, V: Integer;
begin
  ParseIp := False;
  P := 1; Part := 0;
  while Part < 4 do
  begin
    V := 0; N := 0;
    while (P <= Length(S)) and (S[P] >= '0') and (S[P] <= '9') do
    begin
      V := V * 10 + (Ord(S[P]) - 48);
      if V > 255 then Exit;
      Inc(P); Inc(N);
    end;
    if N = 0 then Exit;
    I[Part] := V;
    Inc(Part);
    if Part < 4 then
    begin
      if (P > Length(S)) or (S[P] <> '.') then Exit;
      Inc(P);
    end;
  end;
  ParseIp := P > Length(S);
end;

{ --------------------------------------------------------------------------
  The driver itself.  Calling a vector known only at run time needs the
  PUSHF + far CALL trick: the INT opcode takes an immediate, so instead we
  push the flags and make a far call, which leaves the stack exactly as INT
  would and unwinds correctly on the driver's IRET.

  The catch is that the call returns with DS pointing at the DRIVER's
  segment, so until DS is restored every global here is unreachable and
  storing a result would write into the driver.  Move what is needed into
  registers first, restore DS, then store -- MOV does not touch the flags,
  so the carry the driver returned is still good when it is tested.
  -------------------------------------------------------------------------- }
function PktSigAt(Vec: Byte): Boolean;
const Sig = 'PKT DRVR';
var Sg, Of_: Word; I: Integer;
begin
  PktSigAt := False;
  Of_ := MemW[0 : Word(Vec) * 4];
  Sg  := MemW[0 : Word(Vec) * 4 + 2];
  if Sg = 0 then Exit;
  for I := 1 to 8 do
    if Chr(Mem[Sg : Word(Of_ + 2 + I)]) <> Sig[I] then Exit;
  PktSigAt := True;
end;

procedure GetMyMac;
var MSeg, MOfs: Word;
begin
  MSeg := Seg(PktMyMac); MOfs := Ofs(PktMyMac);
  asm
    push ds
    push es
    push di
    mov  ax, MSeg
    mov  es, ax
    mov  di, MOfs
    mov  cx, 6
    mov  bx, Handle
    mov  ah, 6
    pushf
    call far [Handler]
    pop  di
    pop  es
    pop  ds
  end;
end;

function PktOpen(Vec: Byte; EtherType: Word): Boolean;
var FOfs, RSeg, ROfs, TLen: Word;
begin
  PktOpen := False;
  PktErr := '';
  if IsOpen then begin PktOpen := True; Exit; end;

  if not PktSigAt(Vec) then
  begin
    PktErr := 'no packet driver at ' + Hex2(Vec) + 'h';
    Exit;
  end;
  Handler.O := MemW[0 : Word(Vec) * 4];
  Handler.S := MemW[0 : Word(Vec) * 4 + 2];

  Shared.Busy := 0; Shared.Count := 0; Shared.Drops := 0;
  PatchRecv;

  { A zero-length type filter is "every protocol".  Some drivers want the
    class-1 promiscuous mode instead, but the empty filter is the portable
    spelling and USBPKT honours it. }
  AllProt := EtherType = $FFFF;
  if AllProt then TLen := 0
  else
  begin
    Filt[0] := Hi(EtherType);        { the filter is in network order }
    Filt[1] := Lo(EtherType);
    TLen := 2;
  end;

  FOfs := Ofs(Filt);
  RSeg := Seg(PktRecv);
  ROfs := Ofs(PktRecv);
  asm
    push ds
    push es
    push si
    push di
    mov  ax, RSeg
    mov  es, ax
    mov  di, ROfs
    mov  si, FOfs
    mov  cx, TLen
    mov  bx, 0FFFFh
    mov  dl, 0
    mov  ah, 2
    mov  al, 1
    pushf
    call far [Handler]
    mov  cx, ax
    mov  ax, dx
    pop  di
    pop  si
    pop  es
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
    mov  Handle, cx
    mov  ErrDH, ah
  end;
  if CarryB <> 0 then
  begin
    PktErr := 'access_type refused on ' + Hex2(Vec) + 'h, driver error '
              + Num(ErrDH);
    Exit;
  end;
  IsOpen := True;
  GetMyMac;
  PktOpen := True;
end;

procedure PktClose;
begin
  if not IsOpen then Exit;
  asm
    push ds
    mov  bx, Handle
    mov  ah, 3
    pushf
    call far [Handler]
    pop  ds
  end;
  IsOpen := False;
end;

function PktSend(const Buf; Len: Word): Boolean;
var FSeg, FOfs: Word;
begin
  FSeg := Seg(Buf); FOfs := Ofs(Buf);
  asm
    push ds
    push si
    mov  ax, FSeg
    mov  ds, ax
    mov  si, FOfs
    mov  cx, Len
    mov  ah, 4
    pushf
    call far [Handler]
    pop  si
    pop  ds
    jnc  @@ok
    mov  CarryB, 1
    jmp  @@fin
  @@ok:
    mov  CarryB, 0
  @@fin:
  end;
  { Carry means the driver's transmit buffer was full and NOTHING went out.
    From the caller's side that looks exactly like a packet lost on the
    wire, except retrying at once will fail the same way.  Counting the two
    apart is the difference between "the link is lossy" and "we are
    overrunning the card". }
  if CarryB <> 0 then begin Inc(PktTxFail); PktSend := False; end
  else begin Inc(PktTxOk); PktSend := True; end;
end;

function PktPoll(var Buf; Max: Word; var Got: Word): Boolean;
var N: Word;
begin
  PktPoll := False;
  Got := 0;
  PktRxDrop := Shared.Drops;
  if Shared.Busy = 0 then Exit;
  N := Shared.Len;
  if N > Max then N := Max;
  Move(Shared.Data, Buf, N);
  Got := N;
  Inc(PktRxCount);
  Shared.Busy := 0;            { release it only after the copy is done }
  PktPoll := True;
end;

begin
  IsOpen := False;
  PktRxCount := 0; PktRxDrop := 0; PktTxOk := 0; PktTxFail := 0;
end.
