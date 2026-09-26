# netdrv -- a faster PM2000.COM

**The PicoMEM's packet driver, `PM2000.COM`, rebuilt so an NEC V20/V30 moves
packet data with `REP INSB`/`REP OUTSB` instead of one byte per loop. On the
V30 that is 21-26% more network throughput, measured, with every byte checked.**

**By StevenC and Claude (Anthropic)**, 2026-09-23: StevenC guiding and
testing on his machines, Claude doing the analysis, the code, the builds
and the measurements.

This is the one directory in this project that is *not* original work and
*not* public domain. `orig\` and `src\` are Crynwr packet driver source as
distributed in [ISA-PicoMEM](https://github.com/FreddyVRetro/ISA-PicoMEM)
under `src/drivers/NETWORK`, copyright Russell Nelson / Crynwr Software and
contributors, **GNU GPL version 1** -- see the header of every `.ASM`. The
changes in `src\` are under the same licence.

## What was slow

`PM2000.ASM` has two copy paths. A 186-or-later CPU gets `REP INSW`; anything
else reads the NE2000 data port one byte at a time:

```
read_loop:  in al,dx / stosb / in al,dx / stosb / loop read_loop
```

The driver decides with the Crynwr shift test from `TAIL.ASM` -- shift by 33
and see whether the count was masked -- and **an NEC V20/V30 answers "8086"**.
Checked on the V30 with `probe\SHFTTST.COM`, which runs exactly that test:
`is_186=0`. So the V30 was on the slow path, although it has every one of the
186's string I/O instructions.

## What changed

Three files, and nothing on any other CPU's path:

| | |
|---|---|
| `HEAD.ASM` | two new flags, `is_nec` and `has_ins` |
| `TAIL.ASM` | after the shift test, an 8086 answer is asked one more question: `AAD` with a base of 11. Intel honours the base and answers 11; NEC ignores it and answers 10 -- the same probe `starter/cpu.pas` in DOSBridge uses. The banner says `NEC V20/V30 processor (REP INS/OUTS)` when it fires |
| `PM2000.ASM` | `block_input` and `block_output` use `REP INSB` / `REP OUTSB` when `has_ins` is set and `is_186` is not. The byte count is rounded up to even first, exactly as the old loop did, so the card sees the same bus traffic |

The version string is `0.5-SC1` (`SC2` and `SC3` since; see below), so a loaded copy says which it is.

A genuine 8086/8088 still takes the byte loop, and a 186/286/386 still takes
`REP INSW` -- both byte-identical to the original code.

## Measured -- NEC V30, 2026-09-23

HTGET from dosd's HTTP server on the LAN, output to `NUL` so the disk is not
in it, except the last row. `NETBENCH.BAT` is the harness; both drivers were
run on the same machine in the same hour, swapped live with `-u`.

| | original 0.5 | SC1 | |
|---|---|---|---|
| 1 MB  | 8.7 / 8.9 / 9.1 / 8.9 s  (~115 KB/s) | 7.5 / 7.3 / 7.5 / 7.3 s  (~139 KB/s) | **+21%** |
| 5 MB  | 40.2 / 39.6 / 40.9 s  (~127 KB/s) | 33.2 / 32.7 s  (~156 KB/s) | **+22%** |
| 10 MB | 76.5 s  (~134 KB/s) | 60.9 s  (~168 KB/s) | **+26%** |
| 1 MB to disk | 13.6 / 13.5 / 13.4 s | 12.1 / 12.4 s | +10% |

(One original 1 MB run took 10.8 s; it is left out of the average as an
outlier, and including it only widens the gap.)

The disk row gains least because the disk is the PicoMEM too: writing the
file is the same card's time, and this change does not touch it.

**Integrity**: a 1 MB and a 10 MB file downloaded through SC1 came back with
CRC-32s `DD7975E3` and `C959DFA4`, identical to the source files. Every
DOSBridge job while SC1 was loaded -- the jobs, their results, deploys --
also travelled over it.

## SC2, and the 386SX

`0.5-SC2` also fixes the `REP INSW` bug described under "Not changed" below:
the extra word read is gone, since the rounded-up count already covers an
odd byte. On the V30 it measures the same as SC1
(7.4 s / 32.5 s / 61.2 s for 1 / 5 / 10 MB) with a 10 MB download CRC-exact,
as expected -- the V30 never takes that path.

**The 386SX test is incomplete.** SC2 loaded on it (`1445:03D0`, two bytes
past the original's handler -- the two new flags) and carried its polls and
job results, so the fixed `REP INSW` path does move packets both ways. But
its CRC-checked download never came back, and no timing run finished: the
machine's PicoMEM 1 was failing through the afternoon and then **died
outright on 2026-09-23**. A 286 or 486 takes the same path, so a 386 with a
working card is still the test that covers all three.

## SC3: the register pauses, and where the ceiling now is

`pause_` put a `push ax / in al,61h / pop ax` before every NIC register
access -- 197 of them in the source, about 25 per received packet -- for real
DP8390s, which need four bus clocks between chip selects. The PicoMEM
emulates the chip and answers each cycle itself, and `REP INSB` was already
hitting its data port back to back without them. `PM_NoPause` in
`PICOMEM.INC` now switches them off (0 restores the original timing); the
binary is 344 bytes smaller.

**SC4 and SC5 are SC3 plus attribution, and SC5 is the build in `bin\`.**
Its banner has a second line, `Optimized by StevenC & Claude: REP INS/OUTS
on NEC V20/V30, no NIC pauses`, and `PM2000.ASM` has a header note listing
the changes and who made them (SC4 named StevenC alone). The Crynwr and
PicoMEM notices are all still there, as the GPL requires. No code changed,
so SC3's numbers are SC5's; it has been the V30's boot driver since
2026-09-23 (CRC `5C800029`).

Measured on the V30, SC3 / SC2 / SC3 swapped live in the same half hour:

| | SC2 | SC3 | SC3 again |
|---|---|---|---|
| 1 MB  | 7.5 / 7.4 s | 7.5 / 7.5 s | 7.5 / 7.3 s |
| 5 MB  | 33.0 s | 32.5 s | 32.5 s |
| 10 MB | 61.5 s | 60.7 s | 60.2 s |

**About 1-2%**, the same direction at every size that is long enough to
resolve it. Real, and as small as the arithmetic said. A 10 MB download
through SC3 came back CRC-exact (`C959DFA4`), after about 45 MB of benchmark
traffic and every bridge job of the evening had crossed it.

That is the more useful result: **the driver is no longer where the time
goes.** Removing a quarter of its register traffic moved the total by the
width of the noise, so what remains -- about 8.5 ms per full packet at
~170 KB/s -- is mTCP on a ~8 MHz CPU, the card's WiFi bridge, and the round
trips, none of which a packet driver can touch. The 386SX makes the same
point from the other side: in the V30's room, with a CPU four to five times
faster, it managed 1 MB in 24.5 s against the V30's 7.4 -- on a PicoMEM 1
that died hours later, but the CPU was plainly not what limited it.

## SC5 on a PicoMEM 1, 2026-09-25

Everything above was measured with the V30's PicoMEM 2. On 2026-09-25 a
PicoMEM 1 (StevenC's "1.11 board", BIOS 2025-11-02 by `PMINFO`) went into
the V30, so the driver was run on the other card generation with the CPU
held constant. Both drivers twice, swapped live, same `NETBENCH`, which now
also writes 5 and 10 MB to disk and CRCs every saved file:

| | shipped 0.5 | SC5 | |
|---|---|---|---|
| 1 MB to `NUL`  | 9.2 / 9.3 s | 7.8 / 7.9 s | **15%** |
| 5 MB to `NUL`  | 41.0 / 42.1 s | 34.3 / 34.4 s | **19%** |
| 10 MB to `NUL` | 76.2 / 78.7 s | 64.8 / 64.8 s | **18-20%** |
| 1 MB to disk   | 15.6 s median of 6 | 14.4 s median of 12 | **~5%** |
| 5 MB to disk   | 75.7 s | 68.4 / 69.5 s | 9% |
| 10 MB to disk  | 141.7 s | 128.0 / 128.9 s | 10% |

The 1 MB-to-disk row was noisy in the first runs (15.6 / 19.7 against
13.7 / 14.7 / 18.1 s), so it was run again the same evening: six runs on
SC5, six on the shipped driver, six on SC5 again, in one job with live
swaps so any drift would show. Shipped: 15.3 16.2 14.5 15.9 16.8 14.7 s.
SC5: 18.4 15.4 14.4 15.3 16.2 14.0, then 14.1 14.3 15.0 13.8 14.3 14.4 s.
Median 15.6 against 14.4 s (7.7%), mean 15.6 against 15.0 s (3.9%), best
14.5 against 13.8 s (4.8%) -- **about 5%**, real but inside the 1-2 s a
single run wanders by. The shorter the write, the less the driver shows:
most of a 1 MB disk run is the card writing its own SD card.

**Every disk run on both drivers was CRC-exact** against the server copy
(`04D0E435`, `BDBF684D`, `2B11D791`). SC5 is the boot driver on that SD card
now too, and the bridge's jobs have run over it since.

The PicoMEM 1 is a little slower than the PicoMEM 2 through the same driver
(10 MB in 64.8 s against 60.2 s), and SC5's lead is a little smaller on it
-- consistent with the section above: what is left per packet is the card
and mTCP, not the copy loop. **No further driver change is proposed.**
Nothing measured points at the driver any more, and the disk rows are the
card's SD writes, which a packet driver cannot reach.

Two things this run found that are not the driver, and both cost time:

* **A 10 MB download to disk "took twelve and a half minutes".** It took
  128 s. The rest was DOSBridge's `HD` computing the file's CRC at 16 KB/s
  afterwards, in the same job, so the job looked like a stalled transfer.
  `HD`'s loop is assembly now, four times faster (`docs/tools.md` over
  there). Time a transfer on its own, and CRC it separately.
* **The first run's timings were all ~1.2 s -- 404s, counted as passes.**
  The payload directory had gone from dosd's tree, and HTGET's exit code is
  20-29 for a 2xx but 45 or more for a 404, so "20 or more" passed both.
  `NETBENCH` now requires 20-29, and it uses no `SET` and no pipe: on a box
  whose 256-byte environment is full, a `SET` fails, and a pipe fails
  silently whenever `%TEMP%` is not a real directory.

## Not changed, and why

* **`REP INSW` on the V30.** The card is 8-bit; whether a 16-bit `IN` to it
  is split correctly depends on the motherboard's bus logic, which on an
  8086-class board is not a given. The bus cycles are the same count either
  way, so the win would be small.
* **A latent bug on the 286/386 path, found reading it** -- fixed in SC2,
  above: `read_186` did `inc cx / shr cx,1 / jnc`, and the carry after that
  is set when the original count was *even* -- so every even-length read
  fetched one extra word past the programmed DMA count and stored one byte
  past the buffer. SC1 left it alone; it had not been seen to break
  anything.

## Building

```
build.cmd          src\  -> bin\PM2000.COM
build.cmd orig     orig\ -> build\orig\PM2000.COM, and compares it with the
                   shipped orig\PM2000.COM. It must say IDENTICAL
```

The source is TASM/MASM syntax, so it is **assembled by Borland TASM 3.2 on
the DOS machine itself** (`C:\BP\BIN\TASM.EXE`) over DOSBridge -- the same
assembler that built the shipped binary, which is why `build.cmd orig`
reproduces it byte for byte. NASM cannot read this syntax, and JWasm can but
picks shorter encodings, so its output differs from the shipped binary and
proves nothing about the toolchain.

TLINK is a DPMI program and cannot run on an 8086-class box, so the three
`.OBJ` files come back to Windows and are linked with
[JWlink](https://github.com/Baron-von-Riedesel/jwlink/releases) into
`tools\jwlink\` (not committed). One wrinkle: `TAIL.ASM` declares
`hw_int_no` `EXTRN` and nothing defines it; TASM drops unreferenced
externals so TLINK never saw it, JWlink does, and the link runs with
`UNDEFSOK`. Nothing references it.

**Never call a batch variable `ZIP`.** Info-ZIP reads `%ZIP%` as default
options, so `set ZIP=zip.exe` made every zip quietly write an archive called
`zip.exe` and not the one asked for.

## Trying it on a machine

**The PicoMEM is the boot disk and this is the machine's only network**, so
do not put it in `AUTOEXEC.BAT` until it has run on that machine. Swap it
live instead -- one job, so the result comes back over the new driver:

```
C:\DRIVERS\PM2000.COM -u 0x60
C:\PMNET\NEW\PM2000.COM 0x60
```

If the new one fails, the machine drops off the network and a power cycle
brings it back on the original, because nothing on disk changed. The same
two lines with the paths swapped put the original back without a reboot --
**provided the original has a name DOS will execute.** Once it has been
kept aside as `PM2000.ORG`, `C:\DRIVERS\PM2000.ORG 0x60` runs nothing:
COMMAND.COM only runs `.COM`, `.EXE` and `.BAT`, so on 2026-09-25 that swap
unloaded the driver and loaded no replacement, and the box was off the
network until it was rebooted. Keep a runnable copy -- the 386SX's SD card
has `C:\PMNET\ORIG.COM` -- and swap back to that.

## NETBENCH.BAT

```
CALL NETBENCH.BAT http://<server>:8080/f/netbench LABEL [DISK]
```

Appends one line per run to `C:\WORK\NB.LOG`: 1 MB twice, 5 MB and 10 MB
to `NUL`, 1 MB to disk, and with `DISK` also 5 MB and 10 MB to disk. Every
disk run is followed by its `crc32` line from `C:\TOOLS\HD.EXE`. A run that
did not get a 2xx is logged `FAILED`. It needs `C:\WORK\ELAPSED.COM` from
DOSBridge, and `CALL` -- run bare from a job, the job never gets control
back.
