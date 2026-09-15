# Changelog

CH375Mouse -- StevenC -- https://github.com/jdredd87/CH375USBTools

The version lives in `ver_str` in `src/usbmouse.asm` and nowhere else. A
release is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## 1.1.0 -- a serial mouse on a USB-to-serial adapter

`USBMOUSE.COM` now drives two kinds of mouse through the same `INT 33h`: a
USB HID mouse plugged into the CH375, and a **serial mouse on a
USB-to-serial adapter** plugged into the CH375. It works out which is
attached. Everything above the input layer -- `INT 33h`, the cursor, the
event handlers, the PS/2 emulation -- is untouched and shared, because
`apply_report` takes three bytes and a serial packet decodes into exactly
those.

Verified on a Keyspan `06CD:0121` with a Mouse Systems mouse: `MOUSETST`
34/34, `EVTEST` clean, `PS2TEST` 25/25 with 160 real packets through the
PS/2 BIOS path, so **Windows 3.0 works** with `/W`.

**The framing is decided from the stream, not assumed.** After three bytes
the decoder looks at the fourth: a header means the packet was three bytes
(MM Series) and that byte starts the next one; anything else means it is
`dx2` and the packet is five (Mouse Systems). Being wrong costs one packet
and corrects itself.

**Both movement samples are delivered, not summed.** A Mouse Systems packet
holds two successive samples; adding them halves the cursor update rate,
which is what "not very smooth" feels like. It also removes an overflow --
+100 and +100 summed in a byte is -56, so a fast flick used to reverse.

**`SET_RETRY 00` on the serial path, and this one made the machine
unusable.** The serial bring-up returns before the shared tail where the
chip is put back to reporting NAKs, so it stayed on `8F` -- retry NAKs for
ever -- and every poll of an idle endpoint ran to a full timeout, up to
sixteen times per tick at 145 Hz. DOS crawled and the box needed a reboot.
`DIR C:\BP\BIN` now takes 3.6s against 3.5s with no driver at all.

This is the fourth time this bug has appeared across these projects, always
from the same cause: a new code path that returns before the shared tail.

**`CHECK_EXIST` resets the chip and asks again** before deciding there is no
card. A chip left mid-transaction fails that test on a card that is fitted,
and this driver's own `/U` can leave it that way -- so load, unload, load
reported "No CH375 responds at that I/O address".

Three smaller faults, all real and none of them the one above: an 8-bit
overflow summing movement; reads into an 8-byte HID buffer when a bulk IN
carries up to 64; and trusting `ch_read`'s count, which reports what the
CHIP said rather than what it stored, so the decoder walked past the buffer
and consumed driver variables as movement.

## Unreleased

**THE SAME MOUSE SPEAKS EITHER PROTOCOL.** The mouse on the bench has been
read as Mouse Systems by `MOUPROBE` and as Microsoft by this driver, minutes
apart, on one adapter, without being unplugged. Both readings are correct --
the byte streams are unambiguous.

It was found by accident and read as a bug at first: two `MOUPROBE` runs a
minute apart identified the same mouse as different protocols.

**What selects it is NOT known, and the first answer was wrong.** The middle
button fitted the early evidence exactly -- the run that reported `left right
middle` ended in Mouse Systems, the run that reported only `left right`
stayed Microsoft, and the Logitech convention is that a mouse switches
protocol to report a third button. It was written up as established, then
tested directly: with the driver resident and the mouse in Microsoft mode,
pressing only the middle button repeatedly changed nothing through **1840
decoded packets**, with resyncs unchanged and the protocol unmoved.

What the evidence supports is that the protocol is settled at power-up, and
that opening the port IS a power cycle, since `SerOpen` raises the RTS and
DTR that power the mouse. So every program that opens the port gets its own
answer, and they disagree -- `MOUPROBE` and `USBMOUSE` on one Keyspan, and
`USBMOUSE` differently again on a PL2303.

So a driver that decides the protocol once is betting that answer never
changes under it, and the cost of losing is total -- wrong framing, wrong
button sense, wrong movement, until it is reloaded. Not knowing the mechanism
is the case FOR not depending on it.

**The driver now decides again when the decode falls apart.** The trigger has
to be one a healthy stream cannot pull, so it is not "a byte looked odd":
`ser_bad` counts bytes thrown away **with no report delivered between them**
and every delivered report clears it. An occasional dropped byte -- the CH375
loses them, 3 to 19 in these runs -- never approaches the threshold of 8,
because a report lands between each one. Only a decoder reading the wrong
protocol fails continuously, and it gets there inside about two packets.

Measured both ways, on hardware, rather than argued:

| | re-decisions | reports |
|---|---|---|
| started correct, 3280 serial reads | **0** | 1329 |
| started deliberately locked to the WRONG protocol | **1** | 1329 |

The wrong-protocol build is the test that matters -- it is the real mouse,
real movement and real clicks, with the decoder pointed at the wrong
protocol on purpose. It converged immediately and finished with matched
press and release counts on all three buttons.

**The detector reads both protocols at 8N1**, in the probe as well as the
driver. A 7-bit sender read at eight bits puts its stop bit in bit 7, which
moves Microsoft's headers to `C0-FF` and its bodies to `80-BF`; Mouse
Systems headers sit at `80-87`. The ranges do not overlap, so one framing
reads both and one header settles which is being spoken.

**`MOUPROBE` opens the port once.** It used to open, close and open again to
force a power cycle, so a Microsoft mouse would announce itself with `M`.
That announcement is no longer relied on -- the protocol comes out of the
stream, which works for a mouse that says nothing and for one being moved
while it speaks -- and on a PL2303 the close/open pair left the adapter
delivering **nothing at all**, intermittently. It presented as an unpowered
mouse and sent the tool hunting RTS and DTR for an evening.

What settled it was running the driver against the same adapter in the same
state: 263 reports and 34/34. The adapter was healthy and the diagnostic was
the broken one. A probe that lies is worse than no probe, because it is what
you reach for when confused.

**`SET_RETRY` has one caller now.** `set_retry_n` with `ser_enum_ready` and
`ser_poll_ready` in front of it, called from the tails of `ser_open`. This
bug had appeared five times across these projects and twice in this one
file, always from the same shape -- a new path that returns before the
shared tail. Centralising it also cut `bytes resynced past` from 77 to 4.

The install banner no longer names a protocol. It said which one before a
single byte had arrived, which was a guess printed as a fact; `/S` reports
it after the stream has spoken, alongside the re-decision count.

Two findings from the sibling projects were checked against this driver and
recorded in the README:

* `CLR_STALL` resets the CH375's endpoint-0 data toggle, so manual control
  transfers work only every other time unless endpoint 0 is cleared first.
  This driver issues only optional no-data requests, so the effect is
  invisible here -- but `SET_IDLE` may be failing silently on the second
  call, and clearing endpoint 0 in `hid_request` would be correct.
* The CLD-in-an-interrupt-handler rule does **not** apply here: every string
  operation in `usbmouse.asm` is after `resident_end`, in transient code.
  Checked rather than assumed.

## 1.1.0 -- 2026-09-08

* **`/S` reports the I/O base the resident copy is using**, read out of its
  image rather than assumed. Without it there was no way to confirm which
  address a driver loaded with `@nnn` actually took.
* The help screen says so too.
* `CHDIAG`, `MOUSETST`, `EVTEST`, `PS2TEST`, `TICKCHK`, `CLKCHK`, `MDEMO`
  and `CLICKTST` all report a version and answer `/?`. The five that take a
  positional `[seconds]` argument check for `/?` before parsing it as a
  number, so `/?` does not silently become "use the default".
* `MOUSETST`'s local `Ver` -- which holds the *driver's* version string --
  is now `DrvVer`, so it cannot be confused with the program's own.
* `build.cmd` picks up `chtool.pas` from `..\CH375USBTOOLS\src` with `-Fu`,
  the same arrangement the keyboard and combo projects already used, and
  the repository URL in its header had `Tools` twice.

## 1.0.0 -- 2026-09-06

First numbered release. Everything below has been run on the hardware: a
CH375B rev B7 on an ISA card at `260h`, a low-speed Pixart optical mouse
(VID/PID `093A/2510`), MS-DOS on an 8086-class machine.

* `USBMOUSE.COM`, a resident INT 33h mouse driver, about 1.5 KB resident.
  It enumerates the mouse itself -- bus reset, speed negotiation,
  descriptors, address, configuration, HID boot protocol -- and polls the
  interrupt IN endpoint from a timer hook.
* Low-speed devices work. `SET_USB_SPEED` has to be issued after the last
  `SET_USB_MODE` and after the post-reset connect has been cleared, or it is
  silently ignored; that is the whole reason a low-speed mouse would
  otherwise answer every transfer with `24h`.
* INT 08h is taken over and the PIT divided by 8 for a 145 Hz poll, with
  every 8th tick forwarded, so BIOS timekeeping and the DOS clock stay
  right. The fast rate is given up automatically if another program hooks
  the timer above us, which is what makes double-click work in Windows;
  `/K` keeps it anyway.
* `/W` presents the mouse as a PS/2 BIOS pointing device (INT 15h C0h/C2h,
  INT 11h bit 2, INT 74h), which is what Windows 3.x understands. Movement,
  clicks and double-click all work in Windows 3.0.
* Options: `@nnn /V /F /E=n /R=n /K /W /S /U /?`.
* Private INT 33h functions `7F00h`-`7F03h` for testing: status, report
  injection, poll suspend, last raw report.
* The version is printed on every run, and kept in the resident image at
  `010Bh` so `/S` reports the version of the copy that is already loaded.
* Test tools, 78 checks in all: `MOUSETST` (34), `EVTEST` (19),
  `PS2TEST` (25), plus `TICKCHK`, `CLKCHK`, `CLICKTST`, `MDEMO`, `CHDIAG`.
* Assembles identically with `nasm` on a PC and with `MNASMFIX.COM -O9` on
  the DOS machine itself; `build.cmd dosbuild` checks that, byte for byte.
* Released into the public domain under the Unlicense.  `tools/MNASMFIX.COM`
  is third-party and keeps its own terms.
* Built and tested over DOSBridge -- https://github.com/jdredd87/DOSBridge
