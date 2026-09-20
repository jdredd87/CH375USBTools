program pm1dump;
{ PM1DUMP -- the card's BIOS ROM and shared memory into a file.
  PicoMEM1 tools, StevenC.  Public domain (the Unlicense).

    PM1DUMP [file] [/K] [/R] [/P=2A0]

  24 KB: the 16 KB ROM followed by the 8 KB of shared memory that sits
  straight after it.  Read-only; the file is for reading somewhere with
  room to read it.  The default name is PM1DUMP.BIN in the current
  directory.

  THE WIFI KEY IS IN THERE.  When the card answers its WiFi query it
  copies a structure into the shared memory that holds the network's
  name AND its key, and that copy stays there until something else
  overwrites it.  So by default the 63 bytes the key occupies are
  written out as zeros -- a dump is a file that gets copied about.

    /K   keep the key bytes.  Only for a machine whose network you own
         and a file that is not going anywhere
    /R   ROM only: 16 KB, no shared memory, and then nothing is blanked
         because there is nothing there to blank
    /P=  I/O base to try if the card BIOS does not answer (default 2A0)

  Finding where to blank costs one read-only command, the disk-list
  query, because that is what locates the parameter area (pm1card.pas
  explains why it moves).  If it cannot be found, BOTH known offsets
  are blanked rather than neither.

  Exit code: 0 written, 1 no card, 3 no shared memory, 4 the file
  could not be written. }

{$MODE OBJFPC}{$H-}

uses pm1card, vidfix;

const
  VER = '1.0.0';
  ROMLEN = 16384;
  W_KEY  = 39;           { the key, inside the WiFi structure }
  W_KEYLEN = 63;

var
  Name: string;
  KeepKey, RomOnly: Boolean;
  ForceBase: Word;
  Buf: array[0..ROMLEN + SHARED_LEN - 1] of Byte;

function ParseHex(const S: string; var W: Word): Boolean;
var I: Integer; C: Char; V: Word;
begin
  V := 0; ParseHex := False;
  if S = '' then Exit;
  for I := 1 to Length(S) do begin
    C := UpCase(S[I]);
    case C of
      '0'..'9': V := V * 16 + Ord(C) - 48;
      'A'..'F': V := V * 16 + Ord(C) - 55;
    else Exit;
    end;
  end;
  W := V; ParseHex := True;
end;

procedure Args;
var I: Integer; S: string; W: Word;
begin
  Name := 'PM1DUMP.BIN';
  KeepKey := False; RomOnly := False; ForceBase := $2A0;
  for I := 1 to ParamCount do begin
    S := ParamStr(I);
    if (Length(S) >= 2) and ((S[1] = '/') or (S[1] = '-')) then
      case UpCase(S[2]) of
        'K': KeepKey := True;
        'R': RomOnly := True;
        'P': if (Length(S) > 3) and (S[3] = '=') then
               if ParseHex(Copy(S, 4, 9), W) then ForceBase := W;
      end
    else
      Name := S;
  end;
end;

procedure Blank(At: Word);
var I: Word;
begin
  for I := 0 to W_KEYLEN - 1 do
    if LongInt(At) + I < SHARED_LEN then Buf[ROMLEN + At + I] := 0;
end;

var
  F: file;
  I: Word;
  Bad: Word;
  Len: LongInt;
begin
  Args;
  WriteLn('PM1DUMP ', VER, ' -- the card''s ROM and shared memory to a file');

  if not AskBios then PmBase := ForceBase;
  Bad := TestPort(PmBase, 100);
  if Bad <> 0 then begin
    WriteLn('no PicoMEM at ', Hex4(PmBase), 'h (', Bad,
            ' of 100 test-port reads out of sequence)');
    Halt(1);
  end;
  if PmRomSeg = 0 then begin
    WriteLn('the card''s BIOS did not answer, so its ROM segment is unknown');
    Halt(3);
  end;

  Len := ROMLEN;
  if not RomOnly then Len := ROMLEN + SHARED_LEN;

  { find the parameter area before reading, so the blanking knows where
    to bite.  The query writes into that same area, which does no harm:
    the disk list is not what has to be kept out of the file }
  if (not RomOnly) and (not KeepKey) then FindParam;

  for I := 0 to Len - 1 do
    if I < ROMLEN then Buf[I] := Mem[PmRomSeg : I]
      else Buf[I] := SharedB(I - ROMLEN);

  if (not RomOnly) and (not KeepKey) then begin
    if PmParam <> 0 then begin
      Blank(PmParam + W_KEY);
      WriteLn('WiFi key bytes zeroed: 63 bytes at +', PmParam + W_KEY,
              ' in the shared memory');
    end else begin
      Blank(PARAM_2025 + W_KEY);
      Blank(PARAM_2026 + W_KEY);
      WriteLn('the parameter area was not found, so BOTH known key',
              ' positions were zeroed');
    end;
  end else if KeepKey and (not RomOnly) then
    WriteLn('/K: the WiFi key is in this file if the card has answered a',
            ' WiFi query');

  Assign(F, Name);
  {$I-}
  Rewrite(F, 1);
  {$I+}
  if IOResult <> 0 then begin
    WriteLn('cannot write ', Name);
    Halt(4);
  end;
  {$I-}
  BlockWrite(F, Buf, Len);
  Close(F);
  {$I+}
  if IOResult <> 0 then begin
    WriteLn('failed while writing ', Name);
    Halt(4);
  end;

  WriteLn('ROM segment ', Hex4(PmRomSeg), 'h, ', Len, ' bytes to ', Name);
  if RomOnly then WriteLn('(ROM only)')
    else WriteLn('the first ', ROMLEN, ' bytes are the ROM, the rest is the',
                 ' shared memory');
  Halt(0);
end.
