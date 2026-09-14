# Picking this up next

Written 2026-09-09, rewritten 2026-09-10 after a long session on the data
corruption and again the same evening after CDC-ECM started working. For
whoever continues this, including a fresh Claude Code instance.

## Read these first, in this order

1. **`INSTALL.md`** -- what the thing does and how to use it. Short.
2. **This file** -- state, the open fault, and what to do next.
3. **`README.md`** -- the engineering notebook, newest at the top. The
   corruption sections are long because most of their value is the list of
   things that turned out not to be the cause.
4. **`CHANGELOG.md`** -- the same story in order. Several entries are
   retractions; those are the useful ones.

## Where to work from

**Use `C:\dosbridgeDEV`.** It is the git repo, it has the real `CLAUDE.md`,
and `dosd` runs from it. `C:\dosbridge` is an old runtime copy whose
`CLAUDE.md` is empty; never sync "the newer file" in that direction.

`MSYS_NO_PATHCONV=1` in front of anything passing a DOS switch like `/I=65`.

## State: it works, and one fault is still open

`USBPKT.COM` is a Crynwr packet driver for a USB Ethernet adapter on a CH375
ISA card. One command, like `NE2000.COM`. mTCP runs over it at
`packetint 0x65` and DOSBridge stays on the NE2000 at 60h throughout. Ping,
DNS, HTTP, FTP and telnet all work.

### Added this session: a CLASS driver, and it transmits

`ecm.pas` drives **CDC-ECM**, which is a USB class rather than a chip: the
device describes itself and one bring-up covers adapters from any vendor.
`ECMLINK` is the proof-of-life tool for it, and `build.cmd ecm` runs the
whole thing on the DOS machine.

It exists because an **AX88179A** arrived reporting the same USB ID as the
AX88179 (`0B95:1790`), enumerating fine on the vendor path and transmitting
nothing at all through it. That part also offers ECM as configuration 3.
Verified on hardware 2026-09-10, four consecutive runs: everything about the
device discovered from its own descriptors, MAC read out of the string
descriptor, ARP request sent and **answered by the host it asked about**.

That is a transmit path on an adapter that had none. `ADAPTERS.md` has the
full entry.

**And `USBPKT` now speaks it too** -- the back-end is written, the bring-up
is verified on hardware, and the data path is NOT yet verified. See below;
finishing that is the first job.

It was far less work than expected, because at the USB level the two paths
are the same transfers and `rx_go` already was the ECM receive loop. The
ECM path is the vendor path with the parser removed.

### Fixed this session

**`REP INSB` / `REP OUTSB`,** on all three byte-moving loops, gated on a
run-time `Has186` probe, portable loops kept and reachable via `/8`. Worth
2.6% on throughput -- which was the prediction, since at `/R=1` this is
round-trip-bound -- and **33% off the length of the interrupt**, which was
the point. `USBPKT /S` now measures its own worst poll.

**Two register-preservation bugs in the burst walk.** `rx_deliver` calls the
application's receiver through `call far [cs:rcv_tmp]`, and the comment above
that call says nothing may be assumed about any register afterwards. The loop
then assumed two: `CX`, the frame length used to compute the stride to the
next frame, and `BP`, the entry stride for the whole burst read as
`add si, bp` every iteration -- and the register a C compiler is likeliest to
be using as a frame pointer. Both are pushed now.

**Corruption went from 67% of 5 MB downloads to about 11%.** Large, and not a
cure.

### The open fault

A 5 MB download comes back the right length with a region of wrong bytes,
roughly **1 download in 9**, or **1 event per 44 MB**. The signature is
measured across the whole run, not inferred from a window:

```
deltas +192 x4 +76 x158
```

| | |
|---|---|
| first piece | always **exactly 4 bytes**, displacement -64 (mod 256) |
| second piece | the remainder, displacement +76 (mod 256) |
| length | 162 four times, 82 once -- only the second piece varies |
| alignment | every event starts at an **even** offset, 5 of 5 |

Fixed displacements with a variable length is the shape of a structural
offset applied in the wrong place. Nothing is altered bit by bit and nothing
is dropped -- the file stays in step everywhere else -- so a region is
**overwritten with payload duplicated from elsewhere in the stream**.

The displacements are known only **modulo 256** from the ramp files. That is
what `CNT5M.BIN` and `RAMPCHK /K` exist to fix, and they have not yet caught
an event.

## What has been EXCLUDED, and by how much

The most valuable part of this file. Do not re-run these.

| ruled out | how |
|---|---|
| disk, FAT, DOS file I/O | `RAMPCHK /W` writes 5 MB and reads it back perfect, no network in the path |
| mTCP + `HTGET` + disk | **165 MB** clean over the NE2000, P(0) = 2.4% |
| the burst parser | 3 corruptions with the tiling counter at **zero**, and 3 tiling anomalies that produced **perfect** files -- a clean anti-correlation |
| the HTTP server | dosd on 8080 corrupts at the same rate as the port-80 server |
| either byte loop | fast path and `/8` both corrupt, and differently |
| out-of-region delivery | `n_outside` reads 0 on the runs that corrupt |

**And one deduction.** A substitution *does* change a TCP checksum --
checked, not assumed; only a true permutation of 16-bit words is invisible.
Corrupt data nonetheless reaches the file, so **mTCP is not verifying receive
TCP checksums on this path**. That is why driver-level damage lands on disk
instead of costing a retransmission.

**What is left:** the CH375 read itself, or the contention between transmit
and receive on it.

## DONE: the SR9700 is in USBPKT, and mTCP runs over it

This section was the plan. It is kept as the record because what the plan
got wrong -- and what was then argued into it and back out of it against the
evidence -- is worth more than the parts it got right.

### What it actually took

| | |
|---|---|
| identification | a USB-ID table -- this part has nothing else to go on |
| endpoints | a descriptor walk that skips the class-`08` flash on interface 0 |
| bring-up | NCR reset, PHY reset and release, one RCR write, read back |
| MAC | six single-byte register reads out of PAR |
| transmit | `tx_hdrlen` of 2 and one `stosw` |
| receive | a loop over the records in a burst, plus a boundary search when the first header is impossible -- far more than the "twenty lines" first estimated, and the section below is why |
| the flag | `ecm_mode` -> `link_mode` with three named values |

Measured on hardware: gateway 3/3, `8.8.8.8` 3/3, DNS resolving, HTTP GET
complete, and **5 MB byte-exact -- `RAMPCHK` verdict "exactly the ramp",
zero mismatches**.

**Timing needs replicates here.** Six timed 5 MB downloads came in at 263,
270, 284, 299 and 308 seconds, so run-to-run variance is about 15% and a
single before/after pair proves nothing about a code change. Two claims in
this file were made from such pairs before the replicates existed, and both
were withdrawn. Where a change has to be justified, use the frame counters:
they do not drift.

**175 MB byte-exact**, 35 independent 5 MB downloads across both transports,
zero mismatches. That matters beyond this adapter: the open corruption fault
runs at roughly one event per 44 MB on the AX88179, on this same CH375, ISA
card and machine, so 175 MB clean here changes which half of the system is
under suspicion.

### The plan said "a linear tiling parse", and the plan was right

The plan predicted "a linear tiling parse ... the only new thinking", on the
assumption that a burst holds several `[header][frame]` records end to end.
That is exactly what it holds.

It was dropped anyway, on evidence that looked conclusive: a 60-second
listen and a 5 MB download both showed one frame per USB transfer ended by
a short packet, precisely as CDC-ECM behaves, and `sr9700.pas` reads one
frame per call and had decoded 69 consecutive frames correctly. So the loop
became a straight-line parse that delivered the first record and returned.

**This chip tiles only when the frames are SMALL.** A download of full-size
frames is a test that structurally cannot see it. 5,054 frames passed with
no burst disagreeing with its own header; by 26,000 the counter had caught
229 -- bursts of 268 bytes holding a 64-byte record, two hundred bytes of
good frames behind it going on the floor.

The counter was four lines, written into the straight-line parse because
that parse's assumption was the thing most likely to be wrong. **Nothing
else reported anything.** TCP retransmitted the losses, every file arrived
byte-exact, and the 100 MB volume test that was meant to qualify this
driver would have passed either way. A driver that silently drops 0.9% of
bursts and 4.6% to misparse is not one any download would have failed.

The lesson is not "tile parsers are hard". It is that **the measurement
which would have vindicated the driver was incapable of failing**, and the
only instrument that could see the fault was the one put there on purpose
to doubt the assumption. Put a counter on whatever you have assumed about a
chipset's framing before you put a download through it.

### The plan said to skip the chip reset. That was wrong too.

It repeated the Pascal driver's suspicion that `NCR_RST` takes the USB front
end down with it. The Pascal driver resets **by default** and works; without
the reset the bring-up succeeds in every visible respect and the link
register never comes up.

### What the plan got right

* `ecm_probe`/`ecm_bring` is the template, and it slots in at the same place
  in the enumeration, before a configuration has been chosen.
* Skipping the mass-storage interface is the whole of the endpoint job.
* Single-byte register reads, always.
* `SET_RETRY 00` before any endpoint is polled.
* **`/T` is the reason this cost one evening.** The bring-up ran on the
  first hardware attempt and every later iteration was non-resident, so the
  machine was never at risk while the geometry was still being argued about.

### The receive parse still rejects about 3% of bursts -- START HERE

This is the one piece of unfinished work, and it is well instrumented.

A burst is thrown away when the first header in it is impossible -- a length
under 4 or over 1518. Four mechanisms were proposed for it, implemented, and
every one measured at zero: `rx_drain` leaving the pipe part-read (`n_flush`
= 0), the chip's empty-record convention (`n_empty` = 0), a record straddling
a transfer boundary (`n_short` = 2 in 4,361), and a lost phase carried
between bursts (266 rejections against 270 without it).

What is known, from the attribution latch that records how the PREVIOUS
burst ended: rejections **usually** follow rejections, so there is a cascade
and most of the cost is in it -- but not always. One sample shows a rejection
following a burst that parsed **cleanly**, which rules out "a rare event
knocks it out of phase and it never recovers" as the whole story. Both
readings are in the latch; it prints the previous outcome as 0 clean,
1 truncated, 2 impossible, 3 residue. A captured burst held a valid
record at offset 7 whose length ran to exactly the end of the burst
(10 + 1518 = 1528), which is what the recovery search is built on.

The search recovers about 30% -- 61 of 206 in one run. **The cheap next step
is to widen its acceptance test**: it currently requires the candidate
record to end exactly on the end of the burst, and accepting one that ends
on another plausible header would cover the bursts that hold more than one
record. After that, the question worth answering is what starts a cascade in
the first place, and `n_over` (bursts too big for the 2 KB buffer, 9-17 per
5 MB) is the only counter that moves at anything like the right rate.

Everything needed is already in `/S`: `reads with an impossible length`,
`bursts realigned by search`, the last rejected length with its offset and
burst size, and how the previous burst ended.

### A second thing measured and wrong: the receive filter

The narrow receive filter went in with a persuasive argument attached --
one frame per USB transfer, 16 ms a frame paid whether it was wanted or
not, a segment that is 60% multicast, an overflow counter reading B3. All
true. `/M` was added so the conclusion could be tested rather than
asserted, and the same 5 MB download took **307.9 s narrow and 312.3 s
wide**. 1.4%.

The filter stays narrow because a packet driver should deliver what its
clients asked for, not because it buys throughput. The claim had already
been written into three files before it was measured.

### The one thing left open: NSR says DOWN

`NSR` reads `81` after `USBPKT`'s bring-up and `C1` after `SRLINK`'s, on the
same adapter minutes apart, differing only in bit 6 (`LINKST`) -- while the
driver goes on to carry mTCP. It is reported and nothing depends on it, and
the raw byte is printed beside the verdict so the next person does not spend
an evening on the cable.

Two candidates have been tested and ruled out. The PHY reset used `delay_ms`, a
calibrated spin loop, and the ASIX path a few hundred lines below carries a
comment about that exact trap -- it failed intermittently until switched to
`delay_ticks`, a guaranteed minimum. Same switch here changed nothing,
still `81`. Kept anyway, because a guaranteed minimum is right regardless.
And all-multicast, via `/M`, also reads `81`.

And promiscuous, via `/P`, also reads `81` -- which was the last filter
bit `SRLINK` set and this driver did not. `SRLINK` writes RCR `3B` and
reads `C1`; `USBPKT` writes `31`, `39` or `3B` and reads `81` every time.
So the filter is not it either, and the bus-reset sequence has been read
side by side and matches: 100 ms, mode 7, 40 ms hold, mode 6, wait for
connect, 200 ms.

Three candidates excluded is worth more than a guess, and it is where this
stops: nothing depends on the bit, the raw byte is printed, and a status
register that disagrees with a data path carrying volume byte-exact is not
the most useful thing to spend the next evening on.

Otherwise: a read taken in a window `SRLINK` never occupies, or one
bring-up leaving the PHY subtly different. Neither is shown.

## What to do next

### 0. Where this was left

**The driver is in its best known state and the corruption is NOT solved.**
Both register fixes are in the default build, `/8` still reaches the
portable loops, and the boot copy in `C:\CH375` was updated so the machine
actually starts with them.

Verified totals at hand-off, all with the fixes in:

| | volume | events |
|---|---|---|
| USBVFY, receive path only | 44 MB | 0 |
| HTTP over USBPKT | ~220 MB | 5 |
| NE2000 control | 165 MB | 0 |

The USBVFY figure is **not** an exclusion: at 1 event per 44 MB it expects
1.0 and is a 37% outcome. Getting it to ~180 MB, where a clean sweep means
something, is about three hours of unattended running with the loop in
`vfyloop.py`, or well under one with a static ARP entry allowing unicast at
full rate.

### 1. Read the paired A/B result in `vfylog.txt`

`USBVFY` verifies the receive path with **nothing above it** -- our own
IPv4/UDP, a payload keyed to absolute stream position, every byte checked on
arrival, no TCP, no mTCP, no file system, and no checksum filtering anywhere.

It runs paired, because a pure listener tests the wrong thing: during a real
download the box ACKs constantly, so `pkt_send` and `rx_poll` interleave on
the chip under `chip_busy`. `/A=2` transmits back every second datagram,
`/A=0` never transmits, and windows alternate so nothing varying with time of
day favours an arm.

* **an event in `/A=2` and not `/A=0`** -> contention is the mechanism.
* **both arms clean at ~177 MB** -> the raw receive path is sound at ~2%, and
  the fault needs something only the mTCP/HTTP path produces. Surprising
  given the NE2000 control, and it would want explaining rather than
  ignoring.

At the time of writing: **44.35 MB clean, zero events** -- a 37% outcome, so
not yet a result.

### 2. Catch one event on the counter pattern

Everything about the displacement is modulo 256 until this happens. `-64`
could be `-320` or `-576`, and the "CH375's 64-byte packet buffer" idea rests
entirely on which. One event on `CNT5M.BIN` reports the true source offset
outright.

0 of 26 counter runs have corrupted against 5 of 44 ramp runs -- p about
0.15, suggestive, unexplained, possibly nothing. It is **not** the counter
hiding the fault: a planted displacement reads back exactly, and a 4 GB
period has no blind spot the way a 256-byte ramp does.

### 1b. DONE: mTCP runs over CDC-ECM

Verified on hardware. `AUTOEXEC.BAT`'s own `USBPKT` came up on the class
path unattended after a power cycle, survived a warm reboot still on ECM,
`PING` got 4 of 4, and 1 MB, 5 MB and 10 MB `HTGET`s all came back with
**zero** mismatches at 23-24 KB/s. CHANGELOG has the detail.

**And the 130 MB sweep came back clean** -- thirteen consecutive 10 MB
downloads, every one verified byte by byte, zero mismatches, and every
driver error counter still at zero over 52,739 bursts. That is a 5%
outcome if the class path shared the vendor path's fault rate, so it is
evidence at roughly the 95% level. CHANGELOG has the table.

**Then it was used at the keyboard: telnet, FTP, HTTP GETs and pings, all
working.** Worth treating as separate evidence rather than more of the
same. FTP opens two simultaneous TCP connections, which nothing here had
tested; telnet is a long-lived stream of tiny packets where latency is felt
instead of averaged away; and a person notices "sluggish", which no counter
in this driver can report -- they all read zero through the broken runs
earlier that day as well as the good ones.

**One thing left open on it:**

* **`longest poll` reads 54.7 ms**, a whole tick at `/R=1`, where the
  vendor path was tuned down to 22. An ECM frame is 24 separate 64-byte
  transactions and a mid-frame pause is waited out on `RX_NAKWAIT`, a
  budget sized for a burst protocol. It did not move over the whole 130 MB
  sweep, which also suggests the counter is saturated rather than measured.
  Nothing has broken because of it -- but bound that wait, the way
  `ecm.pas` bounds its own, before anyone raises the timer rate on this
  path.

**And one tempting conclusion to resist.** The class path shares
`bulk_in`, `ch_read`, the `REP INSB` fast path and the `chip_busy` TX/RX
interlock with the vendor path, so 130 MB clean looks like it excludes the
CH375 read path and points the open corruption fault at the burst parser.
It does not: the corruption was measured on the **AX88179** and this sweep
ran on the **AX88179A**, a different adapter on a different cable. Two
variables moved together. Promising lead, not an exclusion.

**How to re-test it, because the order matters:**

1. **Power-cycle the machine** (`dospower cycle`) or unplug and re-plug the
   adapter. Nothing weaker works -- see the latch in `ADAPTERS.md`. A warm
   reboot does NOT, because the CH375 feeds the adapter off the ISA bus.
2. `USBPKT /S` -- it must say `protocol=CDC-ECM` and `link=UP`. If it says
   `AX88179 vendor`, the device was still latched and nothing after this
   point means anything.
3. `PKTTEST /M=<ours> /I=65 /T=<a live host> /S=8` -- an ARP that is
   answered proves the whole loop in both directions.
4. `SET MTCPCFG=C:\CH375\MTCPAX.CFG` then `PING`, then `HTGET` and check
   the CRC against the table below.

Step 2 is not a formality. Most of the time lost getting here went into
runs that were measuring the vendor path while appearing to measure the
class one.

### 3. Or: the other half of the class work

This is now the better second job, and it is a different kind of work from
chasing the corruption -- so it is a reasonable thing to pick up when the
statistics above need hours of unattended running anyway.

`ecm.pas` proves the protocol on hardware. What it does not do is run inside
an interrupt: `USBPKT` polls the chip from INT 08h, in assembler, with a
budget measured in microseconds, and every Pascal convenience in `ecm.pas`
is unavailable there. The receive half is the easy direction -- ECM carries
**raw frames with no header, trailer, entry array or tiling**, so the entire
AX88179 burst parser and every counter that exists to police it simply have
no counterpart. The transmit half needs the NAK retry that `bulk_out`
already has, plus the zero-length terminating packet.

A useful property: the two back-ends can be chosen at load time from what
the descriptors say, which is what `NETID` already reads. Nothing needs to
be decided by the user.

### 4. Only then, a third chipset

`ADAPTERS.md` has the survey: AX88772, then RTL8152/8153. Not before the
corruption is understood -- a second vendor bring-up on top of an unexplained
receive fault makes both harder to diagnose. Note ECM does not carry this
caveat, because it was written to a published spec rather than reverse
engineered, and its proof was a round trip rather than a byte count.

## Tools

| | |
|---|---|
| `USBPKT /S` | counters, `longest poll`, `bursts whose frames did not tile`, `frames past the frame region` |
| `USBPKT /8` | load with the portable byte loops instead of `REP INSB` |
| `RAMPCHK f` | check a downloaded ramp: where, how much, **altered vs shifted** |
| `RAMPCHK f /K` | the counter pattern -- reports the **exact** source offset |
| `RAMPCHK f /W=n` | write a ramp, so the disk can be tested with no network |
| `USBGET ip name file` | fetch over TFTP on our own stack, mTCP absent |
| `USBVFY ip /A=n /S=n` | verify the receive path with nothing above it |
| `mkramp.py` | generates every fixture, byte-identically |
| `mkblast.py` | the Windows sender for `USBVFY` |
| `USBLINK /V` | bring-up narrated, chip status at every register access |
| `ECMLINK` | CDC-ECM: discover, bring up, print what was READ, then ARP a host and require **that host's** reply. `ECMLINK [@260] [our-ip] [target-ip]` |
| `build.cmd ecm` | unload `USBPKT`, then run `ECMLINK` on the DOS machine |
| `ecmsweep.py` | the 130 MB soak: 13 x 10 MB, each verified byte by byte, stopping on the first bad round so the box is left in the state that produced it. Reads the driver's error counters every round, because a counter moving is evidence even in a round that verifies clean |
| `TICKCHK` | INT 08h and 1Ch rates -- tells you if the PIT is disturbed |

**`mkblast.py --corrupt-every N`** plants the real fault's signature -- 4
bytes from -64 then 158 from +76 -- into one datagram in N. `USBVFY` has to
catch and decode them. Use it whenever the receiver is touched; it caught 42
of 42 after the last rewrite and decoded both displacements exactly, which
is also the only end-to-end proof that the decode works, since no real event
has yet landed on the counter pattern.

**Validate an instrument before believing it, and again after editing it.**
`RAMPCHK` has been re-validated three times against `RAMPOK`/`RAMPSH`/
`RAMPAL`, and `/K` against `CNTBAD`, which plants the real signature and
requires it back. Not ceremony: the first "event" `USBVFY` ever reported was
foreign traffic, decorated with an exact displacement computed from a
sequence number that had overflowed `LongInt` into the negative.

## Things that will bite you

**A clean run proves almost nothing.** At 1 event per 44 MB a 5 MB download
is a 90% chance of looking fine, and two clean runs is 1-in-9 of meaning
nothing. I stopped there once and shipped a false cure. Work out the expected
count before believing a null.

**Do not treat a small clean control as an exclusion.** 15 MB of clean
NE2000 was called an exoneration of mTCP; it was a 71% outcome. It took 165
MB to exclude them properly.

**Say what state the device was in when you measured it.** The AX88179A's
row in `ADAPTERS.md` has now been wrong twice in opposite directions, both
times from a real measurement taken on a device somebody had disturbed --
once reading "receives frames", once "moves no traffic in either
direction", on the same adapter and the same binary. A USB device is
stateful and the state survives your program.

**`ctrl_in` ends a control data stage on a packet shorter than EIGHT.** It
should be `cmp dl, [ep0max]`. On a device whose endpoint 0 carries 64 bytes
an exactly-26-byte descriptor is short for the endpoint but not by that
test, so `ctrl_in` asks for more and gets status 2B. Nothing hits it today
because every descriptor read in the driver asks for an exact length, and
it is left alone because the AX88179 shares that code and is not on the
bench. Fix it with that adapter plugged in, not without.

**`BusUp` leaves the chip retrying NAKs, and you must put it back.**
`ch375.pas` issues `SetRetry($8F)` while enumerating -- right there, because a
device still waking up should be waited for. It is exactly wrong afterwards:
on a data endpoint a NAK means "busy, ask again", and a chip told to retry it
in hardware raises **no interrupt at all**, so every transfer reports `no
interrupt` and a busy endpoint is indistinguishable from a dead one.
`ax179.pas` and `usbpoll.pas` both do `SetRetry($00)` after bring-up;
`ecm.pas` did not, and its first hardware run sent one frame and then failed
every transfer and all forty receive polls. Retry NAKs in software, the way
`usbpkt.asm`'s `bulk_out` does.

**And a chip left on 8F wedges the NEXT program.** It is still grinding on a
transaction after your own wait expired, so it does not answer `CHECK_EXIST`
-- and the next tool prints a completely convincing `No CH375 at 0260h` for a
card that is plainly fitted. Two runs were lost to that before the cause was
obvious. Put the retry policy back from an **exit hook**, not from a line at
the end of `main`: the paths that need it most are the ones that `Halt`
early. `ECMLINK` also resets and re-asks rather than believing the first
failed `CHECK_EXIST`, which is worth copying.

**`doscap` first when the box goes quiet.** A long job makes `dosctl status`
say STALE, which is not a fault. And a job that runs but returns **zero
bytes** means the box is out of file handles rather than that the job failed:
commands still run and print to the console, but the batch cannot open
`OUT.TXT`, so `dosctl` reports "no output, and rc 0" -- which is also exactly
what a missing program looks like. `doscap` showed "Extended Error 4".
`FILES=30` is now in `CONFIG.SYS`; a warm reboot clears it if it recurs.

**Never power cycle unattended.** POST stops at "Press F1 to continue"
because of the CMOS configuration fault, so a cut needs hands. A warm
`dosctl reboot` is safe and takes 20 seconds.

**Broadcast is not free.** `USBVFY` needs it -- nothing on the box answers
ARP while our stack holds only the 0800 handle, so unicast stops being
delivered once the sender's cache lapses, and 9 datagrams arrived in 15
minutes before that was understood. But broadcast reaches every host on the
segment, and here that includes the PicoMEM WiFi interface DOSBridge runs
over: at 40/s the agent could not get its own ARP through and a whole
15-minute window was lost. **12/s is the rate that has proved reliable.** A
static ARP entry on the sender (`arp -s`, needs elevation) would allow
unicast at full rate.

**The listener starts before the sender.** `NetOpen` must ARP the peer before
it can open the IP handle, and a flood already in progress loses that one
frame. The test can destroy its own setup step.

**Never background a `dosctl exec` with a shell ampersand.** The job runs to
completion on the box but the pipe collecting its output dies with the shell,
`dosd` discards a result nobody awaits, and a running DOS job cannot be
cancelled. That cost 75 minutes. Use the harness's own background facility.

**Do not truncate a job's output with `tail`** unless certain you do not need
it. A three-download job piped through `tail -45` lost the first two results,
each of which cost eleven minutes of box time.

**A failed `nasm` run deletes `bin\USBPKT.COM`.** Safe direction, but do not
reach for a binary that is "still there". Adding code to `rx_deliver` is the
likeliest trigger: the conditional jumps in `rxd_ok` reach `rxd_bad`, an 8086
conditional jump is short only, and there is a trampoline above `rxd_ok` for
exactly that.

**Pascal is case-insensitive.** `ACKEVY` and `AckEvy` are one identifier.
That has cost three names here -- see also `InC`/`Inc` and `DdX`/`DDX` in
`CLAUDE.md`.

**Nothing goes at I/O 0260.** `CONFIG.SYS` records why: the Lo-tech EMS board
sat there, which is the CH375's base, and the two fought -- the CH375 read
back `FF` and the receive buffers filled with it. Board and `LTEMM` both
removed 2026-09-08. Demonstrated precedent that bus contention at 0260
corrupts CH375 reads on this machine.

**`AXPROBE`/`USBLINK` is not a prerequisite** and running it first gets in
the way: it leaves the device enumerated, which is the state `USBPKT` then
has to fight. Run `USBPKT` first.

**Never install on INT 60h.** That is the network this machine is
administered over. `USBPKT`, `USBGET` and `USBVFY` all refuse it in code.

**Do not raise `/R` in `AUTOEXEC.BAT`.** It reprograms the PIT and `EDIT`
wedges the machine. `/R=8` is also the leading suspect for one bout of file
handle exhaustion, unproven.

## The verification harness

An HTTP server on the LAN at **192.168.50.46 port 80** serves
`/download/1mb`, `/download/5mb` and `/download/10mb`. `dosd` serves the same
shapes at **8080** under `/f/local/`, which is how the counter file is
available at all.

| | bytes | CRC-32 |
|---|---|---|
| 1 MB ramp | 1,048,576 | `04D0E435` |
| 5 MB ramp | 5,242,880 | `BDBF684D` |
| 10 MB ramp | 10,485,760 | `2B11D791` |
| `CNT5M.BIN`, the counter | 5,242,880 | `0FC93951` |

`RAMPCHK` is about 18 s for 5 MB, because a clean 8 KB block costs one
`CompareByte` against a prebuilt reference rather than 8192 tests; only
failing blocks pay for the per-byte walk. It was 340 s before that.

**Regenerate the fixtures rather than trusting copies:**

```
python mkramp.py --stage C:\dosbridgeDEV\files\local
```

## Two things worth knowing about the harness itself

**Two `dosd` daemons were running for most of 2026-09-10**, started thirty
minutes apart, both bound to UDP 8069, both appending to the same `dosd.log`
so it read as continuous. `SO_REUSEADDR` on the UDP socket allowed it and is
now removed, so a second instance fails to bind and says so.

It matters because it does not look like a Windows problem: two sockets on
one UDP port means each datagram goes to one arbitrarily, so a multi-datagram
TFTP transfer is split between two daemons holding separate state, which
presents as stalled transfers, deploys failing their CRC, and results that
never return. **TCP was unaffected**, so the HTTP corruption measurements
stand -- but the TFTP-based ones (`USBGET`'s runs, its 55 flow restarts, and
one deploy that "arrived corrupt") now have a second candidate explanation
with nothing to do with the driver.

**`USBVFY` was three times slower than an ordinary HTTP download** until a
32-bit multiply was hoisted out of its per-byte loop -- 4.9 KB/s against
12.8 after. If a test here feels slow, price the inner loop against `BENCH`
before blaming the machine. It is an 8 MHz box, but it was not the
bottleneck.

## Two things that want hands at the keyboard

* **`C:\PATH` should be `C:\TOOLS`** in `AUTOEXEC.BAT`. The line reads
  `PATH=C:\PATH;C:\WINDOWS;...`, so the word `PATH` became the first
  directory and `C:\TOOLS` is still not on the path. Everything here calls
  tools by full path, so nothing is blocked.
* **The CMOS configuration.** Until it is set, a power cycle stops at F1 and
  cannot recover the box unattended, which constrains every recovery
  decision. POST code 162 is a configuration/checksum error rather than a
  dead battery, which fits an RTC that keeps the month and day and loses only
  the year. On the PS/2 it is *Set Configuration* from the Reference
  Diskette.
