# Changelog

CH375Keyboard -- StevenC and Claude -- https://github.com/jdredd87/CH375USBTools

The version lives in `ver_str` in `src/usbkbd.asm` and nowhere else. A
release is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## Unreleased

**Rebuilt 2026-09-24 for the credit, and nothing else.** Every program's
banner now ends `-- StevenC & Claude`, and every source header says the
same. No code changed and no version was bumped, so this build shares its
version numbers with the one before it -- the CRC tells them apart.
Deployed to the V30 under `C:\CH375\` and CRC-checked there.


No code change. A bug was found in 1.7.1 while building `CH375Combo`, and
is recorded here rather than fixed, because fixing it changes what this
driver keeps resident.

**`/F` retries the bring-up from inside the timer interrupt, using code and
buffers that DOS has already taken back.** `bringup`, `parse_config` and the
128-byte `cfg_buf` they parse into all live *above* `resident_end` -- in the
part of the image released when the driver goes resident with INT 21h
3100h. So every hot-plug retry runs code and writes a buffer in memory that
now belongs to whatever was loaded next, from inside an interrupt, on a
machine with no memory protection. It works right up until something else
uses that memory.

Without `/F` there is nothing wrong: the retry path is never taken and the
transient part is never entered again.

`CH375Combo` fixes it the cheap way -- when `/F` is given the whole image
stays resident, about 14 KB instead of 5 KB, and nobody who does not use
`/F` pays for it. The same change would work here, at the same cost.

Also worth noting for anyone reading this driver's poll loop: it polls one
endpoint, and that is the only reason it is safe to do so as directly as it
does. Polling a second interrupt endpoint on the same CH375 makes the chip
answer with packets no device sent; see `CH375Combo/README.md`.

## 1.8.0 -- 2026-09-08

* **`/?` never worked, and now does.** The option parser folded each switch
  letter to upper case with `AND 0DFh` *before* testing it, which is right
  for letters and wrong for everything else: it turns `?` (3Fh) into 1Fh,
  so the comparison further down could never match. `USBKBD /?` silently
  loaded the driver instead of printing help. `USBCOMBO` found and fixed
  this in its own copy of the same parser; this one kept the bug until now.
  `?` is now tested before the upper-casing, and the unreachable second
  test further down the chain is gone.
* **`/S` reports the I/O base the resident copy is using**, read out of its
  image rather than assumed. There was previously no way to confirm which
  address a driver loaded with `@nnn` actually took -- which is precisely
  the situation in which you want to know.
* The help screen says that `/S` shows the base in use. No net lines were
  added: the screen is 23 lines and that is all there is room for.
* `KBDRAW`, `KBDTST`, `KBDBIOS`, `KBCINJ` and `KBD16` all report a version
  and answer `/?`.

## 1.7.1 -- 2026-09-07

* **`/W` withdrawn.** It locked the machine solid, needing a power cycle,
  and the reason is structural rather than a slip.

  This driver delivers keys from inside its INT 08h handler, because a
  polled USB keyboard has nowhere else to run. Calling INT 09h from there
  runs a handler that ends with its own EOI to the 8259 -- `out 20h, 20h`
  -- on top of the one this handler issues a moment later. Two
  end-of-interrupts for one interrupt corrupts the controller's in-service
  state, interrupts stop arriving, and the machine is dead. The nested
  handler may also STI and re-enter us, which is no better.

  Doing it safely would need an interrupt synthesised without the EOI,
  from a context that is not already inside an interrupt -- and this
  driver has no such context. The option is accepted and ignored; the
  routine is left in the source as a comment explaining why, because the
  idea is the obvious one to have and the trap is not obvious at all.

  **The measurement that motivated it still stands.** EDIT and QBASIC do
  own INT 09h and INT 08h, and a program driving its input from IRQ1 does
  need an interrupt rather than a buffer write. The conclusion is
  therefore that on a machine with no 8042, this is not solvable from a
  software driver -- not that the diagnosis was wrong.

## 1.7.0 -- 2026-09-07

* **`/W` calls INT 09h after delivering a key**, to wake a program that
  owns the keyboard interrupt and is waiting on it.

  **The measurement this rests on.** `I16SPY` was extended to paint the
  owner of INT 09h and INT 08h, sampled from inside the interrupted
  program. At the DOS prompt: `INT 09h = 12DF:0045`, `INT 08h =
  12DF:003C`. With EDIT running: **both are `504A`** -- QBASIC's own
  segment. So EDIT/QBASIC takes over the keyboard hardware interrupt and
  the timer, and drives its input from IRQ1 rather than from the BIOS.

  That is the whole explanation, and it fits every observation: a program
  waiting on IRQ1 never looks in the BIOS buffer, so keys put there are
  invisible; and the instant any key is pressed on the machine's own
  keyboard, IRQ1 fires, QBASIC's handler runs, it wakes, and everything
  queued arrives at once. Which is exactly what was reported from the
  first day.

  A software driver cannot raise IRQ1 and, with no 8042, cannot fake one.
  `/W` calls INT 09h instead, running whatever handler is installed. The
  key travels normally in the BIOS buffer and is collected once the
  program is awake. Off by default: calling another program's interrupt
  handler behind its back earns an opt-in.

### Correcting 1.6.0's static analysis -- it was backwards

1.6.0 claimed `QBASIC.EXE` contains `MOV AX,2516` and no `MOV AX,2509`,
and concluded it hooks INT 16h but not the keyboard interrupt. **That is
wrong.** `QBASIC.EXE` is **PKLITE-compressed** -- the `PKLITE` marker is at
file offset 1Eh, the entry point is `FFF0:0100` and there is a single
relocation. Every byte pattern searched was compressed data, not code, so
both the hit and the miss were coincidence.

The runtime probe says the opposite of what the bad analysis said: QBASIC
hooks INT 09h **and** INT 08h. `/H`, which was built on the wrong
conclusion, made no difference and is worse than the default for this case
-- it steers keys away from the BIOS buffer. Kept as a diagnostic only.

Lesson recorded: check for a packer before reading an old DOS binary as
code.

## 1.6.0 -- 2026-09-07

* **`/H` delivers keys through an INT 16h hook of our own** instead of by
  writing the BIOS keyboard buffer. A small ring, and a hook that answers
  AH=00h/01h/10h/11h from it; when the ring is empty every call chains, so
  the machine's own keyboard is unaffected.

  **Why there is a second delivery mode at all.** The buffer write is the
  right default and drives ordinary typing everywhere tested. It does not
  drive DOS EDIT's menu bar. DOSBridge's `KINJ`, which hooks INT 16h and
  answers inside the call, drives that menu perfectly; `KNET`, which
  queues a key for the BIOS to serve, does not -- and neither did this
  driver. Same key words, same BIOS, opposite outcomes, so the difference
  is in who answers the call, not in what is delivered.

  Static analysis of `QBASIC.EXE` -- which `EDIT.COM` is a front end for --
  found `MOV AX,2516` in the image and no `MOV AX,2509`. So it hooks INT
  16h itself and does **not** hook the keyboard hardware interrupt. Its
  menu loop is talking to its own handler, and a key merely sitting in the
  BIOS buffer is evidently not what that handler looks for.

  `/H` is **verified to deliver into QBASIC**: with `/X=29` holding Escape,
  EDIT's welcome dialog cleared. Whether it drives the *menus* needs Alt-F
  followed by an arrow, which no automated test here can produce -- that
  one is a keyboard test.

* **`/X=hh` pretends HID usage hh is held down**, so delivery into a real
  interactive program can be tested with nobody typing. Bounded to 64
  repeats, and it has to be: the first version repeated forever and fed
  Down keys into COMMAND.COM, wedging the batch file that had launched the
  test.
* **`I16SPY.COM` also reports who owns INT 09h and INT 08h**, sampled from
  inside the interrupted program.

### A second measurement mistake, same shape as the first

The frozen INT 16h counters were re-examined after `QBASIC.EXE` turned out
to hook INT 16h itself. A spy loaded before QBASIC sits *below* QBASIC's
own handler, so calls QBASIC services internally never reach it -- the
same confound as the KNET one, from a different direction. The counters
are therefore not proof that EDIT stops asking for keys, and the earlier
claim that it does is withdrawn a second time.

What is solid, because it was seen directly: a burst of `Alt-F Down Down`
queued in one datagram drives the menu (New -> Open -> Save), and the same
keys spaced a second apart do not. Whatever the mechanism, delivery timing
and delivery *route* both matter, and `/H` changes the route.

## 1.5.1 -- 2026-09-07

* **CLD in the interrupt path.** The direction flag belongs to whoever the
  handler interrupted, and this driver's ISR path contains five string
  operations: `STOSB` in `ch_read`, `LODSB` in both control-transfer
  builders, and the `REP STOSB` and `REP MOVSB` that zero-fill and remember
  a report. Every one of them ran backwards if the foreground program
  happened to be sitting on `DF=1`, writing over whatever lay below the
  buffer instead of filling it. That is a bug that depends entirely on what
  else is running, so the driver works perfectly until it suddenly does
  not. Nothing needs restoring: the CPU pushed the original flags on
  interrupt entry and whichever IRET runs pops them back.

  **Found by reading davidegat's independent CH375 driver**, which states
  the rule outright -- <https://github.com/davidegat/CH375USB>. That
  project reached most of the same conclusions separately: the mode 5/7/6
  reset order, low speed having to be reapplied after the final mode 6,
  `SET_RETRY` because the default retries NAK forever, storing the real
  `bMaxPacketSize0` for short-packet detection, boot protocol with idle 0,
  the make/break diff over a six-key report, driver-generated typematic,
  and the shift flags at 40:17, 40:18 and 40:96. Worth reading.

## 1.5.0 -- 2026-09-07

* **`/T` self-tests the delivery path and exits**, needing no keypress and
  no keyboard. It drives usage 04h through `key_down`, then the same key
  through `apply_report`'s press/release diff, then checks the release
  produces nothing -- reading each result back through `INT 16h`.

  This existed because it should have existed from the start. All 33
  earlier checks test the driver's plumbing: that it enumerated, that the
  timer calls it, that its tables match `hidkey.pas`. Not one of them
  tested the thing that matters most -- that a usage arriving from the
  keyboard comes out of `INT 16h` as the right key -- because that needed
  somebody to press a key. A delivery regression could hide behind 33
  passing checks, and for a while one appeared to.
* **`/Y=n` sets the HID idle rate** in 4 ms units, default 0 = report only
  on change. A nonzero rate makes the keyboard repeat its state forever,
  so the report path and the interrupt handler can be exercised with
  nobody typing. `/Y=25` produced 87 reports through the new private stack
  in a few seconds, which is how that stack was shown to be sound.

## 1.4.0 -- 2026-09-07

Two structural defects in the interrupt handler, both found while chasing
DOS EDIT's menus and both real regardless of that.

* **The handler now runs on its own stack.** An interrupt handler runs on
  whatever stack the interrupted program left behind, and that stack is not
  ours to spend: `poll_kbd` nests several calls deep and can run a whole
  control transfer for the LEDs. A program with a tight stack gets its own
  memory quietly written over, and what that looks like from outside is the
  OTHER program crashing. 256 bytes, switched in and out around the poll.
* **`check_top`, at last.** If something hooks INT 08h after we did, its
  handler is the one the PIT calls -- at OUR divided rate, 145 Hz instead
  of 18.2, because it chains down to us. Anything timing from the tick then
  runs eight times too fast. The driver now notices, puts the PIT back and
  stops dividing; polling drops to 18.2 Hz, slow for typing but correct for
  everybody else. `on_top` had existed as a variable since 1.0.0 and was
  never once maintained.
* `/K` injects scancodes through the keyboard controller with 8042 command
  D2h instead of writing the BIOS buffer, so keys arrive as real IRQ1
  interrupts -- the only way to reach a program that hooks INT 09h. It
  checks the controller answers at load time and falls back if not.
  **On the development machine it falls back**: port 64h reads FF, because
  an XT-class box has an 8255 keyboard latch and no D2h at all. `KBCINJ`
  proves this in ten seconds on any machine before `/K` is trusted.
* **`KBCINJ.EXE`**, new: injects a known scancode with D2h and checks it
  comes back through INT 16h. Needs no CH375 and no driver.
* **`KBD16.EXE`**, new: which INT 16h generations this BIOS implements,
  tested by writing the BIOS buffer directly and asking all six functions.

* **`I16SPY.COM`**, new: hooks INT 16h, counts calls by function, and
  paints the totals into video memory. Painting is the point -- a stuck
  interactive program holds the foreground, so nothing else runs and no
  output can be collected; the screen is the only channel out. It is what
  finally explained EDIT.

### On DOS EDIT's menus -- settled

The reported symptom was that EDIT can be typed into but its menu bar
cannot be driven: Alt-F opens the File menu and nothing after that has any
effect. Several plausible causes were tested and eliminated:

* Not the shift bytes. 1.1.0 added 40:18 and 40:96, and Alt-F works.
* Not the PIT rate. `/R=1` removes the division entirely; no change.
* Not the 8042. This machine has none, so `/K` cannot apply.
* Not a missing enhanced INT 16h. `KBD16` reports AH=10h/11h/12h all
  present and able to see a word written into the BIOS buffer.
* Not the arrow-key encoding. Both 5000h and 50E0h were tried.

* Not the driver. `KNET` reproduces the symptom exactly with no USB driver
  loaded at all.
* Not the BIOS read path. Every key type round-trips through the buffer
  unchanged, including the `50E0`->`5000` fold for AH=00h.

**What it is.** EDIT's menu IS driven through the ordinary enhanced INT 16h
pair -- `I16SPY` shows tens of thousands of AH=11h peeks and AH=10h reads
matching the keys delivered. But EDIT drains whatever is already waiting
and then stops asking; the counters freeze. A key arriving after that sits
in the BIOS buffer until a real keyboard interrupt wakes it, whereupon
everything queued arrives at once.

Demonstrable both ways. Three keys in one datagram, queued before EDIT
looks: `2100 5000 5000` -> the highlight moves New -> Open -> Save, AH=10h
reaches 0004. The same Down one second later, menu already open: nothing,
AH=11h frozen at 26C2.

So the key values, the scancodes and the BIOS path are all correct -- a
queued key drives that menu. What cannot be supplied is the WAKE-UP. A real
keyboard raises IRQ1; writing the BIOS buffer raises nothing, and `/K`
needs an 8042 this machine does not have. For a person typing, Alt-F then
Down half a second later always misses.

**A measurement mistake, recorded.** The first run loaded `I16SPY` BEFORE
`KNET`, so KNET -- which answers its four functions without chaining --
absorbed EDIT's calls above the spy, and AH=00h/01h/10h all read zero. That
was misread as "EDIT never calls INT 16h" and produced a confident, wrong
conclusion, including the claim that no driver change could ever matter. A
spy must sit on TOP of the chain, i.e. be loaded last. It also explains the
`KINJ` anomaly that had been left dangling: KINJ works because its keys are
always already queued when EDIT looks.

## 1.2.0 -- 2026-09-07

Fixes a bug in 1.1.0 that killed the machine's OTHER keyboard. After typing
on the USB keyboard and then `USBKBD /U`, the ordinary PS/2 keyboard
stopped working and only a reboot brought it back.

* **The BIOS owns the lock state; the driver adopts it.** 1.1.0 wrote
  40:17's Scroll/Num/Caps bits out of its own `locks` byte, which started
  at zero. On a machine booted with NumLock on -- which this one is -- the
  first keypress silently cleared NumLock in 40:17 while 40:97 still had
  the LED lit. From then on the driver and the BIOS disagreed about the
  lock state and each overwrote the other, and the LED-update handshake is
  where that turns into a keyboard that has stopped responding.
  `set_flags` now carries bits 4..7 of 40:17 through untouched, `locks` is
  seeded from 40:17 at install, and the driver's own lock keys toggle the
  BIOS byte in place rather than a private copy.
* **A lock toggled on the other keyboard now updates the USB keyboard's
  LED**, which falls out of doing the ownership properly rather than being
  a feature added on purpose.
* **`/U` clears every modifier bit it owns** in 40:17, 40:18 and 40:96. No
  key is held once the driver is gone, and a stuck Ctrl or Alt bit left
  behind turns every later keystroke into a control sequence -- the same
  symptom by a different route.
* **`/U` only clears 40:96 bit 4 if this driver was the one that set it.**
  This BIOS sets it itself, so `/E` had nothing to do here; clearing a bit
  that was never ours would have been a new bug of the same shape.
* **`KBDBIOS.EXE`**, new: dumps the BIOS keyboard data area -- all four
  flag bytes decoded bit by bit, the buffer with its head and tail, the
  vectors, the interrupt mask. It exists because none of the driver's own
  status output could show any of the above, and the way to find a bug like
  it is to photograph the data area before and after and subtract. That is
  how this one was found.

## 1.1.0 -- 2026-09-07

Menus in DOS text-mode programs work now. `EDIT.COM` could be typed into
but its menu bar could not be reached, and the reason was a byte and a
half of missing state.

* **`0040:0018` and `0040:0096` are maintained as well as `0040:0017`.** A
  program that asks `INT 16h AH=12h` for the keyboard state is answered out
  of those two, not out of 40:17, and they are where the LEFT and RIGHT
  halves of Ctrl and Alt are told apart. A TUI that opens its menus on Alt
  looks there. Maintaining only 40:17 gives exactly the reported symptom: a
  keyboard you can type on perfectly and cannot drive a menu with.
* **`/E`** sets 40:96 bit 4, "101/102-key keyboard installed", which is what
  makes software use the enhanced `INT 16h` calls (`AH=10h/11h/12h`). It is
  off by default because an XT-class BIOS does not have those functions and
  claiming the keyboard would send a program off to call them.
* **`/U` reads the saved interrupt vector out of the published pointer
  block** rather than through its own `old08` symbol. `/S` and `/U` reach
  into the resident copy at the reading build's offsets, so adding one byte
  of resident data moves everything below it -- and unloading a mismatched
  copy restored a wrong vector and killed the machine on the next timer
  tick, well after the command that caused it had returned. Found by doing
  it.
* **`/S` and `/U` now refuse a resident copy whose version differs** from
  the binary doing the asking, and say both versions. This is also why the
  version is bumped rather than left at 1.0.0: the guard is only worth
  anything if the version actually changes when the layout does.
* `KBDTST /W` watches all three shift bytes independently of the key
  buffer, because Alt pressed on its own never puts a word in the buffer --
  the only trace it leaves is in those bytes, so the interesting case was
  invisible.

## 1.0.0 -- 2026-09-06

First release. Run on the hardware: a CH375B rev B7 on an ISA card at
`260h`, an HP USB keyboard (`04F2:1717`, low speed), MS-DOS on an
8086-class machine. `KBDTST` reports 33 checks passed, 0 failed.

* `USBKBD.COM`, a resident keyboard driver, about 2 KB resident. It
  enumerates the keyboard itself, puts it in HID boot protocol, polls the
  interrupt IN endpoint from a timer hook, and writes scancode/ASCII words
  into the BIOS keyboard buffer at `0040:001E`. Shift state is maintained
  at `0040:0017`.
* Auto-repeat is generated by the driver, because `SET_IDLE 0` means a
  held key produces exactly one report. `/D=n` and `/T=n` tune it.
* Lock LEDs are driven over the control endpoint on a lock keypress.
* Ctrl-Alt-Del reboots.
* `hidkey.pas` holds the same usage-to-scancode mapping in Pascal, for
  `KBDRAW`; the resident image publishes its table addresses at `0111h`
  and `KBDTST` compares the two across all 256 usages.
* `KBDRAW` does everything the driver does except go resident -- the safe
  way to check a key translates correctly.
* Both `polls` and `reports` are counted, because with `SET_IDLE 0` an idle
  keyboard sends nothing and a report count alone cannot tell "not being
  called" from "called, nothing to report".
* Known: a program that hooks `INT 09h` and reads the 8042 itself -- most
  games -- does not see any of this. A physically stuck key repeats
  forever and will flood the BIOS buffer.
