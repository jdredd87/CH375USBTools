# Changelog

CH375Audio -- StevenC -- https://github.com/jdredd87/CH375USBTools

The version lives in the `VER` constant of each tool in `src/`. A release
is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## 1.0.2 -- 2026-09-12

**Bytes do reach the speaker, and 1.0.0 said they did not.** The claim was an
inference from the chip's counters, and the counters answer a different
question: a CH375 OUT token puts its packet on the wire *before* any handshake
is due, so "0 accepted" means no acknowledgement came back, not that the
device heard nothing. Recorded from the speaker's headphone jack:

| DOS box doing | mean |
|---|---|
| nothing | -44.1 dB |
| enumerating only, no packets | -44.6 dB |
| hammering with SILENT packets | -30.2 dB |
| hammering with a full-scale square wave | -19.8 dB |

Enumeration alone is indistinguishable from silence, so it is not a bus-reset
pop; the noise appears only when the stream is armed and packets sent, and the
content moves the level by 10 dB. The data is being carried.

It is still not playback. The spectrum is a broadband click-train at the
PACKET cadence rather than the waveform: the device wants 1000 packets a
second and gets 138, so it is starved 95% of the time. A controllable noise
source, and a worse one than the PC speaker already in the machine.

**The ceiling is the port interface, not the handshake timeout.** The obvious
objection was that EpOut waits for an acknowledgement that never comes, so the
rate measures waiting rather than sending. /FAST issues the token and moves on:
138 packets/s against 131 with the wait. No difference. The limit is the cost
of pushing bytes through the CH375 -- 8,844 bytes/s against 192,000
needed, 4.6%, and not improvable by better transfer handling.

**A slower rate was asked for and refused.** SET_CUR of the endpoint's
sampling-frequency control at 8000 and 16000 Hz returns success, but GET_CUR
stalls and the descriptor declares one discrete rate, so there is no evidence
any of it took effect. Had 8 kHz been honoured the arithmetic would have
changed -- 8 kHz stereo is 32 bytes a frame, inside the chip's buffer -- which
is why it is asked before a byte of audio is sent.

New in DAISO: /HAMMER=secs (send flat out, long enough to record), /ZERO (send
silence -- the control that makes the comparison mean anything), /FAST (issue
tokens without waiting), /LEN=n (packet size).

## 1.0.1 -- 2026-09-12

**A freeze, and the one line that caused it.** `DAKEYS` run at the keyboard
locked the machine after the banner and needed a power cycle. The cause is
in this project, not in the CH375 layer, and every other polling tool in the
collection already guards against it:

`BusUp` arms `SET_RETRY 8F` -- retry NAKs indefinitely -- which is correct
for **enumeration**, where a device still waking up should be waited for. It
is exactly wrong afterwards. An interrupt endpoint with no news NAKs by
design, so with infinite retry still armed the chip retries it forever and
never raises the interrupt the driver waits on; `WaitInt` gives up on its own
count, the loop fires another token at a chip still grinding on the last one,
and the chip stops answering anything at all -- including `CHECK_EXIST`,
which is where "no CH375 at 0260" on a fitted card comes from. That wedge had
already been seen once during development and was misdiagnosed as a stranded
token on exit.

`chdiag`, `kbdraw` and `usbpoll` all call `SetRetry($00)` immediately before
their poll loop, and `usbpoll` states the reason in one sentence: *an idle
device would otherwise block the poll for as long as it stayed idle.*
`DAKEYS` called it only from its `ExitProc`, which is far too late -- by then
the machine is already wedged.

Fixed by moving the whole bring-up into `daudio.BringUp`, which ends with
`SetRetry($00)`, so no tool here can arm infinite retry and then poll. Five
consecutive `DAKEYS` runs with no wedge.

Three other things came out of the same report:

* **The toggle now starts at `$80`**, matching every working polling tool in
  the collection rather than 0.
* **The watch loops are bounded by a spin count as well as by the clock.** A
  loop that can only end when the tick counter advances never ends if the
  tick counter stops -- which is precisely the "machine is frozen" case being
  fixed.
* **Stale keystrokes are drained before watching.** A key left in the BIOS
  buffer made the first `KeyWaiting` true, so the watch announced that it had
  stopped at the keyboard and exited before looking at anything once --
  indistinguishable from a watch that ran and saw nothing, which is the one
  answer it exists to produce. It happened on the first real knob test.

**Stage breadcrumbs on stderr.** Everything between the banner and the first
output was silent USB work, which broke this project's own rule that a
program taking more than a moment must prove it is alive. `BringUp` now names
each stage (`chip`, `enumerate`, `descriptors`, `set config`, `ready`) on
handle 2 -- which DOS 6.22 cannot redirect, so it reaches the real screen even
while the bridge captures stdout. A recurrence now names the stage instead of
being a mystery.

**`DAVOL /WATCH=secs`** added: poll the mixer and report anything that moves.
It answers a question `DAKEYS` cannot when a device has no buttons -- whether
a volume knob is a digital encoder (it moves the Feature Unit and USB sees it)
or analogue (it moves the amplifier and USB never hears about it). On the
speaker tested, 40 seconds saw nothing move.

**The test device has no buttons.** Just a knob. The HID interface decodes
correctly and the press path is written, but it cannot be exercised on this
hardware, and the README now says that rather than leaving it as an open gap.

## 1.0.0 -- 2026-09-12

First release. Four tools for USB Audio Class devices over a CH375, and a
measured negative result on playback.

**What works.** `DAPROBE` decodes the whole Audio Class topology from the
configuration descriptor -- terminals, feature units, formats, alternate
settings, endpoints -- and ends with a verdict computed from the attached
device rather than from a table. `DAVOL` reads and sets volume and mute
through Audio Class control transfers on the Feature Unit, with actions
applied left to right so a command line is a little script. `DAKEYS` reads
the transport buttons off the HID interrupt endpoint, decoding the
bit-to-button map from the device's own report descriptor rather than
hardcoding it.

**What does not, and why it is a tool rather than a sentence.** `DAISO`
arms the isochronous stream and tries to feed it. Playback is blocked three
times over: the endpoint is isochronous and the CH375 always waits for a
handshake that isochronous does not send; the endpoint wants 192-byte
packets and the chip transmits from a 64-byte buffer; and the stream needs
192,000 bytes/second on a hard 1 ms deadline against 19,055 measured. Any
one of those ends it. Measured on the hardware: `SET_INTERFACE` succeeds,
then 0 of 100 packets are accepted, every one a timeout.

It is a runnable tool rather than a paragraph so that a future chip
revision or an unusual device gets tested instead of being talked out of it
by a comment -- the same reason CH375Video keeps its FL2000 findings.

**Verified against** a Jieli Technology `UACDemoV1.0` (`4C4A:4155`) on an
a CH375 rev B7 at I/O 260h. Volume written and read back at
both ends of the device's range; mute set, read, toggled, read. The one
path **not** observed is an actual button press -- the poll loop runs and
the endpoint NAKs cleanly, but nobody has pressed a button while `DAKEYS`
was watching, and the tool says so rather than implying silence is health.

### Four bugs worth recording, all caught by the hardware

* **A nine-byte configuration descriptor decoded as "not an audio
  device".** `BusUp` keeps only what its bring-up needed, which here is the
  header. The first run reported no audio interfaces on a speaker. The
  truncation warning is what caught it; `GetConfigFull` now fetches in two
  stages and refuses a short read rather than decoding a partial topology,
  because that and "a device with no controls" look identical.
* **The playback format was read as mono.** The format block was assigned
  straight to the playback fields, so the *last* one seen won -- and on any
  speaker with a microphone that is the capture format. Formats are now
  held and committed by the endpoint that follows them.
* **Every button was off by one bit.** The `Usage` before a `Collection`
  names the collection, not a field. HID local items are consumed by the
  next main item, so usages are buffered and only committed at the `Input`.
* **Channel counts disagreed between tools.** `DAVOL` counted channels with
  a non-zero control bitmap and called it "channels past master", which
  reported the microphone unit as having none while `DAPROBE`, reading the
  descriptor length, said one. Counted from the length now -- and taken
  before the padding loop that had been running the count to 8.

### And one inherited from CH375Video

`DAKEYS` polls an interrupt endpoint, and exiting while that endpoint is
NAKing strands a token in the chip -- so the next program's `CHECK_EXIST`
fails and reports "no CH375 at 0260" on a card that is fitted. It happened
during development exactly as CH375Video's notes predicted. The cure is two
halves that must agree, so both live in `daudio.pas` rather than being
copied into four programs: `Quieten` as an `ExitProc`, and `ChipThere`
resetting and re-asking on the way in.
