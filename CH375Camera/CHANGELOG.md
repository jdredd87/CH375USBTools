# Changelog

CH375Camera -- StevenC -- https://github.com/jdredd87/CH375USBTools

The version lives in the `VER` constant of each tool in `src/`. A release
is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

## 0.2 -- 2026-09-20

Everything here still works on the V30 it was written on; what changed is
that it now also works on a **386**, where it did not.

* **Blanking is measured in time, not packets.**  `BLANK_RUN = 8` counted
  empty packets, and its own comment gave the assumption away: "a packet
  about 1 ms".  That holds on a V30, where a token costs about 0.44 ms.  A
  386 issues tokens four to five times faster, so eight empties fit inside
  a normal gap BETWEEN LINES and every strip was declared finished early:
  five strips MISS and a 110 ms "capture" where the V30 takes 1.7 s.
  `CamStart` now measures the machine's own token rate -- 250 per 110 ms on
  the V30, 1752 on the 386 -- and sets the threshold to `BLANK_MS` worth of
  silence, with the old 8 as the floor.  `CAMSNAP` prints both numbers.
* **`vidfix`**, shared with DOSBridge and pulled in through `chtool`: FPC's
  runtime hooks INT 10h with a coprocessor stub, and on a 386 with no 387
  the first video BIOS call never returns.  That is what froze `CAMLIVE` on
  `DispOpen`, whose first statement asks the BIOS for the current mode.
* **`CAMLIVE /L`** writes each phase to `C:\WORK\CAMLIVE.LOG`, closing the
  file every time.  It is how the freeze above was found: the program
  prints nothing on the way down because its output is still buffered, so
  the only evidence that survives is a file that was closed.

Measured on the 386 (PicoMEM 1, no coprocessor), camera on a CH375 at 260h:
176x144 in 715 ms, 320x240 in 1815 ms, 352x288 in 2200 ms; `CAMLIVE` 12
pictures in mode X with **0 strips missed**; every display mode -- VESA,
mode X, 13h, 12h, 80x50, 80x25, ASCII -- and the button, 5 presses for 5.

## 0.1 -- 2026-09-18

First version. An IBM PC Camera (`0545:8080`, Xirlink C-It, model 2) taking
colour photographs through a CH375, in real-mode DOS.

* `CAMSNAP` 0.4.0 -- stills at 176x144 (YUV), 320x240 and 352x288 (Bayer),
  as 24-bit or grey BMP plus the raw bytes. 1.5 / 1.7 / 2.2 s a picture.
* `CAMLIVE` 0.6.0 -- pictures on the screen over and over: VESA 640x480,
  mode X, 13h, 12h, 80x50 and 80x25 half-block text, ASCII. Colour or grey,
  three detail levels, auto-contrast, `S` to save, button watch.
* `CAMBTN` 0.1.0 -- watches registers 0100..0135 for the button.
* `CAMPROBE` 0.2.0, `CAMCAL` 0.2.0 -- the raw-stream experiments.
* `FASTTEST` -- every assembly routine checked against its Pascal.

What was established, all of it measured on the camera:

* An isochronous **IN** endpoint works on a CH375, unlike the OUT case
  `CH375Audio` measured -- once the camera's own maximum packet (`0106`/
  `0107`) is set to 64.
* The camera's FIFO is 33 packets; it drops whole lines when full and
  abandons the frame when it overflows.
* The window registers `0102`..`0105` are start and end in 8-pixel steps
  (start + 1 for the columns), and a 64-pixel column of the full height
  arrives whole in one frame once the packet loop is assembly.
* 176x144 frames carry one leading byte, lose the last column of each
  window to the scaler, and have to be copied raw and unpacked afterwards.
* A USB bus reset wedges a camera that has streamed; everything attaches
  warm instead.

Confirmed on hardware after the first write-up, the same day: the VESA
path (a boot that offered mode 101h), and **the button** -- register `0113`,
latched, acknowledged by writing `01`; `CAMBTN` 0.2.0 counts presses with
beeps, and `CAMLIVE` saves on a press (checking after every strip, since a
check once per picture missed them).

Later the same day: `CAMLIVE` draws the finished picture line by line
across the full width instead of strip by strip, and odd scales get the
word-fill dither -- VESA 6.6 s to 5.0, 352x288 on VESA 10.4 s to 8.0.

`CAMSNAP` /A: the photograph also as ASCII art (`.TXT`, printed too) and
ANSI half-block colour art (`.ANS`), each character a block mean rather
than one sample; `CAMLIVE /A` uses the same ASCII. `ans2png.py` renders a
`.ANS` for the README.
