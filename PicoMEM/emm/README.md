# emm -- the PicoMEM's EMS driver and UMB manager, faster, fixed and smaller

**`PMEMM` r01-SC2**: the PicoMEM's EMS driver rebuilt with a fast path for
the call EMS programs make in their inner loops, word-wide memory moves,
and **seven bugs fixed** -- the worst of them corrupting every EMS move
that crossed a 16 KB page -- and its move made to let interrupts in. **`UMBSC`**: the `USE!UMBS` upper memory
manager, rebuilt to take **no conventional memory at all** (it was 224
bytes).

> [!CAUTION]
> ## UNOFFICIAL, MODIFIED DRIVERS -- NOT THE PICOMEM'S OWN
>
> Neither driver here is made, endorsed, reviewed or supported by the
> PicoMEM's author or the ISA-PicoMEM project. `PMEMM` r01-SC2 is our
> modification of the source that project distributes; `UMBSC` is our own
> rewrite of a public-domain driver. The PicoMEM's own `PMEMM.EXE` and
> `USE!UMBS.SYS` are what to use if in doubt, and **please do not report
> problems with these builds to the PicoMEM project** -- open an issue here
> instead. The banners read `r01-SC2` / `Optimized by StevenC & Claude` and
> `UMBSC 2.2-SC1` so they cannot be confused with the originals.
>
> **Both load from `CONFIG.SYS`, and the PicoMEM is the boot disk.** Have a
> boot floppy before trying either.

**By StevenC and Claude (Anthropic)**, September 2026: StevenC guiding and
testing on his machines, Claude doing the analysis, the code, the builds
and the measurements.

## What is here

| | |
|---|---|
| `orig\` | `PMEMM.ASM` and `PMEMM.INC` as the ISA-PicoMEM tree has them, with the few edits that make them build (below), `LTEMM.MAC` reconstructed, and the shipped `PMEMM.EXE`. `build.cmd orig` reproduces that binary's load image **byte for byte** |
| `src\` | `PMEMM` r01-SC2. Every change is marked `SC:` in the source |
| (UMBSC) | moved to DOS Bridge, `extras/umbsc` -- see below |
| `test\emstest.pas` | `EMSTEST.EXE`: a behaviour test of every EMS function, then a benchmark. Runs on the DOS machine against whatever driver is loaded |
| `test\emuems.py` | the same behaviour test, run against a driver **binary** in an 8086 emulator on Windows -- see below |

## PMEMM r01-SC1

### The bugs

All five are in the original `PMEMM.EXE` as shipped, and all were found by
`EMSTEST` on the V30 or by `emuems.py`, then confirmed in the source.

1. **Function 57h (move/exchange memory region) corrupted anything that
   crossed an EMS page.** When the conventional side was the source, the
   pointer for the next piece advanced by 64 KB *times* the length of the
   piece rather than by the length: `Add32 [bp].zero_low,0`, arguments in
   the wrong order, where the destination side had the correct
   `Add32 0,[bp].zero_low`. On the V30, a 16385-byte move went wrong at
   byte 16384 exactly; a 40001-byte move starting at page offset 16383 went
   wrong at byte 1.
2. **57h, EMS to EMS at different offsets, lost its place.** A piece that
   ended because the *other* side reached a page boundary left this side's
   offset unstored, so the next piece re-read the same bytes.
3. **57h, overlapping moves upwards, restored the wrong page map.** The
   page map was saved *after* the backward-copy setup had already mapped
   pages, and with the direction flag set, so the "restore" put back a
   scrambled map.
4. **Function 56h subfunction 1 (alter map and call, by segment) always
   failed with 8Bh.** It converted the segment to a page number and then
   read the segment back over it.
5. **Functions 44h and 50h compared only the low byte of the logical page
   number.** Page 257 of a 64-page handle was accepted as page 1 of the
   page list plus 512 bytes, and mapped whatever was there, instead of
   failing with 8Ah.

EMS games mostly use 44h and never meet any of these; 57h is what disk
caches, RAM disks and some loaders use.

### What is faster

1. **44h has a fast path** at the top of INT 67h. It is the call games make
   per frame, per sprite, per sound buffer, and the original ran it through
   the full frame every function gets: 50 bytes of work area, eight pushes,
   a table dispatch, a `MUL` to index the page table and eight pops. The
   fast path saves four registers and does the lookup with shifts. Every
   error, and unmapping, falls through to the original code, so every error
   code is still exactly the original's.
2. **57h moves a word at a time** (`REP MOVSW` and an odd byte), and
   exchanges a word at a time. On the V30's 16-bit bus that is half the
   bus cycles and half the instructions.
3. **57h goes backwards only when it has to.** The original copied
   backwards, **a byte at a time**, for every move whose source was below
   its destination, overlapping or not -- conventional to conventional
   upwards, or EMS to a later page of the same handle. Now only a real
   overlap goes backwards.
4. **No `MUL` anywhere on the mapping path** (50h, 55h, 56h, 57h and the
   rest), and a shorter dispatch.
5. **Boot prints the page counter every 16 pages** instead of all 255,
   through DOS, with `/n`. (`/q` still silences it completely.)

**Measured on the V30**, 2026-09-27, `EMSTEST /B`: each driver loaded from
`CONFIG.SYS` with `DEVICEHIGH` (so both run from the card's upper memory),
each run straight after a boot, two seconds per row.

| per second | original `PMEMM.EXE` | r01-SC1 | |
|---|---|---|---|
| 44h map, page changes | 4,594 | **6,665** | **+45%** |
| 44h map, same page | 4,788 | **7,506** | **+57%** |
| 40h status -- dispatch alone | 8,477 | 8,606 | +2% |
| 50h map 4 pages at once | 1,132 | 1,100 | -3% |
| 4Eh get + set page map, a pair | 1,407 | 1,407 | same |
| 47h + 48h save + restore, a pair | 1,472 | 1,472 | same |
| 57h move 16 KB conventional to EMS | 576 KB/s | **672 KB/s** | **+17%** |
| 57h move 16 KB EMS to conventional | 592 KB/s | **672 KB/s** | **+14%** |
| 57h move 16 KB EMS to EMS | 560 KB/s | 560 KB/s | same |
| 57h exchange 16 KB | 576 KB/s | 560 KB/s | same |
| 57h move 16 KB conventional to conventional | 848 KB/s | **1,648 KB/s** | **+94%** |
| 57h move 16383 bytes, odd, to EMS | 592 KB/s | 576 KB/s | same |

Where it did not move, the card is the limit rather than the driver: EMS
to EMS reads and writes the PSRAM behind the window on both sides, and no
copy loop makes that faster. Conventional to conventional has no card in
it, and doubled. The 50h row's 3% is within what a two-second sample
varies by; it does no more work than before and was not a target. **And
the original failed 6 of `EMSTEST`'s data checks on the machine; r01-SC1
fails none.**

### Memory

r01-SC1 is **144 bytes bigger** resident (6,976 against 6,832), all of
it the 44h fast path and the fixes. It loads high, so this is upper memory,
of which the V30 has 45 KB free. The tables it carries -- 64 handles with
8-byte names, a word per page twice over -- are where the rest goes, and
halving them was judged not worth the risk to a boot driver for UMB bytes
nobody is short of.

**Loaded low it is 2.2-2.6x faster again** (2026-09-28, V30, `EMSTEST`
straight after each boot; the behaviour transcript identical, CRC
`90046ADC`): 44h map 6,632 -> 16,307 calls a second, 40h 8,606 -> 18,604,
50h 1,100 -> 2,798, 4Eh 1,407 -> 3,284, 47h/48h 1,472 -> 3,785.  Code runs
~2.4x slower out of the PicoMEM's upper memory, and every per-call
function is mostly the driver's own code; the 16 KB moves are the card's
PSRAM either way and gain only ~5%.  It costs 6,992 bytes of conventional
memory, and the V30 now loads it with `device=` rather than `devicehigh=`.
`C:\dosbridgeDEV\projects\dostune` has the comparison.

### Behaviour: identical except for the fixes

`emuems.py` runs the *real binaries*, original and new, in an 8086
emulator (Unicorn) against a model of the PicoMEM's EMS hardware -- four
16 KB windows whose page registers are I/O ports, two windows showing one
page really being the same memory -- through ~200 checks: every function
and subfunction the driver has, the error codes, the registers each call
must preserve, 57h in all four directions with odd lengths, odd offsets,
page crossings and overlap both ways, reallocation up and down past
another handle, 55h and 56h jumping and calling into real code.

The two transcripts differ **only** in the lines the fixes change:

```
original  13 data checks failed     r01-SC1  0 data checks failed
44 log 256+1 H1    AH=00            44 log 256+1 H1    AH=8A
57/00 c->e check   0 first bad 1    57/00 c->e check   1
57/00 overlap fwd  AH=92 win 0      57/00 overlap fwd  AH=92 win 1
56/01 map+call seg AH=8B            56/01 map+call seg AH=00
...
```

and the emulator was checked against the machine first: on the original
driver it fails the same checks, at the same byte, as `EMSTEST` did on the
V30.

### Building it

```
build.cmd          src\  -> bin\PMEMM.EXE and bin\PMEMM.SYS
build.cmd orig     orig\ -> build\orig\, and compares with the shipped EXE
```

The same toolchain as `..\netdrv`: Borland TASM 3.2 on the DOS machine
over DOSBridge, JWlink here. The original was assembled in **one pass**
(its forward jumps carry `NOP` padding), so `orig` builds without `/m`;
`src` uses `/m2`.

What `orig\` needed to build at all, none of which changes the binary:
`LTEMM.MAC` is missing from the ISA-PicoMEM tree and was reconstructed
from the shipped code (every macro expansion matches it); `0xAAh`-style
constants TASM rejects; an unterminated string; one label spelled two
ways; and three messages and one `CBW` that differ between the source and
the binary it supposedly built. With those, the load image and entry point
are identical to the shipped `PMEMM.EXE`.

**`bin\PMEMM.SYS`** is the same driver as a flat file: the load image of
the EXE, which has no relocations and its device header at offset 0.
`CONFIG.SYS` takes either. **Do not test it with `DEVLOAD`**: loading
`PMEMM` with `DEVLOAD` hung the V30 twice -- the original as well as
ours, as `.EXE` and as flat `.SYS` -- and each needed a power cycle. Why
was not chased: booting it from `CONFIG.SYS` works, and is how it was
tested.  **A lead, 2026-09-28**: on the V30 `DEVLOAD` 3.25 refused
*every* driver before calling it -- "free drive letter not found, increase
LASTDRIVE" -- and hung once more with `/V`, loading DOS Bridge's XMSSC,
whose init had never run.  So the hang may be `DEVLOAD`'s and not the
driver's.  With `LASTDRIVE=G` in `CONFIG.SYS` (there since that evening)
it calls drivers again -- and **`DEVLOAD /V`, which DOS Bridge's `dosdrv`
used, hangs the V30 by itself**, with a driver that does nothing.  So both
`PMEMM` hangs under `DEVLOAD` were very likely `/V`'s.  `PMEMM` under plain
`DEVLOAD` has not been retried.

### r01-SC2: two more fixes, 2026-09-28

Both found while building DOS Bridge's `extras/xmssc` (an XMS driver on top
of this one), both in the original `PMEMM.EXE` as well.  The banner reads
`r01-SC2`.

1. **57h held interrupts off for the whole move.**  The INT 67h entry
   (`int67_full`) clears the interrupt flag and `func24`, the move, never
   set it again -- every other function starts with `STI`; this one had
   none.  So a long move delayed every interrupt by its whole length -- 23
   ms for 16 KB between conventional memory and EMS, ~35 ms EMS to EMS, ~100
   ms for a 16 KB exchange -- and past ~27 ms **the V30 loses BIOS clock
   ticks** (`C:\dosbridgeDEV\docs\hardware.md`).
   **Now** a move goes in pieces of at most 4 KB, and between pieces
   interrupts are let in -- with the caller's page map put back in the two
   windows the move borrows first, so an interrupt routine sees the frame
   as its program left it.  `f24_data`, where the move keeps that map, is
   one variable for everyone, and that is why this is safe: a 57h made by
   an interrupt routine in the window saves the same map there, so ours is
   still right when it returns.  Interrupts now wait ~9 ms at most.
2. **A window nobody had mapped came back mapped to page 0.**  The card
   disables a window with FFh (`DIS_EMS`), but `ramchk` started every
   window's record at logical page 0 -- and so did `func29` (5Ch, prepare
   for warm boot), which therefore *mapped* page 0 into every window
   instead of disabling them.  A saved and restored page map (4Eh, 47h/48h,
   the end of every 57h) then wrote that 0 to the card.  Found on the V30
   straight after a boot: the first move after power-on changed a window
   from FFh to 00h.  Both now record `DIS_EMS`; an original left over from
   the Lo-tech source, which disabled with 0.

**Measured on the V30** after the change (`EMSTEST`, straight after a boot):
the behaviour transcript is **`90046ADC`, the same as r01-SC1's**, 0 data
checks failed.  The per-call functions are unchanged (44h 16,307 a second).
The 57h rows, and why two of them fell:

| 57h, 16 KB | r01-SC1 | **r01-SC2** | |
|---|---|---|---|
| conventional <-> EMS | 704 KB/s | **672** | 4 pieces now: ~4.5% for bounded interrupts |
| EMS to EMS | 640 | **416** | the SC1 figure was **lost ticks, not speed**: two windows run at ~445 KB/s timed by the PIT |
| exchange | 576 | **160** | the same: the exchange loop is a word at a time, and SC1 held interrupts off ~100 ms per call |

**The `EMS->EMS` and exchange figures in the tables above are therefore
inflated**: they were timed by the BIOS tick on a driver that lost ticks.
The conventional <-> EMS moves (23 ms) were not.

`test\emuems.py` gained two checks for the second fix -- a never-mapped
window restored as disabled, and 5Ch leaving every window disabled: r01-SC2
passes them, r01-SC1 fails both, and the original now fails 15 data checks
(the 13 above and these two).  Its transcript is otherwise the same as
r01-SC1's line for line.

### Known issue

**When it cannot install, it stays loaded**: with no EMS to be had (on a
PicoMEM 1 whose configuration has EMS off, seen on a 486 on 2026-09-28) it
prints "Installation failed - No EMS available", keeps 2,192 bytes and its
`EMMXXXX0` device, and leaves INT 67h hooked -- every function then answers
80h (EMS software malfunction), and nothing touches a port.  That is the
original's design, and harmless, but a program that finds `EMMXXXX0` will
think there is EMS until it asks.  Discarding the driver instead would need
the INT 67h vector it replaced saved first (`emminit` does not).

## UMBSC 2.2-SC1

**UMBSC has moved to DOS Bridge** (2026-09-27): it is a DOS tool for any PC
with upper memory and no 386 memory manager, not a PicoMEM one, so its
source, its emulator test and its write-up now live in the DOS Bridge
repository as an optional extra, `extras/umbsc`, and ship in the DOS Bridge
kit -- https://github.com/jdredd87/DOSBridge.  That is its only copy; this
section used to hold it.

In short: `USE!UMBS.SYS` rebuilt so DOS discards the driver and its 125
resident bytes live in upper memory -- 224 bytes of conventional memory back,
the same answers, the same blocks in the same order.  The V30's install
below still uses it.

## Status

**Now, 2026-09-28: r01-SC2** -- `C:\DRIVERS\PMEMMSC.SYS`, CRC
`BAC75327`, 9,151 bytes, loaded low (7,040 bytes resident); r01-SC1 is kept
beside it as `PMEMMSC.S1`.  The V30's whole `CONFIG.SYS` is DOS Bridge's
`projects\dostune` variant `xms2`, which also loads DOS Bridge's XMSSC on
top of this driver.  EMSTEST straight after a boot: transcript `90046ADC`,
0 data checks failed.

**Both were installed on the V30, 2026-09-27** -- `PMEMMSC.SYS` (CRC
`6052BD1C`) and `UMBSC.SYS` (`C80F0E0C`) in `C:\DRIVERS`, from this
`CONFIG.SYS`:

```
DOS=UMB
FILES=30
BUFFERS=20
REM Device=c:\drivers\USE!UMBS.SYS C800-D000 D800-E000
Device=c:\drivers\umbsc.sys C800-D000 D800-E000
REM Devicehigh=c:\drivers\pmemm.exe /n
Devicehigh=c:\drivers\pmemmsc.sys /n
devicehigh=c:\dos\ansi.sys
```

One at a time, each followed by a reboot, `MEM /C` and `EMSTEST`, so a
failure would have named its line: `PMEMMSC` first, then `UMBSC`. The
`CONFIG.SYS` before them is kept as `C:\CONFIG.SC0`. Both boots came
straight back (16 and 20 seconds).

`MEM /C`, before and after:

| | before | after |
|---|---|---|
| `USE!UMBS` in conventional memory | 224 bytes | **gone** |
| conventional memory free | 575,472 | **575,696** (+224) |
| largest executable program | 575,376 | **575,600** (+224) |
| upper memory, total | 65,552 | 65,424 (-128: `UMBSC`'s resident part) |
| the EMS driver, in upper memory | 6,848 | 6,992 (+144) |
| loaded high | DOSKEY, PM2000, PMEMM, ANSI | the same four |

(`BUFFERS` came down from 40 to 20 afterwards, a separate change with its
own reboot; that is another 10,640 bytes of conventional memory and has
nothing to do with these drivers. The table is before it.)

`EMSTEST` with both in: `data checks failed: 0`, the same transcript CRC
(`90046ADC`) as with `PMEMMSC` alone, and the benchmark above.
