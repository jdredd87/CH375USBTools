# Picking this up next

Written 2026-09-19, at the end of the first session on the PicoMEM 2. For
whoever continues it, including a fresh Claude Code instance.

## Read these first

1. **This file.**
2. **`README.md`** -- the protocol, what was found, and the hazards. The
   hazard section is the reason nothing here has hurt the boot disk.
3. **`src/pmcard.pas`'s header** -- the rules every command obeys.
4. The card's sources, for reference only (GPLv2 -- read, do not copy):
   https://github.com/FreddyVRetro/ISA-PicoMEM. The files that matter:
   `src/isa_devices/dev_picomem_io.cpp` (the ports), `src/pm_cmd.cpp` (the
   commands), `src/pm_defines.h` (codes and shared-memory layout),
   `src/USB_Host_Driver/` (the USB host), `pmbios/pm_hw.asm` (how its own
   BIOS sends a command).

## State, 2026-09-19

**Works, on the hardware:** detection through the BIOS and the test port,
the shared memory decoded, the USB/disk/WiFi status queries, repeated
queries (10 in 10 s, and a 10 s `PMUSB` watch), the ROM dump.

**The machine:** the 8086-class box (NEC V30, MS-DOS 6.22), holding a
PicoMEM 2 -- board id 11, BIOS of 2026-06-16, base 2A0h, ROM at D000h,
IRQ 7. The other machine in use, a Gateway 2000 386SX/25, has a PicoMEM 1
in it; these tools read either, but everything below was measured on the 2.

DOS boots from `cdrive` on the card's SD card -- **the card is the boot
disk** -- and DOSBridge runs over the card's WiFi NE2000 at 300h. Both
facts constrain everything below.

**What the USB ports gave:** USB-A with a USB Ethernet adapter in it:
"1 device", description empty (nothing in the firmware claimed it). USB-C
with the IBM camera: not seen -- it is the flashing port, not a host.

## Hazards

* **Never send a command that is not already whitelisted without reading
  its handler in `pm_cmd.cpp` first.** Disk and image commands (80h-8Dh),
  memory and configuration commands, `CMD_LockPort` (37h) and the audio
  switches are all one mistake away from a machine that cannot read its
  own boot disk, or cannot reach the network it is administered over.
* **A hang is not necessarily the card.** The only three hangs so far were
  our own `Intr` call switching interrupts off (README). Check the interrupt
  flag and the tick with `PMTICK` before blaming the firmware.
* **Never `TYPE C:\WORK\OUT.TXT` in a bridge job.** That is the job's own
  output file; the job copies it onto its own end until the disk is full.
  It happened once this session and needed a power cut.
* **`doscap shot` saying "exclusive" means a live preview is open** (two
  `ffplay` windows held it for most of this session). Ask for it to be
  closed rather than killing it. Once it was, `doscap` confirmed `PMUSB`'s
  spinner turning on the real screen through a 25 s watch, and caught two
  lines of `PMPROBE` output wrapping at 80 columns -- fixed.

## Where this goes: talking to USB devices needs our own firmware

The stock firmware's USB host runs TinyUSB with class drivers for HID, mass
storage, MIDI and game pads, `CFG_TUH_VENDOR 0` and `CFG_TUH_CDC 0`, and no
command that reaches a device: no descriptor read, no control request, no
endpoint. A device it does not claim is enumerated and then ignored. **So
DOS cannot drive a USB device through the PicoMEM without firmware
changes.** Nothing on the DOS side can change that.

The firmware is complete source for this board (`PICOMEM_20` in
`src/CMakeLists.txt`), and replacing it is proven: **PicoGraph**
(https://github.com/ianhan/picograph) turns a PicoMEM 2 into a video card
through a USB DisplayLink adapter on this same port.

### The proposal: a USB pass-through in the card's firmware

Add a small command group in the unused range **C0h-CFh**, answering into
the 2 KB parameter area at shared +886 so no new transport is needed:

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
buffer, 1 KB per command, and 8 MB of PSRAM on the far side -- enough for
the camera's whole frame, which is exactly what `CH375Camera` could not do.

Written as our own additions to a fork of their firmware, and GPLv2 because
it is linked into theirs -- kept in its own folder with that licence, apart
from this Unlicense collection.

### Why it has not been done yet

* **Flashing needs hands.** The RP2350 is flashed through the USB-C port
  with the BOOT button held. A firmware that fails to start takes the boot
  disk AND the DOSBridge network with it, until someone reflashes the
  stock image -- keep `PM2-6-21-26.uf2` beside any test build.
* **There is no toolchain on this PC yet**: no `arm-none-eabi-gcc`, `cmake`
  or pico-sdk. The firmware also expects its own TinyUSB copy
  (`PrepareTinyUSB.sh`).
* The configuration and disk images live on the SD card and are read by
  the firmware at boot. A test build must leave the SD code exactly as it
  is.

### The order to do it in

1. Install the toolchain; build the **stock** firmware unmodified and
   compare it with the published `.uf2` -- a build that differs before any
   change is not a base to change.
2. Add C0h only (list devices). Flash, with somebody at the machine, and
   check the machine still boots and DOSBridge still answers before
   anything else.
3. `PMUSB` learns C0h: VID:PID for the Ethernet adapter on USB-A.
4. Then C1h-C4h, and a port of `CH375USBTOOLS`' `USBINFO` onto them. Then
   the SR9700 driver, the camera.

## Since this was written

**2026-09-20.** The parameter area is no longer assumed to be at +886.
A PicoMEM 1 with the BIOS of 2025-11-02 puts it at +374, and against that
card `PMPROBE` and `PMUSB` reported nothing at all while reporting success.
`pmcard.pas` gained `FindParam`, which locates it from the shape of the
disk-status answer, and both tools call it. The sibling project
[PicoMEM1](../PicoMEM1/) is where that was worked out, and it carries eight
more tools for the older card -- the live memory map through command 05h,
the emulated devices probed from the PC side, and timings for the card's
memory and its command round trip.

## Ideas not done

* A `PMUSB` mode that beeps on a change, for plug tests with nobody
  reading the screen.
* The WiFi structure's layout past the SSID and status line is not
  decoded; `/W` prints only those two.
* `CMD_GetMEMType` and `CMD_PCINFO` look read-only but have side effects in
  their handlers (`PC_End()`); they were left off the whitelist on purpose.
