# CH375USBTools — the complete guide

Everything in this repository, what it is for, what it can and cannot do,
and why. If you only read one file, read this one.

**Contents**

1. [What this is](#what-this-is)
2. [The machine it was built on](#the-machine-it-was-built-on)
3. [Which driver do I want?](#which-driver-do-i-want)
4. [First run](#first-run)
5. [The drivers](#the-drivers)
6. [The tools](#the-tools)
7. [If your card is not at 260h](#if-your-card-is-not-at-260h)
8. [What works and what does not](#what-works-and-what-does-not)
9. [The 8042 problem](#the-8042-problem)
10. [Windows](#windows)
11. [Things the hardware does that are not in the datasheet](#things-the-hardware-does-that-are-not-in-the-datasheet)
12. [Troubleshooting](#troubleshooting)
13. [Building from source](#building-from-source)
14. [What a 386 would unlock](#what-a-386-would-unlock)
15. [Related work](#related-work)

---

## What this is

The WCH **CH375** is usually sold as a way to read a USB stick from an old
machine, and nearly every driver you can find for it does exactly that.
This repository is what the chip can do *instead*: act as a USB **host** on
a real-mode DOS machine, talk to arbitrary USB devices, and present a
keyboard and a mouse to DOS as though they had always been there — plus an
Ethernet adapter as a packet driver, and a **display** as a second screen.

Four projects:

| | |
|---|---|
| **[CH375USBTOOLS](CH375USBTOOLS/)** | seven probe tools. What is plugged in, what it says about itself, what it puts on the wire — any device, any class |
| **[CH375Mouse](CH375Mouse/)** | `USBMOUSE.COM` — INT 33h mouse driver, plus PS/2 BIOS emulation for Windows 3.x |
| **[CH375Keyboard](CH375Keyboard/)** | `USBKBD.COM` — keyboard driver writing into the BIOS keyboard buffer |
| **[CH375Combo](CH375Combo/)** | `USBCOMBO.COM` — both at once, for a USB-to-PS/2 adapter |

Everything here has been run on real hardware. Where something is untested,
this guide says so rather than implying otherwise.

---

## The machine it was built on

An **IBM PS/2 Model 30** — the original 8086 model, not one of the 286 or 386
ones. It is a 1987 machine, nine years older than USB, and almost every
limitation in this guide is a fact about it rather than a shortcoming of the
code.

**A second machine has since been used**, a **Gateway 2000 386SX/25**, and
every project here has been run on it: the drivers, the
camera, the DisplayLink adapter, the modem and the FOSSIL. It is four to five
times the Model 30 and it found two faults the 8086 never could -- see
[On a 286/386/486](#on-a-286386486-the-runtime-hooks-int-10h). Everything
below still describes the 8086, because that is what the code targets.

Both machines boot from a **PicoMEM** ISA card and reach the network through
it, and the cards are swapped between them -- so which card is in which box
is a fact with a date on it. [PicoMEM1](PicoMEM1/) and
[PicoMEM2](PicoMEM2/) read them; neither is about the CH375, and both are in
this collection because the bridge that builds and tests everything here runs
over those cards' WiFi. `PM1INFO` identifies the card from the BIOS date in
its ROM, which is the only reliable way to tell one from the other.

```
Machine    IBM PS/2 Model 30 (8086)
CPU        8086, 8-bit ISA bus           <- this matters more than anything else
DOS        MS-DOS 6.22
USB        CH375B rev B7 on an ISA card, I/O base 260h
Windows    Windows 3.0 (real mode)
Keyboard   XT-class internally -- NO 8042 CONTROLLER, port 64h reads FF
```

Two consequences run through everything:

* **`cpu 8086`.** No near conditional jumps, no `PUSHA`, no 386
  instructions. Where a conditional jump cannot reach, the test is inverted
  over an unconditional `jmp near`, or a trampoline is added. There are
  several in the sources and they are commented as such — they are not
  stylistic.
* **No 8042.** Whatever the PS/2 badge suggests, the Model 30 8086 is
  XT-class inside and nothing answers at the AT keyboard-controller ports:
  port 64h reads `FF`. Nothing can inject a scancode at the hardware level,
  which is the single biggest limitation in this repository.
  [See below](#the-8042-problem).

Devices exercised:

| device | what it showed |
|---|---|
| HP USB keyboard `04F2:1717` | low speed, boot keyboard on interface 0, EP 81 |
| ASUS WiFi dongle `0B05:1786` | full speed, vendor class `FF/FF/FF`, four bulk endpoints — enumerated and dumped, not driven |
| PS2-to-USB adapter `0E8F:0020` | low speed, **two** boot HID interfaces, keyboard on EP 81 and mouse on EP 82 |

---

## Which driver do I want?

**Load exactly one.** Each resets the CH375, enumerates from scratch,
assigns the USB address and hooks `INT 08h` to poll. Two of them on one chip
reset it out from under each other.

| you have | load |
|---|---|
| a USB mouse | `USBMOUSE.COM` |
| a USB keyboard | `USBKBD.COM` |
| a USB-to-PS/2 adapter with both, or a combo dongle | `USBCOMBO.COM` |
| a mouse, and you want Windows 3.x | `USBMOUSE /W` or `USBCOMBO /W` |
| a USB Ethernet adapter | `USBPKT.COM` — see CH375Net |
| DOS software that wants a modem | `FOSSIL.COM` — see CH375Fossil |
| a USB display adapter | nothing resident; the CH375Video tools drive it directly |
| a USB speaker or headset | nothing resident; the CH375Audio tools set its volume and read its buttons. It cannot be played through — see below |
| no idea what you have | `USBINFO` first — it drives nothing |

A **display** adapter is the odd one out: there is no resident driver for
it and no `INT` to hook, because DOS has no notion of a second screen. The
CH375Video tools open the adapter, draw, and close — see
[CH375Video/README.md](CH375Video/README.md).

An **audio** device is the odd one out in the other direction: it is
beautifully described by its own descriptors and still cannot be driven.
Audio is a continuous isochronous stream — 192-byte packets, one every
millisecond, 192 KB/s, with no framebuffer to hide behind — against about
19 KB/s available and a chip that has no isochronous mode. What *is*
reachable is everything that is not the stream: volume and mute over
control transfers, and the transport buttons over an interrupt endpoint.
See [CH375Audio/README.md](CH375Audio/README.md).

The rule that generalises, and the one to apply before attempting any new
class on this bus: **ask whether the device can buffer.** A device that
holds state you update is reachable from a slow host however exotic its
protocol; a device that must be fed continuously at line rate is not,
however well documented it is.

---

## First run

```
cd CH375USBTOOLS
build.cmd scan            find the card
build.cmd info            dump everything the device will tell you
```

`USBSCAN` answers *"what address is the card at"*, which every other tool
assumes you already know. `USBINFO` does not care what class the device is —
that is the difference between it and `CHDIAG`, which stops at *"this is not
a mouse"*.

Then load the driver that matches what you found.

---

## The drivers

### `USBMOUSE.COM` — CH375Mouse

Resident INT 33h mouse driver, about 1.5 KB. Functions `00h`–`24h` with a
text-mode software cursor, plus `/W` for PS/2 BIOS emulation so Windows 3.x
finds a pointing device.

```
USBMOUSE            load
USBMOUSE /W         load with Windows 3.x support
USBMOUSE /S  /U     status, unload
```

### `USBKBD.COM` — CH375Keyboard

Resident keyboard driver, version 1.7.1. Enumerates a USB HID keyboard,
translates usages to PC scancodes, and writes them into the BIOS keyboard
buffer at `0040:001E` — exactly what a real keyboard interrupt does. It also
maintains the three shift-state bytes and drives the lock LEDs.

```
USBKBD              load
USBKBD /S  /U       status, unload
```

### `USBCOMBO.COM` — CH375Combo

Both halves in one image, about 5.3 KB resident. Written because a
USB-to-PS/2 adapter is **one** USB device with two boot HID interfaces, and
the two single-purpose drivers cannot share the chip.

```
USBCOMBO            load -- that is all most people need
USBCOMBO /?         a full help screen
USBCOMBO /W         ...with Windows 3.x mouse support
USBCOMBO /S  /U     status, unload
```

The switches worth knowing:

| | |
|---|---|
| `/G=n` | mouse speed. **Bigger is faster**, default 16, no ceiling |
| `/M=n` | poll the mouse every *n*th tick, default 2 |
| `/R=n` | poll rate, `18.2 × n` Hz, default 16 (291 Hz). **Lower loses keystrokes** |
| `/NK` `/NM` | drive only the mouse, or only the keyboard |
| `/W` | PS/2 BIOS emulation for Windows 3.x |
| `/T` | self-test both halves and exit; needs no keypress |

---

## The tools

### CH375USBTOOLS — seven, class-agnostic

| | |
|---|---|
| `USBINFO` | **run this first.** Every descriptor the device will part with, decoded field by field with raw bytes alongside |
| `HIDREP` | decodes a HID report descriptor into the field map an actual driver needs |
| `USBPOLL` | sits on an IN endpoint and prints every packet |
| `USBCTL` | issues the control transfer you type and shows every stage |
| `CHREG` | the chip's 256 internal registers, with a watch mode |
| `USBSCAN` | finds CH375 boards |
| `USBMON` | watches for devices being plugged and unplugged |

### The per-driver test programs

These are not decoration. Each driver has parts that fail independently, and
each tool isolates one of them.

**CH375Mouse:** `CHDIAG` (is this a mouse?), `MOUSETST` (INT 33h
conformance), `EVTEST` (event handler), `PS2TEST` (25 checks replicating the
exact call sequence Windows 3.0's `MOUSE.DRV` makes), `TICKCHK` and `CLKCHK`
(timer behaviour), `MDEMO` and `CLICKTST` (interactive).

**CH375Keyboard:** `KBDRAW` (raw reports), `KBDTST` (33 checks including
table agreement), `KBDBIOS` (BIOS keyboard data area), `KBCINJ` (is there an
8042?), `KBD16` (which INT 16h calls exist), `I16SPY` (counts INT 16h calls
and paints the INT 09h/08h owners into video memory — the only channel out
of a machine whose foreground is held).

**CH375Combo:** `COMBOTST` — 40 checks, plus:

```
COMBOTST /W=20      watch BOTH endpoints live, with beeps
COMBOTST /KB=20     watch the KEYBOARD reports only
COMBOTST /BIOS      dump the BIOS keyboard data area
COMBOTST /FLUSH     empty the BIOS keyboard buffer
COMBOTST /BEEP      check you can hear the cues
```

`/W` **beeps at you**, because the one thing no automated check can do is
move the mouse: three rising notes to start, one blip per report used, three
falling notes to stop, four hard notes if packets arrived and none was used.
That last cue exists because a driver once discarded 100% of real mouse data
while every automated check passed — they all inject their own reports and
never touch the USB read.

### Every program takes /?

Every program in every project prints its own full help with `/?`, and
`-?`, `?`, `/HELP` and `--HELP` all do the same thing. That screen is the
authority on what a tool accepts — this guide summarises, `/?` is complete.

Bare `/H` is deliberately *not* a help switch: `USBKBD` and `USBCOMBO`
already use `/H` for the INT 16h delivery hook, and a switch that means
"help" in one program and something else in the next is worse than no
shorthand at all.

Every program also prints its name, its version and who wrote it on the
first line, so a capture from a machine you are not sitting at says which
build produced it:

```
USBSCAN 1.0.0  --  find CH375 boards in the ISA I/O space
```

---

## On a 286/386/486: the runtime hooks INT 10h

Everything here is built for the plain 8086 and runs unchanged on a V30, a
286, a 386 or a 486 -- with one trap that is not ours.

Free Pascal's i8086 runtime installs a coprocessor-error handler at startup
and, on a machine where it believes an x87 is present, puts it on **INT 10h**,
the video BIOS vector. The handler starts with `FNSTSW`. With no coprocessor
fitted that read gives 0 on an 8086/V30 and the handler chains harmlessly --
but on a **386 with no 387** it reads back with bit 7 set, the handler takes
its error path, and the video BIOS call never happens. The machine stops dead,
printing nothing, because the output is still in a buffer.

`CH375USBTOOLS/src/vidfix.pas` puts the vector back. It is pulled in by
`chtool`, which nearly every program here uses, and named directly by the few
that do not (`fasttest`, `ecmlink`, `usbget`, `usbvfy`, `rampchk`, the
PicoMEM2 tools). It acts only when there is no coprocessor, the vector points
inside the running program, the bytes are that stub, and the address it
recovers is in ROM -- so it is inert everywhere else, and one binary is
correct on every machine.

It came from DOSBridge, where the same file lives in `starter/`; the two are
kept identical on purpose. The long version, with the measurements, is in
DOSBridge's `docs/hardware.md`.

## If your card is not at 260h

`260h` is the CH375's own default and the address this was developed
against, but the board's address is set by **jumpers** and yours may be
somewhere else. Nothing in this repository is hardwired to `260h`.

**The three drivers take `@hex`:**

```
USBCOMBO @300           load the combo driver against a card at 300h
USBKBD @2A0
USBMOUSE @240
```

**Every tool that touches the chip takes `/P=hex`:**

```
USBINFO /P=300
USBPOLL /P=300 /E=1
HIDREP  /P=300
USBCTL  /P=300
CHREG   /P=300
USBMON  /P=300
KBDRAW  /P=300
CHDIAG  /P=300
```

**`USBSCAN` finds it for you**, and takes `/P=hex` to mean *test only this
one address*:

```
USBSCAN                 try the eight addresses a board is normally at
USBSCAN /P=340          test 340h and nothing else
USBSCAN /A              sweep every 16-byte boundary -- read /? first
```

The plain scan tries `260 250 240 230 220 210 200 290` and nothing else,
so a board jumpered outside that list reports *"No CH375 found"* while
being perfectly healthy. `/A` sweeps everything, but probing an address
means **writing** to it, so it skips a reserved list and you should read
`USBSCAN /?` before using it.

**Confirming what a loaded driver took.** `/S` prints the base the resident
copy is actually using, read out of its image rather than assumed:

```
C:\>USBCOMBO /S
USBCOMBO 1.1.0 -- StevenC
Loaded: USBCOMBO 1.1.0.
  I/O base=0260h  (data, command+1)
Keyboard half:
  live=1
  ...
```

**The tools that do not take a base do not need one.** `MOUSETST`,
`EVTEST`, `PS2TEST`, `CLICKTST`, `MDEMO`, `TICKCHK`, `CLKCHK`, `KBDTST`,
`KBDBIOS`, `KBD16`, `KBCINJ` and `COMBOTST` reach the driver through
`INT 33h`, the BIOS, or the resident image's published pointer block. None
of them opens the card, so there is no address for them to get wrong.

**Two cautions, neither of them measured here.** The drivers' `@nnn`
parser shifts left four bits per hex digit with no digit cap, so more than
four digits wraps silently rather than complaining. And on this machine's
8-bit bus, addresses above `3FF` are likely to alias — that is ordinary
XT-bus behaviour rather than anything specific to the CH375, but it means
`@400` and up are not worth trying. `260h` is the only base this has ever
actually run at; the rest is correct by inspection.

---

## What works and what does not

| | DOS | Windows 3.0 | Windows 95 |
|---|---|---|---|
| USB mouse | **yes**, INT 33h | **yes**, via `/W` | **untested** |
| USB keyboard | **yes**, BIOS buffer | **no**, and unfixable here | **untested** |
| USB Ethernet | **yes**, packet driver at INT 65h | n/a | **untested** |
| USB display | **yes**, DisplayLink only | no | **untested** |
| USB camera | **yes**, IBM PC Camera, stills | no | **untested** |
| USB storage | no — out of scope | no | no |
| USB hubs | no | no | no |
| WiFi dongles, speakers, serial adapters | enumerated and dumped only | — | — |

**A USB display works, and only on DisplayLink.** That is not a gap
waiting to be filled — it follows from what the link can carry. A chip is
usable here only if it has a **framebuffer of its own**, so a picture
holds once sent, and a **compressed** command stream, so sending it is
affordable. DisplayLink has both.

Fresco Logic's **FL2000**, the chip in most cheap USB-to-HDMI dongles, has
neither: it bridges USB to parallel RGB, so the whole frame must arrive
raw and keep arriving at the pixel clock — 36.9 MB/s for 640×480, against
about 19 KB/s available. The tools identify it by vendor ID and say so
rather than failing silently.

So **if you want HDMI, buy a DisplayLink USB-to-DVI adapter and a passive
DVI-to-HDMI converter.** DVI-D and HDMI carry the same signalling, and
that is the configuration everything in CH375Video was measured on.

**Programs that read the keyboard through `INT 09h` never see anything from
`USBKBD` or `USBCOMBO`.** DOS EDIT and QBASIC are both such programs; so are
most games. This was chased to a definitive conclusion with `I16SPY`, which
showed `INT 09h` *and* `INT 08h` both move into QBASIC's segment the moment
EDIT starts. Typing into EDIT works; its **menus** do not. The mouse
*does* reach EDIT's menus, because EDIT reads its mouse through INT 33h.

**Windows 95 is not supported and has not been tested.** There is no 386-class
machine here to test it on, and shipping a claim that cannot be verified is
worse than shipping nothing. See [what a 386 would
unlock](#what-a-386-would-unlock).

**A USB camera works, and so far only one: the IBM PC Camera**
(`0545:8080`, Xirlink C-It model 2) -- colour stills at up to 352x288 in
about two seconds, and pictures on the DOS screen every few seconds. It
proves that an isochronous *IN* stream can be read through a CH375, which
the audio work had seemed to rule out; what made this camera work was its
own packet-size and window registers, which other cameras mostly lack.
[CH375Camera/README.md](CH375Camera/README.md) says which other cameras
have a chance, and [CH375Camera/NEXT.md](CH375Camera/NEXT.md) is where to
start with one.

---

## The 8042 problem

An AT-class machine has an Intel 8042 keyboard controller, and its command
`D2h` means *"pretend this scancode arrived from the keyboard"* — a real
IRQ1, indistinguishable from a keypress. That is the clean way to feed a
synthetic keyboard into DOS, and it reaches everything, including programs
that hook `INT 09h`.

**The Model 30 has no 8042.** It predates that arrangement — XT-class
internally, PS/2 only on the outside — and port 64h reads `FF`. There is no
controller to send `D2h` to. `KBCINJ` reports whether a given machine is
better off; `USBKBD /K` and `USBCOMBO /K` will use the 8042 where one
exists and say so, and fall back where one does not.

So on this hardware:

* keys can be **written into the BIOS buffer** — everything reading `INT 16h`
  or DOS sees them; and
* keys **cannot be made to look like IRQ1** — so anything reading the
  hardware itself is unreachable.

There is no software workaround. Calling `INT 09h` directly does not help:
the handler reads port 60h and finds whatever the hardware last latched. It
was tried, as `USBKBD /W`, and it **locked the machine** — the nested
handler's EOI lands on top of the driver's own and corrupts the 8259. That
option is withdrawn and the note by `wake_int09` explains it at length.

---

## Windows

### Windows 3.0 — mouse yes, keyboard no

Confirmed in a live session on this machine, not merely predicted.

Windows has never heard of INT 33h. Its mouse support is a DLL named in
`SYSTEM.INI` as `[boot] mouse.drv=`, and the one shipped with Windows 3.0 —
`MOUSE.DRV`, 4,896 bytes, 31 October 1990 — is a pure **PS/2 BIOS** driver.
Disassembled, it never touches the 8042: it wants `INT 15h AH=C0h` to report
model `F8/FA/FC`, `INT 11h` bit 2 set, the `C2xx` call sequence, and a
callback registered with `C207h` that it reaches by hooking `INT 74h` and
chaining to whatever was there.

So `/W` claims to be a PS/2 model `FC`, takes `INT 74h` first, and delivers
packets in the frame the BIOS uses. **The stock Microsoft driver then runs
unmodified** — none of this needs any Windows-side code.

```
USBCOMBO /W
WIN
```

with `[boot] mouse.drv=mouse.drv` in `SYSTEM.INI`. `/W` is opt-in because
claiming to be a PS/2 model FC on an 8086 is a lie other software can see.
All three vectors come back on `/U`.

The keyboard half does nothing under Windows, for the same reason as EDIT:
Windows drives input from `INT 09h`. `KEYBOARD.DRV` reads its scancode from
port 60h and there is no 8042 to put one there. Use the machine's own
keyboard.

**Windows cannot be exited over DOSBridge** — it reads the keyboard at
`INT 09h`, where neither `KINJ` nor `KNET` can reach. The only way out is the
power switch. That is why `PS2TEST` exists: it makes exactly the calls
`MOUSE.DRV` makes, in the same order, and proves the emulation **without
starting Windows**.

### Windows 95 — untested, and honestly so

Windows 95 needs a 386 or better. The Model 30 here is an 8086. Nothing here has
ever been run under Windows 95, and none of it is written with Windows 95 in
mind:

* the drivers are real-mode TSRs, not VxDs;
* Windows 95 would want a `.386` virtual device driver to arbitrate the
  CH375 between VMs;
* the PS/2 BIOS emulation targets the Windows 3.0 `MOUSE.DRV` contract
  specifically, and Windows 95's mouse stack is different.

`davidegat/CH375USB` does support Windows 95, via a companion `CH375MOU.DRV`
bridge. If that is what you need, use theirs.

---

## Things the hardware does that are not in the datasheet

Each of these cost real debugging time.

**Command `0Ah` is a general register read.** Documented only as
`GET_MAX_LUN`. Registers `C0h`–`FFh` turn out to be the chip's 64-byte USB
data buffer — run `CHREG` after a transfer and the descriptor that just
arrived is still sitting there.

**`CLR_STALL` also resets the endpoint's data toggle.** A control transfer
that *succeeds* leaves endpoint 0 advanced and the next one is stalled; one
that *failed* cleared the stall on its way out. So transfers alternate —
fail, work, fail, work — which reads as a flaky device and is not one.
Clearing endpoint 0 before every control transfer fixes it.

**Low speed must be set at exactly one moment.** `SET_USB_SPEED` is silently
ignored unless issued after the last `SET_USB_MODE` *and* after the connect
interrupt from the bus reset has been read and cleared. Most mice and many
keyboards are low speed, so this is not an edge case.

**The data toggle is per endpoint.** Polling two endpoints through one
toggle variable makes every second transaction on each a mismatch, reported
as `2Bh`.

**Poll an interrupt endpoint faster than its `bInterval`.** A report the
host does not collect is *replaced*, not accumulated. Polling this adapter's
mouse at 73 Hz against its 100 Hz interval discarded a quarter of the
movement and the pointer crawled.

**A device's answer to `SET_PROTOCOL` is not a promise.** This adapter
answers `SET_PROTOCOL 0` with success and then keeps sending its native
report-ID format anyway. Read the format off the packet, never off the
request's status. Believing the acknowledgement once cost a driver 100% of
its real mouse data.

**Under `SET_IDLE 0`, every report carries a change.** A stream in which no
packet is empty is exactly correct, not evidence of anything fabricated —
and a silent endpoint is a still device, not a broken one. Both were
misread here, in opposite directions, on the same day.

### Two rules for resident code

**`CLD` before any string operation reachable from an interrupt handler.**
The direction flag belongs to the interrupted program. Five string
operations in the keyboard driver's ISR ran backwards whenever the
foreground left `DF=1` — a fault that depends entirely on what else is
running. Credit for the rule goes to
[davidegat/CH375USB](https://github.com/davidegat/CH375USB).

**A polled driver has no safe context outside its own interrupt.** There is
nowhere else to run, which makes anything requiring "not inside an
interrupt" impossible.

---

## Troubleshooting

### "No CH375 found", or the driver says there is no card

The board's address is jumpered, and every program here assumes `260h`
until told otherwise. Check what you actually have:

```
USBSCAN             the eight addresses a board is normally jumpered to
USBSCAN /P=340      test one you already know about
USBSCAN /A          sweep -- read USBSCAN /? first, it writes to ports
```

Then give the address to whatever you are running: `@hex` for the three
drivers, `/P=hex` for the tools. See
[If your card is not at 260h](#if-your-card-is-not-at-260h).

### The keyboard is completely dead

Check the BIOS keyboard buffer **before** blaming a driver.

```
COMBOTST /BIOS      show it
COMBOTST /FLUSH     empty it
```

The BIOS keeps a 15-entry ring at `0040:001E`. When it is full the BIOS
discards every new keystroke **from every keyboard on the machine**. Total
keyboard death, looks exactly like a crashed driver, is not one:

```
40:1A head = 001E   40:1C tail = 003C      <- 15 queued, nothing reading
```

Anything that runs without reading the keyboard fills it — including
DOSBridge's own agent loop, so typing at the machine while that is polling
will do it with no driver loaded at all.

### The mouse pointer crawls

Raise `/G`. `USBCOMBO /G=16` is the default and `/G=24` or more is
available; it multiplies and has no ceiling. Note that this adapter emits
only about **33 reports a second** — the PS/2 mouse's own sample rate — so a
faster pointer is also a choppier one. No poll rate fixes that; `/M` is
already above what the device can generate.

### There is no mouse pointer at the DOS prompt

Correct behaviour. Only a program that calls INT 33h and asks for a cursor
gets one. Run `MDEMO` to see coordinates move.

### Typing drops or transposes characters

Raise the poll rate: `/R=16` is the default and lower values lose keys. A
boot keyboard reports the *set of keys held right now, in no order*, so a
keypress completed between two polls never happened, and two keys in one
report have no ordering. At 145 Hz `abcdefghijkl` came back as
`abcdefghjikl`; at 291 Hz it is exact.

### Nothing enumerates

`USBINFO` first. If it finds no chip, `USBSCAN`. If the chip answers but no
device does, try `/V` on the driver for a bring-up trace — every step prints
the status it returned.

### The machine hangs during a probe

`USBSCAN` without `/A` only tries addresses a CH375 board is actually
jumpered to, and even `/A` skips a reserved list. The first version swept
blind and wrote into the floppy controller at `3F0h`, which took a power
cycle. Do not use `/FORCE` casually.

---

## Building from source

```
cd <project>
build.cmd
```

Needs Free Pascal cross-compiling to `i8086-msdos` (`-Tmsdos -Pi8086`) and
`nasm`, both of which ship with FPC and both of which must be on `PATH`.
Nothing else.

Targets that *run* something additionally need
[DOSBridge](https://github.com/jdredd87/DOSBridge); set `DOSBRIDGE` if it is
not in `C:\dosbridge`.

The binaries are committed deliberately: the machine this targets has no
compiler for them, and for most people the `.COM` file is the thing they
actually want.

**A development footgun:** the version string does not change between
development builds, so two different images that both say `1.0.0` pass the
`/S` and `/U` version check and then read each other's data at the wrong
offsets. Always `/U` before deploying a new build.

---

## What a 386 would unlock

Everything below is **not implemented**. Some of it is now TESTED, because a
**Gateway 2000 386SX/25** has since run every project in this collection --
so the guesses that turned out to be wrong are marked as such rather than
left standing.

**What the 386 actually changed, measured 2026-09-19/20:** nothing about the
CH375 itself. Both SR9700 adapters and an AX88179A moved 5 MB byte-exact, the
mouse, keyboard, camera, DisplayLink, audio and modem projects all behave as
they do on the 8086, and the USB packet rate -- 100 frames/s, the number that
caps this whole collection -- is unchanged, because it is the chip's limit and
not the CPU's. What the faster machine DID do is expose two latent faults: the
runtime's INT 10h hook (above) and a camera heuristic that counted packets
instead of measuring time.

The rest of this section is still a plan rather than memory:

**Windows 95 support.** The obvious big one, and the reason the machine
matters — Windows 95 needs a 386. It would want a `.386` VxD to arbitrate
the CH375 between virtual machines, and a mouse bridge in the shape of
`davidegat`'s `CH375MOU.DRV` rather than the Windows 3.0 PS/2 BIOS trick.

**An 8042, probably.** A 386-class machine almost certainly has one, and
that single fact removes the largest limitation in this repository. With
`D2h` injection, `USBKBD /K` and `USBCOMBO /K` already work — the code is
written and has never had hardware to run on. DOS EDIT's menus, QBASIC and
most games would all become reachable.

**386 instructions.** Everything here is `cpu 8086`: no near conditional
jumps, no 32-bit registers. A 386 target could drop the trampolines and use
`PUSHAD`/`POPAD` in the ISRs.

**USB hubs**, so more than one device at a time — `davidegat` has
experimental support for four downstream ports.

**Mass storage**, which this repository has deliberately never touched.
`davidegat` does it properly and there is no reason to duplicate it.

**Worth reading their source before writing any of it.** Two rules already
came from that project — `CLD`-in-an-ISR and the mode-7 bring-up order —
and both fixed real bugs here. It is cheaper to learn from than to
rediscover.

---

## Related work

[**davidegat/CH375USB**](https://github.com/davidegat/CH375USB) is an
independent CH375 host stack for the same chip at the same I/O address, also
in NASM. It covers ground this repository does not — mass storage with a
drive letter, experimental hub support, and Windows 95 via a companion
driver — and targets 386-class machines such as the Pocket386.

Where they overlap, they overlap substantially: both present a USB keyboard
through the BIOS keyboard buffer and a USB mouse through INT 33h. What is
different here is the 8086 constraint taken seriously, and the class-agnostic
diagnostic suite.

**If you have a 386 and want USB storage, use theirs.**

---

## Licence

**Public domain**, under [the Unlicense](https://unlicense.org) — see
`LICENSE`. Copy it, sell it, strip my name off it. No attribution required.

The one exception is `CH375Mouse/tools/MNASMFIX.COM`, which is somebody
else's work and stays under their terms.

Written by **StevenC**. <https://github.com/jdredd87/CH375USBTools>
