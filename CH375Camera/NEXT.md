# Picking this up next

Written 2026-09-18, at the end of the session that built CH375Camera from
nothing to a tested release. For whoever continues it -- including a fresh
Claude Code instance -- and in particular for **adding more cameras**, which
is what this is being parked waiting for.

## Read these first, in this order

1. **This file** -- the state, the hazards, and how to start on a new camera.
2. **`README.md`** -- "Which cameras" first, then "How it works". The how
   is long because most of its value is the list of things that were tried
   and did not work; each cost an experiment on the hardware.
3. **`CHANGELOG.md`** -- the same story in order.
4. **`src/camgrab.pas`'s header** -- what the camera does with the data we
   cannot read. That model is the thing any new camera has to be checked
   against.

## Where things are

| | |
|---|---|
| sources, binaries, docs | `C:\CH375USB\CH375Camera` -- pushed to https://github.com/jdredd87/CH375USBTools |
| the bridge that builds and runs it | `C:\dosbridgeDEV` (`dosd` must be running; `DOSBRIDGE=C:\dosbridgeDEV` for `build.cmd`) |
| Linux's driver it learned from | `drivers/media/usb/gspca/xirlink_cit.c` in the kernel -- not copied here (GPL); fetch it again |
| the DOS machine | NEC V30, MS-DOS 6.22, CH375B at `260h`, the camera plugged straight into the CH375 (no hub) |

## State, 2026-09-18

**Works, tested on the hardware, `CAMTEST` ALL PASSED unattended:**

* IBM PC Camera `0545:8080` model 2 (`bcdDevice 030A`) only.
* Stills at 176x144 (YUV), 320x240 and 352x288 (Bayer GRBG): 1.5-2.2 s,
  every strip on its first frame, 24-bit BMP, RAW, ASCII (`.TXT`) and ANSI
  (`.ANS`) out.
* `CAMLIVE` on VESA 640x480 (boot-dependent), mode X, 13h, 12h, 80x50 and
  80x25 half-block text, ASCII; colour and grey; `/F=1|2|4` detail.
  About 3-5 s a picture.
* The button: register `0113`, latched, acknowledged by writing `01` --
  confirmed press for press.
* `FASTTEST`: every assembly routine equal to its Pascal, byte for byte.

**Not done, and deliberately so:**

* **Video.** The camera cannot slow down enough -- see the README. Not a
  missing feature on this camera.
* **Any other camera.** See below.

**Known rough edges, none blocking:**

* 352x288 on VESA lands on an odd scale (3x) and is the slowest view, 8 s.
* Saving a 24-bit BMP takes several seconds on this CPU.
* Exposure varies a little frame to frame, so strips can differ slightly in
  brightness; not visible in most scenes.
* `CAMPROBE` still uses the old, slower packet read (`cit.FastRead` via
  its own loop); it is the first-contact experiment tool and kept as it
  was. `CAMCAL` uses the fast one.

## Hazards -- read before running anything

* **A USB bus reset wedges this camera once it has streamed.** Only a power
  cycle clears it. Everything attaches *warm* (`cit.WarmUp`) for that
  reason; a new camera may or may not share the fault, so test it early:
  stream, stop, then enumerate again.
* **`dospower cycle` is fine on this machine now**; the box comes back in
  about a minute. `dosreboot` (warm) is gentler when the box still answers,
  and a warm reboot is often enough to get VESA back on a boot without it.
* **The capture card needs ~40 s to lock onto a new video mode.** A program
  that switches mode and exits sooner is never seen by it. Hold the mode
  for a minute before believing a black screenshot (`capture.md`).
* **Running a batch file over DOSBridge:** `COMMAND /C NAME`, never the name
  alone or `CALL` -- a named batch never returns (no result comes back) and
  a batch's output ignores redirection. No `SET` either: bridge jobs have
  too little environment. `CAMTEST.BAT` is written this way.
* **Nothing may wait for a key.** A `PAUSE` with nobody at the machine
  stops the bridge until someone presses one or the power is cycled.

## Adding a camera: the order to do it in

1. **Identify it.** `CH375USBTOOLS\bin\USBINFO.EXE` over the bridge
   (`dosctl run`). Note VID:PID, `bcdDevice`, class, and every streaming
   alternate setting with its endpoint type and maximum packet.
2. **The first gate is packet size.** The CH375 holds 64 bytes. Is there an
   alternate setting whose isochronous (or bulk) IN endpoint has a maximum
   packet of **64 or less**? If not, is there a known vendor register that
   sets it, as `0106`/`0107` does on the C-It? If neither, it will not
   stream through this chip -- stop there, and write down why, the way
   `CH375Audio` did.
3. **Find its protocol.** A Linux driver is the usual source (`gspca/*`,
   `uvcvideo`, `usb/video`). Note the start sequence, frame marker, pixel
   format, frame-rate control and any window/crop registers.
4. **Get packets.** `CAMPROBE` is written for the C-It (it calls `CamUp`,
   which refuses anything else) -- copy it, swap in the new start sequence,
   and look at the status tally and hex dumps. Success is "every token
   returns success with data".
5. **Measure what it drops.** `CAMCAL` + `rawcal.py` record the raw stream
   with the fast loop. Look for: a FIFO depth (consecutive packets after a
   start), blanking (runs of empty packets), frame markers, frame size.
6. **Find a way to cut the data per frame** so a part of the picture
   arrives whole: a window like `0102`-`0105`, a lower resolution, a lower
   frame rate. Without one, only the timing-reconstruction approach is left
   (described in the README; it gave a blurred strip) -- stills will be
   poor.
7. **Only then** split the camera out behind an interface (next section),
   so the second camera is the first real test of it.

### Camera classes, most promising first

* **Other Xirlink/IBM** (`0545:8080` models 0/1/3, `0545:8002` NetCamera,
  `0545:800C`/`800D` Veo): same family, Linux has the sequences. Model 3
  and the NetCam Pro read the button the same way (`0113`).
* **Still/dual-mode digital cameras (USB Still Image class, PTP)**: the
  most promising route to *generic* -- bulk transfers of finished JPEGs,
  no race with a sensor, one standard across makes. Needs a PTP client
  (small) and a JPEG decoder on the 8086 (slow but fine for stills).
* **Old full-speed vendor webcams**: case by case, by the gates above.
* **Modern UVC webcams**: poor -- high-speed devices, streaming packets
  over 64 bytes, often MJPEG only, no standard crop to take strips with.
  Worth one `USBINFO` look each, not much more.

## Making it generic

Already camera-independent: `camgrab.Pkt` (the packet loop), the strip
assembly in `GrabWindow` (given line lengths and header bytes),
`camdisp`, `camfast`, `camfile`, and `CAMLIVE`/`CAMSNAP` apart from the
mode numbers.

Camera-specific, and what a driver would supply:

| today | what it is |
|---|---|
| `cit.CamUp`, `cit.WarmUp` | identify (VID:PID:bcd) and attach without a bus reset |
| `cit.M2Start`, `M2Off`, `StreamGo`/`Stop` | start and stop sequences |
| `M2Start`'s `0106`/`0107` writes | packet-size control |
| `camgrab.GrabWindow`'s `0102`-`0105` writes | window control |
| `camgrab.Modes` (`Lead`, `Hdr`, `Overlap`, `Unit_`, `Fmt`) | frame header, units, format per mode |
| `camgrab.RowRGB`/`RowGrey`, `camfast` Bayer/YUV routines | pixel formats (Bayer and C-It YUV are done) |
| `CAMBTN`, `CAMLIVE.ButtonPressed` | the button |

A driver record of procedure variables for those, chosen by VID:PID at
attach, is the shape it wants. Do it when the second camera is on the
bench, not before -- the interface should come from two real cameras.

## Ideas not done

* `REP INSB` in `camgrab.Pkt` on a 186+ (the V30 has it; `USBPKT` does it).
  Makes each packet read faster, but capture waits on the camera, so no
  picture comes sooner -- only worth it for consistency.
* A 386 path in `camfast` using 32-bit registers -- a real drawing speed-up
  on a 386, untestable here.
* Per-strip brightness matching (overlap strips a few pixels and scale)
  if exposure seams ever matter.
* A per-picture text-mode palette was tried and removed (README: small
  subjects lost their colour); do not retry it the same way.
