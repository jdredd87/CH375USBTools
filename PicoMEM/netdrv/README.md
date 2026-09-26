# netdrv -- a faster PM2000.COM

**The PicoMEM's packet driver, `PM2000.COM`, rebuilt to move network data
faster on an NEC V20/V30: up to 27% more throughput on the V30, measured on
both a PicoMEM 2 and a PicoMEM 1, with every downloaded byte CRC-checked.
On a 386 it is the same speed and fixes a buffer over-read.**

**By StevenC and Claude (Anthropic)**, September 2026: StevenC guiding and
testing on his machines, Claude doing the analysis, the code, the builds
and the measurements.

This is the one directory in this project that is *not* original work and
*not* public domain. `orig\` and `src\` are Crynwr packet driver source as
distributed in [ISA-PicoMEM](https://github.com/FreddyVRetro/ISA-PicoMEM)
under `src/drivers/NETWORK`, copyright Russell Nelson / Crynwr Software and
contributors, **GNU GPL version 1** -- see the header of every `.ASM`. The
changes in `src\` are under the same licence.

## Before and after

Original = the shipped `PM2000.COM` 0.5. New = `bin\PM2000.COM`, whose
banner reads `0.5-SC5` and `Optimized by StevenC & Claude`. Both drivers
were run on the same machine in the same session, swapped live, downloading
with mTCP `HTGET` from a server on the LAN (`NETBENCH.BAT`). Where a size
was run more than once, the time is the average. "Faster" is throughput:
how much more data per second.

**NEC V30 + PicoMEM 2**

| | original | new | faster |
|---|---|---|---|
| 1 MB  | 8.9 s  (115 KB/s) | 7.5 s  (137 KB/s) | **+19%** |
| 5 MB  | 40.2 s (127 KB/s) | 32.5 s (158 KB/s) | **+24%** |
| 10 MB | 76.5 s (134 KB/s) | 60.5 s (169 KB/s) | **+27%** |

**NEC V30 + PicoMEM 1**

| | original | new | faster |
|---|---|---|---|
| 1 MB  | 9.3 s  (111 KB/s) | 7.9 s  (130 KB/s) | **+18%** |
| 5 MB  | 41.6 s (123 KB/s) | 34.4 s (149 KB/s) | **+21%** |
| 10 MB | 77.5 s (132 KB/s) | 64.8 s (158 KB/s) | **+20%** |
| 1 MB saved to disk  | 15.6 s | 14.4 s | +8% |
| 5 MB saved to disk  | 75.7 s | 69.0 s | +10% |
| 10 MB saved to disk | 141.7 s | 128.5 s | +10% |

The rows without "saved to disk" download to `NUL`, so they measure the
network alone. Saving to disk gains less because the disk is the PicoMEM
too: writing the file is the card's own SD time, which a packet driver
cannot touch. The 1 MB disk row is the median of 6 runs against 12.

**386SX/25 + PicoMEM 1** -- same speed, as expected

| | original | new | faster |
|---|---|---|---|
| 1 MB  | 3.4 s  | 3.4 s  | same |
| 5 MB  | 15.4 s | 14.5 s | same (one run each) |
| 10 MB | 28.5 s | 28.4 s | same |
| 1 MB saved to disk  | 9.2 s  | 9.3 s  | same |
| 5 MB saved to disk  | 43.9 s | 45.7 s | same (one run each) |
| 10 MB saved to disk | 87.4 s | 86.4 s | same (one run each) |

A 386 (and a 286 or 486) already used the fast `REP INSW` copy in the
original driver, so there was no slow path to fix. For these CPUs the new
driver is a **correctness fix at no cost**: it no longer reads past the end
of each packet (below). The 1 MB and 10 MB rows are averages of 6-12 runs
per driver, taken in turn, so any drift would show; the differences are
well inside the run-to-run spread.

The 386 also shows where the V30's time goes: **the same PicoMEM 1 moves
10 MB in 28 s in the 386 and 65 s in the V30**, so on the V30 the limit is
the CPU running mTCP, not the card or the WiFi. That is why the V30 gained
from a faster copy loop and the 386 does not.

**Every file came through intact.** 1, 5 and 10 MB downloads were CRC-32
checked against the server's copy on both drivers, on both cards in the
V30 and on the PicoMEM 1 in the 386, and the new driver has carried all of
DOSBridge's traffic since -- jobs, results, deploys. Not tested: a 386
with a PicoMEM 2 (same CPU path, different card), a 286 or 486 (no
machines), and a genuine Intel 8086/8088, which runs the original byte loop
unchanged.

## What changed

1. **The V30 was on the slow path.** The driver picks its copy loop with
   Crynwr's shift-count test, and an NEC V20/V30 answers "8086" -- so it
   read the card one byte per `IN`/`STOSB`, although it has the 186's
   string I/O instructions. The new driver asks one more question, `AAD`
   with a base of 11 (Intel answers 11, NEC 10), and on NEC uses
   `REP INSB` / `REP OUTSB`. This is nearly all of the gain.
2. **No register pauses.** The original puts a dummy port-61h read before
   each of ~25 register accesses per packet, for real DP8390 chips. The
   PicoMEM emulates the chip and does not need them (`PM_NoPause` in
   `PICOMEM.INC`; 0 puts them back). Worth 1-2%.
3. **A bug fix on the 286/386 path.** `read_186` read one word past the
   programmed count, and wrote one byte past the buffer, on every
   even-length read. Found reading the code; it had not been seen to break
   anything. Verified on the 386SX: CRC-exact at 1, 5 and 10 MB.

A genuine Intel 8086/8088 still runs the original byte loop unchanged.

**Why it stops here:** after these, removing a quarter of the driver's
register traffic moved the total by 1-2%. What is left per packet is mTCP
on an ~8 MHz CPU, the card's WiFi and the round trips -- nothing a packet
driver can reach. `REP INSW` on the V30 was left alone: the card is 8-bit,
and whether an 8086-class board splits a 16-bit `IN` correctly is not a
given.

## Using it

**The PicoMEM is the boot disk and the machine's only network**, so try it
live before putting it in `AUTOEXEC.BAT` -- in one job, so the result comes
back over the new driver:

```
C:\DRIVERS\PM2000.COM -u 0x60
C:\PMNET\PM2000.COM 0x60
```

If it fails, the machine drops off the network and a reboot brings it back
on the original, because nothing on disk changed. To make it permanent,
keep the original under a name DOS will run -- **not** `PM2000.ORG`, which
COMMAND.COM will not execute, so a swap back to it unloads the driver and
loads nothing -- and copy the new one over:

```
COPY C:\DRIVERS\PM2000.COM C:\PMNET\ORIG.COM
COPY C:\PMNET\PM2000.COM   C:\DRIVERS\PM2000.COM
```

`PKTDRV` tells them apart: the new driver's handler is at `...:03D0`, the
original's at `...:03CE`.

## Measuring it: NETBENCH.BAT

```
CALL NETBENCH.BAT http://<server>:8080/f/netbench LABEL [DISK]
```

Needs a server offering `/1mb`, `/5mb` and `/10mb`, and `C:\WORK\ELAPSED.COM`
from DOSBridge. Appends to `C:\WORK\NB.LOG`: 1 MB twice, 5 MB and 10 MB to
`NUL`, 1 MB to disk, and with `DISK` also 5 and 10 MB to disk, each disk run
followed by its CRC-32. A run that did not get a real `200 OK` is logged
`FAILED`. Always `CALL` it -- run bare from a job, the job never gets
control back.

## Building

```
build.cmd          src\  -> bin\PM2000.COM
build.cmd orig     orig\ -> build\orig\PM2000.COM, and compares it with the
                   shipped orig\PM2000.COM. It must say IDENTICAL
```

The source is TASM/MASM syntax, **assembled by Borland TASM 3.2 on the DOS
machine itself** (`C:\BP\BIN\TASM.EXE`) over DOSBridge -- the assembler that
built the shipped binary, which is why `build.cmd orig` reproduces it byte
for byte. TLINK needs DPMI and cannot run on an 8086-class box, so the
`.OBJ` files are linked on Windows with
[JWlink](https://github.com/Baron-von-Riedesel/jwlink/releases), unpacked
into `tools\jwlink\` (not committed), with `UNDEFSOK` because `TAIL.ASM`
declares an `EXTRN hw_int_no` that nothing defines or uses.
