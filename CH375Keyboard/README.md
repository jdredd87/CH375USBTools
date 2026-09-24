# CH375Keyboard

**Version 1.7.1** · one of four projects in [CH375USBTools](../README.md)

If you want a keyboard **and** a mouse on the same card, this is not the
driver -- see **[CH375Combo](../CH375Combo/)**, which is this driver's image
with `CH375Mouse`'s `INT 33h` half built into it. Everything below still
applies to the keyboard side of it, including the part about DOS EDIT.

`USBKBD.COM` is a resident DOS keyboard driver that gets its input from a
USB HID keyboard plugged into a WCH **CH375** ISA card. It enumerates the
keyboard itself — bus reset, speed negotiation, descriptors, address,
configuration, HID boot protocol — then polls the interrupt IN endpoint from
a timer hook, translates HID usages into PC scancodes, and writes them into
the BIOS keyboard buffer where DOS expects to find them.

    cd CH375Keyboard
    build.cmd                 build everything into bin\
    build.cmd raw             ...then watch reports without loading anything
    build.cmd test            ...then load, run the suite, unload
    build.cmd load            ...then load it and leave it resident

## Files

| | |
|---|---|
| `src/usbkbd.asm` | the driver. Assembles to `USBKBD.COM`, about 9 KB, of which roughly 2.5 KB stays resident |
| `src/hidkey.pas` | HID usage → scancode and ASCII, as a unit. `KBDRAW` uses it; `USBKBD` carries the same mapping in assembly, and `KBDTST` checks the two agree |
| `src/kbdraw.pas` | **run this first.** Everything the driver does except go resident: enumerate, poll, decode, and print the scancode and ASCII byte the driver *would* deliver. Nothing is hooked, so a mistake prints a wrong line instead of wedging the machine |
| `src/kbdtst.pas` | 33 checks against a loaded driver, including a byte-for-byte comparison of the two translation tables. `/W=secs` then watches what `INT 16h` and the three shift bytes do while you type |
| `src/kbdbios.pas` | dumps the BIOS keyboard data area: the four flag bytes decoded bit by bit, the buffer with head and tail, the vectors, the interrupt mask. Writes nothing, so it is safe with a driver loaded, and two runs either side of a load can be diffed |
| `src/kbcinj.pas` | does 8042 command `D2h` work on this machine? Injects a known scancode and checks it comes back through `INT 16h`. Run it before trusting `/K` — an XT-class machine has no `D2h`, and finding that out by trying can cost the keyboard until a power cycle |
| `src/kbd16.pas` | which `INT 16h` generations this BIOS implements, and what it hands back for each kind of key. Writes the BIOS buffer directly and asks all six functions |
| `src/i16spy.asm` | counts `INT 16h` calls by function and paints the totals — plus the owners of `INT 09h` and `INT 08h` — into video memory, so a stuck interactive program can be watched with `doscap`. The tool that finally explained EDIT |

The CH375 layer comes from `ch375.pas` in the **CH375USBTOOLS** project next
door, found with `-Fu`. Its `.ppu` is compiled into this project's own
`bin\`, so the two projects share source and never a compiled unit.

## How keys reach DOS

The driver writes scancode/ASCII words into the BIOS keyboard buffer at
`0040:001E` and moves the tail at `0040:001C`, which is exactly what a real
keyboard interrupt does. Everything reading the keyboard through `INT 16h`
or through DOS sees them. The shift state is maintained too — in all three
of the bytes that carry it, which is its own section below.

**What it cannot drive:** a program that takes over the keyboard *hardware*
interrupt and drives its input from IRQ1 never looks in the BIOS buffer at
all. DOS EDIT and QBASIC both do this, and it is the one case this driver
cannot reach on this hardware — see **DOS EDIT's menus** below for the
measurement and the reason. `/K` exists for exactly this and needs an
AT-class 8042; `KBCINJ` says in ten seconds whether a machine has one.

## Command line

    USBKBD [@260] [/S] [/U] [/F] [/V] [/N] [/E] [/K]
           [/R=n] [/D=n] [/T=n] [/?]

| | |
|---|---|
| `@nnn` | CH375 I/O base in hex, default `260`. `/S` prints the base the loaded copy actually took |
| `/?` | the full help screen. This did not work before 1.8.0 — see the changelog |
| `/S` | status of the copy already loaded — including its version, which is the interesting number when two builds are in play |
| `/U` | unload. Refuses if something else hooked `INT 08h` after us, and refuses a resident copy whose version differs from its own |
| `/F` | load even with no keyboard attached, and keep looking for one |
| `/V` | trace each bring-up step and the status it returned |
| `/N` | do not drive the lock LEDs |
| `/E` | claim a 101/102-key keyboard in `0040:0096` bit 4, so software uses the enhanced `INT 16h` calls. Off by default: an XT-class BIOS does not have them. This machine's BIOS sets the bit itself, so `/E` has nothing to do here |
| `/K` | inject scancodes through the keyboard controller with 8042 command `D2h` instead of writing the BIOS buffer, so keys arrive as real IRQ1 interrupts — the only way to reach a program that owns `INT 09h`. **Needs an AT-class 8042**, checked at load time, and falls back to the BIOS buffer if absent |
| `/R=n` | timer divisor, 1–16. PIT rate becomes 18.2 × n Hz; default 8, about 145 Hz |
| `/D=n` | fast ticks before a key starts repeating, default 72 |
| `/T=n` | fast ticks between repeats, default 5 |

### Diagnostics

| | |
|---|---|
| `/T` | self-test the delivery path and exit. **Run this first if the driver seems not to work** |
| `/Y=n` | HID idle rate in 4 ms units, default 0 = report only on change. Nonzero makes the keyboard repeat its state, so the report path can be exercised with nobody typing |
| `/X=hh` | pretend HID usage `hh` is held down, 64 repeats then it lets go. `04` is `a`, `29` is Escape, `51` is Down. Bounded deliberately: an unbounded one floods `COMMAND.COM` and wedges whatever batch file launched it |

### Withdrawn, and why

| | |
|---|---|
| `/H` | delivers keys through an `INT 16h` hook of our own instead of the BIOS buffer. Kept as a diagnostic, but **not** a fix for EDIT and worse than the default there: it steers keys away from the one buffer a blocked BIOS read is watching |
| `/W` | **withdrawn — accepted and ignored.** It called `INT 09h` to wake a program that owns the keyboard interrupt, and locked the machine solid. The full reasoning sits beside `wake_int09` in the source; the short version is below |

## If it seems not to work at all

    USBKBD /T

That drives a key through the whole delivery path — `key_down`, then a
report through the press/release diff, then the release — and reads each
result back through `INT 16h`. It needs no keyboard, no keypress, and does
not go resident:

```
Self-test: driving usage 04h through the delivery path.
  ok   key_down -> INT 16h gave 1E61h
  ok   a whole report through the press diff -> 1E61h
  ok   the matching release produced no key
  PASS -- the delivery path is intact.
```

If that prints `PASS`, the translation and the BIOS-buffer write are intact
and the problem is elsewhere. `USBKBD /Y=25` then `USBKBD /S` is the other
half: the idle rate makes the keyboard report continuously, so `reports`
climbing proves the interrupt handler is receiving and processing them with
nobody typing.

**This should have existed from the start.** All 33 checks in `KBDTST` test
the driver's plumbing — that it enumerated, that the timer calls it, that
its tables match `hidkey.pas`. Not one tested that a usage arriving from the
keyboard comes out of `INT 16h` as the right key, because that needed a
human. A delivery regression could hide behind 33 passing checks, and for a
while one appeared to.

**Two things worth ruling out first,** because both have been mistaken here
for driver faults: a DOSBridge box that has gone offline sits in a
`UGET: no ARP reply` retry loop and appears dead to everything; and a
program whose menus need a real keyboard interrupt, discussed below.

## The three shift bytes

The driver maintains `0040:0017`, `0040:0018` **and** `0040:0096`. Only the
first is the famous one, and on its own it is not enough.

| | |
|---|---|
| `40:17` | the classic byte: shift, ctrl, alt, the four locks, insert |
| `40:18` | bit 0 left Ctrl, bit 1 left Alt. Bits 2–7 are the BIOS's (SysReq, Pause, lock keys while physically held) and are preserved, not guessed |
| `40:96` | bit 2 right Ctrl, bit 3 right Alt, bit 4 "101/102-key keyboard installed" |

A program that asks `INT 16h AH=12h` for the keyboard state is answered out
of the second and third, and they are where the left and right halves of
Ctrl and Alt are told apart. Version 1.0.0 maintained only `40:17`, and the
symptom was exactly what you would expect once you know that: `EDIT.COM`
could be typed into happily and Alt-F did nothing at all.

## The lock keys belong to the BIOS

Scroll, Num and Caps Lock live in bits 4–6 of `40:17`, and their LEDs are
shadowed in `40:97`. Those bits are **shared** with the BIOS and with any
other keyboard the machine has, so the driver reads them, follows them and
toggles them in place. It does not keep its own copy.

Version 1.1.0 did keep its own copy, starting at zero, and wrote it into
`40:17` on every report. On a machine booted with NumLock on, the first
keypress cleared NumLock in `40:17` while `40:97` still had the LED lit —
and from then on the driver and the BIOS each kept overwriting the other's
idea of the lock state. What that looked like from outside was the machine's
**PS/2 keyboard dying** after `USBKBD /U`, needing a reboot, with nothing in
the driver's status output to suggest why. `KBDBIOS` exists because of it:
dump the data area before and after, and the difference is obvious.

The upside of fixing it properly is that Caps Lock pressed on the machine's
other keyboard now updates the USB keyboard's LED, because the driver
follows the BIOS rather than arguing with it.

## Four things that are not obvious

**The report is a state, not an event.** Byte 0 is the modifier bitmap,
byte 1 is reserved, bytes 2–7 are up to six usages held down *right now*, in
no particular order. A usage in this report and not the last one is a press;
one in the last and not this one is a release. Comparing slot by slot would
report a press and a release every time the keyboard reordered its list,
which some do.

**The driver has to generate auto-repeat itself.** `SET_IDLE 0` tells the
keyboard to report only when something changes, which is what a driver wants
— otherwise the endpoint floods. But it means a held key produces exactly
one report, and DOS expects repeat. So repeat is generated here, from the
fast tick, for whichever non-modifier key went down last.

**Usage 01h in a key slot is not a key.** It is a rollover error — the
keyboard saying more keys are down than it can report. Treating it as a
keypress produces a burst of garbage exactly when somebody is typing fast,
so the whole report is discarded when it appears.

**Caps Lock is not a second Shift.** It swaps the case of *letters* only.
Applying it to the digit row turns `1` into `!` whenever Caps Lock is on,
which is a common bug and very annoying to type through. `KBDTST` checks
this specifically, in both directions.

## `CLD` in the interrupt path

The direction flag belongs to whoever the handler interrupted, and this
driver's ISR path contains five string operations: `STOSB` in `ch_read`,
`LODSB` in both control-transfer builders, and the `REP STOSB` and
`REP MOVSB` that zero-fill and remember a report. Every one of them ran
**backwards** if the foreground program happened to be sitting on `DF=1`,
writing over whatever lay below the buffer instead of filling it.

That is a bug which depends entirely on what else is running, so the driver
works perfectly until it suddenly does not. Nothing needs restoring
afterwards: the CPU pushed the original flags on interrupt entry, and
whichever `IRET` eventually runs pops them back.

Found by reading [davidegat's independent CH375
driver](https://github.com/davidegat/CH375USB), which states the rule
outright. That project reached most of the same conclusions separately — the
mode 5/7/6 reset order, low speed reapplied after the final mode 6,
`SET_RETRY` because the default retries NAK forever, storing the real
`bMaxPacketSize0` for short-packet detection, boot protocol with idle 0, the
make/break diff over a six-key report, driver-generated typematic, and the
shift flags at 40:17, 40:18 and 40:96. Worth reading.

It had one more rule that was already true here by accident rather than
intent: **every failure path must leave CH375 mode 7.** Leaving the
controller asserting USB bus reset makes healthy devices look dead. This
driver's bring-up has no exit between mode 7 and mode 6, so it was safe.

The mouse driver next door was checked against this too: all of its string
operations sit after `resident_end`, in transient code only, so it is not
affected.

## Two hand-written copies of one table, and how they are kept honest

`USBKBD` needs its translation as assembly tables; `hidkey.pas` expresses the
same mapping as case statements, because a literal Pascal array has to be
counted by hand and miscounting it by one silently shifts every key after
the mistake. (The first draft of `hidkey.pas` did exactly that.)

Two copies of one mapping is the kind of thing that drifts silently —
somebody fixes a key in one and not the other, and then the driver and the
diagnostic disagree about what the keyboard just did. So the resident image
publishes where its tables are, in a pointer block at `0111h`, and `KBDTST`
reads them straight out of memory and walks all 256 usages:

```
-- the two translation tables --
  ok    scancode table agrees for all 256 usages
  ok    E0-prefix list agrees for all 256 usages
  ok    unshifted character table agrees
  ok    shifted character table agrees
```

That check needs no keyboard and no human.

## What a loaded driver looks like

```
USBKBD 1.7.1 -- StevenC
  connect            : 15
  connect after reset: 15
  device rate reg 07 : 11
  GET_DESCR device   : 14
  SET_PROTOCOL boot  : 14
  SET_IDLE 0         : 14
USB keyboard on CH375: endpoint 1, HID interface 0, VID/PID 04F2/1717
Low-speed device; USB bus set to 1.5 Mbps.
USBKBD resident.  Keys go to the BIOS buffer.
```

and `USBKBD /S` afterwards:

```
Loaded: USBKBD 1.7.1.  live=1
  endpoint=1
  polls=1170
  reports=81
  keys delivered=16
  keys dropped (buffer full)=16
  timer divisor=8
```

`polls` and `reports` are both there for a reason: with `SET_IDLE 0` an idle
keyboard sends nothing at all, so a driver that is polling perfectly well
shows a frozen report count. Telling *"not being called"* from *"called,
nothing to report"* needs both numbers — and the first version of `KBDTST`
failed a healthy driver for exactly that reason.

The `dropped` count above is also correct, and worth understanding: a key
was physically held down, auto-repeat filled all fifteen slots of the BIOS
buffer in about a second, and nothing was reading it. A real keyboard
behaves the same way.

## Why a timer hook

DOS is not reentrant and the CH375 has no useful IRQ wiring on this card, so
the keyboard is polled. 18.2 Hz is far too slow to type through, so
`INT 08h` is taken over and the PIT divided by 8. The original handler is
still called every 8th tick, so BIOS timekeeping, DOS's own clock and
anything else chained on `INT 08h` see exactly the rate they expect.

If something else hooks `INT 08h` afterwards, its handler is the one the PIT
calls — at *our* divided rate, because it chains down to us — and anything
timing from the tick then runs eight times too fast. The driver notices,
puts the PIT back and stops dividing; polling drops to 18.2 Hz, slow for
typing but correct for everybody else. `on_top` existed as a variable from
1.0.0 and was not actually maintained until 1.4.0.

The handler also runs on **its own stack**. An interrupt handler runs on
whatever stack the interrupted program left behind, and that stack is not
ours to spend: `poll_kbd` nests several calls deep and can run a whole
control transfer for the LEDs. A program with a tight stack gets its own
memory quietly written over, and what that looks like from outside is the
*other* program crashing.

## DOS EDIT's menus

EDIT's editor accepts typing perfectly. Its **menus cannot be driven from
the USB keyboard on this machine, and no change to this driver will fix
that.** It is the one thing in the project that ends in a wall, so here is
the whole chain of evidence.

**What EDIT does.** `I16SPY.COM` paints the owner of `INT 09h` and `INT 08h`
into video memory, sampled from inside the interrupted program — the only
channel out of a machine whose foreground is held by a stuck program:

```
DOS prompt:   INT 09h = 12DF:0045   INT 08h = 12DF:003C
inside EDIT:  INT 09h = 504A        INT 08h = 504A      <- QBASIC's segment
```

**EDIT and QBASIC take over the keyboard hardware interrupt** and drive
their input from IRQ1, not from the BIOS. A program doing that never looks
in the BIOS keyboard buffer while it waits, so a key put there is invisible
— and the instant any key is pressed on the machine's own keyboard, IRQ1
fires, QBASIC's handler runs, it wakes, and everything queued arrives at
once. That is the reported symptom precisely.

**Why it cannot be fixed here.** A software driver cannot raise IRQ1, and
this machine has **no 8042** — `KBCINJ` reports port 64h reads `FF`, because
an XT-class box has an 8255 keyboard latch and no injection command at all.
Calling `INT 09h` to supply the nudge was tried (`/W`) and **locked the
machine**: this driver delivers from inside its timer handler, so the nested
handler's EOI to the 8259 lands on top of its own, the controller's
in-service state is corrupted, and interrupts stop arriving. Doing it safely
needs an interrupt raised without an EOI from outside an interrupt, and a
polled USB keyboard has no such context.

**`/K` is the real fix, on hardware that has a keyboard controller.** There
keys arrive as genuine IRQ1s and this whole class of problem — games
included — disappears.

### Ruled out along the way, each by measurement

* **The shift bytes.** Fixed in 1.1.0; Alt-F works.
* **The PIT rate.** `/R=1` removes the division entirely: no change.
* **The arrow encoding.** Both `5000h` and `50E0h` tried.
* **A missing enhanced `INT 16h`.** `KBD16` reports all six functions
  present, and the BIOS round-trips every key type exactly, including
  folding `50E0`→`5000` for `AH=00h`.
* **The driver itself.** `KNET` reproduces the symptom with no USB driver
  loaded at all.
* **The delivery route.** `/H` delivers through an `INT 16h` hook instead of
  the buffer and fails identically.

And one positive result that pins it down: a burst of `Alt-F Down Down`
queued in a **single** datagram drives the menu (New → Open → Save), while
the same keys a second apart do not. The keys, the scancodes and the BIOS
path are all correct. What is missing is the interrupt.

### Two measurement mistakes, recorded rather than buried

Both produced confident wrong conclusions, and both have the same shape.

**Hook order.** The first `I16SPY` run loaded the spy *before* `KNET`, so the
chain was `INT 16h → KNET → I16SPY → BIOS`. KNET answers the four functions
it handles without chaining, absorbing EDIT's calls above the spy — and the
counters read zero. That was read as "EDIT never calls `INT 16h`". A spy has
to sit on **top** of the chain, which means loading it last.

**A packed binary read as code.** `QBASIC.EXE` was searched for
`MOV AX,2509` (hook `INT 09h`) and `MOV AX,2516` (hook `INT 16h`); the
second was present, the first was not, and the conclusion drawn was that
QBASIC hooks the BIOS keyboard service and *not* the hardware interrupt.
**It is PKLITE-compressed** — the marker is at file offset `1Eh`, the entry
point is `FFF0:0100`, and there is a single relocation. Every byte examined
was compressed data, so both the hit and the miss were coincidence, and the
conclusion was the exact reverse of the truth. The runtime probe above
settled it properly. *Check for a packer before reading an old DOS binary as
code.*

## Do not mix builds

`/S` and `/U` reach into the resident copy using the offsets of the binary
doing the asking. Add one byte of resident data and everything below it
moves — so unloading a resident 1.0.0 with a 1.1.0 binary read the saved
interrupt vector from the wrong address and restored garbage, killing the
machine on the next timer tick, well after the command that caused it had
returned.

Both now refuse a resident copy whose version differs from their own, and
say which is which. `/U` additionally takes the vector out of the published
pointer block rather than a symbol, so it does the right thing across
builds. If you are ever stuck with a mismatched pair, reboot.

## Ctrl-Alt-Del, and a warning about stuck keys

Ctrl-Alt-Del reboots, which is what everyone expects of it and the only way
off a machine whose only keyboard is this one.

The flip side: a **physically stuck key** is delivered forever, because
auto-repeat is generated by the driver and a key nothing releases is never
released. If the stuck combination happens to be Ctrl-Alt-Del the machine
will reboot in a loop. Less dramatically, a stuck ordinary key floods the
BIOS buffer and the DOS console with characters, which is enough to derail a
batch file that was reading input — including DOSBridge's own agent loop.
Both were observed during development, with a weight resting on the
keyboard. `USBKBD /U` or a power cycle is the way out.

## Hard limits worth remembering

Exit codes must be ≤ 20, filenames are 8.3, and a DOS critical error blocks
forever and looks exactly like a hang. See `CLAUDE.md` at the DOSBridge
repository root.

---

Written by **StevenC** and **Claude** (Anthropic): StevenC guiding, deciding and testing on real hardware, Claude doing most of the analysis, code and measurement.
