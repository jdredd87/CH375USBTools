; ==========================================================================
; USBKBD.COM -- a DOS keyboard driver fed by a USB HID keyboard attached
;               to a WCH CH375 in host mode.
;
;   Version 1.7.1                                                  StevenC & Claude
;   CH375Keyboard.  Public domain (the Unlicense).
;
; The version number is written down in exactly one place: ver_str, just
; below the signature.  It is what every message prints and what a resident
; copy carries in memory, so bumping it there is the whole job.
;
;   USBKBD [@260] [/S] [/U] [/F] [/V] [/N] [/E] [/K] [/R=n] [/D=n] [/T=n]
;       @nnn    CH375 I/O base in hex, default 260
;       /S      report status of an already-loaded copy
;       /U      unload
;       /F      install even if no keyboard enumerates, and keep looking
;       /V      trace each bring-up step and the status it returned
;       /K      inject through the keyboard controller (8042 command D2h)
;               instead of writing the BIOS buffer.  Keys then arrive as
;               real IRQ1 interrupts, which is the only way to reach a
;               program that hooks INT 09h -- DOS EDIT's menus, and most
;               games.  Needs an AT-class 8042; checked at load time
;       /W      accepted and ignored.  It used to call INT 09h to wake a
;               program that owns the keyboard interrupt; that locked the
;               machine, and the note by wake_int09 says why
;       /H      deliver keys through an INT 16h hook of our own rather
;               than by writing the BIOS keyboard buffer.  Some programs
;               -- DOS EDIT's menu bar is the known one -- take no notice
;               of a key that is merely sitting in the buffer
;       /X=hh   pretend HID usage hh is held down for ever, so delivery
;               into a real program can be tested with nobody typing.
;               04 is 'a', 51 is Down.  Bounded to 64 repeats: an
;               unbounded one floods COMMAND.COM.  A diagnostic, not a
;               setting
;       /T      self-test: drive one usage through the delivery path and
;               report what INT 16h gives back, then exit without going
;               resident.  Needs no keypress
;       /Y=n    HID idle rate in 4 ms units, default 0 = report only on
;               change.  Nonzero makes the keyboard repeat its state, so
;               the report path can be watched with nobody typing
;       /N      do not drive the lock LEDs
;       /E      claim a 101/102-key keyboard in 40:96 bit 4, so software
;               uses the enhanced INT 16h calls.  Needs a BIOS that has
;               them; an XT-class one does not
;       /R=n    timer divisor, PIT rate = 18.2 * n Hz.  Default 8 (145 Hz);
;               n must be 1..16 and the BIOS tick is still delivered at
;               18.2 Hz whatever n is
;       /D=n    typematic delay before repeat, in fast ticks.  Default 72,
;               about half a second at the default rate
;       /T=n    typematic period, in fast ticks.  Default 5, about 29/s
;
; HOW KEYS REACH DOS.  The driver writes scancode/ASCII words straight into
; the BIOS keyboard buffer at 0040:001E and moves the tail at 0040:001C,
; which is exactly what a real keyboard interrupt does.  Everything that
; reads the keyboard through INT 16h or through DOS sees them, and so does
; the shift state, which is maintained at 0040:0017 as well.
;
; WHAT IT CANNOT DRIVE.  A program that reads the keyboard controller
; itself by hooking INT 09h never looks at the BIOS buffer, so it never
; sees any of this.  That is most games.  Reaching those needs the 8042 and
; is a different, riskier program.
;
; WHY A TIMER HOOK -- DOS is not reentrant and the CH375 has no useful IRQ
; wiring on this card, so the keyboard is polled.  18.2 Hz is too slow to
; type through, so INT 08h is taken over and the PIT divided by 8; the
; original handler is still called every 8th tick, so BIOS timekeeping,
; DOS's own clock and anything else chained on INT 08h see exactly the rate
; they expect.
;
; WHY THE DRIVER HAS TO REPEAT KEYS ITSELF.  SET_IDLE 0 tells the keyboard
; to report only when something changes, which is what a driver wants --
; otherwise the endpoint floods.  But it means a held key produces exactly
; one report, and DOS expects auto-repeat.  So the repeat is generated
; here, from the fast tick, for whichever non-modifier key went down last.
;
; ASSEMBLING -- either of these produces the same image:
;       nasm -f bin usbkbd.asm -o USBKBD.COM
;       MNASMFIX -O9 -f bin -o USBKBD.COM USBKBD.ASM      (on the DOS box)
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
        db      'USBKBD01'                      ; 0103

; The version, in ASCII, ending in '$' so it can be printed as it stands.
; It is resident and sits immediately after the signature, so /S reports
; the version of the copy ALREADY LOADED rather than its own -- which is
; the interesting number when two builds are in play.
ver_str:
        db      '1.8.0$'                        ; 010B

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

; ---- saved vectors ----
old08:  dd      0

; ---- hardware ----
io_dat: dw      0x260
io_cmd: dw      0x261
ep_in:  db      0                ; interrupt IN endpoint number
ep_tog: db      0x80             ; SET_ENDP6 argument: bit 6 is the toggle
kbd_if: db      0                ; bInterfaceNumber of the keyboard
cfg_val:db      1
ep0max: db      8

; ---- timing ----
tick_n: db      8                ; PIT divisor asked for on the command line
tick_c: db      8                ; countdown to the next downstream tick
on_top: db      1                ; 1 = INT 08h still points at us
in_poll:db      0                ; reentrancy guard for the CH375
live:   db      0                ; 1 = a keyboard enumerated
low_spd:db      0                ; 1 = bus was dropped to 1.5 Mbps
retry_c:db      0                ; ticks until the next hot-plug retry

; ---- typematic ----
rep_delay: dw   72               ; fast ticks before the first repeat
rep_rate:  dw   5                ; fast ticks between repeats
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

; ---- counters, for /S ----
; n_polls counts every fast tick the poll ran on, whether or not the
; keyboard had anything to say.  n_reports cannot stand in for it: with
; SET_IDLE 0 an idle keyboard reports nothing at all, so a driver that is
; polling perfectly well shows a frozen report count.  Telling "not being
; called" from "called, nothing to report" needs both numbers.
n_polls:   dw   0
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
        ret
bp_full:
        ; The buffer holds 15 entries and DOS is not draining it.  Dropping
        ; the key is what a real keyboard does too -- the BIOS beeps, this
        ; just counts it, because a beep from inside a timer ISR on every
        ; key of a fast typist is worse than the lost key.
        pop     ds
        inc     word [cs:n_full]
        pop     dx
        pop     cx
        pop     bx
        pop     ax
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

        cmp     byte [live], 0
        jne     short pk_islive
        jmp     near pk_hotplug
pk_islive:
        inc     word [n_polls]

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
        jmp     near pk_repeat           ; no answer this tick
pk_answered:
        cmp     al, INT_SUCCESS
        je      short pk_got
        mov     [last_ist], al
        cmp     al, INT_DISCONNECT
        jne     short pk_notgone
        mov     byte [live], 0
        mov     byte [rep_key], 0
        jmp     near pk_done
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
        call    apply_report
        jmp     short pk_done

pk_repeat:
        call    do_repeat
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
        jmp     near pk_done
ph_due:
        mov     byte [retry_c], 72
        mov     al, CMD_TEST_CONNECT
        call    ch_cmd
        call    ch_rd
        cmp     al, INT_CONNECT
        je      short ph_conn
        jmp     near pk_done
ph_conn:
        call    bringup
        jmp     near pk_done

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
        jc      short bu_notkbd

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

        ; A NAK from the key endpoint must come straight back, or an idle
        ; keyboard would hold the timer ISR for as long as it stayed idle.
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        xor     al, al
        call    ch_wr

        mov     byte [ep_tog], 0x80
        mov     byte [led_now], 0xFF     ; force the first LED sync
        mov     byte [live], 1
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
; Walk the configuration descriptor for a HID interface whose protocol byte
; says keyboard, and the first interrupt IN endpoint inside it.  A combo
; keyboard-and-mouse dongle puts the mouse on another interface, so the
; protocol byte matters rather than just taking the first HID.
; CF set if there is no such pair.
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
        mov     byte [got_if], 0
        mov     byte [got_ep], 0
        xor     bx, bx                   ; BX = offset
pc_loop:
        mov     al, bl
        add     al, 2
        cmp     al, cl
        ja      short pc_done
        mov     al, [si + bx]            ; bLength
        cmp     al, 2
        jb      short pc_done
        mov     ah, [si + bx + 1]        ; bDescriptorType
        cmp     ah, 4
        jne     short pc_notif
        ; interface: class 3, protocol 1 is a boot keyboard
        mov     byte [in_kbd], 0
        cmp     byte [si + bx + 5], 3
        jne     short pc_next
        cmp     byte [si + bx + 7], 1
        jne     short pc_next
        mov     byte [in_kbd], 1
        cmp     byte [got_if], 0
        jne     short pc_next
        mov     ah, [si + bx + 2]
        mov     [kbd_if], ah
        mov     byte [got_if], 1
        jmp     short pc_next
pc_notif:
        cmp     ah, 5
        jne     short pc_next
        cmp     byte [in_kbd], 0
        je      short pc_next
        cmp     byte [got_ep], 0
        jne     short pc_next
        mov     ah, [si + bx + 2]        ; bEndpointAddress
        test    ah, 0x80                 ; must be IN
        je      short pc_next
        mov     dl, [si + bx + 3]        ; bmAttributes
        and     dl, 3
        cmp     dl, 3                    ; must be interrupt
        jne     short pc_next
        and     ah, 0x0F
        mov     [ep_in], ah
        mov     byte [got_ep], 1
pc_next:
        xor     ah, ah
        add     bx, ax
        jmp     short pc_loop
pc_done:
        cmp     byte [got_if], 0
        je      short pc_fail
        cmp     byte [got_ep], 0
        je      short pc_fail
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
        mov     dx, msg_found
        call    puts
        mov     al, [ep_in]
        call    putdecw_al
        mov     dx, msg_iface
        call    puts
        mov     al, [kbd_if]
        call    putdecw_al
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
        jnc     short st_extra
        mov     dx, msg_t_three
        call    puts

        mov     dx, msg_t_pass
        call    puts
        jmp     near quit
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

        ; Go resident, keeping everything up to resident_end.
        mov     dx, resident_end
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
        ; confirm which address a driver loaded with @nnn actually took.
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
        mov     dx, msg_s_live
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
        mov     al, [op_wake]
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
        ; never worked here.  AND 0xDF folds lower case to upper by
        ; clearing bit 5, which is right for letters and wrong for
        ; everything else: it turns '?' (3Fh) into 1Fh, so the comparison
        ; further down could never match and the switch was ignored.
        ; USBCOMBO found and fixed this; USBKBD has the same parser and
        ; kept the bug until now.
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
        mov     byte [op_leds], 0
        jmp     short pa_more
pa_s6:
        cmp     al, 'H'
        jne     short pa_s6h
        mov     byte [op_hook], 1
        jmp     short pa_more_t
pa_s6h:
        cmp     al, 'W'
        jne     short pa_s6w
        mov     byte [op_wake], 1
        jmp     short pa_more_t
pa_s6w:
        cmp     al, 'X'
        jne     short pa_s6x
        call    pa_hexnum
        mov     [op_hold], al
        jmp     short pa_more_t
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
        jne     short pa_s6b
        mov     byte [op_enh], 1
        jmp     short pa_more_t
pa_s6b:
        ; '?' is caught up in pa_slash now, before the upper-casing, so
        ; there is nothing left to test for here.
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
res_seg:    dw  0
res_seg_enh: db 0                ; own_enh, read out of the resident copy
res_hook:    db 0                ; op_hook, likewise
bu_err:     dw  0

desc_buf:   times 64 db 0
cfg_buf:    times 128 db 0

msg_prog:      db 'USBKBD $'
msg_by:        db ' -- StevenC & Claude', 13, 10, '$'
msg_ok:        db 'USBKBD resident.  Keys go to the BIOS buffer.', 13, 10, '$'
msg_found:     db 'USB keyboard on CH375: endpoint $'
msg_iface:     db ', HID interface $'
msg_vidpid:    db ', VID/PID $'
msg_lowspd:    db 'Low-speed device; USB bus set to 1.5 Mbps.', 13, 10, '$'
msg_already:   db 'USBKBD is already loaded.  /U unloads it.', 13, 10, '$'
msg_isres:     db 'Loaded: USBKBD $'
msg_isres2:    db '.', 13, 10, '$'
msg_s_live:    db '  live=$'
msg_s_base:    db '  I/O base=$'
msg_s_baseh:   db 'h  (data, command+1)', 13, 10, '$'
msg_s_ep:      db '  endpoint=$'
msg_s_poll:    db '  polls=$'
msg_s_rep:     db '  reports=$'
msg_s_keys:    db '  keys delivered=$'
msg_s_full:    db '  keys dropped (buffer full)=$'
msg_s_rate:    db '  timer divisor=$'
msg_s_lock:    db '  locks (bit0 num, 1 caps, 2 scroll)=$'
msg_s_enh:     db '  claiming a 101/102-key keyboard (/E)=$'
msg_hold:      db 'Pretending a key is held down (/X), 64 repeats then it lets'
               db ' go.', 13, 10, '$'
msg_s_wake:    db '  /W (withdrawn -- it locked the machine)=$'
msg_s_hook:    db '  delivering through an INT 16h hook (/H)=$'
msg_s_ring:    db '  keys served through the hook=$'
msg_s_kbc:     db '  injecting through the 8042 (/K)=$'
msg_s_kbcbad:  db '  injections the 8042 refused=$'
msg_kbc:       db 'Injecting through the keyboard controller (8042 D2h).', 13, 10, '$'
msg_nokbc:     db 'No keyboard controller answers port 64h; /K ignored and'
               db ' the BIOS', 13, 10
               db 'buffer used instead.', 13, 10, '$'
msg_notres:    db 'USBKBD is not loaded.', 13, 10, '$'
msg_unloaded:  db 'USBKBD unloaded.', 13, 10, '$'
msg_hooked:    db 'Cannot unload: something else hooked INT 08h after us.', 13, 10, '$'
msg_mismatch:  db 'The resident copy is version $'
msg_mismatch2: db ' and this one is $'
msg_mismatch3: db '.', 13, 10
               db 'Refusing: /S and /U read the resident copy at the'
               db ' offsets of', 13, 10
               db 'the build doing the reading, and these two are not the'
               db ' same', 13, 10
               db 'image.  Use the matching USBKBD.COM, or reboot.'
               db 13, 10, '$'
msg_nochip:    db 'No CH375 responds at that I/O address.', 13, 10, '$'
msg_oldchip:   db 'CH375 revision is older than B5; this driver needs the'
               db ' command-port ready flag.', 13, 10, '$'
msg_nodev:     db 'No USB keyboard enumerated.  Use /F to load anyway and'
               db ' wait for one.', 13, 10, '$'
msg_notkbd:    db 'The attached device is not a HID boot keyboard.  USBINFO'
               db ' in CH375USBTOOLS says what it is.', 13, 10, '$'
msg_forced:    db 'No keyboard yet; loading anyway and polling for one.', 13, 10, '$'
msg_laststat:  db 'Last CH375 status: $'
msg_t_start:   db 'Self-test: driving usage 04h through the delivery path.', 13, 10, '$'
msg_t_one:     db '  ok   key_down -> INT 16h gave 1E61h', 13, 10, '$'
msg_t_two:     db '  ok   a whole report through the press diff -> 1E61h', 13, 10, '$'
msg_t_three:   db '  ok   the matching release produced no key', 13, 10, '$'
msg_t_spare:   db '  FAIL -- the release produced a spurious key.', 13, 10, '$'
msg_t_pass:    db '  PASS -- the delivery path is intact.', 13, 10, '$'
msg_t_wrong:   db '  FAIL -- INT 16h returned $'
msg_t_none:    db '  FAIL -- nothing reached the BIOS keyboard buffer.', 13, 10, '$'
msg_t_conn:    db '  connect            : $'
msg_t_conn2:   db '  connect after reset: $'
msg_t_rate:    db '  device rate reg 07 : $'
msg_t_descr:   db '  GET_DESCR device   : $'
msg_t_proto:   db '  SET_PROTOCOL boot  : $'
msg_t_idle:    db '  SET_IDLE 0         : $'

msg_help:
        db 'USBKBD [@260] [/S] [/U] [/F] [/V] [/N] [/E] [/K] [/R=n]', 13, 10
        db '  @nnn  CH375 I/O base in hex; /S shows the one in use', 13, 10
        db '  /S    status of the loaded copy      /U  unload', 13, 10
        db '  /F    load even with no keyboard     /V  trace the bring-up', 13, 10
        db '  /K    inject through the 8042 instead of the BIOS buffer.', 13, 10
        db '        The only way to reach a program that hooks INT 09h --', 13, 10
        db "        EDIT's menus, most games.  Needs an AT-class 8042", 13, 10
        db '  /W    accepted and ignored; it used to lock the machine', 13, 10
        db '  /H    deliver via an INT 16h hook, not the BIOS buffer.', 13, 10
        db '        Try this if a program ignores the keyboard', 13, 10
        db '  /T    self-test the delivery path and exit', 13, 10
        db '  /Y=n  HID idle rate, 4ms units; 0 = on change (default)', 13, 10
        db '  /N    do not drive the lock LEDs', 13, 10
        db '  /E    claim a 101/102-key keyboard in 40:96, so software', 13, 10
        db '        uses the enhanced INT 16h calls.  Needs an AT BIOS', 13, 10
        db '  /R=n  timer divisor, 1..16, default 8 (145 Hz polling)', 13, 10
        db '  /D=n  ticks before a key repeats, default 72', 13, 10
        db '  /T=n  ticks between repeats, default 5', 13, 10
        db 13, 10
        db 'Keys are written into the BIOS keyboard buffer, so anything', 13, 10
        db 'reading INT 16h or DOS sees them.  A program that hooks INT 09h', 13, 10
        db 'and reads the 8042 itself -- most games -- will not.', 13, 10, '$'
