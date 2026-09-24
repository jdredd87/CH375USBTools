# Changelog

CH375Net -- StevenC and Claude -- https://github.com/jdredd87/CH375USBTools

Versions live in the `VER` constant of each program.

## Unreleased

**Rebuilt 2026-09-24 for the credit, and nothing else.** Every program's
banner now ends `-- StevenC & Claude`, and every source header says the
same. No code changed and no version was bumped, so this build shares its
version numbers with the one before it -- the CRC tells them apart.
Deployed to the V30 under `C:\CH375\` and CRC-checked there.

## USBPKT drives the SR9700, and mTCP runs over it

The third chipset, and the first one chosen by USB ID rather than by what
the device says about itself -- this part has no class descriptor, no
functional descriptor and no vendor string worth trusting. The housing says
"Gzcyc No:9700".

**It works.** `USBPKT` enumerates it cold, skips the driver-CD flash on
interface 0, brings the chip up, reads the MAC out of PAR one register at a
time and goes resident. mTCP then runs over it: gateway 3/3, `8.8.8.8` 3/3,
DNS resolving, HTTP GET complete.

A **175 MB** volume campaign -- 35 independent 5 MB downloads across both
transports -- came back byte-exact every time, zero mismatches. That matters
beyond this adapter: the open corruption fault runs at roughly one event per
44 MB on the AX88179, on this same CH375, ISA card and machine, so 175 MB
clean here changes which half of the system is suspect.

**Roughly 17-20 KB/s** against the AX88179's 22-23 KB/s. The range is
deliberate: six timed 5 MB downloads in one night came in at 263, 270, 284,
299 and 308 seconds, so run-to-run variance is about 15% and a single pair
of runs cannot support a claim about a code change. Two such claims were
made here before the replicates existed and both are withdrawn -- see
below.

### A counter that cost four lines and was the only thing that saw the bug

The receive layout is neither the ASIX one nor the ECM one. There is no
trailer, no packet count, no entry array and no computed stride -- so all
of the ASIX machinery that looked like the model to follow applies to
nothing here -- but the records ARE laid end to end, several to a transfer,
and they have to be walked.

That was the original plan and it was then talked out of, which is the part
worth recording. A 60-second listen and a 5 MB download both showed exactly
one frame per USB transfer, ended by a short packet, precisely as CDC-ECM
behaves; the reference Pascal driver reads one frame per call and had
decoded 69 consecutive frames correctly. On that evidence the loop was
dropped for a straight-line parse.

**The evidence was real and the conclusion was wrong.** This chip tiles
when the frames are SMALL, so a download of full-size frames is a test that
cannot see it. 5,054 frames went by without a single burst disagreeing with
its own header. At 26,000 the counter had caught 229: bursts of 268 bytes
carrying a 64-byte record, with two hundred bytes of good frames behind it
going on the floor.

Nothing else reported anything. TCP retransmitted what was dropped and
every file still arrived byte-exact, so **the 100 MB of verified downloads
that were supposed to qualify this driver would have passed either way**.
The counter -- four lines, written into the straight-line parse precisely
because that was the thing most likely to be wrong -- is the only reason it
was ever seen.

`rx_have_sr` now walks every record in the burst, and the residue counter
dropped from 229 in 26,000 bursts to effectively nothing.

### Four explanations for the remaining rejections, all measured at zero

About 6% of bursts were still being thrown away because the first header in
them was impossible -- a length under 4 or over 1518. Four mechanisms were
proposed, implemented and measured:

| | predicted | measured |
|---|---|---|
| `rx_drain` leaving the pipe part-read | `n_flush` > 0 | **0** |
| the chip's empty-record convention | `n_empty` > 0 | **0** |
| a record straddling a transfer boundary | `n_short` > 0 | **2 in 4,361** |
| a lost phase carried between bursts | rejections fall | **266 vs 270** |

Every one was plausible and every one was a guess wearing the clothes of an
argument. What finally said something useful was an **attribution latch** --
recording how the PREVIOUS burst ended, and printing it beside the failure.
Rejections usually follow rejections, so there is a cascade and most of the
cost is in it; but one sample shows a rejection after a burst that parsed
cleanly, so "a rare event knocks it out of phase for good" is not the whole
story either.

The cause is still unexplained. The effect is now recovered: a rejected
burst is **searched** for a record boundary on a sharp test -- a length in
range that lands exactly on the end of the burst -- which recovers about
30% of them and takes frames delivered above one per burst. Extending the
search to accept a boundary landing on another plausible header is the
cheap next step.

**Three counters were added or exposed along the way, and that is the real
content of this entry.** `n_flush` existed all along and `/S` never printed
it. One counter was doing duty for two different faults that mean opposite
things -- a synchronisation failure and a truncation -- and splitting them
took the diagnosis from 4.7% of something to 212-of-213 of one specific
thing in a single run. Neither the driver's own error counters nor any
download could see any of this: **every one of the 29 verified downloads
came back byte-exact throughout**, including the ones taken while the
driver was dropping 6% of its bursts.

### `ecm_mode` is now `link_mode`, with three named values

The flag was a byte tested as `<> 0` and meaning "ECM", which works exactly
until somebody adds a third mode -- at which point every one of those tests
is quietly wrong in a different way. It is now `LM_AX` / `LM_ECM` / `LM_SR`
and every test names the mode it wants. `ecm_undo` became `link_defaults`
for the same reason: a shared routine with one path's name on it is how the
next person ends up writing a second copy.

### Two things the hardware said and reasoning did not

**The chip reset was left out on a theory, and the theory was wrong.**
`NCR_RST` resets the network chip, and on a part whose USB front end shares
that reset the device drops off the bus mid-bring-up -- which is the shape
of two hangs the Pascal driver cost. Plausible, and false here: the Pascal
driver resets by default and comes up every time. Put back.

**`NSR` says the link is down while the link plainly works.** It reads `81`
after `USBPKT`'s bring-up and `C1` after `SRLINK`'s, on the same adapter
minutes apart -- the difference is bit 6, `LINKST`, with the speed bit and
everything else agreeing. Nothing depends on it, and the driver goes on to
carry mTCP, so it is a fault in the bit rather than in the path. It now
prints the **raw byte** beside the verdict, because a driver that says only
DOWN sends the next person to check the cable, the switch and the socket
before anything else.

The obvious explanation was tested and is not it. The PHY reset used
`delay_ms`, a calibrated spin loop, where the ASIX bring-up a few hundred
lines below carries a comment about that exact trap -- it failed
intermittently at a numbered step until it was switched to `delay_ticks`,
which waits on the BIOS counter and is a guaranteed minimum. Switching the
SR9700's PHY delays the same way changed nothing: still `81`. The change is
kept because a guaranteed minimum is right regardless, and it is recorded
here as a fix that measured as nothing rather than as the answer.

### A persuasive argument about the receive filter, measured and wrong

The default receive filter is now the narrowest that works -- the address
in PAR plus broadcast -- and the reason it changed is worth recording,
because the reason it changed is not the reason it was changed *for*.

The argument was: unlike the AX88179, this chip cannot aggregate. One frame
per USB transfer means a 1442-byte frame is twenty-three 64-byte reads and
about 16 ms of an 8086-class machine, **paid whether anything wants the
frame or not**. A listing of this segment is roughly 60% multicast -- mDNS,
SSDP, IGMP, LLDP -- and the chip's own receive overflow counter read `B3`
after sixty seconds of it. Every one of those facts is true, and the
conclusion that the filter must therefore be the throughput setting on this
part does not follow from them.

`/M` was added specifically so the claim could be tested instead of
asserted: it turns all-multicast back on, so the same download can be timed
both ways on the same adapter on the same segment. **307.9 s narrow,
312.3 s wide. 1.4%, which is nothing.** Multicast is a large share of an
idle segment and a small share of the frames arriving while a download is
actually running.

So the filter stays narrow for the ordinary reason -- a packet driver
delivers what its clients asked for, and an application that wants
multicast says so through `set_multicast_list` -- and the throughput claim
is gone. It had already been written into three files before it was
measured, which is the whole argument for measuring first.

### `/T` is why this cost one evening and not three

`USBPKT /T` runs the entire bring-up and then quits **without going
resident**. Every iteration of the geometry, the register writes, the MAC
and the link register went through it, so the part that can take the machine
down was only exercised once it had nothing left to get wrong. The bring-up
worked on the first hardware run.

`/D` is the new switch that refuses this path, mirroring `/X` for ECM. The
only honest way to show that a chipset path is what makes a difference is to
be able to turn it off on the same adapter and watch what stops.

## Used in anger: telnet, FTP, HTTP and ping over CDC-ECM

Driven at the keyboard rather than by a harness, and that is the point of
recording it separately. Everything above was verified by automated
one-shot bulk downloads; this was a person sitting at the machine using the
adapter as a network card.

**telnet, FTP, HTTP GETs and pings all worked.**

Three of those exercise things no test here had touched:

* **telnet** is a long-lived interactive connection of tiny packets, where
  every round trip is felt. A bulk download hides latency and hides a
  driver that delivers frames late; an interactive session does not.
* **FTP opens TWO connections** -- a control channel plus a data channel
  per transfer, with a listening socket for the latter. That is the first
  time this driver has carried more than one simultaneous TCP flow, and it
  is more pressure on the receive upcall than any download produced.
* **A human decides when something feels wrong.** No counter here reports
  "sluggish", and the driver's own error counters cannot: they all read
  zero through both the good runs and the broken ones earlier in the day.

This is the evidence the whole exercise was for. The adapter that
enumerated and could not transmit is now a network card somebody can just
use.

## USBPKT speaks CDC-ECM, and the adapter latches itself out of it

`ecm.pas` proved the protocol; this puts it in the packet driver, so mTCP
can run over a class adapter rather than only a known chip.

**The two data paths turned out to share almost everything.** At the USB
level they are the same transfers -- 64-byte bulk reads accumulated until a
short packet ends them, 64-byte writes with a zero-length packet when the
total lands on a multiple of 64 -- and `rx_go` was already exactly that. All
that differs is what the bytes mean, so the ECM receive path is the vendor
path with the parser removed: `rx_have` hands the accumulated bytes up as
one frame instead of calling `rx_deliver`, and `psend` omits the 8-byte
header. The entire AX88179 burst walk, entry array, tiling arithmetic and
every counter that polices them have no counterpart and stay at zero, which
is correct rather than suspicious. `/S` reports which protocol is running so
those zeros can be read properly.

Endpoint numbers stopped being assemble-time immediates. They were
`(EP_BULK_IN << 4) | PID_IN`, correct for one chip family; an ECM adapter
names its own endpoints and is entitled to any of them. This one happens to
use the same 2 and 3, and relying on that would have been a coincidence
dressed up as a design.

`/X` forces the vendor path, which is the only way to compare the two on a
device that offers both.

### The adapter latches into vendor mode, and only a re-plug clears it

This is the finding worth keeping. A freshly powered AX88179A reports
**three** configurations; once its vendor bring-up has run it reports
**one**, with the CDC-NCM and CDC-ECM configurations simply absent from the
descriptor. From `/V`'s trace of the device descriptor read: `n12 03`
fresh, `n12 01` afterwards.

Nothing in software clears it -- not a USB bus reset (ECMLINK does one on
every run and still read `01`), and **not a warm reboot**, because the
CH375 card feeds the adapter off the ISA bus and a warm boot never drops
that rail. Unplugging the adapter does.

So `USBPKT` now asks the ECM question between SET_ADDRESS and
SET_CONFIGURATION, before anything has been selected. The first build asked
afterwards and worked *intermittently*, which is the worst way to be wrong:
two runs of the same binary on the same adapter disagreed, and the
difference was whether the previous run had left the device in the class
configuration or the vendor one.

### Three bugs, each found by an instrument rather than by reading

**The chip was told to report NAKs during control transfers.** Carried over
from `ecm.pas`, where it is right, and it is wrong here: on a data endpoint
a NAK means "busy, ask again" and must be reported, but in a control
transfer the data stage has to be retried INSIDE the transfer. Restarting
from the SETUP asks the question again rather than waiting for the answer.
Trace: twelve whole transfers, 10 ms apart, every one `S14 I2A`, on a device
whose descriptors were there throughout. `read_mac` has said this in a
comment for months.

**Then the opposite, one layer up.** Forcing the chip back to 00 on the way
out of the probe clobbered the `8F` that the rest of `usb_enum` depends on,
and the very next step -- the configuration descriptor read -- began
reporting NAKs instead of waiting them out. The bring-up failed at step 25
with status 2A on an adapter that had worked a minute earlier. The probe now
restores `8F` and lets `usb_enum`'s own tail set 00 exactly once, as it
always did.

**`ctrl_in` ends a data stage on a packet shorter than EIGHT.** That is
right for a device whose endpoint 0 carries 8 bytes and wrong for this one,
which carries 64: a 26-byte string descriptor arrives in one 26-byte packet
-- short for the endpoint, not short by that test -- so `ctrl_in` asked for
more and the device answered status 2B. Trace `S14 I14 n1A I2B`, then
bring-up step 62. The MAC read now fetches the two-byte header and then
exactly `bLength` bytes, which is the correct idiom anyway and sidesteps it.
`ctrl_in` itself is left alone deliberately -- the AX88179 path shares it,
that adapter is not on the bench, and a latent bug nobody is hitting is a
poor reason to change untestable code. The one-line fix is recorded in
NEXT.md.

### Verified on hardware: mTCP runs over CDC-ECM

After a power cycle -- which is what it takes, see the latch above --
`AUTOEXEC.BAT`'s own `USBPKT` came up on the class path unattended, and
everything above it worked:

```
  protocol=CDC-ECM (class, from the descriptors)
  link=UP  notifications=4
  tokens in=29 out=31
```

`29` is `(2 << 4) | PID_IN` and `31` is `(3 << 4) | PID_OUT`, both built
from endpoint numbers read out of the descriptors.

| | |
|---|---|
| `PKTTEST /T=192.168.50.46` | ARP answered -- a frame reached the wire and the reply came back |
| `PING 192.168.50.46` | **4 of 4 replies**, average 51.4 ms |
| `HTGET .../download/1mb` | **1,048,576 bytes, CRC-32 `04D0E435`** -- exactly the expected value |
| `HTGET .../download/5mb` | **5,242,880 bytes in 214.3 s, 0 mismatches** -- `RAMPCHK`: "exactly the ramp" |
| `HTGET .../download/10mb` | **10,485,760 bytes in 450.3 s, 0 mismatches** |

The last three rows are what matter: full TCP downloads, byte-perfect, over
a driver that gets its entire configuration from the device.

**23-24 KB/s**, against 11.4 KB/s recorded for the vendor path. Do not read
that as "the class path is twice as fast" -- the two numbers come from
different adapters on different days, and this one has had no tuning at all.
It is worth knowing only because it rules out the obvious worry, that
carrying one frame per USB transfer instead of a batched burst would be
ruinous. It is not.

Also worth knowing: the 5 MB and 10 MB runs came out at 24.5 and 23.3 KB/s,
so the rate does not decay with transfer length -- which is the shape a
leak, a growing buffer or a degrading toggle would have.

### 130 MB clean, and this time the number means something

The 16 MB above was a 70% outcome and proved nothing, so the sweep it asked
for was run: **thirteen consecutive 10 MB downloads, every one verified byte
by byte by `RAMPCHK`.**

```
round  1/13  CLEAN  445.1s  23.0 KB/s      round  8/13  CLEAN  476.6s  21.5 KB/s
round  2/13  CLEAN  441.9s  23.2 KB/s      round  9/13  CLEAN  469.5s  21.8 KB/s
round  3/13  CLEAN  446.2s  22.9 KB/s      round 10/13  CLEAN  470.8s  21.8 KB/s
round  4/13  CLEAN  447.6s  22.9 KB/s      round 11/13  CLEAN  464.7s  22.0 KB/s
round  5/13  CLEAN  449.6s  22.8 KB/s      round 12/13  CLEAN  472.6s  21.7 KB/s
round  6/13  CLEAN  446.5s  22.9 KB/s      round 13/13  CLEAN  452.7s  22.6 KB/s
round  7/13  CLEAN  461.3s  22.2 KB/s
```

**130 MB, zero mismatches, zero bad rounds**, in 109 minutes. And every
error counter in the driver still reads zero afterwards, across **52,739
bursts, 50,263 frames delivered and 35,684 sent**:

```
bursts that made no sense=0      reads with an impossible length=0
bursts too big for the buffer=0  bursts whose frames did not tile=0
frames past the frame region=0   reads rescued by flipping the toggle=0
frames nobody wanted=0
```

The arithmetic, which is the whole reason for choosing 130:

| clean | P if the fault rate matched the vendor path |
|---|---|
| 16 MB | 0.70 -- says nothing |
| **130 MB** | **0.052** |
| 146 MB, counting the earlier runs | 0.036 |

So this is evidence at roughly the **95% level, and it is not proof.** It
says the class path does not corrupt data at anything like the vendor path's
1-event-per-44-MB rate. It does not say the rate is zero.

**Throughput dipped and recovered**: 23.0 KB/s early, 21.5 at round 8, 22.6
at round 13. About 7%, non-monotonic, so it is the LAN or the server rather
than anything accumulating in the driver -- a leak, a growing buffer or a
degrading toggle would not come back up.

### What this does NOT establish, because the adapter is different

The obvious next thought is that the class path shares `bulk_in`, `ch_read`,
the `REP INSB` fast path, `rx_go`'s accumulate loop and the `chip_busy`
TX/RX interlock with the vendor path -- so 130 MB clean through all of that
ought to exclude the shared CH375 read path as the home of the open
corruption fault, and point at the burst parsing instead.

**It does not, and the reason is a confound worth naming.** The corruption
was measured on the **AX88179** (MAC `00:50:B6:B6:1C:64`). This sweep ran on
the **AX88179A** (`A0:CE:C8:BC:0A:91`) -- a different physical adapter, on a
different cable, through a USB-C-to-A adapter. Two variables moved at once,
so a clean result here cannot be attributed to the protocol rather than to
the hardware.

Doing it properly means running the class path on an adapter whose vendor
path has shown the fault, which needs an ECM-capable adapter that also
corrupts -- or the 179 back in the machine long enough to re-measure. Until
then this is a promising lead and not an exclusion. That distinction is
exactly what four dead hypotheses in this file were each killed by.

### The interrupt got long, and that was the one thing being tuned away

`USBPKT /S` after the 10 MB run:

```
longest poll=65354 counts, 54.7 ms
```

At `/R=1` a tick is 55 ms, so a single poll consumed essentially a whole
one. That is the opposite direction from the work that shortened this
interrupt by a third, and it is the cost the class path pays: an ECM frame
is one USB transfer per frame, so a 1514-byte frame is 24 separate 64-byte
transactions, and a device that pauses part way through is waited out --
`RX_NAKWAIT` is 200 mid-burst NAKs, and a bulk transfer only ends on a
short packet.

**Treat the number itself with suspicion.** 65354 is close enough to the
16-bit counter's 65536 that it may be saturated rather than measured, in
which case the true figure is that value *or more*. Either way it is long,
and either way the fix is the same shape: bound the mid-frame wait for ECM
the way `ecm.pas` bounds it, rather than inheriting a budget sized for a
burst protocol.

Nothing observed has actually broken because of it -- 10 MB came back
byte-exact and the box stayed responsive throughout -- but the existing
notes record `EDIT` being wedged by a long poll at `/R=8`, so anyone raising
the timer rate on the class path should measure this first.

**The link reading is what made the rest diagnosable**, and it was added
because an earlier attempt read `bursts collected=0` with no way to tell a
broken receive path from a cable that was not connected. `USBPKT` now polls
the ECM interrupt endpoint every sixteenth tick and `/S` reports `link=`.
It says `not stated` rather than `DOWN` when the device has not spoken --
notifications are sent on CHANGE, and an unknown is not a negative.

### One wart, recorded rather than fixed

**`USBPKT /U` after an ECM bring-up leaves the adapter unable to
re-enumerate.** Observed directly: unload, then `ECMLINK`, and the bus
reports `a device is attached but nothing answers`. A power cycle clears
it. The vendor path does not do this -- after it, `ECMLINK` still
enumerates (and then finds only one configuration, per the latch above).

Nothing is lost by it in normal use, because the driver loads once at boot
and stays. It matters when iterating, and it is why the test procedure in
NEXT.md starts with a power cycle rather than an unload.

## CDC-ECM: a class driver, and an adapter that could not transmit now does

`ecm.pas` and `ECMLINK`. CDC-ECM is a USB **class**, not a chip: the device
describes itself in its own descriptors and one bring-up covers adapters
from any vendor, including ones nobody here has bought.

It was written because an **AX88179A** turned up that reports the same USB
ID as the AX88179 (`0B95:1790`) and behaves differently: it enumerates on the
vendor path, takes every register write, reads its MAC, reports link up,
receives frames -- and **nothing it transmits is ever answered**. The same
part offers CDC-ECM as configuration 3. So rather than reverse-engineer what
the 179A wants that the 179 does not, the standard was implemented.

Verified on hardware 2026-09-10, reproduced on four consecutive runs:

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

**Nothing in it is hardcoded to that adapter.** The configuration number,
both interface numbers, the alt setting, all three endpoints and the MAC's
string index are read out of the descriptors. Hardcoding "configuration 3"
would have worked on this one device and made the whole exercise pointless.

Three things in ECM are easy to get wrong and all three bit:

* **The data interface's alt 0 has NO endpoints.** That is by design -- an
  idle ECM device reserves no bus bandwidth -- so a driver that selects the
  configuration and stops has a device that is perfectly healthy and
  completely silent. `SET_INTERFACE` to the alt setting that has endpoints
  is not optional.
* **The MAC is in a STRING descriptor**, as twelve UTF-16 hex characters.
  Not a register, not a descriptor field. The Ethernet Networking functional
  descriptor carries the string index and nothing else useful.
* **A frame ends when a short packet ends it**, so a frame whose length is an
  exact multiple of 64 needs an explicit zero-length packet after it or the
  device waits for a continuation that never comes.

### Two bugs found by running it, both worth keeping

**The chip was left retrying NAKs, and that broke transmit entirely.**
`ch375.pas`'s `BusUp` sets `CMD_SET_RETRY` to `8F` -- absorb NAKs in hardware
-- which is right while enumerating and exactly wrong on a data endpoint,
where a NAK means "busy, ask again". A chip retrying in hardware raises no
interrupt at all, so every transfer reports `no interrupt`. First hardware
run: frame 1 went out, then every later bulk OUT and all forty receive polls
failed. `ax179.pas` and `usbpoll.pas` already put it back to `00`;
`usbpkt.asm` says the same thing at length and retries in software instead.
`ecm.pas` was simply missing the line.

Its second-order effect is nastier: a chip walked away from on `8F` is still
grinding when the program exits, so it does not answer `CHECK_EXIST`, and
the **next** program prints a thoroughly convincing `No CH375 at 0260h` for a
card that is plainly fitted. Two runs were lost to that. The policy is now
restored from an `ExitProc`, because the paths that need it are the ones
that `Halt` early, and `ECMLINK` resets and re-asks rather than believing a
single failed `CHECK_EXIST`.

**The test accepted somebody else's ARP reply.** The first version required
only "an ARP reply arrived", and on the second run it duly reported
`REPLY from 192.168.50.249` to a request for `.46` -- and declared the
transmit path proven on the strength of it. A live segment carries other
people's ARP traffic; that reading proves the RECEIVE path, which on this
adapter was never in doubt. It now requires the sender protocol address to
be the host asked about **and** the target hardware address to be ours,
which is what makes it an answer rather than an overheard frame.

Also: the link is read from the interrupt endpoint, the whole queue is
drained, and the **last** notification is believed. An ECM device queues
`NETWORK_CONNECTION = 0` as it comes up and only reports `1` once the PHY has
negotiated seconds later, so reading one notification reports the link as
down for as long as the device has been alive. Reading one is worse than
reading none, because it is confidently stale -- the first run printed
`link: DOWN` and then transmitted a frame that was answered.

### What this is not

**It is not a packet driver.** `USBPKT.COM` still speaks only the ASIX vendor
path, so mTCP cannot yet run over an ECM adapter. `NEXT.md` has what turning
`ecm.pas` into a second `USBPKT` back-end involves; the short version is that
the receive half gets much simpler -- raw frames, no burst header, no entry
array, no tiling, so the whole AX88179 parser has no counterpart -- and the
work is in getting it into the timer interrupt in assembler.

## REP INSB and REP OUTSB: the interrupt is a third shorter

The job the entry below left "still unwritten" is written, and both halves
of what that entry predicted turned out to be right -- which is worth
stating plainly, because plenty of predictions in this file were not.

Three loops moved a byte at a time through port I/O and now collapse to one
instruction each when the CPU has it: `ch_read_fast` (pull a packet out of
the chip), `ch_read_ovl` (drain a burst that cannot be used) and
`bulk_out_loop` (transmit). `Has186` is probed at install time, the portable
loops are still there, and the fast ones are emitted as `db` bytes because
the assembler targets 8086 and is right to refuse them as source.

Measured with the SAME BINARY on the same 1 MB file from the same server,
which is the comparison the old 73s-to-71s figure could not make -- that one
was two different builds:

| | 1 MB | CRC-32 | longest poll |
|---|---|---|---|
| `REP INSB` / `REP OUTSB` | **63.6s** | `998E4325` | **22.0 ms** |
| `/8`, the 8086 loops | 65.3s | `998E4325` | 32.6 ms |

**Throughput moved 2.6%, and that was the prediction.** At `/R=1` this
driver is round-trip-bound, not read-bound. Anyone reaching for this change
to make the default faster should stop here.

**The interrupt got 33% shorter, and that was the point.** A poll that takes
32.6 ms out of a 55 ms tick is 59% of the machine while traffic flows, which
is the sort of number that wedges `EDIT` at `/R=8`.

Every error counter read zero on both runs, both files verified byte-exact
on the box against `zlib.crc32` on the Windows side.

**And then 5 MB came back corrupt -- and four runs proved it is USBPKT, and
that it predates all of this work.**

| 5 MB, same file, same server | time | result |
|---|---|---|
| written locally by `RAMPCHK /W`, no network | | exactly the ramp |
| over the NE2000 at INT 60h | 62.9s | exactly the ramp |
| over USBPKT, fast path | 312.0s | 162 bytes wrong |
| over USBPKT, `/8` portable loops | 309.6s | wrong, and differently |
| over the NE2000, 10 MB | 125.3s | exactly the ramp |
| over USBPKT, fast path, again | 305.6s | exactly the ramp |

**It is intermittent -- two USB runs in three -- so no single clean run
proves anything.** The disk and DOS file I/O are eliminated by a file that
never crossed a wire. The two corrupt USBPKT rows disagree with each other,
ruling out a deterministic bug in either byte loop, and the `/8` row is code
that shipped before any of this, so the `REP INSB` change did not cause it.

The NE2000 rows had to be earned. The first draft of this entry rested on
ONE clean NE2000 run and called it decisive; at a two-in-three failure rate
that is a coin toss reported as a result. At 15 MB of clean NE2000 exposure
-- three 5 MB-equivalents -- the same coincidence needs about one chance in
twenty-five, so "the fault is in USBPKT" is now well supported. Supported,
still not proven.

**And a correction to the signature analysis, which was mine.** The first
reading called the leading fragment "exactly 64 bytes earlier" and made much
of 64 being the CH375's bulk maximum packet size. The ramp repeats every 256
bytes, so a delta is a displacement MODULO 256 and nothing in the test
distinguishes -64 from -320. The coincidence was real; the inference was
not.

**A concrete candidate did come out of reading the code.** `rx_deliver` is
handed the burst length in `CX`, uses it to locate the trailer, then reuses
`CX` and never keeps it -- so every per-frame bounds check afterwards is
against `RXBUF_SZ`, the buffer, rather than against the bytes this burst
actually delivered. `rxbuf` is not cleared between bursts, so a trailer
claiming a frame past the received data hands up leftovers from an earlier
burst: real stream payload, duplicated, with the file in step everywhere
else. That is the observed signature, it explains why every counter reads
zero, and it fits the mod-256 caveat -- data from a previous burst is
displaced by roughly a burst, which reads as a small delta.

Not a diagnosis. What would settle it: verify the entry array's frames tile
the received burst exactly and count the ones that do not.

**The signature is specific.** Not shifted -- the file never lost step -- but
162 bytes at offset 3,802,924 overwritten with payload from elsewhere:

```
want 2C 2D 2E 2F | 30 31 32 33 34 35 36 37 ...
got  EC ED EE EF | 7C 7D 7E 7F 80 81 82 83 ...
```

Four bytes from **64 earlier** (delta +192 = -64), then 158 from **76
later**, then correct data resumes -- and 64 is the CH375's bulk maximum
packet size. One USB packet's worth of data landed at the wrong offset in
the burst buffer. That accuses burst assembly in `rx_go`/`rx_got`, not the
chip interface and not the wire.

It also means a mangled frame reached the file rather than being caught by a
TCP checksum, so the driver's correctness is load-bearing here rather than
backstopped by the layer above.

Three things it establishes about evidence regardless of the cause:

* **The 1 MB test was too small to be a test.** Passing it twice is exactly
  what a rare fault looks like at a fifth of the exposure.
* **Every error counter read zero on both corrupt runs**, so "all counters
  zero" says only that nothing *detected* a fault. It had been getting
  quoted throughout these notes as though it meant the receive path was
  sound.
* **`longest poll` was unchanged between clean and corrupt runs**, so it
  does not present as a poll that ran long either.

And one methodological correction that is mine: the first comparison changed
the size AND the server at once -- 1 MB from `dosd` on 8080, 5 MB from the
Delphi server on 80. The NE2000 control is what separated them properly.

### `RAMPCHK`, and why a checksum was never going to be enough

New tool. The test files are a repeating `00`..`FF` ramp, so the correct
byte at any offset is `offset mod 256`; `RAMPCHK` reports where a file
deviates, by how much, and above all whether the stream was **ALTERED** (in
step, short runs, varying deltas) or **SHIFTED** (one constant-delta run to
the end, the delta being the number of bytes lost). Those have completely
different causes and a CRC cannot tell them apart -- it only ever says "no".

Validated before being believed, against three crafted files: clean, three
bytes dropped at 20000, three bytes altered. It named all three correctly,
including `SHIFTED ... 3 byte(s) were DROPPED there`. An instrument that has
not been shown able to fail is not evidence.

`RAMPCHK /W <bytes>` writes a ramp instead of checking one, which is how the
disk got ruled out with no network in the path at all.

### A spinner, on stderr, because stdout is not on the screen

A 26-minute read over the bridge is indistinguishable from a wedged machine:
a job's stdout is redirected into `OUT.TXT`, so nothing reaches the console
until the job ends. COMMAND.COM 6.22 has **no stderr redirection** -- usually
a nuisance here, exactly right for this -- so handle 2 reaches the screen
whatever the batch does with handle 1. Captured output stays clean; the box
gets a heartbeat.

One character then a backspace, animating in place, scrolling nothing, the
same trick `UGET` uses. It ticks every 8 KB block, about twice a second. The
first version ticked every 256 KB, which here is one move every eighteen
seconds -- a heartbeat slower than the observer's patience is not a
heartbeat, and it would have failed at the one job it exists for.

### Measured in passing: the NE2000 gap is 5x, not 2x

Using the NE2000 as a control gave the comparison this file had been
estimating: the same 5 MB from the same server is **62.9s on the NE2000
against 312.0s** over USBPKT. These notes claimed "the last 2x is
structural". It is five.

### The 10 ms figure below was wrong, and wrong in the flattering direction

The entry after this one estimated "a full burst read is ~10 ms of a 55 ms
tick" and that `REP INSB` "would take that to ~3 ms". Neither number
survives contact with a measurement:

* The peak poll is **32.6 ms**, over three times the estimate.
* It came down to 22.0 ms, not to a third of anything.

The absolute saving, ~10.6 ms, is close to what a 10-to-3 estimate implies.
The SHARE is completely different, and the reason is that the poll is not
just the read loop: issuing the IN token, spinning in `ch_wait` for the
chip's interrupt, and the drain-and-unwedge path are all inside the same
measurement. The read loop is roughly a third of a peak poll rather than all
of it, so making it nearly free could never have taken the poll to 3 ms.

Estimating one component and quoting it as the whole is the same mistake
this file has recorded before under other names. The instrument below is the
answer to it.

### `longest poll` in `/S`, because a claim is not a measurement

`USBPKT /S` now reports the longest single poll it has seen, in PIT counts
and in milliseconds. PIT channel 0 counts down at 1.193 MHz and latching it
either side of `rx_poll` costs four port accesses, so the driver can measure
its own worst interrupt for essentially nothing.

Two things about it are deliberate:

* **It is only taken at `/R=1`.** With the counter at its power-on divisor
  of 65536 the subtraction is exact modulo 65536 -- the counter wraps where
  the arithmetic does -- for anything up to a full 54.9 ms period. Once `/R`
  has reloaded it with something smaller those two stop agreeing and a
  wrapped reading would be *wrong* rather than merely missing. Nothing is
  lost by skipping it: the poll does the same work per burst whatever the
  tick rate, so the figure at `/R=1` is the figure at `/R=8`. What `/R`
  changes is how often it is paid.
* **It prints a dash, not a zero, when nothing was timed.** `0.0 ms` would
  read as "measured, and free", which is the opposite of the truth.

### `/8` forces the portable loops

One switch, no rebuild, on the machine where a fault would actually show.
The risk being covered is specific and was the only real objection to this
change: `REP INSB` issues port reads far closer together than the loop it
replaces, and the CH375's settling delays are not decoration. If a transfer
ever CRCs wrong, `/8` is the first thing to try -- and if `/8` fixes it,
that is the answer rather than a hint.

### Costs

`rx_scratch` went from 64 bytes to 256. The fast drain is a single
`REP INSB` and it has to have somewhere to put the bytes that is not the
caller's buffer -- being too small for them is how that path is reached in
the first place -- and the length the chip reports is one byte, so 256
cannot be overrun. With the probe and the timer, the resident image went
from 6144 to 6448 bytes.

`/R`'s help text said "default 8" long after the default became 1. Fixed.

## The machine is a V30, so REP INSB was never off the table

A correction to the entry two below, and it costs something real.

When the payload read loop was inlined, the comment justifying the shape of
it said a `REP INSB` "cannot be had here -- INS is 80186 and up". `INS` is
indeed 186-class, and the assembler targets 8086 so it will not accept it as
source. But **the development machine is a NEC V30, which has the 186
instruction set**, and DOSBridge has had the convention for this all along:
probe `Has186` at run time in `starter/cpu.pas`, keep the portable loop,
emit the fast one as `db` bytes, never delete the slow one. `bench.pas`
demonstrates the pattern.

So the fast path was available, the comment talked the next reader out of
it, and it is still unwritten. Three loops would take it — the payload read,
the drain, and transmit, the last being the biggest per byte because the
read loop got inlined and the write loop never did.

**It would not make the default faster**, and the first version of this
entry said it would. At `/R=1` the driver is round-trip-bound, not
read-bound, and there is direct evidence: inlining the read loop made reads
3.6x faster and moved 1 MB from 73s to 71s. The real win is that a full
burst read is ~10 ms of a 55 ms tick — 19% of the machine while traffic
flows — and `REP INSB` would take that to ~3 ms. Given `/R=8` wedged `EDIT`
by stealing too much of the machine, a quieter driver is worth more than a
benchmark. Whether the CH375 keeps up with reads issued that close together
is measurable, not arguable: the CRC'd download harness settles it in one
run.

Comment corrected in `usbpkt.asm`, and the opportunity is now written into
the README under what is not done, rather than buried in a wrong aside.
`INSTALL.md` also stopped calling the machine an 8086; it is a Model 30 with
a V30 in it, and the binaries target plain 8086 so they load anywhere.


## /R defaults to 1 again: the fast timer breaks MS-DOS EDIT

Reverting a default I set two entries ago, and the reason is a good one.

`/R=8` runs the receive poll at 145 Hz. It is worth twice the throughput and
drops the round trip from ~55 ms to 6 ms, and on those numbers it was the
obvious default. **Then EDIT wedged the machine hard enough to need the power
switch.**

The mechanism is the interrupt chain, and `TICKCHK` had already said it in
so many words without my joining the dots. The driver hooks INT 08h and
reprograms the PIT, then chains onward 1 tick in 8, so the BIOS clock and
INT 1Ch stay correct — 145 Hz on 08h, 18 Hz on 1Ch, DOS keeps perfect time.
What that does not cover:

- a program hooking INT 08h **after** this driver sits in **front** of it and
  sees all 145 interrupts, so its own timing runs eight times fast;
- a program reprogramming the PIT for itself leaves the 1-in-8 chaining
  dividing the wrong thing, which starves the BIOS clock eightfold and looks
  precisely like a hang.

Neither is something a packet driver gets to do to the rest of the machine
uninvited. **The default now touches the PIT not at all.** `/R` remains, for
when you know what else is running: `/R=8` while shifting a large file is
sensible, `/R=8` in `AUTOEXEC.BAT` on a machine somebody uses is not.

The cost is real and is the right trade: ~55 ms round trip instead of 6 ms,
1 MB in 71 s instead of 36 s. A network driver that breaks the text editor
is not a working network driver.

**Confirmed at the keyboard, both ways.** EDIT was run twice on a freshly
booted machine: once with the driver unloaded, once with it resident at the
`/R=1` default. Both open, work and exit normally. Loading the driver makes
no difference to the editor, which is the whole point and is the thing that
was not true at `/R=8`.

That A/B matters more than either half on its own. It exonerates the driver
rather than merely failing to convict it, and it means the freeze seen in
between was the key-injection automation being used to drive EDIT, not the
driver. `TICKCHK` agrees from the other side — `INT 08h is normal: hooking
after the driver is safe`, where before it warned.

Worth recording how this was missed. `TICKCHK` printed *"INT 08h runs fast.
Anything hooking it after the driver runs its timers this much too fast"* and
I quoted that line approvingly as evidence the timer was **healthy** — which
it was, for DOS. The warning was about everything else, and I read past it
because the measurement I cared about had come out well.

And worth recording how it was nearly missed twice. The first apparent
confirmation was an EDIT session that looked fine and was followed by the
machine freezing, and it got called fixed on the strength of the first half.
It needed a clean run on a freshly booted box, with the automation that had
been confusing the picture taken out of it, before the answer meant
anything.


## Second adapter, and the tools stop being called AX

**A second, physically different AX88179 works, with nothing changed.** It
was plugged in and the machine booted; `AUTOEXEC.BAT` brought it up
unprompted. Different manufacturer, different MAC — `00:50:B6:B6:1C:64`
against the first adapter's `40:AE:30:6D:00:34`.

- boot brought it up on its own, no intervention
- ARP answered, 100/100 round trips at 7 ms
- ping 8.8.8.8 3/3 `ttl=118`, `google.com` 2/2 `ttl=109`
- 1 MB `04D0E435` and 5 MB `BDBF684D`, checksummed on the box, both exact
- three boots — two warm, one cold — all up at 6-7 ms
- every error counter zero throughout

That is worth more than it might look. A sample of one cannot tell a working
bring-up from one accidentally tuned to a single unit's quirks. Two
independent adapters can. It is **not** evidence about a different chipset —
same `0B95:1790` silicon — and the register map has still only ever driven
one part.

### Renamed away from AX

The tools were named for the only chip they had ever seen, which is a poor
name for a project that wants more of them:

| was | is |
|---|---|
| `AXPKT.COM` | `USBPKT.COM` |
| `AXPROBE.EXE` | `USBLINK.EXE` |
| `AXRECV.EXE` | `USBRECV.EXE` |
| `AXSEND.EXE` | `USBSEND.EXE` |
| `AXNET.EXE` | `PKTTEST.EXE` |
| `AXTICK.EXE` | `PKTTICK.EXE` |

`NETID` and `PKTSCAN` were already generic. **`ax179.pas` keeps its name on
purpose** — it is the AX88179/178A register map, it is chip-specific, and
pretending otherwise would be the actual lie. Same for the resident
signature, `AXPKT001` → `USBPKT01`.

Whole suite re-run on hardware afterwards: `PKTSCAN`, `NETID`, `USBLINK`,
`USBRECV` (20 frames, 0 errors, 0 layout wrong), `USBSEND` (router replied),
`USBPKT`, `PKTTEST` 100/100 at 7 ms. `AUTOEXEC.BAT` and `NET.BAT` updated on
the machine and verified across a reboot.

### ADAPTERS.md

A support matrix, to grow: works / should work / needs a driver / unlikely,
with USB IDs. Currently one part in the first column and one in the second.

It is honest about what the rename bought, which is naming and not much
else. A new chipset still needs a bring-up in `ax179.pas`'s equivalent *and*
in `usbpktini.inc`, plus a dispatch on the USB ID. What it would **not**
need is the CH375 layer, the packet driver side, or most of the receive
engine — and that engine is the part that took four sessions, so the second
chipset should cost far less than the first. Suggested order: AX88772, then
RTL8152/8153, then CDC-ECM as a class driver covering many at once.

It also warns to run `NETID` rather than believe the packaging, because a box
marked AX88179 with an RTL8153 inside is a common way to waste an evening.


## 1.0.0 — it works, and a stranger can install it

The whole suite goes to 1.0.0 together. `USBPKT` had been sitting at 0.1.0
while it grew into something that enumerates the device, brings the adapter
up, goes resident, survives a boot and moves ten megabytes without an error.
The version had stopped describing it.

- `USBPKT` 0.1.0 → **1.0.0**
- `USBLINK` 0.2.0 → **1.0.0**
- `USBRECV` 0.1.0 → **1.0.0**
- `USBSEND` 0.1.0 → **1.0.0**
- `NETID`, `PKTSCAN`, `PKTTEST`, `PKTTICK` already 1.0.0

**[INSTALL.md](INSTALL.md) is new** and is the front door: what hardware you
need, four steps, how to load it at boot safely, and what to do when it does
not work. Written for somebody who has never seen this project — the test
being whether it reads as *one command like `NE2000.COM`*, because that is
what it now is.

The README has grown into a 750-line engineering notebook. That content is
worth keeping and is not what a new reader wants first, so it now says so
and points at the install guide.

Everything below this line is that notebook, newest first.


## Suite regression pass, and USBSEND stops guessing

`AxBulkSize` went from `$02` to `$01` in `ax179.pas` during the receive
hunt, and that file is shared -- `USBLINK`, `USBRECV` and `USBSEND` all build
on it and none had been run since. They have now:

| | result |
|---|---|
| `PKTSCAN` | both drivers found, 60h and 65h |
| `NETID` | `0B95:1790 ASIX AX88179`, supported |
| `USBLINK` | `bulk-in queue, size 01`, link up, 10 Mbps full duplex |
| `USBRECV` | 17 bursts, 17 frames, 0 errors, 0 layout wrong |
| `USBSEND` | `REPLY from 04:D4:C4:D2:2B:00` -- transmit works |
| `PKTTICK` | both phases, 0 errors |
| `PKTTEST` | 100/100 round trips, 7 ms |
| `USBPKT` | link up, resident, 0 in every counter |

Nothing regressed.

**`USBSEND` no longer defaults its addresses.** It shipped with
`/I=192.168.50.222` and `/T=192.168.50.1` baked in -- this machine's
network. On anybody else's it would quietly ARP a subnet they have never
heard of, on a range that might well belong to someone. Both are required
now, with a message that says why, which is how `PKTTEST` has always worked.

The example in the README keeps the real addresses, because it is a
transcript and transcripts should be true, but it now shows the invocation
above the output so it is clear they were given rather than assumed.


## Latency measured properly, and it was never 50 ms

`PKTTEST` grew `/N=count`: it sends an ARP, waits for the answer, repeats, and
divides the elapsed BIOS ticks by the count. One exchange is far shorter
than the 55 ms tick, so a single timing is meaningless and a few hundred is
not.

That was worth building, because mTCP's `PING` reports about 50 ms over this
adapter *at every poll rate*, and I spent a while hunting a fixed 46 ms
delay on the strength of it. The AX88179's aggregation timer was the prime
suspect -- the adapter holds a part-full burst until it expires -- so `/Q=n`
was added to sweep it. `/Q=2` and `/Q=128` measure identically. Not that.

Timed honestly, there is no anomaly to explain:

```
            /R=1    /R=4    /R=8   /R=16    NE2000
round trip  ~55ms    13ms     6ms     6ms      1ms
```

It tracks the poll interval and floors at 6 ms. mTCP's 50 ms is its own
timing granularity. **Measure a driver with something that is not the thing
you are trying to measure through.**

**`/R` now defaults to 8** rather than 4. Throughput stops improving after
4, but latency does not, and latency is what a telnet session or a BBS
feels -- which is most of what this machine does. It fits because bursts are
1 KB: 17 reads at about 5.3 µs a byte is 5.7 ms inside a 6.9 ms tick.

Verified at the new default: 6 ms round trip over 200 exchanges with none
lost, three boots (two warm, one cold) all coming up at 6-7 ms, 1 MB and
5 MB fetched and CRC-32'd on the box (`04D0E435`, `BDBF684D`) both exact,
every error counter zero, and `TICKCHK` showing INT 08h at 145 Hz with
INT 1Ch still at 18 Hz so DOS timekeeping is untouched.

`/Q` is kept. It is a real knob and now a documented dead end.


## Twice as fast, and a measurement I had to withdraw

1 MB now takes 36s where it took 73s. The ISA NE2000 in the same machine
does it in 18s, so this went from 4x that to 2x.

**The retraction first.** The previous entry says the poll rate does not
affect throughput -- 39s at `/R=1`, 39s at `/R=2`, 37s at `/R=4`. That was
measured through a write to the PicoMEM disk, which hid the entire effect.
Fetching to `NUL` instead shows it plainly:

```
                    /R=1   /R=2   /R=4   /R=8      NE2000
before               73s    61s    60s    48s        18s
after the read fix   71s    43s    36s    36s
```

The claim was wrong and the numbers it was based on were worthless. Fetch to
`NUL` when measuring a driver; a disk on a machine this slow will happily
absorb whatever you are trying to see.

**The payload read loop was costing about 150 clocks a byte.** A `call
ch_rd` per byte: call, push, two port-61h settling reads, the data read,
pop, ret, plus the caller's bookkeeping. Around 19 µs a byte, which caps the
whole driver near 50 KB/s however fast the wire is. It is now inlined, with
the settling pair dropped -- in that loop only, nowhere else.

That is safe here because of what the CPU is. `IN` is 14 clocks with the bus
wait states, `STOSB` 11, `LOOP` 17: about 5 µs between consecutive reads on
an 8 MHz 8086 with no help at all, already far longer than the CH375 asks
for. `REP INSB` would be the obvious answer and is not available -- `INS` is
80186 and up, and this is an 8086. On anything faster the delay wants
putting back.

Correctness was checked before speed, and again after: 1 MB fetched to disk
and CRC-32'd on the box, `04D0E435`, exact, with every error counter at
zero.

**`/R` now defaults to 4** rather than 1. `/R=8` ties on throughput but its
6.9 ms tick cannot hold a full 31-read burst at 10.5 ms; `/R=4` gives 13.7
ms, which can. The 480 ms latency outliers `/R=4` used to produce are gone
now the interrupt is cheap -- 6/6 pings, average 50.29 ms, no spikes.
`TICKCHK` confirms INT 08h at 72 Hz and INT 1Ch still at 18 Hz, so DOS
timekeeping is untouched.


## Proved with real volume, not just pings

Everything up to here had been small packets -- pings, a 559-byte page,
protocol banners -- which is not evidence that a receive path works.

Fetched over HTTP onto the DOS box and checksummed there with `HD.EXE`
against the source -- 64 KB `8156EC0D`, 512 KB `9EBAF22E`, 1 MB `04D0E435`,
5 MB `BDBF684D`, 10 MB `2B11D791`. **Every one exact.**

The 10 MB run:

```
bursts collected 18439   frames delivered 15858   frames sent 11977
bursts that made no sense       = 0
reads with an impossible length = 0
bursts too big for the buffer   = 0
reads rescued by flipping toggle= 0
```

Twenty-eight thousand frames through an 8086 without a single counted
error. Verifying on the box rather than pulling the file back matters above
about half a megabyte: a megabyte does not fit in one bridge job.

Throughput is about 18 KB/s and the poll rate does not change it: 39s at
`/R=1`, 39s at `/R=2`, 37s at `/R=4`. Nor does it change latency. Both were
measured because both looked like obvious wins; neither was. `/R` stays at
its default and the README now says so, with the numbers.


## It works

An IBM PS/2 Model 30 -- 8086, 1987 -- on the internet through a USB
Ethernet adapter, driven by a CH375 on the ISA bus.

```
USBPKT /I=65
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.
```

```
ping 192.168.50.1     3/3    ttl=64     49.30 ms
ping 8.8.8.8          3/3    ttl=118    49.30 ms
ping google.com       3/3    ttl=106    55.25 ms   (resolved to 192.179.24.113)
HTGET example.com     559 bytes of HTML
NC test.rebex.net 21  220-Welcome to test.rebex.net!
NC pocbbs...net 23    Net2BBS - Resolving your IP Address...
```

And the driver's own counters after all of that, which are the part worth
looking at:

```
bursts collected                = 967
frames delivered                = 154
frames sent                     = 108
frames nobody wanted            = 0
bursts that made no sense       = 0
reads with an impossible length = 0
bursts too big for the buffer   = 0
```

### The last bug was one line, and it was an optimisation

`rx_poll` opened with this:

```
cmp     byte [n_handles], 0
jne     short rx_go
ret                              ; nobody is listening; do not even
                                 ; touch the chip
```

Perfectly reasonable, and completely wrong. Nothing is listening between
the driver going resident and an application opening a handle -- and during
that gap the AX88179 keeps receiving, with nobody draining it. By the time a
client arrives the adapter is backed up, the driver starts already behind,
and it never catches up: every read returns another full 64-byte packet,
the transfer never ends, the buffer fills, the burst is discarded, and the
next one starts mid-transfer. That is the whole of the "endless stream of
FF" that took the previous four sessions.

It now polls whether or not anyone is listening, and throws the result away
if not. An idle poll is a NAK and returns almost at once, so it costs the
couple of percent this driver already spent looking. Overflows in a
ten-second run went from 182 to **0**, and the ARP reply that had never once
come back arrived on the first try, three times out of three.

The measurement that pointed at it was crude and worth remembering: loading
the driver and opening a handle back to back in one batch file, with no
pause between them, took frames delivered from 2 to 18. That was the whole
clue.

### What was eliminated to get there

Worth listing, because each one cost an experiment and none of them was the
answer:

- **Polling rate.** `USBRECV` gained a `/D=ms` switch and ran at 28 ms
  between polls, exactly USBPKT's rate: 20 bursts, 0 errors.
- **Interrupt context.** `PKTTICK` ran the reference `AxRxBurst` from a hook
  on INT 08h: 9 bursts, 0 errors, 0 overruns.
- **The receive filter.** `RX_CTL_PROMISC` set as a probe changed nothing.
- **Transmit.** A listen-only run from fresh power wedged just the same.
- **Read pacing.** Extra settling inside the payload loop changed nothing.
- **The bring-up path.** USBLINK's Pascal bring-up and USBPKT's own assembly
  one both wedged identically.
- **Aggregation size and timer.** Both were separately wrong and both were
  fixed; neither was the cause.

`PKTTICK.EXE` is kept. It is the tool that killed the interrupt-context
theory and it will be the right tool the next time something only goes
wrong inside the ISR.


## USBPKT brings the adapter up on its own at last

`USBPKT /I=65` with no `USBLINK` in front of it:

```
Bringing the adapter up... link up.
MAC address: 40:AE:30:6D:00:34
Resident at vector 65h.
```

That had failed every single time before, always at step 2 -- the second
PHY power write -- with status 28, a timeout. The cause was the one already
found in `read_mac` and not yet applied anywhere else: `ctrl_out_r` and
`ctrl_in_r` ran with the chip set to **report** NAKs rather than absorb
them, so a device that was merely busy failed the transfer outright. They
now set `8F` for the duration and put it back to `00` before returning.

The comment above `set_retry` in that file has said "control transfers want
8F" since it was written. It took three separate bugs to notice it applied
to the code underneath it.

**`CLR_STALL` was being given the wrong endpoint.** `82h` -- the USB
endpoint address with the direction bit -- where the CH375 wants the bare
number `2`. `ch375.pas` calls `ClrStall(AX_EP_BULK_IN)` and that constant is
2. So every attempt to resynchronise the bulk endpoint was clearing an
endpoint that does not exist, silently. Fixing it changed the symptom
immediately: instead of returning a "successful" 64 bytes of FF, the chip
started reporting `2B`, `INT_RET_TOGGLE_MISMATCH`, which says exactly what
is wrong.

**A toggle mismatch is now recovered rather than treated as a lost packet.**
The device sent the other DATAx; the data is still there and we asked with
the wrong PID. `bulk_in` flips and asks again, once. Overflows in a
ten-second run went from 181 to 4.

### Two theories killed, which is worth as much as a fix

**Polling rate is not the cause.** `USBRECV` polls flat out -- about 850
times a second -- and `USBPKT` manages 36, because it polls from the timer
and a 64-byte read off this bus is expensive. That looked like the whole
story. So `USBRECV` grew a `/D=ms` switch and was run at 28 ms between
polls, exactly USBPKT's rate, against the same adapter: **20 bursts, 20
frames, 0 errors, 0 layout wrong.** The reference is perfectly happy at
USBPKT's speed. Whatever the difference is, it is not the rate.

**Nor is it the receive filter.** `RX_CTL_PROMISC` was set as a probe, on
the theory that unicast replies were being dropped by the adapter while
broadcasts got through. It changed nothing. Reverted -- and it is the wrong
default regardless, on a machine that cannot drain what it already asks for.

### Where the remaining fault stands

Transmit is correct and confirmed from another machine. Frames that arrive
parse correctly. But after a frame or two the bulk endpoint starts
returning full 64-byte packets of FF, reported as `INT_SUCCESS` with length
40h, and never sends a short packet again -- so the burst never ends, the
buffer fills, and everything after it is discarded.

Not the hardware, not the poll rate, not the filter, not the aggregation
size, not the toggle alone, and `CLEAR_FEATURE` on the correct endpoint
does not clear it. What is left is something `rx_poll` does that
`AxRxBurst` does not, and the two now agree on every point that has been
checked line by line. The next thing to try is running the reference code
itself from the timer interrupt -- if `AxRxBurst` wedges there and not in
the foreground, the difference is interrupt context, not logic.


## Our own test tools, and mTCP off the CH375 entirely

`PKTTEST.EXE` and the `PktApi` unit. A Crynwr packet-driver client that talks
to **the vector you name** -- no scan, no config file, no default that can
reach the wrong card.

The reason is a rule for this project from here on: **mTCP is for sanity
checks on the working NE2000 at 60h, and nothing else.** Testing the CH375
adapter through mTCP meant pointing `MTCPCFG` at a second config for the
duration of a test and pointing it back afterwards -- two adapters, one
environment variable, and a machine administered over the other one. That
arrangement only has to be got wrong once. Everything that touches the
CH375 is now ours.

```
PKTTEST /M=<my ip> [/I=hex] [/T=<target ip>] [/S=secs] [/L] [/R] [/X]
```

`/T` ARPs an address and waits. `/L` listens and prints every frame. `/R`
listens *and answers* -- ARP for `/M`, and ICMP echo -- so the adapter is
pingable from another machine, which is the only way to prove it takes
unicast traffic. A driver can receive every broadcast on the wire and still
drop everything addressed to itself.

It asks the driver for every protocol and picks out what it wants in
software, deliberately: a tool that exists to diagnose a driver must not
depend on that driver's type filtering being right.

### What now works

Measured with PKTTEST against a live network:

- **Transmit is correct**, and confirmed from outside the machine rather
  than by trusting our own counters: an ARP request sent through USBPKT
  reached the wire and the far end learned `192.168.50.222` at the
  adapter's MAC.
- **Receive parses correctly.** Real frames arrive through the packet
  driver with the right addresses and ethertypes, and `bursts that made no
  sense` is 0 where it used to be 4657 out of 4659.

### Four receive faults fixed on the way

**A length the chip could not have meant.** When the CH375 stops driving
the ISA data bus every read returns FF, so the length byte reads as 255.
`ch_read` drained 255 bytes, stored the first 64, and reported a full
packet. `rx_poll` then kept asking until its budget ran out and handed up
1536 bytes of FF as a burst. A bulk packet cannot exceed 64 bytes, so a
length above that is now refused outright.

**One bad read poisoned the endpoint for ever.** `bulk_in` advanced the
data toggle on *every* success, including reads that were not packets.
After one, every IN asked for the wrong DATAx and nothing matched again.
The toggle now only advances on a read we believe.

**The toggle was never resynchronised when adopting an adapter.** `rx_tog`
is assembled as DATA0, but after `USBLINK` the adapter has been receiving
and the device's toggle has moved on. `/A` now clears both bulk endpoints,
which resets the toggle at both ends.

**A budget that discarded what it had already read.** Ending a burst when
the read budget ran out lost the frames already collected *and* left the
remainder in the chip, so the next tick began mid-transfer. Bursts are now
collected across ticks -- the chip holds the rest quite happily -- and only
a genuinely full buffer discards.

Two constants are a pair and must move together: `RX_BUDGET` and `tick_n`.
A 64-byte read costs enough on this bus that 31 of them do not fit in a
145 Hz tick, and a receive loop that overruns its own period leaves the
foreground no time to run at all. That is not a crash; the machine simply
stops getting anywhere, and it took a power cycle to clear. `tick_n` now
defaults to 2.

### Still open: an endless stream of FF

After the first frame or two, the adapter starts returning full 64-byte
packets of FF, reported as `INT_SUCCESS` with length 40h, and never sends a
short packet again. Nothing recovers it -- not draining, not
`CLEAR_FEATURE(ENDPOINT_HALT)` on the bulk endpoint, not a bigger buffer,
not smaller aggregation.

It is emphatically not the hardware. `USBRECV.EXE` was run against the same
adapter minutes later and read 20 frames with 0 errors and every layout
check passing.

The one measured difference is the polling pattern, and it is stark:
**USBRECV made 5083 idle polls in six seconds -- about 850 a second -- and
got clean NAKs whenever the wire was quiet. USBPKT polls 36 times a second**,
because it polls from the timer and each 64-byte read is expensive. Whatever
this state is, USBRECV never stays still long enough to enter it. That is
where to look next.


## The MAC read had to let the chip absorb NAKs

`USBPKT /A` — take the adapter exactly as `USBLINK` left it — failed on its
very first act, reading the MAC, on hardware `USBLINK` had finished with
seconds earlier:

```
Taking the adapter as it stands (/A).
The adapter did not return its MAC address.
Chip status on the last try: 2A
```

`2A` is `INT_RET_NAK`: the device is awake and saying "not now". `read_mac`
set retry to `00` — report a NAK rather than retry it — which is right for
polling an idle endpoint and wrong for a control transfer, as the comment
above `set_retry` in this very file already said. It now sets `8F` for the
transfer and puts it back to `00` on every exit, so nothing is left retrying
in the background for the next program to trip over. That is the whole fix,
and `/A` has been reliable since.

Three things found alongside it:

**`ctrl_in` never recorded the chip status.** `bu_st` held whatever the last
high-level command had put there, so `read_mac`'s "only a stall needs
clearing" test — and every error message — was reading a status belonging to
an unrelated operation. There is now a `ch_waitst` wrapper that records it,
with `FF` for no interrupt at all. Until this was fixed no failure in a
control transfer could be diagnosed at all, which is why the NAK above went
unseen for so long.

**`delay_ticks 1` guarantees nothing.** It waits for the BIOS counter to
*change*, so `1` is anywhere from 0 to 55 ms depending on where in the tick
you arrive; `n` guarantees `n-1` whole ticks. The 20 ms the AX88179 needs
between the two PHY reset writes was sometimes not happening at all. Callers
now pass `n+1` and the routine's comment says so.

**A comment here was simply wrong.** The entry below says "the Pascal
bring-up clears a stall only after one happens". It does not: `Setup8` in
`ch375.pas` opens *every* control transfer, in and out, with `ClrStall(0)`.
The claim had never been checked against the source it described. The clear
is back where the reference has it.

### Still broken: the receive path

`USBPKT` brings the adapter up and sends, but what comes back off the bulk
endpoint is not frames. A cold boot, a clean `USBLINK`, `/A` loading and
reading the MAC, and then 521 of 522 bursts rejected, each 1536 bytes of a
repeating four-byte pattern.

It is not the hardware and it is not the adapter. `USBRECV.EXE` — the Pascal
receiver — was run on the same machine minutes later and read 20 bursts, 20
frames, 4104 bytes, 0 errors, layout checks all passing. The fault is in
`rx_poll` in `usbpkt.asm`, and `USBRECV` is the working reference to diff it
against.

### USBLINK can hang the machine, so nothing USB belongs in AUTOEXEC.BAT

Loading the adapter from `AUTOEXEC.BAT` was tried and has been taken out
again. On four boots out of five — cold power cycles included — `USBLINK`
hung outright, before the point where the machine becomes reachable over the
network. A hang is not something `IF ERRORLEVEL` can catch, so the fallback
that was supposed to make this safe never ran. Recovering needed the power
switch each time, and on a machine administered remotely that is the one
failure mode worth designing against.

`NET.BAT` from the prompt costs a power cycle at worst. That is where this
stays until the bring-up cannot hang.


## USBPKT does the whole job

`USBPKT.COM` now enumerates the device and brings the adapter up itself, so
it is one command like `NE2000.COM`. `USBLINK` is a diagnostic now, not a
prerequisite. Verified from a cold start: link up, gateway 2/2, 8.8.8.8 2/2
at ttl=118, and `HTGET http://example.com/` returning 200 OK, with the
machine's own driver at 60h untouched.

Four faults found getting there, and the order matters because each one hid
the next:

**`CLEAR_FEATURE` before every register access.** `CMD_CLR_STALL` is not a
local chip operation — the CH375 issues a real control transfer to the
device. Doing that ahead of every write left the device busy when the write
arrived, so it NAKed. The failure moved around as timing shifted (step 7,
then 9, then 3), always with status 2A, always blaming whichever register
happened to be next. The Pascal bring-up clears a stall only after one
happens, and never NAKs; this now does the same.

**`SET_USB_MODE` without its readback.** The chip leaves a status byte in
the data port and a byte nobody collects is still there for the next read.
Three mode changes during enumeration meant three stale bytes queued ahead
of the device descriptor — which is where it failed, three commands
downstream of the cause.

**`WaitInt` milliseconds treated as a spin count.** The Pascal's
`WaitInt(Ms)` is an outer loop over an inner 400-poll spin. `wait_for(300)`
was being handed 300 raw iterations: four hundred times too short.

**A teardown that overwrote its own diagnostic**, so a failure at step 3
reported a register the teardown had touched on the way out.

Also: `/A` takes the adapter as it stands (`/N` was already taken -- it
means "do not hook the timer", and binding a second meaning to it made a
documented switch silently do something else), `/U` unconfigures the device
before releasing memory, and the failure message now names the real cause
of the common step-23 failure and the only thing that actually fixes it.

## Unreleased

### Working, and proven on the hardware

* **`USBLINK` 0.2.0 brings an ASIX AX88179 (`0B95:1790`) all the way up**
  over a CH375: configuration set, PHY powered and out of reset, clocks
  selected, MAC read (`40:AE:30:6D:00:34`), receive path configured, link
  negotiated. First run, no debugging. `medium mode 0136` — 10 Mbps full
  duplex — and `rx control` reads back exactly the bits written.
* **`USBRECV` 0.1.0 reads real Ethernet off the wire.** A broadcast UDP
  frame from `192.168.50.8` and an IGMP query from the router both arrived
  and decode correctly by hand from the hex dump. Frames start at offset 0
  with no padding, which confirms `RX_CTL` `IP_ALIGN` being clear does what
  was intended.
* **`ax179.pas`** holds everything that knows what an AX88179 is, so the
  two programs and the eventual packet driver share one register map
  rather than three copies of it.
* The PHY is restricted to **10BASE-T** by default, by withdrawing the
  gigabit and 100 advertisements rather than by forcing the speed, so the
  far end negotiates normally. `/G` leaves it at gigabit. This is a runtime
  switch and not a constant because the arithmetic changes on a 486.
* Bulk-in aggregation is turned **off**, where Linux turns it on: this
  machine cannot absorb a 20 KB burst 64 bytes at a time. Also a 486
  decision waiting to be reversed.

### Two traps in the shared CH375 layer, found the hard way

* **`BusUp` never sends SET_CONFIGURATION.** A device with an address but
  no configuration is in Address state, where control transfers to endpoint
  0 work perfectly and every other endpoint does not exist. Every register
  access succeeded and the link came up; then all 7056 IN tokens to the
  bulk endpoint timed out in eight seconds. `AxInit` now sets the
  configuration first, taking the value from the descriptor rather than
  assuming 1.
* **`BusUp` sets `SET_RETRY 8F`, retry NAKs for ever.** Correct while
  enumerating, wrong for polling an idle endpoint: the chip retries instead
  of reporting, the caller's wait expires, and a poll takes seconds and
  returns "no interrupt". Two polls in nine seconds became 865 in under
  one. `AxInit` now sets no-retry after bring-up.

  `USBPOLL` already did both of these. Neither was documented anywhere but
  its source; both are now in this project's README.

* `AxRxBurst` drains and discards the remainder of a transfer that will not
  fit the caller's buffer, and reports how much went missing in
  `AxRxOver`. Leaving a transfer half-read desynchronises the endpoint and
  every burst after it is garbage -- which is what the first 2 KB buffer
  did before it was enlarged to 16 KB.
* Error reporting from the poll loop is capped at eight lines. An error
  that repeats every poll otherwise printed thousands of identical lines
  and the run spent all its time on output rather than on the wire.

### The receive buffer layout, solved and verified

    [frame 1][pad to 8][frame 2][pad to 8]...[entry 1][entry 2]...[trailer]

* trailer: last 4 bytes LE, low word = packet count, high word = offset of
  the entry array.
* entry: 4 bytes per packet, `(entry >> 16) and $1FFF` = frame length.
* frames: from offset 0, each padded to an 8-byte boundary. With IP_ALIGN
  clear there is no leading pad, so byte 0 is the destination MAC.

It matches what the Linux driver describes after all. Every earlier reading
that said otherwise was a truncated transfer, not a different format --
see the two bugs below. `USBRECV` checks each invariant and prints a tick or
a cross beside it rather than assuming any of them.

### Two more bugs, both mine, both in AxRxBurst

* **A NAK was being treated as the end of a transfer.** In USB a bulk
  transfer ends with a SHORT packet; a NAK part-way through only means "not
  ready yet, ask again". Every multi-frame transfer was being truncated --
  the capture that started this hunt stopped at 256 bytes with a second
  frame cut in half and no trailer in it at all. Mid-burst NAKs are now
  retried, bounded, and only a short packet ends a burst.
* **Zeroing `AX_RX_BULK_QCTRL` does not mean "no aggregation".** It means
  *no limit*, which is the opposite: the chip appends frames for as long as
  traffic arrives and the transfer never ends. One capture reached 55,680
  bytes before the buffer gave up. The control byte is now 07 -- all three
  limits on -- with the size, timer and inter-frame gap exposed as
  `AxBulkCtrl` / `AxBulkSize` / `AxBulkTimer` / `AxBulkIfg` and reachable
  from `USBRECV` as `/C=` and `/B=`.

### Throughput, measured

* About **1650 bytes/sec** sustained with the link deliberately loaded --
  roughly 13 kbit/s.
* In a 15-second run: **12,112 idle polls against ~390 reads carrying
  data**. The limit is not how fast bytes leave the CH375, it is that the
  chip has something for us on about 3% of polls. Raw read bandwidth looks
  nearer 50 KB/s if the duty cycle could be improved.
* Burst size does not behave the way you would guess: `/B=02` gives
  1650 B/s and `/B=08` gives **302 B/s**, five times worse, because a
  bigger threshold makes the chip wait longer and drop more while waiting.
  The default is 2 for that measured reason rather than a guessed one.

### Transmit works, and a real machine confirmed it

* **`USBSEND` 0.1.0** builds an ARP request, sends it, and waits for an
  answer. The router replied: `REPLY from 04:D4:C4:D2:2B:00 --
  192.168.50.1 answered us.` Three runs, three replies, two polls to the
  first one.
* Proving it this way is deliberate. A bulk write returning success only
  means the CH375 accepted the bytes; a misplaced header field or a missed
  padding flag makes the chip drop the frame in silence and report nothing.
  A reply cannot be manufactured at this end -- it means another computer
  received the frame, parsed it, believed it and addressed a response back
  to this MAC. The router's MAC also matches the one in an unrelated IGMP
  query `USBRECV` caught earlier.
* The TX header is 8 bytes: two little-endian 32-bit words, the frame
  length then zero -- except when the total including the header is an
  exact multiple of the 64-byte packet size, when bits 15 and 31 are set.
  That case separately needs a zero-length packet to end the USB transfer;
  the two requirements arise together and are easy to conflate.

### A third bug in AxRxBurst, and this one hung the machine

* **The overflow drain was unbounded.** When a burst does not fit the
  caller's buffer the remainder has to be read and discarded or the
  endpoint desynchronises -- but that was written as "read until a short
  packet", and the chip can stream continuously. On a busy network the
  loop never returned, and a DOS program that never returns takes the box
  with it. It hung twice and needed the power cycled both times. Now
  bounded at 1024 packets, which is far more than any sane burst and
  finite.

### USBPKT, and PKTSCAN before it

* **`PKTSCAN` 1.0.0** lists which interrupt vectors hold a packet driver,
  by the "PKT DRVR" signature three bytes into the handler. Read-only, so
  it is safe over the live connection it is reporting on. On this machine:
  60h taken, 61-66 / 68-6C / 6E-6F / 78-7E free, and 67h and 6Dh occupied
  by EMS and video rather than free.
* **`USBPKT.COM` 0.1.0 is written and assembles at 8,221 bytes.** It does
  not work yet, and it refuses to do damage while not working, which was
  the part worth getting right first:
  - vector 60h refused outright, exit code 4, proven on the hardware;
  - any vector already carrying the signature refused;
  - neither overridable by a switch;
  - install aborts cleanly when the adapter will not answer, leaving no
    vector hooked -- `PKTSCAN` before and after shows 60h untouched.
* Written but unproven: the Crynwr entry point and dispatch, the two-call
  receive handshake, `send_pkt` with its 8-byte header, the INT 08h poll
  with an adaptive budget and a re-entry guard, install, unload with
  out-of-order hook detection, and `/S`.
* **The bug:** `read_mac` in `usbpktini.inc` returns an error where the
  identical vendor request from Pascal returns the MAC four times out of
  four. New assembly, not the chip and not the register map -- both proven.
* **The split is wrong and known to be.** `USBPKT` needs `USBLINK` to have
  brought the adapter up first. A driver you have to prepare with a second
  program is one somebody will forget to prepare; folding the bring-up in
  comes after the control transfer works.

### It pings

    Packet sequence number 0 received from 192.168.50.1 in 46.75 ms, ttl=64
    Packet sequence number 1 received from 192.168.50.1 in 51.85 ms, ttl=64
    Packet sequence number 2 received from 192.168.50.1 in 51.85 ms, ttl=64
    Packets sent: 3, Replies received: 3, Replies lost: 0

mTCP, on an IBM PS/2 Model 30, over USB Ethernet on a CH375 ISA card, with
the machine's own network at INT 60h untouched throughout. The ~50 ms round
trip is the 18.2 Hz poll interval showing through, not the wire.

`USBPKT.COM` implements driver_info, access_type, release_type, send_pkt,
get_address, reset_interface, set_rcv_mode, get_rcv_mode and
get_statistics, with receive collected on the timer and handed up through
the two-call handshake. mTCP's `pkttool` and DOSBridge's `PKTCAP` both
drive it correctly.

### The two bugs between "frames move" and "it pings"

Both hid behind a partial success, which is the worst place for a bug to
hide.

* **The delivered length included the Ethernet FCS.** RX_CTL_DROP_CRC means
  "discard frames whose CRC is wrong", not "strip the CRC". PKTCAP's own
  dump had been saying so for a while: a 42-byte ARP request padded to the
  60-byte minimum arrived as 64 bytes, with four non-zero bytes after the
  padding.
* **bulk_out restored SI on success.** It was added for the NAK rewind and
  wrongly applied to the success path, so the caller's SI never advanced
  and every 64-byte packet after the first re-sent the beginning of the
  frame.

The second is why this looked like a receive fault for hours. A 60-byte ARP
request is 68 bytes with the transmit header -- 64 plus 4 -- and the four
repeated bytes land in padding nobody reads, so ARP resolved perfectly. A
74-byte ping is 82 -- 64 plus 18 -- and those are real IP header bytes, so
the router dropped every one in silence. ARP succeeding is precisely what
made the transmit path look innocent.

### Also

* PKTCAP, in DOSBridge, gained a third argument naming the interrupt
  vector. That is a safety feature rather than a convenience: without it
  the tool attaches to the first packet driver between 60h and 80h, which
  on a bridge machine is the network the bridge runs over, and with ALL the
  frames it captures are frames nobody else receives. Naming a second
  driver confines the capture to the card being debugged.

### Not done
* **The packet driver.** A Crynwr driver at INT 60h, so `mTCP` and
  `WATTCP` work without a TCP stack being written here.
* **A duty-cycle fix.** 3% of polls carrying data is the thing standing
  between 1.6 KB/s and something nearer 50 KB/s, and it is a tuning
  problem rather than a bus-speed one.
