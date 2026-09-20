# PicoMEM2

**Talking to a PicoMEM 2 card from real-mode DOS: what it is, what it has
mounted, and what is plugged into its USB port.**

The [PicoMEM](https://github.com/FreddyVRetro/ISA-PicoMEM) is an 8-bit ISA
card with a Raspberry Pi RP2350 on it that emulates memory, disks, sound
cards and an NE2000 over WiFi. The PicoMEM 2 adds a USB-A host port. This
project reads the card from DOS through its own command port, with tools
written here in Pascal; the card's published firmware and BIOS sources were
read to learn the protocol, and nothing is copied from them.

One of the projects in [CH375USBTools](../README.md), and the first that is
not about the CH375; [PicoMEM1](../PicoMEM1/) is the other, for the older
card, and it is where the memory map, the emulated devices and the timings
are gone into properly. The two share a protocol and not a unit. the question it starts from is whether the PicoMEM's
USB host could do what the CH375 does -- let DOS drive a USB device itself.
**Through the stock firmware, it cannot**, and why is below.

## Tools

| | |
|---|---|
| `PMPROBE` | find the card, prove it, decode its shared memory (board, init states, memory map, disk images), and ask for the USB device list. `/D` disk summary, `/W` WiFi state (read the caution), `/X` hex dumps, `/U-` sends nothing at all |
| `PMUSB` | the USB device list; `/S=n` watches it for n seconds and prints each change, for plugging things in and out |
| `PMDUMP` | the card's 16 KB BIOS ROM and 8 KB shared memory to a file, for reading on Windows |
| `PMCMDT` | N queries in a row, D ticks apart, no DOS calls between -- the test that cleared the card of a hang it did not cause |
| `PMTICK` | the interrupt flag, the 8259 and the BIOS tick around one command -- the instrument that found that hang |

`build.cmd` builds them all; `build.cmd probe`, `usb`, `dump` and `tick`
also run one on the DOS machine over DOSBridge.

## What it found on this machine

The card read here is a **PicoMEM 2 in the 8086-class box** (NEC V30, MS-DOS
6.22). The other machine in use, a Gateway 2000 386SX/25, has a PicoMEM **1**
in it -- these tools work on either, but the board id and firmware below are
the 2's.

```
BIOS     : answered INT 13h AH=60h -- base 02A0h, ROM at D000h, device mask 070Eh
test port: 100 of 100 reads in sequence -- a PicoMEM is at 02A0h
  board       : PicoMEM 2, a later id than the published list (id 11, pico id 0)
  SD card     : ok        USB host : ok        WiFi : ok
  memory map : 0   1   2   3   4   5   6   7   8   9   A   B   C   D   E   F
               ssssssssssssssssssssssssssssssssssssssss......vvoo..BB......oooo
  disk 0      : cdrive  (255 MB)      ... and devdrive, devdrive2, devdrive3
command 61 (USB status): ok
  |   USB  : 1 device
  |
```

The ROM identifies itself as the **PicoMEM 2 BIOS of 2026-06-16**, the one
shipped with firmware PM2-6-21-26.

**The USB-A port** had a USB Ethernet adapter in it (an SR9700 clone), and
the card reports **one device with an empty description**. That is not a
fault: a description is only written when one of the firmware's class
drivers claims the device -- HID (mouse, keyboard, joystick), mass storage,
MIDI, game pads -- and nothing claims a network adapter or a camera. The
firmware keeps no USB ID or descriptor for a device it did not claim, and
has no command that returns one.

**The USB-C port** had the IBM PC Camera in it, through a C-to-A adapter,
and the card does not see it at all. USB-C is the RP2350's own port -- the
one its firmware is flashed through -- and in this firmware it is not a
host port. The source shows a single USB controller, configured as host on
root port 0 (`CFG_TUH_RPI_PIO_USB 0`), and refusing to start the host when
USB serial debugging is on; the board itself is not documented.

## How it talks to the card

The card answers on eight I/O ports at **2A0h** by default. The protocol,
from its firmware (`dev_picomem_io.cpp`) and BIOS (`pm_hw.asm`):

| port | read | write |
|---|---|---|
| base+0 | status: 00 ready, 01 busy, 02 error, 03 no such command, 04 initialising | a command |
| base+1, +2 | a 16-bit result | a 16-bit argument |
| base+3 | **test port**: every read returns one more than the last | |
| base+4, +5 | a byte stream, during commands that move data | |

* **Finding it.** Its BIOS answers `INT 13h` with `AH=60h AL=0 DX=1234h`
  by returning `DX=AA55h`, `AX` the base, `BX` its ROM segment, `CX` a
  device mask. The test port then proves it: no other card counts.
* **Shared memory.** 8 KB of RAM the card emulates at ROM segment + 16 KB
  (`D000:4000` here): 32 bytes of BIOS variables (init states, board and
  firmware IDs), the card's configuration at +82 (disk image names and
  geometry, memory map, NE2000 port), and a 2 KB parameter area that text
  answers are written into.
* **Where that parameter area starts depends on the firmware, and this
  project assumed it.** +886 is right for the PicoMEM 2's BIOS of
  2026-06-16. The PicoMEM 1's of 2025-11-02 puts it at +374, because the
  configuration block between them grew from 256 bytes to 768: `886 = 82 +
  768 + 36`, `374 = 82 + 256 + 36`. Run against that card, `PMPROBE` read a
  count byte the firmware had never written and reported `USB: 0 line(s)`
  after a command that had plainly succeeded -- a true sentence and a wrong
  conclusion. `FindParam` in `pmcard.pas` now looks for it instead, and
  `PMPROBE` and `PMUSB` call it; [PicoMEM1's README](../PicoMEM1/README.md)
  explains how it is found.
* **A command** is: wait for status 00, write the argument, write the
  command, wait for 00, read the result.

## Hazards -- read before adding a command

**The card may be the boot disk.** On this machine it is: DOS boots from a
disk image on the card's SD card, and every sector DOS reads is a command
on the same port. A command left stuck is a disk that no longer answers.
So `pmcard.pas` will only send four commands -- reset-status and the USB,
disk and WiFi status queries -- and refuses every other command number in
the one routine that writes the port. Every wait has a deadline; the
card's own library spins forever. Nothing calls DOS while a command is in
flight, because a `WriteLn` to a redirected stdout is itself a disk command.

**`/W` can drop the network.** The WiFi query retries the connection if the
firmware thinks the signal is gone. On a machine administered over that
WiFi -- this one -- a retry is a dropped link. Off by default.

**`Intr` with a cleared `Registers` turns interrupts off.** The first
`PMUSB` wedged the machine three times in a row, each time on its second
USB query, and each time it looked like the card had hung. It had not. FPC's
`Intr` loads `Registers.Flags` into the CPU before the interrupt, the record
had been cleared with `FillChar`, and the card's BIOS returns with `IRET` --
so `INT 13h AH=60h` came back with interrupts off and the BIOS tick stopped.
Every wait measured in ticks then lasted for ever. `PMPROBE` survived only
because it never waited on the clock.

It took three instruments to settle, in this order: `PMCMDT` showed two
queries back to back were fine and ten spaced a second apart were not --
time, not traffic; `PMTICK` then showed `IF=0` **in its control run, with
no command sent at all**, which put the fault before the first command.
`AskBios` now passes the live flags in and restores interrupts afterwards.
`CH375Fossil` and `CH375Combo` also call `Intr` with a cleared record and
have not been checked for the same thing.

## Files

| | |
|---|---|
| `src/pmcard.pas` | the card: detection, the command whitelist, shared memory |
| `src/pmprobe.pas`, `pmusb.pas`, `pmdump.pas` | the tools |
| `src/pmcmdt.pas`, `pmtick.pas` | the two diagnostics that found the hang |
| `NEXT.md` | where this goes next: talking to USB devices needs our own firmware |
