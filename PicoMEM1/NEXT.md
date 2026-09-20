# Picking this up next

Written 2026-09-20, at the end of the first session on the PicoMEM 1. For
whoever continues it, including a fresh Claude Code instance.

## Read these first

1. **This file.**
2. **`README.md`** — the tools, what was measured, and the hazards. The
   hazard section is why nothing here has touched the boot disk.
3. **`src/pm1card.pas`'s header** — the rules every command obeys, and why
   the parameter area is searched for rather than assumed.
4. **`../PicoMEM2/README.md`** — the sibling project, same protocol,
   different card. Its `NEXT.md` holds the firmware plan, which applies to
   the 2 and not to this board.
5. The card's sources, for reference only (GPLv2 — read, do not copy):
   https://github.com/FreddyVRetro/ISA-PicoMEM. The files that matter:
   `src/pm_cmd.cpp` (every command handler; read the one you intend to
   send), `src/pm_defines.h` (command numbers, the shared-memory layout,
   `BIOSVAR_t` and `PMCFG_t`), `src/isa_devices/dev_memory.h` (the memory
   type codes), `src/pm_boards/pm.h` (this board family), `src/pm_libs/
   pm_apps.cpp` (the card's own setup screen — it prints most of what
   `PM1CFG` and `PM1DEV` print, which is how the port numbers were checked).

## State, 2026-09-20

**Works, on the hardware:** all eight tools, on a PicoMEM 1 with the BIOS of
2025-11-02 in a Gateway 2000 386SX/25. Detection, the full configuration,
the live memory map through command 05h, the emulated-device probe, all
three text answers including WiFi, the AdLib scale, the benchmark, and a
dump pulled back to Windows and checked byte for byte.

**Found and fixed:** the parameter area moves between firmwares, so
PicoMEM2's `PMPROBE` and `PMUSB` reported nothing at all on this card while
reporting success. Both now call `FindParam`. See the README.

**PM1WATCH exists**, and it is the tool to reach for whenever the question is
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
three buttons. `PM1MOUSE` is the tool and the README has the output. The
control run with `/E-` shows the same bytes never move when nothing is sent.
`BV_USBDevice` stays 00 throughout, exactly as the firmware's own "not used
for the moment" comment says it would.

## Ideas not done

* **An INT 33h driver, so DOS gets a pointer.** This is the obvious next
  piece of real work and it is squarely what this collection does --
  `CH375Mouse` is the same job for the CH375, and a good deal harder, since
  it has to run the whole USB stack itself. Here the hard part is already
  done by the card: enable reporting, hook the card's IRQ (it is 7 on this
  machine, and `BV_IRQ` says which), accumulate the deltas and serve
  `INT 33h` functions 0, 3, 4, 7, 8 and 11. The card's own distribution has
  such a driver (`PMMOUSE`), so it is known to be possible; this would be
  ours, and it would work on a PicoMEM 2 unchanged. Read `CH375Mouse`'s
  resident structure first -- it already solves the INT 33h half.
* ~~A USB keyboard.~~ **Answered: this firmware has no keyboard path at
  all.** The card claims the device and reports `1: USB keyboard`, but
  `KEYB_Enabled` -- the flag command 54h sets -- is read by nothing, and
  `IRQ_R_KEYBOARD` is defined in a header and raised nowhere, where
  `IRQ_R_MOUSE` is raised and works. Demonstrated with 54h sent and
  accepted, using `PM1WATCH /2` -- two identical 25-second windows, one
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
* **The AdLib, heard rather than detected.** `PM1OPL` proves the OPL2
  answers and plays a scale, and nothing on the DOS side can tell whether a
  sound came out — the card's audio output is its own hardware. Somebody
  with ears, or with the audio side of `doscap` wired to the card rather
  than to the PC's own video capture, could close that loop.
* **The other emulated sound cards.** This card has Tandy, CMS, Sound
  Blaster, Mindscape, Covox, MPU and GUS all configured off, so `PM1DEV`
  reports them off and probes nothing. Turning one on means the card's setup
  screen at the keyboard, and then `PM1DEV` should find it at the port
  `PM1CFG` names. Worth doing once to prove the detection, and it is the one
  thing here that needs a human at the machine.
* **EMS.** Also off. The firmware's port list is `268h`, `288h`, `298h`,
  `2A8h` with a window at `D000h` or `E000h` — and **none of them is 260h**,
  which is the one number that matters, because that is where the CH375 card
  lives and anything else there corrupts its reads. So a PicoMEM's EMS and a
  CH375 can share a machine. That is worth knowing and has not been tested.
* ~~`PM1BENCH` against the PicoMEM 2.~~ **Done, 2026-09-20, in the same
  386SX.** Every row inside 1%, three of them inside a tenth of a percent:
  the RP2350 buys nothing, because the measurement is of the ISA bus and not
  of the microcontroller. The README has the table. What the newer firmware
  did change: the answers area (+374 to +886) and a cleaner OPL2 status.
* **The 8259 and the card's IRQ.** `BV_IRQ` says 7 and nothing here watches
  it. The card fires a multiplexed interrupt for its own purposes; a tool
  that counted them over a minute would say whether it is idle.

## What would need firmware, and does not belong here

Everything about driving a USB device through the card. The stock firmware
enumerates a device and then ignores it unless one of its class drivers
claims it: there is no command that reads a descriptor, sends a control
request or opens an endpoint. That is not a DOS-side problem and no tool in
this folder can work around it.

[`../PicoMEM2/NEXT.md`](../PicoMEM2/NEXT.md) has the proposal — a command
group in the unused range C0h–CFh answering into the parameter area — and
the reasons it has not been done: no ARM toolchain on the build PC, and
flashing needs hands on the machine with a known-good image beside it. All
of it applies to this board too, with one extra caution: **this card's
firmware is older than the sources in that repository**, so a build from
today's tree is not the image that is on it.
