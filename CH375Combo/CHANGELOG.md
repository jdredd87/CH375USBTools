# Changelog -- CH375Combo

All notable changes to `USBCOMBO.COM` and its test program.

## Unreleased

**Rebuilt 2026-09-24 for the credit, and nothing else.** Every program's
banner now ends `-- StevenC & Claude`, and every source header says the
same. No code changed and no version was bumped, so this build shares its
version numbers with the one before it -- the CRC tells them apart.
Deployed to the V30 under `C:\CH375\` and CRC-checked there.

## 1.1.0 -- 2026-09-08

* **`/S` reports the I/O base the resident copy is using**, printed above
  the two halves because it belongs to the card rather than to either one.
  Without it there was no way to confirm which address a driver loaded with
  `@nnn` actually took.
* The help screen's `@nnn` line says that `/S` shows the base in use. The
  screen is full at 23 lines, so the words were traded rather than added.
* `COMBOTST` reports a version and answers `/?`, with the whole of its
  header block -- including what the beeps mean and why `/W` exists.

## 1.0.0 -- 2026-09-07

First release. One driver for a USB keyboard and a USB mouse sharing a
single CH375, built because `USBMOUSE.COM` and `USBKBD.COM` cannot both be
loaded and a USB-to-PS/2 adapter is one device with both on it.

### The driver

* Enumerates once and claims **both** boot HID interfaces, walking the
  configuration descriptor for a keyboard (protocol 1) and a mouse
  (protocol 2) and the first interrupt IN endpoint inside each. Either half
  on its own is enough: a plain keyboard, a plain mouse and an adapter
  carrying both are all valid outcomes.
* Keys into the BIOS keyboard buffer at `0040:001E`, with the three shift
  bytes maintained and the lock bits left to the BIOS -- the whole keyboard
  half is `CH375Keyboard` 1.7.1's, unchanged.
* Pointer out through INT 33h, functions `00h`..`24h`, with a text-mode
  software cursor -- `CH375Mouse` 1.0.0's implementation, with the data
  renamed where the two halves would have collided.
* **Separate data toggles per endpoint.** The toggle is per endpoint in USB
  and `SET_ENDP6` carries the one for the transaction about to be issued;
  one variable shared between two endpoints makes every second transaction
  on each a toggle mismatch, reported as `2Bh` and looking exactly like a
  flaky device.
* Separate report buffers per half. A mouse packet landing in the
  keyboard's `rep_buf` would be diffed against the last key report and come
  out as keystrokes.
* One endpoint per tick, alternately, so each is sampled at 72 Hz at the
  default divisor -- still well above the 10 ms `bInterval` either
  interface asks for, at half the ISR cost of asking both. `/B` puts both
  on the same tick.
* Restores INT 33h on `/U` through the vector published at `0133`, on the
  same terms as INT 08h and INT 16h: only if we took it, and only if it is
  still ours. Verified: `0021:40D2` before load, `0021:40D2` after unload.
* INT 33h is hooked only when a mouse enumerated, or when `/F` says one is
  expected. Hooking it with no mouse makes function `00h` report a pointing
  device that never moves, and an application that believes in a dead mouse
  hides its keyboard fallback.
* New options: `/NK` and `/NM` to drive one half only, `/C` to skip the
  mouse's `SET_PROTOCOL`, `/B` and `/Q` as diagnostics. `/N` alone still
  means "no lock LEDs"; `/NK` and `/NM` are told apart by the character
  after it, consumed only if it is one of those two.

### Reading the report format off the packet

This adapter's mouse interface declares HID report IDs -- 1 pointer, 2
system control, 3 consumer keys -- so every packet leads with an ID byte.
It also answers `SET_PROTOCOL 0` with **success** and then keeps sending
that format anyway. The request is still issued, because it is the right
thing to ask for and a device that honours it is simpler to drive, but its
answer is not relied on: `mou_strip_id` decides from the packet.

Verified with a hand on the mouse: 116 reports used, 0 rejected, the pointer
tracking to `410,128`, button bits following `00 -> 01 -> 03` as left and
then both were pressed, and 6 keys delivered into the BIOS buffer in the
same run.

### A wrong turning, recorded rather than buried

Before anyone had moved the mouse, the endpoint delivered a steady stream of
`01 00 XX 00 00` -- report 1, no buttons, small varying X, Y and wheel zero.
Polling that endpoint alone appeared to give nothing, and of 441 packets,
441 carried movement and none carried none. That was read as the chip
fabricating packets.

**Both readings were wrong.** `SET_IDLE 0` means "report only when something
changes", so every report from a healthy mouse carries a change -- a stream
in which they all do is exactly correct, not impossible. And the runs that
saw nothing had a mouse sitting still; the idle stream was a real, slightly
noisy mouse.

The version built on that reasoning rejected any packet longer than a boot
report, on the grounds that the device had acknowledged `SET_PROTOCOL 0`.
**It discarded 100% of real mouse data**, and every automated check passed
while it did -- they all inject their own reports and never touch the USB
read. Moving the mouse and watching `COMBOTST /W` is what caught it.

Kept from that detour, on their own merits:

* `ch_flush` -- a bounded wait must give up, and giving up does not cancel
  the transaction, so a leftover completion could in principle be read by
  the other endpoint's next poll. The reasoning holds and the case has never
  been seen; `n_flush`, `n_tmo` and `m_tmo` all stay 0 and `/S` reports them.
* One endpoint per tick -- kept for the halved ISR cost on an 8086, not
  because it fixed anything. `/B` puts both on the same tick; both work.

`mou_boot` and `m_bogus` survive as `/S` counters with nothing depending on
them.

### Poll rate, and the keyboard's hard ceiling

A boot keyboard report is the set of keys held right now in no defined
order, so anything completed between two polls is invisible and anything
simultaneous is unordered. Measured by typing `abcdefghijkl` twice:

| rate | window | result |
|---|---|---|
| 145 Hz (`/R=8`) | 7 ms | `abcdefghjikl` / `abcdefjilkl` -- dropped and transposed |
| 291 Hz (`/R=16`) | 3.4 ms | `abcdefghijklabcdefghijkl` -- correct |

So the default is now `/R=16`, up from CH375Keyboard's 8. `rep_delay` and
`rep_rate` are counted in fast ticks and doubled with it, to 144 and 10 --
carrying the old values over would have given a quarter-second typematic
delay and 58 repeats a second.

Tracing the adapter's own report stream (`COMBOTST /KB`) settled the
transposition question: it appends new usages to the next free slot, so slot
order is press order and the driver's slot scan delivers them correctly.
Rollover from `j` to `k` to `l` comes out right. A device that reordered its
slots would transpose and nothing could be done about it.

**The mouse now yields on any tick the keyboard reported.** At 291 Hz a tick
is 3.4 ms; a tick carrying a key report has already done the report diff,
the translation and the BIOS write, and adding a mouse transaction pushed
the handler toward overrunning -- which loses a keyboard sample. Typing
while moving the mouse hard was exactly where characters went missing. The
mouse loses one sample out of many, which a delta-reporting device does not
notice.

`/A` and `/B` are gone; `/M=n` replaces them, setting how often the mouse is
polled (default every 4th tick, 73 Hz).

### Mouse speed, and a switch that read backwards

The pointer is not poll-limited: moving continuously, the adapter emits
about 33 reports a second -- the PS/2 mouse's own sample rate -- while the
driver polls at 145 Hz. Polling harder cannot help, so speed is a matter of
multiplication.

* `/M` default corrected from 4 to **2**. At 73 Hz against the adapter's
  100 Hz `bInterval` the driver was discarding about a quarter of the
  movement. A comment claimed a delta-reporting device loses nothing at a
  lower rate -- wrong: an uncollected interrupt report is *replaced*, not
  accumulated. **Poll an interrupt endpoint faster than its `bInterval`,
  whatever the payload means.**
* `/G` is now a **speed multiplier, bigger is faster, default 16**. It used
  to set the INT 33h mickeys-per-unit directly, which meant smaller was
  faster -- backwards from how anyone thinks about it -- and capped at 8x,
  because the scaling divides by that value and it cannot go below 1.
  Multiplying instead removes the ceiling, and applying it to the raw delta
  makes it stack with whatever sensitivity an application sets rather than
  fighting it. Function `0Bh`'s mickey counters are taken before it.
* The default of 16 is not the textbook 1. One unit per mickey suits a
  mouse reporting a hundred-plus times a second; at 33 it crawls. 8 was
  still slow on the hardware, 16 felt right. `/G=1` restores the textbook
  rate.
* `/S` now prints both poll rates in **Hz** rather than only the divisors.

### `/?` never worked, here or in USBKBD

The argument parser upper-cases each switch character with `AND 0DFh`,
which is right for letters and wrong for everything else: it turns `?`
(3Fh) into 1Fh, so the comparison against `?` further down could never
match. `/?` was silently ignored and the driver loaded instead. `?` is now
tested before the upper-casing. **CH375Keyboard has the same parser and the
same bug.**

The help text itself is rewritten for somebody who wants to use the driver
rather than debug it: the three commands that cover almost every use come
first, the surprising behaviour -- no mouse pointer at the DOS prompt -- is
stated before the options rather than left to be discovered, and the whole
screen fits in 24 lines so nothing scrolls off.

### PS/2 BIOS emulation, so Windows 3.x finds the mouse (`/W`)

Ported from `CH375Mouse`, where the contract was established by
disassembling Windows 3.0's `MOUSE.DRV` rather than trusting a reference.
`INT 15h AH=C0h` reports model `FC`, `INT 11h` bit 2 is set, the `C2xx`
sequence is answered, and `INT 74h` is taken first so that when `MOUSE.DRV`
hooks it and chains to what it found, the packet is delivered in the frame
the PS/2 BIOS uses. Only the report buffer needed renaming; `ps2_emit`
reads the boot-shaped report *before* the `/G` multiplier, so Windows gets
raw mickeys and scales them itself.

**Confirmed in a live Windows 3.0 session on the hardware:** the USB mouse
moved and clicked, the USB keyboard did nothing -- exactly the split the
design predicts. The keyboard side is not fixable on this machine:
`KEYBOARD.DRV` reads its scancode from port 60h and there is no 8042 to put
one there, so calling `INT 09h` would only make the handler read whatever
the hardware last latched.

**The mouse divisor now applies only while the driver owns the timer.**
Windows hooks `INT 08h` above us, `check_top` hands the PIT back to 18.2 Hz
to keep Windows' timing right, and `/M=4` on top of that would have polled
the mouse about four times a second. When `on_top` is clear, every tick
polls the mouse.

`PS2TEST.EXE` from `CH375Mouse` runs unmodified against this driver -- it
uses only the `7F00h`/`7F01h`/`7F02h` private functions, which mean the same
thing here -- and passes **24/24**, covering the whole call sequence, the
callback frame, Y inversion, both sign bits and all three buttons. That
matters because Windows reads the keyboard at `INT 09h` and cannot be exited
over the bridge, so a live Windows session costs a power cycle.

`/W` previously meant CH375Keyboard's withdrawn INT 09h wake, which was
accepted and ignored; it now means what it means in `USBMOUSE`. `/W=n`
takes a subset of the three vectors as a bitmask (1/2/4) -- added to bisect
a suspected crash on load, kept because it is the fastest way to find out
which hook a machine objects to. All three are restored by `/U`, and only
the ones actually taken.

**The keyboard half does not work under Windows and cannot:** Windows
drives input from `INT 09h` and never reads the BIOS ring. Same wall as DOS
EDIT.

### A full BIOS buffer kills every keyboard on the machine

Reported as "`USBCOMBO /?` and then no keyboard input at all". `/?` was
innocent -- dumping `40:17`, `40:18`, `40:96`, `40:97` and the ring pointers
either side of it showed them byte-for-byte identical, and the help path
prints and exits through `INT 21h/4C00h` without touching anything.

The cause was the BIOS keyboard ring at `0040:001E` being **full**: head
`001E` against tail `003C`, fifteen keys queued and nothing reading them.
The BIOS discards new keystrokes from *every* source once that happens, so
the machine's own keyboard dies alongside the USB one. Anything that runs
without reading the keyboard fills it -- DOSBridge's own agent loop
included, with no driver loaded at all.

**What the driver contributed, now fixed:** `do_repeat` carried on
auto-repeating at 29 keys a second into a buffer it could not write to, so
a single missed key-release pinned the ring full permanently and turned
itself into total keyboard loss until reboot. `buf_put` now returns CF on a
drop and `do_repeat` cancels the repeat, letting the ring drain.

**New in COMBOTST:** `/BIOS` dumps the keyboard data area, `/FLUSH` empties
the ring. Both work with no driver loaded, and `/FLUSH` recovers the machine
over the bridge without a power cycle -- which matters, because a machine
with a full buffer cannot be told to fix itself from its own keyboard.

### Two harness bugs worth recording

Both made the driver look broken when it was not, and both are the same
mistake in different clothes -- trusting a measurement without checking the
measuring instrument.

* The live watch seeded its "last seen" packet as empty, so a **leftover
  packet from a previous run** counted as new traffic. With the mouse
  untouched that printed "packets arrived and none was used" and sounded the
  failure beep, when nothing had arrived at all.
* It read **one key per loop iteration**. The BIOS ring holds 15 words and
  the loop is slow while the mouse streams, so the driver filled the buffer
  faster than the harness emptied it, and keys lost at the *buffer* looked
  exactly like keys the driver never saw. It now drains up to 16 per pass,
  drains again at the end, and prints the driver's own `n_full` and
  `n_keys` beside its own count so the two can be reconciled.

### A bug this exposed in USBKBD 1.7.1

`/F` retries the bring-up from inside the timer interrupt, and `bringup`,
`parse_config` and `cfg_buf` all live **above `resident_end`** -- in memory
DOS releases when the driver goes resident. The retry therefore runs code
and writes buffers in memory that now belongs to something else. It works
until something else uses it.

Fixed here by keeping the whole image resident when `/F` is given, and only
then: 14512 bytes instead of 5424. Recorded against `CH375Keyboard` too
rather than silently changed there.

### Testing

* `USBCOMBO /T` -- 7 checks, no hardware beyond the chip and no keypress:
  key delivery to INT 16h twice over, the release producing nothing, a
  mouse report reaching the INT 33h coordinates with the right scaling, a
  button press and release through the edge detector, and the packet parser:
  report 1's ID stripped, report 2 refused, a boot report passed through
  untouched, and a report ID still stripped after `SET_PROTOCOL` said yes --
  which is the case this adapter actually presents.
* `COMBOTST.EXE` -- 42 checks with the driver loaded: the INT 33h API as an
  application calls it, and fabricated reports through the real report path.
  Reads the resident copy through the published pointer block at `0111`
  rather than hard-coded addresses; the first version did the latter and
  confidently reported a neighbouring variable as the poll count. It also
  drains the per-button press and release counters before injecting, since
  function 00h does not clear them and they bank real clicks.
* `COMBOTST /W[=secs]` -- watches **both** endpoints live and **beeps**:
  three rising notes to start moving, one blip per report used, three
  falling notes to stop, four hard notes if packets arrived and none was
  used. `COMBOTST /BEEP` plays them all so the speaker can be checked
  first. The beeps exist because the one thing no automated check can do is
  move the mouse, and the run that found the filter bug was only
  interpretable with a human in the loop.
* The idle-pointer check was **removed** as an invalid assertion: a real
  mouse is noisy and legitimately reports when untouched, and asserting
  stillness would have locked in the filter bug. What replaced it asserts
  the thing that does hold -- nothing that arrives is discarded.

Verified on the hardware: `/T` 7/7, `COMBOTST` 42/42, and with a hand on
the mouse 116 reports used, 0 rejected, pointer tracking, buttons tracking,
6 keys delivered in the same run.

### Known limitations

* No PS/2 BIOS mouse emulation, so Windows 3.x will not find a pointing
  device through this driver. That is `CH375Mouse`'s `/W`, and Windows
  running over a driver that divides the PIT underneath it is a separate
  argument. Load `USBMOUSE` for that job.
* DOS EDIT's menus are not reachable, for exactly the reasons in
  `CH375Keyboard/README.md`: EDIT drives its input from INT 09h and this
  machine has no 8042 to raise IRQ1 with. Nothing here changes that.
* `/K` needs an AT-class keyboard controller. This machine has none --
  port 64h reads `FF` -- and the driver says so and falls back.
* The version string does not change between development builds, so two
  different images that both say `1.0.0` pass the `/S` and `/U` version
  check and then read each other's data at the wrong offsets. Always `/U`
  before deploying a new build.
