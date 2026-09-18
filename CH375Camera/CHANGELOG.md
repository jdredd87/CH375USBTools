# Changelog

CH375Camera -- StevenC -- https://github.com/jdredd87/CH375USBTools

The version lives in the `VER` constant of each tool in `src/`. A release
is: bump it, add an entry here, `build.cmd`, commit, `git tag -a`.

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
