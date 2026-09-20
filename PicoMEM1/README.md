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

`PM1BENCH` on the 386SX/25, timed off the BIOS tick:

| | per second |
|---|---|
| card I/O port read | 134,663 |
| card RAM word read | 179,896 |
| card ROM word read | 189,538 |
| the PC's own RAM, the same loop | 247,325 |
| whole command round trip | 11,372 — 88 microseconds each |

The card's emulated RAM reads at **72%** of the speed of the PC's own, which
is the number that matters if you are thinking of using it as memory: a Pico
answering an ISA cycle in software costs about a third more than the RAM on
the motherboard, and no more than that. The memory rows use identical
far-pointer addressing so that the only difference left is which chip
answers the bus cycle — the first version compared `MemW[]` against a Pascal
array index and was measuring the compiler, not the card.

Expect a few percent of run-to-run variation. The Pico has a second core
doing SD and WiFi work that nothing on the DOS side can see or schedule
around.

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

**The WiFi key is in the shared memory.** The same query copies a structure
in that holds the network's name *and its key*, 63 bytes at +39, and it
stays there until something overwrites it. `PM1STAT` reads the SSID at +6
and the status text at +102 and never the bytes between them; `PM1DUMP`
zeros them unless you pass `/K`. A dump is a file that gets copied about.

**The NE2000 is never probed.** It carries the network the card is being
administered over and its registers are paged, so a read is not harmless.
`PM1DEV` looks for the packet driver's `PKT DRVR` signature in the interrupt
vector table instead, which proves the same thing by reading memory.

**`PM1MEM /W` writes one byte per block, and only above C000h.** Below that
is the PC's own RAM with DOS and the running program in it, and block 0 is
the interrupt vector table, where a byte wrong for a microsecond is a machine
that stops.

## Files

| | |
|---|---|
| `src/pm1card.pas` | the card: detection, the command whitelist, the shared memory, and the search for the parameter area |
| `src/pm1info.pas`, `pm1cfg.pas`, `pm1mem.pas`, `pm1dev.pas` | what it is, what it is set to, what it has mapped, what answers |
| `src/pm1stat.pas`, `pm1opl.pas`, `pm1bench.pas`, `pm1dump.pas` | its answers, its AdLib, its speed, its memory in a file |
| `NEXT.md` | what is left, and what would need firmware |
