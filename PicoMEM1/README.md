# PicoMEM1

**Reading a PicoMEM 1.x card from real-mode DOS: what it is, what it has
mounted, what it has mapped over your memory, which of its emulated devices
are actually answering, and what it costs to talk to.**

The [PicoMEM](https://github.com/FreddyVRetro/ISA-PicoMEM) is an 8-bit ISA
card with a Raspberry Pi Pico on it that emulates memory, disks, sound cards
and — on a Pico W — an NE2000 over WiFi. The **PicoMEM 1** is the original
family (1.0 through 1.14, plus the Low Profile and 1.2A); the PicoMEM 2 is
the RP2350 board with the USB-A host port, and it has [its own project
here](../PicoMEM2/). The two speak the same protocol on the same ports, so
most of what is in both folders works on either card — but not all of it
did, and the differences turned out to be the interesting part.

One of the projects in [CH375USBTools](../README.md), and, like its sibling,
not about the CH375 at all. Written in Pascal from reading the card's
published firmware and BIOS sources (GPLv2); no code is taken from them, and
nothing here is a port of anything.

## Tools

| | |
|---|---|
| `PM1INFO` | what the card is and how it came up: BIOS date out of the ROM, every init state, IRQ, disk counts, and where this firmware writes its answers |
| `PM1CFG` | the whole configuration: disk and ROM images, the memory map, EMS, boot options, NE2000, and every sound card it is set to emulate. Sends one query and changes nothing |
| `PM1MEM` | the **live** memory map — 64 blocks of 16 KB asked one at a time — beside the configured one. `/W` also asks the PC what it sees at each block |
| `PM1DEV` | which emulated devices really answer, from the PC side: the card's own port, an OPL2's timers, the packet driver on its NE2000, the joystick, the RTC, and every option ROM in the upper memory area |
| `PM1STAT` | the three text answers — disks with their geometry, the USB device list, and `/W` the WiFi state. `/S=n` watches the USB list for n seconds |
| `PM1OPL` | plays a scale through the AdLib the card emulates, after proving an OPL2 is there by its timers |
| `PM1BENCH` | what the card costs: port reads, its RAM and ROM against the PC's own, and a whole command round trip |
| `PM1MOUSE` | turns on the card's mouse reporting, watches the deltas and buttons arrive in its shared memory while you move a USB mouse, and turns it off again. **Beeps** when it wants your hand on the mouse |
| `PM1DUMP` | the 16 KB ROM and 8 KB shared memory to a file. **Blanks the WiFi key by default** |

`build.cmd` builds them all; `build.cmd info`, `cfg`, `mem`, `dev`, `stat`,
`opl`, `bench` and `dump` also run one on the DOS machine over
[DOSBridge](https://github.com/jdredd87/DOSBridge).

## The thing this project found

**Where the card writes its text answers depends on the firmware, and
assuming it is a silent failure.**

The card answers three queries — USB devices, disk images, WiFi — not with a
return value but by writing text into a *parameter area* in the 8 KB of
shared memory it emulates just above its ROM. PicoMEM2's tools have that
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

So nothing here assumes it. `FindParam` in `pm1card.pas` **looks for it**:
the disk-status answer has a shape nothing else in the shared memory has —
a count byte, then that many strings, each of which the firmware builds as
`   HDDn : ...` and then overwrites the second character of with `FEh` for
its own menu, so a line starts `20 FE 20 "HDD"`. Find the first of those and
the count byte is the byte before it. It reports how many candidates it saw,
because the card's own boot-time menu leaves stale copies further up.

PicoMEM2's `pmcard.pas` now has the same routine, and `PMPROBE` and `PMUSB`
call it. On this card they now say

```
answers at +374 on this firmware, not +886
USB: 1 line(s)
  |   USB  : 0 devices
```

## What this card is, measured

A **PicoMEM 1 in a Gateway 2000 386SX/25** (MS-DOS 6.22, no 387), which is
the machine DOSBridge is currently driving. The card is the boot disk and
carries the network, which is what every hazard below is about.

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
simply untouched. PicoMEM2's `PMPROBE` reads the zero and prints *"PicoMEM
prototype (id 0, pico id 0)"*, which is a confident answer to a question the
card did not answer. `PM1INFO` says so instead.

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

`BV_USBDevice`, the byte `PM1INFO` prints as "USB devices", stays `00`: it
tracks only mouse, keyboard and joystick, so a drive never appears in it.

### A USB mouse, all the way to the PC side

A mouse on the same port reports as `1: USB mouse`, and it does more than
report. The card's HID driver keeps an X delta, a Y delta and a button mask,
and once reporting is enabled it copies them into the **IRQ variable
structure** in its shared memory on every movement and raises its
multiplexed interrupt. Those bytes are readable from DOS with no driver at
all, which is what `PM1MOUSE` does:

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

**`BV_USBDevice` stays `00` throughout** — the byte `PM1INFO` prints under
"USB devices", which has bits defined for mouse, keyboard and joystick. The
firmware's own header says *"! Not used for the moment"*, and a claimed,
actively-reporting mouse leaving it at zero is that comment demonstrated.
An earlier draft of this project proposed checking that byte to see whether
a mouse had been claimed; it would never have worked, and the source said so
before the test did.

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
passes it: `00` then `C0` in the bits that matter. `PM1OPL` then plays a
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

### What it costs to talk to

`PM1BENCH` on the 386SX/25, timed off the BIOS tick, three runs agreeing to
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

## Hazards — read before adding a command

**The card is the boot disk.** DOS boots from a disk image on its SD card,
and every sector DOS reads is a command on the same port these tools use. A
command left stuck is a disk that no longer answers. So `pm1card.pas` will
send only five commands — reset-status, the memory-type query, and the USB,
disk and WiFi status queries — and **refuses every other command number in
the one routine that writes the port**, rather than by convention. Every
wait has a deadline; the card's own library spins forever. Nothing calls DOS
while a command is in flight, because a `WriteLn` to a redirected stdout is
itself a disk command.

**Command 05h is on that list because its handler was read, not because it
sounded safe.** It looks one entry up in a table and returns; it writes
nothing, mounts nothing, opens no file. `PM1MEM` still asks for **one** block
first — `D000h`, where this card's own BIOS is, so the answer is known — and
stops if it comes back as anything else. Sixty-four commands into a firmware
whose numbering you have not checked is not a first move.

**`PM1STAT /W` can drop the network.** The WiFi query makes the firmware
retry the connection if it thinks the signal has gone, and on a machine
administered over that WiFi a retry is a dropped link. Off by default. It
was run here, once, deliberately, with a smart plug within reach.

**Two commands here are not queries**, and they are the only two: `52h` and
`53h`, mouse reporting on and off. Each handler is three lines -- set a
boolean, clear the result, return ready -- so neither writes a file, mounts
anything, moves memory or saves configuration, and neither can reach the SD
card. `PM1MOUSE` sends the disable on every exit path, so the card is left as
it was found. Everything else in both PicoMEM projects is a pure query, and
a third non-query needs its handler read the same way first.

**The WiFi key is in the shared memory.** The same query copies a structure
in that holds the network's name *and its key*, 63 bytes at +39, and it
stays there until something overwrites it. `PM1STAT` reads the SSID at +6
and the status text at +102 and never the bytes between them; `PM1DUMP`
zeros them unless you pass `/K`. A dump is a file that gets copied about.

**The NE2000 is never probed.** It carries the network the card is being
administered over and its registers are paged, so a read is not harmless.
`PM1DEV` looks for the packet driver's `PKT DRVR` signature in the interrupt
vector table instead, which proves the same thing by reading memory.

**`PM1MEM /W` writes one byte per block, and only above C000h, and never
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
| `src/pm1card.pas` | the card: detection, the command whitelist, the shared memory, and the search for the parameter area |
| `src/pm1info.pas`, `pm1cfg.pas`, `pm1mem.pas`, `pm1dev.pas` | what it is, what it is set to, what it has mapped, what answers |
| `src/pm1stat.pas`, `pm1opl.pas`, `pm1bench.pas`, `pm1dump.pas` | its answers, its AdLib, its speed, its memory in a file |
| `NEXT.md` | what is left, and what would need firmware |
