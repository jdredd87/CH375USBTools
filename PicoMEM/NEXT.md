# Picking this up next

Written 2026-09-20, at the end of the first session on the PicoMEM cards. For
whoever continues it, including a fresh Claude Code instance.

## Read these first

1. **This file.**
2. **`README.md`** — the tools, what was measured, and the hazards. The
   hazard section is why nothing here has touched the boot disk.
3. **`src/pmcard.pas`'s header** — the rules every command obeys, and why
   the parameter area is searched for rather than assumed.
4. The card's sources, for reference only (GPLv2 — read, do not copy):
   https://github.com/FreddyVRetro/ISA-PicoMEM. The files that matter:
   `src/pm_cmd.cpp` (every command handler; read the one you intend to
   send), `src/pm_defines.h` (command numbers, the shared-memory layout,
   `BIOSVAR_t` and `PMCFG_t`), `src/isa_devices/dev_memory.h` (the memory
   type codes), `src/pm_boards/pm.h` (this board family), `src/pm_libs/
   pm_apps.cpp` (the card's own setup screen — it prints most of what
   `PMCFG` and `PMDEV` print, which is how the port numbers were checked).

## State, 2026-09-20

**Works, on the hardware:** all eight tools, on a PicoMEM 1 with the BIOS of
2025-11-02 in a Gateway 2000 386SX/25. Detection, the full configuration,
the live memory map through command 05h, the emulated-device probe, all
three text answers including WiFi, the AdLib scale, the benchmark, and a
dump pulled back to Windows and checked byte for byte.

**Found and fixed:** the parameter area moves between firmwares, so
the first version of these tools reported nothing at all on the older card
while reporting success. `FindParam` now locates it, and both offsets are
confirmed on hardware. See the README.

**PMWATCH exists**, and it is the tool to reach for whenever the question is
"does anything happen, and where?" -- it watches all 8 KB rather than a place
somebody guessed. Its `/T` self-test is not decoration: the first version of
it sent one query twice, rewrote identical bytes and reported nothing, which
would have made a broken watcher look like a true negative.

**The USB host works.** A thumb drive on a micro-USB OTG adapter came back
as `1: USB Disk 979.5 MB USB 2.0  Flash Disk` — a named line, which settles
that the blank line an Ethernet adapter gives means *unclaimed*, not
*unseen*. The host is the Pico's native controller on root port 0, which on
this board is the micro-USB connector it is flashed through. DOS gets no new
drive from it: the card mounts the volume inside itself as a source of disk
images. See the README.

**A USB mouse works, as far as the PC side.** Enabled with command 52h, the
card copies an X delta, a Y delta and a button mask into its IRQ variables
on every movement: 163 changes in 25 seconds, deltas to 109 counts, all
three buttons. `PMMTEST` is the tool and the README has the output. The
control run with `/E-` shows the same bytes never move when nothing is sent.
`BV_USBDevice` stays 00 throughout, exactly as the firmware's own "not used
for the moment" comment says it would.

## Ideas not done

* **An INT 33h driver, so DOS gets a pointer.** The obvious next piece of
  real work, and squarely what this collection does: `CH375Mouse` is the
  same job for the CH375 and a good deal harder, since it has to run the
  whole USB stack itself. Here the card has already done everything except
  the last step.

  **Checked on the hardware 2026-09-20, before writing anything:**

  | | |
  |---|---|
  | `INT 33h` | `0032:40D2` -- **not a driver.** That points into low memory below DOS; it is an uninitialised vector. Nothing serves the mouse interface |
  | `INT 0Fh` (IRQ 7) | `D000:2C1E` -- **the card's own BIOS ROM.** The card installs and services its multiplexed interrupt already |

  So the card's BIOS owns the IRQ and does *not* provide INT 33h, which
  settles the design: **chain, do not replace.** Hook INT 0Fh, read
  `mouse_x`, `mouse_y` and `mouse_b` out of the IRQ variables FIRST,
  accumulate, then jump to the BIOS handler at the saved vector so its own
  acknowledge still happens. Then serve INT 33h functions 0, 3, 4, 7, 8
  and 11.

  Polling instead of chaining does not work well enough: the firmware
  overwrites those three bytes on every event and does not accumulate, so
  anything slower than the report rate silently loses movement. `PMMTEST`
  polls and says so -- its totals are a floor, not a total -- which is fine
  for "does data arrive" and useless for a pointer.

  **The non-resident prototype is done: `PMIRQ`, 2026-09-20.** `/A` proved
  the mechanism on `INT 1Ch` (91 ticks of an expected 91), `/B` then hooked
  the card's IRQ 7, chained to its BIOS handler at `D000:2C1E`, and counted
  **694 interrupts carrying new data in twenty seconds** -- about 35 events
  a second where polling saw 14. The chain, the restore and the card all
  survived. What is left is the resident part: a TSR that keeps the
  accumulators, serves `INT 33h`, and unhooks on request.

  The card's own distribution has such a driver (`PMMOUSE`), so it is known
  to be possible; this would be ours, and it would work on either card
  unchanged. Read `CH375Mouse`'s resident structure first -- it already
  solves the INT 33h half.

  One hazard already visible: that garbage `INT 33h` vector is **non-zero**,
  and the usual way a program tests for a mouse driver is exactly that. Any
  driver we write should install a proper handler rather than assume the
  vector is free, and anything that probes for a mouse should check the
  handler really answers function 0 rather than trusting the vector.
* ~~A USB keyboard.~~ **Answered: this firmware has no keyboard path at
  all.** The card claims the device and reports `1: USB keyboard`, but
  `KEYB_Enabled` -- the flag command 54h sets -- is read by nothing, and
  `IRQ_R_KEYBOARD` is defined in a header and raised nowhere, where
  `IRQ_R_MOUSE` is raised and works. Demonstrated with 54h sent and
  accepted, using `PMWATCH /2` -- two identical 25-second windows, one
  typing and one still, because the card is the boot disk and its own disk
  traffic moves bytes whatever anyone does. Both windows came back empty,
  with the watcher validated on the same binary immediately afterwards.
  **Repeated on the PicoMEM 2 and its 2026-06-16 firmware, same result** --
  two cards, two firmwares, the same nothing. That card also writes a bare
  `02` byte where a keyboard's name should go, which is a firmware bug and
  not a reading error. Nothing on the DOS side can change that;
  it needs firmware, like everything else in the last section.
* **A hub.** `CFG_TUH_HUB` is 1 and nothing has ever tested one. Two devices
  at once would also exercise the multi-line answer, which has only ever
  been seen with a single entry.
* **The AdLib, heard rather than detected.** `PMOPL` proves the OPL2
  answers and plays a scale, and nothing on the DOS side can tell whether a
  sound came out — the card's audio output is its own hardware. Somebody
  with ears, or with the audio side of `doscap` wired to the card rather
  than to the PC's own video capture, could close that loop.
* **The other emulated sound cards.** This card has Tandy, CMS, Sound
  Blaster, Mindscape, Covox, MPU and GUS all configured off, so `PMDEV`
  reports them off and probes nothing. Turning one on means the card's setup
  screen at the keyboard, and then `PMDEV` should find it at the port
  `PMCFG` names. Worth doing once to prove the detection, and it is the one
  thing here that needs a human at the machine.
* **EMS.** Also off. The firmware's port list is `268h`, `288h`, `298h`,
  `2A8h` with a window at `D000h` or `E000h` — and **none of them is 260h**,
  which is the one number that matters, because that is where the CH375 card
  lives and anything else there corrupts its reads. So a PicoMEM's EMS and a
  CH375 can share a machine. That is worth knowing and has not been tested.
* ~~`PMBENCH` against the PicoMEM 2.~~ **Done, 2026-09-20, in the same
  386SX.** Every row inside 1%, three of them inside a tenth of a percent:
  the RP2350 buys nothing, because the measurement is of the ISA bus and not
  of the microcontroller. The README has the table. What the newer firmware
  did change: the answers area (+374 to +886) and a cleaner OPL2 status.
* **The 8259 and the card's IRQ.** `BV_IRQ` says 7 and nothing here watches
  it. The card fires a multiplexed interrupt for its own purposes; a tool
  that counted them over a minute would say whether it is idle.

## What would need firmware, and does not belong in these tools

Everything about driving a USB device through the card. The stock firmware
enumerates a device and then ignores it unless one of its class drivers
claims it: there is no command that reads a descriptor, sends a control
request or opens an endpoint. That is not a DOS-side problem and no tool in
this folder can work around it.

### The proposal: a USB pass-through in the card's firmware

A small command group in the unused range **C0h-CFh**, answering into the
2 KB parameter area so no new transport is needed:

| cmd | does | answer |
|---|---|---|
| C0h | list devices | per address: VID, PID, class, whether a firmware driver claimed it |
| C1h | get a descriptor (device, config, string) | the bytes |
| C2h | control transfer, setup packet in the parameter area | status, data |
| C3h | open a bulk or interrupt endpoint | status |
| C4h | bulk/interrupt transfer, up to 1 KB | status, length, data |

TinyUSB's host API already has each piece: `tuh_vid_pid_get`,
`tuh_descriptor_get_*_sync`, `tuh_control_xfer`, `tuh_edpt_open`,
`tuh_edpt_xfer`. An unclaimed device's endpoints can be opened directly.
With that in place every CH375 driver's USB layer maps onto five commands,
and the PicoMEM gives what the CH375 cannot: full speed with no 64-byte
buffer, 1 KB per command, and PSRAM on the far side -- enough for a camera's
whole frame, which is exactly what `CH375Camera` could not do.

Replacing the firmware is proven: **PicoGraph**
(https://github.com/ianhan/picograph) turns a PicoMEM 2 into a video card
through a USB DisplayLink adapter on the same port.

### Why it has not been done

* **Flashing needs hands.** The Pico is flashed over USB with the BOOT
  button held. A firmware that fails to start takes the boot disk AND the
  DOSBridge network with it until someone reflashes the stock image -- keep
  the published `.uf2` beside any test build.
* **There is no ARM toolchain on the build PC**: no `arm-none-eabi-gcc`,
  `cmake` or pico-sdk, and the firmware expects its own TinyUSB copy
  (`PrepareTinyUSB.sh`).
* The configuration and disk images live on the SD card and are read at
  boot. A test build must leave the SD code exactly as it is.
* **Neither card runs a build of today's sources.** The 2025-11-02 and
  2026-06-16 BIOSes are both older than the 2026-09-11 tree -- which the
  device-name wording proves independently, since the sources say
  `USB mouse` where the 2026-06-16 firmware says `Mouse`. Build the stock
  firmware unmodified and compare it with the published image before
  changing a line.

### The order to do it in

1. Install the toolchain; build the **stock** firmware and compare with the
   published `.uf2`. A build that differs before any change is not a base.
2. Add C0h only (list devices). Flash with somebody at the machine, and
   check it still boots and DOSBridge still answers before anything else.
3. `PMSTAT` learns C0h: a real VID:PID for a device the firmware ignores.
4. Then C1h-C4h, and a port of `CH375USBTOOLS`' `USBINFO` onto them.
