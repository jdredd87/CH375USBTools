# USB Ethernet adapters and CH375Net

Which chipsets this driver handles, which it could, and which it cannot.

## Short answer: try it anyway

**`USBPKT` does not look at the USB ID at all.** It enumerates whatever is
plugged in and runs the bring-up. `NETID`'s verdict is advisory — it reads a
table, and the table cannot know about every rebadge.

That matters more than it sounds, because **an adapter can be an ASIX part
wearing somebody else's USB ID**. Dock stations and own-brand dongles very
often are: the silicon is an AX88179, the ID says Lenovo or Dell or a house
brand, and no table has heard of it. On one of those, `USBPKT` simply works
while `NETID` calls it unknown.

So if `NETID` does not recognise your adapter, **run `USBPKT` regardless.**
A wrong guess costs nothing: the bring-up fails at a numbered step, says so,
and nothing is left in a bad state. `USBLINK /F` does the same with the full
step-by-step narration, which is what you want if it fails and you care why.

What this cannot do is make a genuinely different chip work. An RTL8153
under any ID will stop at step 1 or 2, because the register writes go
nowhere. That is a missing driver, not a detection problem.

---

**Run `NETID` before believing any of it.** It reads the USB descriptors and
prints the vendor and product ID, which is the only thing that actually
identifies what you have. A box that says "AX88179" and a chip that is an
RTL8153 are a common combination, and so are two adapters with the same
outward appearance and different silicon inside.

```
C:\CH375> NETID
device   : 0B95:1790  ASIX
chip     : ASIX AX88179
family   : ASIX AX88179/178A
SUPPORTED.
```

---

## Status key

| | |
|---|---|
| **Works** | driven, on hardware, by this project |
| **Works (class)** | driven by `ecm.pas` and `USBPKT`'s class path, which read the device's own descriptors rather than knowing the chip. Any adapter offering CDC-ECM should land here |
| **Should work** | same register map as something that works, not yet tried |
| **Needs a driver** | understood part, no bring-up written for it yet |
| **Unlikely** | needs more than the CH375 can give it |

---

## Works

| Chip | USB ID | Notes |
|---|---|---|
| ASIX AX88179A **over CDC-ECM** | `0B95:1790`, `iProduct` "AX88179A" | **Works fully.** `USBPKT` brings it up as a class device from `AUTOEXEC.BAT` and mTCP runs over it: verified 2026-09-10/11 with **130 MB** of downloads byte-exact (zero mismatches, 13 rounds of 10 MB) and, at the keyboard, **telnet, FTP, HTTP GETs and pings**. Discovered geometry: configuration 3, control interface 0, data interface 1 alt 1, bulk endpoints 2 IN / 3 OUT, MAC `A0:CE:C8:BC:0A:91` from the string descriptor -- `ECMLINK` and `USBPKT` agree independently. 22-23 KB/s. **Read the vendor-mode latch below before testing it.** Sold as a **USB-C** adapter, model `UTC-GE-AL-AX01`, used here through a USB-C-to-A adapter. |
| ASIX AX88179 | `0B95:1790` | The reference part. Verified on **two physically different adapters** from different manufacturers — MACs `40:AE:30:6D:00:34` and `00:50:B6:B6:1C:64`. Both boot, link, and move data. **They do NOT move 5 MB byte-exact reliably**, which this row used to claim: about one 5 MB download in nine comes back the right length with a corrupt region, and every error counter reads zero while it happens. See the README. The claim was true of the runs it was written from and was never a property of the adapter. |

## Before you plug a new one in

Run **`NETID`** first. The box an adapter came in is not evidence of what is
inside it, and re-badged parts are the norm rather than the exception.

Two of the IDs below need no new code at all -- `0B95:1790` and `0B95:178A`
share a register map and `ax179.pas` drives both, which is why it is not
called `ax88179.pas`.

**A new adapter is also a free experiment on the open corruption fault.**
Roughly one 5 MB download in nine comes back corrupt and the cause is
narrowed to the CH375 read path or its transmit/receive contention, with
everything above the driver excluded by measurement. So:

* **another AX88179 or 178A** tests whether the fault follows the ADAPTER.
  Two have already been tried and both corrupt, so a third that also does
  points firmly away from one flaky piece of hardware.
* **a different chipset** is worth more, because it keeps the CH375, the ISA
  card, the driver above the bring-up and the whole machine constant while
  changing the USB device. If it still corrupts, the CH375 read is
  implicated and the adapter is exonerated. If it does not, the reverse.

Either way, budget the volume: at 1 event per 44 MB a single clean 5 MB
download means almost nothing, and treating a small clean result as a
control is the mistake this project has made most often.

## Sends and receives, but no packet driver yet

| Chip | USB ID | Notes |
|---|---|---|
| **DM9601/SR9700-compatible clone** | `0FE6:9702`, `iProduct` "USB 2.0 10/100M Ethernet Adaptor", no manufacturer string, housing marked **"Gzcyc No:9700"** | **Identified and answering.** Register file reads correctly, MAC `00:E8:00:4C:26:D5`, NSR reports link up. Two interfaces: **interface 0 is MASS STORAGE** (`08/06/50`, the driver-CD flash) and interface 1 is the network one — bulk `81` IN / `02` OUT, interrupt `83` IN. **It only implements SINGLE-BYTE register reads** — see below. `sr9700.pas` + `SRLINK` drive it and **both directions are verified on real traffic**. **There is no packet driver**, so mTCP cannot use it and it is *not* on the supported list. |

### The quirk: multi-byte register reads are broken

`0FE6:9700` is the CoreChip SR9700 in Linux's `sr9700.c`, and the housing
marking "9700" agrees. The SR9700 uses the same vendor requests as the DM9601,
so the Linux framing should have worked first time. It appeared not to:

```
type C0 req 00 val 0000 idx 0000 -> success, 8 bytes
type C0 req 00 val 0000 idx 0010 -> success, 8 bytes
   both:  00 E8 00 4C 26 D5 07 05
```

Identical whatever register was asked for, which reads as "this device does not
implement the protocol". It does. **A multi-byte read returns the PAR block
from `0x10` regardless of `wIndex`** — those eight bytes are the MAC address
followed by two bytes of something else. Single-byte reads decode `wIndex`
correctly:

```
00h=00  01h=C1  00h=00      -> index honoured
```

So the register file is perfectly readable, one transfer per register. **A
driver for this part must read registers singly.** One that fetches the six
MAC bytes in a single transfer gets the fixed block and happens to come up with
the right answer *for the MAC specifically* — and the wrong answer for
everything else, which is a far nastier way to be wrong.

### What has actually been measured

| | |
|---|---|
| Identification | `NETID` names it from the table; `DMPROBE` confirms it from the silicon |
| Register read/write | **works**, one byte at a time |
| MAC | `00:E8:00:4C:26:D5`, read from PAR |
| Link | NSR reports up; PHY brought out of reset by the driver |
| **Receive** | **works** — frames decode as mDNS, SSDP, IGMP, LLDP and ARP with real addresses |
| **Transmit** | **works** — an ARP for the gateway was **answered**: `REPLY from 192.168.50.1 is at 04:D4:C4:D2:2B:00` |
| Sustained receive | 60 s, 69 frames, 30,677 bytes |
| Transmit rate | **299 of 300 frames, 100 frames/s, 6,046 bytes/s** |
| Packet driver | **none** — `USBPKT` does not know this chipset |

The ARP reply is the part that proves transmit properly. A send that returns
success only means the chip took the bytes; a reply means the frame left the
host, crossed the wire, was understood by a real device, and its answer came
back **addressed to our own MAC** — which exercises the receive filter too.

**100 frames/second** is the CH375's packet-rate ceiling showing up again, the
same number that sets the video project's frame rate, killed the audio one and
caps CH375Serial at 38400 baud. A 60-byte frame plus the two-byte header is one
USB packet, so frames/second and packets/second are the same figure here.

**The receive overflow counter is not zero over a long run.** It read `00` on
short tests and `B3` after 60 seconds. That is the chip saying it dropped
frames it could not hand over fast enough, and it is expected rather than
alarming: a slow host on a busy segment cannot take every broadcast, and
Ethernet has always been allowed to drop. It does mean this adapter will not
be a quiet listener on a loaded network.

One send in 300 was refused. Worth knowing before anybody reads 100 frames/s as
a guarantee.

### Receive needs reassembly, and the failure is disguised

A frame larger than one 64-byte USB packet spans several, and **the
three-byte header is only on the first**. A reader that treats every packet
as a fresh frame decodes the first correctly and then reads the *middle* of
the frame as an Ethernet header — which produces a listing full of plausible
frames interleaved with ones whose "MAC addresses" are ASCII text:

```
61 bytes  70:73:32:2E:63:6F -> 1F:92:01:69:62:6D  type 6D00
```

`70:73:32:2E:63:6F` is not an address, it is `ps2.co` out of the middle of
somebody's SSDP announcement. Once `SrRecv` consumes the whole frame — CRC
included — before looking for the next header, the listing is clean.

### A Word loop bound that can be zero is a 64 KB memory smear

This took the machine down **twice, in two different places in the same
function**, and it is worth naming as a shape rather than as two bugs:

```pascal
for I := 0 to Len - 1 do ...     { Len is a Word. Len = 0 counts to 65535. }
```

Both instances were reachable from perfectly ordinary traffic — the chip
sends a header whose length is exactly 4 (header plus CRC, no payload) as a
routine way of saying "nothing here", and a packet carrying only the header
gives a zero copy count. The symptom is a hang immediately after the *first*
frame arrives, which reads as a receive fault and is really an arithmetic
one. Pascal gives no warning whatsoever. Every such loop in `sr9700.pas` is
now guarded.

### What is left before it can be called supported

`USBPKT` is the packet driver, and it does not know this chipset. That is the
whole of the remaining gap, and it is not a small one: `usbpkt.asm` and
`usbpktini.inc` are about 5,500 lines of assembly whose chipset handling is a
**binary** `ecm_mode` flag — AX88179 layout or CDC-ECM layout — rather than a
general dispatch. Adding a third means:

* a bring-up in assembly (straightforward: a handful of single-byte register
  writes, which is *less* work than the ASIX path),
* a transmit header of two little-endian length bytes, where the existing code
  has `tx_hdrlen` of 8 for ASIX and 0 for ECM,
* and the hard part — a **receive path that parses the three-byte header and
  reassembles across USB packets**, which neither existing mode needs. ECM
  treats a whole burst as one frame; ASIX parses its own layout.

It is a real feature rather than a patch, and half-doing it would produce a
driver that corrupts frames — which is worse than not having one, because the
corruption fault this project is already chasing would get a second suspect.

Until that exists, this adapter is **driven but not supported**, and those are
different words on purpose.

### Three things this adapter taught the project

**A success status is not evidence the device understood the request.** The
CH375 reads into its own 64-byte buffer, and `DMPROBE`'s first version printed
this adapter's configuration-descriptor bytes as though they were a register
file. They looked plausible until the MAC came out as `03:08:00:00:00:00` —
which is an endpoint descriptor.

**The test that works is A/B/A.** Read register 0, read register 10h, read
register 0 again. Only *the two reads of 0 agree and the middle one differs*
proves the device is decoding `wIndex`. Poisoning the caller's buffer does not
catch a stale read, because the chip copies its own stale buffer over the
poison — and a buffer will agree with itself all day. The first framing sweep
had the same disease as the thing it was testing: it stopped at the first
`INT_SUCCESS`, so on a device that answers the first framing spuriously it
never tried the others.

**The first bulk endpoint pair is not necessarily the network one.** This
device's mass-storage interface comes first and has its own bulk IN/OUT. A
driver that takes the first pair binds to the flash chip and then waits forever
for frames from something that has never heard of Ethernet, with nothing in the
failure pointing at the cause. Pick by exclusion.

## Tried, and it is NOT what its ID says

**ASIX AX88179A** -- `0B95:1790`, the *same USB ID as the AX88179*, and the
only thing in the descriptors that distinguishes them is the product string.

Marked **`UTC-GE-AL-AX01`** on the case: a USB-C gigabit adapter, used here
through a USB-C-to-A adapter. Worth recording because the marking is the
only warning you get before plugging it in -- the USB ID does not
distinguish it, and a listing saying "AX88179 chipset" would be telling the
truth as far as the ID goes.

The descriptors:

```
idVendor   0B95  ASIX
idProduct  1790
iProduct   "AX88179A"
bNumConfigurations 3

CONFIG 1  INTERFACE 0  FF/FF/00 vendor specific, 4 endpoints
            EP 81 IN interrupt   EP 82 IN bulk
            EP 03 OUT bulk       EP 05 OUT bulk
CONFIG 2  02/0D  CDC-NCM
CONFIG 3  02/06  CDC-ECM
```

So `NETID` reporting `0B95:1790` is **not** enough to conclude you have the
reference part. Read `iProduct`.

**How far it gets, which is most of the way and not all:** it enumerates,
falls back to full speed correctly, accepts `set configuration`, takes every
register write, reads its MAC (`A0:CE:C8:BC:0A:91`) and reports **link up**.
`USBPKT` loads it and goes resident.

**It carries frames both ways and mTCP still cannot use it.** Measured
2026-09-10 after a clean boot, over 83 seconds:

```
bursts collected=163      frames delivered=18      frames sent=7
bursts whose frames did not tile=0   frames past the frame region=0
```

`PKTTEST /T=192.168.50.46` ARPs that host and **gets the reply**, so a frame
reaches the wire and the answer comes back. `PING` over mTCP on the same
driver, seconds later, times out on all four packets. So the fault is
narrower than "it cannot transmit": something works at the ARP level and
does not at the IP level, and that has not been chased because the class
path below makes it moot.

**This entry has now been wrong twice, in opposite directions, and both
times from a measurement taken in a state nobody had checked.** It first
said the adapter "receives frames"; then, on 2026-09-10, that it "moves no
traffic in either direction" on the strength of 181 bursts and 0 frames
delivered. That reading was real but the device was not in a clean state --
ECMLINK had reconfigured it into the ECM configuration and USBPKT had then
re-enumerated it. After a reboot the same binary delivers frames. **Take
adapter measurements from a freshly powered device, and say which state the
device was in.**

The endpoints are **not** the problem either, which was the first guess:
the driver issues tokens to endpoint 2 IN and 3 OUT, and this part's vendor
configuration is exactly `EP 82` IN and `EP 03` OUT. It has a second bulk
OUT at `EP 05` that the 179 does not, which is worth a look -- the 179A may
expect transmit on a different queue, or need a register the 179 does not.

**Do not read the `/V` bring-up trace after `USBPKT` has already loaded it.**
Every register access reports NAK in that case and the MAC read "fails",
which looks like a dead device and is an artifact of re-initialising one
that is already configured. Power cycle first, or believe the boot banner.

### The vendor bring-up LATCHES it, and only a re-plug clears that

The most important thing on this page, because it makes everything else
here intermittent if you do not know it.

A freshly powered AX88179A reports **three configurations**: vendor,
CDC-NCM, CDC-ECM. Once the vendor bring-up has run, the same adapter
reports **one**, and the two class configurations are not merely
unselectable -- they are absent from the descriptor it hands back.

Measured 2026-09-10, from `USBPKT /V`'s trace of the device descriptor
read, where the last byte is `bNumConfigurations`:

| | |
|---|---|
| fresh device | `n12 03` -- eighteen bytes, three configurations |
| after the vendor bring-up | `n12 01` -- one |

**Nothing in software clears it.** Confirmed one at a time:

* a USB bus reset does not -- `ECMLINK` does a full mode-7/mode-6 reset on
  every run and still read `01`;
* `SET_CONFIGURATION(0)` is weaker than a bus reset, so it cannot;
* **a warm reboot does not**, which is the one that catches people. The
  CH375 card feeds the adapter off the ISA bus and a warm boot never drops
  that rail, so the adapter is never re-powered. Verified: rebooted, and
  `AUTOEXEC.BAT`'s own `USBPKT` still came up on the vendor path.

What does clear it is **unplugging the adapter and plugging it back in**,
or a full power cycle of the machine.

Two consequences worth carrying:

* **Ask what a device can do before configuring it.** `USBPKT` probes for
  CDC-ECM between SET_ADDRESS and SET_CONFIGURATION for exactly this
  reason. An earlier build probed afterwards and worked intermittently --
  the worst possible symptom, since two runs of one binary on one adapter
  disagreed.
* **A session that has run the vendor path cannot test the class path.**
  Re-plug the adapter first, or every ECM result in that session is a null
  you cannot interpret.

### The opportunity in it -- taken, and it worked

This part offers **CDC-ECM as configuration 3 and CDC-NCM as configuration
2**. CDC-ECM is a *class*: one bring-up covering many adapters from many
vendors rather than one vendor bring-up each. So rather than chase the
179A's vendor quirks, `ecm.pas` was written to the spec and `ECMLINK` was
pointed at this adapter.

**It transmits.** Verified on hardware 2026-09-10, and reproduced on four
consecutive runs:

```
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
```

So the adapter is not broken and the silicon is not at fault -- what does
not work is this project's **vendor** bring-up for a part that shares the
179's USB ID and evidently not all of its behaviour. Through the class
driver it does the one thing it could never do before.

The vendor path is left as it is. Making it transmit would benefit exactly
one adapter; `ecm.pas` already covers this one and every other ECM device
nobody here has bought yet.

## Should work

| Chip | USB ID | Notes |
|---|---|---|
| ASIX AX88178A | `0B95:178A` | Same register map and the same bring-up as the 179 — `ax179.pas` covers both, which is why it is not called `ax88179.pas`. Nobody has plugged one in yet. |

If you have one, `NETID` will call it supported and `USBPKT` will try. Please
say whether it worked.

## Needs a driver

Understood parts where the work is a bring-up module, not new research. All
of them are USB 2.0 or a 2.0 fallback mode, which is what matters — see
below.

| Chip | USB ID | Notes |
|---|---|---|
| ASIX AX88772 / 772A/B/C | `0B95:7720`, `0B95:772A`, `0B95:772B` | The most common 100 Mbit USB adapter ever made. Different register map from the 179 but the same *shape* — vendor control requests, an MII PHY behind them. The obvious next one. |
| ASIX AX88772 (Linksys etc.) | `077B:2226`, `2001:1A02`, others | Same silicon, rebadged. |
| Realtek RTL8152 | `0BDA:8152` | 100 Mbit. Very common. Register access is vendor requests over control, like the ASIX parts. |
| Realtek RTL8153 | `0BDA:8153` | Gigabit sibling of the 8152, falls back to USB 2.0. |
| Microchip/SMSC LAN9500 | `0424:9500`, `0424:EC00` | 100 Mbit, used in older Raspberry Pi boards among others. |
| Davicom DM9601 | `0A46:9601` | 100 Mbit, cheap and old, seen in very inexpensive dongles. |
| CDC-NCM (class) | any | The harder of the two class protocols: frames are batched into NTBs with a header and an index, so it needs a parser where ECM needs none. Worth having only if something turns up that offers NCM and not ECM -- most devices offering one offer both. |

## Unlikely

| Chip | Why |
|---|---|
| Anything USB 3.0 **only** | The CH375 is a full-speed host: 12 Mbps, USB 1.1 signalling. A 3.0-only device with no 2.0 fallback cannot talk to it at all. In practice almost every "USB 3.0 gigabit" adapter does fall back — the AX88179 here is one, and it runs at full speed quite happily. |
| Anything needing isochronous transfers | The CH375 does control, bulk and interrupt. Ethernet adapters do not use isochronous, so this is theoretical. |

---

## What "add a chipset" actually involves

Renaming the tools away from `AX*` was the easy half. The honest position is
that the bring-up is still one chip's:

- `ax179.pas` is the AX88179/178A register map and bring-up. It keeps its
  chip name deliberately, because that is what it is.
- `usbpktini.inc` — the driver's own bring-up — has the same sequence in
  assembly.

So a new chipset needs a bring-up in **both**, plus a dispatch on the USB ID.
Everything underneath is already generic and would not need touching:

- `ch375.pas` / the CH375 layer in `usbpkt.asm` — enumeration, control
  transfers, bulk endpoints. Chip-agnostic.
- `pktapi.pas`, `pktscan.pas`, `pkttest.pas`, `pkttick.pas` — packet driver
  side, nothing USB-specific.
- The receive engine — burst collection, the frame/metadata layout parsing,
  the toggle handling. **This is the part that took four sessions to get
  right**, and the AX88179's burst format is not universal, so a new chip
  may need its own parser even though the machinery around it is shared.

The realistic order, easiest first:

1. **AX88772.** Same vendor, same idiom, best documented, most common.
2. **RTL8152/8153.** Different vendor, same idiom. Widely available.
3. **CDC-ECM.** A class driver, so one implementation covers many adapters —
   more upfront work, much better return.

---

## Reporting one

If you try an adapter this does not know, the useful thing is the `NETID`
output — the USB ID especially — plus what `USBPKT` said. If it got as far as
a step number, `USBLINK /V` prints the chip status at every register access,
which is usually enough to see where it stopped.

Adapters that **fail** are worth recording here too. "This ID is an RTL8153
and is not supported yet" saves the next person buying the same one.
