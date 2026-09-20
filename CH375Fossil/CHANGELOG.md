# Changelog

CH375Fossil -- StevenC -- https://github.com/jdredd87/CH375USBTools

The version lives in `ver_str` in `src/fossil.asm` and nowhere else. A
release is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## Unreleased

**Verified on a 386, and one latent bug fixed on the way.**

`fosapi`, `fosbbs` and `fostest` cleared their register records with
`FillChar` before every `Intr($14, ...)`, which also cleared the FLAGS --
and FPC's `Intr` loads `Registers.Flags` into the CPU before the interrupt.
A handler that ends in `IRET` then hands interrupts back DISABLED, the BIOS
tick at 0040:006C stops, and every wait in this unit -- all of which are
bounded by that tick -- waits for ever. `FOSSIL.COM` re-enables them
itself, so nothing here ever showed it, but FSC-0015 says nothing about the
interrupt flag and a driver that simply IRETs would freeze the clock of
every program here. 43 sites now go through `ClearRegs`, which clears
everything except the flags. The same bug, in the same shape, wedged a 386
three times in PicoMEM2's `AskBios` before it was understood.

`FOSBBS` on the LOOPBACK transport never returns, and that is not a fault:
on loopback the BBS is its own caller -- carrier is always asserted and
everything it sends comes straight back as input -- so `Session` never
ends. It is written for the TCP transport and wants a caller. Run it with
`/PKT`, or against a modem, and not on loopback.

Measured on the 386 (PicoMEM 1, no coprocessor), 2026-09-20:

| | |
|---|---|
| `FOSDET` | 10/10 |
| `FOSTEST`, loopback | **57/57**, unchanged by the flags fix |
| `FOSAT` through a real modem on a Keyspan adapter over the CH375 | 5/5, a 1052-byte `ATI4` at 617 bytes/s |
| `FOSPKT` on the bridge's own packet driver at 60h | 2/2 -- both handles taken and released, and the link survived |
| `FOSBBS` over TCP, dialled from Windows with a telnet client | a whole session: greeting, menu, time, description, housekeeping, echo, goodbye |
| `FOSWDOG` | 2/2 -- the line opened, 75 s of silence, and the handles came back on their own. The result arriving at all is the pass |
| the 4 KB binary download | 4,544 bytes carrying **all 256 byte values, 00h and FFh included** |

One note for whoever writes the next client. The first dialler reported "no
FFh" and it was tempting to read that as the driver losing the telnet
escape. It was the CLIENT: a literal FFh arrives doubled (`IAC IAC`), and a
parser that treats the pair as a command and drops both will report a clean
8-bit test as broken -- or, worse, a broken one as clean.


**Moved into this collection.** It was written in DOSBridge's `projects/`
tree, which is where its test machinery lives, but the CH375 transport is
what it is for -- it turns `CH375Serial`'s adapter work into something an
unmodified DOS program can use. It belongs beside that.

Nothing about the driver changed in the move: `FOSSIL.COM` is byte-identical
across it, 30,006 bytes, CRC-32 `7BFBE9DB`.

The test programs did change, and had to. They used DOSBridge's `About` and
`Tester` units, and a project inside this collection should not need another
repository to compile. The banner is `chtool` now, like every other tool
here, and the pass/fail counting is `src/fosapi.pas` -- deliberately the
same interface as `Tester`, so the programs moved across with a changed uses
clause and one `Banner` call and nothing else. Re-verified from the new
location: 57 of 57 on the loopback suite, and the Courier answering `ATI4`
at 911 bytes/s through a Keyspan.

## 0.1.0 -- a modem that is not there

`FOSSIL.COM` implements FSC-0015 on `INT 14h` -- all thirty functions --
with three transports behind one table of far pointers:

* **loopback**, where the timer feeds the transmit ring back into the
  receive ring. It exists so the whole API can be tested with nothing
  plugged in, and it is why the core was correct before any hardware was
  involved.
* **CH375**, a real modem on a USB-to-serial adapter. Verified against a
  USRobotics Courier V.Everything through **FTDI** and **Keyspan** adapters
  at 9600, 19200 and 38400, byte-exact, zero errors.
* **PKT**, a TCP listener on any packet driver, presenting an accepted
  connection to the application as a carrier. Verified with `FOSBBS`, a BBS
  that believes it has a modem on COM1 and contains neither the word TCP nor
  the word telnet: 128 KB byte-exact in both directions including `0FFh` and
  `00h`, at about 13 KB/s to a real telnet client.

The `README.md` carries the measurements and, at more length, the things
that were wrong on the way. The four worth knowing:

* **A telnet negotiation loop.** Answering an acknowledgement with another
  acknowledgement, against RFC 854's one loop-prevention rule, produced
  30,461 segments for 2.5 KB of real output. Every other symptom in the PKT
  transport -- dropped frames, a six per cent retransmit rate, a second call
  whose handshake ACK vanished, throughput an order of magnitude low -- was
  that one bug wearing a different hat.
* **The receive ring was not FIFO.** The allocator searched from the slot it
  last used, so once the drain freed that slot it was handed straight back
  while the drain had moved on. The ring quietly stopped draining.
* **The transport ran from the timer interrupt**, so sending re-entered a
  packet driver that had enabled interrupts during its own IRQ. It runs from
  `INT 14h` now, which a BBS polls continuously anyway. The watchdog stays
  on the timer deliberately: it exists for when the application has died,
  which is exactly when `INT 14h` stops being called.
* **Two bounded waits held their deadline in BX** and read the BIOS tick
  through ES across a call that clobbers both, so function 05h gave the
  packet driver handles back before the FIN was sent. That had been quietly
  wrong in 08h the whole time; only a test that cared *when* something
  happened could see it.

Known limits, stated plainly: real BBS software of the Renegade and
QuickBBS era wants a **286**, and the machine this was written on is a V30 --
an 8086 with the 186 instruction set. Neither package got far enough to open
a line, so nothing there indicts the driver, but it does mean the driver is
still only exercised by software written to test it.
