# CH375Combo

`USBCOMBO.COM` — one DOS driver for a USB **keyboard and mouse at the same
time**, over a single WCH CH375 in host mode. Keys go into the BIOS
keyboard buffer; the pointer comes out through INT 33h.

One of four projects in [CH375USBTools](../README.md). See also
**[CH375Keyboard](../CH375Keyboard/)** and **[CH375Mouse](../CH375Mouse/)**,
whose drivers this one replaces when you want both devices, and
**[CH375USBTOOLS](../CH375USBTOOLS/)** for the probe tools that made it
possible to work out what the hardware was doing.

    cd CH375Combo
    build.cmd                 build USBCOMBO.COM and COMBOTST.EXE into bin\
    build.cmd test            ...then run the driver's own /T self-test
    build.cmd suite           ...then load it, run COMBOTST, unload
    build.cmd trace           ...then bring it up with /V and unload
    build.cmd watch           ...then watch both endpoints live.  MOVE THE
                              MOUSE when you hear the rising beeps

Sources are in `src\`, built binaries in `bin\`, and the binaries are
committed: the machine this targets has no compiler for them.

## Why this exists

`USBMOUSE.COM` and `USBKBD.COM` **cannot both be loaded.** Each resets the
CH375, enumerates from scratch, assigns the USB address and hooks INT 08h to
poll it; two of them on one chip reset it out from under each other and
interleave transactions with no locking at all. One CH375, one host driver —
and until now that meant choosing between a keyboard and a mouse.

A **USB-to-PS/2 adapter** makes that choice both unnecessary and unwanted,
because it is *one* low-speed USB device carrying *two* boot HID interfaces:

```
0E8F:0020  "PS2toUSB Adapter"   low speed, USB 1.10, 480 mA

INTERFACE 0   class 03/01/01  HID boot keyboard
              EP 81  IN  interrupt  max 8  interval 10   report descr  62 bytes
INTERFACE 1   class 03/01/02  HID boot mouse
              EP 82  IN  interrupt  max 5  interval 10   report descr 130 bytes
```

Two interfaces, two interrupt IN endpoints, one device address, one
enumeration. So this driver enumerates once, claims both interfaces, and
polls both endpoints from the same timer hook.

It is not limited to an adapter. A plain keyboard brings up the keyboard
half alone, a plain mouse the mouse half alone, and a combo dongle that
presents both gets both. Whichever halves enumerate are the halves that
run, and `/S` says which.

## Options

    USBCOMBO [@260] [/S] [/U] [/F] [/V] [/NK] [/NM] [/C] [/N] [/E] [/K]
             [/T] [/Q] [/R=n] [/M=n] [/G=n] [/D=n] [/T=n] [/Y=n] [/X=hh]
             [/H] [/?]

| | |
|---|---|
| `@nnn` | CH375 I/O base in hex, default `260`. `/S` prints the base the loaded copy actually took |
| `/?` | the full help screen |
| `/S` | status of the loaded copy — both halves, in full |
| `/U` | unload |
| `/F` | install even with nothing attached, and keep looking. **Keeps the whole image resident**, about 14 KB instead of 5 KB — see "What `/F` costs" below |
| `/V` | trace each bring-up step and the status it returned |
| `/NK` | ignore the keyboard interface; drive the mouse only |
| `/NM` | ignore the mouse interface; drive the keyboard only |
| `/C` | do not ask the mouse for boot protocol. A diagnostic — see "The report-ID wrinkle" |
| `/N` | do not drive the lock LEDs |
| `/E` | claim a 101/102-key keyboard in `40:96` bit 4 |
| `/K` | inject keys through the 8042 (command `D2h`) instead of writing the BIOS buffer. Needs an AT-class controller; **the PS/2 Model 30 this was built on has none** and says so at load time |
| `/T` | self-test both halves and exit without going resident |
| `/R=n` | timer divisor; PIT rate = 18.2 × *n* Hz. **Default 16 (291 Hz)**, *n* = 1..16. Lower it and the keyboard starts dropping characters — see "Poll rate is the keyboard's ceiling" |
| `/M=n` | poll the mouse every *n*th tick. Default 2, giving it 145 Hz |
| `/G=n` | mouse speed multiplier. **Bigger is faster**, no ceiling. Default 16; `/G=1` is the textbook rate |
| `/D=n` | typematic delay before repeat, in fast ticks. Default 144 |
| `/T=n` | typematic period, in fast ticks. Default 10 |
| `/Y=n` | keyboard HID idle rate in 4 ms units. Default 0 = report on change |
| `/X=hh` | pretend HID usage `hh` is held down, bounded to 64 repeats. A diagnostic |
| `/H` | deliver keys through an INT 16h hook instead of the BIOS buffer |

| `/Q` | do not flush a stale CH375 interrupt before a token. A diagnostic |

| `/W` | PS/2 BIOS emulation, so **Windows 3.x** finds the mouse. `/W=n` hooks a subset as a bitmask (1 = INT 15h, 2 = INT 11h, 4 = INT 74h) — a diagnostic |

In `CH375Keyboard` `/W` meant the withdrawn INT 09h wake, which was accepted
and ignored; nothing depended on that, and here it means what it means in
`USBMOUSE`.

## What it delivers

**Keys** go straight into the BIOS keyboard buffer at `0040:001E`, with the
tail moved at `0040:001C` — exactly what a real keyboard interrupt does.
Everything reading through INT 16h or through DOS sees them, and the shift
state is maintained at `0040:0017`, `0040:0018` and `0040:0096` alongside.
The whole keyboard half is `CH375Keyboard`'s, unchanged, so everything in
[its README](../CH375Keyboard/README.md) applies here too — including the
part about DOS EDIT's menus, which this driver does not fix either.

**The pointer** comes out through **INT 33h**, functions `00h`–`24h`, with a
text-mode software cursor — `CH375Mouse`'s implementation.

## Windows 3.x

`USBCOMBO /W` makes the **mouse** work under Windows 3.x. **The keyboard
half does not work there at all**, and cannot.

Both halves of that were confirmed in a live Windows 3.0 session on this
machine, not merely predicted: the USB mouse moved and clicked, and the USB
keyboard did nothing.

Windows drives the keyboard from `INT 09h` and never looks at the BIOS ring
this driver writes into — the same wall as DOS EDIT. It is not fixable here
either: `KEYBOARD.DRV` takes its scancode from **port 60h**, and with no
8042 on this machine there is no way to put a byte there. Calling `INT 09h`
ourselves would not help, because the handler would still read port 60h and
find whatever the hardware last latched. The machine's own keyboard covers
typing under Windows.

Windows has never heard of INT 33h. Its mouse support is a DLL named in
`SYSTEM.INI` as `[boot] mouse.drv=`, and the one shipped with Windows 3.0 —
`MOUSE.DRV`, 4,896 bytes, 31 October 1990 — is a pure **PS/2 BIOS** driver:
disassembled, it never touches the 8042. Its contract is `INT 15h AH=C0h`
reporting model `F8/FA/FC`, `INT 11h` bit 2 set, the `C2xx` sequence, and a
callback registered with `C207h` that it reaches by hooking `INT 74h` and
chaining to whatever was there. So `/W` takes `INT 74h` first and delivers
the packet in the frame the BIOS uses.

```
USBCOMBO /W                       load before starting Windows
```

and in `SYSTEM.INI`:

```
[boot]
mouse.drv=mouse.drv
```

It is opt-in because claiming to be a PS/2 model `FC` on an 8086 is a lie
other software can see. All three vectors come back on `/U`.

**Proved without booting Windows.** `PS2TEST` from `CH375Mouse` makes
exactly the calls `MOUSE.DRV` makes, in the same order, and runs unmodified
against this driver — it uses only the `7F00h`/`7F01h`/`7F02h` private
functions, which mean the same thing here:

```
  ok    C205h initialise ... C201h reset ... C207h set callback ... C200h enable
  ok      Y is inverted: USB counts down, PS/2 counts up = -3
  ok      left / right / middle button bits
  24/24 checks passed.
```

That matters because **Windows cannot be exited over the bridge** — it reads
the keyboard at `INT 09h`, so the only way out is the power switch.

Two things to know before trying it live:

* **The tick rate.** This driver divides the PIT by 16 where `USBMOUSE` used
  8. `check_top` hands the rate back when Windows hooks `INT 08h` above us,
  which is what keeps Windows' own timing right. That exposed a bug worth
  knowing about: with the PIT back at 18.2 Hz, dividing the mouse by `/M=4`
  on top would have polled it about **four times a second** — a slideshow,
  not a pointer. The divisor now only applies while the driver still owns
  the timer; when it does not, every tick polls the mouse.
* `/G` does not affect the Windows path. `ps2_emit` reads the boot-shaped
  report *before* the speed multiplier, so Windows gets raw mickeys and
  scales them itself.

## The thing that took the longest

This adapter's mouse interface declares HID **report IDs** — 1 for the
pointer, 2 for system control, 3 for consumer keys — so every packet it
sends leads with an ID byte. It also answers `SET_PROTOCOL 0` with
**success** and then carries on sending that format regardless.

So the request is issued — it is the right thing to ask for, and a device
that honours it makes life simpler — but its answer is not trusted for
anything. `mou_strip_id` reads the format off the packet: strip report 1's
ID, drop reports 2 and 3, pass a 3- or 4-byte boot report through untouched.

**Verified with a hand on the mouse:**

```
  wire (up to 5)   boot      len  verdict
  01 00 0A FB 00   00 0A FB    5  used (ID stripped)
  01 01 F8 0B 00   01 F8 0B    5  used (ID stripped)
  01 03 0E F6 00   03 0E F6    5  used (ID stripped)

  reports USED     : 116
  packets REJECTED : 0
  pointer now      : x=410 y=128 buttons=3
```

Signed X *and* Y both varying, button bits following `00 → 01 → 03` as left
and then both were pressed, and the keyboard half delivering keys into the
BIOS buffer at the same time.

### A wrong turning, recorded rather than buried

Before anyone had moved the mouse, this endpoint delivered a steady stream
of `01 00 XX 00 00` — report 1, no buttons, a small varying X, Y and wheel
zero. Two observations made that look like the *chip* fabricating packets
rather than a mouse sending them: polling this endpoint alone appeared to
give nothing at all, and of 441 packets, **441 carried movement and none
carried none**.

Both readings were wrong.

* `SET_IDLE 0` means *report only when something changes*, so every report
  from a healthy mouse carries a change. A stream in which they all do is
  exactly right, not impossible. That was the load-bearing mistake.
* The runs that saw nothing had a mouse that happened to be sitting still.
  The idle stream was a real, slightly noisy mouse all along.

The version built on that reasoning refused any packet longer than a boot
report, on the grounds that the device had acknowledged `SET_PROTOCOL 0` and
therefore could not be sending five bytes. **It threw away 100% of real
mouse data** — and every automated check still passed while it did, because
they all inject their own reports and never go near the USB read.

What caught it was moving the mouse and watching `COMBOTST /W`.

Two things survive from that detour, and they are worth keeping:

* **`ch_flush`** — a bounded wait must give up, and giving up does not
  cancel the transaction, so a leftover completion could in principle be
  read by the other endpoint's next poll. The reasoning holds; the case has
  never been seen. `n_flush`, `n_tmo` and `m_tmo` all stay 0, and `/S`
  reports them so that is checkable rather than assumed.
* **Asymmetric poll rates** — the keyboard on every tick, the mouse on
  every fourth. Alternating them evenly was tried as a fix for something it
  turned out not to be, and halving the keyboard's rate cost real
  keystrokes; see "Poll rate is the keyboard's ceiling". `/M=n` sets the
  mouse's share.

The lesson is not about this chip. *"No real device would send this"* is a
claim about the device, and the way to settle it is to make the device send
something known — move the mouse — not to reason about what the bytes ought
to look like.

## Why the mouse needs `/G=16`

The pointer is **not** poll-limited, and polling harder does nothing for it.
Moving the mouse continuously, this adapter emits about **33 reports a
second** — the PS/2 mouse's own sample rate arriving through it — while the
driver polls that endpoint at 145 Hz. Nothing is being missed; there is
simply not much to collect, and each report carries a small delta.

So the only lever is multiplication, and `/G` is it. The textbook value of 1
— one screen unit per mickey — assumes a mouse reporting a hundred-plus
times a second and gives a pointer that crawls on this hardware. 16 was
arrived at by trying it: 8 was still slow.

`/G` multiplies the **raw delta**, before the INT 33h sensitivity an
application sets through function `0Fh` or `1Ah`, so it stacks with that
rather than fighting it. The true mickey counters that function `0Bh`
reports are taken before it, so an application measuring raw movement still
sees the truth.

**The cost is honest:** at 33 samples a second a faster pointer is a
choppier one — same samples, bigger jumps. That chop is the device's rate
showing through, and no driver setting removes it. Smoothing it would mean
spreading each delta over the ticks until the next report, which buys
smoothness with about 30 ms of lag.

An earlier version had this backwards in both senses: `/G` set the INT 33h
mickeys-per-unit directly, so *smaller* was faster and it hit a hard ceiling
of 8× because the scaling divides and the divisor cannot go below 1.

## Poll rate is the keyboard's ceiling

A HID boot keyboard report is the **set of keys held right now, in no
defined order** — not a list of events. Two things follow, and both were
measured rather than reasoned about:

* A key pressed **and** released between two polls never happened. Missing
  characters.
* Two keys that go down between the same pair of polls arrive in one report,
  and nothing in the data says which came first.

`CH375Keyboard` polls at 145 Hz and that is a 7 ms window. Typing
`abcdefghijkl` twice through it gave `abcdefghjikl` and `abcdefjilkl` —
characters dropped, and `i`/`j` swapped. At **291 Hz** the same test gave
`abcdefghijklabcdefghijkl`, exactly right, so the default here is `/R=16`.
The typematic constants are counted in fast ticks and had to double with it,
or auto-repeat would run at 58 a second.

**The transposition risk turns out not to bite on this adapter.** Tracing
its report stream with `COMBOTST /KB` shows it appends new usages to the
next free slot, so slot order *is* press order:

```
K  00 00 0D 00 00 ...    j down
K  00 00 0D 0E 00 ...    j still down, k down too   <- rollover
K  00 00 0E 00 00 ...    j up, k held
K  00 00 0E 0F 00 ...    k + l
```

The driver scans slots in that same order, so rollover comes out correct. A
device that reordered its slots would transpose, and nothing could be done
about it.

**The mouse yields to the keyboard.** A tick carrying a key report has
already done the expensive work — report diff, translation, BIOS write,
sometimes an LED transfer — and a mouse transaction on top pushes the
handler toward the length of a whole tick, which at 291 Hz is 3.4 ms. An
overrunning tick is a lost keyboard sample, and typing under heavy mouse
movement was where characters went missing. So `apply_report` clears the
mouse's turn. A delta-reporting device does not notice one skipped sample;
typing notices a lost key.

## The report descriptor it comes from

`HIDREP /I=1` is where the format above was read from — the driver's parsing
is not guesswork:

```
  id  kind     byte.bit  size  count  usage
  1   Input    0.0       1     5      Button 1 .. Button 5
  1   Input    1.0       8     3      X .. Wheel
  2   Input    0.0       1     3      System Power Down .. System Wake Up
  3   Input    0.0       16    1      consumer control
```

Report 1 is therefore `ID, buttons, X, Y, wheel` — five bytes, which is
exactly endpoint 82's max packet. A three-byte boot-report parser pointed at
that reads the button bitmap out of the **ID field** and the X movement out
of the buttons, which is why the ID has to come off first.

Reports 2 and 3 are dropped rather than parsed: reading a system-control
packet as a boot report puts a power-button press into the mouse buttons.
`/T` checks both — report 1 stripped, report 2 refused.

## Two endpoints, two data toggles

The CH375's `SET_ENDP6` carries the data toggle for the transaction about to
be issued, and USB keeps a toggle **per endpoint**. Polling two endpoints
through one toggle variable makes every second transaction on each of them a
toggle mismatch, which the chip reports as `2Bh` and which reads as a flaky
device. So `ep_tog` and `mep_tog` are separate, and each is written
immediately before its own token. This is not tidiness; it is the difference
between working and not.

## What `/F` costs, and a bug it exposed in USBKBD

`/F` installs with nothing attached and keeps looking, retrying the bring-up
from inside the timer interrupt about twice a second.

The code that does that looking — `bringup`, `parse_config`, and the
128-byte `cfg_buf` they parse into — lives **above `resident_end`**, in the
part of the image DOS hands back when the driver goes resident. So a
hot-plug retry runs code and writes buffers in memory DOS has already given
to whatever was loaded next, from inside an interrupt, on a machine with no
memory protection. It works right up until something else uses that memory.

**`USBKBD.COM` 1.7.1 has exactly this bug.** It is recorded in
`CH375Keyboard/CHANGELOG.md` rather than quietly fixed, because fixing it
there means changing what that driver keeps resident.

Here it is fixed the cheap way: when `/F` is given, the whole image stays —
about 14 KB instead of 5 KB — and nobody who does not use `/F` pays for it.

## Memory

| | |
|---|---|
| resident, normally | 5392 bytes (5.3 KB) |
| resident, with `/F` | 14688 bytes (14.3 KB) |
| on disk | 14421 bytes |

Larger than either single driver, which is the price of both halves plus a
full INT 33h implementation in one image.

## Adapters and devices it has been used with

| | |
|---|---|
| **PS2toUSB Adapter** `0E8F:0020`, low speed, two HID boot interfaces (keyboard 03/01/01, mouse 03/01/02) | **keyboard half proven**, mouse half **not yet** -- see below |

Measured on a Gateway 2000 386SX/25 (PicoMEM 1, no 387), 2026-09-20,
CH375 at 260h:

* `USBCOMBO /T` self-test: both delivery paths intact.
* `COMBOTST`: 40 of 40 checks.
* A real PS/2 **keyboard** through the adapter: **305 keys** reached
  INT 16h, none dropped.
* A real PS/2 **optical mouse** through the adapter: nothing at all. Not a
  driver fault, and the evidence is at the USB level rather than ours --
  `USBPOLL /E=2 /I=1` polled the mouse endpoint 1177 times in 40 seconds
  and got **1177 NAKs, 0 packets, 0 errors**. A NAK is the endpoint saying
  it has nothing to report, so the adapter is answering and the PS/2 side
  is producing no data.

  Three things to check before suspecting anything here, in order: the
  mouse is in the GREEN socket (a swap gives exactly this -- keyboard fine,
  mouse silent), the adapter was re-plugged into USB with both devices
  already attached (these adapters usually read their PS/2 ports only at
  power-up), and the mouse really speaks PS/2. Retest with a plain ball
  mouse; that is the open item.

**A trap while testing this.** `USBPOLL` stops on any key in the BIOS ring,
and keys typed through the adapter MINUTES EARLIER are still sitting in it
-- the poll exited "after 0s" twice before that was understood, each run
eating one stale keystroke. Flush the ring first (head := tail at 40:1A).

## Testing

Three layers, and they fail independently on purpose.

**`USBCOMBO /T`** needs no hardware beyond the chip and no keypress. It
drives a usage through `key_down` to INT 16h, then the same key as a whole
report through the press/release diff, then the release; then a mouse report
through `apply_mouse` into the INT 33h coordinates, a button press and
release through the edge detector, and the packet parser in both of its
modes. Seven checks:

```
Self-test: a key through to INT 16h, a report through to INT 33h.
  ok   key_down -> INT 16h gave 1E61h
  ok   a whole report through the press diff -> 1E61h
  ok   the matching release produced no key
  ok   a mouse report moved the pointer 8 across, 4 down
  ok   a button press and release produced both edges
  ok   report 1 stripped, report 2 dropped, boot report kept
  ok   a 5-byte packet refused by a device that agreed to boot
  PASS -- both delivery paths are intact.
```

**`COMBOTST.EXE`** runs with the driver loaded and covers what `/T` cannot
reach: the INT 33h API as an application actually calls it, and what the
device is really putting on the wire. 43 checks, including the idle-pointer
regression test above. It reads the resident copy through the published
pointer block at `0111` rather than through hard-coded addresses — the first
version of it did the latter and confidently reported a neighbouring
variable.

**`COMBOTST /W[=secs]`** watches **both** endpoints live and prints a line
per distinct mouse packet: the bytes as they arrived, the boot report the
driver made of them, the length, and what the driver did with it. At the end
it reports keys delivered and what they were.

**It beeps**, because the one thing no automated check can do is move the
mouse, and a cue nobody hears wastes the run:

| | |
|---|---|
| three rising notes, twice | start moving and clicking |
| one short blip | a report was used — one per report, so movement is audible |
| three falling notes, twice | stop |
| four hard high notes | packets arrived and the driver used none of them |

`COMBOTST /BEEP` plays all four and exits, so you can check you can hear
them before relying on them.

That last cue is not decorative. It is the exact signature of the filter
bug described above, and the run that found it looked like this — 61
distinct packets, every one `REJECTED`, `reports USED : 0`.

Verified on the hardware, this build:

* `/T` — **7/7**
* `COMBOTST` — **42/42**
* `COMBOTST /W` with a hand on the mouse — **116 reports used, 0 rejected**,
  pointer tracking to `410,128`, `buttons=3`, and **6 keys delivered** in
  the same run, arriving at INT 16h as what was typed
* INT 33h vector `0021:40D2` before load → `16DE:11B1` loaded →
  `0021:40D2` after `/U`

## If the keyboard goes completely dead

**Check the BIOS keyboard buffer before blaming the driver.**

```
COMBOTST /BIOS      show it
COMBOTST /FLUSH     empty it
```

The BIOS keeps a 15-entry ring at `0040:001E`. When it is full the BIOS
**discards every new keystroke from every keyboard on the machine** — the
USB one and the machine's own. The symptom is total keyboard death, it
looks exactly like a crashed driver, and it is not one:

```
40:1A head = 001E   40:1C tail = 003C      <- 15 queued, nothing reading
```

Anything that runs without reading the keyboard lets keys pile up —
including DOSBridge's own agent loop, so typing at the machine while that is
polling will do it on its own with no driver loaded at all. `/FLUSH` clears
it without a reboot, and it can be run over the bridge when the keyboard is
too dead to type the command.

**What the driver contributes, and what was fixed.** Auto-repeat used to
carry on at 29 keys a second into a buffer it could not write to. One missed
key-release would then pin the ring full for ever, which turns a lost
release into the whole machine losing its keyboard until it is rebooted.
`buf_put` now reports the drop and `do_repeat` cancels the repeat, so the
ring gets a chance to drain. `/S` counts the drops as `keys dropped (buffer
full)`.

This was found chasing a report that `USBCOMBO /?` killed the keyboard. It
did not: dumping `40:17`, `40:18`, `40:96`, `40:97` and the ring pointers
before and after showed them **byte-for-byte identical**. `/?` prints and
exits through `INT 21h/4C00h` and touches nothing.

## A development footgun

The version string is what `/S` and `/U` compare, and it does not change
between builds during development. Two different images that both say
`1.0.0` pass the version check and then read each other's data at the wrong
offsets. **Always `/U` the old copy before deploying a new build**, and if
the resident copy is from a build you no longer have, reboot.

## Hard limits worth remembering

Exit codes must be ≤ 20, filenames are 8.3, and a DOS critical error blocks
forever and looks exactly like a hang. See `CLAUDE.md` at the DOSBridge
repository root.

## Licence

**Public domain**, under [the Unlicense](https://unlicense.org) — see
`LICENSE` at the repository root.

Written by **StevenC**. <https://github.com/jdredd87/CH375USBTools>
