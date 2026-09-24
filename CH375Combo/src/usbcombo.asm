; ==========================================================================
; USBCOMBO.COM -- one DOS driver for a USB keyboard AND a USB mouse sharing
;                 a single WCH CH375 in host mode.
;
;   Version 1.0.0                                                  StevenC & Claude
;   CH375Combo.  Public domain (the Unlicense).
;
; WHY THIS EXISTS.  USBMOUSE.COM and USBKBD.COM cannot both be loaded.  Each
; resets the CH375, enumerates from scratch, assigns the USB address and
; hooks INT 08h to poll it; two of them on one chip reset it out from under
; each other and interleave transactions with no locking at all.  One
; CH375, one host driver -- and until now that meant choosing.
;
; A USB-to-PS/2 adapter makes the choice unnecessary and unwanted.  It is
; ONE low-speed USB device with TWO boot HID interfaces on it:
;
;   INTERFACE 0   class 03/01/01  boot keyboard   EP 81 IN  interrupt  max 8
;   INTERFACE 1   class 03/01/02  boot mouse      EP 82 IN  interrupt  max 5
;
; Two interfaces, two interrupt IN endpoints, one device address, one
; enumeration.  So this driver enumerates once, claims both interfaces, and
; polls both endpoints from the same timer hook -- keys into the BIOS
; keyboard buffer the way CH375Keyboard does it, motion and buttons out
; through INT 33h the way CH375Mouse does.
;
; It is not limited to an adapter.  A plain keyboard brings up the keyboard
; half alone, a plain mouse the mouse half alone, and a combo dongle that
; presents both gets both.  Whichever halves enumerate are the halves that
; run; /S says which.
;
;   USBCOMBO [@260] [/S] [/U] [/F] [/V] [/N] [/NK] [/NM] [/C] [/E] [/K]
;            [/T] [/R=n] [/D=n] [/T=n] [/Y=n] [/X=hh]
;       @nnn    CH375 I/O base in hex, default 260
;       /S      report status of an already-loaded copy, both halves
;       /U      unload
;       /F      install even if nothing enumerates, and keep looking
;       /V      trace each bring-up step and the status it returned
;       /NK     ignore the keyboard interface; drive the mouse only
;       /NM     ignore the mouse interface; drive the keyboard only
;       /M=n    poll the mouse endpoint every nth fast tick, default 2.
;               The keyboard is polled every tick and is not adjustable:
;               it reports state rather than events, so a lower rate loses
;               and reorders keystrokes.  A mouse reports deltas and loses
;               nothing by being read less often
;       /Q      do not flush a stale CH375 interrupt before issuing a
;               token.  This reproduces the cross-talk between the two
;               endpoints that ch_flush exists to stop, which is the only
;               reason to want it.  A diagnostic, never a setting
;       /C      do not ask the mouse for the boot protocol, so its native
;               report-ID packets are what arrives.  A diagnostic: the
;               driver copes with either, and this is how the coping gets
;               tested.  See THE REPORT-ID WRINKLE below
;       /N      do not drive the lock LEDs
;       /E      claim a 101/102-key keyboard in 40:96 bit 4
;       /K      inject keys through the 8042 (command D2h) instead of
;               writing the BIOS buffer.  Needs an AT-class controller;
;               this machine has none and says so at load time
;       /T      self-test both halves and exit without going resident:
;               drive a usage through to INT 16h, and a mouse report
;               through to the INT 33h coordinates.  Needs no keypress
;       /X=hh   pretend HID usage hh is held down, bounded to 64 repeats
;       /Y=n    HID idle rate for the keyboard in 4 ms units, default 0
;       /R=n    timer divisor, PIT rate = 18.2 * n Hz.  Default 16 (291 Hz),
;               n = 1..16.  Lower it and the keyboard starts dropping and
;               transposing characters -- see the note by tick_n
;       /M=n    poll the mouse every nth fast tick, default 2.  This
;               must stay ABOVE the device's own report rate -- 100 Hz
;               here, from a 10 ms bInterval -- or movement is discarded
;               rather than accumulated and the pointer crawls
;       /G=n    mouse speed multiplier, default 16.  BIGGER IS FASTER and
;               there is no ceiling: /G=8 moves the pointer eight times as
;               far for the same hand movement.  It multiplies the raw
;               delta, so it stacks with whatever sensitivity the
;               application sets through INT 33h rather than fighting it.
;               Note that a faster pointer is a choppier one -- see the
;               note by `gain`
;       /D=n    typematic delay before repeat, in fast ticks.  Default 144
;       /T=n    typematic period, in fast ticks.  Default 10
;
; HOW KEYS REACH DOS.  Scancode/ASCII words go straight into the BIOS
; keyboard buffer at 0040:001E with the tail moved at 0040:001C, which is
; what a real keyboard interrupt does, and the shift state is maintained at
; 0040:0017 alongside.  Everything that reads through INT 16h or through
; DOS sees them.  A program that hooks INT 09h and reads the controller
; itself never looks at that buffer and so never sees any of this -- DOS
; EDIT is one, and CH375Keyboard/README.md has the whole measurement.
;
; HOW THE MOUSE REACHES DOS.  INT 33h, functions 00h..24h, with a
; text-mode software cursor.  The same implementation as CH375Mouse, minus
; the PS/2 BIOS emulation: that exists to make Windows 3.x see a pointing
; device, and Windows running over a driver that divides the PIT underneath
; it is a separate argument.  Load USBMOUSE for that job.
;
; TWO ENDPOINTS, TWO DATA TOGGLES.  The CH375's SET_ENDP6 carries the data
; toggle for the transaction about to be issued, and USB keeps a toggle PER
; ENDPOINT.  Polling two endpoints from one driver through one toggle
; variable makes every second transaction on each of them a toggle
; mismatch, which the chip reports as 2Bh and which reads as a flaky
; device.  So ep_tog and mep_tog are separate, and each is written
; immediately before its own token.
;
; THE REPORT-ID WRINKLE.  The mouse interface on this adapter declares HID
; report IDs -- 1 for the pointer, 2 for system control, 3 for consumer
; keys.  In its native mode every packet therefore arrives with a leading
; ID byte, so a 3-byte boot-report parser reads the button bitmap out of
; the ID field and the X movement out of the buttons.  SET_PROTOCOL 0 asks
; for the boot report instead and this adapter obliges, but a device is
; free to ignore that request and some do.  So poll_mou does not trust it:
; it looks at the length of what actually turned up and at byte 0, strips
; an ID when there is one, and drops reports 2 and 3, which are not
; pointer data at all.  /C forces the untrusted path so it gets exercised.
;
; WHY A TIMER HOOK -- DOS is not reentrant and the CH375 has no useful IRQ
; wiring on this card, so both endpoints are polled.  18.2 Hz is too slow
; to type through and far too slow to move a pointer with, so INT 08h is
; taken over and the PIT divided by 8; the original handler is still called
; every 8th tick, so BIOS timekeeping, DOS's own clock and anything else
; chained on INT 08h see the rate they expect.
;
; THE REPORT FORMAT HAS TO BE READ OFF THE PACKET.
;
; This adapter's mouse interface declares HID report IDs -- 1 for the
; pointer, 2 for system control, 3 for consumer keys -- so every packet it
; sends leads with an ID byte:
;
;   01 01 F8 0B 00      ID 1, left button, X = -8, Y = +11, wheel 0
;   01 03 0E F6 00      ID 1, left+right,  X = +14, Y = -10
;
; It also answers SET_PROTOCOL 0 with SUCCESS and then carries on sending
; exactly that format regardless.  So the request is issued -- it is the
; right thing to ask for, and a device that honours it makes life simpler --
; but its answer is not trusted for anything.  mou_strip_id looks at the
; length and at byte 0, strips the ID from report 1, and drops reports 2 and
; 3, which are not pointer data at all: reading a system-control packet as a
; boot report puts a power-button press into the mouse buttons.
;
; VERIFIED with a hand on the mouse: 90 reports used, 0 rejected, the
; pointer tracking from 320,100 to 414,19, and the button bits following
; 00 -> 01 -> 03 as left and then both were pressed -- while the keyboard
; half delivered keys into the BIOS buffer at the same time.
;
; A WRONG TURNING WORTH RECORDING.  Before anyone had moved the mouse, this
; endpoint delivered a steady stream of 01 00 XX 00 00 -- report 1, no
; buttons, a small varying X, Y and wheel zero.  Two observations made that
; look like the chip inventing packets rather than a mouse sending them:
; polling this endpoint alone appeared to give nothing at all, and of 441
; packets, 441 carried movement and none carried none.
;
; Both readings were wrong.  SET_IDLE 0 means "report only when something
; changes", so every report from a healthy mouse carries a change -- a
; stream in which they all do is exactly right, not impossible.  And the
; runs that saw nothing had a mouse that happened to be sitting still; the
; idle stream was a real, slightly noisy mouse.
;
; The version built on that mistake refused any packet longer than a boot
; report, reasoning that the device had acknowledged SET_PROTOCOL 0 and so
; could not be sending five bytes.  It threw away 100% of real mouse data,
; and every injected-report check still passed while it did -- because
; injected reports never go near the USB read.  What caught it was moving
; the mouse and watching COMBOTST /W.
;
; The lesson is not about this chip: "no real device would send this" is a
; claim about the device, and the way to settle it is to make the device
; send something known, not to reason about what the bytes ought to be.
;
; THE TWO ENDPOINTS DO NOT WANT THE SAME RATE.  The keyboard is polled on
; every fast tick, because a boot keyboard report is the SET of keys held
; right now in no defined order -- so a keypress completed between two polls
; never happened, and two keys arriving in one report are delivered in
; whatever order the device listed them.  Missing and transposed characters,
; both measured, both only made rarer by a shorter window: 7 ms at the
; default 145 Hz, 3.4 ms at /R=16.  A mouse report is a DELTA and loses
; nothing by being read less often, so it gets every /M=n-th tick, 2 by
; default.  The long note in poll_kbd has the detail.
;
; CLD FIRST.  The direction flag belongs to whoever was interrupted, and
; this handler's path is full of string operations: STOSB in ch_read, LODSB
; in both control-transfer builders, REP STOSB and REP MOVSB in the report
; diff.  Every one runs backwards on DF=1, writing over whatever lies below
; the buffer instead of filling it -- a fault that depends entirely on what
; the foreground program was doing, so the driver works perfectly until it
; suddenly does not.  tick_body starts with CLD.  The rule came from
; davidegat's independent CH375 stack: https://github.com/davidegat/CH375USB
;
; ASSEMBLING -- either of these produces the same image:
;       nasm -f bin usbcombo.asm -o USBCOMBO.COM
;       MNASMFIX -O9 -f bin -o USBCOMBO.COM USBCOMBO.ASM     (on the DOS box)
; Every jump carries an explicit short/near at its natural size, because
; mininasm shortens jumps on every pass and a forced-long jump never
; converges.  Do not widen one to fix a range error -- add a trampoline.
; ==========================================================================

        cpu     8086
        bits    16
        org     0x100

; ---- CH375 commands ----
CMD_GET_IC_VER   equ 0x01
CMD_SET_SPEED    equ 0x04
CMD_RESET_ALL    equ 0x05
CMD_CHECK_EXIST  equ 0x06
CMD_READ_REG     equ 0x0A
CMD_SET_RETRY    equ 0x0B
CMD_SET_USB_ADDR equ 0x13
CMD_SET_USB_MODE equ 0x15
CMD_TEST_CONNECT equ 0x16
CMD_SET_ENDP6    equ 0x1C
CMD_SET_ENDP7    equ 0x1D
CMD_GET_STATUS   equ 0x22
CMD_RD_USB_DATA  equ 0x28
CMD_WR_USB_DATA7 equ 0x2B
CMD_CLR_STALL    equ 0x41
CMD_SET_ADDRESS  equ 0x45
CMD_GET_DESCR    equ 0x46
CMD_SET_CONFIG   equ 0x49
CMD_ISSUE_TOKEN  equ 0x4F

INT_SUCCESS      equ 0x14
INT_CONNECT      equ 0x15
INT_DISCONNECT   equ 0x16
INT_STALL        equ 0x2E

PID_OUT          equ 0x01
PID_IN           equ 0x09
PID_SETUP        equ 0x0D

USB_ADDR         equ 2

; ==========================================================================
; RESIDENT IMAGE
; ==========================================================================

entry:
        jmp     near init                       ; 0100

; An already-resident copy is found by walking the INT 08h chain and
; looking for this string at a fixed offset.  It must stay at 0103 -- /U
; and /S both depend on it, and installing a second copy over the first
; would leak the interrupt vectors of the one underneath.
signature:
        db      'USBCMB01'                      ; 0103

; The version, in ASCII, ending in '$' so it can be printed as it stands.
; It is resident and sits immediately after the signature, so /S reports
; the version of the copy ALREADY LOADED rather than its own -- which is
; the interesting number when two builds are in play.
ver_str:
        db      '1.1.0$'                        ; 010B

; Where the translation tables are, so KBDTST can read them straight out of
; the resident image and check them against hidkey.pas key by key.  Two
; hand-written copies of the same mapping is exactly the kind of thing that
; drifts silently, so the check is automated rather than trusted.  This
; block is part of what a resident copy promises, the same way the
; signature at 0103 and the version at 010B are: it starts at 0111.
tab_ptr:                                        ; 0111
        dw      tab_scan                        ; 0111
        dw      tab_mod                         ; 0113
        dw      tab_plain                       ; 0115
        dw      tab_shift                       ; 0117
        dw      tab_ext                         ; 0119
        dw      tab_ext_n                       ; 011B
        dw      n_reports                       ; 011D
        dw      n_keys                          ; 011F
        dw      n_full                          ; 0121
        dw      live                            ; 0123
        dw      locks                           ; 0125
        dw      ep_in                           ; 0127
        dw      tick_n                          ; 0129
        dw      n_polls                         ; 012B
        dw      op_enh                          ; 012D
        dw      old08                           ; 012F -- see do_unload
        dw      op_kbc                          ; 0131
; The mouse half's own published fields, appended rather than interleaved so
; that every offset a CH375Keyboard-era tool already knows stays where it
; was.  0111..0131 is USBKBD's block, byte for byte.
        dw      old33                           ; 0133 -- see do_unload
        dw      mep_in                          ; 0135
        dw      mlive                           ; 0137
        dw      m_reports                       ; 0139
        dw      cur_x                           ; 013B
        dw      cur_y                           ; 013D
        dw      buttons                         ; 013F
        dw      mou_id                          ; 0141
        dw      has33                           ; 0143
        dw      mwire_buf                       ; 0145
        dw      mrep_len                        ; 0147
        dw      n_tmo                           ; 0149
        dw      m_tmo                           ; 014B
        dw      n_flush                         ; 014D
        dw      n_replen                        ; 014F
        dw      mou_boot                        ; 0151
        dw      m_bogus                         ; 0153
        dw      rep_buf                         ; 0155 -- the keyboard's own
                                                ; last report, so a live view
                                                ; can show both endpoints
        dw      m_ignored                       ; 0157
        dw      m_short                         ; 0159
        dw      ps2_on                          ; 015B
        dw      gain                            ; 015D -- COMBOTST sets this
                                                ; to 1 around its arithmetic
                                                ; checks and puts it back

; ---- saved vectors ----
old08:  dd      0
old33:  dd      0

; ---- hardware ----
io_dat: dw      0x260
io_cmd: dw      0x261
ep_in:  db      0                ; interrupt IN endpoint number
ep_tog: db      0x80             ; SET_ENDP6 argument: bit 6 is the toggle
kbd_if: db      0                ; bInterfaceNumber of the keyboard
cfg_val:db      1
ep0max: db      8

; The mouse half's share of the same device.  mep_tog is not a duplicate
; kept for tidiness: the data toggle is per endpoint, and one variable
; shared between two endpoints makes every second transaction on each of
; them a toggle mismatch.
mou_if: db      0                ; bInterfaceNumber of the mouse
mep_in: db      0                ; its interrupt IN endpoint
mep_tog:db      0x80             ; and its own data toggle
mlive:  db      0                ; 1 = a mouse enumerated
mou_id: db      0                ; 1 = its reports carry a leading report ID
mou_boot:db     0                ; 1 = it ACKNOWLEDGED SET_PROTOCOL 0.
                                 ; Reported by /S and otherwise unused: this
                                 ; adapter says yes and then sends its
                                 ; report-ID format anyway, so the answer
                                 ; cannot be relied on for anything
has33:  db      0                ; 1 = we took INT 33h and owe it back

; ---- PS/2 BIOS pointing-device emulation, for Windows 3.x (/W) ----
old15:  dd      0
old11:  dd      0
old74:  dd      0
op_ps2: db      0                ; /W asked for it
ps2_on: db      0                ; ...and it is installed
ps2_en: db      0                ; INT 15h C200h BH=1 has enabled reporting
ps2_hof:dw      0                ; the callback registered by C207h
ps2_hsg:dw      0
ps2_pnd:db      0                ; a packet is waiting to be delivered
ps2_st: db      0                ; the three PS/2 packet bytes
ps2_x:  db      0
ps2_y:  db      0
ps2_pkt:db      3                ; package size from C205h

; The ROM configuration table INT 15h AH=C0h hands back.  Windows 3.0's
; MOUSE.DRV reads the model byte at offset 2 and insists on F8h, FAh or FCh
; before it will believe a pointing device exists.  FCh also makes it choose
; INT 74h, which is free on an XT-class box.  The feature bytes claim
; nothing, because nothing else here is being emulated.
cfg_tab:
        dw      8                        ; bytes following
        db      0FCh                     ; model:    PS/2 class
        db      004h                     ; submodel
        db      000h                     ; BIOS revision
        db      000h, 000h, 000h, 000h, 000h
kb_found:db     0                ; what parse_config decided, before the
mo_found:db     0                ; bring-up commits it to live / mlive
op_nokbd:db     0                ; /NK ignore the keyboard interface
op_nomou:db     0                ; /NM ignore the mouse interface
op_noboot:db    0                ; /C do not ask the mouse for boot protocol
op_noflush:db   0                ; /Q leave stale interrupts alone (see ch_flush)
; The keyboard is polled on EVERY fast tick and the mouse on every
; mou_div-th one.  The two do not want the same rate -- see the long note in
; poll_kbd.  /M=n sets the divisor; 1 means the mouse every tick as well.
; 2, giving the mouse 145 Hz at the default tick rate.
;
; This was 4 -- 73 Hz -- on the reasoning that a delta-reporting device
; loses nothing by being read less often, since two small movements read as
; one larger movement leave the pointer in the same place.  THAT IS WRONG,
; and it showed up as a pointer that crawled.
;
; It would be true only if the device accumulated movement until asked.  An
; interrupt endpoint does not work that way: the device prepares a report
; each bInterval and a report the host never collects is replaced by the
; next one.  This adapter's bInterval is 10 ms, so it offers up to 100
; reports a second, and polling at 73 Hz simply discards about a quarter of
; the movement.  145 Hz is comfortably above what it can generate, so
; nothing is dropped.
;
; The general rule: poll an interrupt endpoint FASTER than its bInterval,
; never slower, whatever the payload means.
mou_div:  db    2
mou_cnt:  db    1
turn_mou: db    0                ; 1 = the mouse gets this tick

; ---- timing ----
; 16, not the 8 CH375Keyboard uses, and the difference is measured rather
; than chosen.  At 145 Hz -- one look at the keyboard every 7 ms -- typing
; abcdefghijkl twice produced "abcdefghjikl" and "abcdefjilkl": characters
; dropped, and i/j transposed because both landed in one report.  At 291 Hz
; the same test produced "abcdefghijklabcdefghijkl", exactly right.
;
; The keyboard cannot do better than the poll rate: a boot report is the set
; of keys held right now, in no order, so anything completed between two
; polls is invisible and anything simultaneous is unordered.  Halving the
; window halves both.  /R=n still overrides it.
tick_n: db      16               ; PIT divisor asked for on the command line
tick_c: db      16               ; countdown to the next downstream tick
on_top: db      1                ; 1 = INT 08h still points at us
in_poll:db      0                ; reentrancy guard for the CH375
live:   db      0                ; 1 = a keyboard enumerated
low_spd:db      0                ; 1 = bus was dropped to 1.5 Mbps
retry_c:db      0                ; ticks until the next hot-plug retry

; ---- typematic ----
; Both are counted in FAST ticks, so they have to move with tick_n above --
; carrying the old 72/5 to a doubled rate would give a quarter-second
; typematic delay and 58 repeats a second, which feels like a fault.  At the
; default 291 Hz these are about half a second and 29 a second, matching what
; CH375Keyboard delivers at 145 Hz with 72/5.
rep_delay: dw   144              ; fast ticks before the first repeat
rep_rate:  dw   10               ; fast ticks between repeats
rep_key:   db   0                ; usage currently repeating, 0 = none
rep_mods:  db   0                ; modifiers as they were when it went down
rep_cnt:   dw   0                ; countdown

; ---- keyboard state ----
prev_rep: times 8 db 0           ; the last report, for the press/release diff
cur_mods: db    0
; bit0 num, bit1 caps, bit2 scroll -- the same bit order as the LED
; report.  This is a VIEW of 0040:0017, not a second copy of it: the BIOS
; owns the lock state, and the driver reads it, follows it, and toggles it
; in place.  See adopt_locks for why that matters.
locks:    db    0
own_enh:  db    0                ; we were the one who set 40:96 bit 4
led_now:  db    0xFF             ; what the keyboard's lights are set to
op_leds:  db    1                ; /N clears this
op_enh:   db    0                ; /E sets 40:96 bit 4 as well
op_kbc:   db    0                ; /K injects through the 8042 instead
op_test:  db    0                ; /T self-test the delivery path and exit
op_hook:  db    0                ; /H deliver through an INT 16h hook
op_hold:  db    0                ; /X=hh pretend usage hh is held down
op_wake:  db    0                ; /W call INT 09h after delivering a key
hold_n:   dw    0                ; ...this many more times, then stop
old16:    dd    0
RINGN     equ   16               ; words; a key is one word
ring:     times RINGN * 2 db 0
ring_h:   dw    0                ; read cursor, in bytes
ring_t:   dw    0                ; write cursor
n_ring:   dw    0                ; keys served through the hook
n_rfull:  dw    0                ; keys dropped because the ring was full
hid_idle: db    0                ; /Y idle rate, 4 ms units, 0 = on change
n_kbcbad: dw    0                ; injections the controller refused

; --------------------------------------------------------------------------
; MOUSE STATE.  Everything INT 33h reports, and everything a report changes.
; The layout is CH375Mouse's, unchanged, because MOUSETST and CLICKTST read
; it through the private INT 33h functions below and there is no reason to
; make them learn a second one.
; --------------------------------------------------------------------------
cur_x:  dw      320              ; virtual coordinates, 0..639 x 0..199
cur_y:  dw      100
min_x:  dw      0
max_x:  dw      639
min_y:  dw      0
max_y:  dw      199
buttons:dw      0
mick_x: dw      0                ; motion counters for function 0Bh
mick_y: dw      0
frac_x: dw      0                ; sub-unit remainder of the scaling
frac_y: dw      0
; Mickeys per 8 virtual units, as INT 33h functions 0Fh and 1Ah define
; them: SMALLER is faster, and Y is twice X because the default range is 640
; wide and 200 tall.  These belong to the APPLICATION -- most set them
; themselves -- so /G no longer touches them.  It used to, which made /G
; read backwards and gave it a hard ceiling of 8x, because the scaling
; divides by these and they cannot go below 1.
m8_x:   dw      8                ; mickeys per 8 virtual units (function 0Fh)
m8_y:   dw      16

; The driver's own speed multiplier, applied to the raw delta BEFORE the
; INT 33h scaling above.  /G=n, bigger is faster, 1 = textbook rate.  It
; multiplies rather than divides, so there is no ceiling.
;
; This exists because the pointer is not poll-limited and cannot be fixed by
; polling harder.  Moving continuously, this adapter emits about 33 reports
; a second -- that is the PS/2 mouse's own sample rate coming through it --
; while the driver polls the endpoint at 145 Hz.  Nothing is being missed;
; there is simply not much to collect, and each report carries a small
; delta.  Multiplying it is the only lever left.
;
; The cost is honest and worth stating: at 33 reports a second, a larger
; multiplier means bigger jumps between samples, so a faster pointer is a
; choppier one.  That chop is the device's sample rate showing through and
; no driver setting removes it.
;
; The true mickey counters that function 0Bh reports are taken BEFORE this
; is applied, so an application measuring raw movement still sees the truth.
; 16, not the textbook 1.
;
; A multiplier of 1 means one screen unit per mickey, which is right for a
; mouse reporting a hundred-plus times a second.  This adapter emits about
; 33, so 1 gives a pointer that crawls -- unusable in practice however
; correct it looks on paper.  16 was arrived at by trying it on the
; hardware: 8 was still slow, 16 felt right.  /G=1 restores textbook
; behaviour for a device that does not need the help.
gain:   dw      16
vis:    dw      -1               ; cursor counter, -1 = hidden
drawn:  db      0                ; cursor currently painted on screen
draw_off:dw     0                ; where, and what was under it
draw_old:dw     0
scr_msk:dw      0x77FF           ; text cursor masks (function 0Ah)
cur_msk:dw      0x7700
vid_seg:dw      0xB800
vid_col:dw      80

; per-button press/release bookkeeping, three buttons
press_n:  dw    0, 0, 0
press_x:  dw    0, 0, 0
press_y:  dw    0, 0, 0
rel_n:    dw    0, 0, 0
rel_x:    dw    0, 0, 0
rel_y:    dw    0, 0, 0

; user event handler (function 0Ch)
ev_mask:dw      0
ev_off: dw      0
ev_seg: dw      0
ev_cond:dw      0                ; what the last report did, as a 0Ch mask

mwire_buf: times 8 db 0          ; the packet exactly as it arrived
mrep_buf: times 8 db 0           ; and the 3-byte boot-shaped report taken
                                 ; out of it.  Two buffers rather than one
                                 ; because stripping a report ID in place
                                 ; destroys the evidence of what the device
                                 ; really sent -- and on a device whose
                                 ; report format has to be guessed, that
                                 ; evidence is the whole diagnostic.
                                 ; Neither may be the keyboard's rep_buf: a
                                 ; mouse packet landing there would be
                                 ; diffed against the last key report and
                                 ; come out as keystrokes
m_reports: dw   0                ; mouse reports applied, real or injected
mlast_ist: db   0                ; last non-success status from EP mep_in
mrep_len:  db   0                ; length of the last report the mouse sent
mbtn_seen: db   0                ; every button bit ever seen set
mbtn_reps: dw   0                ; reports that carried a button down
mpoll_off: db   0                ; 1 = the timer leaves the mouse endpoint be
m_ignored: dw   0                ; report-ID packets that were not the pointer
m_short:   dw   0                ; packets too short to be a report at all
m_dup:     dw   0                ; packets byte-identical to the one before
m_zero:    dw   0                ; packets carrying no movement and no button
m_bogus:   dw   0                ; packets too long for the agreed protocol
mprev_buf: times 8 db 0          ; the previous packet, for that comparison

; ---- counters, for /S ----
; n_polls counts every fast tick the poll ran on, whether or not the
; keyboard had anything to say.  n_reports cannot stand in for it: with
; SET_IDLE 0 an idle keyboard reports nothing at all, so a driver that is
; polling perfectly well shows a frozen report count.  Telling "not being
; called" from "called, nothing to report" needs both numbers.
n_polls:   dw   0
m_polls:   dw   0                ; the same number for the mouse endpoint
n_tmo:     dw   0                ; keyboard polls that timed out waiting
m_tmo:     dw   0                ; mouse polls that timed out waiting
n_flush:   dw   0                ; stale interrupts thrown away by ch_flush
n_replen:  db   0                ; length of the last KEYBOARD report.  A
                                 ; keyboard boot report is 8 bytes; seeing 5
                                 ; here means a mouse packet was read as a
                                 ; key report, which is the whole reason
                                 ; ch_flush exists
n_reports: dw   0
n_keys:    dw   0
n_full:    dw   0                ; keys dropped because the BIOS buffer was full
last_ist:  db   0                ; last non-success poll status

; ---- scratch used inside the ISR ----
rep_buf:  times 8 db 0
setup_b:  times 8 db 0

; --------------------------------------------------------------------------
; A private stack for the interrupt handler.
;
; An interrupt handler runs on whatever stack the interrupted program left
; behind, and that stack is not ours to spend.  poll_kbd nests several calls
; deep and can run a whole control transfer for the LEDs; a program with a
; tight stack -- a large text-mode application, say -- gets its own memory
; quietly written over.  What that looks like from the outside is the OTHER
; program crashing, or the machine rebooting in the middle of something, and
; nothing points at the driver at all.  DOS EDIT rebooting this machine is
; what turned this up.
;
; So the handler saves SS:SP, switches to this, and switches back.  256
; bytes is generous for the call depth above and cheap once.
; --------------------------------------------------------------------------
stk_ss:   dw    0
stk_sp:   dw    0
          times 512 db 0
stk_top:

; ==========================================================================
; CH375 PORT LAYER
; The two IN AL,DX from port 61h are the ISA settling delay: port 61h is
; the keyboard controller's port B, harmless to read, and two reads are
; comfortably longer than the chip needs between a command and its data.
; ==========================================================================

ch_cmd:                                  ; AL = command byte
        push    dx
        push    ax
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     ax
        mov     dx, [io_cmd]
        out     dx, al
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     dx
        ret

ch_wr:                                   ; AL = data byte
        push    dx
        mov     dx, [io_dat]
        out     dx, al
        push    ax
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     ax
        pop     dx
        ret

ch_rd:                                   ; -> AL
        push    dx
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        mov     dx, [io_dat]
        in      al, dx
        pop     dx
        ret

; Wait for the chip to raise its interrupt, then read the status.
; CX = spin limit.  CF set on timeout, otherwise AL = status.
ch_wait:
        push    dx
        mov     dx, [io_cmd]
ch_wait_spin:
        in      al, dx
        test    al, 0x80
        je      short ch_wait_got
        loop    ch_wait_spin
        pop     dx
        stc
        ret
ch_wait_got:
        pop     dx
        mov     al, CMD_GET_STATUS
        call    ch_cmd
        call    ch_rd
        clc
        ret

; Read the chip's data buffer into ES:DI, at most CL bytes.  Returns the
; length the chip reported in AH, and the number actually stored in AL.
; Bytes past the caller's limit are still read out of the chip -- leaving
; them behind desynchronises every later read.
ch_read:
        push    bx
        mov     al, CMD_RD_USB_DATA
        call    ch_cmd
        call    ch_rd
        mov     ah, al                   ; AH = reported length
        mov     bl, al
        xor     bh, bh                   ; BH = stored so far
        or      bl, bl
        je      short ch_read_done
ch_read_loop:
        call    ch_rd
        cmp     bh, cl
        jae     short ch_read_skip
        stosb
        inc     bh
ch_read_skip:
        dec     bl
        jne     short ch_read_loop
ch_read_done:
        mov     al, bh
        pop     bx
        ret

; --------------------------------------------------------------------------
; Clear endpoint 0.  Every control transfer starts with this, and it is not
; tidying -- it is required.  CLR_STALL on the CH375 also resets the
; endpoint's data toggle inside the chip.  Without it a control transfer
; that SUCCEEDS leaves endpoint 0 advanced and the NEXT one is stalled by
; the device, so control transfers work every other time.  That reads as a
; flaky device and is not one.
; --------------------------------------------------------------------------
clr_ep0:
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     cx, 0x4000
        call    ch_wait
        ret

; --------------------------------------------------------------------------
; A control transfer with no data stage.  DS:SI -> the 8 setup bytes.
; Returns AL = final status.
; --------------------------------------------------------------------------
ctrl_nodata:
        call    clr_ep0
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     cx, 8
ctrl_nd_wr:
        lodsb
        call    ch_wr
        loop    ctrl_nd_wr

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0x80                 ; SETUP is always DATA0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_SETUP
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short ctrl_nd_out
        cmp     al, INT_SUCCESS
        jne     short ctrl_nd_out

        ; The status stage carries DATA1.  Without saying so the chip
        ; reports a toggle mismatch, 2Bh, instead of success.
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_IN
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short ctrl_nd_out
        cmp     al, INT_STALL
        jne     short ctrl_nd_out
        ; A device that does not implement the request stalls endpoint 0,
        ; and a stall left set fails every later control transfer.
        push    ax
        call    clr_ep0
        pop     ax
ctrl_nd_out:
        ret

; --------------------------------------------------------------------------
; A control transfer with a one-byte OUT data stage -- which is exactly
; SET_REPORT for the LEDs and nothing else here.  DS:SI -> setup, BL = byte.
; CX on entry is the spin limit for each wait, so the ISR can keep it short.
; --------------------------------------------------------------------------
ctrl_out1:
        push    cx
        call    clr_ep0
        pop     cx
        push    cx
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        push    cx
        mov     cx, 8
ctrl_o1_wr:
        lodsb
        call    ch_wr
        loop    ctrl_o1_wr
        pop     cx

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0x80
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_SETUP
        call    ch_wr
        pop     cx
        push    cx
        call    ch_wait
        jc      short ctrl_o1_out
        cmp     al, INT_SUCCESS
        jne     short ctrl_o1_out

        ; data stage: one byte, DATA1
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 1
        call    ch_wr
        mov     al, bl
        call    ch_wr
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_OUT
        call    ch_wr
        pop     cx
        push    cx
        call    ch_wait
        jc      short ctrl_o1_out
        cmp     al, INT_SUCCESS
        jne     short ctrl_o1_out

        ; status stage: zero-length IN, DATA1
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_IN
        call    ch_wr
        pop     cx
        push    cx
        call    ch_wait
ctrl_o1_out:
        pop     cx
        ret

; ==========================================================================
; THE BIOS KEYBOARD BUFFER
; A ring of words at 0040:001E, head at 0040:001A, tail at 0040:001C, with
; the ends given by 0040:0080 and 0040:0082 so a BIOS that moved it is
; still followed.  Writing here is what a keyboard interrupt does, which is
; why everything that reads INT 16h sees it.
; ==========================================================================

; AX = the word to insert (AH scancode, AL ASCII).  Preserves everything.
buf_put:
        push    ax
        push    bx
        push    cx
        push    dx
        push    ds
        mov     cx, 0x40
        mov     ds, cx
        mov     bx, [0x1C]               ; tail
        mov     dx, bx
        add     dx, 2
        cmp     dx, [0x82]               ; past the end?
        jb      short bp_nowrap
        mov     dx, [0x80]
bp_nowrap:
        cmp     dx, [0x1A]               ; would the tail meet the head?
        je      short bp_full
        mov     [bx], ax
        mov     [0x1C], dx
        pop     ds
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc                              ; delivered
        ret
bp_full:
        ; The buffer holds 15 entries and nothing is draining it.  Dropping
        ; the key is what a real keyboard does too -- the BIOS beeps, this
        ; just counts it, because a beep from inside a timer ISR on every
        ; key of a fast typist is worse than the lost key.
        ;
        ; CF says so, and do_repeat acts on it.  That matters more than it
        ; looks: a FULL BIOS BUFFER KILLS EVERY KEYBOARD ON THE MACHINE,
        ; not just this one, because the BIOS discards new keystrokes from
        ; any source once the ring is full.  Measured on this box -- head
        ; 001E against tail 003C, fifteen keys queued, nothing reading them
        ; -- and the symptom is "no keyboard input at all", which looks
        ; exactly like a dead driver and is not.
        pop     ds
        inc     word [cs:n_full]
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        stc                              ; dropped
        ret

; Update the BIOS shift-flag byte at 0040:0017 from cur_mods and locks, so
; INT 16h AH=02h and everything that reads 40:17 directly agree with what
; the USB keyboard is actually doing.
set_flags:
        push    ax
        push    bx
        push    ds
        mov     ax, 0x40
        mov     ds, ax
        mov     al, [cs:cur_mods]
        xor     bl, bl
        test    al, 0x20                 ; right shift
        je      short sf_nrs
        or      bl, 0x01
sf_nrs:
        test    al, 0x02                 ; left shift
        je      short sf_nls
        or      bl, 0x02
sf_nls:
        test    al, 0x11                 ; either control
        je      short sf_nc
        or      bl, 0x04
sf_nc:
        test    al, 0x44                 ; either alt
        je      short sf_na
        or      bl, 0x08
sf_na:
        ; Bits 4..7 -- the three locks and the Insert toggle -- are NOT
        ; ours.  They are the BIOS's, they are shared with whatever other
        ; keyboard the machine has, and they are carried through untouched.
        ;
        ; Version 1.1.0 wrote them from the driver's own `locks` byte, which
        ; started at zero.  On a machine booted with NumLock on that meant
        ; the first keypress silently cleared NumLock in 40:17 while 40:97
        ; still had the LED lit -- and from then on the driver and the BIOS
        ; disagreed about the lock state and each kept overwriting the
        ; other.  The visible result was that the machine's own PS/2
        ; keyboard stopped working, which took a reboot and looked nothing
        ; like a lock-state problem.
        mov     al, [0x17]
        and     al, 0xF0
        or      bl, al
        mov     [0x17], bl

; --------------------------------------------------------------------------
; 0040:0018 and 0040:0096, the other two shift-state bytes.
;
; A program that asks INT 16h AH=12h for the keyboard state gets its answer
; out of THESE, not out of 40:17, and they are where the left and right
; halves of Ctrl and Alt are told apart.  A DOS text-mode program that
; opens its menus on Alt is normally looking here -- so a driver that
; maintains only 40:17 gives you a keyboard you can type on perfectly well
; and cannot drive a menu bar with.  That is not a subtle failure to find
; once you know where to look, and it is invisible until you try.
;
;   40:18  bit0 left Ctrl   bit1 left Alt    bits 2..7 belong to the BIOS
;                                            (SysReq, Pause, the lock keys
;                                            while physically held) and are
;                                            preserved rather than guessed
;   40:96  bit2 right Ctrl  bit3 right Alt   bit4 101/102-key keyboard
; --------------------------------------------------------------------------
        mov     al, [cs:cur_mods]
        mov     bl, [0x18]
        and     bl, 0xFC                 ; bits 0 and 1 are ours
        test    al, 0x01                 ; left control
        je      short sf_nlc
        or      bl, 0x01
sf_nlc:
        test    al, 0x04                 ; left alt
        je      short sf_nla
        or      bl, 0x02
sf_nla:
        mov     [0x18], bl

        mov     bl, [0x96]
        and     bl, 0xF3                 ; bits 2 and 3 are ours
        test    al, 0x10                 ; right control
        je      short sf_nrc
        or      bl, 0x04
sf_nrc:
        test    al, 0x40                 ; right alt
        je      short sf_nra
        or      bl, 0x08
sf_nra:
        ; Bit 4 says "a 101/102-key keyboard is installed", which is what
        ; makes software use the enhanced INT 16h calls (AH=10h/11h/12h).
        ; It is NOT set by default: on an XT-class BIOS those functions do
        ; not exist, and claiming the keyboard would send a program off to
        ; call them and get nonsense back.  /E sets it for a machine whose
        ; BIOS does support them, and USBKBD /S reports what it did.
        cmp     byte [cs:op_enh], 0
        je      short sf_noenh
        or      bl, 0x10
sf_noenh:
        mov     [0x96], bl
        pop     ds
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; Read the lock state out of 0040:0017 into `locks`.
;
; Called at install time and after every report, so the driver follows the
; BIOS rather than competing with it.  A Caps Lock pressed on the machine's
; other keyboard therefore updates the USB keyboard's LED too, which is the
; behaviour you want from two keyboards on one machine and falls out of
; doing the ownership properly.
;
;   40:17  bit4 scroll  bit5 num   bit6 caps
;   locks  bit2 scroll  bit0 num   bit1 caps
; --------------------------------------------------------------------------
adopt_locks:
        push    ax
        push    bx
        push    ds
        mov     ax, 0x40
        mov     ds, ax
        mov     al, [0x17]
        pop     ds
        xor     bl, bl
        test    al, 0x20                 ; num lock
        je      short al_nn
        or      bl, 0x01
al_nn:
        test    al, 0x40                 ; caps lock
        je      short al_nc
        or      bl, 0x02
al_nc:
        test    al, 0x10                 ; scroll lock
        je      short al_ns
        or      bl, 0x04
al_ns:
        mov     [cs:locks], bl
        pop     bx
        pop     ax
        ret

; Toggle one lock in 0040:0017 itself, then re-read it.  AL = the 40:17 bit.
toggle_lock:
        push    bx
        push    ds
        mov     bl, al
        mov     ax, 0x40
        mov     ds, ax
        mov     al, [0x17]
        xor     al, bl
        mov     [0x17], al
        pop     ds
        pop     bx
        call    adopt_locks
        ret

; --------------------------------------------------------------------------
; Throw away any interrupt still pending from an earlier transaction.
;
; Defensive, and it has never once fired on this hardware -- n_flush stays 0
; and so do n_tmo and m_tmo.  It is kept because the reasoning holds even
; though the case has not been seen: ch_wait gives up after a bounded spin
; -- it has to,
; inside a timer interrupt, because a device that stops answering must cost
; one tick and not the machine.  But giving up does not CANCEL the
; transaction: the CH375 raises its interrupt whenever the answer finally
; arrives, which may be long after we stopped looking.
;
; With one endpoint that leftover is harmless: the next poll asks the same
; endpoint the same question and reads the answer to the previous one, which
; is at worst a report arriving a tick late.  With two endpoints it is not
; harmless at all, because the next poll is the OTHER endpoint's, and it
; reads a completion that belongs to its neighbour.  The mouse's packet gets
; diffed against the last keyboard report; the keyboard's gets folded into
; the pointer.
;
; /S reports n_flush, n_tmo and m_tmo, so whether any of this ever happens
; can be read off the machine rather than taken on trust.  On this adapter
; all three stay 0.  /Q turns the flush off.
; --------------------------------------------------------------------------
ch_flush:
        cmp     byte [op_noflush], 0
        je      short cf_go
        ret
cf_go:
        push    ax
        push    bx
        push    dx
        mov     bx, 8                    ; bounded; this runs in an ISR
cf_loop:
        mov     dx, [io_cmd]
        in      al, dx
        test    al, 0x80                 ; bit 7 high = nothing pending
        jne     short cf_done
        inc     word [n_flush]
        mov     al, CMD_GET_STATUS
        call    ch_cmd
        call    ch_rd
        dec     bx
        jne     short cf_loop
cf_done:
        pop     dx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; The PIT.  Channel 0, mode 3, divisor 65536/n -- so the chip interrupts n
; times as often, and the tick handler passes every nth one downstream.
; These live in the resident image because check_top has to be able to give
; the fast rate back long after the transient part has gone.
; --------------------------------------------------------------------------
pit_fast:
        push    ax
        push    bx
        push    dx
        mov     al, 0x36
        out     0x43, al
        xor     ax, ax                   ; 65536
        mov     bl, [tick_n]
        xor     bh, bh
        xor     dx, dx
        mov     ax, 0
        dec     ax                       ; 65535, close enough and it
        div     bx                       ; avoids dividing by zero above
        out     0x40, al
        mov     al, ah
        out     0x40, al
        pop     dx
        pop     bx
        pop     ax
        ret

pit_slow:
        push    ax
        mov     al, 0x36
        out     0x43, al
        xor     al, al
        out     0x40, al                 ; divisor 0 = 65536 = 18.2 Hz
        out     0x40, al
        pop     ax
        ret

; --------------------------------------------------------------------------
; Is INT 08h still ours?
;
; If something hooked INT 08h after we did, its handler is the one the PIT
; now calls -- at OUR rate, 145 Hz instead of 18.2, because it chains down
; to us.  Anything that measures time from the tick then runs eight times
; too fast, which for a program with a timed input loop means it never
; settles long enough to read a keystroke.
;
; So the rate goes back and this driver stops dividing: polling drops to
; 18.2 Hz, slow for typing but correct for everybody else.  The mouse
; driver does exactly this, and for the same reason -- it is what makes
; double-click work under Windows.
; --------------------------------------------------------------------------
check_top:
        push    ax
        push    bx
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     ax, [0x0022]             ; segment half of the INT 08h vector
        mov     bx, cs
        cmp     ax, bx
        je      short ct_out
        cmp     byte [cs:on_top], 0
        je      short ct_out             ; already handed it back
        mov     byte [cs:on_top], 0
        call    pit_slow
        mov     al, 1
        mov     [cs:tick_c], al
ct_out:
        pop     ds
        pop     bx
        pop     ax
        ret

; ==========================================================================
; INJECTING THROUGH THE KEYBOARD CONTROLLER  (/K)
;
; Writing scancode/ASCII words into the BIOS buffer is enough for anything
; that reads the keyboard through INT 16h, and that is most software.  It is
; not enough for a program that hooks INT 09h and works in scancodes: such a
; program never looks at the buffer, so the keys are simply invisible to it.
; DOS EDIT is one -- you can type into the editor, because that path goes
; through INT 16h, and its menus do not respond at all, because that path
; does not.  The giveaway is that the keys are not lost: they sit in the
; buffer and all arrive at once the moment a real keypress on another
; keyboard wakes the program up.
;
; 8042 command D2h is the way out.  It means "put this byte in the output
; buffer as though the keyboard had sent it", and it raises a genuine IRQ1.
; From there the machine cannot tell our keys from a real keyboard's: the
; BIOS INT 09h handler does the translation, the shift state, the lock keys
; and the LEDs, and so does any program that hooked it.
;
; So in /K mode this driver stops translating altogether.  It sends make and
; break codes -- including for the modifier keys, which the BIOS-buffer path
; never needed -- and touches neither the buffer nor 40:17.  All the shared
; state that had to be got right in the other mode simply is not ours here.
;
; WHY IT IS NOT THE DEFAULT.  D2h needs a real AT-class 8042.  An XT-class
; controller does not have the command, and writing it there can leave the
; controller confused with no keyboard at all until a power cycle.  So /K is
; opt-in, and it checks the controller answers before promising to use it.
; ==========================================================================

; AL = the byte to inject.  CF set if the controller would not take it.
; Every wait is bounded: this runs inside the timer interrupt, and an 8042
; that has stopped answering must cost one tick rather than the machine.
kbc_send:
        push    bx
        push    cx
        mov     bl, al
        mov     cx, 0x400
kbs_w1:
        in      al, 0x64
        cmp     al, 0xFF
        je      short kbs_fail           ; nothing there at all
        test    al, 0x02                 ; input buffer full?
        je      short kbs_ok1
        loop    kbs_w1
        jmp     short kbs_fail
kbs_ok1:
        mov     al, 0xD2
        out     0x64, al
        mov     cx, 0x400
kbs_w2:
        in      al, 0x64
        test    al, 0x02
        je      short kbs_ok2
        loop    kbs_w2
        jmp     short kbs_fail
kbs_ok2:
        mov     al, bl
        out     0x60, al
        pop     cx
        pop     bx
        clc
        ret
kbs_fail:
        inc     word [cs:n_kbcbad]
        pop     cx
        pop     bx
        stc
        ret

; BL = usage -> AL = scancode, CF set if the usage has no PC equivalent.
; Factored out of translate because /K needs the scancode and none of the
; character handling that goes with it.
scan_of:
        push    bx
        cmp     bl, 0xE0
        jb      short so_norm
        cmp     bl, 0xE7
        ja      short so_none
        sub     bl, 0xE0
        xor     bh, bh
        mov     al, [cs:tab_mod + bx]
        jmp     short so_have
so_norm:
        cmp     bl, 0x04
        jb      short so_none
        cmp     bl, 0x65
        ja      short so_none
        sub     bl, 0x04
        xor     bh, bh
        mov     al, [cs:tab_scan + bx]
so_have:
        or      al, al
        je      short so_none
        pop     bx
        clc
        ret
so_none:
        pop     bx
        stc
        ret

; BL = usage, AH = 0 for a make code or 80h for a break code.
inject_scan:
        push    ax
        push    bx
        push    dx
        mov     dh, ah
        mov     al, bl
        push    bx
        mov     bl, al
        call    scan_of
        pop     bx
        jc      short inj_out
        mov     dl, al
        call    is_ext                   ; BL = usage, CF if extended
        jnc     short inj_noext
        mov     al, 0xE0                 ; the prefix a real keyboard sends
        call    kbc_send
inj_noext:
        mov     al, dl
        or      al, dh                   ; bit 7 set makes it a break code
        call    kbc_send
inj_out:
        pop     dx
        pop     bx
        pop     ax
        ret

; Inject make and break codes for every modifier bit that changed.  The
; BIOS-buffer path carries modifiers in the shift byte and never needs an
; event for them; the 8042 path has to send the real thing.
inject_mods:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     dl, [prev_rep]
        mov     dh, [rep_buf]
        mov     al, dl
        xor     al, dh
        or      al, al
        je      short im_out
        mov     bh, 1                    ; walking bit mask
        xor     cl, cl                   ; and its index
im_loop:
        test    al, bh
        je      short im_next
        mov     bl, 0xE0
        add     bl, cl                   ; usages E0..E7, in that bit order
        test    dh, bh
        je      short im_break
        xor     ah, ah
        jmp     short im_send
im_break:
        mov     ah, 0x80
im_send:
        call    inject_scan
im_next:
        shl     bh, 1
        inc     cl
        cmp     cl, 8
        jb      short im_loop
im_out:
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ==========================================================================
; WAKING A PROGRAM THAT OWNS INT 09h  (/W)
;
; Some programs take over the keyboard hardware interrupt and drive their
; input from it rather than asking the BIOS for keys.  DOS EDIT is one:
; with EDIT running, INT 09h AND INT 08h both point into QBASIC's segment
; instead of the BIOS's.  Measured rather than guessed -- I16SPY paints the
; owner of both vectors on screen, and the segment changes from 12DF to
; 504A the moment EDIT starts.
;
; Such a program never looks at the BIOS keyboard buffer while it waits, so
; a key put there is not seen at all.  That is precisely the reported
; symptom: keys typed at EDIT's menu do nothing, then all arrive at once
; the instant any key is pressed on the machine's own keyboard -- because
; THAT raises IRQ1, which runs the program's own handler, which wakes it.
;
; A software driver cannot raise IRQ1, and with no 8042 it cannot fake one.
; What it can do is CALL INT 09h, which runs whatever handler is installed
; -- the program's own -- and gives it the nudge it is waiting for.  The
; key itself still travels normally, in the BIOS buffer, and is picked up
; once the program is awake.
;
; WHY THIS IS TOLERABLE RATHER THAN RECKLESS.  The handler will read port
; 60h and find whatever the keyboard hardware last latched.  With nobody
; touching the other keyboard that is a BREAK code -- a key release, bit 7
; set -- which an INT 09h handler discards without producing a keystroke.
; So the ordinary case is a wake-up and nothing else.  It stays off by
; default all the same: calling somebody else's interrupt handler behind
; its back earns an opt-in.
; ==========================================================================

; WITHDRAWN, and left here as a warning rather than deleted.
;
; The idea was sound and the measurement behind it stands: EDIT and QBASIC
; do own INT 09h, and a program waiting on IRQ1 does need an interrupt
; rather than a buffer write.  Calling INT 09h to supply it does not work,
; because of where the call had to be made from.
;
; This driver delivers keys from inside its INT 08h handler.  Calling
; INT 09h from there runs a handler that ends with its own EOI to the 8259
; -- `out 20h, 20h` -- on top of the one this handler issues a moment
; later.  Two end-of-interrupts for one interrupt corrupts the controller's
; in-service state and interrupts stop arriving: the machine locks up hard
; and needs the power cycle it got.  The nested handler may also STI and
; re-enter us, which is no better.
;
; Doing it safely would mean synthesising an interrupt without the EOI, in
; a context that is not already inside an interrupt -- and this driver has
; no such context, because a polled USB keyboard has nowhere else to run.
; /W is therefore accepted and ignored.
wake_int09:
        ret

; ==========================================================================
; DELIVERING THROUGH AN INT 16h HOOK  (/H)
;
; The default is to write scancode/ASCII words into the BIOS keyboard
; buffer, which is what a keyboard interrupt does and what every program
; reading INT 16h therefore sees.  It is the right default and it works for
; ordinary typing everywhere tested.
;
; It does NOT drive DOS EDIT's menu bar, and the reason is worth writing
; down because it took a long time to corner.  DOSBridge's KINJ, which
; hooks INT 16h and manufactures a key inside the call, drives that menu
; perfectly.  KNET, which queues a key and lets the BIOS serve it, does not
; -- and neither does this driver's buffer write.  Same key words, same
; BIOS, opposite outcomes; the difference is only in who answers the call.
;
; QBASIC.EXE -- which EDIT.COM is a front end for -- hooks INT 16h itself
; (MOV AX,2516 is in the image; MOV AX,2509 is not).  So its menu loop is
; talking to its own handler, and a key that is merely sitting in the BIOS
; buffer is evidently not what that handler goes looking for.
;
; So this mode delivers the way KINJ does: a small ring, and an INT 16h
; hook that answers from it.  When the ring is empty the call chains, so
; the real keyboard keeps working exactly as before.
;
; Note it does NOT also write the BIOS buffer -- a key must be delivered
; once, not twice.  The cost is that a program reading 0040:001E directly,
; rather than through INT 16h, sees nothing in this mode.  Almost nothing
; does that; EDIT does not.
; ==========================================================================

FLG_ZF   equ    0x0040

; AX = the key word.  Called from the ISR, so it must not block.
ring_put:
        push    bx
        push    cx
        mov     bx, [ring_t]
        mov     cx, bx
        add     cx, 2
        cmp     cx, RINGN * 2
        jb      short rp_nowrap
        xor     cx, cx
rp_nowrap:
        cmp     cx, [ring_h]
        je      short rp_full
        mov     [ring + bx], ax
        mov     [ring_t], cx
        pop     cx
        pop     bx
        ret
rp_full:
        inc     word [n_rfull]
        pop     cx
        pop     bx
        ret

; -> AX = the next key, CF set if the ring is empty.  Does not remove it.
ring_peek:
        mov     bx, [cs:ring_h]
        cmp     bx, [cs:ring_t]
        je      short rk_empty
        mov     ax, [cs:ring + bx]
        clc
        ret
rk_empty:
        stc
        ret

ring_drop:
        push    bx
        mov     bx, [cs:ring_h]
        add     bx, 2
        cmp     bx, RINGN * 2
        jb      short rd_nowrap
        xor     bx, bx
rd_nowrap:
        mov     [cs:ring_h], bx
        inc     word [cs:n_ring]
        pop     bx
        ret

; --------------------------------------------------------------------------
; INT 16h.  Only the four functions that fetch a keystroke are touched;
; everything else, the shift-state calls included, goes straight through.
;
; The peek functions report "a key is waiting" in ZF, which lives in the
; caller's flags on the interrupt frame -- so those are edited in place and
; returned with IRET.  The read functions return the key in AX.  When the
; ring is empty every one of them chains, which is what keeps the machine's
; own keyboard working normally while this is loaded.
; --------------------------------------------------------------------------
int16:
        cmp     ah, 0x00
        je      short i16_read
        cmp     ah, 0x10
        je      short i16_read
        cmp     ah, 0x01
        je      short i16_peek
        cmp     ah, 0x11
        je      short i16_peek
i16_chain:
        jmp     far [cs:old16]

i16_peek:
        push    bp
        mov     bp, sp                   ; bp+2 IP, bp+4 CS, bp+6 FLAGS
        push    bx
        call    ring_peek
        jc      short i16_peek_none
        and     word [bp + 6], 0xFFFF - FLG_ZF     ; ZF=0: a key is waiting
        pop     bx
        pop     bp
        iret
i16_peek_none:
        pop     bx
        pop     bp
        jmp     short i16_chain

i16_read:
        push    bx
        call    ring_peek
        jc      short i16_read_none
        call    ring_drop
        pop     bx
        iret
i16_read_none:
        pop     bx
        jmp     short i16_chain

; ==========================================================================
; TRANSLATION
; AL = usage, AH = modifiers.  Returns AX = the BIOS word, or AX = 0 if the
; usage produces nothing.  CF set means "extended", which here only affects
; the ASCII byte -- DOS identifies those keys by scancode with a zero ASCII.
; ==========================================================================

translate:
        push    bx
        push    cx
        push    dx
        mov     dl, al                   ; DL = usage
        mov     dh, ah                   ; DH = modifiers
        jmp     short tr_go

; The 8086 has no near conditional jump, and this routine is longer than a
; short jump reaches, so the two exits are trampolined.  Do not "simplify"
; these away -- see the note about mininasm at the top of the file.
tr_j_none:
        jmp     near tr_none
tr_j_done:
        jmp     near tr_done

tr_go:
        ; --- scancode ---
        xor     bh, bh
        mov     bl, dl
        cmp     bl, 0xE0
        jb      short tr_normal
        cmp     bl, 0xE7
        ja      short tr_j_none
        sub     bl, 0xE0
        mov     al, [cs:tab_mod + bx]
        jmp     short tr_havescan
tr_normal:
        cmp     bl, 0x04
        jb      short tr_j_none
        cmp     bl, 0x65
        ja      short tr_j_none
        sub     bl, 0x04
        mov     al, [cs:tab_scan + bx]
tr_havescan:
        or      al, al
        je      short tr_j_none
        mov     ah, al                   ; AH = scancode
        xor     al, al                   ; AL = ASCII, none yet

        ; --- extended keys carry no character ---
        mov     bl, dl
        call    is_ext
        jc      short tr_j_done

        ; --- the printable run, 04..38 ---
        cmp     dl, 0x04
        jb      short tr_pad
        cmp     dl, 0x38
        ja      short tr_pad
        mov     bl, dl
        xor     bh, bh
        sub     bl, 0x04
        test    dh, 0x22                 ; either shift
        jne     short tr_shifted
        mov     al, [cs:tab_plain + bx]
        jmp     short tr_caps
tr_shifted:
        mov     al, [cs:tab_shift + bx]
tr_caps:
        ; Caps Lock swaps the case of LETTERS only, never of the digit row.
        ; Treating it as a second Shift is a common bug and very annoying
        ; to type through.
        test    byte [cs:locks], 0x02
        je      short tr_ctrl
        cmp     dl, 0x04
        jb      short tr_ctrl
        cmp     dl, 0x1D
        ja      short tr_ctrl
        test    dh, 0x22
        jne     short tr_caps_down
        mov     al, [cs:tab_shift + bx]
        jmp     short tr_ctrl
tr_caps_down:
        mov     al, [cs:tab_plain + bx]
tr_ctrl:
        test    dh, 0x11                 ; either control
        je      short tr_alt
        ; Ctrl-A..Ctrl-Z are 01..1A; every other key with Ctrl held has no
        ; character and DOS reads the scancode instead.
        xor     al, al
        cmp     dl, 0x04
        jb      short tr_alt
        cmp     dl, 0x1D
        ja      short tr_alt
        mov     al, dl
        sub     al, 0x03
        jmp     short tr_alt
tr_pad:
        ; the keypad: digits only with NumLock on and no shift
        cmp     dl, 0x54
        jb      short tr_alt
        cmp     dl, 0x58
        ja      short tr_pad2
        mov     bl, dl
        xor     bh, bh
        sub     bl, 0x54
        mov     al, [cs:tab_kp1 + bx]
        jmp     short tr_alt
tr_pad2:
        cmp     dl, 0x59
        jb      short tr_alt
        cmp     dl, 0x63
        ja      short tr_alt
        test    byte [cs:locks], 0x01    ; NumLock
        je      short tr_alt
        test    dh, 0x22
        jne     short tr_alt
        mov     bl, dl
        xor     bh, bh
        sub     bl, 0x59
        mov     al, [cs:tab_kp2 + bx]
tr_alt:
        ; Alt suppresses the character everywhere: DOS expects Alt-key as a
        ; scancode with a zero ASCII byte, which is how menu accelerators
        ; and Alt-nnn entry are told apart from ordinary typing.
        test    dh, 0x44
        je      short tr_done
        xor     al, al
tr_done:
        pop     dx
        pop     cx
        pop     bx
        clc
        ret
tr_none:
        xor     ax, ax
        pop     dx
        pop     cx
        pop     bx
        stc
        ret

; BL = usage.  CF set if the key needs the E0 prefix, i.e. it is one of the
; ones the original PC keyboard did not have.
is_ext:
        push    ax
        push    cx
        push    si
        mov     si, tab_ext
        mov     cx, tab_ext_n
ie_loop:
        mov     al, [cs:si]
        inc     si
        cmp     al, bl
        je      short ie_yes
        loop    ie_loop
        pop     si
        pop     cx
        pop     ax
        clc
        ret
ie_yes:
        pop     si
        pop     cx
        pop     ax
        stc
        ret

; ==========================================================================
; THE TIMER HOOK
; ==========================================================================

int08:
        push    ax

        ; Everything real happens on our own stack -- see stk_top above.
        ; Interrupts are already off (this is a hardware interrupt entry and
        ; nothing here re-enables them), so the SS/SP pair can be swapped
        ; without a window.
        mov     [cs:stk_ss], ss
        mov     [cs:stk_sp], sp
        mov     ax, cs
        mov     ss, ax
        mov     sp, stk_top
        call    tick_body
        mov     ss, [cs:stk_ss]
        mov     sp, [cs:stk_sp]

        or      al, al
        jne     short i08_chain
        ; A fast tick that is not a downstream tick: acknowledge the
        ; interrupt ourselves, because the real handler is not going to.
        mov     al, 0x20
        out     0x20, al
        pop     ax
        iret
i08_chain:
        pop     ax
        jmp     far [cs:old08]

; Returns AL = 1 if the downstream INT 08h handler must run this tick.
tick_body:
        ; The direction flag belongs to whoever we interrupted, and this
        ; handler's path contains five string operations: STOSB in ch_read,
        ; LODSB in both control-transfer builders, and the REP STOSB and
        ; REP MOVSB that zero-fill and remember a report.  Every one of
        ; them runs backwards if the interrupted program happened to be
        ; sitting on DF=1, quietly writing over whatever is below the
        ; buffer instead of filling it.
        ;
        ; That is a genuinely nasty bug to be carrying: it depends entirely
        ; on what the foreground program was doing, so the driver works
        ; perfectly until it suddenly does not.  Nothing needs restoring
        ; afterwards -- the CPU pushed the original flags on interrupt
        ; entry and whichever IRET eventually runs, ours or the downstream
        ; handler's, pops them back.
        ;
        ; Found by reading davidegat's independent CH375 driver, which
        ; states the rule outright:
        ;   https://github.com/davidegat/CH375USB
        cld
        call    check_top
        cmp     byte [cs:on_top], 0
        je      short tb_notours
        dec     byte [cs:tick_c]
        jne     short tb_fast
        mov     al, [cs:tick_n]
        mov     [cs:tick_c], al
        call    poll_kbd
        mov     al, 1                    ; the 18.2 Hz tick, passed on
        ret
tb_fast:
        call    poll_kbd
        xor     al, al
        ret
tb_notours:
        ; The PIT is back to 18.2 Hz and somebody else owns the vector, so
        ; every tick is a downstream tick.
        call    poll_kbd
        mov     al, 1
        ret

; --------------------------------------------------------------------------
; Poll the keyboard endpoint.  Runs inside the timer ISR, so it touches no
; DOS and nothing that can block: the CH375 wait is bounded and a device
; that does not answer simply loses this tick.
; --------------------------------------------------------------------------
poll_kbd:
        cmp     byte [cs:in_poll], 0
        je      short pk_enter
        ret
pk_enter:
        mov     byte [cs:in_poll], 1
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    es
        push    ds
        mov     ax, cs
        mov     ds, ax
        mov     es, ax

        ; Nothing at all enumerated: go looking, and there is no endpoint
        ; to poll either way.
        cmp     byte [live], 0
        jne     short pk_islive
        cmp     byte [mlive], 0
        jne     short pk_islive
        jmp     near pk_hotplug
pk_islive:
        ; ------------------------------------------------------------------
        ; THE TWO ENDPOINTS DO NOT WANT THE SAME RATE.
        ;
        ; The keyboard is polled on every fast tick.  It has to be, and the
        ; reason is the shape of the boot protocol: a report is the SET of
        ; keys held right now, in no defined order -- not a list of events.
        ; Two consequences follow, and both were measured on this hardware
        ; by typing abcdefghijkl:
        ;
        ;   * A key pressed AND released between two polls never happened.
        ;     Missing characters.
        ;   * Two keys that go down between the same pair of polls arrive
        ;     in one report, and they are delivered in the order the DEVICE
        ;     listed them -- which says nothing about which was pressed
        ;     first.  Transposed characters: jikl for ijkl.
        ;
        ; Neither can be fixed, only made rarer, and the lever for both is
        ; the length of the window: 7 ms at the default 145 Hz, 3.4 ms at
        ; /R=16.  A build that polled the keyboard on alternate ticks --
        ; 14 ms -- dropped and doubled characters noticeably, which is how
        ; this was found.
        ;
        ; The mouse is less fussy but not indifferent.  Its report is a
        ; delta, so the ORDER of two reports does not matter and neither
        ; does a little jitter -- but a report the host never collects is
        ; lost, not accumulated, because the device replaces it with the
        ; next one every bInterval.  This adapter's bInterval is 10 ms, so
        ; it can offer 100 reports a second and anything slower than that
        ; throws movement away: at 73 Hz the pointer visibly crawled.
        ;
        ; So mou_div is 2, giving 145 Hz at the default tick rate -- above
        ; what the device can generate, which is the point -- and the ISR
        ; still does one transaction rather than two on every other tick.
        ; ------------------------------------------------------------------
        ; When something else has taken INT 08h -- Windows does -- check_top
        ; hands the PIT back to 18.2 Hz and this handler is called at that
        ; rate instead of 291.  Dividing the mouse by 4 on top of that would
        ; poll it about four times a second, which is not a pointer, it is a
        ; slideshow.  So the divisor only applies while we own the timer.
        mov     byte [turn_mou], 1
        cmp     byte [on_top], 0
        je      short pk_mou_notyet      ; not ours: every tick counts
        mov     byte [turn_mou], 0
        dec     byte [mou_cnt]
        jne     short pk_mou_notyet
        mov     al, [mou_div]
        mov     [mou_cnt], al
        mov     byte [turn_mou], 1
pk_mou_notyet:

        ; One half can be up while the other is not -- /NK and /NM ask for
        ; exactly that, and so does a plain mouse.  With no keyboard the
        ; route to the mouse goes through pk_repeat rather than straight to
        ; pk_mouse, so that typematic still counts down on every tick: the
        ; repeat rate is in fast ticks and would otherwise stop.
        cmp     byte [live], 0
        jne     short pk_dokbd
        jmp     near pk_repeat
pk_dokbd:
        inc     word [n_polls]
        call    ch_flush

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, [ep_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, [ep_in]
        mov     cl, 4
        shl     al, cl
        or      al, PID_IN
        call    ch_wr
        mov     cx, 0x2000
        call    ch_wait
        jnc     short pk_answered
        inc     word [n_tmo]
        jmp     near pk_repeat           ; no answer this tick
pk_answered:
        cmp     al, INT_SUCCESS
        je      short pk_got
        mov     [last_ist], al
        cmp     al, INT_DISCONNECT
        jne     short pk_notgone
        mov     byte [live], 0
        mov     byte [rep_key], 0
        jmp     near pk_mouse
pk_notgone:
        cmp     al, INT_STALL
        je      short pk_isstall
        jmp     near pk_repeat
pk_isstall:
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        mov     al, [ep_in]
        or      al, 0x80
        call    ch_wr
        mov     cx, 0x2000
        call    ch_wait
        mov     byte [ep_tog], 0x80
        jmp     near pk_repeat

pk_got:
        mov     di, rep_buf
        mov     cx, 8
        call    ch_read
        xor     ah, ah
        mov     [n_replen], al           ; 8 for a real keyboard report
        mov     bl, al                   ; BL = bytes stored
        xor     byte [ep_tog], 0x40
        cmp     bl, 3
        jae     short pk_len_ok
        jmp     near pk_repeat
pk_len_ok:
        ; zero-fill the tail so the diff below is against a full 8 bytes
        mov     al, bl
        cmp     al, 8
        jae     short pk_full8
        mov     di, rep_buf
        xor     bh, bh
        add     di, bx
        mov     cl, 8
        sub     cl, bl
        xor     ch, ch
        xor     al, al
        rep     stosb
pk_full8:
        inc     word [n_reports]
        ; TYPING WINS.  A tick that carried a keyboard report has already
        ; done the expensive half of its work -- the report diff, the
        ; translation, the BIOS buffer write, sometimes an LED transfer --
        ; and adding a mouse transaction on top of that is what pushes the
        ; handler towards the length of a whole tick.  At 291 Hz a tick is
        ; 3.4 ms, and a tick that overruns is a keyboard sample lost.
        ;
        ; Measured: with the mouse idle, typing abcdefghijkl twice gives
        ; back exactly that.  With the mouse being moved hard at the same
        ; time -- 193 reports in one run -- characters go missing.  So the
        ; mouse yields on any tick the keyboard had something to say.  It
        ; costs the pointer one sample out of however many, which is
        ; invisible on a delta-reporting device, and it costs typing
        ; nothing.
        mov     byte [turn_mou], 0
        call    apply_report
        jmp     short pk_mouse

pk_repeat:
        call    do_repeat

; The mouse endpoint, every tick the keyboard one was polled -- see BOTH
; ENDPOINTS EVERY TICK in the header.  Registers are already saved and
; DS = ES = CS; this is inside the same in_poll guard, so the two halves
; can never be inside the CH375 at once.
pk_mouse:
        cmp     byte [mlive], 0
        je      short pk_done
        cmp     byte [turn_mou], 0
        je      short pk_done
        cmp     byte [mpoll_off], 0
        jne     short pk_done
        call    poll_mou
pk_done:
        pop     ds
        pop     es
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        mov     byte [cs:in_poll], 0
        ret

; --------------------------------------------------------------------------
; /F: no keyboard yet.  Retry the bring-up about twice a second rather than
; every fast tick, because a full bring-up takes long enough that doing it
; 145 times a second would be all the machine did.
; --------------------------------------------------------------------------
pk_hotplug:
        dec     byte [retry_c]
        je      short ph_due
        jmp     near pk_mouse
ph_due:
        mov     byte [retry_c], 72
        mov     al, CMD_TEST_CONNECT
        call    ch_cmd
        call    ch_rd
        cmp     al, INT_CONNECT
        je      short ph_conn
        jmp     near pk_mouse
ph_conn:
        call    bringup
        jmp     near pk_mouse

; --------------------------------------------------------------------------
; One interrupt IN transaction on the mouse endpoint.  Same shape as the
; keyboard's, with its own toggle and its own status byte, and one extra
; job: working out whether what came back has a report ID on the front.
; --------------------------------------------------------------------------
; --------------------------------------------------------------------------
; Turn the packet in mwire_buf into a 3-byte boot-shaped report in mrep_buf.
; BL = bytes received.  CF clear on success; CF set means the packet was not
; pointer data and the caller must drop it.
;
; Whether there is a report ID on the front is decided from the packet, not
; from what SET_PROTOCOL was asked for -- and on this adapter that is not
; caution, it is necessary: it answers SET_PROTOCOL 0 with success and then
; carries on sending its native report-ID format regardless.  Measured on
; the hardware, with /S reporting "reports carry a report ID=1" and "last
; report length=5" after a bring-up whose trace says the request succeeded.
;
; A boot report is 3 bytes, or 4 with a wheel, and has no ID.  This
; adapter's native report is 5 bytes led by the ID -- which is also exactly
; what endpoint 82's max packet allows, so the length alone separates them.
; --------------------------------------------------------------------------
; A NOTE ON A WRONG TURNING, because the wrong version was nearly shipped
; and the reasoning that produced it was seductive.
;
; With an untouched mouse this endpoint delivers a steady stream of 5-byte
; packets of the form 01 00 XX 00 00 -- report ID 1, no buttons, a small
; varying value where X is, nothing else.  Polling the endpoint on its own
; at the time appeared to give nothing, and of 441 packets accepted, 441
; carried movement and none carried none.  That was read as proof that the
; chip was inventing them: surely a real stream would contain some reports
; with no movement in them.
;
; It is not proof of anything.  SET_IDLE 0 means "report only when
; something changes", so EVERY report from a healthy mouse carries a change
; -- movement, or a button edge.  A stream in which every packet carries
; movement is exactly what a real, slightly noisy mouse looks like, and the
; runs that saw nothing simply had a mouse that was sitting still.
;
; The version built on that mistake rejected any packet longer than a boot
; report, on the grounds that the device had acknowledged SET_PROTOCOL 0.
; It rejected 100% of real mouse data.  Moving the mouse produced 61
; distinct packets, every one of them 5 bytes, with X AND Y both signed and
; varying and byte 1 carrying real button bits -- and the driver used none
; of them.  mou_boot and m_bogus survive as counters for /S; nothing
; depends on them any more.
;
; The lesson is not about this chip.  It is that "no device would send
; this" is a claim about the device, and the way to settle it is to make
; the device send something known -- move the mouse -- not to reason about
; what the bytes ought to look like.
mou_strip_id:
        mov     si, mwire_buf
        cmp     bl, 5
        jb      short msi_noid
        mov     byte [mou_id], 1
        cmp     byte [mwire_buf], 1      ; 1 = the pointer
        je      short msi_skipid
        ; 2 is system control -- power, sleep, wake -- and 3 is consumer
        ; keys.  Neither is pointer data, and reading one as a boot report
        ; puts a power-button press into the mouse buttons.
        inc     word [m_ignored]
        stc
        ret
msi_skipid:
        inc     si
        dec     bl
msi_noid:
        cmp     bl, 3
        jae     short msi_copy
        inc     word [m_short]
        stc
        ret
msi_copy:
        mov     al, [si]
        mov     [mrep_buf], al
        mov     al, [si + 1]
        mov     [mrep_buf + 1], al
        mov     al, [si + 2]
        mov     [mrep_buf + 2], al
        clc
        ret

poll_mou:
        inc     word [m_polls]
        call    ch_flush
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, [mep_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, [mep_in]
        mov     cl, 4
        shl     al, cl
        or      al, PID_IN
        call    ch_wr
        mov     cx, 0x2000
        call    ch_wait
        jnc     short pm_answered
        inc     word [m_tmo]
        ret                              ; no answer this tick
pm_answered:
        cmp     al, INT_SUCCESS
        je      short pm_got
        mov     [mlast_ist], al
        cmp     al, INT_DISCONNECT
        jne     short pm_notgone
        mov     byte [mlive], 0
        mov     word [buttons], 0        ; nothing is held once it is gone
        ret
pm_notgone:
        cmp     al, INT_STALL
        jne     short pm_out
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        mov     al, [mep_in]
        or      al, 0x80
        call    ch_wr
        mov     cx, 0x2000
        call    ch_wait
        mov     byte [mep_tog], 0x80
pm_out:
        ret

pm_got:
        push    ds
        pop     es
        mov     di, mwire_buf
        mov     cx, 8
        call    ch_read
        mov     [mrep_len], al
        mov     bl, al                   ; BL = bytes stored
        xor     byte [mep_tog], 0x40     ; DATA0 <-> DATA1

        ; --- what shape is this traffic?  Both numbers are on the WIRE
        ; bytes, before any report ID comes off, so they describe what the
        ; device sent rather than what this driver made of it.
        push    bx
        mov     si, mwire_buf
        mov     di, mprev_buf
        mov     cx, 5
        repe    cmpsb
        jne     short pm_notdup
        inc     word [m_dup]
pm_notdup:
        push    ds
        pop     es
        mov     si, mwire_buf
        mov     di, mprev_buf
        mov     cx, 5
        rep     movsb
        pop     bx

        call    mou_strip_id
        jnc     short pm_kept
        ret
pm_kept:
        ; Button bookkeeping lives here rather than in apply_mouse so that
        ; it counts only what the mouse actually sent.  Injected reports go
        ; through apply_mouse too, and counting those would make the one
        ; number that answers "did a real press ever arrive" say whatever
        ; the test suite last pushed in.
        mov     al, [mrep_buf]
        and     al, 7
        je      short pm_nobtn
        or      [mbtn_seen], al
        inc     word [mbtn_reps]
pm_nobtn:
        mov     al, [mrep_buf]
        or      al, [mrep_buf + 1]
        or      al, [mrep_buf + 2]
        jne     short pm_moved
        inc     word [m_zero]
pm_moved:
        call    apply_mouse
        ret

; ==========================================================================
; TURNING A REPORT INTO KEY EVENTS
; The report is a state, not an event: byte 0 is the modifier bitmap, byte
; 1 is reserved, bytes 2..7 are the usages held down right now, in no
; particular order.  A usage in this report and not the last one is a
; press.  Comparing slot by slot would report a press and a release every
; time the keyboard reordered its list, which some do.
; ==========================================================================

apply_report:
        ; Usage 01h in a key slot is a rollover error -- the keyboard
        ; saying it has lost track, not a key.  Acting on it produces a
        ; burst of nonsense exactly when somebody is typing fast.
        cmp     byte [rep_buf + 2], 0x01
        jne     short ar_go
        jmp     near ar_ret
ar_go:

        cmp     byte [op_kbc], 0
        je      short ar_bios_mods
        ; /K: the modifiers go out as real make and break codes, and the
        ; BIOS keeps the shift state itself.  Nothing here writes 40:17.
        call    inject_mods
        mov     al, [rep_buf]
        mov     [cur_mods], al
        jmp     short ar_press_start
ar_bios_mods:
        mov     al, [rep_buf]
        mov     [cur_mods], al
        call    set_flags
ar_press_start:

        ; --- presses: in the new report, not in the old ---
        mov     si, 2
ar_press:
        mov     bl, [rep_buf + si]
        cmp     bl, 0x01
        jbe     short ar_press_next
        mov     di, prev_rep
        call    in_report
        jc      short ar_press_next      ; was already down
        call    key_down
ar_press_next:
        inc     si
        cmp     si, 8
        jb      short ar_press

        ; --- releases: in the old report, not in the new ---
        mov     si, 2
ar_rel:
        mov     bl, [prev_rep + si]
        cmp     bl, 0x01
        jbe     short ar_rel_next
        mov     di, rep_buf
        call    in_report
        jc      short ar_rel_next        ; still down
        call    key_up
ar_rel_next:
        inc     si
        cmp     si, 8
        jb      short ar_rel

        ; --- remember this report ---
        mov     si, rep_buf
        mov     di, prev_rep
        mov     cx, 8
        push    ds
        pop     es
        rep     movsb
        call    adopt_locks
        call    sync_leds
ar_ret:
        ret

; BL = usage, DS:DI -> an 8-byte report.  CF set if BL is in slots 2..7.
in_report:
        push    cx
        push    di
        add     di, 2
        mov     cx, 6
ir_loop:
        cmp     [di], bl
        je      short ir_yes
        inc     di
        loop    ir_loop
        pop     di
        pop     cx
        clc
        ret
ir_yes:
        pop     di
        pop     cx
        stc
        ret

; --------------------------------------------------------------------------
; A key went down.  BL = usage.
; --------------------------------------------------------------------------
key_down:
        push    ax
        push    bx
        cmp     byte [op_kbc], 0
        je      short kd_bios_path
        ; /K: send the make code and let the BIOS work out what it means.
        ; The lock keys go through here too, so the BIOS toggles its own
        ; state and drives the PS/2 keyboard's lights as it always would.
        xor     ah, ah
        call    inject_scan
        inc     word [n_keys]
        cmp     bl, 0xE0
        jb      short kd_karm            ; a modifier does not repeat
        jmp     near kd_out
kd_karm:
        mov     [rep_key], bl
        mov     al, [cur_mods]
        mov     [rep_mods], al
        mov     ax, [rep_delay]
        mov     [rep_cnt], ax
        jmp     near kd_out

        ; /H: the key goes in our ring and the INT 16h hook serves it.
        cmp     byte [op_hook], 0
        je      short kd_bios_path
        mov     al, bl
        mov     ah, [cur_mods]
        call    translate
        jc      short kd_hook_arm
        or      ax, ax
        je      short kd_hook_arm
        call    ring_put
        inc     word [n_keys]
        call    wake_int09
kd_hook_arm:
        mov     al, bl
        cmp     al, 0xE0
        jb      short kd_arm3
        jmp     near kd_out
kd_arm3:
        mov     [rep_key], bl
        mov     al, [cur_mods]
        mov     [rep_mods], al
        mov     ax, [rep_delay]
        mov     [rep_cnt], ax
        jmp     short kd_out

kd_bios_path:
        ; The three locks toggle on press and never repeat.
        cmp     bl, 0x39                 ; Caps Lock
        jne     short kd_nc
        mov     al, 0x40                 ; 40:17 caps bit
        call    toggle_lock
        call    set_flags
        jmp     short kd_out
kd_nc:
        cmp     bl, 0x53                 ; Num Lock
        jne     short kd_nn
        mov     al, 0x20                 ; 40:17 num bit
        call    toggle_lock
        call    set_flags
        jmp     short kd_out
kd_nn:
        cmp     bl, 0x47                 ; Scroll Lock
        jne     short kd_ns
        mov     al, 0x10                 ; 40:17 scroll bit
        call    toggle_lock
        call    set_flags
        jmp     short kd_out
kd_ns:
        ; Ctrl-Alt-Del reboots, which is what everyone expects of it and
        ; the only way off a machine whose only keyboard is this one.
        cmp     bl, 0x4C                 ; Delete
        jne     short kd_normal
        mov     al, [cur_mods]
        test    al, 0x11
        je      short kd_normal
        test    al, 0x44
        je      short kd_normal
        jmp     near do_reboot

kd_normal:
        mov     al, bl
        mov     ah, [cur_mods]
        call    translate
        jc      short kd_out             ; no PC equivalent
        or      ax, ax
        je      short kd_out
        call    buf_put
        inc     word [n_keys]
        call    wake_int09
        ; Arm the repeat for this key.  A modifier never repeats, and
        ; translate has already rejected anything with no scancode.
        mov     al, bl
        cmp     al, 0xE0
        jb      short kd_arm2
        jmp     near kd_out
kd_arm2:
        mov     [rep_key], bl
        mov     al, [cur_mods]
        mov     [rep_mods], al
        mov     ax, [rep_delay]
        mov     [rep_cnt], ax
kd_out:
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; A key came up.  BL = usage.  Only the repeat needs to know.
; --------------------------------------------------------------------------
key_up:
        cmp     byte [op_kbc], 0
        je      short ku_bios
        push    ax
        mov     ah, 0x80                 ; the break code a real key sends
        call    inject_scan
        pop     ax
ku_bios:
        cmp     bl, [rep_key]
        jne     short ku_ret
        mov     byte [rep_key], 0
ku_ret:
        ret

; --------------------------------------------------------------------------
; Typematic.  Called on every fast tick that did not bring a report.
; --------------------------------------------------------------------------
do_repeat:
        cmp     byte [rep_key], 0
        je      short dr_ret
        cmp     byte [op_hold], 0
        je      short dr_armed
        cmp     word [hold_n], 0
        jne     short dr_countdown
        mov     byte [rep_key], 0        ; the pretend key lets go
        ret
dr_countdown:
        dec     word [hold_n]
dr_armed:
        dec     word [rep_cnt]
        jne     short dr_ret
        mov     ax, [rep_rate]
        mov     [rep_cnt], ax
        push    bx
        mov     bl, [rep_key]
        cmp     byte [op_kbc], 0
        je      short dr_bios
        ; A real keyboard's typematic sends the make code again, so that is
        ; what this sends -- no break code in between.
        xor     ah, ah
        call    inject_scan
        inc     word [n_keys]
        jmp     short dr_pop
dr_bios:
        mov     al, bl
        mov     ah, [rep_mods]
        call    translate
        jc      short dr_pop
        or      ax, ax
        je      short dr_pop
        cmp     byte [op_hook], 0
        je      short dr_buf
        call    ring_put
        inc     word [n_keys]
        jmp     short dr_pop
dr_buf:
        call    buf_put
        jnc     short dr_delivered
        ; The buffer is full and this is an AUTO-REPEAT, not a keypress
        ; anybody made.  Carrying on at 29 a second guarantees the ring
        ; stays full, and a full ring locks out the machine's own keyboard
        ; as well as this one -- so a missed key-release would turn into
        ; the whole machine losing its keyboard until it was rebooted.
        ; Cancel the repeat instead and let the buffer drain.
        mov     byte [rep_key], 0
        jmp     short dr_pop
dr_delivered:
        inc     word [n_keys]
        call    wake_int09
dr_pop:
        pop     bx
dr_ret:
        ret

; --------------------------------------------------------------------------
; Push the lock state to the keyboard's lights, if it has changed.  This is
; a control transfer from inside a timer ISR, which is only tolerable
; because it happens on a lock keypress and nowhere else -- and the waits
; are kept short so a keyboard that stops answering costs one tick rather
; than the machine.
; --------------------------------------------------------------------------
sync_leds:
        cmp     byte [op_leds], 0
        je      short sl_ret
        mov     al, [locks]
        cmp     al, [led_now]
        je      short sl_ret
        mov     [led_now], al
        push    bx
        mov     bl, al
        mov     si, sd_setrep
        mov     al, [kbd_if]
        mov     [sd_setrep + 4], al
        mov     cx, 0x1000
        call    ctrl_out1
        pop     bx
sl_ret:
        ret

do_reboot:
        ; Tell the BIOS this is a warm boot, then jump to the reset vector.
        mov     ax, 0x40
        mov     ds, ax
        mov     word [0x72], 0x1234
        jmp     0xFFFF:0x0000

; ==========================================================================
; TABLES
; USBKBD has to use real tables where hidkey.pas uses case statements --
; assembly gives no choice.  KBDTST checks the two agree, key by key.
; ==========================================================================

; usage 04h..65h -> scancode, 98 entries
tab_scan:
        db 0x1E,0x30,0x2E,0x20,0x12,0x21,0x22,0x23   ; 04 A..H
        db 0x17,0x24,0x25,0x26,0x32,0x31,0x18,0x19   ; 0C I..P
        db 0x10,0x13,0x1F,0x14,0x16,0x2F,0x11,0x2D   ; 14 Q..X
        db 0x15,0x2C                                 ; 1C Y,Z
        db 0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09   ; 1E 1..8
        db 0x0A,0x0B                                 ; 26 9,0
        db 0x1C,0x01,0x0E,0x0F,0x39                  ; 28 Enter Esc BS Tab Sp
        db 0x0C,0x0D,0x1A,0x1B,0x2B,0x2B             ; 2D - = [ ] \ nonUS#
        db 0x27,0x28,0x29,0x33,0x34,0x35             ; 33 ; ' ` , . /
        db 0x3A                                      ; 39 Caps Lock
        db 0x3B,0x3C,0x3D,0x3E,0x3F,0x40             ; 3A F1..F6
        db 0x41,0x42,0x43,0x44,0x57,0x58             ; 40 F7..F12
        db 0x37,0x46,0x45                            ; 46 PrtSc ScrLk Pause
        db 0x52,0x47,0x49,0x53,0x4F,0x51             ; 49 Ins Home PgUp Del End PgDn
        db 0x4D,0x4B,0x50,0x48                       ; 4F Right Left Down Up
        db 0x45                                      ; 53 Num Lock
        db 0x35,0x37,0x4A,0x4E,0x1C                  ; 54 KP / * - + Enter
        db 0x4F,0x50,0x51,0x4B,0x4C,0x4D             ; 59 KP1..KP6
        db 0x47,0x48,0x49                            ; 5F KP7..KP9
        db 0x52,0x53                                 ; 62 KP0 KP.
        db 0x56                                      ; 64 non-US backslash
        db 0x5D                                      ; 65 Application
tab_scan_end:

; usage E0h..E7h -> scancode
tab_mod:
        db 0x1D,0x2A,0x38,0x5B,0x1D,0x36,0x38,0x5C

; usage 04h..38h -> unshifted character, 53 entries
tab_plain:
        db 'abcdefghijklmnopqrstuvwxyz'               ; 04..1D
        db '1234567890'                               ; 1E..27
        db 13, 27, 8, 9, ' '                          ; 28..2C
        db '-=[]\'                                    ; 2D..31
        db '\'                                        ; 32 non-US #
        db ';', 39, '`,./'                            ; 33..38
tab_plain_end:

; usage 04h..38h -> shifted character, 53 entries
tab_shift:
        db 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'               ; 04..1D
        db '!@#$%^&*()'                               ; 1E..27
        db 13, 27, 8, 9, ' '                          ; 28..2C
        db '_+{}|'                                    ; 2D..31
        db '|'                                        ; 32
        db ':"~<>?'                                   ; 33..38
tab_shift_end:

; usage 54h..58h -> character (keypad operators, always active)
tab_kp1:
        db '/*-+', 13

; usage 59h..63h -> character with NumLock on
tab_kp2:
        db '123456789', '0', '.'

; usages that need the E0 prefix
tab_ext:
        db 0x46
        db 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E
        db 0x4F, 0x50, 0x51, 0x52
        db 0x54, 0x58, 0x65
        db 0xE3, 0xE4, 0xE6, 0xE7
tab_ext_n equ $ - tab_ext

; setup packets built once and patched in place
sd_setrep:                                ; HID SET_REPORT, output, id 0
        db 0x21, 0x09, 0x00, 0x02, 0x00, 0x00, 0x01, 0x00
sd_proto:                                 ; HID SET_PROTOCOL boot
        db 0x21, 0x0B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
sd_idle:                                  ; HID SET_IDLE, infinite
        db 0x21, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00

; ==========================================================================
; PS/2 BIOS MOUSE EMULATION  (/W)
;
; Windows 3.x has never heard of INT 33h.  Its mouse support is a Windows
; DLL named in SYSTEM.INI as [boot] mouse.drv=, and the one shipped with
; Windows 3.0 -- MOUSE.DRV, 4,896 bytes, 31 October 1990 -- is a pure PS/2
; BIOS driver.  Disassembled, it never touches the 8042 at all; it drives
; everything through INT 15h AH=C2h plus one hardware vector:
;
;   * INT 15h AH=C0h must return a configuration table whose model byte is
;     F8h, FAh or FCh, or it concludes there is no pointing device at all.
;     FCh also makes it pick INT 74h, free on an XT-class machine.
;   * INT 11h bit 2 must be set -- "pointing device installed".
;   * It then runs C205h, C201h, C203h, C207h, C206h, C202h and C200h,
;     retrying twenty times on error code 4 and giving up on anything else.
;   * C207h registers a callback.  The driver hooks INT 74h itself, and its
;     handler begins by chaining to whatever was already in that vector --
;     expecting the BIOS, which reads the mouse and calls that callback.  So
;     we take INT 74h first and deliver the packet when it chains into us.
;
; That is the whole contract, and it is why none of this needs any Windows
; code: with the emulation in place the stock Microsoft driver runs
; unmodified.  Off unless /W is given, because claiming to be a PS/2 model
; FC on an 8086 is a lie other software can see.
;
; Lifted from CH375Mouse, where it was worked out by disassembling the
; driver rather than trusting a reference, and where PS2TEST proves it
; without starting Windows -- which matters, because Windows reads the
; keyboard at INT 09h and cannot be exited over the bridge.
;
; NOTE THAT THE KEYBOARD HALF IS USELESS UNDER WINDOWS for the same reason:
; it delivers into the BIOS ring and Windows never looks there.  This makes
; the MOUSE work under Windows; the machine's own keyboard has to do the
; typing.
; ==========================================================================

; Clear CF in the flags image that the IRET will restore.
;
; The offset is +8, not +6.  This is reached by a near CALL from inside an
; interrupt handler, so between the saved BP and the IRET frame there is
; also the call's own return address.  Getting that wrong clears bit 0 of
; the return CS instead of the flags, and the machine goes away the moment
; the handler returns -- which is exactly what it did.
ps2_ok:
        push    bp
        mov     bp, sp
        and     word [bp+8], 0xFFFE
        pop     bp
        ret

int11:
        pushf
        call    far [cs:old11]
        or      ax, 4                    ; bit 2: pointing device installed
        push    bp
        mov     bp, sp
        and     word [bp+6], 0xFFFE
        pop     bp
        iret

int15:
        cmp     ah, 0xC2
        je      short i15_c2
        cmp     ah, 0xC0
        je      short i15_c0
        jmp     far [cs:old15]

i15_c0:
        push    cs
        pop     es
        mov     bx, cfg_tab
        mov     ah, 0
        call    ps2_ok
        iret

i15_c2:
        push    ds
        push    cs
        pop     ds
        cmp     al, 0x00
        je      short i15_enable
        cmp     al, 0x05
        je      short i15_init
        cmp     al, 0x07
        je      short i15_sethnd
        cmp     al, 0x04
        je      short i15_type
        cmp     al, 0x01
        je      short i15_reset
        cmp     al, 0x06
        je      short i15_ext
i15_done:
        pop     ds
        mov     ah, 0
        call    ps2_ok
        iret

i15_enable:
        mov     [ps2_en], bh
        mov     byte [ps2_pnd], 0
        jmp     short i15_done
i15_init:
        mov     [ps2_pkt], bh
        jmp     short i15_done
i15_sethnd:
        cli
        mov     [ps2_hof], bx
        mov     bx, es
        mov     [ps2_hsg], bx
        sti
        jmp     short i15_done
i15_type:
        mov     bh, 0                    ; a plain two or three button mouse
        jmp     short i15_done
i15_reset:
        mov     byte [ps2_en], 0
        mov     byte [ps2_pnd], 0
        mov     bh, 0                    ; device ID
        mov     bl, 0xAA                 ; self-test passed
        jmp     short i15_done
i15_ext:
        mov     bl, 0
        mov     cl, 0
        mov     dl, 0
        jmp     short i15_done

; INT 74h.  Entered either from our own poll, or because MOUSE.DRV hooked
; the vector and chained to what it found there -- us.  Either way, if a
; packet is waiting and something has registered a callback, hand it over in
; the frame the PS/2 BIOS uses: status, X, Y and Z pushed in that order, a
; far call, and the caller cleans the stack up afterwards.
int74:
        ; Everything is saved, not just what this handler uses: the callback
        ; belongs to somebody else and there is no contract saying what it
        ; preserves.
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        push    cs
        pop     ds
        cmp     byte [ps2_pnd], 0
        je      short i74_out
        cmp     word [ps2_hsg], 0
        je      short i74_out
        mov     byte [ps2_pnd], 0
        mov     al, [ps2_st]
        xor     ah, ah
        push    ax
        mov     al, [ps2_x]
        xor     ah, ah
        push    ax
        mov     al, [ps2_y]
        xor     ah, ah
        push    ax
        xor     ax, ax                   ; Z, always zero for a 3-byte packet
        push    ax
        call    far [ps2_hof]
        add     sp, 8                    ; the callback returns a bare RETF
i74_out:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

; Turn the report just applied into a PS/2 packet and drive INT 74h with it.
; Y is inverted on the way: USB counts downwards, PS/2 counts up.
;
; This reads mrep_buf -- the boot-shaped report AFTER any report ID has been
; taken off -- so it sees the same three bytes apply_mouse does, whatever
; the device actually sent.
ps2_emit:
        cmp     byte [ps2_on], 0
        je      short ps2_none
        cmp     byte [ps2_en], 0
        je      short ps2_none
        cmp     word [ps2_hsg], 0
        je      short ps2_none

        mov     al, [mrep_buf]
        and     al, 7                    ; buttons sit in bits 0..2 either way
        or      al, 8                    ; bit 3 always reads back set
        mov     ah, [mrep_buf+1]
        mov     [ps2_x], ah
        or      ah, ah
        jns     short ps2_xpos
        or      al, 0x10                 ; X sign
ps2_xpos:
        mov     ah, [mrep_buf+2]
        neg     ah
        mov     [ps2_y], ah
        or      ah, ah
        jns     short ps2_ypos
        or      al, 0x20                 ; Y sign
ps2_ypos:
        mov     [ps2_st], al
        mov     byte [ps2_pnd], 1
        int     0x74
ps2_none:
        ret

; ==========================================================================
; THE MOUSE HALF
;
; Lifted from CH375Mouse's USBMOUSE.COM with the data renamed where the two
; halves would have collided -- mrep_buf above all, since a mouse packet
; landing in the keyboard's rep_buf would be diffed against the last key
; report and produce keystrokes.  The INT 33h semantics are unchanged, so
; MOUSETST and CLICKTST work against this driver as they do against that
; one.
;
; ONE RACE, INHERITED KNOWINGLY.  INT 33h runs in the caller's context and
; apply_mouse runs in the timer interrupt, and both touch the coordinates
; and the drawn-cursor bookkeeping.  A report landing between an
; application's hide and its show can leave the cursor cell painted with
; the wrong character underneath it.  USBMOUSE has the same race and it has
; never been seen to matter; function 7F02h exists so that a test which
; cannot tolerate it can stop the poll first, which is what MOUSETST does.
; ==========================================================================

; --------------------------------------------------------------------------
; Fold one 3-byte boot-protocol report into the driver state.
;   buf+0  bit0 left, bit1 right, bit2 middle
;   buf+1  signed X, right positive
;   buf+2  signed Y, DOWN positive (USB) -- INT 33h wants Y down too
; --------------------------------------------------------------------------
apply_mouse:
        inc     word [m_reports]
        mov     word [ev_cond], 0
        call    hide_cursor_hw

        mov     al, [mrep_buf]
        and     ax, 7
        mov     bx, [buttons]
        mov     [buttons], ax
        call    button_edges             ; BX = old, AX = new

        mov     al, [mrep_buf+1]
        cbw
        add     [mick_x], ax             ; the TRUE mickeys, before gain
        imul    word [gain]              ; DX:AX = delta * gain
        mov     bx, ax
        mov     cx, [m8_x]
        mov     si, frac_x
        mov     di, cur_x
        call    scale_axis
        mov     ax, [cur_x]
        mov     bx, [min_x]
        mov     cx, [max_x]
        call    clamp
        mov     [cur_x], ax

        mov     al, [mrep_buf+2]
        cbw
        add     [mick_y], ax             ; the TRUE mickeys, before gain
        imul    word [gain]              ; DX:AX = delta * gain
        mov     bx, ax
        mov     cx, [m8_y]
        mov     si, frac_y
        mov     di, cur_y
        call    scale_axis
        mov     ax, [cur_y]
        mov     bx, [min_y]
        mov     cx, [max_y]
        call    clamp
        mov     [cur_y], ax

        mov     al, [mrep_buf+1]
        or      al, [mrep_buf+2]
        je      short apply_nomove
        or      word [ev_cond], 1        ; bit 0: the pointer moved
apply_nomove:
        call    show_cursor_hw
        call    fire_event
        call    ps2_emit                 ; /W: the Windows 3.x path
        ret

; BX = movement in mickeys, CX = mickeys per 8 units, SI -> remainder,
; DI -> coordinate.  Working in eighths keeps slow movement from being lost
; to truncation, which is what makes a mouse feel dead at low sensitivity.
scale_axis:
        mov     ax, bx
        mov     dx, 8
        imul    dx                       ; AX = mickeys * 8
        add     ax, [si]                 ; carry the remainder forward
        mov     bx, ax
        cwd
        idiv    cx                       ; AX = units, DX = remainder
        mov     [si], dx
        add     [di], ax
        ret

; AX = value, BX = low, CX = high  ->  AX clamped
clamp:
        cmp     ax, bx
        jge     short clamp_hi
        mov     ax, bx
        ret
clamp_hi:
        cmp     ax, cx
        jle     short clamp_done
        mov     ax, cx
clamp_done:
        ret

; BX = previous button mask, AX = new.  Counts presses and releases per
; button and records where each happened, for functions 05h and 06h.
button_edges:
        push    ax
        push    bx
        mov     dx, ax
        xor     dx, bx                   ; DX = changed bits
        jne     short edges_go
        jmp     near edges_done
edges_go:
        xor     si, si                   ; button index
edges_loop:
        mov     cx, si
        mov     bx, 1
        jcxz    edges_test
edges_shift:
        shl     bx, 1
        loop    edges_shift
edges_test:
        test    dx, bx
        je      short edges_next
        test    ax, bx
        je      short edges_release
        mov     bx, si
        shl     bx, 1
        inc     word [press_n+bx]
        mov     cx, [cur_x]
        mov     [press_x+bx], cx
        mov     cx, [cur_y]
        mov     [press_y+bx], cx
        mov     cx, si                   ; press of button n is bit 1 + 2n
        shl     cx, 1
        inc     cx
        call    cond_bit
        jmp     short edges_next
edges_release:
        mov     bx, si
        shl     bx, 1
        inc     word [rel_n+bx]
        mov     cx, [cur_x]
        mov     [rel_x+bx], cx
        mov     cx, [cur_y]
        mov     [rel_y+bx], cx
        mov     cx, si                   ; release of button n is bit 2 + 2n
        shl     cx, 1
        add     cx, 2
        call    cond_bit
edges_next:
        inc     si
        cmp     si, 3
        jb      short edges_loop
edges_done:
        pop     bx
        pop     ax
        ret

; CX = a bit number; set that bit in ev_cond.  DX holds the changed-button
; mask across this and must survive, so only AX and CX are touched.
cond_bit:
        push    ax
        mov     ax, 1
        jcxz    cond_bit_set
cond_bit_shift:
        shl     ax, 1
        loop    cond_bit_shift
cond_bit_set:
        or      [ev_cond], ax
        pop     ax
        ret

; --------------------------------------------------------------------------
; Text-mode cursor.  Graphics modes get coordinates and buttons but no
; drawn pointer -- see the note in the README; an application that draws its
; own (most of them do) is unaffected.
; --------------------------------------------------------------------------
cursor_ok:                               ; ZF set if we should not draw
; The video mode is read straight out of the BIOS data area rather than with
; INT 10h AH=0Fh.  This runs inside the timer interrupt, and the BIOS video
; service is not reentrant -- a tick landing while the foreground is inside
; INT 10h would corrupt it.  40:49 is the mode, 40:4A the column count.
        push    ax
        push    bx
        push    es
        mov     bx, 0x40
        mov     es, bx
        mov     al, [es:0x49]
        cmp     al, 4
        jb      short cursor_ok_col
        cmp     al, 7
        je      short cursor_ok_mono
        pop     es
        pop     bx
        pop     ax
        xor     ax, ax                   ; a graphics mode: draw nothing
        ret
cursor_ok_mono:
        mov     word [vid_seg], 0xB000
        jmp     short cursor_ok_cols
cursor_ok_col:
        mov     word [vid_seg], 0xB800
cursor_ok_cols:
        mov     bx, [es:0x4A]
        or      bx, bx
        jne     short cursor_ok_have
        mov     bx, 80
cursor_ok_have:
        mov     [vid_col], bx
        pop     es
        pop     bx
        pop     ax
        mov     al, 1
        or      al, al                   ; ZF clear: go ahead
        ret

hide_cursor_hw:
        cmp     byte [drawn], 0
        je      short hide_ret
        push    ax
        push    es
        mov     es, [vid_seg]
        mov     di, [draw_off]
        mov     ax, [draw_old]
        mov     [es:di], ax
        mov     byte [drawn], 0
        pop     es
        pop     ax
hide_ret:
        ret

show_cursor_hw:
        cmp     word [vis], 0
        jl      short show_ret
        cmp     byte [drawn], 0
        jne     short show_ret
        call    cursor_ok
        je      short show_ret
        push    ax
        push    bx
        push    dx
        push    es
        mov     ax, [cur_y]
        mov     cl, 3
        shr     ax, cl                   ; row
        mul     word [vid_col]
        mov     bx, [cur_x]
        shr     bx, cl                   ; column
        add     ax, bx
        shl     ax, 1
        mov     di, ax
        mov     [draw_off], di
        mov     es, [vid_seg]
        mov     ax, [es:di]
        mov     [draw_old], ax
        and     ax, [scr_msk]
        xor     ax, [cur_msk]
        mov     [es:di], ax
        mov     byte [drawn], 1
        pop     es
        pop     dx
        pop     bx
        pop     ax
show_ret:
        ret

; --------------------------------------------------------------------------
; Call the application's event handler, if it asked for one and this event
; is in its mask.  Anything the handler does is its own business; we give it
; the register set the Microsoft driver documents and a stack of our own.
; --------------------------------------------------------------------------
; Call the application's handler, but only for events it actually asked for,
; and tell it which ones happened.  The first version of this passed AX=1
; -- "the pointer moved" -- for every report whatever the mask said, so an
; application that had subscribed to button presses alone was called
; constantly and never once told a button had been pressed.  That is what
; made clicks appear not to work while movement did.
;
;   bit0 moved   bit1/2 left press/release   bit3/4 right   bit5/6 middle
fire_event:
        mov     ax, [ev_seg]
        or      ax, ax
        je      short fire_ret
        mov     ax, [ev_cond]
        and     ax, [ev_mask]
        je      short fire_ret
        push    bp
        mov     bx, [buttons]
        mov     cx, [cur_x]
        mov     dx, [cur_y]
        mov     si, [mick_x]
        mov     di, [mick_y]
        push    ds
        call    far [cs:ev_off]
        pop     ds
        pop     bp
fire_ret:
        ret

int33:
        sti
        push    ds
        push    bp
        push    si
        push    di
        push    bx
        push    cx
        push    dx
        push    ax
        mov     bp, sp                   ; [bp+0]=ax [bp+2]=dx [bp+4]=cx
                                         ; [bp+6]=bx [bp+8]=di [bp+10]=si
        push    cs
        pop     ds

        cmp     ax, 0x7F00
        jne     short i33_not_stat
        jmp     near f_dbgstat
i33_not_stat:
        cmp     ax, 0x7F01
        jne     short i33_not_inj
        jmp     near f_inject
i33_not_inj:
        cmp     ax, 0x7F02
        jne     short i33_not_pause
        jmp     near f_pause
i33_not_pause:
        cmp     ax, 0x7F03
        jne     short i33_not_raw
        jmp     near f_dbgraw
i33_not_raw:
        cmp     ax, 0x7F04
        jne     short i33_not_wire
        jmp     near f_dbgwire
i33_not_wire:
        cmp     ax, 0x24
        jbe     short i33_ok
        jmp     near i33_out
i33_ok:
        mov     bx, ax
        shl     bx, 1
        jmp     word [i33_tab+bx]

i33_tab:
        dw      f_reset,  f_show,   f_hide,   f_getpos     ; 00 01 02 03
        dw      f_setpos, f_press,  f_rel,    f_xrange     ; 04 05 06 07
        dw      f_yrange, f_nop,    f_textcur,f_motion     ; 08 09 0A 0B
        dw      f_setev,  f_nop,    f_nop,    f_mick       ; 0C 0D 0E 0F
        dw      f_nop,    f_nop,    f_nop,    f_nop        ; 10 11 12 13
        dw      f_swapev, f_statesz,f_nop,    f_nop        ; 14 15 16 17
        dw      f_altbad, f_altbad, f_setsens,f_getsens    ; 18 19 1A 1B
        dw      f_nop,    f_nop,    f_nop,    f_disable    ; 1C 1D 1E 1F
        dw      f_enable, f_reset,  f_nop,    f_lang       ; 20 21 22 23
        dw      f_ver                                      ; 24

i33_out:
        pop     ax
        pop     dx
        pop     cx
        pop     bx
        pop     di
        pop     si
        pop     bp
        pop     ds
        iret

f_nop:
        jmp     short i33_out

; --- 00h / 21h  reset ---
f_reset:
        call    hide_cursor_hw
        mov     word [vis], -1
        mov     word [min_x], 0
        mov     word [max_x], 639
        mov     word [min_y], 0
        mov     word [max_y], 199
        mov     word [cur_x], 320
        mov     word [cur_y], 100
        mov     word [buttons], 0
        mov     word [mick_x], 0
        mov     word [mick_y], 0
        mov     word [frac_x], 0
        mov     word [frac_y], 0
        mov     word [m8_x], 8
        mov     word [m8_y], 16
        mov     word [scr_msk], 0x77FF
        mov     word [cur_msk], 0x7700
        mov     word [ev_seg], 0
        mov     word [ev_mask], 0
        mov     word [bp+0], 0xFFFF      ; AX: driver installed
        mov     word [bp+6], 3           ; BX: three buttons
        jmp     near i33_out

; --- 01h show ---
f_show:
        inc     word [vis]
        cmp     word [vis], 0
        jle     short f_show_x
        mov     word [vis], 0
f_show_x:
        call    show_cursor_hw
        jmp     near i33_out

; --- 02h hide ---
f_hide:
        call    hide_cursor_hw
        dec     word [vis]
        jmp     near i33_out

; --- 03h position and buttons ---
f_getpos:
        mov     ax, [buttons]
        mov     [bp+6], ax
        mov     ax, [cur_x]
        mov     [bp+4], ax
        mov     ax, [cur_y]
        mov     [bp+2], ax
        jmp     near i33_out

; --- 04h set position ---
f_setpos:
        call    hide_cursor_hw
        mov     ax, [bp+4]
        mov     bx, [min_x]
        mov     cx, [max_x]
        call    clamp
        mov     [cur_x], ax
        mov     ax, [bp+2]
        mov     bx, [min_y]
        mov     cx, [max_y]
        call    clamp
        mov     [cur_y], ax
        call    show_cursor_hw
        jmp     near i33_out

; --- 05h button press info,  06h release info ---
f_press:
        mov     si, press_n
        jmp     short f_pr_common
f_rel:
        mov     si, rel_n
f_pr_common:
        mov     bx, [bp+6]               ; button index
        cmp     bx, 2
        jbe     short f_pr_ok
        xor     bx, bx
f_pr_ok:
        shl     bx, 1
        mov     ax, [buttons]
        mov     [bp+0], ax
        mov     ax, [si+bx]
        mov     word [si+bx], 0
        mov     [bp+6], ax
        mov     ax, [si+bx+6]            ; x array follows the count array
        mov     [bp+4], ax
        mov     ax, [si+bx+12]
        mov     [bp+2], ax
        jmp     near i33_out

; --- 07h / 08h ranges ---
f_xrange:
        mov     ax, [bp+4]
        mov     bx, [bp+2]
        cmp     ax, bx
        jle     short f_xr_ok
        xchg    ax, bx
f_xr_ok:
        mov     [min_x], ax
        mov     [max_x], bx
        jmp     near i33_out
f_yrange:
        mov     ax, [bp+4]
        mov     bx, [bp+2]
        cmp     ax, bx
        jle     short f_yr_ok
        xchg    ax, bx
f_yr_ok:
        mov     [min_y], ax
        mov     [max_y], bx
        jmp     near i33_out

; --- 0Ah define text cursor ---
f_textcur:
        cmp     word [bp+6], 0
        jne     short f_tc_hw
        mov     ax, [bp+4]
        mov     [scr_msk], ax
        mov     ax, [bp+2]
        mov     [cur_msk], ax
f_tc_hw:
        jmp     near i33_out

; --- 0Bh motion counters ---
f_motion:
        mov     ax, [mick_x]
        mov     [bp+4], ax
        mov     word [mick_x], 0
        mov     ax, [mick_y]
        mov     [bp+2], ax
        mov     word [mick_y], 0
        jmp     near i33_out

; --- 0Ch install event handler ---
f_setev:
        cli
        mov     ax, [bp+4]
        mov     [ev_mask], ax
        mov     ax, [bp+2]
        mov     [ev_off], ax
        mov     ax, es
        mov     [ev_seg], ax
        sti
        jmp     near i33_out

; --- 14h swap event handler ---
f_swapev:
        cli
        mov     ax, [ev_mask]
        mov     bx, [ev_off]
        mov     cx, [ev_seg]
        mov     dx, [bp+4]
        mov     [ev_mask], dx
        mov     dx, [bp+2]
        mov     [ev_off], dx
        mov     dx, es
        mov     [ev_seg], dx
        sti
        mov     [bp+4], ax
        mov     [bp+2], bx
        mov     es, cx
        jmp     near i33_out

; --- 0Fh mickeys per 8 units ---
f_mick:
        mov     ax, [bp+4]
        or      ax, ax
        je      short f_mick_y
        mov     [m8_x], ax
f_mick_y:
        mov     ax, [bp+2]
        or      ax, ax
        je      short f_mick_x
        mov     [m8_y], ax
f_mick_x:
        jmp     near i33_out

; --- 15h state buffer size ---
f_statesz:
        mov     word [bp+6], state_end - state_start
        jmp     near i33_out

; --- 18h / 19h alternate handlers: not supported, and say so ---
f_altbad:
        mov     word [bp+0], 0xFFFF
        jmp     near i33_out

; --- 1Ah / 1Bh sensitivity ---
f_setsens:
        mov     ax, [bp+6]
        or      ax, ax
        je      short f_ss_y
        mov     [m8_x], ax
f_ss_y:
        mov     ax, [bp+4]
        or      ax, ax
        je      short f_ss_done
        mov     [m8_y], ax
f_ss_done:
        jmp     near i33_out
f_getsens:
        mov     ax, [m8_x]
        mov     [bp+6], ax
        mov     ax, [m8_y]
        mov     [bp+4], ax
        mov     word [bp+2], 64
        jmp     near i33_out

; --- 1Fh disable, 20h enable ---
f_disable:
        call    hide_cursor_hw
        mov     word [vis], -1
        mov     word [bp+0], 0x001F
        mov     ax, [old33]
        mov     [bp+6], ax
        mov     ax, [old33+2]
        mov     es, ax
        jmp     near i33_out
f_enable:
        jmp     near i33_out

; --- 23h language ---
f_lang:
        mov     word [bp+6], 0
        jmp     near i33_out

; --- 24h version and type ---
; This is the INT 33h API LEVEL, not this driver's version: applications
; switch features on by it, so it says what the interface does, not which
; build is answering.  The build's own version is ver_str, up at 010B.
f_ver:
        mov     word [bp+6], 0x0700      ; report as 7.00
        mov     word [bp+4], 0x0400      ; CH=4 "other bus", CL=0 no IRQ
        jmp     near i33_out

; --------------------------------------------------------------------------
; Two private functions, outside the Microsoft numbering.  They exist because
; the USB half and the INT 33h half fail independently, and without them a
; driver that reports nothing gives no clue which half is at fault.
;
;   AX=7F00h  status:  BX = 1 if the mouse half enumerated
;                      CL = its interrupt IN endpoint, CH = last CH375 status
;                      DX = mouse report counter
;                      AL = 1 if its reports carry a report ID (see the
;                      wrinkle in the header), AH = last report length
;   AX=7F01h  inject a HID boot report: BL = buttons, CL = dx, CH = dy.
;             Everything downstream of the USB read -- scaling, clamping,
;             button edges, the text cursor, the event callback -- runs
;             exactly as it would for a real report.  This is how the driver
;             is tested when the USB device will not answer.
; --------------------------------------------------------------------------
f_dbgstat:
        mov     al, [mou_id]             ; AL: reports carry a report ID
        mov     ah, [mrep_len]           ; AH: length of the last one
        mov     [bp+0], ax
        mov     al, [mlive]
        xor     ah, ah
        mov     [bp+6], ax
        mov     al, [mep_in]
        mov     ah, [mlast_ist]
        mov     [bp+4], ax
        mov     ax, [m_reports]
        mov     [bp+2], ax
        jmp     near i33_out

; AX=7F02h  suspend or resume the USB poll.  BX=1 stops the timer touching
; the CH375, BX=0 lets it again; the previous setting comes back in BX.
; MOUSETST needs this: its checks inject an exact report and read the state
; straight back, and a real mouse moving underneath makes that non-repeatable.
; AX=7F03h  the last raw report, for working out whether a button press ever
; reached the driver at all:
;   BL/BH = report bytes 0 and 1, CL/CH = bytes 2 and 3
;   AL = every button bit ever seen, AH = length of the last report
;   DX = how many reports carried a button down
; AX=7F04h  the last packet exactly as it came off the wire, BEFORE any
; report ID was taken off the front:
;   BL/BH = bytes 0 and 1,  CL/CH = bytes 2 and 3
;   DL = byte 4,  DH = how many bytes arrived
;   AL = 1 if a report ID has ever been seen,  AH = 0
; 7F03h shows the same packet after the strip; the pair together is what
; tells a wrong strip from a device sending something unexpected.
f_dbgwire:
        mov     al, [mwire_buf]
        mov     ah, [mwire_buf + 1]
        mov     [bp+6], ax
        mov     al, [mwire_buf + 2]
        mov     ah, [mwire_buf + 3]
        mov     [bp+4], ax
        mov     al, [mwire_buf + 4]
        mov     ah, [mrep_len]
        mov     [bp+2], ax
        mov     al, [mou_id]
        xor     ah, ah
        mov     [bp+0], ax
        jmp     near i33_out

f_dbgraw:
        mov     al, [mrep_buf]
        mov     ah, [mrep_buf+1]
        mov     [bp+6], ax
        mov     al, [mrep_buf+2]
        mov     ah, [mrep_buf+3]
        mov     [bp+4], ax
        mov     ax, [mbtn_reps]
        mov     [bp+2], ax
        mov     al, [mbtn_seen]
        mov     ah, [mrep_len]
        mov     [bp+0], ax
        jmp     near i33_out

f_pause:
        mov     al, [mpoll_off]
        xor     ah, ah
        mov     dx, [bp+6]
        mov     [mpoll_off], dl
        mov     [bp+6], ax
        or      dl, dl
        je      short f_pause_out
        ; Suspending.  A poll that is already in flight will still apply its
        ; report after this returns, so wait for it -- otherwise a caller that
        ; has just asked for quiet can get one more movement on top of the
        ; state it is about to check, which is exactly the intermittent
        ; failure this function exists to prevent.
        xor     cx, cx
f_pause_w:
        cmp     byte [in_poll], 0
        je      short f_pause_out
        loop    f_pause_w
f_pause_out:
        jmp     near i33_out

f_inject:
        mov     al, [bp+6]               ; BL: buttons
        mov     [mrep_buf], al
        mov     ax, [bp+4]               ; CL: dx,  CH: dy
        mov     [mrep_buf+1], al
        mov     [mrep_buf+2], ah
        cli
        call    apply_mouse
        sti
        jmp     near i33_out

state_start equ cur_x
state_end   equ mrep_buf


resident_end:

; ==========================================================================
; EVERYTHING BELOW HERE IS DISCARDED WHEN THE DRIVER GOES RESIDENT
; ==========================================================================

; --------------------------------------------------------------------------
; Bring the CH375 and the keyboard up.  CF set on failure, with a message
; already chosen in bu_err.  Called both from init and, for /F, from the
; hot-plug retry inside the ISR -- so it must not print anything itself.
; --------------------------------------------------------------------------
bringup:
        mov     byte [live], 0
        mov     byte [mlive], 0
        mov     al, CMD_CHECK_EXIST
        call    ch_cmd
        mov     al, 0x55
        call    ch_wr
        call    ch_rd
        cmp     al, 0xAA
        je      short bu_chip
        mov     word [bu_err], msg_nochip
        stc
        ret
bu_chip:
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 60
        call    delay_ms
        mov     al, CMD_GET_IC_VER
        call    ch_cmd
        call    ch_rd
        mov     [ic_ver], al
        cmp     al, 0xB5
        jb      short bu_oldchip
        cmp     al, 0xC0
        jb      short bu_ok
bu_oldchip:
        mov     word [bu_err], msg_oldchip
        stc
        ret
bu_ok:
        mov     al, 5                    ; host mode, no SOF
        call    set_mode
        call    bu_conn
        mov     dx, msg_t_conn
        call    bu_trace
        mov     cx, 100
        call    delay_ms
        mov     al, 7                    ; hold the bus in reset
        call    set_mode
        mov     cx, 40
        call    delay_ms
        mov     al, 6                    ; host mode, auto SOF
        call    set_mode
        call    bu_conn
        mov     dx, msg_t_conn2
        call    bu_trace
        mov     cx, 200
        call    delay_ms
        call    drain

        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        mov     al, 0x8F                 ; retry NAKs while enumerating
        call    ch_wr

        ; --- speed.  This has to be here and nowhere else: SET_USB_MODE
        ; puts the bus back to 12 Mbps, and the speed change is silently
        ; ignored until the connect interrupt raised by the bus reset has
        ; been read and cleared.  Move it and it stops working while
        ; looking exactly like a hardware fault.
        mov     al, CMD_READ_REG
        call    ch_cmd
        mov     al, 0x07
        call    ch_wr
        call    ch_rd
        mov     dx, msg_t_rate
        call    bu_trace
        test    al, 0x10
        je      short bu_fullspeed
        mov     byte [low_spd], 1
        mov     al, CMD_SET_SPEED
        call    ch_cmd
        mov     al, 2                    ; 1.5 Mbps
        call    ch_wr
        call    ch_rd
        mov     cx, 400
        call    delay_ms
bu_fullspeed:

        ; --- device descriptor, still at address 0 ---
        mov     bx, 6
bu_dd:
        mov     al, CMD_GET_DESCR
        call    ch_cmd
        mov     al, 1
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short bu_dd_next
        cmp     al, INT_SUCCESS
        je      short bu_dd_got
bu_dd_next:
        mov     [last_st], al
        mov     cx, 150
        call    delay_ms
        dec     bx
        jne     short bu_dd
        mov     word [bu_err], msg_nodev
        stc
        ret
bu_dd_got:
        mov     dx, msg_t_descr
        call    bu_trace
        push    ds
        pop     es
        mov     di, desc_buf
        mov     cx, 64
        call    ch_read
        ; byte 7 is the endpoint-0 max packet size, which short-packet
        ; detection needs
        mov     al, [desc_buf + 7]
        or      al, al
        jne     short bu_ep0ok
        mov     al, 8
bu_ep0ok:
        mov     [ep0max], al

        jmp     short bu_addr
bu_j_fail:
        jmp     near bu_fail

        ; --- address ---
bu_addr:
        mov     al, CMD_SET_ADDRESS
        call    ch_cmd
        mov     al, USB_ADDR
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short bu_j_fail
        cmp     al, INT_SUCCESS
        jne     short bu_j_fail
        mov     al, CMD_SET_USB_ADDR
        call    ch_cmd
        mov     al, USB_ADDR
        call    ch_wr
        mov     cx, 20
        call    delay_ms

        ; --- configuration descriptor ---
        mov     al, CMD_GET_DESCR
        call    ch_cmd
        mov     al, 2
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short bu_j_fail
        cmp     al, INT_SUCCESS
        jne     short bu_j_fail
        push    ds
        pop     es
        mov     di, cfg_buf
        mov     cx, 128
        call    ch_read
        mov     [cfg_len], al

        call    parse_config
        jnc     short bu_cfg_ok
        jmp     near bu_notkbd
bu_cfg_ok:

        ; --- configure, then boot protocol and infinite idle ---
        mov     al, CMD_SET_CONFIG
        call    ch_cmd
        mov     al, [cfg_val]
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short bu_j_fail
        cmp     al, INT_SUCCESS
        jne     short bu_j_fail
        mov     cx, 50
        call    delay_ms

        ; --- the keyboard interface ---
        cmp     byte [kb_found], 0
        je      short bu_no_kbif
        mov     al, [kbd_if]
        mov     [sd_proto + 4], al
        mov     [sd_idle + 4], al
        ; wValue high byte is the idle duration in 4 ms units; 0 means
        ; "report only when something changes", which is what a driver
        ; wants and what makes an idle keyboard silent.  A nonzero rate is
        ; for testing: it makes the keyboard repeat its state forever, so
        ; the report path can be watched without anybody pressing a key.
        mov     al, [hid_idle]
        mov     [sd_idle + 3], al
        mov     si, sd_proto
        call    ctrl_nodata
        mov     dx, msg_t_proto
        call    bu_trace
        mov     si, sd_idle
        call    ctrl_nodata
        mov     dx, msg_t_idle
        call    bu_trace
bu_no_kbif:

        ; --- the mouse interface, the same two requests ---
        ;
        ; SET_PROTOCOL matters more here than it does for a keyboard.  This
        ; adapter's mouse interface declares report IDs, so in its native
        ; mode every packet arrives with a leading ID byte and a boot-report
        ; parser reads the buttons out of the ID field.  Asking for protocol
        ; 0 asks for the 3-byte boot report instead.
        ;
        ; The answer is not trusted either way: a device may stall this
        ; request or accept it and carry on as before, so poll_mou decides
        ; from the packet.  Nothing below depends on this having worked.
        cmp     byte [mo_found], 0
        je      short bu_no_mouif
        cmp     byte [op_noboot], 0
        jne     short bu_no_mouproto
        mov     al, [mou_if]
        mov     [sd_proto + 4], al
        mov     si, sd_proto
        call    ctrl_nodata
        push    ax
        mov     dx, msg_t_mproto
        call    bu_trace
        pop     ax
        ; Only a device that ACKNOWLEDGED the request is held to it.  One
        ; that stalls SET_PROTOCOL is free to send whatever it likes, and
        ; the length filter below must not be applied to it.
        cmp     al, INT_SUCCESS
        jne     short bu_no_mouproto
        mov     byte [mou_boot], 1
bu_no_mouproto:
        ; SET_IDLE 0 on the mouse as well, and unconditionally 0 whatever
        ; /Y said: /Y is a keyboard diagnostic, and a mouse that repeats
        ; its last report forever would move the pointer forever.
        mov     al, [mou_if]
        mov     [sd_idle + 4], al
        mov     byte [sd_idle + 3], 0
        mov     si, sd_idle
        call    ctrl_nodata
        mov     dx, msg_t_midle
        call    bu_trace
bu_no_mouif:

        ; A NAK from the key endpoint must come straight back, or an idle
        ; keyboard would hold the timer ISR for as long as it stayed idle.
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        xor     al, al
        call    ch_wr

        mov     byte [ep_tog], 0x80
        mov     byte [mep_tog], 0x80     ; each endpoint owns its own toggle
        mov     byte [led_now], 0xFF     ; force the first LED sync

        ; Only now does either half go live.  parse_config decided which
        ; halves exist; committing that here rather than there means a
        ; failure anywhere in between leaves both halves switched off
        ; instead of leaving the poll issuing tokens to endpoint 0.
        mov     al, [kb_found]
        mov     [live], al
        mov     al, [mo_found]
        mov     [mlive], al
        clc
        ret

bu_notkbd:
        mov     word [bu_err], msg_notkbd
        stc
        ret
bu_fail:
        mov     [last_st], al
        mov     word [bu_err], msg_nodev
        stc
        ret

; Wait for a connect interrupt, up to about a fifth of a second.
bu_conn:
        push    cx
        mov     bx, 12
bu_conn_l:
        mov     cx, 0x8000
        call    ch_wait
        jc      short bu_conn_n
        cmp     al, INT_CONNECT
        je      short bu_conn_y
bu_conn_n:
        dec     bx
        jne     short bu_conn_l
bu_conn_y:
        pop     cx
        ret

; --------------------------------------------------------------------------
; Walk the configuration descriptor once, looking for BOTH boot HID
; interfaces and the first interrupt IN endpoint inside each.
;
; The descriptor is a flat byte stream, not a tree: endpoints belong to
; whichever interface descriptor most recently preceded them.  So the walk
; carries "which interface am I inside" as it goes, and an interface that is
; neither a boot keyboard nor a boot mouse clears both flags -- otherwise a
; vendor interface's endpoints would be adopted by whatever came before it.
; That is not hypothetical on this adapter: interface 0's report descriptor
; and interface 1's sit between them.
;
; Either half on its own is enough.  A plain keyboard, a plain mouse and an
; adapter carrying both are all valid outcomes; CF is set only when neither
; turned up.  The result goes in kb_found / mo_found, not live / mlive --
; see the note where bring-up commits them.
; --------------------------------------------------------------------------
parse_config:
        mov     si, cfg_buf
        mov     ch, 0
        mov     cl, [cfg_len]
        cmp     cl, 9
        jae     short pc_lenok
        jmp     near pc_fail
pc_lenok:
        mov     al, [cfg_buf + 5]
        mov     [cfg_val], al
        mov     byte [in_kbd], 0
        mov     byte [in_mou], 0
        mov     byte [got_if], 0
        mov     byte [got_ep], 0
        mov     byte [mgot_if], 0
        mov     byte [mgot_ep], 0
        mov     byte [kb_found], 0
        mov     byte [mo_found], 0
        xor     bx, bx                   ; BX = offset
        jmp     short pc_loop            ; over the trampoline, not into it

; Two range fixes, and they are structural rather than cosmetic.  The 8086
; has no near conditional jump, so a target out of short reach has to be
; reached by inverting the test over an unconditional jump or through a
; trampoline -- and this loop is now long enough that both ends of it are
; out of reach of the middle.  pc_t_done is that trampoline; pc_next is
; placed BETWEEN the interface half and the endpoint half further down, so
; that both halves reach it, one forwards and one back.
pc_t_done:
        jmp     near pc_done
pc_loop:
        mov     al, bl
        add     al, 2
        cmp     al, cl
        ja      short pc_t_done
        mov     al, [si + bx]            ; bLength -- AL survives to pc_next
        cmp     al, 2
        jb      short pc_t_done
        mov     ah, [si + bx + 1]        ; bDescriptorType
        cmp     ah, 4
        jne     short pc_notif

        ; An interface descriptor.  Whatever it turns out to be, the
        ; endpoints that follow are no longer the previous interface's.
        mov     byte [in_kbd], 0
        mov     byte [in_mou], 0
        cmp     byte [si + bx + 5], 3    ; bInterfaceClass = HID
        jne     short pc_next
        mov     dh, [si + bx + 7]        ; bInterfaceProtocol
        cmp     dh, 1                    ; 1 = boot keyboard
        je      short pc_is_kbd
        cmp     dh, 2                    ; 2 = boot mouse
        je      short pc_is_mou
        jmp     short pc_next
pc_is_kbd:
        cmp     byte [op_nokbd], 0       ; /NK: leave it alone
        jne     short pc_next
        mov     byte [in_kbd], 1
        cmp     byte [got_if], 0
        jne     short pc_next
        mov     ah, [si + bx + 2]
        mov     [kbd_if], ah
        mov     byte [got_if], 1
        jmp     short pc_next
pc_is_mou:
        cmp     byte [op_nomou], 0       ; /NM: leave it alone
        jne     short pc_next
        mov     byte [in_mou], 1
        cmp     byte [mgot_if], 0
        jne     short pc_next
        mov     ah, [si + bx + 2]
        mov     [mou_if], ah
        mov     byte [mgot_if], 1

; Deliberately here, in the middle.  Everything above jumps forward to it
; and everything below jumps back, and each side is inside the 128 bytes a
; short jump reaches; at the bottom of the routine, where it reads more
; naturally, half the loop could not see it.
pc_next:
        xor     ah, ah
        add     bx, ax
        jmp     near pc_loop

pc_notif:
        cmp     ah, 5                    ; an endpoint descriptor
        jne     short pc_next
        mov     ah, [si + bx + 2]        ; bEndpointAddress
        test    ah, 0x80                 ; must be IN
        je      short pc_next
        mov     dl, [si + bx + 3]        ; bmAttributes
        and     dl, 3
        cmp     dl, 3                    ; must be interrupt
        jne     short pc_next
        and     ah, 0x0F
        cmp     byte [in_kbd], 0
        je      short pc_ep_mou
        cmp     byte [got_ep], 0
        jne     short pc_next
        mov     [ep_in], ah
        mov     byte [got_ep], 1
        jmp     short pc_next
pc_ep_mou:
        cmp     byte [in_mou], 0
        je      short pc_next
        cmp     byte [mgot_ep], 0
        jne     short pc_next
        mov     [mep_in], ah
        mov     byte [mgot_ep], 1
        jmp     short pc_next

pc_done:
        ; An interface without an endpoint is no use, and an endpoint
        ; without its interface number cannot be configured, so each half
        ; needs both before it counts as found.
        cmp     byte [got_if], 0
        je      short pc_no_kbd
        cmp     byte [got_ep], 0
        je      short pc_no_kbd
        mov     byte [kb_found], 1
pc_no_kbd:
        cmp     byte [mgot_if], 0
        je      short pc_no_mou
        cmp     byte [mgot_ep], 0
        je      short pc_no_mou
        mov     byte [mo_found], 1
pc_no_mou:
        cmp     byte [kb_found], 0
        jne     short pc_ok
        cmp     byte [mo_found], 0
        je      short pc_fail
pc_ok:
        clc
        ret
pc_fail:
        stc
        ret

set_mode:                                ; AL = mode code
        push    ax
        mov     al, CMD_SET_USB_MODE
        call    ch_cmd
        pop     ax
        call    ch_wr
        mov     cx, 20
        call    delay_ms
        call    ch_rd
        ret

; Swallow any pending interrupt so the next wait sees a fresh one.
drain:
        push    ax
        push    cx
        mov     bx, 8
drain_loop:
        push    dx
        mov     dx, [io_cmd]
        in      al, dx
        pop     dx
        test    al, 0x80
        jne     short drain_done
        mov     al, CMD_GET_STATUS
        call    ch_cmd
        call    ch_rd
        dec     bx
        jne     short drain_loop
drain_done:
        pop     cx
        pop     ax
        ret

; CX milliseconds, near enough, on anything from a 4.77 MHz 8088 up.
delay_ms:
        push    ax
        push    cx
        push    dx
delay_outer:
        push    cx
        mov     cx, 1200
delay_inner:
        push    dx
        mov     dx, 0x61
        in      al, dx
        pop     dx
        loop    delay_inner
        pop     cx
        loop    delay_outer
        pop     dx
        pop     cx
        pop     ax
        ret

; ==========================================================================
; CONSOLE
; ==========================================================================

putc:
        push    ax
        push    dx
        mov     dl, al
        mov     ah, 2
        int     0x21
        pop     dx
        pop     ax
        ret

crlf:
        push    ax
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        pop     ax
        ret

puts:                                    ; DX -> '$'-terminated string
        push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret

puthex:                                  ; AL
        push    ax
        push    cx
        mov     cl, 4
        shr     al, cl
        call    puthex1
        pop     cx
        pop     ax
        push    ax
        and     al, 0x0F
        call    puthex1
        pop     ax
        ret
puthex1:
        add     al, '0'
        cmp     al, '9'
        jbe     short puthex1_p
        add     al, 7
puthex1_p:
        call    putc
        ret

putdecw:                                 ; AX, 0..65535
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
putdecw_d:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jne     short putdecw_d
putdecw_p:
        pop     ax
        add     al, '0'
        call    putc
        loop    putdecw_p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; DX -> label; prints it and the status in AL, but only under /V.
bu_trace:
        cmp     byte [op_verb], 0
        je      short bu_trace_out
        push    ax
        call    puts
        pop     ax
        push    ax
        call    puthex
        call    crlf
        pop     ax
bu_trace_out:
        ret

; ==========================================================================
; INIT
; ==========================================================================

init:
        cld                              ; same rule, transient side
        call    parse_args
        mov     dx, msg_prog
        call    puts
        mov     dx, ver_str
        call    puts
        mov     dx, msg_by
        call    puts

        cmp     byte [op_help], 0
        je      short init_nohelp
        mov     dx, msg_help
        call    puts
        jmp     near quit

init_nohelp:
        call    find_resident
        cmp     byte [op_status], 0
        je      short not_status
        jmp     near do_status
not_status:
        cmp     byte [op_unload], 0
        je      short not_unload
        jmp     near do_unload
not_unload:
        cmp     word [res_seg], 0
        je      short init_fresh
        mov     dx, msg_already
        call    puts
        mov     al, 1
        jmp     near die_now

init_fresh:
        call    bringup
        jnc     short init_gotkbd
        cmp     byte [op_force], 0
        jne     short init_force
        mov     dx, [bu_err]
        call    puts
        cmp     byte [last_st], 0
        je      short init_dieonly
        mov     dx, msg_laststat
        call    puts
        mov     al, [last_st]
        call    puthex
        call    crlf
init_dieonly:
        mov     al, 1
        jmp     near die_now

init_force:
        mov     dx, msg_forced
        call    puts
        jmp     near init_hook

init_gotkbd:
        ; One line per half that came up, and neither is guaranteed: /NK,
        ; /NM, a plain keyboard and a plain mouse all land here with only
        ; one of them set.
        cmp     byte [live], 0
        je      short init_no_kbline
        mov     dx, msg_found
        call    puts
        mov     al, [ep_in]
        call    putdecw_al
        mov     dx, msg_iface
        call    puts
        mov     al, [kbd_if]
        call    putdecw_al
        call    crlf
init_no_kbline:
        cmp     byte [mlive], 0
        je      short init_no_mouline
        mov     dx, msg_mfound
        call    puts
        mov     al, [mep_in]
        call    putdecw_al
        mov     dx, msg_iface
        call    puts
        mov     al, [mou_if]
        call    putdecw_al
        call    crlf
init_no_mouline:
        mov     dx, msg_vidpid
        call    puts
        mov     al, [desc_buf + 9]
        call    puthex
        mov     al, [desc_buf + 8]
        call    puthex
        mov     al, '/'
        call    putc
        mov     al, [desc_buf + 11]
        call    puthex
        mov     al, [desc_buf + 10]
        call    puthex
        call    crlf
        cmp     byte [low_spd], 0
        jne     short init_saylow
        jmp     near init_hook
init_saylow:
        mov     dx, msg_lowspd
        call    puts

        ; ------------------------------------------------------------------
        ; /T -- self-test the delivery path, then exit without going
        ; resident.
        ;
        ; Every other check in this project tests the driver's PLUMBING:
        ; that it enumerated, that the timer calls it, that its tables
        ; agree with hidkey.pas.  None of them tests the one thing that
        ; matters most -- that a usage arriving from the keyboard comes out
        ; of INT 16h as the right key -- because that needed somebody to
        ; press a key.  This drives usage 04h ('a') through the real
        ; key_down path and then reads INT 16h back, so a delivery
        ; regression cannot hide behind 33 passing checks again.
        ; ------------------------------------------------------------------
        cmp     byte [op_test], 0
        jne     short init_dotest
        jmp     near init_notest
init_dotest:
        mov     dx, msg_t_start
        call    puts

        ; drain anything already pending, so what comes back is ours
        mov     bx, 32
st_drain:
        mov     ah, 1
        int     0x16
        jz      short st_drained
        mov     ah, 0
        int     0x16
        dec     bx
        jne     short st_drain
st_drained:
        mov     byte [cur_mods], 0
        call    adopt_locks

        ; --- 1: translate and buf_put, driven straight from key_down ---
        mov     bl, 0x04                 ; usage 04h, the 'a' key
        call    key_down
        mov     byte [rep_key], 0        ; no repeat: we are about to exit
        call    st_read
        jnc     short st_g1
        jmp     near st_nokey
st_g1:
        cmp     ax, 0x1E61
        je      short st_g3
        jmp     near st_wrong
st_g3:
        mov     dx, msg_t_one
        call    puts

        ; --- 2: the same key as a whole REPORT, through the press/release
        ; diff that the interrupt handler uses.  This is the part that
        ; turns a state into an event, and testing key_down alone walks
        ; straight past it.
        mov     di, prev_rep
        mov     cx, 8
        xor     al, al
        push    ds
        pop     es
        rep     stosb
        mov     di, rep_buf
        mov     cx, 8
        xor     al, al
        rep     stosb
        mov     byte [rep_buf + 2], 0x04
        call    apply_report
        mov     byte [rep_key], 0
        call    st_read
        jnc     short st_g2
        jmp     near st_nokey
st_g2:
        cmp     ax, 0x1E61
        je      short st_g4
        jmp     near st_wrong
st_g4:
        mov     dx, msg_t_two
        call    puts

        ; --- 3: releasing it must produce nothing at all ---
        mov     di, rep_buf
        mov     cx, 8
        xor     al, al
        rep     stosb
        call    apply_report
        call    st_read
        jc      short st_rel_ok
        jmp     near st_extra
st_rel_ok:
        mov     dx, msg_t_three
        call    puts

        ; --- 4: a mouse report through apply_mouse into the INT 33h
        ; state.  The scaling is the part worth checking: at the default 8
        ; mickeys per 8 units X moves one for one, and at 16 for Y it moves
        ; half as far, which is what makes a mouse feel square on a screen
        ; that is 640 wide and 200 tall.  The cursor is forced hidden
        ; first, so nothing is painted into video memory during a test.
        ; The speed multiplier is 16 by default, and every expected value
        ; below is the UNSCALED arithmetic -- 8 mickeys, 8 units.  Set it
        ; aside for the duration so these check the scaling itself rather
        ; than the setting, and put it back before going resident.
        mov     ax, [gain]
        mov     [st_savegain], ax
        mov     word [gain], 1

        mov     word [vis], -1
        mov     byte [drawn], 0
        mov     word [ev_seg], 0
        mov     word [cur_x], 320
        mov     word [cur_y], 100
        mov     word [frac_x], 0
        mov     word [frac_y], 0
        mov     word [m8_x], 8
        mov     word [m8_y], 16
        mov     word [buttons], 0
        mov     word [press_n], 0
        mov     word [rel_n], 0

        mov     byte [mrep_buf], 0       ; no buttons
        mov     byte [mrep_buf + 1], 8   ; +8 mickeys of X
        mov     byte [mrep_buf + 2], 8   ; +8 mickeys of Y
        call    apply_mouse
        cmp     word [cur_x], 328
        je      short st_m1
        jmp     near st_mbad
st_m1:
        cmp     word [cur_y], 104
        je      short st_m2
        jmp     near st_mbad
st_m2:
        mov     dx, msg_t_four
        call    puts

        ; --- 5: a button down and back up, through the edge detector that
        ; functions 05h and 06h read.  A driver that tracks the bitmap but
        ; loses the edges reports a mouse that moves and never clicks,
        ; which is a fault CH375Mouse actually shipped once.
        mov     byte [mrep_buf], 1
        mov     byte [mrep_buf + 1], 0
        mov     byte [mrep_buf + 2], 0
        call    apply_mouse
        cmp     word [buttons], 1
        je      short st_m3
        jmp     near st_mbad
st_m3:
        cmp     word [press_n], 1
        je      short st_m4
        jmp     near st_mbad
st_m4:
        mov     byte [mrep_buf], 0
        call    apply_mouse
        cmp     word [buttons], 0
        je      short st_m5
        jmp     near st_mbad
st_m5:
        cmp     word [rel_n], 1
        je      short st_m6
        jmp     near st_mbad
st_m6:
        mov     dx, msg_t_five
        call    puts

        ; --- 6: packet parsing, in both of the modes it has.  This is
        ; the only part of the driver that exists because of one specific
        ; adapter, so it is the part most likely to rot unnoticed -- and
        ; the two modes disagree about the same five bytes, which is
        ; exactly the kind of thing a test has to pin down.
        ;
        ; mou_boot = 0: the device never agreed to boot protocol, so a
        ; 5-byte packet is a report-ID packet and gets read as one.
        ; mou_boot = 1: it did agree, so a 5-byte packet cannot have come
        ; from it and is thrown away.
        push    ax
        mov     al, [mou_boot]
        mov     [st_saveboot], al
        pop     ax

        mov     byte [mou_boot], 0       ; --- report-ID mode
        mov     byte [mwire_buf], 1      ; report ID 1
        mov     byte [mwire_buf + 1], 0  ; buttons: none
        mov     byte [mwire_buf + 2], 8  ; dx
        mov     byte [mwire_buf + 3], 0  ; dy
        mov     byte [mwire_buf + 4], 0  ; wheel
        mov     byte [mrep_buf], 0xEE    ; poison, so a stripper that copies
        mov     byte [mrep_buf + 1], 0xEE ; nothing is caught rather than
        mov     byte [mrep_buf + 2], 0xEE ; passing on stale data
        mov     bl, 5
        call    mou_strip_id
        jnc     short st_m7
        jmp     near st_mbad
st_m7:
        cmp     byte [mrep_buf], 0       ; the ID must not read as buttons
        je      short st_m8
        jmp     near st_mbad
st_m8:
        cmp     byte [mrep_buf + 1], 8   ; and X must have come from byte 2
        je      short st_m9
        jmp     near st_mbad
st_m9:
        mov     byte [mwire_buf], 2      ; system control, not the pointer
        mov     bl, 5
        call    mou_strip_id
        jc      short st_m9b
        jmp     near st_mbad
st_m9b:
        ; a boot-shaped 3-byte packet passes through untouched in either
        ; mode, and it is the shape a real report has once the device has
        ; agreed to boot protocol
        mov     byte [mwire_buf], 4      ; buttons, not an ID
        mov     byte [mwire_buf + 1], 9
        mov     byte [mwire_buf + 2], 7
        mov     bl, 3
        call    mou_strip_id
        jnc     short st_m10
        jmp     near st_mbad
st_m10:
        cmp     byte [mrep_buf], 4
        je      short st_m10b
        jmp     near st_mbad
st_m10b:
        cmp     byte [mrep_buf + 1], 9
        je      short st_m10c
        jmp     near st_mbad
st_m10c:
        ; A report-ID packet must be read the same way whether or not the
        ; device claimed to have switched to boot protocol.  This adapter
        ; acknowledges SET_PROTOCOL 0 and then sends report IDs anyway, so
        ; a driver that believed the acknowledgement would throw away every
        ; real packet -- which is exactly what an earlier build did.  See
        ; the note above mou_strip_id.
        mov     byte [mou_boot], 1
        mov     byte [mwire_buf], 1      ; report ID 1
        mov     byte [mwire_buf + 1], 2  ; right button down
        mov     byte [mwire_buf + 2], 0xF8   ; X = -8
        mov     byte [mwire_buf + 3], 3      ; Y = +3
        mov     byte [mwire_buf + 4], 0
        mov     bl, 5
        call    mou_strip_id
        jnc     short st_m10d
        jmp     near st_mbad
st_m10d:
        cmp     byte [mrep_buf], 2       ; buttons, not the ID
        je      short st_m10e
        jmp     near st_mbad
st_m10e:
        cmp     byte [mrep_buf + 1], 0xF8
        je      short st_m10f
        jmp     near st_mbad
st_m10f:
        cmp     byte [mrep_buf + 2], 3
        je      short st_m11
        jmp     near st_mbad
st_m11:
        mov     al, [st_saveboot]
        mov     [mou_boot], al
        mov     ax, [st_savegain]
        mov     [gain], ax
        mov     dx, msg_t_six
        call    puts
        mov     dx, msg_t_seven
        call    puts

        mov     dx, msg_t_pass
        call    puts
        jmp     near quit
st_mbad:
        mov     dx, msg_t_mfail
        call    puts
        mov     al, 1
        jmp     near die_now
st_extra:
        mov     dx, msg_t_spare
        call    puts
        mov     al, 1
        jmp     near die_now
st_wrong:
        push    ax
        mov     dx, msg_t_wrong
        call    puts
        pop     ax
        push    ax
        mov     al, ah
        call    puthex
        pop     ax
        call    puthex
        call    crlf
        mov     al, 1
        jmp     near die_now
st_nokey:
        mov     dx, msg_t_none
        call    puts
        mov     al, 1
        jmp     near die_now
init_notest:
        jmp     short init_hook

; NOTE ON THE SHAPE BELOW.  Each check reads as three lines rather than one
; because the 8086 has no near conditional jump and this routine is longer
; than a short one reaches: the test is inverted over an unconditional near
; jump.  It is not stylistic.
; One key from the BIOS buffer, or CF set if the buffer is empty.
st_read:
        mov     ah, 1
        int     0x16
        jnz     short st_read_have
        stc
        ret
st_read_have:
        mov     ah, 0
        int     0x16
        clc
        ret

init_hook:
        ; /K: make sure a controller actually answers before promising to
        ; inject through it.  If it does not, fall back to the BIOS buffer
        ; and say so, rather than silently delivering nothing.
        cmp     byte [op_kbc], 0
        je      short ih_nokbc
        mov     cx, 0x1000
ih_kbcw:
        in      al, 0x64
        cmp     al, 0xFF
        je      short ih_kbcbad
        test    al, 0x02
        je      short ih_kbcok
        loop    ih_kbcw
ih_kbcbad:
        mov     byte [op_kbc], 0
        mov     dx, msg_nokbc
        call    puts
        jmp     short ih_nokbc
ih_kbcok:
        mov     dx, msg_kbc
        call    puts
ih_nokbc:

        ; Adopt the BIOS's lock state before touching anything, so the
        ; driver starts out agreeing with the machine it just joined.
        call    adopt_locks

        ; 40:96 bit 4 may well already be set -- this BIOS sets it -- in
        ; which case /E has nothing to do and, more to the point, unloading
        ; must not clear a bit that was never ours.
        cmp     byte [op_enh], 0
        je      short ih_noenh
        push    ds
        mov     ax, 0x40
        mov     ds, ax
        mov     al, [0x96]
        pop     ds
        test    al, 0x10
        jne     short ih_noenh           ; already set; not ours to undo
        mov     byte [own_enh], 1
ih_noenh:

        ; Take INT 08h and speed the PIT up.  From here on the driver is
        ; live, so nothing above may fail.
        mov     al, [tick_n]
        mov     [tick_c], al
        mov     byte [retry_c], 1

        cli
        cmp     byte [op_hook], 0
        je      short ih_no16
        mov     ax, 0x3516
        int     0x21
        mov     [old16], bx
        mov     [old16 + 2], es
        mov     dx, int16
        mov     ax, 0x2516
        int     0x21
ih_no16:
        ; INT 33h, but only when there is a mouse to answer for.  Hooking
        ; it with no mouse present makes function 00h report a pointing
        ; device that never moves, and an application that believes in a
        ; dead mouse is worse off than one that finds none at all -- it
        ; will hide its keyboard fallback.  /F hooks anyway, because /F
        ; means one is expected to turn up.
        cmp     byte [mlive], 0
        jne     short ih_do33
        cmp     byte [op_force], 0
        je      short ih_no33
ih_do33:
        mov     ax, 0x3533
        int     0x21
        mov     [old33], bx
        mov     [old33 + 2], es
        mov     dx, int33
        mov     ax, 0x2533
        int     0x21
        mov     byte [has33], 1
ih_no33:
        ; INT 15h, INT 11h and INT 74h, so a Windows 3.x mouse driver can
        ; find a pointing device.  Taken before INT 08h and the PIT speed-up
        ; so that nothing can arrive half-installed.
        cmp     byte [op_ps2], 0
        je      short ih_nops2
        cmp     byte [mlive], 0
        jne     short ih_dops2
        cmp     byte [op_force], 0
        je      short ih_nops2           ; no mouse: do not claim to be one
ih_dops2:
        test    byte [op_ps2], 1
        je      short ih_no15
        mov     ax, 0x3515
        int     0x21
        mov     [old15], bx
        mov     [old15 + 2], es
        mov     ax, 0x2515
        mov     dx, int15
        int     0x21
        mov     dx, msg_v15
        call    puts
ih_no15:
        test    byte [op_ps2], 2
        je      short ih_no11
        mov     ax, 0x3511
        int     0x21
        mov     [old11], bx
        mov     [old11 + 2], es
        mov     ax, 0x2511
        mov     dx, int11
        int     0x21
        mov     dx, msg_v11
        call    puts
ih_no11:
        test    byte [op_ps2], 4
        je      short ih_no74
        mov     ax, 0x3574
        int     0x21
        mov     [old74], bx
        mov     [old74 + 2], es
        mov     ax, 0x2574
        mov     dx, int74
        int     0x21
        mov     dx, msg_v74
        call    puts
ih_no74:
        mov     byte [ps2_on], 1
        mov     dx, msg_ps2
        call    puts
ih_nops2:
        mov     ax, 0x3508
        int     0x21
        mov     [old08], bx
        mov     [old08 + 2], es
        mov     dx, int08
        mov     ax, 0x2508
        int     0x21
        call    pit_fast
        sti

        ; /X=hh -- behave as though usage hh were held down from now on.
        ; The typematic path then injects it forever, through whichever
        ; delivery mode is in force.  It is the only way to test delivery
        ; into a real interactive program without a hand on the keyboard,
        ; and holding a key down is exactly what it imitates.
        cmp     byte [op_hold], 0
        je      short init_nohold
        mov     al, [op_hold]
        mov     [rep_key], al
        mov     byte [rep_mods], 0
        mov     ax, [rep_delay]
        mov     [rep_cnt], ax
        ; Bounded, and it has to be.  An unbounded pretend-key floods
        ; whatever is running -- the first version fed Down keys into
        ; COMMAND.COM and wedged the batch file that had launched the test.
        mov     word [hold_n], 64
        mov     dx, msg_hold
        call    puts
init_nohold:

        mov     dx, msg_ok
        call    puts

        ; Go resident.
        ;
        ; Normally everything above resident_end goes back to DOS.  But /F
        ; keeps looking for a device from inside the timer interrupt, and
        ; the code that does the looking -- bringup, parse_config, and the
        ; 128-byte cfg_buf they parse into -- lives ABOVE resident_end, in
        ; the memory DOS is about to hand to the next program that asks for
        ; some.  It works right up until something else is loaded and uses
        ; that memory, at which point a hot-plug retry runs over whatever
        ; is there now, from inside an interrupt, on a machine with no
        ; memory protection.
        ;
        ; USBKBD 1.7.1 has exactly this bug and this is where it would be
        ; fixed.  Keeping the whole image costs about four more kilobytes,
        ; so it is kept only when /F asks for it and nobody who does not
        ; use /F pays for it.
        mov     dx, resident_end
        cmp     byte [op_force], 0
        je      short ih_keepsz
        mov     dx, image_end
ih_keepsz:
        add     dx, 15
        mov     cl, 4
        shr     dx, cl
        mov     ax, 0x3100
        int     0x21

; --------------------------------------------------------------------------
; Walk the INT 08h chain looking for our signature.  res_seg is left zero
; if there is no resident copy.
; --------------------------------------------------------------------------
find_resident:
        call    find_by_seg
        ret

; Look at the segment INT 08h currently points into and compare the eight
; signature bytes at the fixed offset.  A copy of this program is the only
; thing that can match.
find_by_seg:
        push    ds
        push    es
        push    si
        push    di
        push    cx
        mov     ax, 0x3508
        int     0x21
        mov     ax, es
        or      ax, ax
        je      short fbs_no
        mov     ds, ax
        push    cs
        pop     es
        mov     si, signature
        mov     di, signature
        mov     cx, 8
        repe    cmpsb
        jne     short fbs_no
        mov     ax, ds
        pop     cx
        pop     di
        pop     si
        pop     es
        pop     ds
        mov     [res_seg], ax
        ret
fbs_no:
        pop     cx
        pop     di
        pop     si
        pop     es
        pop     ds
        mov     word [res_seg], 0
        ret

putdecw_al:
        push    ax
        xor     ah, ah
        call    putdecw
        pop     ax
        ret

; --------------------------------------------------------------------------
; Compare the resident copy's version string with our own.  CF set if they
; differ.
;
; This matters more than it looks.  /S and /U reach into the resident copy
; using THIS binary's symbol offsets, so the two images have to have the
; same layout -- and adding one byte of resident data anywhere above them
; moves everything below.  Unloading a mismatched copy would read the saved
; interrupt vector from the wrong address and restore garbage, and the
; machine would die on the next timer tick, some time after the command
; that caused it had returned.  Refusing is the only safe answer, and the
; version string is the one thing whose address is fixed by contract.
;
; /U still works across builds, because it takes the vector out of the
; published pointer block instead of a symbol -- but the check stays, since
; every other field it prints would still be read from the wrong place.
; --------------------------------------------------------------------------
version_match:
        push    ax
        push    cx
        push    si
        push    di
        push    ds
        push    es
        mov     ds, [cs:res_seg]
        push    cs
        pop     es
        mov     si, ver_str
        mov     di, ver_str
        mov     cx, 8
vm_loop:
        mov     al, [si]
        cmp     al, [es:di]
        jne     short vm_bad
        cmp     al, '$'
        je      short vm_good
        inc     si
        inc     di
        loop    vm_loop
vm_good:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     cx
        pop     ax
        clc
        ret
vm_bad:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     cx
        pop     ax
        stc
        ret

; Print "resident is X, this is Y" and give up.
say_mismatch:
        mov     dx, msg_mismatch
        call    puts
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, ver_str
        call    puts
        pop     ds
        mov     dx, msg_mismatch2
        call    puts
        mov     dx, ver_str
        call    puts
        mov     dx, msg_mismatch3
        call    puts
        ret

; --------------------------------------------------------------------------
; /S
; --------------------------------------------------------------------------
do_status:
        cmp     word [res_seg], 0
        jne     short stat_have
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     near die_now
stat_have:
        call    version_match
        jnc     short stat_ok
        call    say_mismatch
        mov     al, 3
        jmp     near die_now
stat_ok:
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, msg_isres
        push    cs
        pop     ds
        call    puts
        mov     ds, [cs:res_seg]
        mov     dx, ver_str
        call    puts
        push    cs
        pop     ds
        mov     dx, msg_isres2
        call    puts
        ; The I/O base the RESIDENT copy is using -- read out of its image,
        ; not this program's default.  Without it there is no way to
        ; confirm which address a driver loaded with @nnn actually took,
        ; which is exactly when you want to know.
        mov     dx, msg_s_base
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [io_dat]
        push    cs
        pop     ds
        push    ax
        mov     al, ah                   ; no puthexw here: two byte prints
        call    puthex
        pop     ax
        call    puthex
        mov     dx, msg_s_baseh
        call    puts
        mov     dx, msg_khalf
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [live]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf


        mov     dx, msg_s_ep
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [ep_in]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_poll
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_polls]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_rep
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_reports]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_keys
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_keys]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_full
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_full]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_tmo
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_tmo]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_replen
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [n_replen]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_flush
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_flush]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_khz
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [tick_n]
        push    cs
        pop     ds
        xor     ah, ah
        mov     bx, 182
        mul     bx
        mov     bx, 10
        xor     dx, dx
        div     bx
        call    putdecw
        call    crlf

        mov     dx, msg_s_rate
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [tick_n]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_lock
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [locks]
        push    cs
        pop     ds
        call    puthex
        call    crlf

        mov     dx, msg_s_enh
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [op_enh]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_wake
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [ps2_on]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_hook
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [op_hook]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_ring
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_ring]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_kbc
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [op_kbc]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_kbcbad
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [n_kbcbad]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        ; --- the mouse half.  Two separate poll counters matter here: a
        ; keyboard that is silent and a mouse that is silent look identical
        ; from one number, and the commonest real fault on this adapter is
        ; one interface enumerating and the other not.
        mov     dx, msg_s_mhead
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mlive]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mep
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mep_in]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mpoll
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_polls]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mpolls2
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_tmo]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mrep
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_reports]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mid
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mou_id]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mlen
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mrep_len]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mbtn
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mbtn_seen]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mshort
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_short]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mboot
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mou_boot]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mbogus
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_bogus]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mdiv
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [mou_div]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        mov     dx, msg_s_mgain
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [gain]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        ; The rate in Hz, worked out rather than left as a divisor -- the
        ; divisor is what the PIT wants and Hz is what anyone reading this
        ; actually wants to know.  18.2 Hz per unit, done as *182/10.
        mov     dx, msg_s_mhz
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [tick_n]
        mov     bl, [mou_div]
        push    cs
        pop     ds
        xor     ah, ah
        xor     bh, bh
        push    bx
        mov     bx, 182
        mul     bx                       ; AX = tick_n * 182
        pop     bx
        xor     dx, dx
        div     bx                       ; / mou_div
        mov     bx, 10
        xor     dx, dx
        div     bx                       ; / 10  -> Hz
        call    putdecw
        call    crlf

        mov     dx, msg_s_mdup
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_dup]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mzero
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_zero]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mign
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [m_ignored]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mx
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [cur_x]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_my
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [cur_y]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_mb
        call    puts
        mov     ds, [cs:res_seg]
        mov     ax, [buttons]
        push    cs
        pop     ds
        call    putdecw
        call    crlf

        mov     dx, msg_s_m33
        call    puts
        mov     ds, [cs:res_seg]
        mov     al, [has33]
        push    cs
        pop     ds
        call    putdecw_al
        call    crlf

        pop     ds
        jmp     near quit

; --------------------------------------------------------------------------
; /U
; --------------------------------------------------------------------------
do_unload:
        cmp     word [res_seg], 0
        jne     short unload_ok
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     near die_now
unload_ok:
        call    version_match
        jnc     short unload_ver_ok
        call    say_mismatch
        mov     al, 3
        jmp     near die_now
unload_ver_ok:
        ; Whether the 101-key bit was ours to clear is recorded in the
        ; RESIDENT copy, so it has to be fetched before we let go of it.
        push    ds
        mov     ds, [cs:res_seg]
        mov     al, [own_enh]
        push    cs
        pop     ds
        mov     [res_seg_enh], al
        pop     ds

        ; INT 08h must still point at the resident copy, or something else
        ; hooked it afterwards and unhooking would strand that handler.
        mov     ax, 0x3508
        int     0x21
        mov     ax, es
        cmp     ax, [res_seg]
        je      short unload_go
        mov     dx, msg_hooked
        call    puts
        mov     al, 2
        jmp     near die_now
unload_go:
        ; The saved vector is read through the pointer block at 012F rather
        ; than through our own old08 symbol, so an image whose data moved
        ; is still unhooked correctly rather than catastrophically.
        cli
        push    ds
        mov     ds, [cs:res_seg]
        mov     bx, [0x012F]             ; where the resident copy keeps it
        mov     dx, [bx]
        mov     ax, [bx + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2508
        int     0x21
        pop     ds
        call    pit_slow

        ; Give INT 16h back, if we took it.  Refusing when somebody hooked
        ; it after us is the same rule as for INT 08h: unhooking then would
        ; strand that handler.
        push    ds
        mov     ds, [cs:res_seg]
        mov     al, [op_hook]
        push    cs
        pop     ds
        mov     [res_hook], al
        pop     ds
        cmp     byte [res_hook], 0
        je      short ul_no16
        mov     ax, 0x3516
        int     0x21
        mov     ax, es
        cmp     ax, [res_seg]
        jne     short ul_no16            ; not ours any more; leave it
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, [old16]
        mov     ax, [old16 + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2516
        int     0x21
        pop     ds
ul_no16:
        ; INT 33h back, on the same terms as INT 16h: only if we took it,
        ; and only if it is still ours.  Both are read out of the RESIDENT
        ; copy, and the vector itself through the published pointer at
        ; 0133, so an image whose data moved is still unhooked correctly
        ; rather than catastrophically.
        push    ds
        mov     ds, [cs:res_seg]
        mov     al, [has33]
        push    cs
        pop     ds
        mov     [res_h33], al
        pop     ds
        cmp     byte [res_h33], 0
        je      short ul_no33
        mov     ax, 0x3533
        int     0x21
        mov     ax, es
        cmp     ax, [res_seg]
        jne     short ul_no33            ; not ours any more; leave it
        push    ds
        mov     ds, [cs:res_seg]
        mov     bx, [0x0133]
        mov     dx, [bx]
        mov     ax, [bx + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2533
        int     0x21
        pop     ds
ul_no33:
        ; INT 15h, INT 11h and INT 74h, if /W took them.  Read out of the
        ; RESIDENT copy, like everything else here.
        push    ds
        mov     ds, [cs:res_seg]
        mov     al, [ps2_on]
        push    cs
        pop     ds
        mov     [res_ps2], al
        pop     ds
        cmp     byte [res_ps2], 0
        je      short ul_nops2
        push    ds
        mov     ds, [cs:res_seg]
        mov     al, [op_ps2]
        push    cs
        pop     ds
        mov     [res_ps2m], al
        pop     ds
        test    byte [res_ps2m], 1
        je      short ul_no15
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, [old15]
        mov     ax, [old15 + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2515
        int     0x21
        pop     ds
ul_no15:
        test    byte [res_ps2m], 2
        je      short ul_no11
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, [old11]
        mov     ax, [old11 + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2511
        int     0x21
        pop     ds
ul_no11:
        test    byte [res_ps2m], 4
        je      short ul_nops2
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, [old74]
        mov     ax, [old74 + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2574
        int     0x21
        pop     ds
ul_nops2:

        ; Hand the keyboard state back in a condition the BIOS can use.
        ; No key is held once we are gone, so every modifier bit we own
        ; must be clear -- a stuck Ctrl or Alt bit left behind turns every
        ; subsequent keystroke on the machine's other keyboard into a
        ; control sequence, which looks exactly like a dead keyboard.  The
        ; lock bits are deliberately left as they are: the user may have
        ; toggled them from the USB keyboard and they belong to the BIOS.
        push    ds
        push    bx
        mov     ax, 0x40
        mov     ds, ax
        and     byte [0x17], 0xF0        ; drop shift, ctrl, alt
        and     byte [0x18], 0xFC        ; drop left ctrl, left alt
        mov     bl, [0x96]
        and     bl, 0xF3                 ; drop right ctrl, right alt
        mov     al, [cs:res_seg_enh]
        or      al, al
        je      short ul_keepenh
        and     bl, 0xEF                 ; and the 101-key bit, if it was ours
ul_keepenh:
        mov     [0x96], bl
        pop     bx
        pop     ds
        sti

        ; Release the resident copy's memory: its environment block first,
        ; then the block itself.
        push    es
        mov     es, [res_seg]
        mov     ax, [es:0x2C]
        or      ax, ax
        je      short unload_noenv
        push    es
        mov     es, ax
        mov     ah, 0x49
        int     0x21
        pop     es
unload_noenv:
        mov     ah, 0x49
        int     0x21
        pop     es

        mov     dx, msg_unloaded
        call    puts
        jmp     near quit

; ==========================================================================
; COMMAND LINE
; ==========================================================================

parse_args:
        mov     si, 0x81
        mov     cl, [0x80]
        xor     ch, ch
        jcxz    pa_done
pa_loop:
        lodsb
        dec     cx
        cmp     al, ' '
        je      short pa_more
        cmp     al, 9
        je      short pa_more
        cmp     al, '@'
        je      short pa_j_base
        cmp     al, '/'
        je      short pa_slash
        cmp     al, '-'
        je      short pa_slash
        jmp     short pa_more
pa_j_base:
        jmp     near pa_base
pa_more:
        jcxz    pa_done
        jmp     short pa_loop
pa_done:
        ret

pa_slash:
        jcxz    pa_done
        lodsb
        dec     cx
        ; '?' HAS TO BE TESTED BEFORE THE UPPER-CASING, and this is why /?
        ; never worked -- in this driver or in USBKBD, which has the same
        ; parser.  AND 0xDF folds lower case to upper by clearing bit 5,
        ; which is fine for letters and wrong for everything else: it turns
        ; '?' (3Fh) into 1Fh, so the comparison further down could never
        ; match.  The switch was simply ignored and the driver loaded.
        cmp     al, '?'
        jne     short pa_notq
        mov     byte [op_help], 1
        jmp     near pa_more
pa_notq:
        and     al, 0xDF                 ; upper case -- letters only
        cmp     al, 'U'
        jne     short pa_s2
        mov     byte [op_unload], 1
        jmp     short pa_more
pa_s2:
        cmp     al, 'S'
        jne     short pa_s3
        mov     byte [op_status], 1
        jmp     short pa_more
pa_s3:
        cmp     al, 'F'
        jne     short pa_s4
        mov     byte [op_force], 1
        jmp     short pa_more
pa_s4:
        cmp     al, 'V'
        jne     short pa_s5
        mov     byte [op_verb], 1
        jmp     short pa_more
pa_s5:
        cmp     al, 'N'
        jne     short pa_s6
        ; /N on its own turns the lock LEDs off; /NK and /NM turn a whole
        ; half of the driver off.  They are told apart by the next
        ; character, which is consumed only if it is one of those two --
        ; so /N /NK and /NKEYBOARD all still mean what they look like.
        jcxz    pa_n_leds
        mov     ah, [si]
        and     ah, 0xDF                 ; upper case
        cmp     ah, 'K'
        jne     short pa_n_mou
        inc     si
        dec     cx
        mov     byte [op_nokbd], 1
        jmp     short pa_more
pa_n_mou:
        cmp     ah, 'M'
        jne     short pa_n_leds
        inc     si
        dec     cx
        mov     byte [op_nomou], 1
        jmp     short pa_more
pa_n_leds:
        mov     byte [op_leds], 0
        jmp     short pa_more
; A second trampoline to pa_more.  The option chain has grown past what one
; short jump at the far end can reach, and the 8086 has no near conditional
; jump to widen -- so the reach is shortened instead.  Nothing falls into
; this label: the instruction above it is an unconditional jump.
pa_more_t0:
        jmp     near pa_more
pa_s6:
        cmp     al, 'H'
        jne     short pa_s6h
        mov     byte [op_hook], 1
        jmp     short pa_more_t0
pa_s6h:
        cmp     al, 'W'
        jne     short pa_s6w
        ; /W now means what it means in USBMOUSE: the PS/2 BIOS emulation
        ; that lets Windows 3.x find the pointer.  In CH375Keyboard it was
        ; the withdrawn INT 09h wake, which was accepted and ignored, so
        ; nothing depended on the old meaning.
        ; /W alone takes all three vectors; /W=n takes a subset, as a
        ; bitmask -- 1 = INT 15h, 2 = INT 11h, 4 = INT 74h.  The mask
        ; exists because loading /W rebooted the machine and the fastest
        ; way to find out which hook did it is to take them one at a time.
        mov     byte [op_ps2], 7
        jcxz    pa_more_t0
        cmp     byte [si], '='
        jne     short pa_more_t0
        call    pa_number
        or      ax, ax
        je      short pa_more_t0
        cmp     ax, 7
        ja      short pa_more_t0
        mov     [op_ps2], al
        jmp     short pa_more_t0         ; the nearer trampoline; pa_more_t
pa_s6w:                                  ; is out of short reach from here
        cmp     al, 'X'
        jne     short pa_s6x
        call    pa_hexnum
        mov     [op_hold], al
        jmp     short pa_more_t0
pa_s6x:
        cmp     al, 'T'
        jne     short pa_s6t
        ; /T on its own is the self-test; /T=n is the typematic period, so
        ; the two are told apart by whether an '=' follows.
        cmp     cx, 0
        je      short pa_s6_selftest
        cmp     byte [si], '='
        je      short pa_s6t
pa_s6_selftest:
        mov     byte [op_test], 1
        jmp     short pa_more_t
pa_s6t:
        cmp     al, 'Y'
        jne     short pa_s6y
        call    pa_number
        mov     [hid_idle], al
        jmp     short pa_more_t
pa_s6y:
        cmp     al, 'K'
        jne     short pa_s6k
        mov     byte [op_kbc], 1
        jmp     short pa_more_t
pa_s6k:
        cmp     al, 'E'
        jne     short pa_s6e
        mov     byte [op_enh], 1
        jmp     short pa_more_t
pa_s6e:
        cmp     al, 'C'
        jne     short pa_s6c
        mov     byte [op_noboot], 1
        jmp     short pa_more_t
pa_s6c:
        cmp     al, 'Q'
        jne     short pa_s6q
        mov     byte [op_noflush], 1
        jmp     short pa_more_t
pa_s6q:
        cmp     al, 'M'
        jne     short pa_s6g
        call    pa_number
        or      ax, ax
        je      short pa_more_t
        cmp     ax, 16
        ja      short pa_more_t
        mov     [mou_div], al
        mov     [mou_cnt], al
        jmp     short pa_more_t
pa_s6g:
        cmp     al, 'G'
        jne     short pa_s6b
        call    pa_number
        or      ax, ax
        je      short pa_more_t
        cmp     ax, 256
        ja      short pa_more_t
        mov     [gain], ax
        jmp     short pa_more_t
pa_s6b:                                  ; '?' is handled up at pa_slash,
pa_s7:                                   ; before the upper-casing
        jmp     short pa_s8
pa_more_t:
        jmp     near pa_more
pa_s8:
        cmp     al, 'R'
        jne     short pa_s9
        call    pa_number
        or      ax, ax
        je      short pa_more_t
        cmp     ax, 16
        ja      short pa_more_t
        mov     [tick_n], al
        jmp     short pa_more_t
pa_s9:
        cmp     al, 'D'
        jne     short pa_s10
        call    pa_number
        or      ax, ax
        je      short pa_more_t
        mov     [rep_delay], ax
        jmp     short pa_more_t
pa_s10:
        cmp     al, 'T'
        jne     short pa_more_t
        call    pa_number
        or      ax, ax
        je      short pa_more_t
        mov     [rep_rate], ax
        jmp     short pa_more_t

; Read "=hh" in hex from SI, CX remaining.  Returns AL.
pa_hexnum:
        xor     bx, bx
        jcxz    pa_hx_out
        cmp     byte [si], '='
        jne     short pa_hx_out
        inc     si
        dec     cx
pa_hx_d:
        jcxz    pa_hx_out
        mov     al, [si]
        call    hexval
        jc      short pa_hx_out
        inc     si
        dec     cx
        push    cx
        mov     cl, 4
        shl     bl, cl
        pop     cx
        or      bl, al
        jmp     short pa_hx_d
pa_hx_out:
        mov     al, bl
        ret

; Read "=nnn" in decimal from SI, CX remaining.  Returns AX, 0 if none.
pa_number:
        xor     ax, ax
        jcxz    pa_num_out
        cmp     byte [si], '='
        jne     short pa_num_out
        inc     si
        dec     cx
        xor     ax, ax
pa_num_d:
        jcxz    pa_num_out
        mov     bl, [si]
        cmp     bl, '0'
        jb      short pa_num_out
        cmp     bl, '9'
        ja      short pa_num_out
        inc     si
        dec     cx
        sub     bl, '0'
        mov     bh, 0
        push    dx
        mov     dx, 10
        push    bx
        mul     dx
        pop     bx
        pop     dx
        add     ax, bx
        jmp     short pa_num_d
pa_num_out:
        ret

; "@nnn" -- the I/O base, in hex.
pa_base:
        xor     bx, bx
pa_base_d:
        jcxz    pa_base_set
        mov     al, [si]
        call    hexval
        jc      short pa_base_set
        inc     si
        dec     cx
        push    cx
        mov     cl, 4
        shl     bx, cl
        pop     cx
        xor     ah, ah
        add     bx, ax
        jmp     short pa_base_d
pa_base_set:
        or      bx, bx
        je      short pa_base_out
        mov     [io_dat], bx
        inc     bx
        mov     [io_cmd], bx
pa_base_out:
        jmp     near pa_more

hexval:                                  ; AL char -> AL value, CF on error
        cmp     al, '0'
        jb      short hv_bad
        cmp     al, '9'
        ja      short hv_a
        sub     al, '0'
        clc
        ret
hv_a:
        and     al, 0xDF
        cmp     al, 'A'
        jb      short hv_bad
        cmp     al, 'F'
        ja      short hv_bad
        sub     al, 'A' - 10
        clc
        ret
hv_bad:
        stc
        ret

die_now:
        mov     ah, 0x4C
        int     0x21

quit:
        mov     ax, 0x4C00
        int     0x21

; ==========================================================================
; TRANSIENT DATA
; ==========================================================================

op_unload:  db  0
op_status:  db  0
op_force:   db  0
op_verb:    db  0
op_help:    db  0
ic_ver:     db  0
last_st:    db  0
cfg_len:    db  0
in_kbd:     db  0
got_if:     db  0
got_ep:     db  0
in_mou:     db  0
mgot_if:    db  0
mgot_ep:    db  0
res_seg:    dw  0
res_seg_enh: db 0                ; own_enh, read out of the resident copy
res_hook:    db 0                ; op_hook, likewise
res_h33:     db 0                ; has33, likewise
res_ps2:     db 0                ; ps2_on, likewise
res_ps2m:    db 0                ; op_ps2, the /W=n mask
bu_err:     dw  0

desc_buf:   times 64 db 0
cfg_buf:    times 128 db 0

msg_prog:      db 'USBCOMBO $'
msg_by:        db ' -- StevenC & Claude', 13, 10, '$'
msg_v15:       db '  hooked INT 15h', 13, 10, '$'
msg_v11:       db '  hooked INT 11h', 13, 10, '$'
msg_v74:       db '  hooked INT 74h', 13, 10, '$'
msg_ps2:       db 'PS/2 BIOS emulation on: Windows 3.x will find a mouse.'
               db 13, 10, '$'
msg_ok:        db 'USBCOMBO resident.  Keys to the BIOS buffer, mouse on'
               db ' INT 33h.', 13, 10, '$'
msg_found:     db 'Keyboard: endpoint $'
msg_mfound:    db 'Mouse   : endpoint $'
msg_iface:     db ', HID interface $'
msg_vidpid:    db 'Device VID/PID $'
msg_lowspd:    db 'Low-speed device; USB bus set to 1.5 Mbps.', 13, 10, '$'
msg_already:   db 'USBCOMBO is already loaded.  /U unloads it.', 13, 10, '$'
msg_isres:     db 'Loaded: USBCOMBO $'
msg_isres2:    db '.', 13, 10, '$'
msg_khalf:     db 'Keyboard half:', 13, 10, '  live=$'
msg_s_base:    db '  I/O base=$'
msg_s_baseh:   db 'h  (data, command+1)', 13, 10, '$'
msg_s_ep:      db '  endpoint=$'
msg_s_poll:    db '  polls=$'
msg_s_rep:     db '  reports=$'
msg_s_keys:    db '  keys delivered=$'
msg_s_full:    db '  keys dropped (buffer full)=$'
msg_s_khz:     db '  polled at Hz=$'
msg_s_rate:    db '  timer divisor=$'
msg_s_tmo:     db '  polls that timed out=$'
msg_s_replen:  db '  last report length (8 = a keyboard report)=$'
msg_s_flush:   db '  stale interrupts flushed=$'
msg_s_mpolls2: db '  polls that timed out=$'
msg_s_lock:    db '  locks (bit0 num, 1 caps, 2 scroll)=$'
msg_s_enh:     db '  claiming a 101/102-key keyboard (/E)=$'
msg_hold:      db 'Pretending a key is held down (/X), 64 repeats then it lets'
               db ' go.', 13, 10, '$'
msg_s_wake:    db '  PS/2 BIOS emulation for Windows (/W)=$'
msg_s_hook:    db '  delivering through an INT 16h hook (/H)=$'
msg_s_ring:    db '  keys served through the hook=$'
msg_s_kbc:     db '  injecting through the 8042 (/K)=$'
msg_s_kbcbad:  db '  injections the 8042 refused=$'
msg_s_mhead:   db 'Mouse half:', 13, 10, '  live=$'
msg_s_mep:     db '  endpoint=$'
msg_s_mpoll:   db '  polls=$'
msg_s_mrep:    db '  reports=$'
msg_s_mid:     db '  reports carry a report ID=$'
msg_s_mlen:    db '  last report length=$'
msg_s_mbtn:    db '  button bits ever seen=$'
msg_s_mign:    db '  report-ID packets dropped (not the pointer)=$'
msg_s_mshort:  db '  packets too short to use=$'
msg_s_mboot:   db '  the device agreed to boot protocol=$'
msg_s_mbogus:  db '  packets rejected as unusable=$'
msg_s_mdiv:    db '  polled every nth tick (/M)=$'
msg_s_mgain:   db '  speed multiplier (/G, bigger is faster)=$'
msg_s_mhz:     db '  polled at Hz=$'
msg_s_mdup:    db '  packets identical to the one before=$'
msg_s_mzero:   db '  packets with no movement and no button=$'
msg_s_mx:      db '  x=$'
msg_s_my:      db '  y=$'
msg_s_mb:      db '  buttons=$'
msg_s_m33:     db '  INT 33h hooked=$'
msg_kbc:       db 'Injecting through the keyboard controller (8042 D2h).', 13, 10, '$'
msg_nokbc:     db 'No keyboard controller answers port 64h; /K ignored and'
               db ' the BIOS', 13, 10
               db 'buffer used instead.', 13, 10, '$'
; /S and /U both land here when nothing is resident.  The bare "not
; loaded" this used to say is true and unhelpful: the commonest way to
; see it is putting USBCOMBO /S in AUTOEXEC.BAT expecting it to LOAD the
; driver, which /S has never done.  So the message says what to run.
msg_notres:    db 'USBCOMBO is not loaded, so there is nothing to report'
               db ' on.', 13, 10
               db 'Run USBCOMBO with no switches to load it; /S then says'
               db ' what it', 13, 10
               db 'is doing and /U unloads it.', 13, 10, '$'
msg_unloaded:  db 'USBCOMBO unloaded.', 13, 10, '$'
msg_hooked:    db 'Cannot unload: something else hooked INT 08h after us.', 13, 10, '$'
msg_mismatch:  db 'The resident copy is version $'
msg_mismatch2: db ' and this one is $'
msg_mismatch3: db '.', 13, 10
               db 'Refusing: /S and /U read the resident copy at the'
               db ' offsets of', 13, 10
               db 'the build doing the reading, and these two are not the'
               db ' same', 13, 10
               db 'image.  Use the matching USBCOMBO.COM, or reboot.'
               db 13, 10, '$'
msg_nochip:    db 'No CH375 responds at that I/O address.', 13, 10, '$'
msg_oldchip:   db 'CH375 revision is older than B5; this driver needs the'
               db ' command-port ready flag.', 13, 10, '$'
msg_nodev:     db 'Nothing enumerated on the CH375.  Use /F to load anyway'
               db ' and wait.', 13, 10, '$'
msg_notkbd:    db 'That device has no HID boot keyboard or boot mouse'
               db ' interface.', 13, 10
               db 'USBINFO in CH375USBTOOLS says what it does have.'
               db 13, 10, '$'
msg_forced:    db 'Nothing found yet; loading anyway and polling for one.'
               db 13, 10, '$'
msg_laststat:  db 'Last CH375 status: $'
msg_t_start:   db 'Self-test: a key through to INT 16h, a report through to'
               db ' INT 33h.', 13, 10, '$'
msg_t_one:     db '  ok   key_down -> INT 16h gave 1E61h', 13, 10, '$'
msg_t_two:     db '  ok   a whole report through the press diff -> 1E61h', 13, 10, '$'
msg_t_three:   db '  ok   the matching release produced no key', 13, 10, '$'
msg_t_spare:   db '  FAIL -- the release produced a spurious key.', 13, 10, '$'
msg_t_four:    db '  ok   a mouse report moved the pointer 8 across, 4 down'
               db 13, 10, '$'
msg_t_five:    db '  ok   a button press and release produced both edges'
               db 13, 10, '$'
msg_t_six:     db '  ok   report 1 stripped, report 2 dropped, boot report'
               db ' kept', 13, 10, '$'
msg_t_seven:   db '  ok   a report ID is stripped even after SET_PROTOCOL'
               db ' said yes', 13, 10, '$'
st_saveboot:   db 0
st_savegain:   dw 0
msg_t_mfail:   db '  FAIL -- the mouse half did not fold a report correctly.'
               db 13, 10, '$'
msg_t_pass:    db '  PASS -- both delivery paths are intact.', 13, 10, '$'
msg_t_wrong:   db '  FAIL -- INT 16h returned $'
msg_t_none:    db '  FAIL -- nothing reached the BIOS keyboard buffer.', 13, 10, '$'
msg_t_conn:    db '  connect            : $'
msg_t_conn2:   db '  connect after reset: $'
msg_t_rate:    db '  device rate reg 07 : $'
msg_t_descr:   db '  GET_DESCR device   : $'
msg_t_proto:   db '  kbd SET_PROTOCOL   : $'
msg_t_idle:    db '  kbd SET_IDLE 0     : $'
msg_t_mproto:  db '  mou SET_PROTOCOL   : $'
msg_t_midle:   db '  mou SET_IDLE 0     : $'

; The help screen.  It has 23 lines to work with -- the banner above it
; takes one and DOS wants one for the prompt -- so everything that did not
; earn its place is in the README instead.  It is written for somebody who
; wants to use the thing, not for somebody debugging it: the first block is
; the three commands that cover almost every use, and the surprising
; behaviour (no pointer at the DOS prompt) is called out before the options
; rather than left to be discovered.
msg_help:
        db 'A USB keyboard AND mouse together, on one CH375 card.', 13, 10
        db 13, 10
        db '  USBCOMBO        load it -- that is all most people need', 13, 10
        db '  USBCOMBO /S     report what it is doing', 13, 10
        db '  USBCOMBO /U     unload it', 13, 10
        db 13, 10
        db 'Keys go into the BIOS keyboard buffer, so DOS and anything using', 13, 10
        db 'INT 16h sees them.  The mouse is INT 33h -- and there is NO pointer', 13, 10
        db 'at the DOS prompt, so a mouse that looks dead there is likely fine.', 13, 10
        db 13, 10
        db 'MOUSE  /G=n speed, default 16.  BIGGER IS FASTER, no ceiling', 13, 10
        db '       /M=n poll every nth tick, default 2', 13, 10
        db '       /NM  ignore the mouse, drive the keyboard only', 13, 10
        db 'KEYBD  /R=n poll rate 18.2*n Hz, default 16.  Lower loses keys', 13, 10
        db '       /D=n repeat delay 144  /T=n period 10  /N no lock LEDs', 13, 10
        db '       /E   claim a 101/102-key keyboard', 13, 10
        db '       /NK  ignore the keyboard, drive the mouse only', 13, 10
        db 'OTHER  @nnn CH375 I/O base in hex; /S shows the one in use', 13, 10
        db '       /F   load with nothing plugged in, and keep looking', 13, 10
        db '       /V   trace the bring-up    /T  self-test, then exit', 13, 10
        db 13, 10
        db 'Load only ONE of USBCOMBO, USBKBD, USBMOUSE: one card, one driver.'
        db 13, 10
        db "EDIT's menus ignore the keyboard (they read IRQ1); the mouse works."
        db 13, 10, '$'

; --------------------------------------------------------------------------
; The end of the image on disk.  /F keeps everything up to here resident,
; because the hot-plug retry it enables calls bringup and parses into
; cfg_buf, both of which are above resident_end.  Without /F, DOS gets
; everything above resident_end back.
; --------------------------------------------------------------------------
image_end:
