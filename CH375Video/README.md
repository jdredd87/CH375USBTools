# CH375Video — USB display adapters over a CH375

A real-mode DOS machine with a CH375 USB host card, driving a
USB-to-VGA adapter.

**It works, and it moves.** A DisplayLink adapter is identified from its
own descriptors, a video mode is set, and pixels appear — a text console,
bouncing sprites, a rotating 3D wireframe cube, and 640×480 or 848×480
widescreen. Every picture below is a real photograph of the adapter's
output, taken through a capture card.

![A text console](doc/console.png)

*80×30 characters at 640×480, drawn from the machine's own ROM 8×16 font.*

| tool | |
|---|---|
| `DLPROBE` | identify the adapter, decode its limits, read the monitor's EDID |
| `DLTEST` | draw test patterns and ask a human whether each appeared |
| `DLBENCH` | measure throughput, so optimisation is aimed rather than guessed |
| `DLDEMO` | moving graphics: `balls`, `stars`, `cube`, `bars`, `raster`, `life` |
| `DLCON` | a text console, which is what this hardware is actually good at |
| `DLFRACT` | a Mandelbrot in fixed point — the one COMPUTE-bound tool |
| `DLIMG` | load a BMP from disk and scale it to fit any mode |
| `DLDASH` | a colour dashboard: panels, gauges, ticker, live keyboard |

`build.cmd` builds all eight. `build.cmd probe` runs `DLPROBE` on the DOS
box; `build.cmd read` runs it with `/K` so nothing is written at all.

## Why this is a different problem from CH375Net

CDC-ECM worked out because Ethernet **has a class**. The device describes
itself, so one bring-up covers adapters from vendors nobody here has
bought.

There is no USB display class. The Video class is for cameras. Every USB
display adapter is a private protocol, so there is nothing to generalise
over and no descriptor that says how to drive it. The only useful first
question is *which* private protocol, and that is what `DLPROBE` answers.

## The adapter

An **IOGEAR GUC2015V**, "USB 2.0 to VGA". Read off the device rather than
the box it came in:

```
17E9:0058   DisplayLink / "IOGEAR External VGA" / serial 009091
one configuration, one interface, class FF vendor-specific
  EP 01  OUT  bulk       max 64      <- commands and pixels
  EP 82  IN   interrupt  max 8
  descriptor type 5F, 30 bytes       <- the capability list
```

`17E9` is DisplayLink, and that is the whole identification — the product
ID varies per OEM and the strings are whatever the reseller asked for.

### Its two limits, and why the clock is the one that bites

The `5Fh` descriptor is a five-byte header then key/length/value triples.
It parses, and the triples **tile it exactly** — 30 bytes of 30, nothing
over. That check is the one that matters: a wrong guess at the layout
still yields plausible keys and values, and only insisting the walk land
on the final byte catches it.

```
key 0204  = 39999999   pixel-clock limit, Hz
key 0200  =  1500000   pixel-area limit
```

**Both bind, and the clock is the tighter one.** 1.5 million pixels of
area sounds like it allows 1024×768; the 40 MHz clock refuses it at 65.
That is the mistake a glance at the pixel count makes, and it makes it in
the optimistic direction.

The cap reads **39,999,999 Hz** — one hertz under a round 40 MHz, so
800×600@60 is reported MARGINAL rather than refused. (Truncating rather
than rounding also printed it as "39.9 MHz", which invites the same
error. It rounds now.)

**The hardware has since settled it.** 800×600@60 needs exactly
40,000,000 Hz — one hertz over the cap — and it drives this adapter
perfectly:

![800x600 at 60 Hz](doc/m800x600.png)

*800×600@60 at 40.0 MHz, one hertz over the advertised limit. Clean.*

So the cap really is a fencepost, and refusing the mode over one hertz
would have been confidently wrong. MARGINAL still stands as the verdict,
because one adapter agreeing is not every adapter agreeing and the honest
report is "try it".

### Widescreen

**720p is not reachable at any blanking** — 1280×720@60 needs 74.25 MHz
and even CVT reduced blanking wants 64. The clock cap decides it, not the
pixel count. **848×480@60 at 33.75 MHz is the 16:9 mode that fits**, and
it works:

![848x480 widescreen](doc/wide848.png)

*106×30 characters at 848×480 — the same console, native 16:9.*

A modern panel will usually letterbox or stretch 640×480 and 800×600
happily, so those stay the dependable choices; 848×480 is the one worth
trying for a native-aspect picture.

## A second adapter, and what it took

A **USB-to-DVI** part was tried next: also DisplayLink, `17E9:028F`,
"AN2440D3". It did not work at first, and the reason was ours.

```
GET_DESCR device  -> 14  success
SET_ADDRESS       -> 14  success
GET_DESCR config  -> 17  buffer overflow
the device answered, then stopped
```

**The CH375's `GET_DESCR` shortcut reads into the chip's own 64-byte
buffer**, and this adapter's configuration descriptor is 73 bytes. So
enumeration ended with a message blaming the device for a limit of ours.
`BusUp` now falls back to a real control transfer when the shortcut
overflows — possible at that point and not earlier, because the device
descriptor has already supplied `Ep0Max`. Nine bytes is all it needs
there; callers fetch the rest once `wTotalLength` tells them how long it
is. The fix is in the shared `ch375.pas`, so every CH375 project gets it.

It also has **two** bulk OUT endpoints, `01` and `0A`. The endpoint scan
kept whichever came last, which picked `0A` — `udlfb` renders to endpoint
1, so a command stream would have gone into the wrong pipe. First bulk
OUT wins now.

| | VGA adapter `0058` | DVI adapter `028F` |
|---|---|---|
| capability descriptor | 30 bytes | 34 bytes |
| pixel-area limit | 1,500,000 | **2,360,000** |
| pixel-clock limit | 39,999,999 Hz | **not advertised** |
| bulk OUT endpoints | 1 | 2 |
| config descriptor | 62 bytes | **73** — over the shortcut |

![1024x768 on the DVI adapter](doc/hires.png)

*1024×768, 128×48 cells — **65 MHz**, so flatly out of reach of the VGA
adapter's 40 MHz cap, and reachable here because this part advertises no
clock limit at all. The panels are laid out for 80 columns, which is why
they do not fill the width; that is layout, not capability.*

Everything else worked unchanged: the same command stream, the same LFSR
mode registers, the same RLE encoder, the same dashboard. Which is the
useful result — the protocol work generalises across DisplayLink parts,
and what did not generalise was two assumptions in this code.

## A third adapter, which cannot work — and why that is architecture

A **USB-to-HDMI** dongle was tried next. It is **not DisplayLink**:
`1D5C:2000`, Fresco Logic, almost certainly an **FL2000/FL2000DX** paired
with an ITE IT66121 HDMI transmitter. Class `10` (audio/video), three
interfaces, a 232-byte configuration descriptor — which is another device
that only enumerates at all because of the control-transfer fallback added
for the DVI adapter.

It cannot be driven here, and the reason is worth writing down because it
is the mirror image of what made DisplayLink work:

| | DisplayLink | **FL2000** |
|---|---|---|
| framebuffer in the chip | yes | **none** |
| pixel data | **compressed** command stream | **raw** |
| delivery | send a change once, it holds | **streamed continuously at the pixel clock** |

FL2000 is a bridge from USB to parallel RGB. There is nothing in it to
hold a picture between frames, so the whole frame must arrive raw and
keep arriving. 640×480 at 16bpp and 60 Hz is **36.9 MB/s**; this path
measures **19 KB/s**. Short by about **1,900×** — and still **25×** short
of what full-speed USB could carry at its theoretical best. There is no
slow path to fall back on, because a slow path implies something holding
the image, and nothing does.

(Confirmed from the reverse-engineered Linux driver rather than guessed:
pixel data is "raw, uncompressed framebuffer data streamed continuously
at video rate", triple-buffered, on endpoint 1 bulk OUT.)

**So the tools name the family and give the reason.** The identification
is one table in `dl.pas` — `DlFamily`, `DlFamilyName`, `DlFamilyVerdict` —
and `DlOpen` records the answer in `DlDevFamily` before it does anything
else. `DLPROBE` and `DLTEST` both print it from there rather than each
keeping a vendor-ID list of their own, which is the dispatch point a
second backend would hook into if one ever became possible. "Not a
DisplayLink device" is true and useless — it leaves somebody holding a
dongle unsure whether they have the wrong tool or the wrong hardware.
Both `DLPROBE` and `DLTEST` refuse it before sending a single byte, which
is the "identify first, separately" split earning its keep.

### So which adapter should you buy?

**Two properties decide it, and neither is on the box:**

1. a **framebuffer in the chip**, so a picture holds once sent
2. a **compressed** command stream, so sending it is affordable

DisplayLink has both. Fresco Logic has neither. Everything else follows
from that, including the counter-intuitive part: **a USB 3.0 dongle is not
the better choice here.** FL2000 is the newer, faster chip, and it is the
one that cannot work at all — because its speed is exactly what let its
designers dispense with the framebuffer and the compression.

**If you want HDMI, do not buy a USB-to-HDMI dongle.** Buy a **DisplayLink
USB-to-DVI** adapter and put a passive **DVI-to-HDMI** adapter on the end.
DVI-D and HDMI carry the same TMDS signalling, so the converter is wire
and costs nothing.

That is not a suggestion, it is the **tested configuration**: the
`17E9:028F` DVI adapter above was driven through exactly such a converter
into the capture card for every measurement in this file, including
1024×768. The HDMI-native dongle sitting beside it does nothing at all.

| you want | buy | why |
|---|---|---|
| VGA | DisplayLink USB-to-VGA | verified — `17E9:0058` |
| DVI | DisplayLink USB-to-DVI | verified — `17E9:028F` |
| **HDMI** | **DisplayLink USB-to-DVI + passive DVI-to-HDMI** | **verified — same signalling** |
| — | any Fresco Logic / FL2000 dongle | cannot work, see above |

### And this is as far as FL2000 goes

No FL2000 support is written, and none is planned. It is not a matter of
effort: a perfectly implemented backend would still need 1,900 times the
bandwidth available, and there is nothing in the chip to hold a picture
while it waited. Recording *why* is worth more than an attempt that could
only fail, so the reasoning lives in `DlFamilyVerdict` where the tools can
print it to whoever plugs one in.

## The monitor, and why the intersection is the answer

`DLPROBE` reads the attached monitor's EDID **through** the adapter and
intersects it with the adapter's caps, because neither list is the answer
alone:

```
mode          dot clock   adapter                  monitor
640x480@60     25.2 MHz   ok                       yes   <--
640x480@75     31.5 MHz   ok                       yes   <--
720x400@70     28.3 MHz   ok                       yes   <--
848x480@60     33.8 MHz   ok                       (not listed)
800x600@60     40.0 MHz   MARGINAL -- but it WORKS  yes
1024x768@60    65.0 MHz   no -- clock              yes
1280x1024@60  108.0 MHz   no -- clock              yes
```

The bench monitor is a DELL 1708FP whose preferred mode is 1280×1024 at
108 MHz — nearly three times what this adapter will clock. Reading either
side alone gets the answer wrong.

### But EDID says what a display *advertises*, not what it will accept

This turned out to matter, and it was measured rather than reasoned. When
the VGA lead was moved to a capture card, `DLPROBE` started reading **that
device's** EDID instead — and it advertises almost nothing:

```
manufacturer EXN, made week 0 of 2009
preferred mode 1024x768 @ 65.0 MHz
range limits   V 23-61 Hz, H 14-76 kHz
established timings (none flagged)
standard timings    (none)
```

No established timings at all, and a 61 Hz vertical maximum. Yet it
demonstrably syncs **320×200@70** and **848×480@60** — both verified by
photograph, and both outside what it claims.

So the monitor column now reads **listed / not listed** rather than
yes / no, because "no" read as "impossible" and that is simply untrue. The
**adapter** column is the hard one: those are limits the chip states about
itself. A display's list is a hint, and the right response to "not listed"
is to try it.

(The 320×200 result above was therefore confirmed on the capture card,
whose hsync floor is 14 kHz. The padded 449-line frame puts hsync at 31.5
kHz, which is inside the DELL's 30–81 kHz range too — so it should work
there as well, but that is a prediction and not yet a photograph.)

## Speed: what was measured, and what it changed

`DLBENCH` exists because CH375Net has four dead optimisation hypotheses
written up, each of which measured as nothing. It reports **bytes/s
alongside the packet rate**, because a payload-bound path and a
transaction-bound path can report the same KB/s and want opposite fixes.

The first run said **72 packets/s in every test** — 13.9 ms for a 64-byte
packet, when a USB bulk transaction takes microseconds. So the time was
never on the wire. It was 64 iterations of `ch375`'s `WrDat`, each of
which is three nested procedure calls in a Large-model binary; `BENCH`
measures a procedure call on this machine at 46,501/s, so 64×3 is ~4 ms
before a byte reaches a port.

Inlining the packet write into one assembler block:

| | before | after |
|---|---|---|
| solid fill | 5,660 B/s, 72 pkt/s | **19,055 B/s, 291 pkt/s** |
| literal pixels | 5,350 B/s | **14,960 B/s** |
| text-like | 5,132 B/s | **13,267 B/s** |

**3–4× faster**, and USBPKT's hand-written assembly Ethernet path runs
2.9 ms/packet — so this is within 15% of it from portable Pascal.

### What was deliberately *not* done

**`REP OUTSB`.** It is an 80186 instruction that a plain 8086 lacks, so it
needs a run-time CPU gate with an 8086 fallback kept working beside it. At 3.4 ms/packet the byte loop is now ~0.3 ms, so it is worth
about 6%. `CLAUDE.md`'s rule applies: do not write a gated fast path when
the gate costs more than the win buys. One path, runs everywhere, and it
will still be right on a 486.

**Coprocessor maths — for the demos.** There *is* an 8087 fitted (an
earlier version of this file said otherwise; that was a stale note, not a
measurement). It does not help the demos: they are transfer-bound, so at
19 KB/s the geometry is free and the arithmetic could cost nothing without
moving the frame rate. See `DLFRACT` below for where it does earn its
place, and where it does not.

## Moving graphics

A 640×480 16bpp framebuffer is 614,400 bytes and this machine has ~514 KB
of free heap, so **there is no back buffer**. The screen is write-only and
remote, and the only affordable way to animate is to touch what changed.

That is the whole design, and the numbers say why: a full solid screen is
0.66 s, a full screen of literal pixels is 43 s, and a 64×64 rectangle is
44 ms.

All five demos below are measured at 640×480 unless noted, and `build.cmd`
has a target for each: `demo`, `stars`, `bars`, `raster`, `cube`, `lowres`.

| `/D=` | what it is | fps | bytes/frame | bound by |
|---|---|---|---|---|
| `stars` | 120 single-pixel stars | 5.8 | 2,240 | what moved |
| `bars` | sliding colour bars | 5.8 | 2,990 | what moved |
| `balls` | 5 × 28² sprites bouncing | 5.0 | 2,944 | what moved |
| `cube` | rotating 3D wireframe | 1.7 | 3,636 | **CPU** |
| `raster` | **full-screen** raster bars | 1.3 | 12,695 | **pixel count** |
| `raster` | the same at 320×200 | **4.5** | 2,873 | pixel count |
| `life` | Conway's Life, 80×60 cells | 0.9 | 4,611 | **CPU** |

### `stars` — the cheapest thing that can move

![Starfield](doc/stars.png)

*120 stars, one pixel each: erase one pixel, draw one pixel, about 18
bytes per star. 2,240 bytes a frame is the floor for anything animated
here.*

### `balls` — dirty rectangles

![Bouncing sprites](doc/balls.png)

*Five 28×28 sprites at **5.0 fps**. Erase where it was, draw where it is,
touch nothing else. No stale pixels anywhere, which is what says the
erase-and-draw bookkeeping is right.*

### `bars` — full-width motion

![Sliding bars](doc/bars.png)

*Eight bars sliding down the screen. This one had a real bug: the first
version drew without erasing, so 203 frames piled into a striped mess that
looked deliberate enough in a screenshot to pass unnoticed. The capture
caught it.*

### `cube` — the only CPU-bound demo

![A rotating wireframe cube](doc/cube.png)

*A 3D wireframe cube at **1.7 fps**, integer fixed point with a 64-entry
quarter sine table — there is no coprocessor in this machine.*

It started at 0.4 fps **with the same bytes per frame**, which is the
signature that the transfer was never the problem. Three fixes took it to
1.7:

* clearing the render tile with `FillWord` (`REP STOSW`) instead of a
  Pascal loop: `CLAUDE.md` measures 439,821 words/s against 68,322 for a
  per-element store
* blitting straight out of the tile instead of copying each row into a
  staging buffer first — 61,952 needless far-pointer accesses a frame
* shrinking the tile from 176² to 112², which the cube never needed

### `life` — the only demo that sends a *delta*

![Conway's Life](doc/life.png)

*Gliders on an 80×60 grid of 8×8 cells, two of them already collided into
something larger. **0.9 fps**, 4,611 bytes a frame.*

Every other demo either repaints everything or knows exactly which
rectangle it moved. Life knows neither — the cells that change are
scattered and different every generation — so it compares the new state
against the old and sends only the difference. That is the technique a
real terminal or windowing layer would need on this path.

**A delta is only as cheap as the change is small**, and that is worth
stating because it is easy to assume otherwise:

| seed | cells changed / generation | bytes/frame |
|---|---|---|
| random soup | ~1,400 of 4,800 | 88,597 |
| **gliders** | **~55** | **4,611** |

Same code, 20× apart. Nothing about the technique rescues content that
genuinely churns — a random field is most of a full repaint however
cleverly you diff it.

Two fixes got it from 0.1 fps to 0.9, and both were diagnosed the same
way — *the bytes per frame barely moved*:

* the first version forced all 4,800 cells to draw once, at 398,528 bytes.
  The screen is already background from the startup clear, so only the
  **live** cells need drawing.
* the generation step wrapped its edges with `mod`: four divisions per
  neighbour, eight neighbours, 4,800 cells — over 150,000 divisions a
  generation, and `BENCH` rates a 16-bit divide at 52,561/s, so about 2.9
  seconds. Wrapping is a **comparison**, not a modulus.

Changed cells are also merged along the row before drawing, because a cell
is 8 separate scanline runs and two neighbours changing alike are 16 runs
done as 8 — see the orientation measurement below for what ignoring the
horizontal grain costs.

### `raster` — full screen, and the slowest for that reason

![Full-screen raster bars](doc/raster.png)

*Five raster bars repainting the **whole** screen at **1.3 fps**, 12,695
bytes a frame — an order of magnitude more than any other demo here.*

`raster` is the odd one out deliberately: it is the only demo that
repaints everything, which is why it is the slowest **and** the only one
low resolution rescues. Everything else touches just what moved and does
not care about the mode at all.

## Low resolution, and the one thing it actually buys

**A full-screen repaint costs about 12 KB at 640×480 no matter what is on
it.** Each RLE command covers at most 256 pixels, so a screen is ~1,200
commands whether it is one flat colour or a hundred bands. That caps *any*
full-screen effect at roughly 1.5 fps, and no amount of making the content
simpler will move it.

So the lever is pixel count, and that is what low resolution is for.

**320×200 syncs, and it is not obvious that it should.** Hsync is vtotal ×
refresh, and a monitor wants at least 30 kHz; a genuine 320×200 frame has
about 225 total lines, which at 70 Hz is 15.7 kHz — half the minimum. That
is exactly why real VGA never sends 320×200 at all, but line-doubles it
into a 400-line frame. There is no line doubler here, so the frame is
padded instead: 200 active lines inside a 449-line total, keeping hsync at
31.5 kHz. The monitor centres the result and letterboxes it.

![Low-resolution raster bars](doc/lowres320.png)

*Full-screen raster bars in a low-res mode — fast, and visibly not right.*

**Be warned: low-res modes here work but do not look good**, and that is
a real limitation rather than a glitch. The padded 320×200 carries 200
picture lines in a 449-line frame, so 55% of every frame is blanking and
the display letterboxes it into a band. A properly proportioned
`320x240@60` (VGA's timings halved, 92% picture) needs **15.7 kHz** of
hsync — fine on paper, and this capture card mis-locks on it and squeezes
the image into the top half.

So both low-res options are display-dependent and neither renders cleanly
on the hardware here. They are kept because the speed is real and some
displays will take them; `640x400@70` is the standard, un-padded
alternative that always looks right.

The controlled comparison is the useful part, because only one row moves:

| demo | 640×480 | 320×200 | bound by |
|---|---|---|---|
| raster (full screen) | 1.3 fps | **4.5 fps** | pixel count |
| balls (dirty rectangles) | 5.0 | 5.0 | sprite area — unchanged |
| cube (render tile) | 1.7 | 1.7 | CPU — unchanged |

**Low resolution helps full-screen effects and nothing else.** The sprite
demo touches the same number of pixels whatever the mode, and the cube
renders into a fixed 112² tile, so neither changes — which is what makes
the raster row's 3.5× credible rather than just a number that got bigger.

`640x400@70` is also there as a standard, un-padded alternative: a real
VESA timing, a fifth fewer pixels than 640×480, and no letterboxing.

### And a gradient defeats all of it

The first raster demo drew each bar as a smooth gradient, so the colour
changed on nearly every row — 280 unique rows, one run each, **13,741
bytes a frame at 1.1 fps**. Quantising to six shades per bar barely
changes the picture. It did not help much either (12,695 bytes), and that
is what exposed the 256-pixel command cap as the real floor: the cost was
never the number of colour changes, it was the number of pixels.

## Text, which is the case this hardware is good at

A row of 8×16 glyphs is mostly paper, and the RLE command collapses a run
of identical pixels into three bytes however long it is — so **a line
costs what its ink costs, not what its area costs**. A full 80×30 page is
85,376 bytes against 614,400 for the same area raw, and draws in 11.7 s.

The font is the machine's own ROM 8×16 set, found through `INT 10h
AX=1130h`. Nothing is embedded in the binary, so nothing can drift from
the ROM.

A whole page in 11.7 s is a page, not a terminal. The realistic use is
incremental: one changed line is about a twentieth of that.

## The one thing here that is not transfer-bound

Everything above is limited by the USB path. `DLFRACT` is the exception,
deliberately: a Mandelbrot's escape-time loop has no encoding trick that
can make it cheaper, and the tool **times the two halves apart** so that
claim is measured rather than asserted.

![Mandelbrot](doc/mandel.png)

*160×120 computed, 16 iterations, shown as 4×4 blocks at 640×480.*

```
compute   20.3 s
transfer  12.8 s
total     33.2 s      compute is 61% of it
bytes     56,576      against 614,400 for the same area raw
```

**The arithmetic is Q8 and 16-bit, and that is the whole performance
story.** `BENCH` measures a 16-bit multiply on this machine at 58,640/s
against 10,920 for a 32-bit one, because FPC calls a software routine for
`LongInt`. The inner loop needs three multiplies per iteration, so in
`LongInt` this picture would spend about 70 seconds in the multiplier
alone. `MulQ8` is a single 16×16→32 `IMUL` and a shift across `DX:AX`.
`CLAUDE.md` records the same lesson from the dosbridge Mandelbrot: moving
it to Q8 with one `IMUL` was worth more than everything else combined.

(The thin black line on the left spike is the set's own needle along the
real axis between −2 and −1.4, not an artifact.)

### The 8087: measured, not assumed

The machine has an **Intel 8087** (control word `03FF`; 7 of 7 arithmetic
tests pass, including the FDIV round-trip). So "there's a coprocessor,
use it" — and the measurement says that would be the wrong rule:

| path | compute |
|---|---|
| Q8 integer, 16-bit `IMUL` | **20.4 s** |
| 8087, double precision | 40.7 s |

**Two to one to the integer path**, because an 8087 `FMUL` is of the order
of a hundred clocks against roughly 25 for a 16-bit `IMUL`.

**Where the 8087 does earn its place is precision, not speed.** Q8 has
eight fractional bits, so its grid is 1/256 and a zoom runs out of it
fast. `DLFRACT` therefore chooses on whether Q8 can resolve the view:

```
steps per pixel = (768 / zoom) / computed width
```

Below about two, Q8 is quantising rather than drawing, and the
coprocessor is used **if one answered the probe**:

| zoom | Q8 steps/pixel | chosen |
|---|---|---|
| 1× | 4.8 | integer — faster, and enough bits |
| 16× | 0.3 | **8087** — the only one with the range |

![16x zoom on the 8087](doc/zoom8087.png)

*Seahorse valley at 16×, 120 iterations, computed in double precision —
490 s, **97% of it compute**. Q8 cannot draw this at all.*

With no coprocessor fitted the integer path runs throughout and a deep
zoom comes out visibly blocky, which is an honest picture of what the
machine can do rather than a refusal. The probe is `FNINIT` then
`FNSTCW`, both no-wait forms and safe with nothing socketed; the
arithmetic after them is not, so it is never reached unless the probe
answered. `/8` and `/Q` override in either direction.

## Orientation costs more than it looks like it should

The same eight colour bands, drawn horizontally and then vertically.
Identical ink, identical area, and the encoder is a **horizontal**
run-length coder:

| | bytes | time | throughput |
|---|---|---|---|
| 8 bands horizontal | 12,480 | 0.60 s | 20,638 B/s |
| 8 bars **vertical** | 29,120 | **8.2 s** | **3,530 B/s** |

2.3× the bytes — and **13.6× the time**. The byte ratio does not explain
the time ratio, and that gap is the finding: throughput itself collapsed,
so the cost is not on the wire.

It is the encoder. A solid fill is *arithmetic* — `DlFillRun` computes
where each run ends and never looks at a pixel. Arbitrary content forces
`DlRleRun` to **scan all 307,200 pixels** to find the runs. So laying a
picture out across the grain costs twice in bytes and thirteen times in
wall clock, and only one of those two costs is visible in a byte counter.

This is the same effect behind the text console's 11.7 s and the 43 s for
a screen of literal pixels. `DLBENCH` test 6 measures it.

## Loading an image, and scaling it to fit

`DLIMG` reads a `.BMP` — 4, 8, 24 or 32 bpp, uncompressed — and scales it
to whatever mode is selected.

![SMPTE bars scaled to fit](doc/scale.png)

*A 320×180 (16:9) source in a 640×480 mode: drawn 640×**360**, aspect
kept, letterboxed. A 1366×768 source is the same ratio and behaves
identically.*

| `/F=` | 16:9 source into 640×480 | |
|---|---|---|
| `fit` | 640×360 | aspect kept, letterboxed (default) |
| `fill` | 853×480 | aspect kept, cropped 106 px each side |
| `one` | 320×180 | no scaling, centred |

![A photo-like image](doc/image.png)

*A 400×300 24-bit BMP scaled up to 640×480.*

Cost depends entirely on content, which is the encoder's character
showing through again: the SMPTE bars above are flat vertical columns and
cost **19,840 bytes**; the Mandelbrot is 400×300 of detail and costs
**135,744**.

**The image is never held in memory.** A 640×480 24-bit BMP is 921,600
bytes against ~514 KB of heap, and the framebuffer it is going to is
614,400 — neither fits. So the file is read one source row at a time, in
the order the destination needs it: seek, read, scale across, send.
Memory is one source row plus one destination row whatever the picture's
size. That is also why the scaler is nearest-neighbour — with only the
current row in hand there is nothing to interpolate vertically against.

**BMP rows run bottom-up**, which is the trap in the format: a positive
`biHeight` means the first row in the file is the *bottom* of the picture.
An upside-down photograph is a very visible bug that no counter reports.
Both orders are handled.

### The 32-bit arithmetic trap, again

The first version took **207 seconds** for a full screen, of which only 7
were transfer. The scaling loop computed `(X * SrcW) div DW` per pixel —
a 32-bit multiply *and* divide, 307,200 times, at `BENCH`'s 10,920/s and
7,280/s. That is about 70 seconds of arithmetic on its own.

Precomputing the column map once per picture took it to **58.7 s with the
bytes unchanged**, which is the same signature as the cube and Life: when
a change moves the clock and not the byte count, it was never the wire.
`CLAUDE.md` records 32-bit arithmetic costing 5–8× its 16-bit equivalent
on this toolchain; this is the third time that has been the answer.

### Why not PNG or JPEG

**PNG is feasible and not yet done.** It needs a Deflate decoder —
Huffman plus a 32 KB sliding window — which is a few hundred lines and
decodes top-down sequentially, suiting this design. Worth doing.

**JPEG is not worth it.** Huffman, dequantise, an IDCT per 8×8 block,
chroma upsampling and a colour-space conversion, with no coprocessor on
the machine. A single photo would take minutes. PCX would be the cheap
next format: its RLE is a dozen lines.

## A colour screen that changes a little, often

`DLCON` draws a page and stops. `dlscr` is the other half — a text screen
with 16-colour attributes and **dirty tracking**, which is what anything
interactive needs.

![The dashboard](doc/dash.png)

*80×30 cells, everything above drawn from the ROM 8×16 font.*

It keeps two cell buffers: what you asked for, and what is on the glass.
`ScrFlush` sends the difference. The numbers say why that is not an
optimisation but the only reason an interactive screen is possible:

| | bytes |
|---|---|
| full 80×30 repaint | ~192,000 |
| **one dashboard frame** | **5,750–14,500** |

**Colour and boxes cost nothing extra.** The attribute is one byte a cell,
ink in the low nibble and paper in the high — exactly what it has always
meant in DOS — and the CP437 line-drawing characters are already in the
ROM font, so a double-ruled border costs what the same number of letters
costs. `ScrBox` is three lines. The gauges use the CP437 shade characters
for the partial cell, which gives four sub-steps per cell free and makes a
slow gauge visibly move instead of jumping.

### What actually costs, measured

| | cells/frame | bytes/frame | fps |
|---|---|---|---|
| with the scrolling ticker | 154 | 13,059 | 0.4 |
| **ticker off** (`/T=0`) | **64** | **5,750** | **0.9** |

**The ticker is 58% of everything the screen sends**, because scrolling
text changes an entire row every time it moves. That is not a bug — it is
what scrolling costs on a path where bytes are time — so it is a knob
(`/T=n`) rather than a fixed tax.

Two things got it there, both found by the same tell as everywhere else in
this project:

* the furniture — panels, borders, titles — was being rebuilt every
  frame. The diff correctly declined to send any of it, so it was pure
  CPU spent proving nothing had moved. Drawn once now.
* the ticker built its row with `S := S + TICKER[C]`, which copies the
  whole string on every append: 3,200 character moves a frame to produce
  80 cells. It writes cells directly now.

And one that **measured as nothing**: unrolling the 8-bit glyph inner
loop, the innermost code in the unit at ~20,000 trips a frame, changed
the frame rate not at all. It was applied and it is genuinely ineffective
— recorded because `CLAUDE.md` keeps a list of exactly these, and a
plausible optimisation that does nothing is worth knowing about twice.

`/K` makes it interactive — Tab selects a gauge, `+`/`-` adjust it, `L`
logs, `R` forces a full repaint, Esc quits. **That path is written but
not yet verified by a human at the keyboard**, which is the only
instrument that can check it.

## 1280x1024, and a television

Driven against a 4K TV through the DVI adapter and a passive DVI-to-HDMI
converter. Its *preferred* mode is 3840x2160 at 297 MHz, which is far out
of reach — so this is the case the intersection was built for: the display
also advertises 640x480, 800x600, 1024x768 and 1280x1024, and `DLPROBE`
picks the largest the adapter allows. **1280x1024 works**, at 160x64 cells.

`DLPROBE` now derives the full timing from the EDID rather than matching
against a table — actives, blanking, sync offsets and widths, and the
clock. The porches have to be *derived* rather than read, which is the
only subtle part:

```
front porch = sync offset
sync        = sync pulse width
back porch  = blanking - offset - width
```

Getting that subtraction backwards shifts the picture sideways and still
syncs, which looks exactly like a monitor needing its auto-adjust.

**A timing that is out of range is not a timing that failed to decode**,
and the tool used to report both the same way. 3840x2160 parses perfectly
and is simply beyond this hardware; calling that "did not decode" blames
the descriptor for a limit of ours — the same mistake the CH375's
`GET_DESCR` shortcut made. It now says which.

### Two things that made a wide screen affordable

A 160x64 screen is 10,240 cells, and the first dashboard frame was sending
**8,214** of them. Two fixes, both about not sending what cannot be seen:

**A space renders as solid paper, so its ink colour is invisible.** The
dirty check compared the whole attribute byte, so a grey-on-black space
counted as different from a black-on-black one. A log panel padded out
with spaces in its text colour therefore covered 6,776 unchanged cells —
two thirds of a full repaint, to draw nothing anybody could see. Spaces
are now compared on their **paper** only: **8,214 cells a frame to 297**.

**The layout is sized to the screen.** The panels were fixed at 80x30, so
a 160x64 mode drew a small dashboard in the corner and left two thirds of
the screen empty. The log panel now fills whatever is left above the
ticker.

One memory note for anyone going further: at 160x64 `dlscr`'s two cell
buffers are 40 KB of a 64 KB data segment. The log lines had to drop from
`ShortString` (256 bytes each, whatever is in them) to `string[110]` just
to fit. **A mode larger than 1280x1024 means moving those cell buffers to
the heap.**

## Proving the machine is alive, and getting out

Every tool here runs for tens of seconds with all its output buffered to
the end, and **none of them proved they were alive**. Run from the bridge
that is merely unhelpful. Run from the machine's own prompt it is
indistinguishable from a lockup — `DLDASH` cost a power cycle for exactly
that reason. Nothing printed, and nothing answered the keyboard either,
because a loop doing port I/O never calls DOS, so Ctrl-Break is never
seen.

`CLAUDE.md` states the rule and this project broke it in six places:

> A program that runs for more than a few seconds must prove it is alive,
> and the proof has to be driven by the CLOCK.

So `DlTick` writes a spinner and `DlEscaped` watches for Esc, in every
long-running loop — `DLDASH`, `DLDEMO`, `DLFRACT`, `DLIMG`, `DLCON`.
Three parts, each load-bearing:

* **stderr, not stdout.** A job's stdout is redirected into a file and
  reaches nobody until the job ends; DOS cannot redirect handle 2 at all,
  so this lands on the real screen where somebody is looking.
* **driven by the tick, not the work.** It stops when the *machine* stops,
  not when the work merely pauses — which are the two cases most worth
  telling apart.
* **in place**, so it scrolls nothing.

`DLFRACT` was the worst of them: up to **490 seconds** of complete silence.

### What the display is left showing

The adapter has its **own framebuffer**, so it keeps the last thing it was
sent after the program exits. There is nothing to "close" — that is what
lets a dashboard stay up after the tool that drew it has gone. But it
surprises anyone expecting a program to tidy its screen away, so the tools
now say so on exit, and `/B` blanks it instead.

The chip itself *is* closed down properly and always was: an `ExitProc`
retires any stranded token with `ABORT_NAK` and restores the retry policy,
which is what stops the next program reporting "no CH375 at 0260" on a
card that is plainly fitted.

## Traps, all of them paid for here

**Every transfer must be padded with `AF`.** The parser does not act on
the final command until more bytes follow it, so an unpadded transfer
silently drops its last command — 256 pixels, seen as a strip of the
*previous* picture surviving in the bottom-right corner. That reads as a
drawing bug or an address off-by-one and is neither: the addresses were
right and the fault was framing. `udlfb` does this with a `memset` that is
easy to read as housekeeping and skip. `DLTEST`'s **test 5** exists for
this failure alone — white over blue, asking only about that corner —
because folding it into "did you see white" hid it.

**Most timing registers take their value through a 16-bit LFSR.**
Registers `01`–`15` are `lfsr16(value)`; `0F` and `17` are plain
big-endian; `1B` is byte-swapped. Raw values give a dead screen and
nothing to diagnose. Taken from `udlfb`; going to that source instead of
trying register values is the decision that made any of this work.

**A picture landing off-centre is usually the monitor.** The first working
pattern sat ~100 px right of centre; the fix was the monitor's own
auto-adjust. `/X` and `/Y` can move the active region within the line
without changing either total or the dot clock, but they have **no
default** — compensating in software for one monitor's un-adjusted
position would have baked this bench into the tool.

**An animation that never erases is not fast, it is wrong.** The first
bars demo drew without erasing, and 203 frames piled into a striped mess
that looked deliberate enough in a screenshot to pass unnoticed. The
capture caught it.

**Polling an endpoint that never answers wedges the chip.** `WaitInt`
gives up; the chip does not. A program exiting then strands the token, and
the next tool reports **"no CH375 at 0260" on a card that is plainly
fitted**. It cost a power cycle. Everything here retires the token with
`ABORT_NAK` on exit and resets-and-re-asks before believing the slot is
empty, because `BusUp` gives up on a failed `CHECK_EXIST` before reaching
its own `ChipReset`.

**Bring-up resets the USB bus, which blanks the adapter.** So every tool
run starts with a dark screen until it sets a mode — which is why a
capture taken *during* a run's startup shows black, and one taken after a
run completes shows the last frame. The adapter holds its output between
runs.

**The retry policy is opposite for the two transfer types.** `8F` (retry
NAKs in hardware) is right for a control data stage and wrong for a data
endpoint, where a NAK is an *answer*. Absorbing it turned six honest NAKs
into six timeouts reported as "no interrupt".

**EDID is read two bytes at a time**, only the second byte being data, and
**all 128 bytes coming back zero is two findings** — the control path
works, and the adapter has nothing to describe. Nothing is decoded from a
zero block: 128 zeroes sum to zero, so it passes the EDID checksum
trivially.

**Git Bash mangles `/K` into a Windows path** before Python sees it, so
program flags passed through `dosctl run` from bash silently vanish. Every
tool here accepts `-K` as well; `cmd` and PowerShell pass either form.

## Next

1. **Only redraw what changed in text.** The console redraws a whole page;
   tracking dirty rows would make it a usable terminal.
2. **Derive timings from the EDID** rather than a built-in table, so any
   monitor's preferred mode is used when it fits inside both caps.
3. **A second DisplayLink adapter.** Everything here is measured on one
   `17E9:0058`. The capability descriptor is read rather than assumed, so
   another should work, but that is a prediction and not a result.
4. **A 486 would change which half is the bottleneck.** The cube is
   CPU-bound here and everything else is transfer-bound; on a faster CPU
   the cube would join the others, and only then would `REP OUTSB` or a
   coprocessor be worth re-measuring.

---

Written by **StevenC** and **Claude** (Anthropic): StevenC guiding, deciding and testing on real hardware, Claude doing most of the analysis, code and measurement.
