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
* **Banners already compiled into shipped drivers stay as they are** until
  that driver next changes for its own reasons (`USBKBD 1.7.1 -- StevenC`,
  `FOSSIL 0.1.0 -- StevenC`, ...). Rebuilding a driver for a credit line alone
  changes a binary that is installed on real machines. When one does change,
  its banner gains Claude in the same release.
* **A README that quotes a banner is quoting real output**, so it stays as
  printed until the binary changes.
* Everything else is public domain (the Unlicense) and needs no credit at
  all, legally -- this is about saying truthfully who did the work.
  `PicoMEM/netdrv/` is the exception: Crynwr GPL source, whose notices must
  stay.
