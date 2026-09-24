# PicoMEM

**Reading a PicoMEM card from real-mode DOS: what it is, what it has mounted,
what it has mapped over your memory, which of its emulated devices are really
answering, what a USB device on it can and cannot do, and what the whole thing
costs to talk to.**

The [PicoMEM](https://github.com/FreddyVRetro/ISA-PicoMEM) is an 8-bit ISA
card with a Raspberry Pi Pico on it that emulates memory, disks, sound cards
and -- on a Pico W -- an NE2000 over WiFi. The **PicoMEM 1** is the original
family (1.0 through 1.14, plus the Low Profile and 1.2A); the **PicoMEM 2** is
the RP2350 board. Everything here runs on both, unchanged, and has been run on
both.

One of the projects in [CH375USBTools](../README.md), and not about the CH375
at all. **It is in that collection because the collection depends on it**:
neither development machine has a working hard disk or a network card, so
both boot from disk images on a PicoMEM and reach the outside world through
the NE2000 the same card emulates over WiFi. Every source file, test binary
and result in that repository crossed one of these cards. When one
misbehaves, nothing builds and nothing runs -- and there was no way to ask it
anything from DOS until these tools existed.

Written in Pascal from reading the card's published firmware and BIOS
sources (GPLv2); no code is taken from them, and nothing here is a port of
anything.

> **This was two projects, `PicoMEM1` and `PicoMEM2`, and they were merged on
> 2026-09-20.** The split came from the order the work happened in rather than
> from any real difference: the PicoMEM 2 project was written first and spent
> its time on one question -- *can DOS drive a USB device through this card?*
> -- while the PicoMEM 1 project came second, found the protocol already
> decoded, and went wide. By the end every tool ran on both cards, so the `1`
> in ten of the names had become a claim about compatibility that was not
> true. The old names are in the git history; the tools that survived are
> below, and three that had been superseded were retired rather than carried.

## Tools

| | |
|---|---|
| `PMINFO` | what the card is and how it came up: BIOS date out of the ROM, every init state, IRQ, disk counts, and where this firmware writes its answers |
| `PMCFG` | the whole configuration: disk and ROM images, the memory map, EMS, boot options, NE2000, and every sound card it is set to emulate |
| `PMMEM` | the **live** memory map -- 64 blocks of 16 KB asked one at a time -- beside the configured one. `/W` also asks the PC what it sees at each block |
| `PMDEV` | which emulated devices really answer, from the PC side: the card's own port, an OPL2's timers, the packet driver on its NE2000, the joystick, the RTC, and every option ROM in the upper memory area |
| `PMSTAT` | the three text answers -- disks with their geometry, the USB device list, and `/W` the WiFi state. `/S=n` watches the USB list for n seconds |
| `PMOPL` | plays a scale through the AdLib the card emulates, after proving an OPL2 is there by its timers |
| `PMBENCH` | what the card costs: port reads, its RAM and ROM against the PC's own, and a whole command round trip |
| `PMMTEST` | turns on the card's mouse reporting, watches the deltas and buttons arrive in its shared memory while you move a USB mouse, and turns it off again. **Beeps** when it wants your hand on the mouse |
| `PMWATCH` | watches **all 8 KB** of the shared memory and reports every byte that moved. The tool for "does anything happen, and where?" -- `/2` runs two windows and takes the difference, `/T` makes it prove it can see a write |
| `PMDUMP` | the 16 KB ROM and 8 KB shared memory to a file. **Blanks the WiFi key by default** |
| `PMTICK` | the interrupt flag, the 8259 and the BIOS tick around one command. A diagnostic, kept because it is what found the `Intr` hang |
| `PMCMDT` | N queries in a row, D ticks apart, with no DOS calls between. The other half of that diagnosis |
| `PMIRQ` | hooks an interrupt, chains it and comes back. `/A` on the harmless timer hook first, `/B` on the card's own IRQ. The groundwork for a mouse driver, and nothing stays resident |

`PMMTEST` is deliberately not called `PMMOUSE`: it is a probe, and the card's
own distribution uses that name for an actual `INT 33h` driver. If one is ever
written here, `PMMOUSE` is the name it should have.

`build.cmd` builds them all; `build.cmd info`, `cfg`, `mem`, `dev`, `stat`,
`opl`, `bench`, `mouse`, `watch`, `dump`, `tick` and `cmdt` also run one on the
DOS machine over [DOSBridge](https://github.com/jdredd87/DOSBridge).

**`netdrv\`** is different in kind: the card's own packet driver,
`PM2000.COM`, rebuilt so an NEC V20/V30 copies packets with `REP INSB` /
`REP OUTSB` -- 21-26% faster on the V30, measured. It is Crynwr's GPL
source, not original work -- the changes are StevenC's and Claude's; its
README says what changed and how it builds.

## The thing this project found

**Where the card writes its text answers depends on the firmware, and
assuming it is a silent failure.**

The card answers three queries — USB devices, disk images, WiFi — not with a
return value but by writing text into a *parameter area* in the 8 KB of
shared memory it emulates just above its ROM. the first version of these tools have that
area at offset **886**, which is where the PicoMEM 2's BIOS of 2026-06-16
puts it, and were written before there was a second card to try.

The PicoMEM 1 here runs a BIOS of **2025-11-02**, and puts it at **374**.
The configuration block that sits between the two grew from 256 bytes to 768
at some point in between, and the answers moved with it. `886 = 82 + 768 +
36`, `374 = 82 + 256 + 36`; the arithmetic is the whole story.

What that looked like was not an error. `PMPROBE` reported

```
command 61 (USB status): ok, status 00, result 0000, 0 ms
USB: 0 line(s)
```

— a successful command, a healthy status, and no devices. It read the count
byte from an offset the firmware had never written, found a zero, and said
so. Every part of that is true and the conclusion is wrong.

So nothing here assumes it. `FindParam` in `pmcard.pas` **looks for it**:
the disk-status answer has a shape nothing else in the shared memory has —
a count byte, then that many strings, each of which the firmware builds as
`   HDDn : ...` and then overwrites the second character of with `FEh` for
its own menu, so a line starts `20 FE 20 "HDD"`. Find the first of those and
the count byte is the byte before it. It reports how many candidates it saw,
because the card's own boot-time menu leaves stale copies further up.

the first version of this unit now has the same routine, and `PMPROBE` and `PMUSB`
call it. On this card they now say

```
answers at +374 on this firmware, not +886
USB: 1 line(s)
  |   USB  : 0 devices
```

## What this card is, measured

A **PicoMEM 1 in a Gateway 2000 386SX/25** (MS-DOS 6.22, no 387), measured on
2026-09-20. Everything here has since been re-run with a **PicoMEM 2**, in
that machine and in the **NEC V30** box as well -- three configurations, and
the tools are identical across all of them. The card is the boot disk and carries the network, which is what
every hazard below is about.

The **same machine later took the PicoMEM 2**, so everything here has a
matching run on the newer card -- the comparison is further down, and the
short version is that it is not faster at anything. Which card is in which
machine is a fact with a date on it, and `PMINFO` reads the BIOS date out of
the ROM rather than inferring it.

```
BIOS      : answered -- base 02A0h, ROM D000h, devices 070Eh
test port : 100 of 100 reads in sequence -- a PicoMEM is at 02A0h
ROM       : 16 KB, signature ok, "PMBIOS"
BIOS date : 2025-11-02  (from the ROM itself)
  board       : not reported by this firmware (all three id bytes are 0)
  PSRAM       : code 08   SD card : ok
  USB host    : ok   config file : ok
  WiFi        : ok   base port : ok
  IRQ         : 7
  disks       : 1 at boot -> 4 mounted;  floppies 0 -> 0
  PC memory   : 639 KB
answers   : the parameter area is at +374  (the 2025-11-02 firmware)
```

**The board identifies itself as nothing.** `BoardID`, `PicoID` and the
firmware revision are all zero. That is not a prototype: the line that fills
them in (`BV_BoardID=BOARD_ID`) is newer than this BIOS, so the bytes are
simply untouched. the first version of these tools reads the zero and prints *"PicoMEM
prototype (id 0, pico id 0)"*, which is a confident answer to a question the
card did not answer. `PMINFO` says so instead.

### What it has mapped

```
             0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
  live       ....................................................Bd..........
  configured ssssssssssssssssssssssssssssssssssssssss......vvoo..BB......oooo
```

Two rows that look nothing alike, and both are right. The **configured** map
describes the whole megabyte, including the parts that are the PC's own —
`s` its RAM, `v` its video, `o` its ROM — because that is how the card's
firmware decides what it must *not* answer for. The **live** map is what the
card is emulating, and on this machine that is 32 KB: its own BIOS ROM at
`D000h` and, at `D400h`, the BIOS RAM and disk buffer, which is the shared
memory everything here reads. Nothing else in the first megabyte comes from
the card at all.

The one disagreement is `D400h`, configured as card BIOS and live as card
BIOS RAM: the configuration marks both halves of the 32 KB window as BIOS,
and the firmware distinguishes them once it is running.

### What is on its USB port

The host runs on the Pico's **native controller, root port 0**
(`CFG_TUH_RPI_PIO_USB 0`), which on a 1.x board is the micro-USB connector
— the same one the card is flashed through. With a thumb drive on a
micro-USB OTG adapter:

```
   USB  : 1 device
    1: USB Disk 979.5 MB USB 2.0  Flash Disk
```

That is a **named** line, and it settles what the blank ones mean. The
firmware writes a description only when one of its own class drivers claims
a device: HID, mass storage, MIDI, XInput pads — `CFG_TUH_CDC` and
`CFG_TUH_VENDOR` are both 0, so a USB Ethernet adapter or a camera is
enumerated and then ignored, and the empty line the PicoMEM 2 gave for an
Ethernet adapter meant *nothing claimed it*, not *nothing was seen*. Here
the mass storage driver claimed the drive, ran a SCSI inquiry for the vendor
and product strings, mounted its filesystem and reported its size.

**DOS does not get a new drive out of it.** The volume is mounted inside the
card as its own second filesystem, beside the SD card, where it is available
as a *source of disk images* rather than as a drive. `HWINFO` still reports
the same four, and the card's own disk list is unchanged.

`BV_USBDevice`, the byte `PMINFO` prints as "USB devices", stays `00`: it
tracks only mouse, keyboard and joystick, so a drive never appears in it.

### A USB mouse, all the way to the PC side

A mouse on the same port reports as `1: USB mouse`, and it does more than
report. The card's HID driver keeps an X delta, a Y delta and a button mask,
and once reporting is enabled it copies them into the **IRQ variable
structure** in its shared memory on every movement and raises its
multiplexed interrupt. Those bytes are readable from DOS with no driver at
all, which is what `PMMTEST` does:

```
answers at +374, so the IRQ variables are at +342
before : 00 00 00 00 00 00 04 00 00 00 00 00 00 00
enable mouse reporting (52h): ok
    2s  dx   -9  dy   -7  buttons 00
    2s  dx   -6  dy   -4  buttons 00
changes seen   : 163
deltas         : x -109 to 81, y -73 to 67
buttons seen   : 07
```

All three buttons, and deltas up to 109 counts in a single report. **The card
does deliver a working mouse to the PC side.** What it does not deliver is a
mouse to *DOS* — that needs an interrupt handler presenting `INT 33h`, which
is a driver rather than a probe. The card's own distribution has one; this
collection does not, yet, and `NEXT.md` says what it would take.

The control run matters as much as the result: with `/E-`, which sends
nothing at all, the same bytes sit at zero through the whole window. The
data only moves because the command was sent.

**`BV_USBDevice` stays `00` throughout** — the byte `PMINFO` prints under
"USB devices", which has bits defined for mouse, keyboard and joystick. The
firmware's own header says *"! Not used for the moment"*, and a claimed,
actively-reporting mouse leaving it at zero is that comment demonstrated.
An earlier draft of this project proposed checking that byte to see whether
a mouse had been claimed; it would never have worked, and the source said so
before the test did.

### The card's interrupt carries the mouse, and polling loses most of it

`PMMTEST` polls, and says so: its totals are a floor because the firmware
overwrites the three mouse bytes on every event and never accumulates.
`PMIRQ /B` hooks the card's own interrupt instead -- `BV_IRQ` says 7, so
`INT 0Fh` -- reads those bytes the moment the card raises it, and chains to
the card's BIOS handler so the acknowledge still happens.

| | events per second |
|---|---|
| polling, `PMMTEST` | about 14 |
| interrupt-driven, `PMIRQ /B` | **about 35** |

694 interrupts carried new data in twenty seconds. **Polling was catching
around 40% of the movement** -- fine for "does data arrive", useless for a
pointer, which is exactly what the tool warned it would be.

**Phase A exists because phase B can stop the machine.** Getting the chain
wrong on the card's IRQ means its interrupt is never acknowledged and the
8259 stays in service, taking the timer and the network down with it. So
`/A` does the identical thing to `INT 1Ch` -- the timer hook the BIOS
provides for the purpose, whose default handler is an IRET -- and counts:

```
  previous handler F000:7BE3
  ticks counted : 91   expected about 91
  the hook, the chain and the restore all work.
```

That proves FPC's `interrupt` procedures set DS up the way this code
assumes, that the chain works, and that the vector is restored, on an
interrupt where a mistake costs nothing. Only then is it worth pointing the
same machinery at the card.

The chain itself is one assembler block, and it has to be:

```pascal
asm
  pushf
  call dword ptr [OldVec]
end;
```

The old handler ends with `IRET`, which pops IP, CS **and the flags**, so the
flags must be on the stack for it. A plain far call would unbalance the
return and the machine would go somewhere random. One block, so nothing the
compiler emits can come between the `PUSHF` and the `CALL`.

### A USB keyboard: claimed, reported, and then nothing

The card claims a USB keyboard and says so -- `PMSTAT` prints `1: USB
keyboard` exactly as it does for a mouse. Nothing else happens, and the
firmware says why before the hardware does:

| | defined | actually used |
|---|---|---|
| `IRQ_R_MOUSE` | `isa_irq.h` | **raised**, `pm_cmd.cpp:2193` |
| `IRQ_R_KEYBOARD` | `isa_irq.h` | **nowhere** |
| `KEYB_Enabled` | declared, set true, set false | **never read** |

Command `54h` turns keyboard reporting on and off and its flag is consumed by
nothing at all; the interrupt source reserved for keystrokes is a `#define`
and no more. The published sources are also **newer** than the BIOS on this
card, so a feature missing there is certainly missing here.

Demonstrated rather than argued, and demonstrated properly: `PMWATCH /2`
runs **two identical windows**, one that asks you to hammer keys and one that
asks you to keep still, and takes the difference. That matters because the
card is the boot disk -- its saved registers and its disk buffer move on
every `INT 13h`, so a single window catches whatever disk traffic happened to
occur and one earlier run was muddied by exactly that.

With `54h` sent and accepted, 25 seconds each way:

```
changes per region, 25 seconds each:
     doing it   keeping still   difference   region
                  (the table is empty)
```

Not one byte, in either window. And the person typing "might have hit a few
keys when I should not have" during the still window -- which changes nothing,
because keystrokes in *either* window produced *nothing*. A slip that would
ruin a positive result cannot hurt a negative one; it only adds typing.

**Repeated on the PicoMEM 2**, with its newer 2026-06-16 firmware, on the
same machine: both windows empty again, and the watcher validated against the
same binary immediately afterwards at the new offset (17 changes, count byte
`02` to `04` at `+886`). Two cards, two firmwares, the same nothing.

That card also **describes a keyboard wrongly**. Where the PicoMEM 1 writes
`USB keyboard`, the PicoMEM 2 writes a single `02` byte and a NUL where a
name should be -- visible in the raw parameter area as
`"    1: " 02 00`, while the same firmware writes `Mouse` perfectly well for
a mouse. `PMSTAT` now says so rather than printing a bare dot and leaving
the reader to wonder whether the tool broke:

```
   USB  : 1 device
    1: .
    ^ no text there: the firmware wrote a byte that is not a name
```

**A null result is worth exactly what the instrument is worth**, so the same
tool has a `/T` that proves it can see a write: it asks for the USB list,
snapshots, then asks for the disk list mid-watch, and the two answers differ.
That reports 28 changed offsets from `+374` onwards, the count byte going
`02` to `04` as two USB lines become four disk lines. It is run against the
**same binary** that produced the silence, after it, every time -- a rebuilt
watcher is an unproven one.

One practical note before any of this works: **the cue is on the PC speaker**,
and on this machine the speaker turned out to be dead. Five sirens through the
DOSBridge kit's own `BEEP` tool produced silence, which exonerated the
software and condemned the hardware; a replacement fixed it. Until then there
was no way to know whether the person had typed during the window, which is
the difference between a measurement and a guess. The cues also print on
stderr, which the bridge does not redirect, so they land on the machine's own
screen as well.

That self-test earned its place immediately. Its **first** version sent the
same query twice and reported nothing at all -- re-asking rewrites
byte-for-byte identical text, and a watcher looking for changed *values*
cannot see a write that changes none. It would have handed back the
keyboard's "nothing changed" as a true negative, with a broken instrument
behind it.

### Which devices answer

```
PicoMEM 02A0h-02A7h: answers, 100 of 100 counting reads in sequence
  its IRQ is 7, its BIOS at D000h, its shared memory at D000:4000
AdLib  388h-389h : ANSWERS as an OPL2 (status 06 then C6)
                   and the card is configured to emulate one
NE2000           : configured at 0300h IRQ 3 -- NOT probed, see below
packet driver    : at interrupt 60h -- the NE2000 is in use
option ROMs between C000h and F000h
  C000h  32 KB
  D000h  16 KB   <- this PicoMEM
```

**There is a working AdLib in this machine and no sound card in it.** The
OPL2 detection is the one from the original manual — mask both timers, reset
the interrupt, read the status, run timer 1, read it again — and the card
passes it: `00` then `C0` in the bits that matter. `PMOPL` then plays a
scale through it.

Two details worth keeping. The status bytes come back `06` and `C6` rather
than `00` and `C0`: the emulation leaves the low bits set where a real OPL2
has them clear, which is invisible to any detection that masks with `E0` as
every one of them does, and visible to anything that compares the whole
byte. And the timer wait is counted in **reads of the chip's own port**, not
in BIOS ticks — a read is a bus cycle whatever the CPU is, so the same code
waits the same 80 microseconds on a V30 and on a 386, which is a
[requirement of this
codebase](https://github.com/jdredd87/DOSBridge/blob/main/CLAUDE.md) rather
than a nicety.

### The same tools on a PicoMEM 2, in the same machine

The PicoMEM 2 was swapped into this 386SX on 2026-09-20, which is the
comparison the numbers above were waiting for: one machine, one CPU, one bus,
two cards. Everything in this folder runs on it unchanged.

| | PicoMEM 1 | PicoMEM 2 |
|---|---|---|
| BIOS date, from the ROM | 2025-11-02 | 2026-06-16 |
| board id | not reported (0) | 11 |
| answers area | +886 would be wrong -- it is at **+374** | **+886** |
| AdLib status bytes | `06` then `C6` | `00` then `C0` |
| a mouse is described as | `USB mouse` | `Mouse` |
| a keyboard is described as | `USB keyboard` | a bare `02` byte -- not text |
| mouse deltas and buttons | yes | yes |
| keystrokes reaching the PC | none | none |
| blocks emulated | 2 (`D000h`, `D400h`) | the same 2 |
| card I/O port read | 129,228/s | 130,101/s |
| card RAM word read | 145,049/s | 145,114/s |
| card ROM word read | 145,114/s | 145,147/s |
| the PC's own RAM | 182,000/s | 182,097/s |
| command round trip | 98 us | 96 us |
| card RAM vs the PC's | 79% | 79% |

**The newer card is not faster, at anything, by any margin worth the word.**
Every row is inside 1%, and three of them inside a tenth of a percent -- on a
tool whose repeatability is 0.1%, so this is a real null and not a noisy one.
The PicoMEM 2 is an RP2350 at a higher clock than the 1's RP2040, and on this
machine it buys nothing: **the card's microcontroller is not the limit.**

**What the limit actually is took a third machine to settle, and the first
answer here was wrong.** This section originally concluded "what is being
measured is the ISA bus, not the microcontroller" -- an 8-bit cycle takes
what it takes, both cards answer within it, done. That explanation makes a
prediction: put the same card in a machine four times slower and the card's
rows should barely move, because the bus is the bus.

They moved. See below.

Two real differences did turn up, both in the firmware rather than the
silicon:

* **The answers area moved**, which is the whole story at the top of this
  file, and `FindParam` now has both directions confirmed on hardware --
  +374 on the older BIOS, +886 on the newer, neither of them assumed.
* **The OPL2 emulation got cleaner.** The PicoMEM 1 returns `06` and `C6`
  where a real chip returns `00` and `C0`; the PicoMEM 2 returns exactly
  `00` and `C0`. Invisible to any detection that masks with `E0`, as every
  correct one does -- and a trap for anything comparing whole bytes.
* **The device descriptions were reworded.** A mouse is `Mouse` on the
  2026-06-16 firmware and `USB mouse` on the 2025-11-02 one, while the
  published source of 2026-09-11 says `USB mouse` -- so the wording changed
  after the newer card's firmware was built. Small, and useful: it is
  independent evidence that the sources are newer than **both** firmwares,
  which is what the keyboard conclusion below rests on. Do not pattern-match
  on these strings; count the lines and read them.

**The mouse works identically on both cards.** 349 changes in 25 seconds
here, deltas to 65 counts, buttons reported -- the same end-to-end path, the
same three bytes in the IRQ variables, and the same missing last mile: DOS
still gets no pointer without an `INT 33h` driver.

And the thumb drive is named on both: `1: USB Disk 979.5 MB USB 2.0  Flash
Disk`. On the PicoMEM 2 that answer comes back through `PMPROBE` too, which
before this work read `USB: 0 line(s)` on the other card.

### The same card in a four-times-slower machine, and the prediction failing

`PMBENCH` with the PicoMEM 2 moved into the NEC V30 box, three runs again:

| | V30 | 386SX | ratio |
|---|---|---|---|
| card I/O port read | 36,173/s | 130,101/s | 3.6x |
| card RAM word read | 39,829/s | 145,114/s | 3.6x |
| card ROM word read | 39,829/s | 145,147/s | 3.6x |
| the PC's own RAM | 44,747/s | 182,097/s | 4.1x |
| command round trip | 407 us | 96 us | 4.2x |
| card RAM vs the PC's | **89%** | **79%** | |

The card's rows scaled with the CPU, almost exactly in step with the PC's own
memory. **If the ISA bus were the ceiling they would have held near 130,000
and the ratio would have gone far above 100%.** Instead the card tracked the
machine it was plugged into.

So the honest reading is that **the loop is CPU-bound on both machines**. The
card adds a modest fixed penalty per access -- 11% on the V30, 21% on the
386SX -- and otherwise keeps up with whatever the CPU can issue. Neither the
microcontroller nor the bus is the bottleneck anywhere in this table; the
thing issuing the reads is.

The ratio moving the *right* way is the confirmation: a fixed per-access cost
is a smaller share of a slower machine's loop, so the card looks relatively
better on the V30 (89%) than on the 386SX (79%). A bus ceiling predicts the
opposite.

One further correction. The original text called this "the same shape as the
finding in `CH375Net`, where a machine four to five times faster left the USB
packet rate exactly where it was. Twice now, the thing that looked like the
bottleneck was the bus." That comparison was wrong twice over: CH375Net's
ceiling is a genuine device limit -- one 64-byte packet per USB frame, which
really does not move with the CPU -- and this one is not a ceiling at all.
The CH375Net result is what a real ceiling looks like, and it is what makes
the difference visible here: **that** number held across machines, and this
one did not.

### What it costs to talk to

`PMBENCH` on the 386SX/25, timed off the BIOS tick, three runs agreeing to
better than a tenth of a percent:

| | per second |
|---|---|
| card I/O port read | 129,228 |
| card RAM word read | 145,049 |
| card ROM word read | 145,114 |
| the PC's own RAM, the same loop | 182,000 |
| whole command round trip | 10,252 — 98 microseconds each |

The card's emulated memory reads at **79%** of the speed of the PC's own,
which is the number that matters if you are thinking of using the card as
memory: a Pico answering an ISA cycle in software costs about a quarter more
than the RAM on the motherboard, and no more than that.

**All four rows use one identical loop**, with the segment *and* the offset
in variables, and getting there took two corrections that are worth knowing
about because both of them flattered the card:

* the first version read the PC's RAM through a Pascal array index and the
  card's through `MemW[]`. Those are different instruction sequences, so it
  was partly measuring the compiler.
* the second version used `MemW[]` for both, but wrote the card's offsets as
  *constant + i* and the PC's as *variable + i* — one extra addition per
  turn, on the PC's side only. It reported the card at 72% of the PC when it
  is really at 79%, and it made the card's **ROM look 5% faster than its
  RAM**, which is not a thing that can happen: the same chip answers both
  the same way. Those two numbers being equal now is the check that the
  instrument is straight.

Repeatability is much better than expected — three consecutive runs inside
0.1%, and a fourth set at a different tick budget agreeing to the same. One
early run came out 9–15% high across every row at once and has not
reproduced in seven attempts since; it is recorded here as a bad measurement
rather than a discovery, because a uniform shift on all rows is the
signature of the clock, not of anything the card did.

### Does a busy card cost the PC anything?

No, measurably. With a USB thumb drive mounted on the card — the firmware
running its USB stack and a FatFs volume on its second core — the card's RAM
reads and its command round trip are **within 0.5%** of the same figures
taken with nothing plugged in at all. `BENCH`, the CPU-only benchmark that
never touches the card, also matches this machine's recorded table row for
row (`248721` and `30321` and `297260` identical to the figures taken before
any of this work). The card does its own work on its own silicon and the PC
does not pay for it.

## How it talks to the card

The card answers on eight I/O ports at **2A0h** by default. The protocol,
read out of its firmware (`dev_picomem_io.cpp`) and its BIOS (`pm_hw.asm`):

| port | read | write |
|---|---|---|
| base+0 | status: 00 ready, 01 busy, 02 error, 03 no such command, 04 initialising | a command |
| base+1, +2 | a 16-bit result | a 16-bit argument |
| base+3 | **test port**: every read returns one more than the last | |
| base+4, +5 | a byte stream, during commands that move data | |

* **Finding it.** Its BIOS answers `INT 13h` with `AH=60h AL=0 DX=1234h` by
  returning `DX=AA55h`, `AX` the base, `BX` its ROM segment, `CX` a device
  mask. The test port then proves it: no other card counts.
* **Shared memory.** 8 KB the card emulates at ROM segment + 16 KB
  (`D000:4000` here): 32 bytes of BIOS variables, a disk parameter table, a
  saved-register area, the configuration, the IRQ mux variables, and a 2 KB
  parameter area that text answers are written into.
* **A command** is: wait for status 00, write the argument, write the
  command, wait for 00, read the result.

## Why DOS cannot drive a USB device through this card

It was the first question asked of the PicoMEM 2, and the answer is no --
not with the stock firmware, and nothing on the DOS side can change it.

The firmware's USB host is TinyUSB with class drivers for **HID, mass
storage, MIDI and game pads**, with `CFG_TUH_CDC 0` and `CFG_TUH_VENDOR 0`,
and **no command that reaches a device**: no descriptor read, no control
request, no endpoint open, no transfer. A device none of those drivers claims
is enumerated and then ignored, and the firmware keeps no VID, PID or
descriptor for it.

That is exactly what the device list shows, and why the distinction is
visible rather than theoretical:

| plugged in | what the card reports |
|---|---|
| USB thumb drive | `USB Disk 979.5 MB USB 2.0  Flash Disk` |
| USB mouse | `Mouse` (on the 2), `USB mouse` (on the 1) |
| USB keyboard | claimed, but the name is broken on the 2 -- see above |
| USB Ethernet adapter | **a blank line** -- seen, not claimed |
| IBM PC Camera | the same |

So a CH375 at 260h remains the only way this collection drives an arbitrary
USB device from DOS. What it would take to change that is in `NEXT.md`.

## Hazards — read before adding a command

**The card is the boot disk.** DOS boots from a disk image on its SD card,
and every sector DOS reads is a command on the same port these tools use. A
command left stuck is a disk that no longer answers. So `pmcard.pas` will
send only five commands — reset-status, the memory-type query, and the USB,
disk and WiFi status queries — and **refuses every other command number in
the one routine that writes the port**, rather than by convention. Every
wait has a deadline; the card's own library spins forever. Nothing calls DOS
while a command is in flight, because a `WriteLn` to a redirected stdout is
itself a disk command.

**Command 05h is on that list because its handler was read, not because it
sounded safe.** It looks one entry up in a table and returns; it writes
nothing, mounts nothing, opens no file. `PMMEM` still asks for **one** block
first — `D000h`, where this card's own BIOS is, so the answer is known — and
stops if it comes back as anything else. Sixty-four commands into a firmware
whose numbering you have not checked is not a first move.

**`PMSTAT /W` can drop the network.** The WiFi query makes the firmware
retry the connection if it thinks the signal has gone, and on a machine
administered over that WiFi a retry is a dropped link. Off by default. It
was run here, once, deliberately, with a smart plug within reach.

**Two commands here are not queries**, and they are the only two: `52h` and
`53h`, mouse reporting on and off. Each handler is three lines -- set a
boolean, clear the result, return ready -- so neither writes a file, mounts
anything, moves memory or saves configuration, and neither can reach the SD
card. `PMMTEST` sends the disable on every exit path, so the card is left as
it was found. Everything else in both PicoMEM projects is a pure query, and
a third non-query needs its handler read the same way first.

**The WiFi key is in the shared memory.** The same query copies a structure
in that holds the network's name *and its key*, 63 bytes at +39, and it
stays there until something overwrites it. `PMSTAT` reads the SSID at +6
and the status text at +102 and never the bytes between them; `PMDUMP`
zeros them unless you pass `/K`. A dump is a file that gets copied about.

**The NE2000 is never probed.** It carries the network the card is being
administered over and its registers are paged, so a read is not harmless.
`PMDEV` looks for the packet driver's `PKT DRVR` signature in the interrupt
vector table instead, which proves the same thing by reading memory.

**`PMMEM /W` writes one byte per block, and only above C000h, and never
into the card's own window.** Below C000h is the PC's own RAM with DOS and
the running program in it, and block 0 is the interrupt vector table. The
card's window is excluded for the same kind of reason: its second half is
the shared memory, and the first byte of that is the marker its BIOS checks
to decide the memory is valid. Putting it back a microsecond later is not
good enough on the card the machine boots from. Those blocks read `-` and
`B` in the output rather than a result.

What it reports on this machine, above C000h: `R` at `C000h` and `D000h`
(option ROM signatures -- the VGA BIOS and the PicoMEM's own), `o` at
`C400h` and `F000h`-`F800h` (reads, will not take a write), `B` at `D400h`,
and `.` everywhere else including `FC00h`, which reads as FFh on this
Gateway.

## Files

| | |
|---|---|
| `src/pmcard.pas` | the card: detection, the command whitelist, the shared memory, and the search for the parameter area |
| `src/pminfo.pas`, `pmcfg.pas`, `pmmem.pas`, `pmdev.pas` | what it is, what it is set to, what it has mapped, what answers |
| `src/pmstat.pas`, `pmopl.pas`, `pmbench.pas`, `pmdump.pas` | its answers, its AdLib, its speed, its memory in a file |
| `src/pmmtest.pas`, `pmwatch.pas` | the mouse path, and the whole-memory watcher |
| `src/pmcmdt.pas`, `pmtick.pas` | the two diagnostics that found the `Intr` hang, kept because the hang is the kind that recurs |
| `NEXT.md` | what is left, and what would need firmware |

---

Written by **StevenC** and **Claude** (Anthropic): StevenC guiding, deciding and testing on real hardware, Claude doing most of the analysis, code and measurement.
