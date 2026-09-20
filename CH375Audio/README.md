# CH375Audio

USB audio devices on a vintage DOS machine, through a CH375 USB host card.

**Playback is not possible, and this project says so with measurements rather
than with a shrug** — including the measurement that proves bytes *do* reach
the speaker and make an audible noise, which is not the same thing as playing
audio. See "Bytes DO reach the speaker" below; the first draft of this file
got that wrong. What *is* possible turns out to be worth having: the
speaker's mixer and its buttons are both reachable, so DOS can set the volume,
mute it, and watch somebody press play — it simply cannot be the thing that
feeds it audio.

A note on the last of those: the speaker this was developed against turned out
to have **no buttons at all**, just an analogue volume knob. The HID interface
and its report descriptor are real and decode correctly — the Jieli firmware
advertises the buttons its chip could have — but this enclosure wires none of
them, so the press path is written and unexercised. `DAKEYS` and the table at
the bottom of this file both say so plainly.

If you want a DOS machine to make noise, the PC speaker and an AdLib/OPL2 are
still the answer. This project is about what a USB audio device can be *used
for* on hardware that cannot stream to it.

---

## The short version

| | |
|---|---|
| Read the device out | **works** — `DAPROBE` |
| Volume and mute | **works** — `DAVOL`, over control transfers |
| The speaker's buttons | **works** — `DAKEYS`, over an interrupt endpoint. The unit tested has none wired, so the press path is untested; see below |
| Playing audio | **impossible** — `DAISO` measures why |

Tested against a Jieli Technology `UACDemoV1.0` (`4C4A:4155`), a common cheap
USB speaker, with a CH375 rev B7 at I/O 260h.

---

## Why playback cannot work

Three separate walls. **Any one of them ends it**, which is why this is not a
matter of optimisation:

**1. The endpoint is isochronous.** Audio streams over isochronous endpoints,
which have no handshake — the host sends one packet per USB frame and nothing
is acknowledged. The CH375 issues a token and then *waits for a handshake*
(`EpOut` calls `WaitInt`), and it maintains a data toggle that isochronous does
not use. Its tokens are OUT, IN and SETUP with bulk/interrupt semantics. There
is no isochronous mode on the chip to select.

**2. The packet is too big to express.** This endpoint asks for 192 bytes in a
single packet. The CH375 transmits out of its own 64-byte buffer, and `EpOut`
takes a `Byte` length. A 192-byte packet cannot be formed at all.

**3. The rate is an order of magnitude out.** 192 bytes every millisecond is
**192,000 bytes/second**, and it is a hard deadline rather than an average — a
late packet is an audible click, not a delay. The fastest this collection has
ever driven a CH375 is **19,055 bytes/second**, measured by `DLBENCH` in
CH375Video on this same machine. That is a factor of ten.

### Measured, not assumed

`DAISO /GO` arms the stream and tries anyway:

```
  SET_INTERFACE 1 alt 1 -> success
  first packet -> device did not answer (timeout) (40)
  attempted 100 packets of 64 bytes
    accepted by the chip : 0
    refused              : 100
    throughput           : 0 bytes/s
    needed               : 192000 bytes/s
```

Arming the interface works, because that is an ordinary control transfer. Every
single data packet then times out, because the endpoint never sends the
handshake the chip is waiting for. The tool puts the interface back to alt 0 on
the way out.

### Bytes DO reach the speaker. Measured, after this was first written wrong.

The first version of this file said flatly that nothing gets through. That was
an inference from the chip's own counters, and the counters answer a different
question: a CH375 OUT token puts its packet **on the wire before any handshake
is due**, so "0 accepted" means the chip never got an acknowledgement, not that
the device heard nothing.

Recorded from the speaker's own headphone jack, with its volume at maximum:

| what the DOS box was doing | mean level |
|---|---|
| nothing | **−44.1 dB** |
| enumerating only — bus reset, descriptors, SET_CONFIG, **no packets** | **−44.6 dB** |
| hammering the endpoint with **silent** packets | **−30.2 dB** |
| hammering it with a **full-scale square wave** | **−19.8 dB** |

Enumeration alone is indistinguishable from silence, so the noise is not a
bus-reset pop. It appears only when the stream is armed and packets are sent,
and the **content changes the level by 10 dB** — so the data is genuinely
being carried, not merely rattling the device.

**But it is not playback.** The spectrum is a broadband click-train at the
*packet* cadence rather than the waveform we sent: the device wants 1000
packets a second and gets 138, so it is starved 95% of the time and what you
hear is it reacting to that. It is a controllable noise source — and a worse
one than the PC speaker the machine already has, so it is a curiosity rather
than a feature.

`DAISO /HAMMER=secs` sends flat out for long enough to record; `/ZERO` sends
silence instead of a tone, which is the control that makes the comparison
mean anything.

### The ceiling is the port interface, not the timeout

The obvious objection to the numbers above is that `EpOut` waits for a
handshake that will never come, so the measured rate is the cost of *waiting*.
It isn't. `/FAST` issues the token and moves on without waiting at all:

| | packets/s | bytes/s |
|---|---|---|
| waiting for the handshake | 131 | 8,437 |
| **fire-and-forget** | **138** | **8,844** |
| **needed** | **1000** | **192,000** |

Removing the wait entirely changed nothing, which means the limit is the cost
of pushing bytes through the CH375's port interface — the same wall
`DLBENCH` measures at ~19 KB/s for larger transfers. **4.6% of what the stream
needs**, and not improvable by being cleverer about transfers.

### Would a different speaker help?

Probably not, and `DAPROBE` will tell you rather than leaving you to guess. The
interesting field is `bSamFreqType`: a device offering a *continuous* range, or
a discrete list with something slow in it (8 kHz mono is 8 KB/s, which is
within reach on paper), would at least be arguable on the rate. The one tested
here offers exactly **one** rate — 48 kHz, 16-bit, stereo — so there is not
even a slower format to argue about.

Walls 1 and 2 do not care about the rate, though. A device would need a
**bulk** or **interrupt** audio endpoint of 64 bytes or less to stand any
chance, and that is not what USB Audio Class devices do.

---

## Devices it has been used with

| | |
|---|---|
| **Jieli "UACDemoV1.0"** `4C4A:4155`, full speed, audio control + 3 streaming interfaces + HID | `DAPROBE`, `DAVOL` and `DAISO` all proven; `DAKEYS` **cannot be tested on it -- the speaker has no buttons** |

Measured on a Gateway 2000 386SX/25 (PicoMEM 1, no 387), 2026-09-20,
CH375 at 260h: the
topology decoded, feature units 2 and 5 found, volume and mute WRITTEN and
read back (25% = -21.5 dB, mute on, unmute, 60% = -11.9 dB), and `DAISO`
reproduced the isochronous result -- every transfer times out.

`DAKEYS` says as much itself when nothing arrives: it cannot tell "nobody
pressed" from "this device does not report". On a speaker with no transport
buttons that is permanent, so the HID half of this project is still
unproven on hardware. It wants a speaker or headset with play/pause and
volume keys.

## The tools

### `DAPROBE` — decode the device

```
DAPROBE [/P=260] [/V] [/T]
```

Walks the whole configuration descriptor and decodes the Audio Class topology:
terminals, feature units, formats, alternate settings and endpoints. Ends with
a verdict computed from *this* device rather than from a table.

```
  INTERFACE 0 alt 0  class 01/01  AudioControl
      INPUT  terminal id 1  USB streaming  2 channel(s)
      OUTPUT terminal id 3  SPEAKER  from unit 8
      FEATURE unit id 2  source 1  control size 1
        master : mute
        ch 1    : volume
        ch 2    : volume

  INTERFACE 1 alt 1  class 01/02  AudioStreaming
      FORMAT type I: 2 channel(s), 2 byte(s)/sample, 16 bits
        rate 1: 48000 Hz
      EP 03  isochronous  max 192  interval 1   <- PLAYBACK
```

### `DAVOL` — volume and mute

```
DAVOL [/P=260] [/U=n] [/C=n] [actions...] [/T]

  /M=1 mute   /M=0 unmute   /M=T toggle
  /V=pct      volume as a percentage of the device's own min..max
  /DB=n       volume in dB, negatives allowed
  /W=secs     wait      /RAMP  sweep      /R  re-read
  /WATCH=secs poll the mixer and report anything that moves
```

Actions run **left to right**, so a command line is a little script:

```
DAVOL /V=100 /W=2 /M=1 /W=2 /M=0
```

With no actions it prints the mixer:

```
  feature unit 2  (2 channel(s) past master)
    ch 0 mute   : off
    ch 1 volume : -14.3 dB  (F1B3h)  range -28.3 dB .. -0.9 dB  step 0.1 dB
    ch 2 volume : -14.3 dB  (F1B3h)  range -28.3 dB .. -0.9 dB  step 0.1 dB
```

**Volume is in dB, not percent.** The unit is 1/256 dB, so `0000h` is 0 dB and
`FF00h` is −1 dB; `8000h` is a reserved "silence" code rather than a very small
number. Devices state their own usable range, and it is *not* −127..0 in
general — this one is −28.3 to −0.9 dB — so `/V=` maps a percentage onto
whatever the device actually reports. That mapping is linear in dB, which is
roughly linear in perceived loudness; linear in amplitude would put everything
useful in the top few percent.

### `DAKEYS` — the buttons

```
DAKEYS [/P=260] [/I=n] [/S=secs] [/X] [/T]
```

The transport buttons are not part of the audio at all: they sit on a separate
HID interface with an **interrupt IN** endpoint, which the CH375 handles
happily.

The bit-to-button map is read **from the device**, not hardcoded. Which bit
means which button is decided by the order usages appear in the HID report
descriptor, and that order is per-device — so `DAKEYS` fetches the report
descriptor and walks it:

```
  BUTTON MAP (bit -> usage, as this device orders them)
    bit  0  Volume Up
    bit  1  Volume Down
    bit  2  Mute
    bit  3  Play/Pause
    bit  4  Next Track
    bit  5  Previous Track
    bit  6  Fast Forward
    bit  7  Stop
```

A speaker like this is a cheap, standard, hot-pluggable eight-button panel that
needs no driver and no interrupt line, which is worth something on its own
terms.

### `DAISO` — the negative result, runnable

```
DAISO [/P=260] [/N=n] [/GO] [/T]
```

Without `/GO` it transmits nothing and just prints the comparison. With `/GO`
it arms the stream, fires OUT tokens at the isochronous endpoint, times them,
and reports whatever the chip says. It exists so that "this cannot work" stays
a measurement instead of becoming folklore — and so that a future chip
revision or an unusual device gets *tested* rather than talked out of it by a
comment.

---

## Building

```
build.cmd            build only
build.cmd probe      ...then decode the attached device
build.cmd vol        ...then read the mixer
build.cmd mute       ...mute, pause, unmute
build.cmd ramp       ...sweep the volume end to end
build.cmd keys       ...watch the buttons
build.cmd iso        ...demonstrate why playback cannot work
```

Needs Free Pascal cross-compiling to real-mode DOS (`-Tmsdos -Pi8086`). The
CH375 layer is `ch375.pas` from `..\CH375USBTOOLS\src`, found with `-Fu`; its
`.ppu` is compiled into this project's `bin\`, so the two projects share source
and never a compiled unit.

Targets that run something need [DOSBridge](https://github.com/jdredd87/DOSBridge);
set `DOSBRIDGE` if it is not in `C:\dosbridge`.

### `daudio.pas`

Three things every tool here needs, kept in one place because a hand-copied
second version of any of them would be dangerous rather than untidy:

* **Chip recovery.** A program that polls an interrupt endpoint and exits while
  the endpoint is NAKing strands a token in the chip, and the *next* program's
  `CHECK_EXIST` then fails — which reads as "no CH375 at 0260" on a card that
  is plainly fitted. The cure is two halves that have to agree: abort the NAK
  on the way out, reset-and-re-ask on the way in. This bit during development,
  exactly as CH375Video predicted it would.
* **The configuration fetch.** `BusUp` keeps only what its bring-up needed —
  on this speaker, the nine-byte header. Every tool has to fetch the rest in
  two stages, and one that forgets decodes nine bytes and reports that the
  device has no audio interfaces. Not hypothetical: that is what the first run
  of `DAPROBE` did, and the "refusing to decode a partial topology" guard is
  there because a short read and a device with no controls look identical.
* **The playback verdict**, from constants, so four tools cannot drift into
  disagreeing about why it does not work.

---

## What is verified, and what is not

Being explicit, because "it compiled" is not evidence:

| | |
|---|---|
| Descriptor decode | **verified** against the real device, 232 bytes, full topology |
| Volume read | **verified** — reads back −14.3 dB, range and step |
| Volume write | **verified** — set to 100% and 0%, read back as −0.9 and −28.3 dB |
| Mute / toggle | **verified** — set, read back ON, toggled, read back off |
| Button *map* | **verified** — decoded from the device's report descriptor |
| Button *press* | **cannot be tested on this unit — it has no buttons.** Just a volume knob, and a 40 s `DAVOL /WATCH` saw the mixer never move, so that knob is analogue: it moves the amplifier and the USB side never hears about it. The HID interface is real and its report descriptor decodes correctly; the Jieli firmware advertises the buttons its chip *could* have, and this enclosure wires none of them |
| Playback | **verified impossible** — 0 of 100 packets accepted |

The button-press path is the one gap, and it is the *device* that closes it
rather than the tool: this speaker has no buttons. `DAKEYS` says so carefully
rather than implying that silence means the hardware is fine:

```
  no button was pressed.
  Nothing here can tell that apart from a device that does not
  report, so this is not by itself evidence of a fault.
```

`DAVOL /WATCH=secs` is the other half of that question, and it needs no HID
interface at all: it polls `GET_CUR` and reports anything that moves. A knob
that is a digital encoder moves the Feature Unit and shows up; an analogue one
never reaches USB. On this unit, nothing moved.

### One thing worth knowing before buying a speaker to test with

**A USB speaker will never make a sound on a host like this**, and that is not a
limitation of these tools — its only input is USB, and USB audio cannot be
streamed from a CH375. Controlling its volume works, and it is the volume of
silence. Another USB speaker will behave the same way; the three walls are
properties of the *host*, not of the device. A speaker with a 3.5 mm input is
a different matter: feed it from the PC's own sound hardware and `DAVOL` then
controls something audible.

---

## Where this sits in the collection

| project | |
|---|---|
| [CH375USBTOOLS](../CH375USBTOOLS) | the shared CH375 layer and the generic probes |
| [CH375Keyboard](../CH375Keyboard) | USB keyboards |
| [CH375Mouse](../CH375Mouse) | USB mice |
| [CH375Net](../CH375Net) | USB Ethernet |
| [CH375Video](../CH375Video) | USB display adapters |
| **CH375Audio** | USB audio: the mixer and the buttons, not the sound |

CH375Video is the closest relative and the useful comparison. There, no device
class existed and every adapter was a private protocol, but the work was
*possible* — DisplayLink adapters have a framebuffer and accept compressed
updates, so a slow host can still drive one. Here the class is excellent and
the documentation is perfect, and it does not help at all, because audio is a
real-time stream and there is no framebuffer to hide behind.

That is the general lesson for anything else attempted on this bus: **ask
whether the device can buffer.** A device that holds state you update is
reachable from a slow host. A device that must be fed continuously at line rate
is not, however well documented it is.

---

Public domain (the Unlicense); see [LICENSE](../LICENSE).
