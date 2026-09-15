# CH375Mouse — a DOS mouse driver for a USB mouse on a CH375

One of four projects in [CH375USBTools](../README.md); this is the mouse
one. See also **[CH375USBTOOLS](../CH375USBTOOLS/)** for class-agnostic probe
tools, and **[CH375Keyboard](../CH375Keyboard/)** for the keyboard driver —
which cannot be loaded at the same time as this one, since one CH375 takes
one host driver.

For a keyboard **and** a mouse together, **[CH375Combo](../CH375Combo/)** is
one driver that does both: it carries this driver's `INT 33h` implementation
unchanged, minus the PS/2 BIOS emulation below. If you need Windows 3.x to
find a pointing device, this is still the driver to load.

## Two kinds of mouse, one INT 33h

`USBMOUSE.COM` drives a **USB HID** mouse plugged straight into the CH375.
The tools below drive a **serial** mouse on a **USB-to-serial adapter**
plugged into the CH375 — a different device, a different protocol, and the
same CH375 card.

| | |
|---|---|
| `USBMOUSE.COM` | **both.** It works out which is attached and installs INT 33h either way. **Working** |
| `MOUPROBE.EXE` | serial mouse on a USB-to-serial adapter: find it, identify its protocol, prove it moves. **Working** |

One driver, two input sources. `USBMOUSE.COM` enumerates whatever is on the
CH375; if it finds no HID interface it asks whether the device is a
USB-to-serial adapter, and if it is, opens the port at 1200 8N1 with RTS and
DTR raised and decodes serial mouse packets instead of HID reports.

### Two adapters, two mice, two protocols

| adapter | mouse | verified |
|---|---|---|
| Keyspan `06CD:0121` | Mouse Systems, 5 bytes, 3 buttons | `MOUSETST` 34/34, `PS2TEST` 25/25 with real packets, four consecutive runs, 0 resyncs |
| FTDI FT232 `0403:6001` | Microsoft, 3 bytes, 2 buttons | `MOUSETST` 34/34, 255 reports, 0 resyncs — **on an older driver**; see below |
| Prolific PL2303 `067B:23A3` | **both, from the same mouse** | `MOUSETST` 34/34, `PS2TEST` 25/25 with 200 PS/2 packets, `CLICKTST` 1329 reports with matched press and release counts on all three buttons |

Every one of them is read at **1200 8N1**. The mouse column is which
protocol was spoken, not how the port was opened -- and on the PL2303 it is
both -- the same mouse has been read as each, and what selects it is not
known; see below.

**Only the FTDI row is not current.** It was measured before the serial path
was reworked -- the stream detector, the re-decision, and
`SET_RETRY` moving to one caller all landed afterwards, and that last one
alone changed `bytes resynced past` from 77 to 4. None of that is
adapter-specific and all of it should be an improvement, but "should" is
what this file has already spent hours on. It is recorded as verified
against an older driver rather than carried forward, and re-running it is a
two-minute check with that adapter plugged in: `MOUSETST` 34/34 and `/S`
reporting the expected protocol with the re-decision count at 0.

### One framing reads both protocols

The driver used to open at 7N1, listen about a second for the `'M'` a
Microsoft mouse sends at power-up, and fall back to 8N1 on silence. That is
gone, and both halves of it were wrong.

**The announcement is not reliable.** The identification scanned the whole
power-up burst for `'M'`, and a mouse being *moved* during that window is
sending movement bytes -- one of which was `4Dh`. A Mouse Systems mouse was
confidently identified as Microsoft on exactly that.

**And 7N1 was never needed.** A Microsoft mouse sends seven data bits, so
reading it at EIGHT captures the stop bit as bit 7 and every byte arrives
with `80h` set: the `40h` header reads as `C0h`, the `00-3Fh` bodies as
`80-BFh`. Framing still works, because the receiver then takes the idle line
as its stop bit.

That is a gift, because at 8N1 the two protocols occupy ranges that do not
overlap:

| | header | packet |
|---|---|---|
| Microsoft at 8N1 | `C0-FF` | 3 bytes, bodies `80-BF` |
| Mouse Systems | `80-87` | 5 bytes |

So one framing reads both, the decoder tells them apart from the data, and
nothing depends on an announcement that may never come or may arrive by
accident.

**The adapter and the mouse are decided at different moments.** Which
ADAPTER it is comes from the USB ID, before the port exists. Which MOUSE it
is comes from the stream afterwards, and because both protocols are read at
one framing, nothing has to be known before the port is opened.

That is why the install banner does not name a protocol. It used to, before
a single byte had arrived, which was a guess printed as a fact:

```
Serial mouse (protocol decided from the stream; /S reports it): bulk IN 3, control OUT 2, VID/PID 067B/23A3
USBMOUSE 1.1.0 resident.  INT 33h installed.
```

`/S` answers it once the mouse has spoken, with the count of how many times
the driver had to change its mind:

```
  protocol seen=Mouse Systems, 1200 8N1, 5 bytes.    protocol decided again=0
```

Nothing about the protocols resembles each other:

| | Mouse Systems | Microsoft |
|---|---|---|
| the mouse sends | 8 data bits | **7** data bits -- but both are READ at 8N1, see above |
| packet | 5 bytes | 3 bytes |
| sync bit | bit **7** of the header | bit **6** of the header |
| movement | two whole samples, summed | **split across bytes** -- top 2 bits of each axis ride in the header |
| buttons | **active LOW** | active HIGH |
| Y | counts up | already screen sense |

Decoding one with the other's rules does not fail loudly. Using Mouse
Systems' active-low buttons on a Microsoft mouse reports a press on **every
single packet**, which is what this driver did when it first met one.

**An FTDI never NAKs.** It answers every poll with its two status bytes and
no data, where a Keyspan NAKs when it has nothing. "Drain until it NAKs" is
therefore a complete stopping rule on one part and an infinite loop's worth
of wasted USB transactions on the other -- four per tick at 145 Hz, in the
timer interrupt, for an idle mouse. The drain stops on a read that contained
no DATA, which is right for both.

### The box locked on the Keyspan, and it was a BAD USB CABLE

Resolved 2026-09-15. Kept in full because the three software theories it
generated were all plausible, all wrong, and each took real effort to kill --
and because the one measurement that would have pointed at hardware
immediately was available the whole time.

What happened. Two jobs ran back to back against a Keyspan `06CD:0121` with a
serial mouse on a jiggler, so the mouse moved continuously and nobody clicked
it.

| job | commands | result |
|---|---|---|
| `49a2` | `/U`, `/W`, `MOUSETST`, `PS2TEST` | **ok, 29.0s.** `PS2TEST` 25/25 with 186 real PS/2 packets |
| `34d9` | `MOUSETST`, `PS2TEST`, `/S` | started, never returned. Box stopped polling |

**The evidence that mattered was already on the table and was read as
software.** After the lock-up the box was power-cycled. It came back
perfectly -- packet driver, agent, network -- and the CH375 itself was fine,
`CHECK_EXIST` returning `AA` and IC version `B7`. But `TEST_CONNECT` returned
`16`, device disconnected, across two cold boots, and `USBMOUSE`'s full
bring-up found nothing either. **The adapter was electrically absent.** A
replacement USB cable brought it straight back.

The confirmation, with the new cable and nothing else changed -- the same job
that hung, run four times:

| run | `MOUSETST` | `PS2TEST` | resyncs | backlog | re-decisions |
|---|---|---|---|---|---|
| 1 | -- | 25/25, 8 real packets | 0 | 0 | 0 |
| 2 | 34/34 | 25/25 | 0 | 0 | 0 |
| 3 | 34/34 | 25/25 | 0 | 0 | 0 |
| 4 | 34/34 | 25/25 | 0 | 0 | 0 |

Three theories died on the way, and the order is the lesson.

* **A stale PS/2 callback.** The most attractive by far: `PS2TEST`'s last
  three checks are `C200h disable`, `no callbacks once disabled`, `C200h
  re-enable`, which reads as exiting with reporting ON and a callback into
  freed memory -- and the driver would then `far call` into whatever loaded
  next. It is wrong. `ps2test.pas` ends with `C2($00,0)` and `C207h` with
  `ES:BX = 0:0`, and `i15_sethnd` stores `ES` into `ps2_hsg` correctly, which
  `ps2_emit` tests before calling. Killed by reading the source.
* **`SET_RETRY` left at `8F`**, the bug that has appeared five times in these
  projects and would have been a sixth. All three families call
  `ser_poll_ready` on their success path and the bring-up calls it again
  afterwards. Killed by reading the source.
* **The BIOS tick stopped advancing.** Every wait in these tools is `repeat
  until Now100 - T0 >= n`, so a frozen tick hangs them silently. Weakened by
  reading -- `int08` chains to `old08` regardless of `poll_off` -- and then
  **killed by measurement**: with the driver resident, `TICKCHK` reads `INT
  08h` and `INT 1Ch` at 18 Hz, twice, exactly as with no driver loaded.
* **Interrupt livelock** was the last one standing, and it had real
  arithmetic behind it: 145 Hz ticks, up to 4 reads per drain, against a chip
  that sustains 110-138 packets/s. It was also wrong, and the number that
  killed it is worth keeping. **A jiggler is not a fast mouse.** It produced
  110 bytes in 12 seconds against 982 for a human hand -- about a NINTH the
  data rate, with deltas of one or two counts. The hang happened under
  unusually LOW traffic, which is the opposite of what livelock needs.

**The lesson is the order, not the theories.** Every one of those was
reasoned from the code, and the code was the wrong place to be looking. The
question "is the device still on the bus?" costs one `CHDIAG` run and was
never asked until three software explanations had been built and demolished.
On a machine where a plug can fail, `TEST_CONNECT` belongs at the TOP of the
list, before any reasoning about interrupt handlers.

One reading that is expected rather than a fault: with a jiggler there is
nothing to click, so `buttons seen=00` and the driver's "no button bit has
ever arrived" note are correct. The button paths are covered by `MOUSETST`'s
synthetic checks, which pass 34/34, and by `CLICKTST` with a hand present.

### The same mouse speaks either protocol, and nobody knows what picks it

The mouse on the bench has been read as **Mouse Systems** by `MOUPROBE` and
as **Microsoft** by this driver, minutes apart, on one adapter, without being
unplugged. That is not a detector being flaky -- both readings are correct,
and the byte streams are unambiguous.

**The mechanism is not known, and the first answer was wrong.** It looked
like the middle button: the Logitech convention is that a mouse switches to
Mouse Systems to report a third button, since Microsoft has no way to carry
one. Two probe runs fitted perfectly --

| run | buttons seen | ended as |
|---|---|---|
| 1 | left right **middle** | Mouse Systems |
| 2 | left right | Microsoft |

-- and it was written up as established. It is not. Tested directly, with
the driver resident and the mouse in Microsoft mode, pressing **only the
middle button, repeatedly**:

```
  button bits ever seen in a raw report: 03
  press counts   left=2  right=6  middle=0
  protocol seen=Microsoft, 1200 7N1, 3 bytes.    protocol decided again=0
  serial reads=1841  packets=1840  bytes resynced past=3
```

1840 packets decoded, resyncs unchanged, protocol unmoved. **The middle
button does not switch this mouse.**

What the evidence does support is that the protocol is settled **at
power-up**, and that opening the port IS a power cycle -- `SerOpen` raises
RTS and DTR, which is where the mouse gets its power. So every open is a
fresh roll, and the answer is not stable:

| who opened it | adapter | protocol |
|---|---|---|
| `MOUPROBE` | Keyspan | Mouse Systems |
| `USBMOUSE` | Keyspan | **Microsoft** |
| `USBMOUSE` | Keyspan, minutes later | **Mouse Systems** |
| `USBMOUSE` | PL2303 | Mouse Systems |

The second theory was that the two programs bring the lines up differently.
Rows three and four killed that too: the SAME program on the SAME adapter
got both answers, minutes apart, with nothing changed. It is not the
program, and it is not the adapter.

The honest version is: **unknown**, and possibly timing-dependent in a way
nothing here controls. That is written down rather than replaced with a
third theory, because the first two were each convincing and each survived
about a day.

**Which is why the driver decides from the stream and decides again.** Not
knowing the mechanism is exactly the case for not depending on it. A driver
that latches the protocol once is betting the answer never changes under it,
and the cost of losing that bet is total -- wrong framing, wrong button
sense, wrong movement, until it is reloaded.

The re-decision trigger has to be one a healthy stream cannot pull, because a
lone odd byte is normal: the CH375 drops them. `ser_bad` counts bytes thrown
away **with no report delivered between them**, and every delivered report
clears it, so a single drop never gets near the threshold of 8. A decoder
reading the wrong protocol fails continuously and reaches it inside about two
packets.

Measured both directions on hardware:

| | re-decisions | reports |
|---|---|---|
| started correct, 3280 serial reads | **0** | 1329 |
| started deliberately locked to the WRONG protocol | **1** | 1329 |

The second row is the one worth keeping: a build with the protocol pinned
wrong on purpose, meeting a real mouse with real movement and real clicks. It
converged immediately and finished with matched press and release counts on
all three buttons. A recovery path that has never run is not a recovery path.

**A real consequence, visible in the button counts.** Microsoft carries two
buttons, so when the mouse comes up in that mode the middle button is not
merely unreported -- it does not exist on the wire. `CLICKTST` shows `button
bits ever seen 03` and `middle=0`, and that is correct behaviour, not a lost
press. The same mouse through `MOUPROBE`, which got Mouse Systems, reports
`left right middle`.

### A wrong diagnosis, and how it was reached

This section said for a while that the mouse on the bench was a **3-byte MM
Series** device and that the driver had been wrongly assuming 5-byte Mouse
Systems framing. That was wrong, and the way it went wrong is worth keeping.

The driver really was losing 40% of its bytes, steadily, through four
unrelated fixes. The cause was `SET_RETRY`: the serial bring-up returned
before the point where the chip is put back to reporting NAKs, so it stayed
on `8F` — retry NAKs for ever — and every poll of an idle endpoint ran to a
full timeout. Bytes went missing.

**Losing two bytes out of every five makes a five-byte packet look like a
three-byte one.** The header lands three bytes after the last one, the
values in between are plausible movement, and the stream reads as a
textbook MM Series capture. So the byte loss was diagnosed as a second,
independent fault — a protocol mismatch — when it was the first fault
wearing a disguise.

`MOUPROBE` read the same mouse as clean 5-byte Mouse Systems throughout,
because it polls from the foreground and never hit the retry bug. Two
readers disagreeing about one mouse was the clue, and it was treated as
"the probe must be right about the protocol" rather than "one of these two
is losing data".

With the retry fixed, the stream is unambiguous:

```
87 00 00 00 00 | 83 00 00 00 00 | 81 00 00 00 00 | 87 00 00 00 00
bytes resynced past = 0
```

Headers every five bytes, and nothing discarded.

**The decoder handles both anyway**, and that is the part worth keeping
rather than the diagnosis. After three bytes it looks at the fourth: a
header means the packet was three bytes and that byte starts the next one;
anything else means it is `dx2` and the packet is five. Being wrong costs
one packet and corrects itself, where the fixed assumption never did. A
3-byte MM mouse will work on this driver even though the one that prompted
the work turned out not to be one.
Everything above the input layer — INT 33h, the cursor, the event handlers,
the PS/2 emulation for Windows 3.x — is shared, because none of it cares
where a report came from. `apply_report` takes three bytes (buttons, dx, dy)
and a serial packet decodes into exactly those.

```
USBMOUSE 1.1.0 -- StevenC
Serial mouse on a USB adapter: bulk IN 1, control OUT 2, VID/PID 06CD/0121
USBMOUSE 1.1.0 resident.  INT 33h installed.
```

**Windows 3.0 works.** `USBMOUSE /W` also presents the mouse as a PS/2 BIOS
pointing device, and that path is above the input layer, so it does not care
that the reports arrived over a serial adapter. `PS2TEST` — which replicates
the exact call sequence Windows 3.0's `MOUSE.DRV` makes — passes 25/25 with
the serial mouse, with **160 real packets delivered** through the PS/2 path
while the mouse was moved.

`MOUSETST` against it, with the mouse being moved and clicked:

```
  reports delivered by the mouse: 130
  live position 0,95 buttons 6
34/34 checks passed.
```

**Both movement samples in a packet are delivered, not summed.** Mouse
Systems sends two successive samples per packet; adding them together is
correct arithmetic and halves the number of cursor updates, so the pointer
moves in fewer, larger steps. Delivering both doubles the update rate for
nothing, and removes an overflow as a side effect — +100 and +100 summed in
a byte is -56, so a fast flick used to reverse direction.

The default `/R=8` gives a 145 Hz poll, which is what makes a serial mouse
feel like a mouse: latency, not bandwidth, is the quality bar here. 1200
baud and five bytes a report is 120 bytes/second against a chip that
sustains about 19,000 — the only project in this collection where the
CH375's packet rate cannot be the limit.

**Nothing in the serial half is tied to one adapter.** `src/dmouse.pas` knows
the two serial mouse protocols and nothing else — it never sees a USB device.
Underneath it, `CH375Serial`'s `dser.pas` dispatches on the adapter family
(CDC-ACM, FTDI, PL2303, CH34x, CP210x, Keyspan), so a mouse driver written
against `dmouse` works on whatever adapters that unit can drive, now and
later.

The thing that could have locked it to one adapter is that **a serial mouse
is powered from RTS and DTR**. An adapter that will not raise them leaves the
mouse dead, and a dead mouse is indistinguishable from a wrong baud rate, a
bad cable, or an unsupported adapter. `SerOpen` raises both on every family
and `SerClose` drops both, so a close/open pair is a power cycle with no
adapter-specific code — which is also what makes a mouse announce itself.

**`MOUPROBE` no longer does that, and the reason is a warning.** It used to
open, close and open again to force the announcement out of a Microsoft
mouse. On a PL2303 that pair left the adapter delivering **nothing at all**,
intermittently, which presents exactly as an unpowered mouse and sent the
tool hunting RTS and DTR for an evening. What settled it was running the
*driver* against the same adapter in the same state — 263 reports, 34/34.
The adapter was healthy and the diagnostic was the broken one.

The announcement is not needed now in any case: the protocol comes out of
the stream, which works for a mouse that says nothing, for one being moved
while it speaks, and for one that changes protocol halfway through. So the
probe opens once, and a mouse that was unpowered gets its power-on from that
single `SerOpen` anyway.

Verified on a Keyspan (InnoSys) `06CD:0121` against a three-button mouse:

```
  device              : 06CD:0121
  family              : Keyspan (InnoSys)
  configuration index : 1
  bulk IN / OUT       : 81 / 01

  87 FE 06 FB 06  87 F6 06 F7 02  87 F2 00 FC FC  ...

  reports decoded    : 196
  bytes resynced past: 0
  net movement       : X -99  Y 258
  buttons seen       : left right middle
```

**196 reports and zero resyncs** is the number that matters: the decoder
stayed in phase for the whole run, which is much stronger evidence than the
movement totals.

### The first run looked like a dead mouse and was a wrong number

882 bytes arrived and fitted no protocol. The mouse was perfect. The line was
open at **seven** data bits and the mouse is Mouse Systems, which is eight —
so bit 7 was being stripped and every `87h` packet header arrived as `07h`,
every `FFh` movement byte as `7Fh`.

That is the same trap DOSBridge's `docs/input.md` records from the other
direction: this machine's own mouse is Mouse Systems, CuteMouse probed it,
settled on Microsoft, and INT 33h then reported no movement at all.

So `MOUPROBE` diagnoses it by name rather than shrugging:

```
  THE FRAMING IS WRONG AND THE MOUSE IS FINE.
  These bytes are a Mouse Systems stream read through SEVEN
  data bits: 87h headers arriving as 07h, every fifth byte...
```

The detector took two attempts, and the first was wrong arithmetic rather
than a wrong idea. Counting header-shaped bytes across the whole stream is
weak — small movement values pass a header mask perfectly well. The signal is
**period**: every Nth byte is a header and the ones between are not. The
first version then compared the best phase against the *sum* of the other
four, which is the wrong denominator, and scored a textbook capture 13
against 30 and rejected it.

The rule that survived, chosen after looking at the numbers rather than
before: **exactly one phase is entirely headers.** On a correct capture that
is 13 of 13 against 0; on the same mouse read through seven bits it is 13 of
13 against a next-best of 9 of 13 — so a ratio test cannot work and
"all of them, and only here" can. Requiring *exactly one* such phase is what
rejects a buffer of zeros, where every phase matches.

It was validated offline against both captures plus a synthetic Microsoft
stream, an all-zero buffer and noise, before being built — which cost
nothing and saved asking a human to wave a mouse at it five more times.

**Version 1.0.0** · StevenC · <https://github.com/jdredd87/CH375USBTools>

`USBMOUSE.COM` is a resident DOS mouse driver that gets its input from a USB
HID mouse plugged into the WCH **CH375** ISA card at I/O `260h`. It enumerates
the mouse itself — bus reset, speed negotiation, descriptors, address,
configuration, HID boot protocol — then polls the interrupt IN endpoint from a
timer hook and presents the result to DOS as a standard **INT 33h** driver.

It is written in assembly and assembles either with `nasm` on Windows or with
`MNASMFIX.COM` on the DOS machine itself. Both produce a byte-identical
7,029-byte image; that is checked, not assumed.

**Working on the development machine**, against a low-speed Pixart optical
mouse (VID `093A`, PID `2510`) on a CH375B rev B7:

```
USBMOUSE 1.0.0 -- StevenC
Low-speed device; USB bus set to 1.5 Mbps.
USB mouse on CH375: endpoint 1, HID interface 0, VID/PID 093A/2510
USBMOUSE 1.0.0 resident.  INT 33h installed.
```

```
  t=0s   x=320 y=100  col=40 row=12  buttons=0
  t=2s   x=312 y=165  col=39 row=20  buttons=0
  t=3s   x=304 y=199  col=38 row=24  buttons=0
  t=9s   x=303 y=82   col=37 row=10  buttons=0
reports received during the demo: 1043
```

---

## Files

`bin\` holds the built tools, committed deliberately: the machine this
targets has no compiler for them, and `USBMOUSE.COM` is the thing most people
actually want.

| | |
|---|---|
| `src/usbmouse.asm` | the driver. Assembles to `USBMOUSE.COM`, 7,029 bytes, of which about 1.5 KB stays resident |
| `src/chdiag.pas` | CH375 diagnostic: the same bring-up, printing every command, status and chip register |
| `src/mousetst.pas` | INT 33h conformance test — 34 checks against a loaded driver |
| `src/evtest.pas` | INT 33h function 0Ch test — 19 checks that the event callback fires for the right events and only those |
| `src/ps2test.pas` | PS/2 BIOS emulation test — 25 checks, replicating the exact call sequence Windows 3.0's `MOUSE.DRV` makes |
| `src/tickchk.pas` | measures the INT 08h and INT 1Ch rates a handler hooking *after* the driver sees |
| `src/clicktst.pas` | button diagnostic: watches the raw report, the INT 33h mask and the press counters together, and beeps so you know when to click |
| `src/mdemo.pas` | shows the cursor and reads the mouse for 25 s, so the pointer can be watched moving |
| `src/clkchk.pas` | proves the DOS clock still keeps time with the driver's PIT change in place |
| `CHANGELOG.md` | what changed in each version |
| `tools/MNASMFIX.COM` | mininasm, patched so it does not create its output read-only. Assembles the driver on the DOS machine itself; not my work, included so the repository is self-contained |

## Building

```
build.cmd                 build everything into bin\
build.cmd test            ...then run MOUSETST and EVTEST on the DOS machine
build.cmd diag            ...then run CHDIAG there
build.cmd ps2             ...then run the PS/2 BIOS emulation test
build.cmd demo            ...then drive the on-screen cursor for 25 s
build.cmd click           ...then watch the button path for 30 s
build.cmd dosbuild        ...then assemble the driver on the DOS machine
                          too, and check the two images match exactly
```

The build itself needs only **Free Pascal** cross-compiling to MS-DOS real
mode (`-Tmsdos -Pi8086`) and **nasm**, which ships with it. Nothing in the
tree depends on anything but the RTL's `Dos` unit.

The targets that run something on the DOS machine additionally need
[DOSBridge](https://github.com/jdredd87/DOSBridge) to reach it; set
`DOSBRIDGE` if it is not in `C:\dosbridge`. Everything here can equally well be copied to the DOS
machine by any other means and run there by hand.

---

## Version

The driver carries a version number from 1.0.0 onwards, and prints it on
every run:

```
USBMOUSE 1.0.0 -- StevenC
```

It is written down in exactly one place — `ver_str` in `src/usbmouse.asm`,
immediately after the resident signature:

```asm
signature:
        db      'USBMOUS1'                      ; 0103
ver_str:
        db      '1.0.0$'                        ; 010B
```

That string is both what gets printed and what stays resident, so there is no
second copy to forget. Releasing is: bump it, add a `CHANGELOG.md` entry,
rebuild, `git tag -a v1.2.3`.

Because it is resident, and at a fixed offset, `USBMOUSE /S` reports the
version of the copy that is **already loaded** rather than its own — which is
the number you want when you are not certain which build went resident:

```
Loaded: USBMOUSE 1.0.0.  live=1  endpoint=1  reports=0  timer divisor=8 ...
```

Any program can read it the same way: follow the `INT 33h` vector to the
driver's segment, check for `USBMOUS1` at `0103h`, then read ASCII from
`010Bh` up to the `$`. `MOUSETST` does exactly that, and checks it looks like
a version rather than checking it against a fixed number, so the check keeps
working across releases. Builds before 1.0.0 have nothing at `010Bh`.

Do not confuse this with **INT 33h function `24h`**, which reports `7.00`.
That is the API level — which interface the driver implements, so that
applications know which calls they may make — and it has nothing to do with
which build is answering.

---

## Using it

```
USBMOUSE                  enumerate and install
USBMOUSE @260             CH375 I/O base in hex (default 260).  /S prints
                          the base the loaded copy actually took
USBMOUSE /?               the full help screen
USBMOUSE /V               trace each bring-up step and the status it returned
USBMOUSE /F               install even with nothing attached, and keep looking
USBMOUSE /E=n             skip enumeration, poll endpoint n regardless
USBMOUSE /W               also present the mouse as a PS/2 BIOS pointing
                          device, so Windows 3.x can see it
USBMOUSE /K               keep the fast poll rate even when another program
                          hooks the timer after us
USBMOUSE /R=n             PIT divisor; poll rate is 18.2 * n Hz (default 8)
USBMOUSE /S               is it loaded, and what state is the USB side in
USBMOUSE /U               unload: restore INT 33h, INT 08h and the PIT
```

`/U` refuses to unload if something else hooked INT 08h afterwards, because
unhooking out of order would leave that other handler pointing into freed
memory.

### What INT 33h functions are implemented

Everything an ordinary DOS application asks for:

`00h` reset · `01h`/`02h` show/hide cursor · `03h` position and buttons ·
`04h` set position · `05h`/`06h` button press/release counts and positions ·
`07h`/`08h` coordinate ranges · `0Ah` text cursor masks · `0Bh` motion
counters · `0Ch` install event handler · `0Fh` mickeys per 8 pixels ·
`14h` swap event handler · `15h` state buffer size · `1Ah`/`1Bh` sensitivity ·
`1Fh`/`20h` disable/enable · `21h` software reset · `23h` language ·
`24h` API level and type (reports 7.00 — the interface level, not this
driver's own version; see [Version](#version)).

Two private functions exist for testing, outside the Microsoft numbering:

* `AX=7F00h` — status: `BX` = USB state (0 nothing, 1 enumerated, 2 attached
  but not enumerated), `CL` = endpoint, `CH` = last CH375 poll status,
  `DX` = report count.
* `AX=7F01h` — inject a HID boot report: `BL` buttons, `CL` dx, `CH` dy. It
  runs through the identical code a real report takes. `MOUSETST` drives this,
  which is what lets the INT 33h half be tested exhaustively without needing a
  human to wave the mouse in a particular pattern.
* `AX=7F03h` — the last raw HID report: `BL`/`BH` = bytes 0 and 1, `CL`/`CH`
  = bytes 2 and 3, `AL` = every button bit ever seen, `AH` = the last report's
  length, `DX` = how many reports carried a button down. `CLICKTST` uses it to
  tell "the mouse never sent a press" apart from "the driver dropped it".
* `AX=7F02h` — suspend (`BX=1`) or resume (`BX=0`) the driver's own polling;
  the previous setting comes back in `BX`. `MOUSETST` needs it: with a live
  mouse, real reports land between an injection and the read-back and the
  deterministic checks become a race. It is also the polite way for an
  application to stop the timer touching the CH375 while it uses the card for
  something else.

**Not implemented: the graphics-mode cursor.** In text modes the driver draws
the classic software cursor (attribute inverted through the `0Ah` screen and
cursor masks, `77FFh`/`7700h` by default). In graphics modes coordinates and
buttons work normally but no pointer is painted — applications that draw their
own, which is most of them, are unaffected. Functions `09h` (graphics cursor
shape) and `10h` (exclusion area) are accepted and ignored rather than
rejected, so callers that set them still run. `18h`/`19h` (alternate event
handlers) return `AX=FFFF` — "not supported", the documented answer.

---

## How it works

### Polling, and why the timer

DOS is not reentrant and this card gives the CH375's INT# pin no useful IRQ
wiring, so the mouse has to be polled. The BIOS tick is 18.2 Hz, far too slow
to track a pointer, so the driver takes over **INT 08h** and divides the PIT by
8 → 145.6 Hz. Every eighth call is forwarded to the original handler, so BIOS
timekeeping, the DOS clock and anything else on INT 08h see exactly the rate
they expect. `clkchk` measures this: 20.0 s of DOS clock in the same wall-clock
time with and without the driver resident and polling.

Each tick issues one interrupt IN token. Retries are turned off after
enumeration (`SET_RETRY` with `25h 00h`), so a mouse with nothing to report
NAKs and the transaction is over in microseconds — `/S` reports `2Ah` as the
usual last status, which is exactly right. If the device does not answer within
a bounded ~3 ms spin the tick is abandoned rather than blocking; with `/E=1`
against a device that never answers, the box runs at 145 failed transactions a
second and stays completely healthy.

A reentrancy flag keeps a tick out of the CH375 while an earlier one is still
in it.

### Giving the tick back when we are not first

Dividing the tick on the way *down* the chain only helps the handlers that are
below us. Anything that hooks INT 08h **after** the driver sits above that
division and sees all 145 interrupts a second, so every timer it runs goes
eight times too fast. Windows is exactly that case — it has to be started
after the driver is loaded — and a Windows whose tick runs eight times fast
has a double-click window eight times too short. Single clicks worked there;
double clicks did not.

`TICKCHK` measures this directly by hooking INT 08h the way Windows does:

```
                    INT 08h    INT 1Ch
  before the fix    144 Hz      18 Hz
  after the fix      18 Hz      18 Hz
```

INT 1Ch was always correct, because the BIOS INT 08h handler is what issues
it and we call that only every eighth interrupt — so a program using the BIOS
user tick never saw the problem.

The fix is for the driver to notice when the INT 08h vector stops being its
own and put the PIT back to 18.2 Hz, then take the fast rate again when it
gets the vector back — which happens by itself when Windows exits. The cost is
that the mouse is polled at 18.2 Hz while such a program is loaded, so the
pointer moves in bigger steps; the distance is still right, because a HID
mouse accumulates movement between polls.

Reprogramming the PIT from inside the timer interrupt means the two routines
that do it must not touch the interrupt flag: `pit_fast` and `pit_slow` now
leave IF entirely alone and the caller states what it is, with `pit_fast_cli`
and `pit_slow_cli` for the INIT and unload paths that run with interrupts on.
An `STI` in there would let a second tick nest inside the first. Doing it with
`PUSHF`/`POPF` instead looked tidier and is not worth it on a CPU whose `POPF`
carries an erratum.

The obvious alternative — snatching the vector back and pushing the newcomer
underneath — was rejected. It needs a stored pointer to the displaced handler,
and once that handler unhooks itself (Windows restores the vector on the way
out) the pointer refers to freed memory with no way to tell. Getting that
wrong crashes the machine, where this merely slows the mouse down. `/K` keeps
the fast rate for anyone who would rather have the smoothness and does not
care what else is running.

### Position and buttons

Movement is accumulated in eighths of a virtual unit before being divided by
the sensitivity, so slow movement is not lost to truncation — the thing that
otherwise makes a mouse feel dead at low speed. Coordinates live in the
standard 640×200 virtual space and are clamped to the `07h`/`08h` ranges.
Button edges are counted per button, with the position each press and release
happened at, which is what functions `05h` and `06h` return.

### Reading the video mode

`cursor_ok` reads the video mode from BIOS data at `40:49`, not with INT 10h
`AH=0Fh`. This code runs inside the timer interrupt and the BIOS video service
is not reentrant; a tick landing while the foreground is inside INT 10h would
corrupt it. The column count comes from `40:4A`, and mono vs colour picks
`B000` or `B800` — decided **every time**, because on this machine the video
card is not the same from one boot to the next.

---

## Two things that stop it dead, neither of them the driver

**Another driver owning the chip.** `CH375R9.SYS` / `CH375DOS.SYS` in
`CONFIG.SYS` is the vendor's USB-disk driver, and it resets the CH375 into
disk mode and keeps it there. There is one chip, one USB port and one device
at a time, so the two cannot share it — it is the disk driver or this one, and
that is a property of the hardware rather than something to engineer around.
`MEM /C` shows it as `CH375R9`.

**A wedged device.** Nothing in software cuts VBUS, so no amount of
`RESET_ALL` or bus resetting will clear a USB device that has got itself
confused — and one that has been through a couple of Windows sessions and a
stint underneath the disk driver can. The symptom is precise and misleading:
the chip reports the device attached, identifies its speed correctly, accepts
the low-speed switch (`reg17` goes `90h` → `D8h`), runs SOF — and then every
transfer returns `20h`, no answer at all. Unplug it and plug it back in; that
is the only fix, and it works immediately.

Both were mistaken for driver faults during development, which is why
`CHDIAG` now lists them in that order before it mentions the cable.

## The low-speed problem, and where the switch has to go

Nearly every USB mouse is a **1.5 Mbps low-speed** device. The CH375 comes up
driving the bus at 12 Mbps, and a low-speed device simply cannot hear it: every
transaction returns `24h`, `USB_INT_RET_TOUT`, meaning the token went out and
nothing came back. A USB stick on the same card enumerates perfectly, which
makes this look convincingly like a hardware fault and is why it took so long
to find.

Two commands solve it, **neither of which is in the CH375 part-I datasheet** —
both are documented for the CH376, and this B7 firmware turns out to implement
them:

```
0Ah sub-address 07h    GET_DEV_RATE    bit 4 set = 1.5 Mbps low-speed device
04h data 02h           SET_USB_SPEED   drop the bus to 1.5 Mbps
```

**Where the second one goes is the entire trick.** `SET_USB_MODE` puts the bus
back to 12 Mbps, so the speed has to be set after the last mode change — but
issued straight after `SET_USB_MODE 6` it is **silently ignored**: no error, no
status, no register change, and every transaction still times out exactly as if
the chip had no low-speed support at all. It only takes once the connect
interrupt raised by the bus reset has been read and cleared.

So the working order is:

```
SET_USB_MODE 5      host enabled, no SOF -- the idle state
wait for USB_INT_CONNECT
SET_USB_MODE 7      hold the bus in reset
SET_USB_MODE 6      host enabled, auto SOF
wait for USB_INT_CONNECT     <- the second one, raised by the reset
drain any further interrupts
SET_RETRY 25h 8Fh
GET_DEV_RATE -> if bit 4, SET_USB_SPEED 02h        <- only works here
GET_DESCR 1 / SET_ADDRESS / SET_USB_ADDR / GET_DESCR 2 / SET_CONFIG
SET_PROTOCOL boot, SET_IDLE 0
poll the interrupt IN endpoint
```

You can see it take: register `17h` goes `90h` → `D8h` the moment the speed
command lands, and `chdiag` prints that. If it still reads `90h`, the command
was issued too early.

**If you move the connect wait or the drain, this stops working**, and the
symptom is a total silence on the bus that looks nothing like a sequencing bug.
That is why `bu_conn` waits for the interrupt rather than sleeping through it.

Two of my own bugs hid behind this for a while and are worth knowing about,
because both produced symptoms that pointed at the hardware:

* `ch_read` returned "`CL` = length" but the `LOOP` that walks the buffer
  leaves `CX` at zero, so the configuration descriptor always arrived with
  length 0 and a perfectly enumerated mouse looked like it had no endpoints.
* The `/V` trace helper ended with `crlf`, which leaves `AL = 0Ah`; the
  `test al,10h` deciding whether to switch to low speed ran straight after it
  and therefore never fired. Adding tracing switched the feature off.

---

## What the CH375 actually does

Worth writing down, because the part-I datasheet documents only the built-in
USB-disk firmware and several widely-copied constants are wrong for this chip.

**Ports on this ISA card**, from the PLD source (`CH375ISA.PLD`):

```
usb = aen & addr:[0260..026f] & !a1 & (ior # iow);   ; A0 picks data/command
d0  = int ;  d0.oe = aen & addr:[0260..026f] & a1 & ior
```

so `base+0` is data, `base+1` is command, and `base+2` bit 0 is a readback of
the chip's INT# pin. Only A9..A4 and A1 are decoded, so the chip also appears
at `264h`, `268h` and `26Ch`.

**Two ways to see the interrupt.** From revision B5 the chip returns a status
byte when you *read* the command port, with bit 7 clear meaning an interrupt is
pending — one `IN` instead of two, and independent of the board. Before B5 you
must use the board's `base+2` bit 0. The driver checks the revision at install
time and refuses to run on anything older rather than silently polling the
wrong port. This chip is **B7**.

**Commands 0Ah and 0Bh take a sub-address.** The datasheet lists only
`GET_MAX_LUN` (`0Ah` + `38h`) and `SET_DISK_LUN` (`0Bh` + `34h`), but the whole
internal map is reachable this way — the vendor's own `CH375DOS.SYS` and
`CH375CHK.C` use `0Ah` + `20h` for device-attached and `0Ah` + `3Eh` for the
drive letter, and `0Bh` + `25h` is `SET_RETRY`. `chdiag /R` dumps the map.
Registers that turned out to matter:

```
07h  bit0 attached  bit1 D- level  bit2 suspend  bit3 bus reset
     bit4 LOW SPEED DEVICE  bit5 SIE free
17h  90h at 12 Mbps, D8h after SET_USB_SPEED 02h
1Ch  40h exactly when the SOF generator is running
20h  bit5 device attached
```

Note that bit 1 of `07h` (the D− line level) reads 0 for this low-speed mouse,
so **do not use it to infer speed** — bit 4 is the one that means anything, and
it agrees with `GET_DEV_RATE` on the CH376.

**Host-mode status codes.** Success is `14h`. A failed transaction returns
`0010xxxx` where the low nibble is the PID the device answered with, or a low
nibble ending `00` for no answer at all:

```
14  success            15  connected        16  disconnected
22  device sent ACK    2A  device sent NAK  2E  device sent STALL
20 24 28 2C            device did not answer -- USB_INT_RET_TOUT
```

**Data toggle.** `CMD_SET_ENDP6` (`1Ch`) sets the host receive endpoint; bit 7
enables it and bit 6 is the DATA0/DATA1 toggle, so you alternate `80h` and
`C0h` across successful transfers. The vendor DOS driver reaches the same
register as internal byte `1Eh`; they are the same thing. Getting this wrong
shows up as every second packet failing, not as silence.

**A stalled control endpoint has to be cleared.** This mouse `STALL`s
`SET_IDLE` — it does not implement it. That is legal and harmless, but a stall
left set fails every later control transfer, so `hid_request` clears endpoint 0
whenever a request comes back `2Eh`.

---

## Clicks

Movement and clicks fail independently, so they are diagnosed independently.
`USBMOUSE /S` now reports what the button path has seen:

```
Loaded: USBMOUSE 1.0.0.  live=1  endpoint=1  reports=1043  buttons seen=01  button reports=4
```

`buttons seen` is the OR of every button mask that has arrived in a report
**from the mouse** — injected test reports are deliberately not counted, so
this number answers exactly one question. If it stays `00` after you have
clicked, the press is not reaching the driver at all.

```
build.cmd click           load the driver, watch the whole button path for
                          30 seconds, unload.  Click while it runs.
```

Measured with a real hand on the mouse, all three buttons:

```
button bits ever seen in a raw report: 07
reports carrying a button down       : 159
press counts   left=46  right=33  middle=34
release counts left=46  right=33  middle=34
Presses arrive and INT 33h reports them.  The driver is fine.
```

`CLICKTST` beeps when its window opens, chirps once per press so you get
confirmation without watching the screen, and beeps twice when it is done —
the speaker runs off PIT channel 2, which is unrelated to the channel 0 the
driver divides, so it cannot disturb the poll rate or the clock. It watches
the raw HID report, the INT 33h button mask and the press counters together,
and says which of the three stages is at fault:

* raw byte 0 never non-zero → the mouse is not sending the press, or not in
  the format expected
* raw moves but the INT 33h mask does not → a driver bug
* both move but an application still ignores clicks → that application reads
  the mouse some other way

Two bugs on this path were found and fixed after the first working build, both
of which broke clicks while leaving movement perfect:

* **The event handler never reported button events.** Function `0Ch` lets an
  application register a callback and a mask of events it cares about. The
  handler was being called with `AX=1` — "the pointer moved" — for every
  report regardless of the mask, so an application subscribed to button
  presses alone was called constantly and never once told that a button had
  been pressed. It now builds the real condition mask (bit 0 moved, bits 1-2
  left press/release, 3-4 right, 5-6 middle), tests it against the
  application's mask, and only calls when something it asked for happened.
  `EVTEST` covers this: 19 checks that every condition is reported with the
  right bit, that a mask of `02h` gets left presses and nothing else, and that
  a mask of zero stops the callbacks.
* **The status stage of a control write used the wrong data toggle.** A
  control write finishes with a zero-length IN carrying DATA1; the driver left
  the host endpoint set to DATA0, so `SET_PROTOCOL` came back `2Bh` (toggle
  mismatch) instead of `14h`. The mouse still reported in a boot-compatible
  layout, which is why this went unnoticed, but the request was not reliably
  taking effect.

If an application still ignores clicks once `CLICKTST` shows presses arriving
and INT 33h reporting them, it is reading the mouse in some way the driver
does not implement — the most likely candidate being the alternate event
handlers of functions `18h`/`19h`, which return "not supported".

---

## Windows 3.x

Windows has never heard of INT 33h. Its mouse support is a Windows DLL named
in `SYSTEM.INI` as `[boot] mouse.drv=`, and the one shipped with Windows 3.0 —
`MOUSE.DRV`, 4,896 bytes, dated 31 October 1990 — turns out to be a pure
**PS/2 BIOS** driver. Disassembled, it never touches the 8042 at all; it drives
everything through `INT 15h AH=C2h` plus one hardware vector. Its contract is:

```
INT 15h AH=C0h   must return a configuration table whose model byte at
                 offset 2 is F8h, FAh or FCh, or it concludes there is no
                 pointing device.  FCh also makes it choose INT 74h.
INT 11h          bit 2 must be set: "pointing device installed"
INT 15h AX=C205h BH=3     initialise, 3-byte packets
        AX=C201h          reset
        AX=C203h BH=3     resolution
        AX=C207h ES:BX    register a callback
        AX=C206h BH=1     scaling 1:1
        AX=C202h BH=2     sample rate
        AX=C200h BH=1     enable
                 ...retrying twenty times on error code 4, giving up on
                 anything else.
```

The last piece is the interesting one. `MOUSE.DRV` hooks `INT 74h` itself, and
its handler *begins by chaining to whatever was already in that vector* —
expecting the BIOS, which reads the mouse and calls the callback registered
with `C207h`. So `USBMOUSE /W` takes `INT 74h` first, and when the Windows
driver chains into it we deliver the packet in the frame the BIOS uses:

```
push status ; push X ; push Y ; push Z ; call far handler ; add sp,8
```

which the callback reads as `[bp+0Ch]`, `[bp+0Ah]`, `[bp+08]` — confirmed by
disassembling the callback rather than trusting a reference. Y is inverted on
the way out, because USB counts downwards and PS/2 counts up.

The upshot is that **none of this needs any Windows code**: with the emulation
in place the stock Microsoft driver runs unmodified.

```
USBMOUSE /W                       load before starting Windows
```

and in `SYSTEM.INI`:

```
[boot]
mouse.drv=mouse.drv               (was msmouse1.drv on this machine)
```

`/W` is opt-in because claiming to be a PS/2 model FC on an 8086 is a lie
other software can see: it makes `INT 15h AH=C0h` answer where the machine's
own BIOS says model FAh, and sets a bit in the `INT 11h` equipment word. All
three vectors are restored by `/U`.

`PS2TEST` makes exactly the calls `MOUSE.DRV` makes, in the same order, so the
emulation is provable without starting Windows — which matters here, because
Windows cannot be exited remotely: it reads the keyboard at INT 9, where
neither `KINJ` nor `KNET` can reach it, so the only way out is the smart plug.

```
=== USBMOUSE PS/2 BIOS emulation test ===
  ok    INT 15h AH=C0h returns a configuration table
  model byte = FC
  ok    model is a PS/2 class the driver accepts (F8/FA/FC)
  ok    bit 2 set: pointing device installed
  ok    C205h initialise ... C201h reset ... C207h set callback ... C200h enable
  ok      Y is inverted: USB counts down, PS/2 counts up = -3
  ok      left / right / middle button bits
  packets delivered: 436
25/25 checks passed.
```

**One trap worth recording.** `/W` hung the machine the first time. `ps2_ok`,
the helper that clears CF in the flags an IRET will restore, is reached by a
*near call* from inside an interrupt handler — so between the saved BP and the
IRET frame there is also the call's own return address. `[bp+6]` was clearing
bit 0 of the return **CS** rather than the flags, and the machine left the
building the moment the handler returned. The offset is `[bp+8]`.

---

## Test results

`build.cmd test` loads the driver, runs `MOUSETST` and unloads:

```
USBMOUSE 1.0.0 -- StevenC
Low-speed device; USB bus set to 1.5 Mbps.
USB mouse on CH375: endpoint 1, HID interface 0, VID/PID 093A/2510
USBMOUSE 1.0.0 resident.  INT 33h installed.
=== USBMOUSE INT 33h test ===
  ok  function 00h reports a driver installed
  ok  button count = 3
  ...
watching for real USB reports for about 10 seconds
  reports delivered by the mouse: 838
  live position 325,0 buttons 0

34/34 checks passed.
USBMOUSE 1.0.0 -- StevenC
USBMOUSE unloaded.
```

`EVTEST` then runs 19 more against the function 0Ch callback, and `PS2TEST`
25 against the PS/2 BIOS emulation -- 78 in all, and the whole set has been
run green against a live mouse with the driver loaded `/W`:

```
34/34 checks passed.                    MOUSETST
19/19 checks passed.                    EVTEST
25/25 checks passed.                    PS2TEST
INT 08h : 18 Hz     INT 1Ch : 18 Hz     TICKCHK
DOS says 15.0 seconds elapsed           CLKCHK
live=1  endpoint=1  reports=364  timer divisor=8  buttons seen=07
```

The last line is the driver's own view afterwards: still enumerated, back at
the fast poll rate now that TICKCHK has let go of the timer, and having seen
all three buttons.

`PS2TEST`'s last check needs the mouse to actually be moving; with an idle
mouse it is not asserted and the run reports `24/24` rather than failing.

The 34 checks cover position setting and read-back, movement in both directions
including negative deltas, clamping at both ends of the default and of a
narrowed range, sub-unit accumulation at half sensitivity, motion counters and
their clear-on-read, all three buttons' state, press and release counts and the
positions they were recorded at, cursor show/move/hide, and reset. They are
driven through the `7F01h` injection hook, with polling suspended via `7F02h`,
so every case is exact and repeatable; polling is resumed for the last section
and the real mouse then proves the USB path on top of that. The 34th reads the
version string out of the resident image and checks it is one.

Also verified on the machine:

* **The real mouse drives it.** 1043 reports over a 25-second run, position
  tracking the jiggler and clamping correctly at the screen edge, with the text
  cursor visible on the captured video.
* `USBMOUSE.COM` from `nasm -f bin` and from `MNASMFIX -O9 -f bin` on the DOS
  box are **byte-identical**.
* With the driver resident and polling at 145 Hz, `CLKCHK` measures 20.0 s of
  DOS clock in the same wall-clock time as without it.
* With `/E=1` — polling an endpoint on a device that never answers — the box
  runs for ten seconds at 145 failed transactions per second and stays healthy;
  `/U` then unloads cleanly.

---

## Assembling on the DOS machine

The driver needs no cross-compiler at all: it assembles on the target, byte
for byte identically to the `nasm` build. `tools\MNASMFIX.COM` in this
repository is the assembler to use -- a patched mininasm, because the stock
one creates its output file read-only, so pass 2 fails and quietly leaves a
stale image behind.

```
build.cmd dosbuild
```

does the whole thing: sends `src\usbmouse.asm` and `tools\MNASMFIX.COM` to
the DOS machine, assembles there, fetches the result back and compares it
with `bin\USBMOUSE.COM` byte for byte. By hand, with
[DOSBridge](https://github.com/jdredd87/DOSBridge)'s commands, it is:

```
dosdeploy src\usbmouse.asm    C:\WORK
dosdeploy tools\MNASMFIX.COM  C:\WORK
dosexec "C:\WORK\MNASMFIX.COM -O9 -f bin -o C:\WORK\USBMOUSE.COM C:\WORK\USBMOUSE.ASM"
```

or copy those two files to the machine by any other means and run the one
command there. Nothing else is needed.

`-O9` matters: without it mininasm leaves some jumps in their long form and the
image comes out larger than nasm's. With it the two agree exactly.

Every jump in `usbmouse.asm` carries an explicit `short` or `near` at its
natural size. If a displacement will not reach, **add a trampoline** — there
are four in the option parser already — rather than widening the jump:
mininasm re-shortens jumps on every pass, so a source that forces them long
never converges.

---

## Two later findings that touch this driver

Both came out of `CH375USBTOOLS` and `CH375Keyboard` after this driver was
finished. Neither is a bug here, and both are worth knowing.

**`CLR_STALL` also resets the endpoint's data toggle.** A control transfer
that succeeds leaves endpoint 0 advanced and the next one is stalled by the
device, so manual control transfers work only every other time. This driver
issues only *no-data* control requests — `SET_PROTOCOL` and `SET_IDLE`, both
optional, both in `hid_request` — and it clears a stall on the way out, so
the effect is invisible: if `SET_IDLE` is silently failing on the second
call, nothing depends on it. `ch375.pas` clears endpoint 0 before every
transfer, and a future version of this driver should do the same.

**`CLD` before any string operation reachable from an interrupt handler.**
The direction flag belongs to the interrupted program, and a `REP MOVSB`
running backwards writes over whatever lies below the buffer. **This driver
was checked and is not affected:** every string operation in `usbmouse.asm`
— the `repe cmpsb` in `find_resident` and the `lodsb` runs in `parse_args` —
sits after `resident_end`, in transient code that runs under DOS with the
flag clear. The keyboard driver had five of them in its interrupt path and
did need the fix.

## Licence

**Public domain**, under [the Unlicense](https://unlicense.org) — see
`LICENSE`. Copy it, sell it, strip my name off it, do whatever you like. No
attribution required, none expected.

The one exception is `tools/MNASMFIX.COM`, which is somebody else's work and
stays under their terms. Delete it if you would rather not carry it: nothing
depends on it, and `nasm` builds the identical image.

---

## Credits

Written by **StevenC**. <https://github.com/jdredd87/CH375USBTools>

Built and tested over [DOSBridge](https://github.com/jdredd87/DOSBridge),
which is what put every one of these binaries on the real machine and
brought the output back.

`tools/MNASMFIX.COM` is not mine: it is
[mininasm](https://github.com/pts/mininasm) with the read-only-output bug
patched out, bundled so the driver can be rebuilt on the DOS machine with
nothing else present.
