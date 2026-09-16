# CH375USBTOOLS

Seven DOS programs for finding out what a USB device is and what it will
tell you, over a WCH **CH375** ISA card in host mode. Nothing here is
storage, and nothing here cares what class the device is — which is the
whole point. `CHDIAG` in the mouse project stops at *"this is not a
mouse"*; these stop at nothing.

One of four projects in [CH375USBTools](../README.md). The three drivers —
**[CH375Mouse](../CH375Mouse/)**, **[CH375Keyboard](../CH375Keyboard/)** and
**[CH375Combo](../CH375Combo/)** — were all written with these.

    cd CH375USBTOOLS
    build.cmd                 build everything into bin\
    build.cmd info            ...then probe whatever is plugged in
    build.cmd scan            ...then look for the card
    build.cmd hid             ...then decode the HID report descriptor
    build.cmd poll            ...then watch the first interrupt IN endpoint
    build.cmd reg             ...then dump the chip's register map

Sources are in `src\`, built binaries in `bin\`, and the binaries are
committed: the machine this targets has no compiler for them.

## The tools

| | |
|---|---|
| `src/ch375.pas` | the shared unit: port handshake, bring-up, control transfers with a real data stage, endpoint I/O. Everything else is a front end for it, and `CH375Keyboard` uses it too |
| `USBINFO.EXE` | **the one to run first.** Every descriptor the device will part with, decoded field by field with the raw bytes alongside: device, string languages and every string, every configuration in full with its interfaces, alternate settings and endpoints, class-specific descriptors, the device qualifier, and each HID report descriptor |
| `HIDREP.EXE` | reads a HID report descriptor as what it is — a little stack program describing a bit layout — and prints the item stream *and* the field map each report actually has. The field map is what you copy into a driver |
| `USBPOLL.EXE` | sits on an IN endpoint and prints every packet. Finds the first interrupt IN endpoint by itself; decodes boot keyboard and mouse reports if that is what the interface claims to be |
| `USBCTL.EXE` | issues the control transfer you type and shows every stage of the answer. The poking tool, and the one that earns its keep when a device misbehaves |
| `CHREG.EXE` | the chip's own internal register map, all 256 of them, with a `/W` watch mode that prints only what changed |
| `USBSCAN.EXE` | finds CH375 boards. Answers "what address is the card at", which every other tool assumes you already know |
| `USBMON.EXE` | watches the port for things being plugged in and pulled out, optionally enumerating each arrival |

Every tool takes `/P=hex` for the I/O base and defaults to `260h`. The
board's address is set by jumpers; if yours is not at `260h`, `USBSCAN`
finds it and `USBSCAN /P=hex` tests one named address on its own.

Every program here prints its own full help with **`/?`** — `-?`, `?`,
`/HELP` and `--HELP` all do the same thing — and prints its name, version
and author on its first line, so a captured log says which build produced
it. Bare `/H` is not a help switch: `USBKBD` and `USBCOMBO` already use it
for the INT 16h delivery hook.


## Worked example

An HP USB keyboard, `04F2:1717`, on a CH375B rev B7:

```
=== USBINFO -- CH375 USB device probe ===
chip     : CH375 rev B7
bus      : low speed (1.5 Mbps)
ep0 max  : 8 bytes

DEVICE DESCRIPTOR  (18 bytes)
  0000  12 01 00 02 00 00 00 08  F2 04 17 17 24 00 01 02  |............$...|
  bcdUSB                2.00
  idVendor              04F2  Chicony
  iProduct              02  "HP USB Keyboard"

CONFIGURATION index 0  (59 of 59 bytes)
    INTERFACE 0
    bInterfaceClass     03/01/01  HID boot keyboard
      HID descriptor  version 1.10  country 0
        subordinate: HID REPORT, 65 bytes
      EP 81  IN   interrupt     max 8  interval 10
```

and `HIDREP` on the same device, which is where a driver comes from:

```
  id  kind     byte.bit  size  count  usage
  0   Input    0.0       1     8      LeftCtrl .. RightGUI
  0   Input    1.0       8     1      (padding)
  0   Output   0.0       1     3      Num Lock .. Scroll Lock
  0   Input    2.0       8     6      no event .. 00FF
  input   report: 8 bytes  (64 bits)
  output  report: 1 bytes  (8 bits)
```

That is the standard HID boot keyboard: one modifier byte, one reserved,
six keycodes, and a one-byte LED report going the other way.

## Two things this suite found out the hard way

### Control transfers work every other time unless you clear endpoint 0

`CLR_STALL` on the CH375 does more than clear a stall: it resets the
endpoint's data toggle inside the chip. A control transfer that *succeeds*
leaves endpoint 0 advanced, and the **next** transfer's data stage is then
stalled by the device — while a transfer that *failed* cleared the stall on
its way out, and so left the endpoint fit for the one after it.

The result is that control transfers alternate: fail, work, fail, work.
That reads as a flaky device or a bad cable and is neither. `USBCTL /N=6`
is what made it visible, because it tallies the attempts:

```
  1 ok, 2 failed   [X.X]        before
  6 ok, 0 failed   [......]     after
```

So `ch375.pas` clears endpoint 0 at the start of every control transfer.
It is not defensive tidying; it is required.

### Ask for the length the descriptor says, not a round number

The obvious way to read a string descriptor is to ask for 255 bytes and
take what comes. On this keyboard that over-read earns a `STALL` at the
tail — and per the above, that stall then poisons the next transfer. Both
`USBINFO` and `HIDREP` therefore do a two-stage read: fetch the first few
bytes, take the real length out of them, then ask for exactly that.

`CtrlIn` also stops on a zero-length packet, which is the third way a
device says "that is all" and the one that is easy to forget.

## USBSCAN and the ISA bus

Probing an address means **writing** to it: `CHECK_EXIST` sends `55h` to
`base+1` and reads `base+0`. On a real ISA machine most addresses belong to
something, and a stray write to the wrong one does not politely return an
error — it hangs the machine. That is not hypothetical. The first version
of `USBSCAN` swept `200h`–`3F0h` blind and wrote into the floppy controller
at `3F0h` on the way past, which took a power cycle to recover.

So the default is a short list of addresses a CH375 board is actually
jumpered to, and even the `/A` sweep skips a reserved list (IDE, the serial
and parallel ports, the floppy controller, the usual disk and network
cards). `/FORCE` overrides that, and the header says why you probably
should not.

## Odds and ends worth knowing

* **Registers `C0h`–`FFh` are the chip's 64-byte USB data buffer.** Run
  `CHREG` after any transfer and the descriptor that just arrived is still
  sitting there. Useful, and not in the datasheet.
* **Do not use the `crt` unit.** It takes over the screen and writes
  straight to video memory, so its output never reaches the redirected
  stdout DOSBridge captures — a tool that uses it runs perfectly and
  appears to print nothing at all. `ch375.pas` provides `KeyWaiting` and
  `Ticks` off `INT 16h` and the BIOS tick counter instead.
* **Every polling tool needs a wall-clock limit.** A device that is idle
  NAKs forever, and a loop waiting for *n* packets will sit there for as
  long as you asked — which from a test harness is indistinguishable from a
  hang. `USBPOLL` takes `/S=secs` and defaults to 20.
* **`/R=n` on `USBPOLL` sets the HID idle rate.** At the default of 0 the
  device reports only when something changes, which is what a driver wants
  — but it means a key that was *already held down* when polling started
  produces nothing at all, because that is not a change. `/R=25` makes the
  device repeat its state every 100 ms.

## Devices this has been run against

| device | what it showed |
|---|---|
| HP USB keyboard, `04F2:1717` | low speed, two HID interfaces, boot keyboard on interface 0, EP 81 IN interrupt max 8 |
| ASUS WiFi dongle, `0B05:1786` | full speed, vendor class `FF/FF/FF`, four bulk endpoints. `CHDIAG` refuses this device; `USBINFO` dumps it in full |
| PS2-to-USB adapter, `0E8F:0020` | low speed, USB 1.10, **two** boot HID interfaces at once — see below |

A USB-to-serial adapter, a USB speaker, USB storage and a wireless
keyboard/mouse combo dongle are all just more of the same to `USBINFO` — it
reports what they say about themselves whether or not anything here could
drive them.

### The PS/2 adapter, in full

A USB-to-PS/2 adapter with a keyboard and a mouse plugged into it is one
low-speed USB device carrying two independent boot HID interfaces:

```
INTERFACE 0   class 03/01/01  HID boot keyboard
              EP 81  IN  interrupt  max 8  interval 10   report descr 62 bytes
INTERFACE 1   class 03/01/02  HID boot mouse
              EP 82  IN  interrupt  max 5  interval 10   report descr 130 bytes
```

Two interfaces, two interrupt IN endpoints, one device address. That is the
cleanest possible shape for a driver that wants both at once -- and the one
case where wanting both is reasonable, since `USBMOUSE.COM` and
`USBKBD.COM` cannot be loaded together. **[CH375Combo](../CH375Combo/) is
that driver**, and building it turned up something no probe tool would have
found on its own: see below.

**One wrinkle worth knowing before writing that driver.** `HIDREP /I=1`
shows the mouse interface declaring **report IDs**:

```
  id  kind     byte.bit  size  count  usage
  1   Input    0.0       1     5      Button 1 .. Button 5
  1   Input    1.0       8     3      X .. Wheel
  2   Input    0.0       1     3      System Power Down .. System Wake Up
  3   Input    0.0       16    1      consumer control
```

So in its native report mode this mouse sends a **5-byte** packet with a
leading ID byte — not the classic 3-byte boot report, and exactly the
5 bytes that endpoint 82's max packet allows. It does advertise
`subclass 01 / protocol 02`, so `SET_PROTOCOL boot` should collapse it to
3 bytes with no ID; a driver that assumed boot mode without asking for it
would misparse every packet. Telling the two apart at run time is easy
enough — a 5-byte report beginning `01` is report mode, 3 or 4 bytes is
boot mode.

### `USBPOLL` needs something to actually happen

`USBPOLL` reports what arrives, and under `SET_IDLE 0` an untouched device
sends **nothing at all** -- which is correct, and looks identical to a
broken endpoint:

```
USBPOLL /E=2 /I=1  ->  polls 88, packets 0, NAK 88   (12 seconds, idle mouse)
```

That output is not evidence the endpoint is dead. Press a key on the device
or move the mouse while it runs, or the measurement means nothing. Two
separate wrong conclusions during `CH375Combo`'s development came from
treating a quiet endpoint as a faulty one; the account is in
[`CH375Combo/README.md`](../CH375Combo/README.md).

The related trap is the opposite reading. Because a device reports only when
something *changes*, **every** packet from a healthy device carries a
change. A stream in which none is empty is exactly right, and is not
evidence of anything being fabricated.

### `SET_PROTOCOL` success does not mean it switched

The PS2-to-USB adapter answers `SET_PROTOCOL 0` with `14h` success and then
keeps sending its native report-ID format. `USBPOLL` and `HIDREP` both issue
the request, so what they print afterwards is what the device *actually*
sends, not what it agreed to -- believe the packet, never the status.

## If you build a resident driver on this unit

`ch375.pas` is written for ordinary programs. Two rules apply the moment
its routines are reachable from an interrupt handler, and both cost real
time to find:

* **`CLD` first.** `ReadUsb` uses `STOSB` and the control-transfer builders
  use `LODSB`; the direction flag belongs to whoever was interrupted, and on
  `DF=1` they run backwards. See the note in `CH375Keyboard`.
* **Bounded waits only.** `WaitInt` takes a millisecond budget for a
  reason. Inside an interrupt handler a device that stops answering must
  cost one tick, not the machine.

## Hard limits worth remembering

Exit codes must be ≤ 20, filenames are 8.3, and a DOS critical error
blocks forever and looks exactly like a hang. See `CLAUDE.md` at the
DOSBridge repository root.

## The shared NASM includes

`src/ch375def.inc`, `src/ch375io.inc` and `src/ch375ser.inc` are not tools.
They are the part of the CH375 layer that two **assembly** drivers both
need, kept in one place so it can only be wrong once:

| | |
|---|---|
| `ch375def.inc` | command codes, statuses, token PIDs. Constants only, so it emits no bytes and may sit anywhere |
| `ch375io.inc` | the register primitives: command, data, status, and the bounded wait for the chip's interrupt |
| `ch375ser.inc` | the `SET_RETRY` split, a vendor request on endpoint 0, and a bulk OUT with its own data toggle |

Used by `CH375Mouse/src/usbmouse.asm` and by DOSBridge's
`projects/fossil/src/fossil.asm`. The Pascal tools share `dser.pas` from
CH375Serial instead; a Pascal unit cannot be included into NASM, which is
why there are two shared layers rather than one.

**Why bother.** The `SET_RETRY` distinction -- `$8F` retries a NAK for ever,
which is right while enumerating and ruinous while polling -- has been
rediscovered **five times** across these projects, each time as a machine
that had become unusably slow, because the knowledge lived in three places
and only one of them had been fixed.

**How the extraction was checked.** Each include sits at the exact position
its code held inside `usbmouse.asm`, so assembling the mouse driver after
the move produced a **byte-identical `USBMOUSE.COM`** -- 10,232 bytes,
CRC-32 `195E9DCE`, before and after. For a pure code motion that is a
stronger check than any hardware test: identical bytes are the same
program. It also mattered practically, because the mouse was not plugged in
at the time and could not have been tested any other way.

Anything one caller needs and the other does not is behind `%ifdef` for the
same reason:

```
CH375_COUNTERS    record failed transfers in last_st and ch_err.
                  The caller declares both.
```

One thing deliberately **not** shared is `CLD`. The FOSSIL driver's copy of
`bulk_out_ser` had grown one, the mouse's had not, and adding it would have
broken byte-identity for no behavioural gain -- DF is clear by DOS
convention on both paths. The caller clears it instead.
