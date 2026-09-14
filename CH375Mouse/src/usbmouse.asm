; ==========================================================================
; USBMOUSE.COM -- a DOS INT 33h mouse driver fed by a USB HID mouse
;                 attached to a WCH CH375 in host mode.
;
;   Version 1.0.0                                                  StevenC
;   https://github.com/jdredd87/CH375USBToolsTools
;   Public domain (the Unlicense).  Do anything you like with it.
;
; The version number is written down in exactly one place: ver_str, a few
; lines below the signature.  It is what every message prints and what a
; resident copy carries in memory, so bumping it there is the whole job --
; that, a CHANGELOG.md entry and a git tag.
;
;   USBMOUSE [@260] [/S] [/U] [/F] [/V] [/R=n]
;       @nnn    CH375 I/O base in hex, default 260
;       /S      report status of an already-loaded copy
;       /U      unload
;       /F      install even if no mouse enumerates, and keep looking
;       /V      trace each bring-up step and the status it returned
;       /E=n    skip enumeration and poll endpoint n regardless.  For a
;               mouse whose descriptors will not parse, and for proving the
;               poll path survives a device that never answers
;       /R=n    timer divisor, PIT rate = 18.2 * n Hz.  Default 8 (145 Hz);
;               n must be 1..16 and the BIOS tick is still delivered at
;               18.2 Hz whatever n is.
;
; The board is the WCH CH375 ISA card, whose PLD decodes
;       base+0   data port
;       base+1   command port (reading it: bit 7 clear = interrupt pending)
;       base+2   bit 0 = a readback of the chip's INT# pin
; Only the first two are used at run time.  Chip revisions from B5 up report
; readiness in bit 7 of the command port, which is one IN rather than two, so
; that is what the poll loop uses; INIT checks the revision and refuses to
; install on anything older rather than silently polling the wrong port.
;
; ASSEMBLING -- either of these produces the same image:
;       nasm -f bin usbmouse.asm -o USBMOUSE.COM
;       MNASMFIX -f bin -o USBMOUSE.COM usbmouse.asm      (on the DOS box)
; Every jump carries an explicit short/near at its natural size, because
; mininasm shortens jumps on every pass and a forced-long jump never
; converges.  Do not widen one to fix a range error -- add a trampoline.
;
; WHY A TIMER HOOK -- DOS is not reentrant and the CH375 has no useful IRQ
; wiring on this card, so the mouse is polled.  18.2 Hz is far too slow to
; track a mouse, so INT 08h is taken over and the PIT divided by 8; the
; original handler is still called every 8th tick, so BIOS timekeeping,
; DOS's own clock and anything else chained on INT 08h see exactly the rate
; they expect.  Poll cost is one IN token, about 200 us; if the device does
; not answer within the bounded wait the tick is simply skipped.
; ==========================================================================

        cpu     8086
        bits    16
        org     0x100

; ---- CH375 commands ----
CMD_GET_IC_VER   equ 0x01
CMD_RESET_ALL    equ 0x05
CMD_CHECK_EXIST  equ 0x06
CMD_SET_RETRY    equ 0x0B
CMD_SET_USB_ADDR equ 0x13
CMD_SET_USB_MODE equ 0x15
CMD_TEST_CONNECT equ 0x16
CMD_ABORT_NAK    equ 0x17
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

PID_OUT          equ 0x01
PID_IN           equ 0x09
PID_SETUP        equ 0x0D

USB_ADDR         equ 2            ; address we give the mouse

; ==========================================================================
; RESIDENT IMAGE
; ==========================================================================

entry:
        jmp     near init                       ; 0100

; An already-resident copy is found by following INT 33h and looking for
; this string at a fixed offset.  It must stay at 0103 -- /U and /S both
; depend on it, and installing a second copy over the first would leak the
; interrupt vectors of the one underneath.
signature:
        db      'USBMOUS1'                      ; 0103

; The version, in ASCII, ending in '$' so it can be printed as it stands.
; It is resident and it sits immediately after the signature, so /S can read
; the version of the copy that is ALREADY LOADED rather than reporting its
; own -- which is the interesting number when two builds are in play.  Keep
; it at 010B: that offset is now part of what a resident copy promises, the
; same way the signature at 0103 is.  Versions before 1.0.0 carry nothing
; here, so /S against one of those prints rubbish; there is one such build.
ver_str:
        db      '1.1.0$'                        ; 010B

; ---- saved vectors ----
old33:  dd      0
old08:  dd      0

; ---- hardware ----
io_dat: dw      0x260
io_cmd: dw      0x261
ep_in:  db      0                ; interrupt IN endpoint number

; ---- the SERIAL mouse path ----
;
; A second kind of mouse entirely: not a USB mouse, but a SERIAL mouse on a
; USB-to-serial adapter that is itself plugged into the CH375.  Everything
; above the input layer is shared -- INT 33h, the cursor, the event
; handlers, the PS/2 emulation -- because none of it cares where a report
; came from.  apply_report takes three bytes (buttons, dx, dy) and that is
; exactly what a serial packet decodes into.
;
; ser_mode is a VALUE and not a flag for the reason USBPKT's link_mode is:
; a third source is likelier than a second was.
SM_HID       equ 0                ; a USB HID mouse, straight into the CH375
SM_SERIAL    equ 1                ; a serial mouse on a USB-to-serial adapter

; WHICH SERIAL MOUSE, which is a different question from which adapter.
;
; Microsoft is 1200 7N1 and three bytes; Mouse Systems is 1200 8N1 and five.
; They disagree about the DATA BITS, so this cannot be sorted out by looking
; at the stream after the fact -- open the port at the wrong width and the
; bytes arrive mangled.  It has to be decided before the framing is set, and
; the mouse itself is what decides it: a Microsoft mouse says 'M' when its
; power comes up and a Mouse Systems mouse says nothing at all.
SP_MOUSESYS  equ 0                ; five bytes, 8N1, three buttons, active low
SP_MICROSOFT equ 1                ; three bytes, 7N1, two buttons, bit 6 sync

ser_mode: db    SM_HID
ser_out:  db    0                ; bulk OUT carrying data
ser_ctl:  db    0                ; bulk OUT carrying the port control message
ser_hdr:  db    0                ; status bytes at the head of every IN packet
ser_ctog: db    0x80             ; toggle for the control endpoint
ser_anyep: db   0                ; 1 = take endpoints whatever type they claim
ser_bud:  db    0                ; reads left in this tick's drain
ser_proto: db   SP_MOUSESYS       ; which serial mouse protocol
ser_bits: db    7                 ; data bits the port is opened at
ser_full: dw    0                ; drains that used the WHOLE budget, i.e.
                                 ; ticks that ran out of patience with bytes
                                 ; still waiting.  THIS is the backlog
                                 ; indicator: reports delivered only measures
                                 ; how much somebody moved the mouse, which
                                 ; is why it could not answer whether the
                                 ; drain was keeping up
ser_reads: dw   0                ; successful reads, for a rate
ser_over: dw    0                ; packets longer than the buffer

; DIAGNOSIS LIVES IN MOUPROBE, NOT IN HERE.
;
; Hunting the framing fault needed a log of the raw bytes before the decoder
; grouped them, and a histogram of read sizes.  Both were invaluable and
; neither belongs in a resident driver: the byte log wrote to memory for
; every byte INSIDE THE TIMER INTERRUPT, on a machine where the cost of ISR
; work had just been demonstrated by making DOS unusable.
;
; They are gone from here and MOUPROBE keeps them, which is where a
; transient tool that can afford the time should have had them all along.
; What stays below is per-packet or per-error, cheap, and answers the
; questions a loaded driver gets asked.

; Bytes drained this tick, before any of them are decoded.
;
; DRAIN FIRST, DECODE AFTER, and the order is the whole point.  The first
; version called apply_report from inside the read loop, so between one
; read and the next the driver drew a cursor, dispatched an event handler
; and emitted a PS/2 packet -- milliseconds during which nothing was
; servicing the adapter.  The probe tool reads back-to-back and sees a
; clean five-byte cadence; the driver saw three-byte gaps in the same
; stream from the same mouse, which is bytes going missing mid-stream
; rather than any fault in the decoding.
ser_q:    times 80 db 0
ser_qn:   db    0

; A buffer of its OWN, and both halves of that matter.
;
; rep_buf is eight bytes because a HID boot report is three and nothing
; sensible is longer.  A serial adapter's bulk IN can carry a whole 64-byte
; packet, and ch_read stores only the BL bytes it is given while RETURNING
; THE CHIP'S FULL COUNT -- so reading a 12-byte packet into rep_buf with
; BL=8 threw four bytes away and then told the caller there were twelve.
; The decoder walked off the end of rep_buf and fed itself rep_count,
; last_ist and rep_len as mouse movement.
;
; Separate, because ser_feed writes the finished report into rep_buf[0..2]
; -- which, if the raw bytes lived there too, would overwrite the ones this
; very batch had not read yet.
SER_BUFSZ equ  72
ser_buf:  times SER_BUFSZ db 0
ser_n:    db    0                ; bytes of the packet being assembled
ser_btn:  db    0                ; buttons held, decoded on the header byte
ser_pkt:  times 8 db 0
ser_vid:  dw    0
ser_pid:  dw    0
ser_reps: dw    0                ; serial packets decoded, for /S
ser_lost: dw    0                ; bytes dropped hunting for a header
ep_tog: db      0x80             ; SET_ENDP6 argument: bit 6 is the toggle
hid_if: db      0                ; bInterfaceNumber of the HID interface
cfg_val:db      1
tick_n: db      8                ; PIT divisor asked for on the command line
tick_use:db     8                ; the divisor actually in force right now
tick_c: db      8                ; countdown to the next downstream tick
on_top: db      1                ; 1 = INT 08h still points at us
op_keep:db      0                ; /K: never give the fast rate up
in_poll:db      0                ; reentrancy guard for the CH375
poll_off:db     0                ; 1 = the timer leaves the CH375 alone
live:   db      0                ; 1 = a mouse enumerated
low_spd:db      0                ; 1 = bus was dropped to 1.5 Mbps
retry_c:db      0                ; ticks until the next hot-plug retry

; ---- mouse state ----
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
m8_x:   dw      8                ; mickeys per 8 virtual units (function 0Fh)
m8_y:   dw      16
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

; ---- PS/2 BIOS mouse emulation, for Windows 3.x (see /W) ----
old15:  dd      0
old11:  dd      0
old74:  dd      0
ps2_on: db      0                ; the emulation is installed
ps2_en: db      0                ; INT 15h C200h BH=1 has enabled reporting
ps2_hof:dw      0                ; handler registered by INT 15h C207h
ps2_hsg:dw      0
ps2_pnd:db      0                ; a packet is waiting to be delivered
ps2_st: db      0                ; the three PS/2 packet bytes
ps2_x:  db      0
ps2_y:  db      0
ps2_pkt:db      3                ; package size from C205h

; The ROM configuration table INT 15h AH=C0h hands back.  The Windows 3.0
; MOUSE.DRV on this machine reads the model byte at offset 2 and insists on
; F8h, FAh or FCh before it will believe a pointing device exists.  FCh also
; makes it choose INT 74h, which is free on an XT-class box.  The feature
; bytes claim nothing, because nothing else here is being emulated.
cfg_tab:
        dw      8                ; bytes following
        db      0FCh             ; model:    PS/2 class
        db      004h             ; submodel
        db      000h             ; BIOS revision
        db      000h, 000h, 000h, 000h, 000h

rep_buf:times 8 db 0
rep_count:dw    0                ; reports applied, real or injected
last_ist:db     0                ; last non-success CH375 poll status
rep_len: db     0                ; length of the last report the mouse sent
btn_seen:db     0                ; every button bit ever seen set
btn_reps:dw     0                ; reports that carried a button down
ev_cond: dw     0                ; what happened in the last report, as the
                                 ; INT 33h function 0Ch condition mask

; ==========================================================================
; CH375 PRIMITIVES.  Every OUT is followed by one `jmp short $+2` hop: the
; vendor driver measured that a CH375 on an ISA card needs the gap after a
; command write, and going to zero there risks silent corruption for about
; 1.5% of throughput we do not need.
; ==========================================================================

ch_cmd:                                  ; AL = command byte
        push    dx
        mov     dx, [io_cmd]
        out     dx, al
        jmp     short ch_cmd_r
ch_cmd_r:
        pop     dx
        ret

ch_wr:                                   ; AL = data byte
        push    dx
        mov     dx, [io_dat]
        out     dx, al
        jmp     short ch_wr_r
ch_wr_r:
        pop     dx
        ret

ch_rd:                                   ; -> AL
        push    dx
        mov     dx, [io_dat]
        in      al, dx
        pop     dx
        ret

; Wait for the chip's interrupt, then read and clear the status byte.
; CX on entry is the spin budget; returns AL = status, CF set on timeout.
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

; Read the receive buffer to DS:DI, keeping at most BL bytes.
; Returns CL = the length the chip reported.
;
; The count is pushed before the copy: LOOP is what walks the buffer and it
; leaves CX at zero, so returning "CL = length" without saving it first
; hands every caller a length of nought.  That silently emptied the
; configuration descriptor and made a mouse that had enumerated perfectly
; look like it had no endpoints.
ch_read:
        mov     al, CMD_RD_USB_DATA
        call    ch_cmd
        call    ch_rd
        mov     cl, al
        mov     ch, 0
        push    cx
        jcxz    ch_read_done
ch_read_loop:
        call    ch_rd
        cmp     bl, 0
        je      short ch_read_skip
        mov     [di], al
        inc     di
        dec     bl
ch_read_skip:
        loop    ch_read_loop
ch_read_done:
        pop     cx
        ret

; ==========================================================================
; INT 08h -- the poll tick.
; ==========================================================================

; --------------------------------------------------------------------------
; Are we still the first handler on INT 08h?
;
; This driver multiplies the tick rate by eight and divides it again on the
; way DOWN the chain, which keeps the BIOS -- and anything that hooked INT 08h
; before us -- at the 18.2 Hz it expects.  Anything that hooks INT 08h AFTER
; us sits above that division and sees all 145 interrupts a second, so every
; timer it runs goes eight times too fast.
;
; Windows is exactly that case: it has to be started after the driver is
; loaded, and a Windows whose tick runs eight times fast has a double-click
; window eight times too short -- which is why single clicks worked there and
; double clicks did not.
;
; So when the vector stops being ours, the multiplication is doing more harm
; than good and the PIT goes back to 18.2 Hz; when we get the vector back --
; Windows restores it on the way out -- the fast rate comes back.  The
; alternative, snatching the vector back and pushing the newcomer underneath,
; needs a pointer to a handler that may since have been freed, and getting
; that wrong crashes the machine rather than merely slowing the mouse down.
; --------------------------------------------------------------------------
check_top:
        cmp     byte [op_keep], 0        ; /K: caller wants smoothness anyway
        jne     short ct_done
        push    es
        push    ax
        push    bx
        xor     ax, ax
        mov     es, ax
        mov     bx, cs
        cmp     word [es:0x22], bx
        jne     short ct_lost
        cmp     word [es:0x20], int08
        jne     short ct_lost
        cmp     byte [on_top], 0         ; ours again -- speed back up
        jne     short ct_out
        mov     byte [on_top], 1
        mov     al, [tick_n]
        mov     [tick_use], al
        mov     [tick_c], al
        call    pit_fast
        jmp     short ct_out
ct_lost:
        cmp     byte [on_top], 0         ; somebody is above us -- slow down
        je      short ct_out
        mov     byte [on_top], 0
        mov     byte [tick_use], 1
        mov     byte [tick_c], 1
        call    pit_slow
ct_out:
        pop     bx
        pop     ax
        pop     es
ct_done:
        ret

int08:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        mov     ax, cs
        mov     ds, ax

        call    check_top
        call    poll_mouse

        dec     byte [tick_c]
        jne     short int08_own
        mov     al, [tick_use]
        mov     [tick_c], al
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        jmp     far [cs:old08]           ; the BIOS tick, at its own rate

int08_own:
        mov     al, 0x20                 ; the other 7 ticks are ours alone
        out     0x20, al
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

; --------------------------------------------------------------------------
; One interrupt IN transaction.  Retries are off, so a mouse with nothing to
; report NAKs and we are back within microseconds.
; --------------------------------------------------------------------------
poll_mouse:
        cmp     byte [poll_off], 0
        je      short poll_go
        ret
poll_go:
        ; live: 0 = nothing found, 1 = enumerated and pollable, 2 = something
        ; is plugged in but has not been enumerated.  Only state 1 may issue
        ; tokens -- polling endpoint 0 because ep_in is still zero would just
        ; produce a stream of errors that look like a driver fault.
        cmp     byte [live], 1
        je      short poll_have
        jmp     near poll_hotplug
poll_have:
        cmp     byte [in_poll], 0
        je      short poll_free
        jmp     near poll_ret
poll_free:
        mov     byte [in_poll], 1
        ; DRAIN THE PIPE, DO NOT SIP FROM IT.
        ;
        ; A HID mouse sends one report per transaction and one transaction
        ; per tick is exactly right.  A serial adapter does not: the Keyspan
        ; is asked to forward every byte the moment it arrives -- which is
        ; what keeps latency down -- so each USB packet carries ONE byte of
        ; mouse data, and a five-byte report needs five transactions.
        ;
        ; At 145 ticks a second that is 145 bytes/s against a 1200-baud
        ; mouse producing 120.  Twenty percent of headroom is not headroom:
        ; lose a few ticks to another interrupt and the backlog sits in the
        ; adapter, so movement arrives late and in bursts.  It reads as a
        ; mouse that does not track properly, which is what it was.
        ;
        ; Sixteen reads a tick is three whole reports, and costs nothing
        ; when the wire is quiet because the first NAK ends the drain.
        ; FOUR, not sixteen.  The backlog counter read zero on every run,
        ; so the budget was never being used -- it was pure exposure: each
        ; extra read is a USB transaction inside a timer interrupt, and
        ; when the chip was wrongly left retrying NAKs each one cost a full
        ; timeout.  Four covers a whole three-byte report in one tick with
        ; a read to spare, and the next tick is only 7 ms away.
        mov     byte [ser_bud], 4
poll_again:

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

        mov     cx, 1500                 ; about 3 ms, then give up on this tick
        call    ch_wait
        jnc     short poll_st
poll_done_t:                             ; trampoline: the serial read path
        jmp     poll_done                ; pushed poll_done out of short reach
poll_st:
        cmp     al, INT_SUCCESS
        je      short poll_got
        mov     [last_ist], al
        cmp     al, 0x2E                 ; STALL: clear it and resynchronise
        jne     short poll_done_t2
        jmp     short poll_stall
poll_done_t2:
        jmp     poll_done
poll_stall:
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        mov     al, [ep_in]
        or      al, 0x80
        call    ch_wr
        mov     cx, 1500
        call    ch_wait
        mov     byte [ep_tog], 0x80
        jmp     poll_done

poll_got:
        cmp     byte [ser_mode], SM_HID
        jne     short poll_got_ser
        mov     di, rep_buf
        mov     bl, 8
        call    ch_read
        mov     [rep_len], cl
        xor     byte [ep_tog], 0x40      ; DATA0 <-> DATA1
        jmp     short poll_hid
poll_got_ser:
        mov     di, ser_buf
        mov     bl, SER_BUFSZ
        call    ch_read
        mov     [rep_len], cl
        xor     byte [ep_tog], 0x40      ; DATA0 <-> DATA1
        ; ch_read hands back what the CHIP said, not what it stored, so a
        ; packet bigger than the buffer would otherwise send the decoder
        ; off the end of it.  Counted, because "this cannot happen" is how
        ; the last one got in.
        cmp     cl, SER_BUFSZ
        jbe     short poll_ser_fits
        mov     cl, SER_BUFSZ
        inc     word [ser_over]
poll_ser_fits:
        push    cx
        call    ser_queue                ; stash it; decode after the drain
        inc     word [ser_reads]
        pop     cx

        ; A SUCCESSFUL READ IS NOT THE SAME AS A READ WITH SOMETHING IN IT.
        ;
        ; The Keyspan NAKs when it has nothing, so "drain until it NAKs" was
        ; a complete stopping rule.  An FTDI never NAKs: it answers every
        ; single poll with its two status bytes and no data.  Under the old
        ; rule the drain would spend its whole budget every tick, for ever,
        ; on an idle mouse -- four USB transactions per tick at 145 Hz, in
        ; the timer interrupt, for nothing.  That is the same shape of fault
        ; as the SET_RETRY one that made DOS unusable, arriving by a
        ; different road.
        mov     al, [ser_hdr]
        cmp     cl, al
        jbe     short poll_drained       ; header only: the pipe is empty
        dec     byte [ser_bud]
        jne     short poll_more
        inc     word [ser_full]          ; budget gone and bytes still coming
poll_drained:
        jmp     short poll_done
poll_more:
        jmp     poll_again
poll_hid:
        cmp     cl, 3
        jb      short poll_done
        ; Button bookkeeping for /S lives here rather than in apply_report,
        ; so that it counts only what the mouse actually sent.  Injected
        ; reports go through apply_report too, and if they were counted the
        ; one number that answers "did a real press ever arrive" would be
        ; whatever the test suite last pushed in.
        mov     al, [rep_buf]
        and     al, 7
        je      short poll_nobtn
        or      [btn_seen], al
        inc     word [btn_reps]
poll_nobtn:
        call    apply_report

poll_done:
        ; The drain is over; now it is safe to spend time.
        cmp     byte [ser_mode], SM_HID
        je      short poll_nodec
        mov     cl, [ser_qn]
        or      cl, cl
        je      short poll_nodec
        mov     byte [ser_qn], 0
        call    ser_bytes
poll_nodec:
        mov     byte [in_poll], 0
poll_ret:
        ret

; With /F the driver installs with nothing attached and looks again about
; twice a second, so plugging a mouse in later still works.
poll_hotplug:
        dec     byte [retry_c]
        jne     short poll_ret
        mov     byte [retry_c], 64
        cmp     byte [in_poll], 0
        jne     short poll_ret
        mov     byte [in_poll], 1
        mov     al, CMD_TEST_CONNECT
        call    ch_cmd
        call    ch_rd
        mov     byte [in_poll], 0
        cmp     al, INT_CONNECT
        jne     short poll_ret
        ; A device appeared.  Enumeration touches DOS for nothing, but it does
        ; take tens of milliseconds, which is far too long inside a timer
        ; interrupt -- so only the detection happens here.  The flag is picked
        ; up by the next INT 33h call, which runs in the caller's context.
        mov     byte [live], 2
        ret

; --------------------------------------------------------------------------
; Fold one 3-byte boot-protocol report into the driver state.
;   buf+0  bit0 left, bit1 right, bit2 middle
;   buf+1  signed X, right positive
;   buf+2  signed Y, DOWN positive (USB) -- INT 33h wants Y down too
; --------------------------------------------------------------------------
; Feed CL bytes at rep_buf into the serial packet decoder, and call
; apply_report for every complete one.
;
; Mouse Systems: five bytes, 1000 0LMR then dx, dy, dx, dy.
;
;   * The buttons are ACTIVE LOW -- a 0 bit means pressed -- which is the
;     single easiest thing here to get backwards, and getting it backwards
;     gives a mouse that reports three buttons held down forever.
;   * There are TWO movement pairs per packet and they are not duplicates;
;     the mouse sampled twice between sends.  Taking only the first halves
;     the reported speed and reads as a sluggish mouse rather than a bug.
;   * Y counts UP and a screen counts DOWN, so it is negated.
;
; It RESYNCHRONISES ON THE HEADER rather than counting blindly, because a
; byte will be lost eventually on a line nobody is flow-controlling, and a
; counting decoder that loses one is permanently one byte out -- which does
; not look like a lost byte, it looks like a mouse that jumps.
; --------------------------------------------------------------------------
; Append this read's data bytes to the tick's queue, stripping the
; adapter's per-packet status header.  No decoding, no cursor, no event
; handlers -- nothing that takes time while the adapter is waiting.
ser_queue:
        mov     ch, 0
        or      cl, cl
        je      short sq_ret
        mov     si, ser_buf
        mov     al, [ser_hdr]
        or      al, al
        je      short sq_copy
        cmp     cl, al
        jbe     short sq_ret
        mov     ah, 0
        add     si, ax
        sub     cl, al
sq_copy:
        mov     bl, [ser_qn]
        mov     bh, 0
sq_byte:
        cmp     bx, 80
        jae     short sq_done
        lodsb
        mov     [bx + ser_q], al
        inc     bx
        dec     cl
        jne     short sq_byte
sq_done:
        mov     [ser_qn], bl
sq_ret:
        ret

ser_bytes:
        mov     ch, 0
        or      cl, cl
        je      short sb_ret
        mov     si, ser_q
        ; Status stripping already happened in ser_queue, so this sees only
        ; data.  Kept as a parameter rather than hard-zeroed because the
        ; queue is the only thing that changed, not the framing.
        xor     al, al
        ; Some adapters put status bytes at the head of every IN packet --
        ; one on the Keyspan, two on FTDI.  They are not data and feeding
        ; them to the decoder would desynchronise it on every single packet.
        or      al, al
        je      short sb_loop
sb_loop:
        lodsb
        call    ser_feed
        dec     cl
        jne     short sb_loop
sb_ret:
        ret

; AX -> AL, clamped into a signed byte.  Movement past the clamp is lost
; rather than wrapped, and losing it is much the lesser evil: a lost count
; is a mouse that moves slightly less far than the hand did, and a wrapped
; one is a mouse that jumps the other way.
clamp_byte:
        cmp     ax, 127
        jle     short cb_lo
        mov     ax, 127
        ret
cb_lo:
        cmp     ax, -128
        jge     short cb_out
        mov     ax, -128
cb_out:
        ret

ser_feed:
        push    cx
        push    si

        cmp     byte [ser_proto], SP_MICROSOFT
        je      ms_feed

        cmp     byte [ser_n], 0
        jne     short sf_body

        ; A header is 1000 0LMR.  Anything else here is a byte we are not in
        ; step with, and dropping it is how the decoder finds its feet.
        mov     ah, al
        and     ah, 0xF8
        cmp     ah, 0x80
        je      short sf_hdr
        inc     word [ser_lost]
        jmp     sf_out
sf_hdr:
        call    ser_btns
        mov     byte [ser_n], 1
        mov     [ser_pkt], al
        jmp     sf_out

sf_body:
        ; THREE BYTES OR FIVE, DECIDED FROM THE STREAM AND NOT ASSUMED.
        ;
        ; Two protocols share this header shape.  MM Series sends THREE
        ; bytes -- header, dx, dy -- and Mouse Systems sends FIVE, with a
        ; second dx/dy pair sampled between reports.  A decoder that picks
        ; one and hopes eats the next packet's header as dx2 on a mouse
        ; that speaks the other, and then discards everything up to the
        ; header after that: two bytes lost in every five, which measured
        ; as a rock-steady 40% through four unrelated "fixes".
        ;
        ; The mouse on this bench is MM.  The probe tool read the same
        ; mouse as Mouse Systems, which is what kept the wrong assumption
        ; alive so long, so neither is safe to assume.
        ;
        ; The test is cheap and needs no configuration: after three bytes,
        ; look at the fourth.  If it is a header, the packet was three
        ; bytes and that byte begins the next one.  If it is not, it is
        ; dx2 and this is a five-byte packet.  Being wrong once costs one
        ; packet and corrects itself, which is what the old assumption
        ; never did.
        cmp     byte [ser_n], 3
        jne     short sf_store
        mov     ah, al
        and     ah, 0xF8
        cmp     ah, 0x80
        jne     short sf_store           ; not a header: a five-byte packet

        ; Three-byte packet complete, and AL starts the next one.
        push    ax
        call    ser_emit3
        pop     ax
        call    ser_btns
        mov     byte [ser_n], 1
        mov     [ser_pkt], al
        jmp     short sf_out

sf_store:
        mov     bl, [ser_n]
        mov     bh, 0
        mov     [bx + ser_pkt], al
        inc     byte [ser_n]
        cmp     byte [ser_n], 5
        jb      short sf_out
        call    ser_emit5
        mov     byte [ser_n], 0
sf_out:
        pop     si
        pop     cx
        ret

; --------------------------------------------------------------------------
; MICROSOFT.  Three bytes, and nothing about it resembles the other one.
;
;   byte 0   1 1 L R Y7 Y6 X7 X6     bit 6 SET marks the header
;   byte 1   1 0 X5 X4 X3 X2 X1 X0
;   byte 2   1 0 Y5 Y4 Y3 Y2 Y1 Y0
;
; The movement is SPLIT ACROSS BYTES -- the top two bits of each axis ride
; in the header -- so a decoder cannot simply take bytes 1 and 2 as dx and
; dy.  Doing that gives a mouse that works perfectly until you move it more
; than 63 units in one report, and then wraps.
;
; The buttons are ACTIVE HIGH here, the opposite of Mouse Systems.  Decoding
; one with the other's sense gives a mouse reporting a press on every single
; packet, which is exactly what this driver did when it met this mouse.
;
; Sync is bit 6: set on the header, clear on the two body bytes.  That is a
; different bit from the other protocol's, which is why the framing has to
; be known rather than guessed.
; --------------------------------------------------------------------------
ms_feed:
        test    al, 0x40
        je      short ms_body
        ; A header always starts a fresh report.
        cmp     byte [ser_n], 0
        je      short ms_hdr
        inc     word [ser_lost]          ; a short report; start again
ms_hdr:
        mov     [ser_pkt], al
        mov     byte [ser_n], 1
        jmp     sf_out
ms_body:
        cmp     byte [ser_n], 0
        jne     short ms_store
        inc     word [ser_lost]          ; body byte with no header
        jmp     sf_out
ms_store:
        mov     bl, [ser_n]
        mov     bh, 0
        mov     [bx + ser_pkt], al
        inc     byte [ser_n]
        cmp     byte [ser_n], 3
        jb      short ms_part
        mov     byte [ser_n], 0

        ; X = the two bits from the header, then six from byte 1.
        mov     al, [ser_pkt]
        and     al, 0x03
        mov     cl, 6
        shl     al, cl
        mov     ah, [ser_pkt+1]
        and     ah, 0x3F
        or      al, ah
        cbw
        mov     bx, ax                   ; BX = dx

        ; Y likewise, from bits 2-3 of the header and byte 2.
        mov     al, [ser_pkt]
        and     al, 0x0C
        mov     cl, 4
        shl     al, cl                   ; bits 2-3 -> bits 6-7
        mov     ah, [ser_pkt+2]
        and     ah, 0x3F
        or      al, ah
        cbw                              ; Y is already screen sense: down
                                         ; is positive, unlike Mouse Systems

        ; Buttons, ACTIVE HIGH: bit 5 left, bit 4 right.  No middle button
        ; in this protocol -- a third one needs the Logitech extension and
        ; this mouse does not claim it.
        push    ax
        mov     al, [ser_pkt]
        mov     ah, 0
        test    al, 0x20
        je      short ms_noleft
        or      ah, 1
ms_noleft:
        test    al, 0x10
        je      short ms_noright
        or      ah, 2
ms_noright:
        mov     [ser_btn], ah
        pop     ax
        call    ser_emit
ms_part:
        jmp     sf_out

; AL = header byte -> ser_btn.  The buttons are ACTIVE LOW: a 0 bit means
; pressed, which is the easiest thing here to get backwards and gives a
; mouse with three buttons held down for ever.
ser_btns:
        push    ax
        xor     ah, ah
        test    al, 0x04
        jne     short sb_noleft
        or      ah, 1
sb_noleft:
        test    al, 0x01
        jne     short sb_noright
        or      ah, 2
sb_noright:
        test    al, 0x02
        jne     short sb_nomid
        or      ah, 4
sb_nomid:
        mov     [ser_btn], ah
        pop     ax
        ret

; MM Series: one dx and one dy.
ser_emit3:
        mov     al, [ser_pkt+1]
        cbw
        mov     bx, ax
        mov     al, [ser_pkt+2]
        cbw
        neg     ax                       ; the protocol counts up, screens down
        xchg    ax, bx
        jmp     short ser_emit

; Mouse Systems: TWO samples, and both are delivered.
;
; The mouse sampled itself twice between sends, so a packet holds two
; successive movements rather than one movement split in half.  Summing
; them is correct arithmetic and throws away the thing that makes a pointer
; feel smooth: it turns two updates into one of twice the size, so the
; cursor moves in fewer, larger steps.  Delivering both doubles the update
; rate for nothing -- the data was already there and already paid for.
;
; It also sidesteps the overflow that summing them created: +100 and +100
; is 200, which a byte turns into -56, so a fast flick used to reverse.
; Two reports of 100 cannot overflow at all.
ser_emit5:
        mov     al, [ser_pkt+1]
        cbw
        mov     bx, ax                   ; first sample
        mov     al, [ser_pkt+2]
        cbw
        neg     ax                       ; screens count down
        call    ser_emit
        mov     al, [ser_pkt+3]
        cbw
        mov     bx, ax                   ; second sample
        mov     al, [ser_pkt+4]
        cbw
        neg     ax

; AX = dy, BX = dx.  Hand it to the shared report path.
ser_emit:
        push    ax
        inc     word [ser_reps]
        mov     al, [ser_btn]
        mov     [rep_buf], al
        mov     ax, bx
        call    clamp_byte
        mov     [rep_buf+1], al
        pop     ax
        call    clamp_byte
        mov     [rep_buf+2], al
        mov     al, [rep_buf]
        and     al, 7
        je      short se_nobtn
        or      [btn_seen], al
        inc     word [btn_reps]
se_nobtn:
        call    apply_report
        ret

; --------------------------------------------------------------------------
apply_report:
        inc     word [rep_count]
        mov     word [ev_cond], 0
        call    hide_cursor_hw

        mov     al, [rep_buf]
        and     ax, 7
        mov     bx, [buttons]
        mov     [buttons], ax
        call    button_edges             ; BX = old, AX = new

        mov     al, [rep_buf+1]
        cbw
        add     [mick_x], ax
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

        mov     al, [rep_buf+2]
        cbw
        add     [mick_y], ax
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

        mov     al, [rep_buf+1]
        or      al, [rep_buf+2]
        je      short apply_nomove
        or      word [ev_cond], 1        ; bit 0: the pointer moved
apply_nomove:
        call    show_cursor_hw
        call    fire_event
        call    ps2_emit
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

; ==========================================================================
; PS/2 BIOS MOUSE EMULATION
;
; Windows 3.x has no idea what INT 33h is: its mouse driver is a Windows DLL
; that talks to the PS/2 pointing-device BIOS.  Disassembling the Windows 3.0
; MOUSE.DRV that ships with this machine shows it never touches the 8042 --
; it drives everything through INT 15h AH=C2h and one hardware vector:
;
;   * INT 15h AH=C0h must return a configuration table whose model byte is
;     F8h, FAh or FCh, or the driver decides there is no pointing device at
;     all.  FCh also makes it pick INT 74h, free on an XT-class machine.
;   * INT 11h bit 2 must be set -- "pointing device installed".
;   * It then runs C205h, C201h, C203h, C207h, C206h, C202h and C200h,
;     retrying twenty times on error code 4 and giving up on anything else.
;   * C207h registers a callback.  The driver hooks INT 74h itself, and its
;     handler begins by chaining to whatever was already in that vector --
;     expecting the BIOS, which reads the mouse and calls that callback.  So
;     we take INT 74h first, and deliver the packet when it chains into us.
;
; That is the whole contract, and it is why none of this needs any Windows
; code: with the emulation in place the stock Microsoft driver runs
; unmodified.  It is off unless /W is given, because claiming to be a PS/2
; model FC on an 8086 is a lie other software can see.
; ==========================================================================

; Clear CF in the flags image that the IRET will restore.
;
; The offset is +8, not +6.  This is reached by a near CALL from inside an
; interrupt handler, so between the saved BP and the IRET frame there is also
; the call's own return address.  Getting that wrong clears bit 0 of the
; return CS instead of the flags, and the machine goes away the moment the
; handler returns -- which is exactly what it did.
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

; INT 74h.  Entered either from our own poll, or because MOUSE.DRV hooked the
; vector and chained to what it found there -- us.  Either way, if a packet is
; waiting and something has registered a callback, hand it over in the frame
; the PS/2 BIOS uses: status, X, Y and Z pushed in that order, a far call, and
; the caller cleans the stack up afterwards.
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
        add     sp, 8                    ; the callback returns with a bare RETF
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
ps2_emit:
        cmp     byte [ps2_on], 0
        je      short ps2_none
        cmp     byte [ps2_en], 0
        je      short ps2_none
        cmp     word [ps2_hsg], 0
        je      short ps2_none

        mov     al, [rep_buf]
        and     al, 7                    ; buttons sit in bits 0..2 either way
        or      al, 8                    ; bit 3 always reads back set
        mov     ah, [rep_buf+1]
        mov     [ps2_x], ah
        or      ah, ah
        jns     short ps2_xpos
        or      al, 0x10                 ; X sign
ps2_xpos:
        mov     ah, [rep_buf+2]
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
; INT 33h
; ==========================================================================

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
;   AX=7F00h  status:  BX = live flag (0 none, 1 enumerated, 2 hot-plug seen)
;                      CL = interrupt IN endpoint, CH = last CH375 status
;                      DX = report counter
;                      AL = PS/2 emulation installed, AH = enabled
;   AX=7F01h  inject a HID boot report: BL = buttons, CL = dx, CH = dy.
;             Everything downstream of the USB read -- scaling, clamping,
;             button edges, the text cursor, the event callback -- runs
;             exactly as it would for a real report.  This is how the driver
;             is tested when the USB device will not answer.
; --------------------------------------------------------------------------
f_dbgstat:
        mov     al, [ps2_on]             ; AL: /W emulation installed
        mov     ah, [ps2_en]             ; AH: the BIOS interface is enabled
        mov     [bp+0], ax
        mov     al, [live]
        xor     ah, ah
        mov     [bp+6], ax
        mov     al, [ep_in]
        mov     ah, [last_ist]
        mov     [bp+4], ax
        mov     ax, [rep_count]
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
f_dbgraw:
        mov     al, [rep_buf]
        mov     ah, [rep_buf+1]
        mov     [bp+6], ax
        mov     al, [rep_buf+2]
        mov     ah, [rep_buf+3]
        mov     [bp+4], ax
        mov     ax, [btn_reps]
        mov     [bp+2], ax
        mov     al, [btn_seen]
        mov     ah, [rep_len]
        mov     [bp+0], ax
        jmp     near i33_out

f_pause:
        mov     al, [poll_off]
        xor     ah, ah
        mov     dx, [bp+6]
        mov     [poll_off], dl
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
        mov     [rep_buf], al
        mov     ax, [bp+4]               ; CL: dx,  CH: dy
        mov     [rep_buf+1], al
        mov     [rep_buf+2], ah
        cli
        call    apply_report
        sti
        jmp     near i33_out

state_start equ cur_x
state_end   equ rep_buf

; PIT channel 0 counts down from 65536/n instead of 65536, so INT 08h fires
; n times as often.  int08 forwards every nth call to the handler below it,
; so the BIOS tick keeps its 18.2 Hz and its count stays right.
;
; These two program the counter and touch the interrupt flag not at all: the
; caller says what the interrupt state is.  check_top calls them from inside
; the timer interrupt, where IF is already clear and an STI would let a second
; tick nest inside the first; INIT and the unload path call the _cli wrappers
; below instead.  Doing it with PUSHF/POPF looked tidier and is not worth it
; on a CPU whose POPF carries an erratum.
pit_fast:
        push    ax
        push    bx
        push    dx
        mov     al, [tick_n]
        xor     ah, ah
        mov     bx, ax
        mov     ax, 0xFFFF               ; 65536/n as (65535/n)+1, which fits
        xor     dx, dx
        div     bx
        inc     ax
        mov     bx, ax
        mov     al, 0x36
        out     0x43, al
        jmp     short pit_f1
pit_f1:
        mov     al, bl
        out     0x40, al
        jmp     short pit_f2
pit_f2:
        mov     al, bh
        out     0x40, al
        pop     dx
        pop     bx
        pop     ax
        ret

pit_fast_cli:                            ; from outside an interrupt handler
        cli
        call    pit_fast
        sti
        ret

pit_slow_cli:
        cli
        call    pit_slow
        sti
        ret

pit_slow:
        push    ax
        mov     al, 0x36
        out     0x43, al
        jmp     short pit_s1
pit_s1:
        xor     al, al
        out     0x40, al
        jmp     short pit_s2
pit_s2:
        xor     al, al
        out     0x40, al
        pop     ax
        ret


resident_end:

; ==========================================================================
; INIT -- everything below here is discarded when the driver goes resident.
; ==========================================================================

init:
        mov     sp, 0xFFFE
        call    parse_args
        call    print_id                 ; every run says what it is
        mov     dx, msg_by
        call    puts
        cmp     byte [op_help], 0
        je      short init_nohelp
        mov     dx, msg_help
        call    puts
        mov     ax, 0
        jmp     near quit
init_nohelp:
        cmp     byte [op_status], 0
        je      short not_status
        jmp     near do_status
not_status:
        cmp     byte [op_unload], 0
        je      short not_unload
        jmp     near do_unload
not_unload:

        call    find_resident
        jnc     short init_fresh
        mov     dx, msg_already
        jmp     near die

init_fresh:
        call    ch375_bringup            ; CF set = no mouse
        jnc     short init_gotmouse
        cmp     byte [op_force], 0
        jne     short init_force
        mov     dx, msg_nodev
        jmp     near die
init_force:
        mov     byte [live], 0
        mov     byte [retry_c], 1
        mov     dx, msg_forced
        call    puts
        jmp     short init_hook
init_gotmouse:
        mov     byte [live], 1
        mov     byte [retry_c], 1
        cmp     byte [op_forceep], 0
        jne     short init_saidep
        call    report_found
        jmp     short init_hook
init_saidep:
        mov     dx, msg_forceep
        call    puts
        mov     al, [ep_in]
        call    putdec
        call    crlf

init_hook:
        ; INT 33h
        mov     ax, 0x3533
        int     0x21
        mov     [old33], bx
        mov     [old33+2], es
        mov     ax, 0x2533
        mov     dx, int33
        int     0x21

        ; INT 08h, then speed the PIT up.  Order matters: the vector has to
        ; be ours before a faster tick can arrive.
        mov     ax, 0x3508
        int     0x21
        mov     [old08], bx
        mov     [old08+2], es
        mov     ax, 0x2508
        mov     dx, int08
        int     0x21

        ; INT 15h, INT 11h and INT 74h, so a Windows 3.x mouse driver can
        ; find a pointing device.  Taken after INT 08h and before the timer
        ; speeds up, so nothing can arrive half-installed.
        cmp     byte [op_ps2], 0
        je      short init_nops2
        mov     ax, 0x3515
        int     0x21
        mov     [old15], bx
        mov     [old15+2], es
        mov     ax, 0x3511
        int     0x21
        mov     [old11], bx
        mov     [old11+2], es
        mov     ax, 0x3574
        int     0x21
        mov     [old74], bx
        mov     [old74+2], es
        mov     ax, 0x2515
        mov     dx, int15
        int     0x21
        mov     ax, 0x2511
        mov     dx, int11
        int     0x21
        mov     ax, 0x2574
        mov     dx, int74
        int     0x21
        mov     byte [ps2_on], 1
        cmp     byte [op_verb], 0
        je      short init_ps2quiet
        mov     dx, msg_t_v74            ; what was in INT 74h before us: on an
        call    puts                     ; XT-class machine this should be
        mov     ax, [old74+2]            ; nothing at all
        call    puthexw
        mov     al, ':'
        call    putc
        mov     ax, [old74]
        call    puthexw
        call    crlf
init_ps2quiet:
        mov     dx, msg_ps2
        call    puts
init_nops2:

        mov     al, [tick_n]
        mov     [tick_use], al
        mov     [tick_c], al
        mov     byte [on_top], 1
        call    pit_fast_cli

        call    print_id
        mov     dx, msg_ok
        call    puts

        mov     dx, resident_end
        add     dx, 15
        mov     cl, 4
        shr     dx, cl
        add     dx, 16                   ; PSP
        mov     ax, 0x3100               ; TSR
        int     0x21

; --------------------------------------------------------------------------

; --------------------------------------------------------------------------
; Find a resident copy: follow INT 33h and look for the signature.
; CF set = found, ES = its segment.
; --------------------------------------------------------------------------
find_resident:
        mov     ax, 0x3533
        int     0x21
        mov     ax, es
        or      ax, ax
        je      short find_no
        mov     si, signature
        mov     di, signature
        mov     cx, 8
        push    ds
        push    cs
        pop     ds
        repe    cmpsb
        pop     ds
        jne     short find_no
        stc
        ret
find_no:
        clc
        ret

; --------------------------------------------------------------------------
do_status:
        call    find_resident
        jc      short stat_have
        jmp     near stat_none
stat_have:
        mov     dx, msg_isres
        call    puts
        mov     dx, ver_str              ; the LOADED copy's version, read out
        call    puts_es                  ; of its image, not ours
        mov     dx, msg_isres2
        call    puts
        mov     al, [es:live]
        add     al, '0'
        call    putc
        ; The I/O base the RESIDENT copy is using -- ES points at its
        ; image, so this is the address it really took, not this program's
        ; default.  Without it there is no way to confirm what @nnn did.
        mov     dx, msg_s_base
        call    puts
        mov     ax, [es:io_dat]
        call    puthexw
        mov     al, 'h'
        call    putc
        mov     dx, msg_s_ep
        call    puts
        mov     al, [es:ep_in]
        call    putdec
        mov     dx, msg_s_rep
        call    puts
        mov     ax, [es:rep_count]
        call    putdecw
        mov     dx, msg_s_rate
        call    puts
        mov     al, [es:tick_use]
        call    putdec
        mov     dx, msg_s_btn
        call    puts
        mov     al, [es:btn_seen]
        call    puthex
        mov     dx, msg_s_brep
        call    puts
        mov     ax, [es:btn_reps]
        call    putdecw
        call    crlf

        ; The serial numbers, and only on the serial path.  They answer a
        ; question "reports=" cannot: that counter rises with how much
        ; somebody moved the mouse, so it says nothing about whether the
        ; driver is keeping up with the mouse.  backlog does.
        cmp     byte [es:ser_mode], SM_HID
        jne     short stat_serial
        jmp     stat_nops2
stat_serial:
        mov     dx, msg_s_sread
        call    puts
        mov     ax, [es:ser_reads]
        call    putdecw
        mov     dx, msg_s_spkt
        call    puts
        mov     ax, [es:ser_reps]
        call    putdecw
        mov     dx, msg_s_slost
        call    puts
        mov     ax, [es:ser_lost]
        call    putdecw
        mov     dx, msg_s_sfull
        call    puts
        mov     ax, [es:ser_full]
        call    putdecw
        call    crlf

        ; The last eight packets, raw.  Five bytes each: status, dx1, dy1,
        ; dx2, dy2.

        cmp     byte [es:ps2_on], 0
        je      short stat_nops2
        mov     dx, msg_s_ps2
        call    puts
        mov     al, [es:ps2_en]
        add     al, '0'
        call    putc
        mov     dx, msg_s_ps2h
        call    puts
        mov     ax, [es:ps2_hsg]
        call    puthexw
        mov     al, ':'
        call    putc
        mov     ax, [es:ps2_hof]
        call    puthexw
        call    crlf
stat_nops2:
        mov     al, [es:btn_seen]
        or      al, al
        jne     short stat_okbtn
        mov     dx, msg_s_nobtn
        call    puts
stat_okbtn:
        mov     ax, 0
        jmp     near quit
stat_none:
        mov     dx, msg_notres
        jmp     near die

; --------------------------------------------------------------------------
do_unload:
        call    find_resident
        jnc     short stat_none
        ; only safe if both vectors still point at that copy
        push    es
        mov     ax, 0x3508
        int     0x21
        mov     ax, es
        pop     es
        mov     bx, es
        cmp     ax, bx
        je      short unload_ok
        mov     dx, msg_hooked
        jmp     near die
unload_ok:
        call    pit_slow_cli
        push    ds
        mov     dx, [es:old33]
        mov     ax, [es:old33+2]
        mov     ds, ax
        mov     ax, 0x2533
        int     0x21
        pop     ds
        push    ds
        mov     dx, [es:old08]
        mov     ax, [es:old08+2]
        mov     ds, ax
        mov     ax, 0x2508
        int     0x21
        pop     ds
        cmp     byte [es:ps2_on], 0
        je      short unload_nops2
        push    ds
        mov     dx, [es:old15]
        mov     ax, [es:old15+2]
        mov     ds, ax
        mov     ax, 0x2515
        int     0x21
        pop     ds
        push    ds
        mov     dx, [es:old11]
        mov     ax, [es:old11+2]
        mov     ds, ax
        mov     ax, 0x2511
        int     0x21
        pop     ds
        push    ds
        mov     dx, [es:old74]
        mov     ax, [es:old74+2]
        mov     ds, ax
        mov     ax, 0x2574
        int     0x21
        pop     ds
unload_nops2:
        mov     ah, 0x49                 ; ES already points at the block
        int     0x21
        mov     dx, msg_unloaded
        call    puts
        mov     ax, 0
        jmp     near quit

; ==========================================================================
; CH375 BRING-UP.  Returns CF clear with ep_in / cfg_val / hid_if filled in.
; ==========================================================================

; CHECK_EXIST once.  ZF set if the chip answered.  It replies with the
; ones-complement of what it was sent, so 55h -> AAh; an empty slot floats
; to FFh or 00h and fails.
chip_ask:
        mov     al, CMD_CHECK_EXIST
        call    ch_cmd
        mov     al, 0x55
        call    ch_wr
        call    ch_rd
        cmp     al, 0xAA
        ret

ch375_bringup:
        ; --- is a chip there? ---
        ;
        ; RESET AND ASK AGAIN BEFORE DECIDING THERE IS NO CARD.  A chip left
        ; mid-transaction by an earlier program fails CHECK_EXIST on a card
        ; that is fitted and working, and "No CH375 responds at that I/O
        ; address" then sends the reader to the jumpers and the slot.
        ;
        ; It is reachable from this driver's own unload: /U restores the
        ; vectors and the timer but does not quiesce a transfer, so the very
        ; next load can meet a chip that is still thinking about the last
        ; one.  SERPROBE has recovered this way all along; this did not, and
        ; a load-unload-load cycle is exactly what testing a driver is made
        ; of.
        call    chip_ask
        je      short bu_chip
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 200
        call    delay_ms
        call    chip_ask
        je      short bu_chip
        mov     dx, msg_nochip
        jmp     near die
bu_chip:
        mov     al, CMD_GET_IC_VER
        call    ch_cmd
        call    ch_rd
        mov     [ic_ver], al
        cmp     al, 0xB5
        jb      short bu_oldchip
        cmp     al, 0xC0
        jb      short bu_ok
bu_oldchip:
        mov     dx, msg_oldchip
        jmp     near die
bu_ok:
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 100
        call    delay_ms

; --------------------------------------------------------------------------
; The bring-up order is the one the datasheet recommends and CHDIAG proves:
; mode 5 while idle, wait for the device to be noticed, mode 7 to hold the
; bus in reset, mode 6 to run, then wait for the SECOND connect interrupt.
; Waiting for that one rather than sleeping through it is not a nicety --
; the low-speed switch below is ignored until it has been read and cleared.
; --------------------------------------------------------------------------
        mov     al, 5                    ; host mode, no SOF: the idle state
        call    set_mode
        mov     cx, 100
        call    delay_ms
        call    bu_conn
        jnc     short bu_present
        ; No connect interrupt.  Ask outright, in case one arrived before we
        ; were looking and was drained.
        mov     bx, 40                   ; a few seconds
bu_wait:
        mov     al, CMD_TEST_CONNECT
        call    ch_cmd
        call    ch_rd
        cmp     al, INT_CONNECT
        je      short bu_present
        mov     cx, 50
        call    delay_ms
        dec     bx
        jne     short bu_wait
        stc
        ret

bu_present:
        mov     dx, msg_t_conn
        call    bu_trace
        mov     cx, 100
        call    delay_ms
        mov     al, 7                    ; hold the USB bus in reset
        call    set_mode
        mov     cx, 40
        call    delay_ms
        mov     al, 6                    ; host mode, auto SOF
        call    set_mode
        call    bu_conn                  ; the second connect
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

; --------------------------------------------------------------------------
; Drop the bus to 1.5 Mbps if this is a low-speed device -- which nearly
; every USB mouse is.
;
; Neither command used here is in the CH375 part-I datasheet; both are
; documented for the CH376, and this B7 firmware turns out to implement
; them.  0Ah sub-address 07h is GET_DEV_RATE, bit 4 set = 1.5 Mbps.  04h is
; SET_USB_SPEED, data 02h = low speed.
;
; WHERE this sits is the whole trick.  SET_USB_MODE puts the bus back to
; 12 Mbps, so the speed must be set after the last mode change -- but issued
; straight after SET_USB_MODE 6 it is silently ignored, with no error and no
; register change, and every transaction then times out exactly as though
; the chip had no low-speed support at all.  It only takes once the connect
; interrupt raised by the bus reset has been read and cleared, which is what
; bu_conn and the drain above do.  Move either and this stops working while
; looking for all the world like a hardware fault.
; --------------------------------------------------------------------------
        mov     al, 0x0A                 ; GET_DEV_RATE
        call    ch_cmd
        mov     al, 0x07
        call    ch_wr
        call    ch_rd
        mov     dx, msg_t_rate
        call    bu_trace
        test    al, 0x10
        je      short bu_fullspeed
        mov     byte [low_spd], 1
        mov     al, 0x04                 ; SET_USB_SPEED
        call    ch_cmd
        mov     al, 2                    ; 1.5 Mbps low speed
        call    ch_wr
        call    ch_rd                    ; take the operation status it leaves
        mov     cx, 400                  ; and give the bus time to settle at
        call    delay_ms                 ; the new rate before talking on it
        mov     al, 0x0A
        call    ch_cmd
        mov     al, 0x17
        call    ch_wr
        call    ch_rd
        mov     dx, msg_t_r17
        call    bu_trace
        mov     al, 0x0A
        call    ch_cmd
        mov     al, 0x1C
        call    ch_wr
        call    ch_rd
        mov     dx, msg_t_r1c
        call    bu_trace
bu_fullspeed:

        cmp     byte [op_forceep], 0
        je      short bu_enum
        mov     al, [op_ep]              ; /E=n: take the endpoint on trust
        mov     [ep_in], al
        jmp     near bu_ready
bu_enum:

        ; --- device descriptor, at address 0 ---
        mov     bx, 8
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
        mov     dx, msg_t_descr
        call    bu_trace
        mov     cx, 200
        call    delay_ms
        dec     bx
        jne     short bu_dd
        stc
        ret
bu_dd_got:
        mov     di, desc_buf
        mov     bl, 64
        call    ch_read

        ; --- give it an address ---
        mov     al, CMD_SET_ADDRESS
        call    ch_cmd
        mov     al, USB_ADDR
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jnc     short bu_addr_ok
bu_fail_t:                                   ; trampoline: the serial branch
        jmp     bu_fail                      ; below pushed bu_fail out of
bu_addr_ok:                                  ; short reach
        cmp     al, INT_SUCCESS
        jne     short bu_fail_t
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
        jnc     short bu_cfg_ok
bu_fail_t3:                              ; the protocol sniff pushed bu_fail
        jmp     bu_fail                  ; out of short reach again
bu_cfg_ok:
        cmp     al, INT_SUCCESS
        jne     short bu_fail_t3
        mov     di, cfg_buf
        mov     bl, 64
        call    ch_read
        mov     [cfg_len], cl

        call    parse_config
        jc      short bu_fail_t3

        ; --- configure, then put the interface in boot protocol ---
        mov     al, CMD_SET_CONFIG
        call    ch_cmd
        mov     al, [cfg_val]
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jnc     short bu_setcfg_ok
bu_fail_t4:
        jmp     bu_fail
bu_setcfg_ok:
        cmp     al, INT_SUCCESS
        jne     short bu_fail_t4
        mov     cx, 50
        call    delay_ms

        ; A serial adapter needs its port opening; a HID mouse needs the
        ; boot-protocol requests below and would not understand this.
        cmp     byte [ser_mode], SM_HID
        je      short bu_nothid

        ; ASK THE MOUSE WHICH IT IS, at 7N1 first.
        ;
        ; A Microsoft mouse announces itself with 'M' when its power comes
        ; up, and needs seven data bits.  A Mouse Systems mouse announces
        ; nothing and needs eight.  Opening at the wrong width does not
        ; merely mislabel the mouse, it mangles every byte -- so this is
        ; decided before the framing is committed, not inferred from the
        ; stream afterwards.
        ;
        ; Seven first because it is the one with an answer: silence at 7N1
        ; is a real result (Mouse Systems), where silence at 8N1 would be
        ; ambiguous.
        mov     byte [ser_bits], 7
        call    ser_open
        jc      short bu_fail

        ; SET_RETRY 00 BEFORE THE SNIFF, not after it.
        ;
        ; The sniff polls an endpoint, and a poll is exactly what 8F ruins:
        ; with NAKs retried for ever a read on a quiet line never returns,
        ; it times out.  Every iteration of the listen loop then costs a
        ; full timeout and hears nothing, so a Microsoft mouse that said 'M'
        ; perfectly clearly is recorded as silent and gets opened at the
        ; wrong width.
        ;
        ; This is the FIFTH appearance of this bug across these projects and
        ; the second in this file, both times because a new piece of code
        ; polls an endpoint somewhere the existing SET_RETRY did not cover.
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        xor     al, al
        call    ch_wr

        call    ser_sniff                ; CF clear if it said 'M'
        jc      short bu_notms
        mov     byte [ser_proto], SP_MICROSOFT
        jmp     short bu_seropen
bu_notms:
        ; Nothing, so take it as Mouse Systems and re-open at eight bits.
        mov     byte [ser_proto], SP_MOUSESYS
        mov     byte [ser_bits], 8
        call    ser_open
        jc      short bu_fail
bu_seropen:
        mov     cx, 50
        call    delay_ms

        ; SET_RETRY 00 BEFORE ANY ENDPOINT IS POLLED.  This path returns
        ; here instead of falling through to bu_ready, and bu_ready is
        ; where that was done -- so the chip stayed on 8F, RETRY NAKS FOR
        ; EVER, which is right for enumeration and ruinous for polling.
        ;
        ; An idle endpoint then never answers, so every poll ran to
        ; ch_wait's full timeout rather than returning on the NAK, and the
        ; drain does that up to sixteen times per tick at 145 Hz.  The
        ; machine spends its life in the timer interrupt and DOS crawls --
        ; which is a resident driver making the whole computer slow, not a
        ; mouse being imperfect.
        ;
        ; CH375Net hit this three times in one session and moved the fix
        ; into the bring-up so no caller could forget it.  This is the
        ; fourth, in a different project, for exactly the same reason: a
        ; new code path that returns before the shared tail.
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        xor     al, al
        call    ch_wr

        mov     byte [ep_tog], 0x80
        clc
        ret
bu_nothid:

        mov     byte [ep_tog], 0x80
        mov     al, 0x0B                 ; SET_PROTOCOL, wValue 0 = boot
        call    hid_request
        mov     al, 0x0A                 ; SET_IDLE, wValue 0 = report on change
        call    hid_request

bu_ready:
        ; --- from here on a NAK must come back immediately ---
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        mov     al, 0x00
        call    ch_wr

        mov     byte [ep_tog], 0x80
        clc
        ret

bu_fail:
        mov     [last_st], al
        stc
        ret

; --------------------------------------------------------------------------
; A class request to the HID interface with no data stage.  AL = bRequest.
; --------------------------------------------------------------------------
hid_request:
        push    ax
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     al, 0x21                 ; class, interface, host to device
        call    ch_wr
        pop     ax
        call    ch_wr                    ; bRequest
        xor     al, al
        call    ch_wr                    ; wValue lo = 0 (boot / infinite idle)
        call    ch_wr                    ; wValue hi
        mov     al, [hid_if]
        call    ch_wr                    ; wIndex lo = interface
        xor     al, al
        call    ch_wr
        call    ch_wr                    ; wLength = 0
        call    ch_wr

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0x80
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_SETUP
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short hid_req_out
        cmp     al, INT_SUCCESS
        jne     short hid_req_out
        mov     al, CMD_SET_ENDP6        ; the status stage carries DATA1, and
        call    ch_cmd                   ; without saying so the chip reports
        mov     al, 0xC0                 ; a toggle mismatch (2Bh) instead of
        call    ch_wr                    ; success
        mov     al, CMD_ISSUE_TOKEN      ; zero-length IN is the status stage
        call    ch_cmd
        mov     al, PID_IN
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        cmp     al, INT_SUCCESS
        je      short hid_req_out
        cmp     al, 0x2E                 ; STALL
        jne     short hid_req_out
hid_req_stall:
        ; A mouse that does not implement SET_IDLE stalls endpoint 0, and a
        ; stall left set would fail every later control transfer.  Clearing
        ; it costs two commands and makes the request genuinely optional.
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        xor     al, al                   ; endpoint 0
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
hid_req_out:
        ret

; --------------------------------------------------------------------------
; Walk the configuration descriptor for the first HID interface and the
; first interrupt IN endpoint inside it.  CF set if there is no such pair.
; --------------------------------------------------------------------------
parse_config:
        mov     si, cfg_buf
        mov     ch, 0
        mov     cl, [cfg_len]
        cmp     cl, 9
        jae     short pc_len_ok
        jmp     near pc_fail
pc_len_ok:
        mov     al, [si+5]
        mov     [cfg_val], al
        xor     bx, bx                   ; BX = offset
        mov     byte [in_hid], 0
        mov     byte [got_if], 0
        mov     byte [got_ep], 0
pc_loop:
        mov     ax, bx
        add     ax, 2
        cmp     ax, cx
        jbe     short pc_in_range
        jmp     near pc_done
pc_in_range:
        mov     di, cfg_buf
        add     di, bx
        mov     al, [di]                 ; bLength
        cmp     al, 2
        jae     short pc_len2
        jmp     near pc_done
pc_len2:
        mov     ah, [di+1]               ; bDescriptorType
        cmp     ah, 4
        jne     short pc_notif
        mov     ah, [di+5]               ; bInterfaceClass
        cmp     ah, 3                    ; HID
        jne     short pc_notmine
        mov     byte [in_hid], 1
        cmp     byte [got_if], 0
        jne     short pc_next
        mov     byte [got_if], 1
        mov     ah, [di+2]
        mov     [hid_if], ah
        jmp     short pc_next
pc_notmine:
        mov     byte [in_hid], 0
        jmp     short pc_next
pc_notif:
        cmp     ah, 5                    ; ENDPOINT
        jne     short pc_next
        cmp     byte [in_hid], 0
        je      short pc_next
        cmp     byte [got_ep], 0
        jne     short pc_next
        mov     ah, [di+2]               ; bEndpointAddress
        test    ah, 0x80
        je      short pc_next
        mov     al, [di+3]               ; bmAttributes
        and     al, 3
        cmp     al, 3                    ; interrupt
        jne     short pc_next
        and     ah, 0x0F
        mov     [ep_in], ah
        mov     byte [got_ep], 1
pc_next:
        mov     di, cfg_buf
        add     di, bx
        mov     al, [di]
        mov     ah, 0
        add     bx, ax
        jmp     near pc_loop
pc_done:
        cmp     byte [got_ep], 0
        je      short pc_serial
        clc
        ret

; No HID interface with an interrupt IN.  Before giving up, ask whether this
; is a USB-to-serial adapter with a serial mouse behind it.
pc_serial:
        call    ser_detect
        jc      short pc_fail
        clc
        ret
pc_fail:
        stc
        ret

; --------------------------------------------------------------------------
; Listen for about a second for the byte a mouse sends when it powers up.
; CF clear if 'M' arrived.
;
; Runs at install time, in the transient half, where a second is free -- the
; resident driver never does this.
; --------------------------------------------------------------------------
ser_sniff:
        mov     bp, 180                  ; ~1 s at 145 ticks, near enough
snf_loop:
        push    bp
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
        mov     cx, 1500
        call    ch_wait
        pop     bp
        jc      short snf_next
        cmp     al, INT_SUCCESS
        jne     short snf_next

        push    bp
        push    cs
        pop     es
        mov     di, ser_buf
        mov     bl, SER_BUFSZ
        call    ch_read
        pop     bp
        xor     byte [ep_tog], 0x40
        cmp     cl, SER_BUFSZ
        jbe     short snf_fits
        mov     cl, SER_BUFSZ
snf_fits:
        ; Skip the adapter's own status bytes, then look for 'M'.
        mov     al, [ser_hdr]
        cmp     cl, al
        jbe     short snf_next
        mov     ah, 0
        mov     si, ser_buf
        add     si, ax
        sub     cl, al
        mov     ch, 0
snf_byte:
        lodsb
        cmp     al, 'M'
        je      short snf_yes
        loop    snf_byte
snf_next:
        mov     cx, 6
        call    delay_ms
        dec     bp
        jnz     short snf_loop
        stc
        ret
snf_yes:
        clc
        ret

; --------------------------------------------------------------------------
; A vendor request with no data stage.  AL = bRequest, BX = wValue,
; DX = wIndex.  This is how every family except the Keyspan is configured:
; the Keyspan takes a flat block on its own bulk endpoint, everyone else
; uses endpoint 0.
;
; The arguments go to memory first because they have to survive a long run
; of ch_wr calls, and "this helper probably preserves my registers" is the
; kind of assumption that cost a whole diagnosis earlier in this driver.
; --------------------------------------------------------------------------
sc_req:   db 0
sc_val:   dw 0
sc_idx:   dw 0

ser_ctrl:
        mov     [cs:sc_req], al
        mov     [cs:sc_val], bx
        mov     [cs:sc_idx], dx

        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     al, 0x40                 ; vendor, device, host to device
        call    ch_wr
        mov     al, [cs:sc_req]
        call    ch_wr
        mov     al, [cs:sc_val]
        call    ch_wr
        mov     al, [cs:sc_val+1]
        call    ch_wr
        mov     al, [cs:sc_idx]
        call    ch_wr
        mov     al, [cs:sc_idx+1]
        call    ch_wr
        xor     al, al
        call    ch_wr                    ; wLength = 0
        call    ch_wr

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
        jc      short sc_bad
        cmp     al, INT_SUCCESS
        jne     short sc_bad

        ; The status stage carries DATA1 and the chip has to be told, or it
        ; reports a toggle mismatch instead of success.
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
        jc      short sc_bad
        cmp     al, INT_SUCCESS
        jne     short sc_bad
        clc
        ret
sc_bad:
        stc
        ret

; --------------------------------------------------------------------------
; Send CL bytes at SI to a bulk OUT endpoint AL, with its own toggle.
; --------------------------------------------------------------------------
bulk_out_ser:
        push    cx
        push    ax
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, cl
        call    ch_wr
        mov     ch, 0
bo_byte:
        lodsb
        call    ch_wr
        loop    bo_byte
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, [ser_ctog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        pop     ax
        push    ax
        mov     cl, 4
        shl     al, cl
        or      al, PID_OUT
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        ; TEST THE STATUS BEFORE RESTORING ANYTHING.  The first version
        ; popped AX first and then compared AL against INT_SUCCESS -- so it
        ; was testing the ENDPOINT NUMBER, which is never 14h, and reporting
        ; that number as the CH375 status.  "Last CH375 status: 02" is not a
        ; USB status at all; it is endpoint 2 wearing the costume, and it
        ; sent the diagnosis at the device for two rounds.
        mov     [last_st], al
        jc      short bos_bad
        cmp     al, INT_SUCCESS
        jne     short bos_bad
        pop     ax
        pop     cx
        xor     byte [ser_ctog], 0x40        ; DATA0 <-> DATA1
        clc
        ret
bos_bad:
        pop     ax
        pop     cx
        stc
        ret

; --------------------------------------------------------------------------
; Open the serial port at the mouse's framing and RAISE RTS AND DTR.
;
; THE CONTROL LINES ARE THE POWER SUPPLY.  A serial mouse draws its power
; from RTS and DTR, so an adapter left with them low gives a mouse that is
; not broken, not misconfigured, and completely silent -- which reads as a
; wrong baud rate, a bad cable or an unsupported adapter, in that order, for
; as long as it takes somebody to measure the pins.
;
; The Keyspan takes a flat 34-byte block on its own bulk OUT endpoint rather
; than a USB control transfer.  It is "set this flag, then this value" for
; every field, so a block of zeros changes nothing and only the fields
; written below do anything.  The layout is CH375Serial's, reconstructed
; from the Linux keyspan driver and proven there against a modem.
; --------------------------------------------------------------------------
KS_SETCLOCK   equ 0
KS_BAUDLO     equ 1
KS_BAUDHI     equ 2
KS_SETLCR     equ 3
KS_LCR        equ 4
KS_SETRXMODE  equ 5
KS_SETTXMODE  equ 7
KS_SETTXFLOW  equ 9
KS_SETRXFLOW  equ 11
KS_SETRTS     equ 19
KS_RTS        equ 20
KS_SETDTR     equ 21
KS_DTR        equ 22
KS_RXFWDLEN   equ 23
KS_RXFWDTMO   equ 24
KS_TXACK      equ 25
KS_PORTEN     equ 26
KS_RXFLUSH    equ 30
KS_RETSTATUS  equ 33
KS_LEN        equ 34

ser_open:
        cmp     byte [ser_vid], 0xCD         ; low byte of 06CD
        jne     short so_gen_t
        cmp     byte [ser_vid+1], 0x06
        je      short so_keyspan
so_gen_t:
        cmp     word [ser_vid], 0x0403
        je      short so_ftdi_t
        jmp     so_generic
so_ftdi_t:
        jmp     so_ftdi
so_keyspan:

        push    cs
        pop     es
        mov     di, ser_msg
        mov     cx, KS_LEN
        xor     al, al
        cld
        rep     stosb                        ; zeros change nothing

        mov     byte [ser_msg + KS_SETCLOCK], 1
        ; 14,769,231 / (1200 * 16) = 769, which is 0301h.  A mouse is 1200
        ; baud and nothing else; there is no other rate to support.
        mov     byte [ser_msg + KS_BAUDLO], 0x01
        mov     byte [ser_msg + KS_BAUDHI], 0x03
        mov     byte [ser_msg + KS_SETLCR], 1
        ; The 16550 encoding: data bits as (count - 5), so 7N1 is 2 and
        ; 8N1 is 3.  NOT the same as FTDI's, which wants the count itself.
        mov     al, [ser_bits]
        sub     al, 5
        and     al, 3
        mov     [ser_msg + KS_LCR], al
        ; The 16550 LCR: data bits in 0-1 as (bits - 5), so 8 bits is 3.
        mov     byte [ser_msg + KS_SETRXMODE], 1
        mov     byte [ser_msg + KS_SETTXMODE], 1
        mov     byte [ser_msg + KS_SETTXFLOW], 1
        mov     byte [ser_msg + KS_SETRXFLOW], 1
        mov     byte [ser_msg + KS_SETRTS], 1
        mov     byte [ser_msg + KS_RTS], 1
        mov     byte [ser_msg + KS_SETDTR], 1
        mov     byte [ser_msg + KS_DTR], 1
        ; FORWARD A WHOLE REPORT AT A TIME, NOT A BYTE AT A TIME.
        ;
        ; One byte per USB packet looks like the low-latency choice and is
        ; the wrong one for a driver that polls from a timer.  At 1200 baud
        ; the next byte is 8.3 ms away, so a tick reads one byte and is then
        ; NAKed -- which caps the driver at one byte per tick, 145 a second
        ; against a mouse producing 120.  Margin that thin loses bytes at
        ; the first interrupt that runs long, and a serial mouse packet with
        ; a byte missing is not a slightly wrong movement, it is a
        ; resynchronisation and the loss of the whole report.
        ;
        ; Measured at 1: 40% of bytes discarded hunting for a header, and it
        ; stayed at 40% through a bigger buffer, a 16-read drain, and moving
        ; the decode out of the read loop.  The probe tool gets a clean
        ; stream from the same mouse only because it polls flat out in the
        ; foreground, which a resident driver cannot do.
        ;
        ; Five is the size of a report, so the adapter forwards exactly when
        ; one is complete -- no added latency for the thing being waited on
        ; -- and the timeout still flushes a partial report if the mouse
        ; stops mid-packet.
        ; THREE, because that is what a report is on this mouse.  Five was
        ; chosen when the framing was assumed to be Mouse Systems, and it
        ; is one and two thirds of an MM report -- so the adapter was
        ; forwarding across packet boundaries, which is the worst of both:
        ; latency of nearly two reports AND a split in the middle of one.
        ;
        ; The timeout went to 8 at the same time and was self-defeating:
        ; at 1200 baud the bytes are 8.3 ms apart, so the timeout always
        ; won and the adapter sent one byte per packet regardless of the
        ; length setting.  16 lets a whole report gather first.
        mov     byte [ser_msg + KS_RXFWDLEN], 3
        mov     byte [ser_msg + KS_RXFWDTMO], 16
        mov     byte [ser_msg + KS_TXACK], 1
        mov     byte [ser_msg + KS_PORTEN], 1
        mov     byte [ser_msg + KS_RXFLUSH], 1
        mov     byte [ser_msg + KS_RETSTATUS], 1

        ; POWER-CYCLE THE MOUSE, because a serial mouse chooses its
        ; protocol from what it sees at power-up and its power is RTS and
        ; DTR.  Opening once with the lines already high leaves a mouse
        ; that was never reset, and one that has not been reset can come up
        ; in a different mode entirely -- three-byte MM rather than the
        ; five-byte Mouse Systems framing.
        ;
        ; This is not a guess about the mouse; it is the difference between
        ; this driver and MOUPROBE, which opens, closes, waits, and opens
        ; again.  MOUPROBE reads a flawless five-byte stream from this
        ; mouse and the driver read three-byte packets from it in the same
        ; minute.  Two readers, one mouse, two protocols: the reader that
        ; resets it gets the one it asked for.
        push    cs
        pop     ds
        mov     si, ser_msg
        mov     cl, KS_LEN
        mov     al, [ser_ctl]
        push    ax
        ; First, with the lines DOWN: the mouse loses power.
        mov     byte [ser_msg + KS_RTS], 0
        mov     byte [ser_msg + KS_DTR], 0
        mov     byte [ser_msg + KS_PORTEN], 0
        call    bulk_out_ser
        mov     cx, 400
        call    delay_ms
        ; Then with them up again, which is the power-on it decides on.
        mov     byte [ser_msg + KS_RTS], 1
        mov     byte [ser_msg + KS_DTR], 1
        mov     byte [ser_msg + KS_PORTEN], 1
        pop     ax
        push    cs
        pop     ds
        mov     si, ser_msg
        mov     cl, KS_LEN
        call    bulk_out_ser
        pushf
        mov     cx, 300                  ; let it announce itself and settle
        call    delay_ms
        popf
        ret
; --------------------------------------------------------------------------
; FTDI.  Four vendor requests on endpoint 0, and a power cycle in the
; middle of them for the same reason the Keyspan gets one: the mouse is
; powered by RTS and DTR and decides what it is when they come up.
;
; The divisor is 3,000,000/baud held in eighths so the fraction survives,
; with the fractional part encoded into the top two bits of wIndex through
; a lookup that is not in numeric order.  At 1200 baud it comes out exact --
; 3,000,000/1200 is 2500 with no fraction -- so wValue is 09C4 and wIndex
; is zero, and none of that machinery is exercised here.  It is written out
; longhand anyway because the next person will want a different rate.
;
; NOTE THE LCR IS NOT THE KEYSPAN'S.  FTDI puts the actual BIT COUNT in the
; low bits, so 8N1 is 8; the Keyspan wants the 16550 encoding, where 8N1 is
; 3.  Copying one into the other gives a port that opens cleanly and reads
; garbage.
so_ftdi:
        mov     al, 0x00                 ; SIO_RESET, both directions
        xor     bx, bx
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no

        mov     al, 0x03                 ; SET_BAUD_RATE
        mov     bx, 0x09C4               ; 2500 = 1200 baud, exactly
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no

        mov     al, 0x04                 ; SET_DATA: bits 0-7, parity 8-10
        mov     bl, [ser_bits]           ; FTDI wants the COUNT, not (count-5)
        mov     bh, 0
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no

        ; Lines DOWN: the mouse loses power.
        mov     al, 0x01                 ; SET_MODEM_CTRL
        mov     bx, 0x0300               ; DTR and RTS both off, both masked
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no
        mov     cx, 400
        call    delay_ms

        ; Lines UP: this is the power-on the mouse decides on.
        mov     al, 0x01
        mov     bx, 0x0303               ; DTR and RTS both on
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no
        mov     cx, 300
        call    delay_ms
        clc
        ret
so_ftdi_no:
        stc
        ret

so_generic:
        ; Recognised but not opened.  Saying so beats pretending: an adapter
        ; whose port was never enabled delivers nothing, and "no bytes" is
        ; the one symptom this driver cannot tell apart from a dead mouse.
        stc
        ret

; --------------------------------------------------------------------------
; Is this a USB-to-serial adapter we know how to open?
;
; Chosen by USB ID, because these parts have nothing else to go on: the
; interface class is vendor-specific and the strings are not to be trusted.
; That is the same decision USBPKT had to make for the SR9700 and it is
; equally unavoidable here.
;
; The endpoint walk takes the first bulk pair on an interface that is NOT
; mass storage.  Skipping class 08 matters: adapters and network parts alike
; put a driver-CD flash first, with its own bulk pair, and binding to it
; gives a driver that works perfectly and never sees a byte.
; --------------------------------------------------------------------------
ser_detect:
        mov     ax, [desc_buf + 8]
        mov     [ser_vid], ax
        mov     ax, [desc_buf + 10]
        mov     [ser_pid], ax

        mov     ax, [ser_vid]
        cmp     ax, 0x06CD                   ; Keyspan / InnoSys
        je      short sd_keyspan
        cmp     ax, 0x0403                   ; FTDI
        je      short sd_ftdi
        cmp     ax, 0x10C4                   ; Silicon Labs CP210x
        je      short sd_generic
        cmp     ax, 0x067B                   ; Prolific
        je      short sd_generic
        cmp     ax, 0x1A86                   ; WCH CH340/CH341
        je      short sd_generic
        stc
        ret

sd_keyspan:
        ; THE KEYSPAN DECLARES TWO CONFIGURATIONS AND ONLY THE SECOND IS
        ; USABLE.  Its first puts INTERRUPT endpoints where the data should
        ; be; the second declares the same endpoint NUMBERS as bulk.  The
        ; CH375's GET_DESCR shortcut can only fetch configuration index 0,
        ; so the numbers come from that descriptor and the VALUE selected is
        ; the other one -- which works because the addresses agree and only
        ; the types differ.  SERPROBE prints both if this ever stops being
        ; true of a later part.
        mov     byte [cfg_val], 2
        mov     byte [ser_hdr], 1            ; one status byte per IN packet
        ; AND THAT IS WHY THE TYPE FILTER HAS TO GO.  The descriptor being
        ; walked is configuration index 0, where this part declares these
        ; endpoints as INTERRUPT; they are bulk only in configuration 2,
        ; which is the one being selected and the one the CH375's GET_DESCR
        ; shortcut cannot fetch.  Insisting on bulk here finds nothing at
        ; all and fails the whole parse -- which is exactly what it did,
        ; three lines under a comment explaining that the types differ.
        ;
        ; The endpoint NUMBERS agree between the two configurations, which
        ; is what makes this safe, and the CH375 issues a token the same way
        ; for either type in any case.
        mov     byte [ser_anyep], 1
        jmp     short sd_walk
sd_ftdi:
        ; TWO status bytes on the head of EVERY bulk IN packet, including
        ; the ones carrying no data -- which is how an idle FTDI answers
        ; instead of NAKing.  A reader that does not strip them gets
        ; rubbish interleaved with its data and blames the baud rate.
        mov     byte [ser_hdr], 2
        mov     byte [ser_anyep], 0
        jmp     short sd_walk
sd_generic:
        mov     byte [ser_hdr], 0
        mov     byte [ser_anyep], 0
sd_walk:
        ; Walk again, this time for bulk endpoints outside mass storage.
        mov     ch, 0
        mov     cl, [cfg_len]
        xor     bx, bx
        mov     byte [in_hid], 0             ; reused: 1 = inside class 08
        mov     byte [got_ep], 0
        mov     byte [ser_out], 0
        mov     byte [ser_ctl], 0
sw_loop:
        mov     ax, bx
        add     ax, 2
        cmp     ax, cx
        jbe     short sw_in_range
sw_fin:                                      ; a trampoline: sw_done is more
        jmp     sw_done                      ; than 128 bytes below and an
sw_in_range:                                 ; 8086 conditional jump is short
        mov     di, cfg_buf                  ; only.  ecm_walk and sr_walk in
        add     di, bx                       ; CH375Net each needed the same.
        mov     al, [di]                     ; bLength
        cmp     al, 2
        jb      short sw_fin
        mov     ah, [di+1]                   ; bDescriptorType
        cmp     ah, 4
        jne     short sw_notif
        mov     ah, [di+5]                   ; bInterfaceClass
        cmp     ah, 0x08                     ; mass storage: the driver CD
        jne     short sw_ifok
        mov     byte [in_hid], 1
        jmp     short sw_next
sw_ifok:
        mov     byte [in_hid], 0
        jmp     short sw_next
sw_notif:
        cmp     ah, 5                        ; ENDPOINT
        jne     short sw_next
        cmp     byte [in_hid], 0
        jne     short sw_next                ; belongs to the flash
        cmp     byte [ser_anyep], 0
        jne     short sw_typeok
        mov     al, [di+3]
        and     al, 3
        cmp     al, 2                        ; bulk
        jne     short sw_next
sw_typeok:
        mov     ah, [di+2]                   ; bEndpointAddress
        test    ah, 0x80
        jne     short sw_epin
        and     ah, 0x0F
        cmp     byte [ser_out], 0
        jne     short sw_ep2
        mov     [ser_out], ah                ; first bulk OUT: data
        jmp     short sw_next
sw_ep2:
        cmp     byte [ser_ctl], 0
        jne     short sw_next
        mov     [ser_ctl], ah                ; second bulk OUT: control
        jmp     short sw_next
sw_epin:
        cmp     byte [got_ep], 0
        jne     short sw_next
        and     ah, 0x0F
        mov     [ep_in], ah
        mov     byte [got_ep], 1
sw_next:
        mov     di, cfg_buf
        add     di, bx
        mov     al, [di]
        mov     ah, 0
        add     bx, ax
        jmp     sw_loop
sw_done:
        cmp     byte [got_ep], 0
        je      short sw_no
        cmp     byte [ser_out], 0
        je      short sw_no
        ; A part with only one bulk OUT carries its control on endpoint 0
        ; instead; the Keyspan is the one here that needs a second.
        mov     al, [ser_out]
        cmp     byte [ser_ctl], 0
        jne     short sw_ok
        mov     [ser_ctl], al
sw_ok:
        mov     byte [ser_mode], SM_SERIAL
        clc
        ret
sw_no:
        stc
        ret

; --------------------------------------------------------------------------

; Wait for a connect interrupt, about two and a half seconds at most.
; CF clear if it arrived.
bu_conn:
        push    bx
        mov     bx, 20
bu_conn_l:
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short bu_conn_n
        cmp     al, INT_CONNECT
        je      short bu_conn_y
bu_conn_n:
        dec     bx
        jne     short bu_conn_l
        pop     bx
        stc
        ret
bu_conn_y:
        pop     bx
        clc
        ret

; AL = a status byte, DX -> its label.  Prints only under /V.
; AX is saved and restored across the whole thing: crlf ends by writing a
; line feed through putc and so leaves AL = 0Ah.  Callers test the status
; immediately after this returns, and a trace call that quietly changed it
; sent the low-speed switch down the wrong branch for an afternoon.
bu_trace:
        cmp     byte [op_verb], 0
        je      short bu_trace_out
        push    ax
        call    puts
        call    puthex
        call    crlf
        pop     ax
bu_trace_out:
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

drain:                                   ; swallow any pending interrupt
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
        mov     cx, 2
        call    delay_ms
        dec     bx
        jne     short drain_loop
drain_done:
        pop     cx
        ret

; CX milliseconds, at least.  An 8-bit ISA IN is about a microsecond here and
; the loop overhead only makes it longer, so this never undershoots.
delay_ms:
        push    ax
        push    cx
        push    dx
delay_outer:
        push    cx
        mov     cx, 700
delay_inner:
        in      al, 0x61
        loop    delay_inner
        pop     cx
        loop    delay_outer
        pop     dx
        pop     cx
        pop     ax
        ret

; ==========================================================================
; Console output and argument parsing
; ==========================================================================

putc:
        push    dx
        mov     dl, al
        mov     ah, 2
        int     0x21
        pop     dx
        ret

crlf:
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        ret

; Print "USBMOUSE 1.0.0".  Used by the identity line, by the resident banner
; and by /?, so all three cannot drift apart.
print_id:
        mov     dx, msg_prog
        call    puts
        mov     dx, ver_str
        call    puts
        ret

; puts, but for a string in the resident copy (ES) rather than in this one.
puts_es:
        push    ds
        push    es
        pop     ds
        call    puts
        pop     ds
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
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jbe     short puthex1_p
        add     al, 7
puthex1_p:
        call    putc
        ret

puthexw:                                 ; AX
        push    ax
        xchg    al, ah
        call    puthex
        pop     ax
        call    puthex
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

putdec:                                  ; AL, 0..255
        push    ax
        push    bx
        push    cx
        push    dx
        xor     ah, ah
        mov     bx, 10
        xor     cx, cx
putdec_d:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jne     short putdec_d
putdec_p:
        pop     ax
        add     al, '0'
        call    putc
        loop    putdec_p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

report_found:
        cmp     byte [low_spd], 0
        je      short report_fs
        mov     dx, msg_lowspd
        call    puts
report_fs:
        ; Say which KIND of mouse this is.  The line used to read "USB mouse
        ; on CH375 ... HID interface 0" whatever was attached, which on the
        ; serial path is wrong twice over -- it is not a USB mouse and there
        ; is no HID interface -- and the one line a user reads to confirm
        ; the right driver came up should not be describing a different one.
        cmp     byte [ser_mode], SM_HID
        jne     short report_ser
        mov     dx, msg_found
        call    puts
        mov     al, [ep_in]
        call    putdec
        mov     dx, msg_iface
        call    puts
        mov     al, [hid_if]
        call    putdec
        jmp     short report_ids
report_ser:
        mov     dx, msg_proto
        call    puts
        mov     dx, msg_p_ms
        cmp     byte [ser_proto], SP_MICROSOFT
        je      short rs_say
        mov     dx, msg_p_sys
rs_say:
        call    puts
        mov     dx, msg_found_s
        call    puts
        mov     al, [ep_in]
        call    putdec
        mov     dx, msg_serout
        call    puts
        mov     al, [ser_ctl]
        call    putdec
report_ids:
        mov     dx, msg_vidpid
        call    puts
        mov     al, [desc_buf+9]
        call    puthex
        mov     al, [desc_buf+8]
        call    puthex
        mov     al, '/'
        call    putc
        mov     al, [desc_buf+11]
        call    puthex
        mov     al, [desc_buf+10]
        call    puthex
        call    crlf
        ret

; --------------------------------------------------------------------------
parse_args:
        mov     si, 0x81
        mov     cl, [0x80]
        mov     ch, 0
        jcxz    pa_done
pa_loop:
        lodsb
        dec     cx
        cmp     al, ' '
        je      short pa_more
        cmp     al, 9
        je      short pa_more
        cmp     al, '@'
        je      short pa_base_t
        cmp     al, '/'
        je      short pa_slash
        cmp     al, '-'
        je      short pa_slash
pa_more:
        jcxz    pa_done
        jmp     short pa_loop
pa_done:
        ret

; Trampoline.  The parser grew past the 127-byte reach of a short jump back
; to pa_more; widening the jumps would be the wrong fix under mininasm, which
; shortens jumps every pass and never converges on a forced-long one.
pa_more_t:
        jmp     near pa_more
pa_base_t:
        jmp     near pa_base

pa_slash:
        jcxz    pa_done
        lodsb
        dec     cx
        cmp     al, '?'                  ; tested before the upper-casing:
        jne     short pa_notq            ; '?' AND 0DFh is 1Fh, not '?'
        mov     byte [op_help], 1
        jmp     short pa_more_t
pa_notq:
        and     al, 0xDF                 ; upper case
        cmp     al, 'H'
        jne     short pa_noth
        mov     byte [op_help], 1
        jmp     short pa_more_t
pa_noth:
        cmp     al, 'U'
        jne     short pa_s2
        mov     byte [op_unload], 1
        jmp     short pa_more_t
pa_s2:
        cmp     al, 'S'
        jne     short pa_s3
        mov     byte [op_status], 1
        jmp     short pa_more_t
pa_s3:
        cmp     al, 'F'
        jne     short pa_s4
        mov     byte [op_force], 1
        jmp     short pa_more_t
pa_s4:
        cmp     al, 'K'
        jne     short pa_s4a
        mov     byte [op_keep], 1
        jmp     short pa_more_t
pa_s4a:
        cmp     al, 'W'
        jne     short pa_s4b
        mov     byte [op_ps2], 1
        jmp     short pa_more_t
pa_s4b:
        cmp     al, 'V'
        jne     short pa_s5
        mov     byte [op_verb], 1
        jmp     short pa_more_t
pa_s5:
        cmp     al, 'E'
        jne     short pa_s6
        jcxz    pa_e_done
        lodsb                            ; '='
        dec     cx
        jcxz    pa_e_done
        lodsb
        dec     cx
        sub     al, '0'
        cmp     al, 9
        ja      short pa_e_done
        mov     [op_ep], al
        mov     byte [op_forceep], 1
pa_e_done:
        jmp     short pa_more_t

; JCXZ is short-only on an 8086 and the parser has outgrown the reach back to
; pa_done, so the /R handler goes via here.
pa_done_t:
        jmp     near pa_done

pa_s6:
        cmp     al, 'R'
        jne     short pa_more_t3
        jcxz    pa_done_t
        lodsb                            ; skip '='
        dec     cx
        jcxz    pa_done_t
        lodsb
        dec     cx
        sub     al, '0'
        cmp     al, 9
        ja      short pa_more_t3
        mov     ah, al
        mov     al, [si]
        sub     al, '0'
        cmp     al, 9
        ja      short pa_r_one
        inc     si
        dec     cx
        mov     bl, ah
        mov     bh, 10
        push    ax
        mov     al, bl
        mul     bh
        pop     bx
        add     al, bl
        mov     ah, al
pa_r_one:
        cmp     ah, 1
        jb      short pa_more_t3
        cmp     ah, 16
        ja      short pa_more_t3
        mov     [tick_n], ah
        jmp     short pa_more_t3

; Third hop back to pa_more.  The option handlers between here and the first
; trampoline are past a short jump's reach; mininasm re-shortens jumps every
; pass, so widening them would stop the build converging.
pa_more_t3:
        jmp     near pa_more

pa_base:
        xor     bx, bx
pa_base_d:
        jcxz    pa_base_set
        mov     al, [si]
        call    hexval
        jc      short pa_base_set
        inc     si
        dec     cx
        mov     dx, bx
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        shl     bx, 1
        xor     ah, ah
        add     bx, ax
        jmp     short pa_base_d
pa_base_set:
        or      bx, bx
        je      short pa_more_t2
        mov     [io_dat], bx
        inc     bx
        mov     [io_cmd], bx
        jmp     short pa_more_t2

; A second hop for the same reason: the @<hex> parser sits far enough past
; pa_more_t that even the trampoline is out of short reach.
pa_more_t2:
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

; --------------------------------------------------------------------------
die:
        call    puts
        cmp     byte [last_st], 0
        je      short die_now
        mov     dx, msg_laststat
        call    puts
        mov     al, [last_st]
        call    puthex
        call    crlf
die_now:
        mov     ax, 0x4C01
        int     0x21
quit:
        mov     ah, 0x4C
        int     0x21

; --------------------------------------------------------------------------
op_unload:  db  0
op_status:  db  0
op_force:   db  0
op_verb:    db  0
op_help:    db  0
op_ps2:     db  0
op_forceep: db  0
op_ep:      db  0
ic_ver:     db  0
last_st:    db  0
cfg_len:    db  0
in_hid:     db  0
got_if:     db  0
got_ep:     db  0

msg_ok:        db ' resident.  INT 33h installed.', 13, 10, '$'
msg_prog:      db 'USBMOUSE $'
msg_by:        db ' -- StevenC', 13, 10, '$'
msg_t_conn:    db '  connect          : $'
msg_t_conn2:   db '  connect after reset: $'
msg_t_rate:    db '  device rate reg 07 : $'
msg_t_v74:     db '  INT 74h previously  : $'
msg_t_r17:     db '  after speed, reg 17: $'
msg_t_r1c:     db '  after speed, reg 1C: $'
msg_t_descr:   db '  GET_DESCR device   : $'
msg_lowspd:    db 'Low-speed device; USB bus set to 1.5 Mbps.', 13, 10, '$'
msg_found:     db 'USB mouse on CH375: endpoint $'
msg_proto:     db 'Serial mouse: $'
msg_p_ms:      db 'Microsoft, 1200 7N1, 3 bytes.  $'
msg_p_sys:     db 'Mouse Systems, 1200 8N1, 5 bytes.  $'
msg_found_s:   db 'bulk IN $'
msg_serout:    db ', control OUT $'
msg_iface:     db ', HID interface $'
msg_vidpid:    db ', VID/PID $'
msg_already:   db 'USBMOUSE is already loaded.  /U unloads it.', 13, 10, '$'
msg_isres:     db 'Loaded: USBMOUSE $'
msg_isres2:    db '.  live=$'
msg_s_base:    db '  I/O base=$'
msg_s_ep:      db '  endpoint=$'
msg_s_rep:     db '  reports=$'
msg_s_rate:    db '  timer divisor=$'
msg_s_btn:     db '  buttons seen=$'
msg_s_brep:    db '  button reports=$'
msg_s_sread:   db '  serial reads=$'
msg_s_spkt:    db '  packets=$'
msg_s_slost:   db '  bytes resynced past=$'
msg_s_sfull:   db '  BACKLOG (drains that ran out of budget)=$'
msg_ps2:       db 'PS/2 BIOS mouse interface installed (INT 15h/11h/74h).', 13, 10, '$'
msg_s_ps2:     db '  PS/2 interface: enabled=$'
msg_s_ps2h:    db '  handler=$'
msg_s_nobtn:   db 'No button bit has ever arrived from the mouse.  If you have'
               db 13, 10, 'clicked since loading, the press is not reaching the'
               db 13, 10, 'driver at all -- see README, "clicks".', 13, 10, '$'
msg_notres:    db 'USBMOUSE is not loaded.', 13, 10, '$'
msg_unloaded:  db 'USBMOUSE unloaded.', 13, 10, '$'
msg_hooked:    db 'Cannot unload: something else hooked INT 08h after us.', 13, 10, '$'
msg_nochip:    db 'No CH375 responds at that I/O address.', 13, 10, '$'
msg_oldchip:   db 'CH375 revision is older than B5; this driver needs the'
               db 13, 10, 'command-port ready flag that B5 introduced.', 13, 10, '$'
msg_nodev:     db 'No USB mouse enumerated.  Use /F to load anyway and wait'
               db 13, 10, 'for one to be plugged in.', 13, 10, '$'
msg_forced:    db 'No mouse yet; loading anyway and polling for one.', 13, 10, '$'
msg_forceep:   db 'Enumeration skipped; polling endpoint $'
msg_laststat:  db 'Last CH375 status: $'

; Scratch used only by INIT, so it costs no resident memory.
desc_buf:   times 64 db 0
cfg_buf:    times 96 db 0
ser_msg:    times 40 db 0

; The help text lives past the resident end, so however long it gets it costs
; nothing but disk.
msg_help:
        db 'A DOS INT 33h mouse driver for a USB mouse on a CH375.', 13, 10
        db 13, 10
        db '  USBMOUSE            enumerate the mouse and install', 13, 10
        db '  USBMOUSE @nnn       CH375 I/O base in hex        (default 260)', 13, 10
        db '                      /S prints the base the loaded copy took', 13, 10
        db '  USBMOUSE /R=n       PIT divisor, poll rate is 18.2*n Hz  (1-16, default 8)', 13, 10
        db '  USBMOUSE /V         trace every bring-up step and the status it returned', 13, 10
        db '  USBMOUSE /F         install with nothing attached, and keep looking', 13, 10
        db '  USBMOUSE /E=n       skip enumeration, poll endpoint n regardless', 13, 10
        db '  USBMOUSE /K         keep the fast poll rate even when another program', 13, 10
        db '                      hooks the timer after us.  Smoother, but that', 13, 10
        db '                      program then runs its own timers 8x too fast.', 13, 10
        db '  USBMOUSE /W         also present the mouse as a PS/2 BIOS pointing device,', 13, 10
        db '                      so Windows 3.x can see it.  Load before starting Windows.', 13, 10
        db '  USBMOUSE /S         report whether it is loaded, and what the USB side sees', 13, 10
        db '  USBMOUSE /U         unload, restoring INT 33h, INT 08h and the timer rate', 13, 10
        db '  USBMOUSE /?         this help', 13, 10
        db 13, 10
        db 'Options may be combined, in any order:  USBMOUSE @260 /R=4 /V', 13, 10
        db 13, 10
        db 'StevenC   https://github.com/jdredd87/CH375USBToolsTools', 13, 10
        db 'Public domain (the Unlicense).  Do anything you like with it.', 13, 10
        db '$'
