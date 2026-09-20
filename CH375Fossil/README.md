# CH375Fossil

A FOSSIL driver for DOS with **pluggable transports** -- so that software
written for a modem in 1991 can talk to a USB serial adapter on a CH375, or
to a TCP socket over any packet driver, without knowing either exists.

It belongs in this collection because the CH375 transport is what it is
*for*: it is the piece that turns `CH375Serial`'s adapter work into
something an unmodified DOS program can use, by pretending to be a modem on
`INT 14h`. The TCP transport is a side product -- it is not tied to the
CH375 at all, it rides on any packet driver -- but it is where most of the
testing happened, because a socket can be driven from a script and a modem
cannot.

```
CH375Fossil/
  src/     fossil.asm and its four includes; the six test programs
  bin/     FOSSIL.COM and the built .EXEs
  tools/   callbbs.py, the caller that drives a session from Windows
           GO.BAT, which loads the driver, runs a BBS, and unloads
  build.cmd   build, or: build.cmd test | modem | wdog | dosbuild
```

**The driver needs only nasm.** The test programs need Free Pascal, and
every target that runs something needs
[DOSBridge](https://github.com/jdredd87/DOSBridge) to reach the machine.

**Status: working end to end.** The whole `INT 14h` surface passes 57 of 57
checks over a loopback transport, and the CH375 transport drives a real
USRobotics Courier V.Everything through an FTDI adapter -- `AT` commands out,
a 1052-byte `ATI4` dump back, byte-clean and with nothing dropped, at 9600,
19200 and 38400 baud.

This collection keeps *written* and *verified* apart on purpose, so read the
Status table at the foot before trusting any particular part: the Keyspan
path is written and unexercised, and there is no `PKT` transport at all.

---

## What a FOSSIL is, and why it is the right shim

FOSSIL -- Fido Opus SEAdog Standard Interface Layer -- is a resident driver
that replaces `INT 14h` with a real, buffered, interrupt-driven serial API.
It exists because the BIOS `INT 14h` is unusable: it polls, it has no
buffering, it drops bytes above 2400 baud, and it cannot be made to work at
9600 on a loaded machine.

Every DOS BBS, mailer and door program of the era therefore talks FOSSIL,
detects it at startup, and refuses to run without one. That is the whole
opportunity: **the abstraction boundary was already drawn, thirty years ago,
by people who wanted to swap the hardware underneath.** We are supplying a
new underneath.

The API is small -- about 30 functions -- and the parts that matter are
tiny: read a byte, write a byte, is there a byte, how much room is left,
what is the carrier doing. Everything else is screen and keyboard helpers
that most callers ignore.

---

## Every switch the driver takes

They were nowhere in this file until 2026-09-20, and one of them is a trap.

| | |
|---|---|
| `@nnn` | CH375 I/O base in hex, default 260 |
| `/C` | the **CH375** transport: a real modem on a USB-to-serial adapter |
| `/D=n` | **the serial baud rate.** 9600 by default |
| `/P` | the **TCP** transport: a socket presented as a COM port |
| `/V=n` | packet driver vector, hex, for `/P`. The driver will not guess it |
| `/I=a.b.c.d` | our own IP, for `/P` |
| `/H=a.b.c.d` | a host to seed one ARP entry with, for `/P` |
| `/G=a.b.c.d` | gateway, for `/P` |
| `/T=n` | TCP port to listen on, for `/P` |
| `/L` | **loopback**, and the default -- what you get with no switches at all |
| `/B=n` | loopback bytes per tick. **Not baud.** See below |
| `/R=n` | timer divisor, 1 to 16: how often the driver polls |
| `/S` | print status and exit |
| `/U` | uninstall |

**`/B` is not the baud rate, and it looks exactly like it is.** It sets the
loopback transport's byte rate and is ignored by `/C` and `/P`. Asking for
`/C /B=38400` loads the CH375 transport at the default 9600 and reports
`baud 9600` in its banner, which is the only thing that gives it away. The
baud switch is `/D`. Caught on the V30, by reading the banner rather than
trusting the command line:

```
FOSSIL.COM /C /B=38400  ->  Transport: CH375 ... baud 9600   batch 32
FOSSIL.COM /C /D=38400  ->  Transport: CH375 ... baud 38400  batch 48
```

**Unloading is not tidiness.** The driver takes `INT 08h` and divides the
PIT, so a driver left loaded changes the timer rate for everything after it
-- including anything that measures. `/U` refuses if something hooked `INT
08h` or `INT 14h` afterwards, rather than restoring a vector that is no
longer its own.

## Verified on both machines

Re-run end to end on the **NEC V30** on 2026-09-20, after the `VidFix`
change and the move to a single merged PicoMEM project, with a USRobotics
Courier on a Keyspan `06CD:0121`:

| | |
|---|---|
| `FOSDET`, no driver loaded | declines to call `AH=04h`, as designed |
| `FOSDET`, driver loaded | names itself, buffers and free counts consistent |
| `FOSTEST` over loopback | **57 passed, 0 failed** -- every `INT 14h` function |
| `FOSAT` over CH375 at 9600 | `ATI4`, 1052 bytes, 617 B/s |
| `FOSAT` over CH375 at 38400 | `ATI4`, 1052 bytes, **1196 B/s** |

That last figure is the number this README already documented for 38400,
reproduced to the byte on a different day after a year's worth of changes to
everything around it. Nothing about the transport moved.

## The two transports

| | what it is | what it needs that we do not have |
|---|---|---|
| **`CH375`** | a real modem on a USB-to-serial adapter, through the CH375 host card | nothing -- the adapter layer is proven |
| **`PKT`** | a TCP/telnet socket presented as a COM port, over any packet driver | **a TCP stack** |

The first one is the reason to start. `CH375Serial` has already driven a
USRobotics Courier V.Everything through three different adapter families at
up to 115200 baud with byte-exact echo -- so the hard part, which is
enumerating and configuring a USB serial part from an 8086, is done and
measured. What FOSSIL adds to it is residency and buffering.

The second is the more useful one in the end -- it is how a DOS BBS reaches
the internet, and it is what NetFoss and DOSFoss do -- but it needs a
component this project has deliberately never built. See the TCP section.

---

## What already exists, and what it is worth

| | where | reusable as |
|---|---|---|
| the CH375 layer, in NASM | `CH375USBTOOLS/src/ch375*.inc` | **shared outright** -- see below |
| USB serial adapter bring-up | `CH375Serial/src/dser.pas` | **the algorithm, not the code** -- it is Pascal, we need a TSR |
| a resident CH375 poller | `CH375Mouse/src/usbmouse.asm` | **the skeleton.** It already does all of it |
| IPv4, no TCP | `dosbridgeDEV/starter/net.pas` | reference for the checksum and the packet driver calls |
| packet driver conventions | `dosbridgeDEV/docs/network.md` | read it before touching `PKT` |

**`usbmouse.asm` is the actual starting point, and that cannot be
overstated.** It is 4,365 lines of NASM that already: brings up the CH375,
enumerates a device, identifies a USB serial adapter by family, opens it at
a line setting, reads from a bulk endpoint on a timer tick at a
*reprogrammed* PIT rate, keeps a re-entrancy guard around CH375 register
access, survives hot-unplug, and goes resident. A FOSSIL driver over CH375
is that program with the mouse decoding replaced by two ring buffers.

The pieces of it that are load-bearing here, by name:

* `tick_n` / `tick_use` / `tick_c` -- the PIT divisor and the chain back to
  `old08`. This is what buys a poll rate above 18.2 Hz.
* `in_poll` -- the re-entrancy guard. `INT 14h` will now touch the CH375
  from the foreground *while* `INT 08h` wants to touch it from a tick. This
  guard is the only thing standing between those two.
* `ser_bud` -- the per-tick read budget, so one noisy tick cannot eat the
  whole timeslice.
* `set_retry_n` / `ser_enum_ready` / `ser_poll_ready` -- the `SET_RETRY`
  split. **`$8F` retries a NAK forever, which is right for enumeration and
  ruinous for polling.** That distinction has now been rediscovered five
  times across these projects. Do not rediscover it a sixth.

---

## The constraint that decides the design -- and what it actually measured

Not baud rate. **USB packet rate.** This CH375 sustains roughly **110-138
bulk packets per second**, measured independently across CH375Audio,
CH375Video and CH375Serial, and a bulk packet carries at most 64 bytes.

**The first version of this file predicted throughput from that ceiling and
was too pessimistic by a factor of about six.** The prediction is kept here
because the way it was wrong is the useful part.

It reasoned from `CH375Serial`'s 58-character echo test, where an FTDI took
7 packets -- about 8 bytes each -- and concluded the FTDI would sustain
around 1,100 B/s. Measured through `FOSAT`, pulling a 1052-byte `ATI4` dump
off a Courier:

| baud | batch asked for | bytes/s | IN packets | bytes/packet | packets/s |
|---|---|---|---|---|---|
| 9600 | 32 | 617 | 75 | 14.0 | ~44 |
| 19200 | 48 | 911 | 40 | 26.3 | ~35 |
| 38400 | 48 | **1196** | 23 | **45.7** | **~26** |

Byte-exact at every rate, nothing lost, no CH375 errors.

Three things in that table matter:

* **45.7 bytes per packet, not 8.** The echo test was latency-dominated --
  58 characters is a short burst, and an adapter with nothing queued
  forwards immediately. It measured how fast a nearly-idle adapter reacts,
  which is not what a file transfer does. **A burst measurement is not a
  throughput measurement**, and using one as a floor for the other produced
  a number that was wrong in the direction that would have driven the wrong
  design decision.

* **The packet rate FALLS as the baud rate rises** -- 44, then 35, then 26.
  That is the batching working exactly as intended, and it is why the
  ceiling never binds: `ser_batch_for` asks the adapter to gather
  `baud/300` bytes into each packet, capped at 48, which holds the packet
  rate near 30/s across the whole range. At 38400 we are using a fifth of
  the packet budget this card has.

* **The transport is not the limit at any rate we can ask for.** 1196 B/s at
  38400 is 31% of the 3840 B/s line rate -- the rest is the *modem* pausing
  between lines. And FOSSIL's own baud encoding tops out at 38400, because
  the three bits function 00h gives it only name eight rates. So the honest
  summary is: **the FOSSIL baud ceiling is reached before the CH375 packet
  ceiling is, and there is roughly 5x headroom left over.**

What the old table did get right, and what still stands, is the adapter
ranking and the reason for it:

* **FTDI and Keyspan both have a receive-batching control** -- a latency
  timer and `RXFWDLEN` respectively -- which is the entire mechanism above.
* **The PL2303 has none,** because CDC line coding has no equivalent, so it
  forwards one or two bytes at a time regardless. 627 packets for one
  `ATI4` dump against this transport's 23 is not a small difference; it is
  the difference between using a fifth of the packet budget and needing
  five times more than exists. It is therefore **not opened by this driver
  at all**, which is the same answer `dser.pas` gives for a family it will
  not drive properly: returning failure beats opening a port that then
  delivers nothing, because "no bytes" is the one symptom that cannot be
  told apart from dead hardware.

---

## Architecture

One resident `.COM`, one `INT 14h` dispatcher, two ring buffers, and a
transport behind a small vector of entry points.

```
    application  (BBS, terminal, mailer, ZMODEM)
         |  INT 14h
    +----v-------------------------------------------+
    |  FOSSIL core                                   |
    |    dispatch, status bits, flow control         |
    |    rx ring  <----------------+                 |
    |    tx ring  ---------+       |                 |
    +----------------------|-------|-----------------+
                           |       |
    +----------------------v-------^-----------------+
    |  transport vtable: init/poll/send/close/status |
    +----------------------+-------------------------+
         |                          |
    CH375 backend              PKT backend
    (bulk IN/OUT)              (TCP + telnet)
```

The transport is a table of far pointers filled in at load time from a
command-line switch, not a compile-time choice -- one binary, `/CH375` or
`/PKT`. Both backends are driven from the same `INT 08h` tick, and neither
is allowed to call DOS.

### Why the buffers have to be rings, and generous ones

A real FOSSIL is fed by a UART interrupt that fires per character. Ours is
fed by a timer tick, so the receive ring has to absorb everything that
arrives between two polls, and the transmit ring has to hold whatever the
application dumps in a burst.

At 145.6 Hz that gap is 6.9 ms, which is nothing -- but the poll can be
*skipped*, because the re-entrancy guard will refuse a tick that lands while
`INT 14h` is mid-transaction with the CH375, and because a long DOS
operation can mask interrupts for far longer than one tick. 4 KB each
direction, and the `ifree`/`ofree` fields of the `AH=1Bh` structure report
the truth so that a well-written caller throttles itself.

### Two things that will bite

* **`AH=02h` blocks, and must block with interrupts enabled.** Receive-with-
  wait spins until the ring has a byte, and the only thing that can put a
  byte there is the timer tick. A `CLI` anywhere in that loop is a hung
  machine -- and from the bridge, a hung machine is indistinguishable from a
  slow one.
* **`INT 14h` and `INT 08h` now both talk to the CH375.** The mouse driver
  only ever touched the chip from the tick. Sending is new, it is
  foreground, and it is exactly the interleaving `in_poll` exists to
  prevent -- but `in_poll` currently guards the tick against itself, not the
  tick against the foreground. It has to become real mutual exclusion, and
  the foreground side must be the one that backs off.

---

## The `INT 14h` function set

From FSC-0015. Detection is `AH=04h` returning `AX=1954h`, plus the
signature word `1954h` at offset 6 of the interrupt handler with the maximum
supported function number in the byte after it.

| AH | function | plan |
|---|---|---|
| 00h | set baud rate | **yes** |
| 01h | transmit with wait | **yes** |
| 02h | receive with wait | **yes** |
| 03h | request status | **yes** -- the one every caller polls |
| 04h | initialize driver | **yes** -- and where `PKT` opens its handle |
| 05h | deinitialize driver | **yes** -- and where `PKT` releases it |
| 06h | raise/lower DTR | **yes** -- a real hang-up on CH375 |
| 07h | timer tick parameters | yes, trivial |
| 08h | flush output (wait until sent) | **yes** |
| 09h / 0Ah | purge output / input | yes, trivial |
| 0Bh | transmit no wait | **yes** |
| 0Ch | non-destructive read-ahead | **yes** |
| 0Dh / 0Eh | keyboard read, without / with wait | yes -- straight to `INT 16h` |
| 0Fh | set flow control | **yes** -- see below |
| 10h | ctrl-C/K checking, transmit on/off | yes |
| 11h-13h, 15h | cursor and screen writes | minimal -- BIOS teletype, no ANSI engine |
| 14h | watchdog | **yes, and it matters here** -- see the `PKT` hazard |
| 16h | timer tick chain add/delete | yes -- we own `INT 08h` already |
| 17h | reboot | yes |
| 18h / 19h | read block / write block | **yes -- the hot path.** ZMODEM uses these |
| 1Ah | break on/off | CH375 only; `PKT` returns success and does nothing |
| 1Bh | driver information | **yes** -- `ifree`/`ofree` are how a caller throttles |
| 7Eh / 7Fh | install/remove external application | stub, returning failure |

The ANSI functions get a deliberately minimal answer. `13h` is specified as
"write with ANSI processing", and writing an ANSI interpreter is a project
of its own; callers that need one overwhelmingly ship their own and use
`15h`. Doing `13h` as BIOS teletype is a documented lie, and a smaller one
than pretending the driver is absent.

**Flow control is where a FOSSIL earns its keep, and where ours is
weakest.** `0Fh` asks for RTS/CTS or XON/XOFF. On CH375, RTS/CTS is the
adapter's job and we can set it at open; XON/XOFF we would have to do in
software, in the ring. On `PKT`, TCP does its own flow control and both
answers are meaningless. Plan: honour what the adapter can do, implement
XON/XOFF in the core where it is nearly free, and report accurately through
`1Bh` rather than claim a mode we do not run.

---

## The `PKT` backend

**A packet driver is an abstraction boundary somebody else already drew, and
it is exactly the one we want.** It is a published interrupt API on a vector
in 60h..80h, and every conforming driver looks identical from above --
`NE2000.COM`, PicoMEM's `pm2000`, and CH375Net's own `USBPKT`, which
installs a Crynwr driver over a USB Ethernet adapter. So this transport
binds to a **vector**, not to a card, and a BBS running on it cannot tell
what its frames leave through.

Stack that on FOSSIL and there are two independent boundaries: FOSSIL hides
the transport from the BBS, the packet driver hides the NIC from FOSSIL.

### It listens; it does not dial

A BBS waits for a call. That maps onto modem semantics so cleanly that
unmodified software needs no telnet awareness at all:

| TCP | what the BBS sees |
|---|---|
| listening | no carrier |
| connection accepted | **DCD goes high** -- a call |
| connection closed | DCD drops -- hang up |

### The handle is the dangerous part, and the rule was already paid for

`docs/network.md`, on `PKTCAP`:

> A frame delivered to your handle is not delivered to mTCP's [...] an
> unqualified capture can quietly starve the link you are working over
> [...] the bridge runs over that network, so recovery needs hands on the
> keyboard.

Three consequences, none optional, all implemented:

* **The vector must be named.** There is no "find the first packet driver"
  path, because on this machine the first one is the bridge's own lifeline.
  `/P` without `/V=` refuses and says why.
* **The handle belongs to the session, not to the driver.** Nothing is taken
  at load time; `AH=04h` binds and `AH=05h` releases. A loaded-but-idle
  FOSSIL is harmless, which is what makes it safe to leave resident on a
  machine reached over the same card. `/U` calls `AH=05h` through the API
  *before* freeing the resident block, so the driver can never be left
  holding a far pointer into memory DOS has reused.
* **A watchdog releases it anyway** after about a minute with no FOSSIL
  calls. The first two both assume the application still gets to execute;
  this one does not, and it is what turns "the test program crashed" from a
  trip to the keyboard into a pause.

**Two handles are held at once** -- 0800 for IP and 0806 for ARP. The spec
lets a driver refuse a second `access_type` for a type *already in use*,
which is the same type, not any type. Answering ARP is not optional: a box
that only asks looks fine until its neighbour's cache expires and then
silently stops being reachable, which is the exact shape of the transport
stall that took weeks to find.

### What works today -- a whole BBS session over TCP

`FOSBBS` is a BBS that believes it is talking to a modem on COM1. It waits
for DCD, reads and writes through `INT 14h`, and hangs up by dropping DTR.
It contains no networking code and does not mention TCP or telnet anywhere.
Dialled from Windows with an ordinary telnet-speaking client:

```
carrier in 1.05s
--- greeting + dump ---  (2188 bytes)          <- exactly the expected total
--- integrity check ---
   expected 40 pattern lines, got 40
   ALL 40 LINES BYTE-EXACT
   You said: Hello from Windows
--- G -- goodbye, read to close ---  (33 bytes)
   Goodbye. Dropping carrier.
   the closing line arrived COMPLETE
far end closed: True
```

### Full BBS coverage, and the four bugs it found

`FOSBBS` is now the test bed for everything a real BBS could ask of a
FOSSIL: calls in a row, 8-bit clean transfers both ways through block I/O,
the buffer accounting a caller throttles on, the housekeeping calls a BBS
makes once and then trusts (00h, 0Fh, 10h, 14h, 16h, 1Ah), and carrier loss.
Driven from Windows by an ordinary telnet-speaking client:

```
--- [H] housekeeping ---          HOUSEKEEPING OK
--- [B] binary download ---       ALL 4096 BYTES BYTE-EXACT, including 0xFF and 0x00
--- [U] binary upload ---         UPLOAD OK 02048
   arrivals: 9 chunks, mean 456 bytes, largest 510
   gaps between arrivals: median 68 ms, worst 79 ms
   throughput 6075 bytes/s
call 1 and call 2 both served, closing line COMPLETE, far end closed
ALL CHECKS PASSED
```

and from the driver's own side, over two calls:

```
rx 2060  tx 10142  lost 0
ARP in 184 out 3  dropped 0  errors 0  abandoned 0
TCP state 1  calls 2  seg in 71  out 76  rexmit 0  bad 0
```

#### The telnet negotiation loop -- the one that mattered

**We sent `IAC WILL ECHO`, the caller answered `IAC DO ECHO`, and we read
that answer as a fresh request and said `WILL ECHO` again. For ever.**

RFC 854's loop-prevention rule is that a party must never acknowledge an
acknowledgement -- reply only when your stated position actually changes.
Neither end was doing it, so both were guilty, and adding BINARY to the
agreeable list tripled the rate. The driver now keeps what it has already
said about each option and stays silent otherwise.

What it cost before it was found is the useful part:

| | storming | fixed |
|---|---|---|
| segments out, for ~2.5 KB of real output | **30,461** | 76 (for 10 KB) |
| bytes that reached the application | **8** | 2,060 |
| retransmissions | 41 | **0** |
| frames dropped | 37 | **0** |
| download throughput | 661 B/s | **6,075 B/s** |
| worst gap between arrivals | 1,067 ms | **79 ms** |

**Every other symptom in this project's PKT transport was this bug wearing a
different hat.** The dropped frames, the six per cent retransmit rate, the
second call that never got its handshake ACK, and throughput an order of
magnitude below the link -- one fault, four faces, and three separate wrong
diagnoses chased before the segment counter was finally read next to the
byte counter. `seg out 30461` for `tx 2501` is not a performance problem; it
is a loop, and the ratio says so at a glance.

#### The receive ring was not FIFO

The allocator searched for a free slot *starting at* the last one it used,
so once the drain freed that slot it was handed straight back out -- while
the drain, which reads strictly in order, had moved on to the next slot,
found it empty, stopped, and never came back. The ring quietly ceased
draining. The write index now always moves forward.

#### Draining it exposed a re-entrancy hazard, and wedged the machine twice

With the ring finally draining, a tick could handle eight frames, each of
which may send a segment -- and sending calls the packet driver from inside
a timer interrupt. A packet driver commonly enables interrupts during its
own IRQ so as not to block the clock, which means our tick can land inside
it and call `send_pkt` re-entrantly. Most are not re-entrant, and the box
hung hard enough to need the plug pulled. Twice.

The budget is now two frames per tick: enough that the receive rate is not
capped at one frame per tick, few enough that one tick cannot sit in the
driver. **The proper fix is to drive the transport from `INT 14h` rather
than from the timer**, since a BBS calls `03h` constantly anyway; that is
not done and is the largest known piece of work left here.

#### The transport no longer runs from the timer

This was the largest known piece of work left, and it is done.

Sending means calling the packet driver, and a packet driver commonly
enables interrupts during its own IRQ so as not to block the clock -- so a
timer-driven transport can land inside the driver and call `send_pkt`
re-entrantly. That is what wedged this machine twice. Everything except the
watchdog now runs from `pt_service`, called from **`INT 14h`**, which on a
BBS is a livelier clock than the timer anyway: a BBS polls function 03h
continuously, and every blocking wait (01h, 02h, 08h, and the close in 05h)
pumps the transport while it spins.

Two consequences worth writing down:

* **Every transport timer is measured against a tick counter, not against
  the number of calls.** `INT 14h` is called at whatever rate the
  application feels like, so a per-call countdown would expire almost
  instantly on a busy BBS and never on an idle one. The timer interrupt now
  does nothing but count.
* **The watchdog deliberately stays on the timer**, and is the one driver
  call still made from interrupt context. It exists for the case where the
  application has *died* -- which is exactly when `INT 14h` stops being
  called, so a watchdog driven from there could never fire. It runs once,
  long after any foreground code has stopped touching the driver.

Measured after the move: **6,236-6,844 bytes/s**, and across three calls
`seg in 88, out 93` for 13 KB with `dropped 0, rexmit 1, bad 0, errors 0`.

#### A caller who vanishes mid-transfer

The normal way a call ends is not a polite goodbye; it is somebody closing
their terminal. `FOSBBS` is now dialled three times: a full session, then a
caller who starts a download and disappears without warning (RST, not FIN),
then a third call that must be served normally. The BBS notices the carrier
go mid-sentence, gives the line back, and answers call three -- byte-exact
as usual. `calls the caller dropped: 1` is asserted, not merely observed,
because a test that would pass whether or not the caller was noticed is
not a test of noticing.

#### The CH375 layer is now shared, not copied

It was duplicated on purpose to begin with: `usbmouse.asm` was working,
shipped code, and a driver that had not yet run had no business putting it
at risk. That reasoning expired once this one was carrying a BBS, so three
includes moved to `CH375USBTOOLS/src` and both drivers use the same copy:

| | |
|---|---|
| `ch375def.inc` | command codes, statuses, token PIDs |
| `ch375io.inc` | the register primitives and the bounded wait |
| `ch375ser.inc` | the `SET_RETRY` split, the endpoint-0 vendor request, the bulk OUT |

**It also still assembles on the DOS box itself, to the same bytes.**
`mininasm` has no include path, so all eight files have to sit in the
current directory and it must be run from there -- but given that, it
produces a **byte-identical** 29,982-byte image to NASM's. That was worth
checking rather than assuming: the header had claimed a DOS build for a
while without one ever being tried, and the command it named
(`E:\MNASMFIX.COM`) turned out not to exist on this machine at all.

**The check that matters for the mouse is byte-identity.** Each include sits at the exact
position its code held inside `usbmouse.asm`, so the mouse driver still
assembles to **10,232 bytes, CRC-32 `195E9DCE`** -- the same image as
before. For a pure code motion that is stronger than a hardware test:
identical bytes are the same program. It was also the only check available,
because the CH375 had the modem on it and the mouse could not be plugged in.

The FOSSIL side is *not* byte-identical -- its `CLD` moved out of
`bulk_out_ser` into the caller -- so it was re-proved the other way: 57/57
on loopback, the full BBS battery over TCP, and the Courier answering
`ATI4` at 911 B/s in 40 packets, which is the same figure as before the
move.

`CH375_COUNTERS` is the one `%ifdef`: it makes the shared code record
failures in `last_st`/`ch_err`, which the mouse has no use for.

#### Two things finalised at the same time

* **The byte counters are 32-bit.** A single 128 KB transfer wrapped a Word
  four times, and `tx 9127` for 137 KB is worse than no counter -- it reads
  as a plausible small number. It now reads `tx 140221`.
* **The receive drain is no longer capped.** `FRM_DRAIN` was 2 as a
  mitigation for the timer re-entrancy; with `pt_service` running from
  `INT 14h` there is nothing left for it to protect against, and a ring
  that can only be emptied a fraction at a time is just a slower ring. It
  is the full 8 now.

#### Real BBS software needs a 286, and this machine is not one

Two packages were put on the box and both refused:

| | |
|---|---|
| **QuickBBS 2.75** (1991) | would not run |
| **Renegade** | "needs a 286 or higher" |

The machine is an **NEC V30**. That is an 8086 with the **80186** instruction
set -- `PUSHA`/`POPA`, `ENTER`/`LEAVE`, `BOUND`, `INS`/`OUTS`, `IMUL` with an
immediate, shifts by an immediate -- and this project has verified that
directly: `Has186`'s immediate-shift really executes here, and `AAD`
identifies the part as a V30. So a "needs a 186" requirement would have been
fine. **286 is a different bar, and it is a real one.**

That is worth writing down plainly, because it says something about the
driver and something else about the hardware, and they are easy to confuse:

* **Nothing here indicts the FOSSIL driver.** Neither package got far enough
  to open a line. The refusal is at startup, on a CPU check.
* **The driver is still only exercised by software written to test it.**
  `FOSBBS` can only exercise the paths somebody thought of, and that limit
  stands until a BBS nobody here wrote runs against it. One informal human
  session over telnet is the closest it has come.

The options, none of them urgent: a 286-or-better machine, or a genuinely
8086-era board -- Opus, Fido, RBBS-PC, early Maximus -- from the years when
FOSSIL itself was written for 808x machines. Parked until there is hardware
to try it on.

#### The Keyspan, finally exercised

It was the one path in this driver that had never executed: transcribed
from `usbmouse.asm`, which drives a Keyspan at 1200 baud and nothing else,
with the divisor computed here where the mouse hardcodes it. Swapped in and
pointed at the Courier:

| baud | bytes/s | Keyspan IN packets | FTDI, same test |
|---|---|---|---|
| 9600 | 617 | **38** | 75 |
| 19200 | 911 | **27** | 40 |
| 38400 | 1196 | 27 | 23 |

Byte-exact `ATI4` at every rate, zero errors. **The throughput figures are
identical between the two families because the modem is what limits them,
not the transport** -- but the Keyspan does it in roughly half the USB
packets at the lower rates, which is the `RXFWDLEN` batching earning its
place and the reason this collection ranks it first. By 38400 they
converge.

Two things confirmed rather than assumed while it was in:

* **`923077/baud` is right.** That divisor had only ever been exercised at
  1200, where it happens to come out exact. 9600, 19200 and 38400 all carry
  a remainder and all three answer.
* **It really does use two bulk OUT endpoints** -- data on 1, the 34-byte
  control block on 2. The install line reports both now (`OUT ep 1
  ctl ep 2`), because it previously showed only the data one and that made
  a working adapter look like it had fallen back to a single endpoint.

#### The throughput figures here are understated, and the reason is familiar

Everything measured below was measured through `callbbs.py`, which parses
every received byte through a telnet state machine in interpreted Python.
The first time a **real telnet client** pulled the 128 KB block instead, the
driver's own log said:

```
large transfer: 131072 bytes in 10s
about 13107 bytes/second
```

against the 6,700-7,100 bytes/s the test harness had been reporting for the
same transfer. **The bottleneck was the instrument, not the driver**, and
every rate in the sections below is therefore a floor rather than a result.

This project already has that written down twice -- *a null result is worth
exactly what the instrument is worth*, from the transport stall in
`docs/network.md*, and *a burst measurement is not a throughput
measurement*, from the CH375 packet-rate estimate earlier in this file. It
was still worth walking into a third time to find out, because a test client
that is slower than the thing it measures reports the thing it measures as
slow, and nothing about the output says so.

#### Endurance: 128 KB, byte for byte

4 KB proves the path is correct and says nothing about a real file, where
the rings wrap dozens of times, the sequence numbers climb past anything a
16-bit counter could hold, and a slow leak has time to show.

```
--- [L] 128 KB endurance transfer ---
   arrivals: 258 chunks, mean 509 bytes, largest 511
   gaps: median 72 ms, worst 142 ms
   131072 bytes in 18.4s -- 7105 bytes/s
   ALL 131072 BYTES BYTE-EXACT, including 0xFF and 0x00
```

and from the driver, over that call and the aborted one after it:
`seg in 318, out 323, rexmit 0, dropped 0, bad 0`.

One thing to know when reading `/S` after a run like this: **`rx` and `tx`
are 16-bit counters and they wrap.** 137 KB through a Word is not a fault,
it is four wraps; the segment counters are the ones to reason from.

#### The watchdog, proved by the only test that can prove it

The watchdog exists for one case: the application that opened the line has
died while holding the packet driver's handles -- which on this machine are
the bridge's own network. `FOSWDOG` opens the line and then goes completely
silent for 75 seconds, touching `INT 14h` not once, and installs **no**
ExitProc to tidy up after itself. Everywhere else in this project that would
be the dangling-callback bug; here it is the entire point.

So the test is its own proof. If the watchdog works the handles come back on
their own, the agent starts polling, and the job's result is delivered. If it
does not, nothing is ever heard from the machine again.

```
seconds spent silent: 75
handles held 0   watchdog fired 1
```

The result arrived, which is the pass. Note `dropped 68` alongside it: with
no `INT 14h` calls there is no `pt_service`, so frames piled up in the ring
and were refused. That is correct -- there was nobody left to deliver them
to.

#### Unloading with a call still up -- and the bug it caught

A BBS can crash mid-call, leaving the driver holding a live connection. The
`[X]` command in `FOSBBS` simulates exactly that: it restores the previous
`ExitProc` and halts, so nothing hangs up and nothing is released. `/S` then
reports `handles held 1` and `TCP state 3` -- an established connection with
no application behind it -- and `/U` has to clean it up.

The first run failed: **nothing closed the abandoned connection.** The cause
was worth the test on its own.

`fos_pump` clobbers ES and BX -- it reaches `tcp_send_seg`, which sets ES to
our own segment. Both bounded waits, function 05h's close and function 08h's
flush, were holding their deadline in BX and reading the BIOS tick through
`ES:046Ch` **across that call**. After the first pump, `[es:046Ch]` was
reading the driver's own code as if it were the clock. Function 05h decided
its grace period had already elapsed, handed the packet handles back before
the FIN was ever transmitted, and left the caller's connection hanging with
nothing to close it.

Both waits now read the clock through a helper that restores ES, and keep
their deadline in memory rather than in a register. The connection is closed
in 1.7 s.

**This one had been quietly wrong in `08h` the whole time** and no earlier
test could see it, because a flush whose deadline is garbage still returns --
it just stops waiting. It took a test that cared *when* something happened,
rather than only whether it did.

#### A buffer asked for and never filled

The driver's protocol is two calls -- "give me a buffer", then "I filled
it" -- and nothing promises the second arrives. An abandoned frame left a
slot marked *being filled* for ever. It is reclaimed now. Worth saying
plainly: the counter for this has read **zero** on every run since, so the
fix addresses a hazard that was real in the code and was never the fault
being chased. It is kept because it costs four instructions.

### Three bugs this cost, and each one is worth keeping

**The frame ring dropped everything.** `mul bl` is an EIGHT-bit multiply --
`AX = AL * BL` -- so with `FRM_MAX` (1518) in AX it silently multiplied by
the low byte and returned an address in the middle of nowhere. The poll loop
also let `frm_dispatch` clobber the slot index in BX, so slots were never
freed and the same buffer was re-parsed for ever. The counters said it
plainly once they were read: `ARP in 43176 out 1`. Forty-three thousand
parses of one stale buffer, and not one reply sent.

**Telnet replies jumped the sequence queue.** Answering a negotiation sent
three bytes inline at `snd_nxt` and never advanced `snd_nxt`. The peer took
them, then our next data segment went out at the *same* sequence number and
the peer trimmed the overlap -- silently eating exactly as many bytes of
real output as we had sent in replies. Three to six characters vanished from
the start of every session and everything after was perfect, which reads as
a startup race and is nothing of the kind. **Anything that occupies sequence
space has to go through the one path that advances it.**

**Hanging up jumped the queue too.** `tcp_shutdown` sent the FIN
immediately, overwriting the tracking of a data segment that had not been
acknowledged -- so a lost final segment could never be retransmitted and the
closing line went missing. The FIN now queues behind the data like anything
else and the tick sends it once the ring is empty.

### And one failure that was the instrument, not the driver

The closing line looked truncated for two rounds before the cause was even
looked at, because the test client stopped reading after 0.6 seconds of
quiet. A stop-and-wait sender talking to a delayed-ACK peer has gaps far
longer than that, so "it went quiet" was being read as "it finished".
Reading until the socket actually closes fixed the measurement, not the
driver. `docs/network.md` already has the rule: **a null result is worth
exactly what the instrument is worth.**

### The earlier milestone

Verified on hardware against the bridge's own packet driver at INT 60h --
the risky configuration, deliberately, because it is the one that can take
the machine off the network:

```
Installed.  Transport: packet driver at INT 0060h  ip 192.168.50.66  peer 192.168.50.46
  ARP in 1  out 1  dropped 0  errors 0  peer MAC EC:8E:B5:7A:2C:F5
```

That MAC is the Windows machine's Ethernet adapter. Both handles were taken,
an ARP request went out, the reply came back and was parsed, both handles
were released -- and the job's own result then reached Windows over the same
card, which is the proof that matters.

**TCP itself is not written yet.** The binding, the receiver callback, ARP
in both directions and the whole handle lifecycle are; IP, TCP and the
telnet `IAC` layer are not. That order was chosen on purpose: the part that
can wedge the machine is now proven, so the part that cannot is what is
left.

### For real use, give it its own card

A BBS *sitting* waiting for calls holds the handle indefinitely, and on
INT 60h that is the bridge's lifeline. Bounded sessions inside one job are
fine for testing; a BBS that actually stays up wants `USBPKT` loaded on a
second vector so the bridge keeps its own NIC. **The code does not change**
-- the vector is a parameter, which is the whole point of binding to the
packet driver interface rather than to a card.

---

## Build and test

NASM, assembled on the DOS box with `E:\MNASMFIX.COM -f bin`, the same way
`usbmouse.asm` is built -- a `.COM` TSR is a flat binary and needs no
linker. The Pascal scaffold `dosnew` created is for the *test* programs, not
for the driver.

**Never `CONFIG.SYS`.** A FOSSIL is conventionally loaded either way and
`X00` ships as a `.SYS`, but the hard constraint in `CLAUDE.md` is absolute
and the reason is good: a bad driver in `CONFIG.SYS` hangs the box before
`AUTOEXEC.BAT` runs, so nothing on the machine can undo it and a power cycle
re-runs the same bad config. `.COM`, loaded from the command line, like
`BNU`.

Two programs, both of which run:

| | proves |
|---|---|
| `FOSDET` | detection. Safe with **no driver loaded**, which is the point -- it is the negative control |
| `FOSTEST` | every function the driver exposes, through `INT 14h` and nothing else |

`FOSDET` makes zero `INT 14h` calls unless the in-memory signature is
already there, and that ordering is the substance of it rather than
caution. The BIOS `INT 14h` defines `AH=00h..03h` and nothing else, so a
blind `AH=04h` on a machine with no driver is a call into undefined ROM.
FSC-0015 puts the signature in memory precisely so the question can be
asked without making the call. Against this box with nothing loaded:

```
INT 14h vector: F000:E739h          <- straight into BIOS ROM
signature at handler+6: FA83h       <- a FOSSIL would say 1954h
no FOSSIL driver is installed
```

`FOSTEST` is a generic FOSSIL client, not a test of our driver in
particular: it asks the driver what it supports and tests what it claims,
so it should pass against `X00` or `BNU` as readily as against this one --
and if it ever does not, that difference is the interesting result.

**57 of 57 checks pass on hardware.** Covered: detection and both maximum-
function reports agreeing, the `1Bh` information block and its live
`ifree`/`ofree`, purge and the idle status bits, baud set and read back,
tick parameters, a byte round trip through `0Bh`/`0Ch`/`02h`, sixteen bytes
through `01h`/`02h` in order, a 55-byte block byte-exact through
`19h`/`18h`, `18h` on an empty port returning zero rather than blocking,
flush leaving the transmitter empty, DTR moving the carrier bit, flow
control and `^C` checking round-tripping, break, the idle keyboard, cursor
position round-tripping, the `16h` timer-tick chain being called and then
*stopping* once removed, the `7Eh` application being installed, dispatched
through `AH=80h`, returning its own value, and stopping once removed, and
the receive ring overrunning and reporting it.

Three functions are **not** tested, and are listed as untested by the suite
itself rather than quietly skipped -- each is indistinguishable from a
crash on a machine reached over a network:

| | why not |
|---|---|
| `0Eh` keyboard read *with wait* | blocks; nobody is at the keyboard |
| `17h` reboot | a job that reboots cannot report its own result |
| `14h` the watchdog actually firing | it reboots -- same problem |

### The bug the loopback found in itself

The first version of the loopback checked whether the receive ring had room
*before* taking a byte off the transmit ring. When the application stopped
reading, the transmit ring simply backed up and nothing was ever dropped --
so `FOSTEST` sent 6 KB into a 4 KB ring and never saw an overrun, and that
one check failed.

The check was right and the transport was wrong. **A serial port has no
back-pressure from a receive buffer to a remote sender.** Bytes arrive off
the wire whether or not anyone has room; the UART drops them and raises
OVRN. Modelling it the other way round made the drop path *unreachable from
a test* -- and that path is exactly the one that matters when the CH375
delivers faster than the application reads, which on this machine it will.

So the byte is now always taken from the transmit ring and `rx_put` decides
whether there is anywhere to put it. Overrun appears at round 4, as the
arithmetic says it should, and the driver's own counters agree with the
suite from the other side:

```
rx 4423  tx 4424  lost 1
```

4423 + 1 = 4424. Two independent accountings of the same bytes.

### Loading it

`.COM`, from the command line, like `BNU` -- **never `CONFIG.SYS`.** A
FOSSIL is conventionally loaded either way and `X00` ships as a `.SYS`, but
the hard constraint in `CLAUDE.md` is absolute and the reason is good: a bad
driver in `CONFIG.SYS` hangs the box before `AUTOEXEC.BAT` runs, so nothing
on the machine can undo it and a power cycle re-runs the same bad config.

`test.cmd` loads it, runs the suite and unloads it inside one job. The
unload is not tidiness: the driver takes over `INT 08h` and divides the PIT,
so a job that leaves it resident leaves the next one running underneath it.
`/U` refuses if anything hooked `INT 08h` or `INT 14h` afterwards, rather
than unhooking from under it.

---

## Status

| | |
|---|---|
| FOSSIL core, all 30 functions | **written, verified on hardware** |
| loopback transport | **written, verified on hardware** |
| `FOSDET` / `FOSTEST` | **written, 57 of 57 on hardware** |
| CH375 transport, FTDI | **written, verified against a real modem** |
| CH375 transport, Keyspan | **written, verified against the modem at 9600/19200/38400** |
| CH375 transport, PL2303 | deliberately **not** opened; see the rate section |
| `FOSAT` | **written, verified** -- 9600, 19200 and 38400, byte-clean |
| function 00h changing the rate live | written; only exercised via `/D=` at load |
| PKT transport: bind, release, watchdog | **written, verified on hardware** |
| PKT transport: ARP both directions | **written, verified on hardware** |
| PKT transport: IP + TCP listener | **written, verified on hardware** |
| PKT transport: telnet negotiation | **written, verified on hardware** |
| `FOSBBS`, a BBS that thinks it has a modem | **written, verified end to end** |
| calls in a row, 8-bit clean both ways | **verified -- see Full BBS coverage** |
| BBS housekeeping calls on a live line | **verified** |
| transport driven from `INT 14h`, not the timer | **written, verified on hardware** |
| CH375 layer shared with CH375Mouse | **verified -- mouse image byte-identical** |
| assembles on the DOS box to the same bytes | **verified** |
| driven by a person from a real telnet client | tried once; nothing felt wrong |
| caller vanishing mid-transfer, and recovery | **verified** |
| 128 KB sustained transfer, byte-exact | **verified** |
| the watchdog actually firing | **verified** |
| unloading with a call still established | **verified** |
| real BBS software | **blocked on the CPU, not on the driver** -- see below |

### What the TCP deliberately is not

One connection, stop-and-wait, no reassembly queue: an out-of-order segment
is dropped and re-ACKed rather than held, so the sender resends it. That is
correct TCP and merely slow under loss, which on a LAN carrying a terminal
session costs nothing measurable. The alternative is a send window and a
reassembly queue -- much more code, whose failure mode is silent corruption
rather than a visible stall. This project has a written rule about which of
those to prefer.

Not implemented, and none of it needed for a BBS: outbound connect, TIME-WAIT
(the port is reused immediately, because a one-line BBS cannot refuse the
next caller for two minutes), window scaling, or any TCP option at all.
| a BBS actually running on it | not attempted |

### Known gaps, stated plainly

* ~~The Keyspan path is code nobody has run.~~ **Run now** -- see below. The
  note is kept because the reasoning was right: it *was* transcribed rather
  than tested, and its baud divisor was computed where the mouse driver's
  was a constant. That is exactly the code that needed exercising, and it
  turned out to be correct. The original wording, for the record:
  It is transcribed from
  `usbmouse.asm`, which is verified, but transcription is not testing and
  the baud divisor here is computed where the mouse driver's was a
  constant. Treat it as unwritten until it answers.
* **Function 00h reprograms the adapter from foreground code.** The
  interlock against the timer tick (`fg_busy`) is reasoned rather than
  measured -- it is sound on one CPU, but it has not been hammered.
* **Carrier detect is real on FTDI only.** It comes from bit 7 of the first
  status byte on every IN packet. The Keyspan's one-byte header is not
  decoded, so DCD there will read as whatever `ser_lines` last set.
