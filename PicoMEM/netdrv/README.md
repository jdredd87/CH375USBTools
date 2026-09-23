# netdrv -- a faster PM2000.COM

**The PicoMEM's packet driver, `PM2000.COM`, rebuilt so an NEC V20/V30 moves
packet data with `REP INSB`/`REP OUTSB` instead of one byte per loop. On the
V30 that is 21-26% more network throughput, measured, with every byte checked.**

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

The version string is `0.5-SC1`, so a loaded copy says which it is.

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

## Not changed, and why

* **`pause_`** -- a `push ax / in al,61h / pop ax` before every NIC register
  access, for real 8390s that need four bus clocks between chip selects. The
  PicoMEM emulates the chip and does not, but it is about 25 per packet, a
  few microseconds each: under 1% of a packet's time. Not worth a change to
  every register access for.
* **`REP INSW` on the V30.** The card is 8-bit; whether a 16-bit `IN` to it
  is split correctly depends on the motherboard's bus logic, which on an
  8086-class board is not a given. The bus cycles are the same count either
  way, so the win would be small.
* **A latent bug on the 286/386 path, found reading it**: `read_186` does
  `inc cx / shr cx,1 / jnc`, and the carry after that is set when the
  original count was *even* -- so every even-length read fetches one extra
  word past the programmed DMA count and stores one byte past the buffer.
  It has not been seen to break anything, and fixing it is a 386 test,
  which has not been done yet.

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
two lines with the paths swapped put the original back without a reboot.
