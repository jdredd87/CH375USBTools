# CH375Net — USB Ethernet on a machine older than USB

**Status: it reaches the internet.**

```
Sending ICMP packets to 8.8.8.8
Packet sequence number 0 received from 8.8.8.8 in 46.75 ms, ttl=118
Packet sequence number 1 received from 8.8.8.8 in 51.85 ms, ttl=118
Packet sequence number 2 received from 8.8.8.8 in 51.85 ms, ttl=118
Packets sent: 3, Replies received: 3, Replies lost: 0
Average time for a reply: 50.15 ms

Sending ICMP packets to 1.1.1.1
Packet sequence number 0 received from 1.1.1.1 in 47.60 ms, ttl=60
```

`ttl=118` from Google and `ttl=60` from Cloudflare are the giveaway: those
packets crossed a dozen routers each way. This is not a device on the local
segment answering politely — it is a full IP path, out and back.

That is mTCP on an **IBM PS/2 Model 30** — an 8086 from 1987, nine years
older than USB — reaching Google's DNS through a USB Ethernet adapter on a
CH375 ISA card. Bring-up, link negotiation, receive, transmit and a Crynwr
packet driver, all working, with the machine's own network at INT 60h
untouched throughout.

That ~50 ms is mTCP's own timing granularity rather than the wire — timed
properly with `PKTTEST /N=200` the round trip is **6 ms**. Which is a
reasonable illustration of this project generally: most of what looked wrong
turned out to be the instrument.

---

## Start here

**[INSTALL.md](INSTALL.md)** — how to actually use this. It is short.

**[NEXT.md](NEXT.md)** — where the work stopped, the next job and how to
test it, and the traps that will otherwise cost you an evening. Start here if
you are picking this up cold.

**[ADAPTERS.md](ADAPTERS.md)** — which USB Ethernet chipsets are supported,
which need a bring-up writing, and which cannot work. Run `NETID` first; the
box an adapter came in is not evidence of what is inside it.

The whole of it, if you have used a packet driver before:

```
C:\CH375> USBPKT              <- one command, like NE2000.COM
C:\CH375> (mtcp.cfg: packetint 0x65)
C:\CH375> PING 8.8.8.8
```

Nothing to add to `CONFIG.SYS`, nothing to configure. `USBPKT` enumerates the
device over the CH375, works out which of three chipsets it is holding, brings
it up and goes resident. `USBPKT /U` unloads it again.

The three, and how each is chosen:

| | how it is recognised | |
|---|---|---|
| **CDC-ECM** | from the device's own descriptors | any adapter that speaks the class |
| **SR9700 / DM9601** | from the USB ID | it says nothing else that would identify it |
| **AX88179 / 178A** | the fallback | the reference part |

ECM is asked for first, because a class path does not depend on a table of USB
IDs being right. `/X` refuses the ECM path and `/D` refuses the SR9700 one,
which is how to show that a chipset path is what makes a difference on an
adapter that offers more than one.

`ECMLINK` and `SRLINK` are the matching diagnostics — they bring an adapter up
and report every step, without going resident.

The rest of this file is the engineering: what was measured, what was tried
and thrown away, and why the code looks the way it does. It is a notebook,
not a manual.

---

## There is a second driver now, and it is a CLASS driver

`ecm.pas` implements **CDC-ECM**, and `ECMLINK` is its proof-of-life tool.
The difference from everything else here is that ECM is a USB *class* rather
than a chip: the device describes itself, so one bring-up covers adapters
from many vendors — including ones nobody here has bought.

```
C:\CH375> ECMLINK
ECM found, and every one of these was READ, not assumed:
  configuration  : 3
  control iface  : 0
  data iface     : 1  alt 1
  bulk in / out  : 2 / 3
  interrupt in   : 1
  max segment    : 1514
MAC      : A0:CE:C8:BC:0A:91
ARP      : who has 192.168.50.46?  tell 192.168.50.222
           REPLY from 192.168.50.46  is at EC:8E:B5:7A:2C:F5
link     : UP, now that the PHY has settled

  VERDICT: the adapter TRANSMITS and RECEIVES over CDC-ECM.
```

That adapter is an **AX88179A**. It reports the same USB ID as the AX88179,
enumerates on the vendor path, reads its MAC, reports link up, receives
frames — and transmits nothing that is ever answered. Through the class
driver it works. `ADAPTERS.md` has the whole entry and `CHANGELOG.md` has
the three ECM details that are easy to get wrong, all of which bit.

**`ECMLINK` proves TRANSMIT, not just bring-up, and that is deliberate.** A
tool that enumerated the device and printed what it found would have declared
this adapter working, because everything up to and including the MAC read
succeeds on the path that cannot send. An ARP request answered by the host it
asked about is the smallest thing that proves the whole loop: the frame
reached the wire, another machine parsed it, and the reply came back up
through the chip. The reply is checked against both the address asked about
and our own hardware address — the first version accepted any ARP reply and
promptly reported one from a host nobody had asked about.

**And `USBPKT` speaks it too, so mTCP runs over it.** The whole
configuration -- which configuration, which interfaces, which alt setting,
which endpoints, the MAC -- is read from the device.

Verified on hardware, in two different ways that are worth keeping apart:

| | |
|---|---|
| by harness | came up on the class path unattended from `AUTOEXEC.BAT`; `PING` 4 of 4; **130 MB** of downloads verified byte by byte, **zero mismatches**, every driver error counter still zero across 52,739 bursts |
| **at the keyboard** | **telnet, FTP, HTTP GETs and pings** -- used as an ordinary network card by a person, not a script |

The second row is not a lesser version of the first. FTP opens two
simultaneous TCP connections, which no test here had done; telnet is a
long-lived stream of tiny packets where latency is felt rather than
averaged away; and a person notices "sluggish", which no counter in this
driver reports.

**One thing will waste your afternoon if you do not know it.** This adapter
stops offering its ECM configuration once its vendor bring-up has run, and
nothing in software undoes that -- not a USB bus reset, and *not a warm
reboot*, because the CH375 feeds the adapter off the ISA bus. Power-cycle
the machine or re-plug the adapter before testing anything about ECM.
`ADAPTERS.md` has the measurement.

---

A USB-to-RJ45 adapter, an ISA card from a different decade, and an IBM PS/2
Model 30 with an 8086 in it. The question this project answers is whether a
CH375 in host mode can carry a class of device nobody uses it for.

The adapter is an **ASIX AX88179** (`0B95:1790`) — a USB 3.0 gigabit part,
running here at full speed, 12 Mbps.

## What works today

```
USBLINK 0.2.0 -- AX88179 bring-up over a CH375 -- StevenC & Claude
device   : 0B95:1790
bus      : full speed (12 Mbps)

Bringing the chip up
  set configuration 01............ ok
  PHY power/reset low............. ok
  ...
MAC address: 40:AE:30:6D:00:34
PHY id     : 001C C915

Link is up.
  medium mode   : 0136  10 Mbps full duplex
  rx control    : 01A8
```

And real frames arrive. This is one, read off the wire by `USBRECV` and
decoded by hand:

```
FF FF FF FF FF FF   destination: broadcast
0C C1 19 59 B1 D2   source
08 00               IPv4
45 00 00 C8 ...     200 bytes, protocol 11 = UDP
C0 A8 32 08         from 192.168.50.8
```

## Getting it running

One command, the way `NE2000.COM` is one command:

```
C:\CH375> USBPKT
USBPKT 0.1.0 -- StevenC & Claude
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.
```

`USBPKT` enumerates the device over the CH375, brings the AX88179 up, and
goes resident. Nothing has to be run before it. Point mTCP at it with a
**copy** of your config — never the one your working network uses:

```
SET MTCPCFG=C:\CH375\MTCPAX.CFG      (packetint 0x65)
PING 8.8.8.8
SET MTCPCFG=c:\network\mtcp\mtcp.cfg
```

`USBPKT /U` unloads it, `/S` reports counters, `/?` explains the rest.

### Loading it at boot

This works now, and on the machine it was written for it is what
`AUTOEXEC.BAT` does. One rule makes it safe:

```
IF EXIST C:\CH375\TRYING.FLG GOTO USBWEDGED
ECHO trying > C:\CH375\TRYING.FLG
C:\CH375\USBPKT.COM /I=65
IF ERRORLEVEL 1 GOTO NOUSB
DEL C:\CH375\TRYING.FLG
SET MTCPCFG=C:\CH375\MTCPAX.CFG
GOTO NETOK
:USBWEDGED
DEL C:\CH375\TRYING.FLG
ECHO Last boot hung bringing the adapter up - skipped this time.
GOTO NETOK
:NOUSB
IF EXIST C:\CH375\TRYING.FLG DEL C:\CH375\TRYING.FLG
ECHO USB adapter did not come up - staying on the other card.
:NETOK
```

`IF ERRORLEVEL` catches a bring-up that **fails**. Nothing catches one that
**hangs** — and if the machine is administered over the network, a hang in
`AUTOEXEC.BAT` happens before anything is listening, so it costs a walk to
the keyboard. The flag is the answer: drop it before trying, delete it
after, and a boot that finds it still there knows the last attempt never
came back. Worst case becomes one power cycle.

Do not put `USBLINK` in `AUTOEXEC.BAT`. `USBPKT` needs it for nothing, and
`USBLINK` is what used to hang.

Verified over eight consecutive boots — warm and cold — plus a deliberate
test with the flag planted by hand, which correctly skipped the block and
came up on the other card.

### What to expect from it

Real volume, checksummed on the DOS box itself with `HD.EXE` and compared
against the source:

| size | CRC-32 | result |
|---|---|---|
| 64 KB | `8156EC0D` | exact |
| 512 KB | `9EBAF22E` | exact |
| 1 MB | `04D0E435` | exact |
| 5 MB | `BDBF684D` | exact |
| 10 MB | `2B11D791` | exact |

The 10 MB run is 18,439 bursts collected, 15,858 frames delivered and 11,977
sent -- call it twenty-eight thousand frames through an 8086 -- with every
one of the driver's error counters still at zero afterwards: no nonsense
bursts, no impossible lengths, no overflows, no toggle rescues.

**About 29 KB/s**, fetching 1 MB in 36 seconds. For scale, the ISA NE2000 in
the same machine does the same megabyte in 18s, so this is within about a
factor of two of a card with hardware interrupts and a 16-bit data path.

Getting there took correcting a measurement. `/R` looked to make no
difference at all, and that was wrong: the test wrote its download to disk,
and the disk hid the whole effect. Fetching to `NUL` instead:

| | `/R=1` | `/R=2` | `/R=4` | `/R=8` |
|---|---|---|---|---|
| before | 73s | 61s | 60s | 48s |
| after inlining the read loop | 71s | 43s | **36s** | 36s |

Two separate things there. The poll rate matters (it always did), and the
payload read loop was costing about 150 clocks a byte in call overhead and
port-61h settling reads — roughly 19 µs a byte, which capped the driver near
50 KB/s regardless of the wire. Inlining it without the settling pair is
safe on an 8086 because `IN`+`STOSB`+`LOOP` already leaves ~5 µs between
reads, far more than the chip asks for. On a faster machine it would want
the delay back.

**Latency needs its own measurement, and mTCP is not it.** `PING` reports
about 50 ms over this adapter at every setting, which sent me looking for a
fixed 46 ms delay that does not exist. `PKTTEST /N=200` does the round trip
itself and divides by the count, which is the only honest way to time
something far shorter than the 55 ms BIOS tick:

| | `/R=1` | `/R=4` | `/R=8` | `/R=16` | NE2000 |
|---|---|---|---|---|---|
| round trip | ~55 ms | 13 ms | **6 ms** | 6 ms | 1 ms |

The real figure tracks the poll interval and floors at 6 ms. mTCP's 50 ms is
its own timing granularity, not the wire.

### But `/R` defaults to 1, and that is deliberate

On the numbers above, 8 is obviously right. It was made the default, and
that was wrong. **MS-DOS `EDIT` is what proved it: with the timer at 145 Hz,
opening the editor wedged the machine hard enough to need the power switch.**
At the default it opens, works and exits normally — checked by running it
both with the driver unloaded and with it resident, which makes it an
exoneration rather than an absence of evidence.

The reason is the interrupt chain. This driver hooks INT 08h and reprograms
the PIT, then chains to whoever was there 1 tick in 8, so the BIOS clock and
INT 1Ch stay honest — `TICKCHK` confirms 145 Hz on 08h and 18 Hz on 1Ch, and
DOS keeps perfect time. But:

- a program that hooks INT 08h **after** this driver sits in **front** of it
  and sees all 145 interrupts, so its own timing runs eight times fast;
- a program that reprograms the PIT for itself leaves our 1-in-8 chaining
  dividing the wrong thing, which starves the BIOS clock by a factor of
  eight and looks exactly like a hang.

Neither is something a packet driver gets to do to the rest of the machine
without being asked. So **the default touches the PIT not at all**, and `/R`
is there for when you know what else is running:

```
USBPKT /R=8        while shifting a large file -- 2x throughput, 6 ms
USBPKT             everything else
```

`/R=8` in `AUTOEXEC.BAT` on a machine somebody actually uses is a bad idea,
and this is the cost of the default: ~55 ms round trip instead of 6 ms, and
1 MB in 71 s instead of 36 s. Correctness first. A network driver that
breaks the text editor is not a working network driver.

If you raise `/R`, note that the budget is sized for it: bursts are 1 KB, so
17 reads at ~5.3 µs a byte is 5.7 ms, which fits inside `/R=8`'s 6.9 ms tick.
Raise `AxBulkSize` as well and that stops being true — the two constants are
related and neither travels alone.

`/Q=n` sets the AX88179's bulk-in aggregation timer (default 128), which
decides how long the adapter holds a part-full burst. It was a suspect for
the latency and is not: 2 and 128 measure the same. The switch is kept
because it is a real knob and now a documented dead end.

The remaining ceiling is the ISA bus rather than the wire — the link is
still several times faster than the driver can drain it, which is why the
PHY is held at 10BASE-T and why a faster cable buys nothing.

Verified end to end on the hardware, from one command:

```
ping 192.168.50.1     3/3    ttl=64
ping 8.8.8.8          3/3    ttl=118
ping google.com       3/3    ttl=106     (DNS)
HTGET example.com     559 bytes of HTML
NC test.rebex.net 21  220-Welcome to test.rebex.net!
NC <a telnet BBS> 23  Net2BBS - Resolving your IP Address...
```

with the driver reporting 967 bursts, 154 frames delivered, 108 sent, and
zero of every error counter it keeps.

### Testing it: use our tools, not mTCP

mTCP is for sanity checks on whatever network the machine is administered
over, and nothing else. It finds its driver through a config file, so
pointing it at a second adapter means editing that file for the duration of
a test and remembering to put it back.

`PKTTEST` takes the vector as an argument instead, so it cannot reach the
wrong card:

```
PKTTEST /M=<a free address> /I=65 /T=<address to ARP>   ask, and wait
PKTTEST /M=<a free address> /I=65 /L                    show what arrives
PKTTEST /M=<a free address> /I=65 /R                    ...and answer ARP and pings
```

`/R` makes the adapter answer to its address, so another machine can ping
it. That matters more than it sounds: a driver can receive every broadcast
on the wire and still drop everything addressed to itself, and only unicast
traffic tells the two apart.

### One thing to know first

**Run `USBPKT` before `NETID` or `USBLINK`, not after.** Those two enumerate
the adapter in order to look at it, and an adapter that is already
enumerated will not answer a fresh enumeration — `USBPKT` then stops at step
23 with status FF, which reads like a dead card and is not one.

Removing the adapter's power is what clears that: unplug it and plug it
back in, or power-cycle the machine, which does the same thing because the
card feeds VBUS off the ISA bus. Resetting the CH375 does not, so there is
a limit to what any program here can do about it on its own. `USBPKT`
unconfigures the device on `/U` for exactly this reason, which makes an
unload-then-load usually work — usually, not always.

This is not new and not specific to `USBPKT`; `USBLINK` has always said
"unplug it and plug it back in" for the same state. It is simply much more
visible now that one program does the whole job.

## The programs

| | |
|---|---|
| `src/ax179.pas` | everything that knows what an AX88179 is: the register map, the two vendor requests, the bring-up, and the bulk read |
| `src/usbpkt.asm`, `src/usbpktini.inc` | `USBPKT.COM` — **the one you run.** Enumerates the device, brings the adapter up, and installs a Crynwr packet driver. Needs nothing before it |
| `src/usblink.pas` | `USBLINK.EXE` — runs the same bring-up and reports every stage. Step one historically, and the one that decided the rest was worth writing. Now a diagnostic rather than a prerequisite |
| `src/usbrecv.pas` | `USBRECV.EXE` — reads the bulk endpoint and makes sense of what comes back. Deliberately an **investigation**, not a parser |
| `src/usbsend.pas` | `USBSEND.EXE` — sends an ARP request and waits for a real machine to answer it |
| `src/pktscan.pas` | `PKTSCAN.EXE` — which interrupt vectors hold a packet driver and which are free. Read-only, and the safety net for everything below |

All take `/?`. `/P=hex` sets the CH375 I/O base (`@hex` for `USBPKT`).

`USBPKT /A` skips the bring-up and takes the adapter as it stands, which is
the old two-program arrangement and still the way to tell a fault in the
bring-up apart from a fault in the driver.  (`/N` is a different switch and
always has been: install the vector but do not hook the timer.)

## Transmit, proved the only way that counts

A write to the bulk endpoint returning "success" only means the CH375 took
the bytes. It says nothing about whether a frame reached the wire — a
header field misplaced, a length off by the eight bytes of the header
itself, a padding flag missed, and the chip discards the lot in silence.

So `USBSEND` does not check that the write succeeded. It asks the network a
question and waits to be answered:

```
USBSEND /I=<a free address> /T=<your router>

Asking 192.168.50.1 who it is, claiming to be 192.168.50.222
  request 1 sent

REPLY from 04:D4:C4:D2:2B:00 -- 192.168.50.1 answered us.
```

Both addresses are required and neither is guessed. A tool that defaults to
somebody else's subnet is a tool that puts an address you have never heard
of on your wire.

That reply cannot be manufactured at this end. A frame built on an 8086,
pushed through an ISA card, put on the wire by the adapter, was received by
the router, parsed, believed, and answered back to this MAC. The router's
MAC also matches the one seen in an unrelated IGMP query `USBRECV` caught
earlier, which is a second, independent confirmation.

**The transmit header** is 8 bytes, two little-endian 32-bit words in front
of the frame: the length, then zero — except when the total including the
header lands on an exact multiple of the endpoint's 64-byte packet size, in
which case bits 15 and 31 are set. That same case also needs a zero-length
packet to terminate the USB transfer, which is a *separate* requirement
that happens to arise at the same moment and is easy to confuse with it.

## Why 10BASE-T, on purpose

`USBLINK` restricts the PHY to 10 Mbps unless you pass `/G`.

Every byte of every frame crosses the ISA bus one `IN` instruction at a
time through a 64-byte window, so a 1514-byte frame is **24 separate CH375
transfers**. Whatever that works out to, it is not megabits. A gigabit link
feeding a receiver that slow does not degrade gracefully — it overruns the
chip's buffers and stays overrun.

Dropping to 10 Mbps throws away no performance that was ever available. It
is done by *restricting what the PHY advertises* rather than by forcing the
speed, so the switch at the far end negotiates normally instead of being
left to guess. It negotiated `0136` — 10 Mbps full duplex — first time.

**On a 486 this calculation changes**, which is why the speed is a runtime
switch and not a constant. The same goes for the bulk-in burst size: this
driver holds it down to something it can drain, where Linux lets the chip
fill 20 KB because it can absorb that. Both are `/G` and `/B=` rather than
constants, so faster hardware needs a different flag and not a rewrite.

## Four traps that cost real time

**`BusUp` does not send SET_CONFIGURATION.** It fetches the descriptors and
assigns the address and stops there. A device with an address but no
configuration is in Address state, where *control transfers to endpoint 0
work perfectly and its other endpoints do not exist*. So every register
read and write succeeded, the link came up — and then every IN token to the
bulk endpoint timed out. 7056 of them, in the run that found it.

**`BusUp` also sets `SET_RETRY 8F`, meaning retry NAKs for ever.** That is
right while enumerating: a device still waking up should be waited for. It
is exactly wrong for polling an endpoint that is idle most of the time —
the CH375 sits there retrying instead of reporting, the caller's own wait
expires, and the poll comes back as "no interrupt" having taken seconds.
Two polls in nine seconds, before; 865 in under a second, after.

**A NAK is not the end of a transfer.** In USB a bulk transfer ends with a
*short* packet; a NAK part-way through only means "not ready yet, ask
again". Treating one as the end truncated every multi-frame transfer — the
first capture stopped at 256 bytes with a second frame cut in half and no
trailer anywhere in it, which sent this hunting for a buffer layout that
had been right all along.

And zeroing `AX_RX_BULK_QCTRL` does **not** mean "no aggregation". It means
*no limit*, which is the opposite: the chip keeps appending frames for as
long as traffic arrives and the transfer never ends. One capture reached
55,680 bytes before the buffer gave up.

**An unbounded drain loop will take the machine with it.** When a burst
overflows the buffer the remainder has to be read and discarded, or the
endpoint desynchronises. That drain was written as "read until a short
packet" — but the chip can stream continuously, so on a busy network it
never returns, and a DOS program that never returns hangs the box. It did,
twice, and needed the power cycled. It is bounded now.

`USBPOLL` already knew the first two of these. None of them is written down
anywhere except in source, which is why they are written down here.

## The receive buffer layout, confirmed

The AX88179 does not put a bare frame on its bulk endpoint. A transfer is:

```
[frame 1][pad to 8][frame 2][pad to 8]...[entry 1][entry 2]...[trailer]
```

* **trailer** — the last 4 bytes, little-endian. Low word is the packet
  count, high word is the offset of the entry array.
* **entry** — 4 bytes per packet. `(entry >> 16) and $1FFF` is the frame
  length.
* **frames** — from offset 0, each padded up to an 8-byte boundary. With
  `IP_ALIGN` clear there is no leading pad, so byte 0 is the destination
  MAC.

Verified live, with every invariant checked rather than assumed:

```
trailer at +676 = 02A00001   count=1  hdr_off=672
  [ok] count is sane (1..32)
  [ok] metadata offset inside the buffer
  metadata area 4 bytes over 1 packet(s) = 4 bytes each
  packet 1/1  entry=029E8800  len=670
      EC:8E:B5:7A:2C:F5 -> 01:00:5E:7F:FF:FA  IPv4
  [ok] frames end before the metadata (02A0 <= 02A0)
```

It looked wrong for a long while, and the layout was never the problem —
see the third trap above.

## The byte loops: REP INSB, and measuring the interrupt instead of the file

Three loops in `usbpkt.asm` moved one byte at a time through port I/O. Each
is now a single instruction on a CPU that has the 186 string I/O
instructions, which this NEC V30 does:

| loop | portable | fast |
|---|---|---|
| `ch_read_fast`, pulling a packet out of the chip | `in`/`stosb`/`loop` | `REP INSB` |
| `ch_read_ovl`, draining a burst that cannot be used | `in`/`loop` | `REP INSB` |
| `bulk_out_loop`, transmit | `lodsb` + `call ch_wr` + `dec`/`jne` | `REP OUTSB` |

`Has186` is probed at install time, the portable loops are still there and
still reachable with `/8`, and the fast ones are emitted as `db` bytes
because the assembler targets 8086 and is right to refuse them as source.
Same arrangement as DOSBridge's `starter/cpu.pas`, including the probe order
-- FLAGS bits 12-15, then the undocumented `AAD` to split NEC from Intel,
and only then the shift-count test, which is last because sources disagree
about whether a V20/V30 masks shift counts and this way it is never asked.

### What it bought, measured on one binary

Same 1 MB file, same server, `/8` the only difference:

| | 1 MB | CRC-32 | longest poll |
|---|---|---|---|
| `REP INSB` / `REP OUTSB` | **63.6s** | `998E4325` | **22.0 ms** |
| `/8`, the 8086 loops | 65.3s | `998E4325` | 32.6 ms |

**2.6% on throughput, and 33% off the interrupt.** The second number is the
one worth having. At `/R=1` this driver is round-trip-bound, so making the
reads nearly free cannot move the file transfer much and does not -- what it
moves is the share of the machine one timer interrupt takes while traffic is
flowing, and a poll costing 32.6 ms out of a 55 ms tick is 59% of the
machine. That is the shape of thing that wedged `EDIT` at `/R=8`.

### The estimate this replaced was out by 3x

This file used to say a full burst read was "about 10 ms of a 55 ms tick --
19% of the machine" and that `REP INSB` would take it "to roughly 3 ms".
Measured, the peak poll is **32.6 ms**, and it came down to 22.0 rather than
to a third of anything.

The absolute saving is about what the estimate implied. The share is not,
and the reason is that the poll is not only the read loop: issuing the IN
token, spinning in `ch_wait` for the chip's interrupt, and the
drain-and-unwedge path all sit inside the same measurement. The read loop is
roughly a third of a peak poll rather than all of it, so no amount of making
it free could have reached 3 ms.

### So the driver now times itself

`USBPKT /S` reports `longest poll` in PIT counts and milliseconds. Channel 0
counts down at 1.193 MHz, and latching it either side of `rx_poll` costs
four port accesses -- cheap enough to leave on permanently, which means the
next person to change this code has the number rather than an argument.

It is **only taken at `/R=1`**, and that is not a limitation worth removing.
With the counter at its power-on divisor of 65536 the subtraction is exact
modulo 65536 -- the counter wraps exactly where 16-bit arithmetic does -- for
anything up to a full 54.9 ms period. Once `/R` has reloaded the counter with
something smaller, the two no longer agree and a wrapped reading would be
*wrong* rather than absent. Nothing is lost: the poll does the same work per
burst whatever the tick rate, so the figure at `/R=1` is the figure at
`/R=8`. What `/R` changes is how often it is paid.

When nothing has been timed it prints a dash rather than `0.0 ms`, because a
zero would read as "measured, and free".

### `/8`, and the risk it covers

`REP INSB` issues port reads far closer together than the loop it replaces,
and the CH375's settling delays are not decoration -- that was the only real
objection to any of this. `/8` forces the portable loops with one switch and
no rebuild, on the machine where a fault would actually show. If a transfer
ever CRCs wrong, try `/8` first; if `/8` fixes it, that is the answer rather
than a hint.

### And then something DID CRC wrong -- and it is USBPKT, not this change

A 5 MB download came back **5,242,880 bytes, the exact right length, with
the wrong contents.** The obvious suspect was the fast path, and `/8` exists
precisely to settle that in one command. It settled it the other way, and
four runs then boxed the fault in completely:

| same file, same server | size | time | result |
|---|---|---|---|
| written locally by `RAMPCHK /W`, no network at all | 5 MB | | exactly the ramp |
| fetched over the **NE2000** at INT 60h | 5 MB | 62.9s | exactly the ramp |
| fetched over the **NE2000** at INT 60h | 10 MB | 125.3s | exactly the ramp |
| fetched over USBPKT, fast path | 5 MB | 312.0s | **162 bytes wrong** |
| fetched over USBPKT, `/8` portable loops | 5 MB | 309.6s | **wrong, and differently** |
| fetched over USBPKT, fast path, again | 5 MB | 305.6s | exactly the ramp |

**It is intermittent -- two USB runs in three -- so no single clean run
proves anything**, and that is the first thing to internalise before
designing any test here.

It is also what makes the NE2000 rows carry weight, and they had to be
earned. The first version of this section rested on ONE clean NE2000 run and
called the matter settled; at a two-in-three failure rate a single clean run
happens by chance a third of the time even if the NE2000 were equally
affected, so that was not evidence, it was a coin toss reported as a result.
With 15 MB of clean NE2000 exposure -- three 5 MB-equivalents -- the same
coincidence needs about one chance in twenty-five.

So, in order of how well established each is:

* **The disk and DOS file I/O are sound** at this size: a file that never
  crossed a wire reads back perfect.
* **The `REP INSB` change did not cause it.** The `/8` row is the code that
  shipped before this work, and the two corrupt runs differ from each other,
  which rules out a deterministic bug in either byte loop.
* **The fault is very probably in USBPKT** rather than in mTCP, `HTGET` or
  the disk, on the strength of 15 MB clean through a different packet driver
  against 2-in-3 failures through this one. Probable, not proven.

#### What the corruption looks like

Taken from the first corrupt run. Not shifted -- `RAMPCHK` says the stream
stayed in step -- and the damage is **162 altered bytes in a single region**
at offset 3,802,924 of 5,242,880. One region in five megabytes.

Only one event has been examined at this level of detail, so read what
follows as one well-characterised sample rather than as the shape of the
fault. Whether the leading fragment is ALWAYS -64 is the thing to check
next, and it is what would turn the hypothesis below into a diagnosis.

The bytes are the whole diagnosis, and they are not noise:

```
want 2C 2D 2E 2F | 30 31 32 33 34 35 36 37 38 39 3A 3B ...
got  EC ED EE EF | 7C 7D 7E 7F 80 81 82 83 84 85 86 87 ...
```

Two pieces, each internally a clean run of consecutive values -- so this is
real payload from elsewhere in the same stream, substituted rather than
damaged:

* the **first four bytes** carry delta +192;
* the **remaining 158** carry a constant delta of **+76**, running cleanly
  to the end of the region, after which correct data resumes.

**Nothing was lost.** Everything outside those 162 bytes is right, so the
file never went out of step -- which means the bytes that appeared early
also appear in their proper places further on. A 162-byte window was
**overwritten with data duplicated from elsewhere in the stream**, not
shifted and not corrupted bit by bit.

**How far away that data came from, this test cannot say.** The ramp repeats
every 256 bytes, so a delta is only ever a displacement MODULO 256: +192
means -64 or -320 or -576, and +76 means +76 or +332 or +588. An earlier
draft of this section read the first fragment as "exactly 64 bytes earlier"
and made much of 64 being the CH375's bulk maximum packet size. That
coincidence is real and the inference was not: nothing here distinguishes 64
from 320. Anyone wanting the true displacement needs a test file whose
period exceeds the file length -- a counter written as 32-bit words, say --
rather than a byte ramp. `RAMPCHK /W` could write one; the server's files
are what they are.

One more thing it implies, and it is worth stating because it raises the
stakes: a mangled frame that reaches the file is a frame whose TCP checksum
was not what caught it. Either the stack is not verifying on this path or
this one slipped through, and in both cases **the driver's correctness is
load-bearing rather than backed up by the layer above.**

#### A real bug, found by reading rather than by measuring

`rx_deliver` walks the frames in a burst and, for each one, calls `rx_one`
to hand it up. `rx_one` ends in `call far [cs:rcv_tmp]` -- the application's
own receiver, somebody else's code, entered from inside a timer interrupt.
The comment directly above that call states the rule:

> nothing may be assumed about any register after it returns

And then the loop assumes one. The stride to the **next** frame is computed
from `CX` three instructions after the call returns:

```
        push    di
        call    rx_one                   ; DI = offset, CX = length
        pop     di
        inc     word [n_frames]
rxd_skip:
        add     cx, 4                    ; <-- CX, after somebody else's code
        add     cx, 7
        and     cx, 0xFFF8
        add     di, cx                   ; <-- where the next frame starts
```

`DI` is pushed across the call. `CX` is not. So whenever the application's
receiver returns with `CX` changed, `DI` lands somewhere other than the next
frame and every frame parsed after it in that burst is assembled out of the
wrong part of the buffer.

The fix is `push cx` / `pop cx`. It is now in.

**Why it stayed hidden is the interesting part**, and it is the same shape as
several other entries here: the bug is not in this driver's behaviour, it is
in a dependency on somebody else's. A receiver that happens to preserve `CX`
hides it completely and forever. mTCP evidently does so most of the time,
which is why 10 MB used to check out clean and why the fault, when it comes,
is intermittent and load-dependent rather than reproducible.

**What this does NOT yet explain, and it matters.** A frame taken from the
wrong offset has a garbage Ethernet header, and a stack that checks anything
at all should drop it -- costing a retransmission, not a corrupted file. For
these 162 bytes to reach the disk, either the misplaced frame carried a
header plausible enough to be accepted and its payload was then placed by
sequence number, or something downstream is not validating. So this is a
genuine defect that was worth fixing on its own terms, and **calling it the
cause of the corruption would be running ahead of the evidence.**

**And it was not the whole bug, which is why the runs got done.** Two 5 MB
downloads on the CX fix came back clean, which at a two-in-three failure
rate is one chance in nine of meaning nothing -- encouraging, not a result.
Three more were run rather than stopping there, and **the third corrupted**.

That is the entire argument for not declaring victory on two clean runs, and
it is worth the wall-clock every time.

#### The second sample, and what it gave away

| | first event | second event |
|---|---|---|
| file offset | 3,802,924 | 2,915,814 |
| length | **162 bytes** | **162 bytes** |
| first 4 bytes | delta **+192** | delta **+192** |
| remaining 158 | delta **+76** | delta **+76** |

Identical length, identical deltas, at two unrelated offsets in different
downloads. **That is a deterministic code path, not a timing accident** --
and it also settles the mod-256 caveat in practice: the same numbers twice
are almost certainly the same true displacements rather than two different
values aliasing to the same residue.

#### The rest of the same bug: BP

Reading the loop again with "deterministic" in mind: the fix above pushed
`CX` across the call and the loop still depended on a second register.

```
rxd_skip:
        add     cx, 4
        add     cx, 7
        and     cx, 0xFFF8
        add     di, cx
        pop     si
        add     si, bp                   ; <-- BP, after the receiver ran
```

**`BP` carries the entry stride for the whole burst**, and it is read at the
bottom of every iteration to step to the next entry. `SI` and `DX` are
pushed at the top of the loop and `DI` was pushed around the call, so `BP`
was the last register in the loop still exposed to somebody else's code --
and it is the one a C compiler is most likely to be using as a frame
pointer, which makes an application's receiver about the likeliest thing in
the machine to clobber it.

Losing it walks the entry array at the wrong pitch, so every remaining frame
in that burst is handed up with the wrong offset and the wrong length. That
is a much better fit for "162 bytes, same deltas, every time" than the CX
path was.

The fix is `push bp` / `pop bp`, and the rule it should have followed from
the start is the one `rx_one`'s own comment states: **the loop must not
depend on any register surviving the call.** With `BP`, `CX`, `DI`, `SI` and
`DX` all saved, it no longer does.

#### And that did not cure it either

Three more 5 MB runs on the `BP` build, and one came back with 162 bytes
wrong at offset 3,193,318. Its `want`/`got` lines are byte for byte the same
as the previous event's, though that part is less remarkable than it looks:
both regions happen to begin at an offset that is `0xE6` modulo 256, and in
a file whose content is `offset mod 256` that alone fixes every visible
byte. **The invariant worth noticing is the shape, not the bytes** -- the
length and the two deltas are identical across all three events, while the
first event sat at residue `0x2C` and therefore shows different values
carrying exactly the same structure.

So: **two register-preservation bugs, both real, both found by reading, both
fixed, and neither one is the cause.** They were worth fixing on their own
terms -- the loop genuinely must not depend on registers surviving foreign
code, and it did -- but they are not this.

Three events now, and the invariant is exact every time:

* **162 bytes**, never any other length;
* the **first 4** at delta +192;
* the **remaining 158** at delta +76.

A fault that reproduces to the byte across three separate downloads at three
unrelated offsets is not a race and not a timing accident. It is a code path
that does the same wrong thing whenever it is reached.

#### Which is where guessing stops

Two inspections have now produced two plausible, real, and irrelevant
answers. A third guess is not worth making, so the parser has been asked the
question directly instead.

The burst layout puts the frames first and the entry array immediately after
the last one, so **walking every frame must land exactly on the entry
array's offset.** `rx_deliver` now checks that at the end of each burst and
counts the bursts where it does not, reported by `/S` as `bursts whose
frames did not tile`.

It is built to be decisive in both directions, which is the point:

* if it **fires** on the runs that corrupt, the walk is mis-striding and the
  bug is in this parser, with the counter pointing straight at it;
* if it **stays at zero** while a download still comes back wrong, then the
  frames were parsed correctly and handed up correctly, **the burst parser
  is exonerated, and the fault is above the driver** -- mTCP or `HTGET`,
  which the NE2000 control would then have been quietly telling us all along
  only that they behave differently on a fast, clean path than on a slow,
  lossy one.

That second outcome would redirect the entire investigation, which is
exactly why it was worth building an instrument that can produce it.

#### The counter fired, and the file was PERFECT

Five more runs, `/S` sampled after each. Every download came back exactly
the ramp -- and `bursts whose frames did not tile` went from 0 to **1**
during the first of them, then held at 1 for the remaining four.

So a burst really did mis-stride, and **the file it belonged to was
byte-perfect.** That is worth more than a corrupt run would have been at
this stage, because it separates two things that were in danger of being
assumed identical:

* **mis-striding happens.** Roughly once in 60,000 bursts here -- rare, but
  real, and nothing before this counter could see it at all.
* **mis-striding is usually harmless.** Which is exactly what the earlier
  reasoning predicted: a frame lifted from the wrong offset has a garbage
  Ethernet header, mTCP drops it, TCP retransmits, and the file is fine. The
  cost is a wasted frame, not bad data.

That leaves the two candidate events at uncomfortably similar rates -- one
tiling failure in about eleven downloads against one corruption in nine --
so they are not yet distinguishable by frequency, and the honest position is
that they may or may not be the same underlying fault.

**The experiment that separates them is now cheap and running:** `/S` after
every download, so each corruption event can be paired with whether
`n_tile` moved on that same run. Every corruption coinciding with a tiling
increment makes the parser the cause. A corruption with `n_tile` unchanged
exonerates it outright.

The build now also records WHERE a failed walk ended against where it
should have (`tile_di` / `tile_lim` in `/S`), so the next tiling failure
reports its magnitude and direction rather than just its existence, and
counts frames whose end runs past the frame region (`n_outside`) --
**counted, not enforced**, because a bound that wrongly rejects a
legitimate frame breaks networking and this model of the layout has not
earned that much trust yet. Measure first; enforce once it has been quiet
for a while.

#### A 4 GB test pattern, and a confound I walked into for the third time

The displacement has been the strongest clue in this whole investigation
and it was only ever readable modulo 256, because the test files are a ramp
whose byte at offset N is N mod 256. `-64` could equally be -320 or -576.
Worse: a displacement that is an exact multiple of 256 substitutes
IDENTICAL byte values and therefore produces a genuinely correct file, so
the measured rate understates the event rate by an unknown factor.

That wanted a longer-period file, and it turned out not to need anyone
else's server: **dosd serves HTTP on 8080**, which is where the very first
1 MB test came from. So `mkramp.py` also generates `CNT5M.BIN`, a 32-bit
little-endian counter of the word index -- period four gigabytes, so every
displacement in a 5 MB file is unique and readable straight out of the
bytes. `RAMPCHK /K` decodes the word sitting in the wrong place and its
index IS the offset it came from.

Validated by planting the real signature into a counter file and requiring
it back:

```
run 1: offset 20000  len 161  delta +240  (NOT constant)
       +0  came from 19936  displacement -64
       +4  came from 20080  displacement 76
       +8  came from 20084  displacement 76
```

Exactly what was planted. Third re-validation of this instrument after an
edit, and the counter pattern immediately found two bugs in the CHECKER
rather than in itself: a small displacement only changes the low byte or
two of each word, so one 162-byte fault came back as 41 single-byte runs
until runs were made gap-tolerant; and the captured window held only the
bytes that DIFFERED, so the decode never had four contiguous bytes and
never fired at all.

**Then eight counter downloads came back clean, and that is where the
confound is.** Every corruption so far came from the HTTP server on port
80; the counter file can only be served by dosd on 8080. So those eight
runs changed the PATTERN and the SERVER at the same time, which is exactly
the mistake already made twice here -- once with size-and-server on the
first 1 MB comparison, once with a single NE2000 control called decisive.

Eight clean runs is unremarkable on its own (about a 43% outcome at the
measured rate), so nothing is concluded from it either way. The control
that separates the two is cheap and is running: **the same 5 MB ramp file
from dosd on 8080.** If dosd-served downloads never corrupt while port-80
ones do at 10%, the server -- and therefore the TCP dynamics it produces --
is the variable, and the hunt moves away from the driver's data path
entirely.

There is one mild inference available already. The counter pattern reveals
displacements the ramp cannot see, so if multiples of 256 were common the
counter runs should have shown a HIGHER rate than the ramp ones. Eight
clean runs is weak evidence that they are not common, which in turn is
weak evidence that the ramp-measured 10% is not a serious underestimate.

##### The control came back: the server is NOT the variable

Eight runs of the same 5 MB ramp from **dosd on 8080**, and two of them
corrupted -- offsets 4,265,958 and 3,331,558, both 162 bytes, both the same
signature. So corruption happens whichever server is asked, and the server
hypothesis is dead. Worth the 48 minutes: it was a clean, cheap way to
remove a whole class of explanation.

It also disposes of the apparent pattern effect. `0/8` on the counter
against `2/8` on the ramp from the same server looks like the pattern
mattering, and it is not significant at all -- about a one-in-two outcome
by chance. Combined, the ramp has now corrupted 5 times in 38 runs, 13%,
and every group is consistent with that.

##### THE CHECKSUM ARGUMENT, AND AN EXONERATION I HAD NO RIGHT TO MAKE

Two things came together here and they overturn the middle of this
section.

**First: our own stack does not verify receive checksums at all.**
`NetUdpRecv` checks length, IHL, destination address and destination port,
and never looks at the UDP or IP checksum. That matters twice over. It
makes TFTP over our stack a MORE sensitive corruption detector per byte
than HTTP over mTCP -- nothing is filtering -- and it explains something
that had been sitting in plain sight: the `RAMPCHK.EXE` deploy that
"arrived corrupt" earlier went over the NE2000 on this same stack, and
these notes already record ~11% of 40 KB tool deploys failing their CRC.
So frames are being corrupted on BOTH links, and the only reason HTTP
looks clean is that mTCP's checksum is throwing them away.

**Second: a displacement cannot survive a TCP checksum, and I checked
rather than assuming.** The tempting theory was that a 16-bit one's
complement sum is order-independent, so a displaced block would slip
through undetected. Half right, and the wrong half:

| what happened to the frame | checksum |
|---|---|
| a 162-byte block substituted from +76 | **caught** |
| the same, at an odd offset | **caught** |
| two 16-bit words swapped (a true permutation) | **PASSES** |

Only a genuine permutation of the same words is invisible. The observed
fault is a substitution -- one region wrong, everything else in step, the
file not a permutation of itself -- so mTCP's checksum should have caught
it and did not.

Which leaves two possibilities, and both put the fault ABOVE the driver:
either mTCP is not verifying on this path, or **the damage happens after
verification** -- in mTCP's copy out of its own buffer, or in `HTGET`'s
file write.

**And that is where I have to withdraw something.** This section said
"mTCP, `HTGET` and the disk *together* are sound, because the same fetch
through a different packet driver is byte-exact". The arithmetic does not
support it and never did:

```
ramp corruption rate: 5 in 220 MB = 1 per 44 MB
  NE2000 HTTP (clean)     15 MB  expected 0.34 events  P(0)=71%
  USBGET TFTP (clean)     20 MB  expected 0.45 events  P(0)=63%
  counter HTTP (clean)   130 MB  expected 2.95 events  P(0)= 5%
```

**Fifteen megabytes of clean NE2000 is a 71% outcome.** It excluded
nothing. I treated a coin toss as a control -- for the second time in this
investigation, having already been caught doing exactly that with a single
NE2000 run earlier in this same section -- and then built three sections on
top of it.

Note what the same table does to the other two claims. The 20 MB of clean
TFTP is equally uninformative (63%), so USBGET has not exonerated the
driver either. The only result in the table with any weight is the counter
file's 130 MB, at 5%.

##### USBVFY: the chip's receive path, with nothing above it

Every layer above the driver being excluded, the remaining suspect was the
CH375 read -- and every test so far had reached it through a whole stack.
`USBVFY` removes all of it: DOSBridge's own IPv4/UDP, a payload that is a
known function of absolute stream position, every byte checked as it
arrives, no TCP, no mTCP, no file system, and no checksum filtering
anywhere (our stack verifies none on receive, so whatever the chip hands up
is what gets tested).

**First real result: 13.4 MB, 9,637 datagrams, every byte correct.** With
17.75 MB now clean across all receive-only runs.

That is a contribution, not a conclusion: at 1 event per 44 MB it expects
0.3 events, so P(0) is about 74%.

##### The first "event" it reported was my own bug

Worth recording in full, because it produced a precise, confident, and
entirely fabricated number:

```
BAD datagram seq 2037260 at payload offset 0  (stream -1450952336)
  +0 came from 0  displacement 1450952336
```

The sender cycles sequence numbers 0..255, so 2037260 cannot occur.
2037260 * 1396 then overflowed LongInt into a negative stream position, and
the displacements were computed from that. **A number that disproves
itself, in the instrument built to be trusted** -- the exact failure this
project keeps catching everywhere else.

What it actually was: foreign traffic. There was no way to distinguish a
datagram of ours whose header had been corrupted from one that was never
ours, and 84 unrelated datagrams had appeared on that port in a single run.
A `UVFY` magic now identifies ours; the very next run filtered 6 foreign
ones and found zero corruption, and the 45-minute run filtered 25. Building
on that first reading would have produced a fabricated finding about the
driver from traffic that never touched it.

##### And a fidelity gap, found before spending hours on it

A pure listener never transmits. During a real download the box ACKs every
couple of segments, so `pkt_send` and `rx_poll` interleave continuously on
the same chip under the `chip_busy` guard -- and a receive-only test does
not touch that at all.

Which matters most for the result it was most likely to give: a clean run
would have read as the chip being exonerated while saying nothing whatever
about contention. `/A=n` now transmits back every n datagrams, default 2,
which is roughly what a TCP receiver does; `/A=0` turns it off.

**So the experiment is a paired A/B**: alternating 45-minute windows at
`/A=2` and `/A=0`, so nothing varying with time of day can favour an arm.
Six cycles gives about 80 MB and 1.8 expected events per arm. If corruption
appears with transmit interleaved and not without, that is the mechanism --
tested rather than hoped for.

##### The paired A/B, running

| cycle | arm | volume | transmits | result |
|---|---|---|---|---|
| 1 | `/A=2` interleaved | 13.24 MB | 4,755 | clean |
| 1 | `/A=0` receive only | 13.36 MB | 0 | clean |

The interleaving is genuinely being exercised -- 4,755 transmits against
9,510 datagrams -- and has produced nothing. Cumulative across all USBVFY
runs: **44.35 MB clean, zero events**, which at 1 event per 44 MB expects
1.0 and so is a 37% outcome. Not a result yet. Six cycles reaches about 177
MB, where a clean sweep would be near 2% and would say something.

##### One more fidelity gap, checked and deliberately not acted on

USBVFY sends 1400-byte datagrams; an HTTP download carries 1460. If the
smaller frames produced a different burst STRUCTURE, this test could be
blind to the fault and 177 MB of clean would be a false exoneration -- the
same shape of mistake as the missing transmit, so it was worth the
arithmetic rather than an assumption:

| | UDP | frame | padded | burst | USB reads |
|---|---|---|---|---|---|
| USBVFY | 1400 | 1442 | 1448 | 1456 | 23 |
| HTTP | 1460 | 1514 | 1520 | 1528 | 24 |

Both are **single-frame bursts**, comfortably inside the 1984-byte budget,
differing by one 64-byte read. The structure is the same, so the smaller
datagrams cannot hide the fault on that account and the running experiment
was left alone. Disrupting it to chase a difference of one USB read would
have cost a window for nothing.

##### Two lessons about the harness, both self-inflicted

**The listener has to be listening first.** Starting the sender first
killed a run: `NetOpen` must ARP the peer before it can open the IP handle,
and the adapter was already taking 56 KB/s against a drain rate near 36, so
the one frame that mattered was lost in the flood the test itself was
creating.

**Broadcast is not free.** It is necessary here -- nothing on the box
answers ARP while its stack holds only the 0800 handle, so unicast stops
being delivered once the sender's cache lapses, and 9 datagrams arrived in
15 minutes before that was understood. But it reaches every host on the
segment, and on this LAN that includes the PicoMEM WiFi interface DOSBridge
runs over: at 40/s the agent could not get its own ARP through, went
offline, and a whole window's result was lost. 12/s is the rate that has
proved reliable.

#### THE CONTROL CAME BACK: it is the USB path, and mTCP is not checksumming

30 NE2000 runs, 150 MB, **zero corruptions.**

```
expected 3.4 events if mTCP or HTGET were the cause  ->  P(0) = 3.3%
with the earlier 15 MB, 165 MB clean                ->  P(0) = 2.4%
```

So **mTCP, `HTGET` and the disk are excluded** -- properly this time, by
enough volume to mean something rather than by a coin toss called a
control. And the fault is specific to the USB path.

That resolves the checksum argument, and only one way. A substitution DOES
change a TCP checksum -- measured above -- so if mTCP were verifying, a
mangled frame would be discarded and never reach the file. Corrupt data
does reach the file. Therefore **mTCP is not verifying receive TCP
checksums on this path**, which is why driver-level damage gets through at
all rather than costing a retransmission.

It also disposes of the deploy-CRC observation that pointed the other way.
~11% of 40 KB tool deploys failing their checksum looked like frame
corruption on the NE2000, and 150 MB of clean NE2000 says it is not: those
failures are the documented mid-transfer stall and its resume arithmetic,
not bytes being altered on the wire.

##### Which brings back the 64, and this time it means something

The first reading of the signature called the leading fragment "exactly 64
bytes earlier" and made much of 64 being the CH375's bulk maximum packet
size. That was retracted, correctly, because a ramp only gives the
displacement modulo 256 and nothing distinguished -64 from -320.

With the fault now localised to the USB path, and with the burst parser
already exonerated by the tiling counter, what is left between the wire and
mTCP is the CH375 read itself -- and a chip whose data FIFO occasionally
returns bytes from the wrong offset would produce exactly this:

* a **displacement** rather than altered bytes, which no byte-moving loop
  can produce on its own -- a bad loop gives wrong bytes, not bytes from
  the wrong place;
* **independent of which loop reads them**, which is why the fast path and
  `/8` corrupt identically -- the chip is the source, not the code;
* **frames that assemble perfectly**, because the burst structure and the
  trailer are read correctly and only the payload bytes inside them are
  wrong, which is precisely what the tiling counter has been saying;
* **only on this adapter**, because nothing else in the machine goes
  through a CH375.

So the original intuition may well have been right for the wrong reason.
It is still not established: the displacement is still only known modulo
256, and "-64 is one USB packet" is only compelling if the true value is
-64 rather than -320 or -576.

**That is exactly what the counter file settles**, and it is now the one
measurement worth spending hours on. A 20-run counter soak is in flight;
at the measured rate it has about a 90% chance of catching an event, and
one event reports the true displacement outright. If it reads -64 and +76
exactly, the chip's 64-byte packet buffer is implicated and this stops
being a hunt. If it reads -320 or -1088, the 64 was a coincidence twice
over.

If the fault is in mTCP or `HTGET`, it must appear over the **NE2000** at
the same rate per byte, because that path runs the identical stack, the
identical client and the identical disk. And the NE2000 moves 5 MB in 63
seconds against 312 -- five times faster -- so the volume needed is
affordable for the first time:

* 30 runs is 150 MB, about 40 minutes, and expects **3.4 events** if mTCP
  or `HTGET` is doing it.
* Zero events over that volume drops the probability to about 3%, which
  would exclude them properly rather than by assertion, and make the fault
  specific to the USB path after all.

That is the next run. It should have been the run made hours ago, instead
of a single clean 5 MB being called a control.

##### An unexpected asymmetry: 0 of 20 on the counter, 5 of 38 on the ramp

Twelve more counter downloads, all clean. That is **0 corruptions in 20
counter runs against 5 in 38 ramp runs** -- p about 0.15, so still short of
significant, but two independent groups (8 and 12) both coming back
perfectly clean is no longer comfortably ignorable.

If it is real it is a big clue, because **the only difference between the
two is the file's contents.** Same server, same size, same URL shape, same
driver, same disk, interleaved in time.

It also cannot be an artifact of the counter pattern hiding the fault,
which was the first thing to check. A displacement is invisible in a ramp
whenever it is a multiple of 256, because the substituted bytes are then
identical. There is no equivalent blind spot in the counter: the period is
four gigabytes, so a displacement of -64 bytes is -16 words and changes the
low byte of every word by 16. `RAMPCHK /K` was shown to read exactly that
back from a planted fault. Whatever else is going on, the counter runs are
not concealing corruption -- they are not experiencing it.

**A data-dependent fault is not as absurd as it sounds**, and there is a
mechanism worth naming: for corrupted bytes to reach the file at all, the
frame carrying them has to survive the TCP checksum. Whether a substituted
block passes depends entirely on the arithmetic of the bytes involved, and
a ramp is far more structured than a counter -- consecutive 16-bit words in
a ramp differ by a constant, so a displaced block's checksum contribution
shifts in a highly regular way. It is at least arguable that the ramp lets
mangled frames through where the counter does not, in which case BOTH
patterns are being corrupted equally and only one of them shows it. That
would make the observed asymmetry a property of the detector, not the
fault.

Which is testable, and is the run in flight: **six ramp and six counter
downloads alternating in a single job**, so time-varying conditions cannot
favour one. Either the asymmetry survives a paired design or it does not.

##### And the structure is now MEASURED, not inferred

The delta tally earns its place here. Both new events report:

```
deltas +192 x4 +76 x158
```

**Exactly four bytes at +192 (-64) and exactly 158 at +76**, across the
whole run rather than the first 32 bytes of it. Every previous statement
of this structure was an inference from a 32-byte window; this is the
measurement, and it agrees. Five events, one shape:

| | |
|---|---|
| first piece | always **4 bytes**, displacement -64 (mod 256) |
| second piece | the remainder, displacement +76 (mod 256) |
| length | 162 four times, 82 once -- so the SECOND piece varies |
| alignment | every event starts at an even offset (5 of 5) |

A fixed displacement with a variable length is the shape of a structural
offset applied in the wrong place. The four-byte first piece is suggestive
on its own: four bytes is the Ethernet FCS, which this driver's own parser
has to trim off every frame because the length the chip reports includes
it.

#### Taking mTCP out of the path: USBGET

`USBGET` fetches a file over the CH375 adapter using DOSBridge's own
IPv4/UDP/TFTP stack, to the same disk, with mTCP nowhere in the path. It
needs two additive overrides in `net.pas` because the Net unit otherwise
takes the first packet driver on 60h..80h -- always the NE2000 here -- and
reads the bridge's own config, so without them it would have tested the
wrong adapter and come back reassuringly clean.

**First result: 5 MB byte-exact.**

```
USBGET: vector 101  addr 192.168.50.222  cfg C:\CH375\MTCPAX.CFG
USBGET: 5242880 bytes on vector 101 (no mTCP)
  blocks 3745 of 1400  resends 110  dups 0  restarts 55
VERDICT: exactly the ramp.
```

(101 decimal is 65h; the resolved address and config are printed precisely
so that a silent fallback to the bridge's own `.66` cannot be mistaken for a
network fault -- see below, where exactly that trap was walked into.)

**What one clean run is worth, stated before more were run: very little,
and only in one direction.** The test is asymmetric by construction and the
tool's own header says so. Corruption here would convict the driver
outright, because there is no TCP left to blame. Cleanliness cannot convict
mTCP, because TFTP is stop-and-wait with one packet in flight and never
builds the conditions a saturated TCP connection does. It can only fail to
convict the driver.

**55 flow restarts** is the number to keep from that run. The mid-transfer
stall this link has always had is firing constantly, so the USB path is
having a hard time under TFTP too -- it is just that TFTP's stop-and-wait
recovers from it byte-exactly, and every restart re-requests from a known
offset.

##### And a self-inflicted failure worth recording

The first attempt reported `no reply after 3 requests` and gave up in 1.3
seconds. That reads as a dead network. It was a timeout that was never
given a chance: `TftpGet`'s `FirstWait` was passed as **0** where `UGET`
passes 36 ticks, and a driver polled at 18.2 Hz cannot answer inside no
time at all.

Worth recording because of how convincingly it framed the hardware -- three
requests, two resends, no answer, over a driver already under suspicion for
data corruption. The correct diagnosis was one line of my own argument
list. It is also why the tool now prints its resolved address: the *other*
way this fails silently is the config override not taking, which leaves
`NetMyIP` as the bridge's `.66`, sends the server's reply to the NE2000's
MAC, and produces the identical message with nothing to distinguish it.

#### THE PARSER IS EXONERATED

The paired experiment came back, and it is unambiguous. Eight downloads,
driver reloaded between each so every counter is per-download:

| run | file | did not tile | frames past region |
|---|---|---|---|
| 3 | **162 bytes wrong** | **0** | **0** |
| 4 | **82 bytes wrong** | **0** | **0** |
| 7 | clean | 1 (ended at 64, wanted 1584) | 0 |
| 1, 2, 5, 6, 8 | clean | 0 | 0 |

**Two corruptions with the parser reporting nothing at all, and the one
parser anomaly produced a perfect file.** Both directions, in one run of
eight.

So the burst walk is not doing this. Neither is the out-of-region delivery
that had just been given a whole section as the leading mechanism -- that
theory was coherent, fitted the signature, and is now dead. It took one
paired observation to kill it, against the dozen unpaired clean runs that
would have proved nothing.

**This is what the counter was built for.** It was written to be able to
come back zero on a corrupt run, and the reason for building it that way
rather than making a third guess is that a guess cannot produce this.

#### Which moves the hunt above the driver -- and complicates the NE2000 control

If the frames are parsed correctly and handed up correctly, then what
reaches mTCP is right and what lands on disk is wrong, so the fault is in
mTCP, in `HTGET`, or in how this driver's upcall interacts with them. But
the NE2000 runs the same mTCP and the same `HTGET` over the same disk and
is clean over 15 MB, so it cannot be a plain bug in either.

What differs is not the code but the CONDITIONS. The NE2000 moves 5 MB in
62.9s and this driver takes 312s -- **five times slower** -- which is a
completely different regime for a TCP connection: a receive window that
actually fills, retransmission timers that actually fire, and out-of-order
and overlapping segments that a fast clean path may simply never produce.
A stack that mishandles an overlapping retransmission would corrupt exactly
like this: a region filled with data from a nearby but wrong stream
position, everything else in step.

That reading also fits the invariant better than anything so far. **The
displacements are fixed at -64 and +76 while the length varies** -- 162 four
times and 82 once -- and a fixed displacement with a variable length is the
shape of a structural offset applied in the wrong place, not of a race.

The next experiment is therefore about the regime rather than the code:
**run the soak at `/R=8`**, which roughly doubles this driver's throughput
and cuts its latency from about 55 ms to 6. If the corruption rate falls
with the timing, it is the conditions and the hunt belongs in the stack. If
it holds at the same rate per byte, that points back at the data path. It
also halves the cost of every run, which is worth having either way.

`/R=8` is the sanctioned use of that switch -- fine for a big transfer,
never in `AUTOEXEC.BAT` -- and nothing that hooks INT 08h is running here.

#### The theory this replaced: out-of-region frames

Kept because the argument was good and someone will reconstruct it
otherwise.



One download, 5,433 bursts, with the new detail reporting:

```
  bursts whose frames did not tile=2  (last ended at 2112, wanted 256)
  frames past the frame region=4
```

**Two mis-strides and four out-of-region frames in a SINGLE download** --
where the earlier cumulative counter had read 1 across 60,000 bursts.

**And that run turned out to be the outlier, not the norm.** Six more
downloads with per-run counters -- the driver reloaded between each, so the
numbers are per-download rather than cumulative -- gave:

| run | bursts | did not tile | past the region |
|---|---|---|---|
| the run above | 5,433 | 2 | 4 |
| 1, 2, 3, 5, 6 | ~5,400 each | 0 | 0 |
| 4 | 5,361 | 1 (ended at 80, wanted 160) | 0 |

So `n_outside` fired four times in one download and **not once in the six
after it**. Writing "about four times per 5 MB download" from that single
sample was the third time in this investigation that one observation got
promoted to a rate, and it is wrong for the same reason each time. The
honest figure is 4 events in roughly 38,000 bursts across seven downloads,
concentrated entirely in one of them -- which is a hint that they arrive in
clusters, and not yet evidence of anything.

The detail is the interesting part. That walk ended at offset **2112** when
the frames occupied only the first **256** bytes of the burst. 2112 is past
`RXBUF_SZ` (2048) -- past the receive buffer entirely -- and the declaration
list says what is on the other side of that boundary:

```
rxbuf:      times RXBUF_SZ db 0      ; 2048
txbuf:      times TXBUF_SZ db 0      ; 1536, immediately after
```

So a runaway walk reads into the **transmit** buffer.

#### Which finally gives the corruption a plausible mechanism

There are two bands a mis-parsed frame can land in, and they behave
completely differently:

* **end beyond `RXBUF_SZ`** -- caught by the existing check and skipped, so
  never delivered. Harmless.
* **end beyond the frames region but still inside the buffer** -- passes the
  existing check and **is delivered**, carrying bytes from beyond what this
  burst actually received. `rxbuf` is never cleared, so those bytes are
  leftovers from an earlier burst: real stream payload from somewhere else.

That second band is exactly the observed corruption -- data duplicated from
elsewhere in the stream, the file otherwise in step -- and it is the band
nothing was checking. `n_outside` fires rarely and in clusters -- four events in
seven downloads, all in one of them -- and corruption appears in roughly one
download in twenty on this build, which is at least the right order for
"most such frames have a garbage Ethernet header and get dropped,
occasionally one is plausible enough to be accepted". Right order is not
evidence; the correlation test below is.

**Enforcing the bound is the obvious next change and it is being held
back deliberately.** At the rate the corruption now appears -- about one
download in twenty -- switching behaviour and then seeing a run of clean
transfers would prove nothing whatever, because a run of clean transfers is
the expected outcome either way. Sixty-odd runs would be needed to tell
enforcement from luck.

The cheaper experiment first: **soak on the current build with per-run
counters, and when a corruption finally happens, look at whether `n_tile`
or `n_outside` fired on that same download.** One paired observation is
worth more than a dozen unpaired clean runs, and it is available for the
price of waiting rather than the price of sixty controlled runs.

Then enforce, with a baseline to compare against.

#### Earlier, before that: two runs with it armed, both clean, counter zero No corruption
event, so nothing yet about the cause -- but not a wasted run either.
**11,419 bursts and 5,699 bursts respectively, with zero tiling failures**,
which establishes the check does not false-positive on healthy traffic. That
matters: a counter that fired all the time would have been worthless in
either direction, and it means a non-zero reading later will mean something.

More runs are queued to catch an event with the instrument armed.

#### Did the register fixes help at all? Possibly, and only possibly

Worth recording because it is the sort of number that gets quoted later:

| build | 5 MB runs | corrupt | |
|---|---|---|---|
| before either fix | 3 | 2 | 67% |
| after `CX` | 5 | 1 | |
| after `CX` + `BP` | 9 | 1 | 11% |

**Six of those nine were consecutive clean runs on the final code**, and that
is enough to say something: if the rate were still 67%, six clean in a row
would happen once in 729 times. So the register fixes really did help, and
substantially.

They did not cure it. One event occurred on the fixed code, so the honest
description is a large partial improvement with the underlying fault still
present -- which is a much less satisfying place to stop than "fixed", and
the reason to keep the tiling counter permanently rather than treating the
matter as closed.

#### Making the hunt affordable: RAMPCHK got 18x faster

At an 11% event rate, catching one with the counter armed takes on the order
of nine runs, and each was eleven minutes: five to fetch and six for the
check. The check being the slower half was absurd -- it is a local disk read
-- and the reason was that it walked five million bytes through a Pascal
loop.

`BUFSZ` is a multiple of the ramp's 256-byte period and every block starts
at a multiple of `BUFSZ`, so **every block's expected contents are the same
8192 bytes.** Build that reference once and a clean block costs a single
`CompareByte` instead of 8192 individual tests; only blocks that fail it pay
for the per-byte walk that locates the runs, and on a healthy file that is
none of them.

**340 seconds to 18.3.** A run cycle went from eleven minutes to five and a
half.

The assumption degrades safely, which is why it is allowed to be an
assumption: if DOS ever returned a short read mid-file, later blocks would
start off the 256-byte period, the reference would stop matching, and those
blocks would simply fall through to the slow path -- which computes the
expected byte from the absolute offset and is always right. Lost speed, not
a wrong answer.

And it was re-validated against the same three crafted files before being
believed a second time, because the fast path changes the detection logic
and a passing instrument that has been edited is just an instrument that has
not been checked. All three still name their faults exactly, and the
`blocks fast` counts confirm the shortcut is doing what it claims: 8 of 8 on
the clean file, 2 on the shifted one (the whole blocks before the seam), 5
on the altered one (the three blocks containing damage took the slow path).

#### The other candidate, still unexamined

A second weakness, in the same routine and easily confused with the one
above. They are not the same thing: the bug above is that `CX` is destroyed
by somebody else's code, and this one is that the burst LENGTH is never kept
anywhere in the first place. Fixing the first does not fix the second.

`rx_deliver` is handed `CX` = the number of bytes the burst actually
delivered, uses it to locate the trailer, and then reuses the register
without ever storing that length. Every per-frame bounds check after that
point is therefore against the size of the buffer:

```
        mov     bx, di
        add     bx, cx
        cmp     bx, RXBUF_SZ        ; the BUFFER, not this burst
        ja      short rxd_skip
```

`rxbuf` is not cleared between bursts, so a trailer that claims a frame
extending past the bytes just received will be handed up bytes left over
from an EARLIER burst -- which is real stream payload from somewhere else,
duplicated, with the file staying in step everywhere else. That is the
observed signature, and it also explains why every counter reads zero:
nothing in the parser is looking for it.

It fits the mod-256 caveat above too. Data left over from a previous burst
is displaced by something on the order of a burst, which shows up as a small
delta and would have been badly misread as "64 bytes".

**This is a hypothesis with a code basis, not a diagnosis.** What would
settle it: check the entry array's frames tile the received burst exactly
-- offsets and lengths summing to `CX` -- and count the ones that do not. If
that counter fires on the runs that corrupt and stays at zero on the runs
that do not, it is the bug.

#### Three things this establishes about evidence, not about the bug

* **The 1 MB test was never a test.** It passed twice on the fast path, and
  that is exactly what a rare fault looks like at a fifth of the exposure.
  This project has made the identical mistake elsewhere -- DOSBridge's
  `simulate_dos.py` moved an 8-byte payload and so could never have caught a
  truncation at 513 bytes. Size the test to the failure, not to patience.
* **Every error counter read zero on both corrupt runs.** Bursts that made
  no sense, impossible lengths, oversized bursts, toggle rescues: 0, 0, 0,
  0. The driver cannot see this happening. "Every counter reads zero" has
  been quoted throughout these notes as though it meant the receive path was
  sound; it only ever meant that nothing *detected* a fault.
* **`longest poll` was identical on the corrupt and the clean runs** -- 22.0
  ms fast, 32.6 ms portable, matching their 1 MB figures to four counts. So
  it does not present as a poll that ran long either.

#### The instrument: `RAMPCHK`

The test files are a repeating `00`..`FF` ramp, so the correct byte at any
offset is `offset mod 256`, and that makes a bad download self-describing in
a way a checksum can never be. A CRC only says "no". `RAMPCHK` says where,
how much, and -- the part that matters -- **whether the stream was ALTERED
or SHIFTED**, which have completely different causes:

* bytes dropped or duplicated leave everything afterwards a clean ramp that
  no longer lines up with its own address, so every later byte is wrong by
  the *same* amount: one enormous constant-delta run, and the delta is the
  number of bytes lost;
* bytes damaged in place leave the stream in step and show up as short runs
  with varying deltas.

It was validated before being believed, against three crafted files -- clean,
three bytes dropped at offset 20000, three bytes altered -- and it correctly
identified all three, naming the exact offsets and calling the dropped-byte
case `SHIFTED ... 3 byte(s) were DROPPED there`. An instrument that has not
been shown able to fail is not evidence, and this file has had to relearn
that more than once.

`RAMPCHK /W <bytes>` writes a ramp instead of checking one, which is what
made the disk row of the table above possible: no packet driver, no adapter,
no server in the path at all.

#### It draws a spinner, and it does it on STDERR

A long run over the bridge used to be indistinguishable from a wedged
machine, because a job's stdout is redirected into `OUT.TXT` and nothing
reaches the screen until the job ends -- so a 26-minute read showed nothing
at all while working perfectly. COMMAND.COM 6.22 has **no stderr
redirection**, which is normally a nuisance here and is exactly what is
wanted for this: handle 2 reaches the console whatever the batch does with
handle 1. The captured output stays clean and the box gets a heartbeat.

One character then a backspace, so it animates in place and scrolls nothing
-- the same trick DOSBridge's `UGET` uses. It ticks **every 8 KB block**,
about twice a second here. It was written to tick every 256 KB first, which
on this machine is one move every eighteen seconds: a heartbeat slower than
the observer's patience is not a heartbeat, and it would have failed at the
one job it exists to do.



## Measured throughput

About **1650 bytes/sec** sustained, with the link deliberately loaded.
That is roughly 13 kbit/s, and it is a real measurement rather than an
estimate.

The interesting part is where it goes. In a 15-second run there were
**12,112 idle polls and only ~390 reads that carried data** — so the
limit is not how fast bytes come out of the CH375, it is that the chip
hands us data on about 3% of polls. Raw read bandwidth looks closer to
50 KB/s if the duty cycle could be fixed.

Burst size matters and not in the obvious direction. `/B=02` gives
1650 B/s; `/B=08` gives **302 B/s** — five times worse, because a larger
threshold makes the chip wait longer and drop more while it waits. The
default is 2 for that measured reason and not a guessed one.

## Not losing the machine

This box is administered over its own network. The working path is a packet
driver at **INT 60h**, `pm2000.com`, loaded from `AUTOEXEC.BAT` at boot,
with mTCP configured `packetint 0x60`. Break that and the machine goes
silent with no way in to undo it.

`AI.BAT` already states the principle, and it is the right one:

> *TZ lives here and not in AUTOEXEC.BAT: a mistake in AUTOEXEC.BAT breaks
> the network before the agent runs and needs hands on the keyboard, while
> a mistake here is fixable over the wire.*

So the rules for anything in this project that goes resident:

1. **The recovery mechanism already exists: power-cycle.** `pm2000.com`
   loads at boot, so a hard reset always comes back with working
   networking — *provided `AUTOEXEC.BAT` is never touched.*
2. **Never add anything from this project to `AUTOEXEC.BAT`.** A TSR that
   hangs at boot is not recoverable remotely at any price. This was tried
   anyway on 2026-09-09, with an `IF ERRORLEVEL` fallback that was supposed
   to make it safe. On four boots out of five, cold power cycles included,
   `USBLINK` hung before the machine became reachable — and a hang sets no
   errorlevel, so the fallback never ran. Every recovery needed the power
   switch. The rule stands, and now it is measured rather than assumed.
3. **Never install on INT 60h.** `PKTSCAN` says what is free; on this
   machine that is `61-66`, `68-6C`, `6E-6F` and `78-7E`. The driver here
   defaults to **65h** and refuses 60h outright.
4. **Refuse to install over an existing packet driver.** The signature is
   there to be checked, so check it.
5. **Always unloadable**, and every test runs load → check → unload as a
   single command, so a failure part-way through cannot leave a TSR
   resident.
6. **`PKTSCAN` before and after.** If 60h still answers, the way back is
   still there.

```
PKTSCAN 1.0.0 -- packet drivers in the interrupt table -- StevenC & Claude

  60h  15A2:03CE   PACKET DRIVER

1 packet driver(s) between 60h and 80h.
Vectors reading 0000:0000: 61 62 63 64 65 66 68 69 6A 6B 6C 6E 6F 78 79 7A 7B 7C 7D 7E
```

Note that `67h` and `6Dh` are in use but are *not* packet drivers — EMS and
video respectively. `PKTSCAN` reports them as occupied rather than free,
which is the distinction that matters when picking a vector.

## The packet driver

`USBPKT.COM` **installs, runs and unloads cleanly.** Proven on the hardware,
with the working network at 60h untouched throughout:

```
=== part one: /N, no timer hook ===
Resident at vector 65h.
  60h  15A2:03CE   PACKET DRIVER      <- the machine's own network
  65h  16DD:1245   PACKET DRIVER      <- this one
USBPKT unloaded.

=== part two: full, timer hooked ===
Resident at vector 65h.
  vector=65   I/O base=0260
  MAC=40:AE:30:6D:00:34
  open handles=0
  timer ticks=10
USBPKT unloaded.
=== done ===
```

`timer ticks=10` is the INT 08h hook firing ten times between install and
status. `PKTSCAN` afterwards shows 60h alone, exactly as before.

### The bug that made this look impossible for hours

`op_nopoll` — the flag saying whether the timer was hooked — lived in the
transient half of the image. `/U` reads it out of the *resident* copy to
decide whether to restore INT 08h, and that offset lands past
`resident_end`, in memory DOS has already taken back. So the answer was
whatever happened to be lying there.

When the garbage read non-zero, `/U` skipped a restore that was mandatory,
leaving our handler in the interrupt vector pointing at memory now issued to
something else. The machine died on some later timer tick — which is why the
fault never appeared in the program that caused it, and why the next
unrelated program looked guilty.

In the `/N` case the same garbage skipped a restore that genuinely *was*
skippable, so that path passed. Right by accident is the worst kind of
right: it makes the broken case look like a different bug.

### Three instruments earned their keep

* **`/N`** — install the vector but do not hook the timer. It is what
  separated "going resident is broken" from "the ISR is broken", and the
  answer was neither: it was unloading.
* **A batch file writing to a log.** `dosctl exec` does not echo program
  output to the screen and its result never arrives if the job outlives the
  timeout, so a file on disk is the only evidence that survives either. Both
  of those cost real time before being understood.
* **A heartbeat poked into video memory from the ISR.** A DOS box that has
  stopped answering still has a screen, and a capture card can photograph
  it. Two stores, and the only channel that reports from a dead machine.

## mTCP talks to it

mTCP's own `pkttool` finds the driver and reads everything off it — code
none of which is mine:

```
Details for driver at software interrupt: 0x65
  Name: AX88179/CH375
  Version: 1   Class: 1   Type: 0   Interface Number: 0
  Function flag: 2  (basic and extended functions)
  Current receive mode: packets for this MAC and broadcast packets
  MAC address: 40:AE:30:6D:00:34
```

And `PKTCAP` — DOSBridge's own capture tool, also not mine — registers a
real handle through `access_type` and gets clean frames out of it:

```
frames captured: 16      bytes: 2320      dropped (busy): 0
first frame    : 64 bytes
  destination  : FF:FF:FF:FF:FF:FF
  source       : 24:F5:A2:5F:61:A5
  ethertype    : 0806  (ARP)
```

So `driver_info`, `get_address`, `get_rcv_mode`, `get_statistics`,
`access_type`, `release_type` and the two-call receive handshake are all
exercised by third-party software and all correct.

`send_pkt` moves frames too: 11 out, 660 bytes — exactly 11 × 60, the right
size for an ARP request.

### The two bugs between "frames move" and "it pings"

Both hid behind a partial success, which is the worst place for a bug to
hide.

**The delivered length included the Ethernet FCS.** `RX_CTL_DROP_CRC` means
"discard frames whose CRC is wrong", not "strip the CRC" — the four bytes
arrive with the frame. `PKTCAP`'s dump had said so plainly for some time: a
42-byte ARP request, padded to the 60-byte minimum, arrived as **64 bytes**
with four non-zero bytes sitting after the padding.

**`bulk_out` restored `SI` on success.** It was added for the NAK rewind and
applied to the success path too, so the caller's `SI` never advanced and
every 64-byte packet after the first re-sent the *beginning* of the frame.

That second one is why the fault looked like a receive problem for so long.
A 60-byte ARP request is 68 bytes with the transmit header — 64 plus 4 — and
those four repeated bytes land in padding nobody reads, so **ARP resolved
perfectly**. A 74-byte ping is 82 — 64 plus 18 — and those eighteen repeated
bytes are real IP header, so the router dropped every one in silence. ARP
working was the thing that made the transmit path look innocent.

### Two transmit bugs found on the way

* **`bulk_out` did not retry a NAK.** A NAK on an OUT means "busy, ask
  again", exactly as on an IN, and the chip is deliberately set to report
  NAKs rather than retry them itself. Every single send failed before this:
  25 errors out, 0 packets out. The retry has to rewind `SI`, because
  `LODSB` has already walked it through the data.
* **The chunk length was read back out of a clobbered `AX`.** `sub cx, ax`
  after `bulk_out` was subtracting a leftover CH375 opcode from the bytes
  remaining.

### And one the statistics block exposed

`pkttool` reported `Errors out: 65557` from a driver that had sent nothing.
`get_statistics` hands the caller a pointer to a struct of **seven**
consecutive 32-bit counters in a fixed order; mine had five, in a different
order, so `pkttool` was reading two variables past the end of it. Fixed,
including the `bytes_in` / `bytes_out` that were simply missing.

### set_rcv_mode reaches the hardware

Modes 1 to 6 are mapped onto the adapter's filter bits and written to
`RX_CTL`. It used to store the value and stop there, so `get_rcv_mode`
agreed with itself while the adapter carried on doing whatever it had been
doing — and an application asking for promiscuous mode and silently not
getting it is a particularly unhelpful failure, because everything looks
fine and simply no interesting frames arrive.

Doing it needed a control transfer that survives going resident: the full
one lives in the transient half and is handed back to DOS. There is now a
minimal resident version — one register, one 16-bit value — reached only
from the INT 65h handler and never from the ISR, because it takes
milliseconds and that is not a cost worth paying inside a timer interrupt.

## What has been proved over it

| | |
|---|---|
| ARP | resolves both directions |
| ICMP, local | 3/3 to the gateway, 3/3 to a LAN host |
| ICMP, routed | 3/3 to `8.8.8.8` at ttl=118, 2/2 to `1.1.1.1` |
| DNS (UDP/53) | `example.com` resolved to `172.66.147.243` |
| TCP | a telnet session to a BBS in Rimini, full 80x24 screen |
| **HTTP** | **`example.com` 200 OK / 559 bytes, `info.cern.ch` 646 bytes** |

```
--- example.com over the CH375 USB adapter ---
mTCP HTGet by M Brutman
Server return code: 200 OK
```

559 bytes, byte for byte what a modern machine gets from the same URL, and
`info.cern.ch` fetched afterwards at 646 bytes with the server's 2014
Last-Modified date preserved on the file. An IBM PS/2 Model 30 from 1987
pulling web pages over a USB network adapter it predates by nine years.

### Two drivers at once

The machine's own network is an NE2000 packet driver at INT 60h and the
bridge this is developed over runs on it, so the two coexisting is not a
nicety. Checked in six stages: vectors before, load ours, vectors with both
present, ping over 60h **while ours is loaded**, ping over 65h, unload,
vectors again, ping over 60h again.

```
===== 5. unload ours =====
USBPKT unloaded.
  60h  15A2:03CE   PACKET DRIVER
1 packet driver(s) between 60h and 80h.
===== 6. 60h ping after unload =====
Packets sent: 2, Replies received: 2, Replies lost: 0
Average time for a reply: 4.25 ms
```

That 4.25 ms against roughly 51 ms over ours is the open question of this
project, and the section below is what is actually known about it.

## Latency: two theories tested, both wrong

The round trip to the gateway is a near-constant **51 ms** over this driver
and **4.25 ms** over the machine's interrupt-driven NE2000 to the same
address one hop away. It is a constant rather than a distribution, which is
the most useful thing about it.

**Theory one: our poll interval.** The ISR collects on the timer, so a
reply could be waiting for the next tick. `/R=n` divides the PIT the way
`USBMOUSE` and `USBCOMBO` do -- the timer runs fast and the handler that
was in the vector before us is called only every nth tick, so the BIOS
clock is undisturbed. Verified working rather than assumed:

```
DOS says 5.0 seconds elapsed
  timer ticks=855          (~171/sec; it reads 106 at /R=1)
  timer divisor (/R)=8
```

Eight times the poll rate, DOS clock still correct -- and the latency did
not move. `/R=8` gives ~51 ms and so does `/R=1`. **Not the cause.**

**Theory two: the adapter's bulk-in aggregation timer.** The chip holds
received data until its own timer expires, whatever we do. `USBLINK /K=hex`
sets it; `0x0080` and `0x0004` both give ~51 ms. **Not the cause.**

So something imposes a fixed ~51 ms in the receive path that is neither of
those. Untested: mTCP's own timing granularity over a polled driver, and
whatever the CH375 does between a frame reaching the chip and the bulk
endpoint having it.

The `/R` work stays. It is correct, it restores the PIT on unload -- leaving
the timer fast with our handler gone would make the DOS clock run eight
times quick with nothing on the machine able to explain why -- and an
eightfold increase in how often the wire is looked at matters for
throughput even if it did nothing here. `/R=1` leaves the timer alone.

### A process note worth more than either theory

Theory one was "disproven" once against a **stale binary**: built, never
re-staged, so the test ran the old driver and produced a confident wrong
answer. What caught it was measuring the *mechanism* -- `timer ticks` --
instead of the *outcome*. Source and behaviour disagreeing is visible; two
identical ping results are not.

`dosctl exec` runs what is already on the box and only `run` re-stages.
That has now cost three wrong conclusions in one session, so: after every
build, `run` the binary once before any test that uses `exec`.

## Which adapters can this drive?

`NETID` says, for whatever is plugged in:

```
device   : 0B95:1790  ASIX
chip     : ASIX AX88179
family   : ASIX AX88179/178A
SUPPORTED.
```

Recognition works two ways, and they are not equally good. **By class** is
the right way: CDC-ECM and CDC-NCM are standards, and an adapter declaring
interface class 02 can be driven without knowing who made it. **By
VID/PID** is the way that actually gets you online, because most cheap
adapters are vendor-specific -- the AX88179 here reports class `FF/FF/00`,
which means "ask the manufacturer".

`netchip.pas` holds both: 24 entries across ASIX, Realtek,
SMSC/Microchip, Davicom, Moschip and common rebadges, plus class-based
detection for anything not tabulated. "Recognised" and "supported" are
deliberately separate -- an adapter it knows but cannot drive says so in
one line, which is far more use than a bring-up that fails halfway and
leaves you wondering about the cable.

**Three are implemented: CDC-ECM, SR9700/DM9601 and the AX88179/178A.**
The most valuable was CDC-ECM, because it is a standard -- one driver, every
adapter that speaks it, instead of another entry in a table of vendor quirks --
and it went in first for that reason.

The SR9700 went in second and taught the more useful lesson: **the layouts that
look alike are not alike.** Its receive framing reads like the ASIX one from a
distance and behaves like the ECM one -- a single frame per USB transfer, ended
by a short packet, with a three-byte header in front. Adding a chipset here is
mostly a question of which of those two shapes it has, and the answer is worth
measuring rather than inferring.

## What is not done

### The REP INSB fast path — done

It is written, measured and on by default where the CPU has it. See **The
byte loops** above: 2.6% on throughput, which was the prediction, and 33%
off the length of the interrupt, which was the point. `/8` puts the portable
loops back.



- **The ARP round trip.** When it loads, point a *copy* of `MTCP.CFG` at the new
  vector. Never the one the working network uses. The goal is a Crynwr driver at INT 60h, because
  that is what `mTCP`, `WATTCP` and NCSA Telnet all speak — get it right
  and the whole DOS networking ecosystem works, with no TCP stack written
  here.

## Building

    build.cmd            build both programs
    build.cmd probe      ...then bring the adapter up on the DOS machine
    build.cmd recv       ...then watch frames arrive
    build.cmd raw        ...then dump bursts without interpreting them
    build.cmd send       ...then ARP the router and wait to be answered

Needs Free Pascal cross-compiling to `i8086-msdos`. `ch375.pas` and
`chtool.pas` come from `..\CH375USBTOOLS\src` via `-Fu`.

Public domain, under [the Unlicense](https://unlicense.org).

Written by **StevenC** and **Claude** (Anthropic): StevenC guiding, deciding and testing on real hardware, Claude doing most of the analysis, code and measurement.
