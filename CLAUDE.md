# CLAUDE.md

Instructions for Claude Code in this repository.

**Everything here is built and tested through DOSBridge.** Its `CLAUDE.md`
(`C:\dosbridgeDEV\CLAUDE.md` on this machine, `DOSBRIDGE` points at it) holds
the rules that govern every DOS machine these tools run on -- the hard
constraints, how to reach the boxes, what hangs them. Read it first; nothing
here repeats it.

## Credit StevenC AND Claude on anything new

StevenC's standing rule, 2026-09-23: *"Make sure Claude is mentioned too in
anything we do. I am guiding you, but you are doing the heavy lifting."*

Every new program banner, source header, README and CHANGELOG entry names
both, in the form the PicoMEM driver set:

```
Optimized by StevenC & Claude: ...                          (a banner line)
Written by **StevenC** and **Claude** (Anthropic): ...      (a README)
```

* A `Co-Authored-By: Claude` commit trailer does not count on its own -- the
  credit belongs where a reader sees it.
* **Every binary was rebuilt with the credit on 2026-09-24** and deployed
  to the V30 (`C:\CH375\<PROJECT>\`, all 82 CRC-checked). Versions were
  not bumped for it -- no code changed -- and each CHANGELOG says so. A
  new banner names both from the start.
* Not credited, on purpose: `CH375Mouse/tools/MNASMFIX.COM` (someone
  else's), `PicoMEM/netdrv/orig/` (the untouched upstream the build is
  checked against), and `CH375Net/bin/cbtest.exe` (no source here).
* Everything else is public domain (the Unlicense) and needs no credit at
  all, legally -- this is about saying truthfully who did the work.
  `PicoMEM/netdrv/` is the exception: Crynwr GPL source, whose notices must
  stay.
