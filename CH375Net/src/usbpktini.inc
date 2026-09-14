; ==========================================================================
; USBPKT -- the transient half: arguments, the safety checks, install,
;          unload and status.  Everything here is released when the driver
;          goes resident and none of it may be reached from the ISR.
;
;   CH375Net, StevenC.  Public domain (the Unlicense).
;
; ONE PROGRAM.  This brings the adapter up itself -- PHY power, clocks, MAC,
; receive path, autonegotiation, link -- and then goes resident, so loading
; the network is a single command the way NE2000.COM is.
;
; It used to require USBLINK to have run first, which was a real limitation
; and never a design: a driver you have to prepare with a second program is
; one somebody will forget to prepare. USBLINK still exists and is still
; the better tool when something is wrong, because it narrates every
; register access; this just gets the machine on the network.
; ==========================================================================

PID_SETUP        equ 0x0D
INT_STALL        equ 0x2E

; --------------------------------------------------------------------------
; Clear endpoint 0.  Required before every control transfer, not tidying:
; CLR_STALL on the CH375 also resets the endpoint's data toggle, and
; without it a transfer that SUCCEEDS leaves endpoint 0 advanced so the
; next one is stalled by the device.  Control transfers then work every
; other time, which reads as a flaky device and is not one.
; --------------------------------------------------------------------------
; AL = the endpoint NUMBER.  Not the USB endpoint address -- no direction
; bit -- because that is what the CH375 wants and what ch375.pas passes:
; ClrStall(AX_EP_BULK_IN) with AX_EP_BULK_IN = 2.
clr_ep:
        push    ax
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        pop     ax
        call    ch_wr
        mov     cx, 0x4000
        call    ch_wait
        ret

clr_ep0:
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     cx, 0x4000
        call    ch_wait
        ret

; --------------------------------------------------------------------------
; How hard the chip tries when a device answers NAK.  8F is "for ever",
; 00 is "report it and move on", and which one is right depends entirely
; on what you are doing:
;
;   control transfers want 8F.  A device that is busy NAKs, and the right
;   response is to ask again -- treating one NAK as a failed transfer means
;   the transfer fails whenever the device happens to be thinking.
;
;   polling an idle endpoint wants 00.  With 8F the chip sits there
;   retrying instead of reporting, the caller's own wait expires, and a
;   poll takes seconds.
;
; USBLINK leaves the chip on 00 because that is what its receive loop
; needs, so this has to put it back to 8F for its own control transfer and
; then set it to 00 again before going resident.  Getting that wrong is
; what made read_mac fail here while the identical request from Pascal
; succeeded four times out of four -- the Pascal had just enumerated, so
; the chip was still on 8F.
; --------------------------------------------------------------------------
; AL = the USB mode.  The readback is not optional and its absence is not
; harmless: SET_USB_MODE leaves a status byte in the data port, and a byte
; nobody collects is still there when the next read happens.  Three modes
; are set during enumeration, so three stale bytes were queued ahead of the
; device descriptor -- which is precisely where this used to fail, with the
; descriptor blamed for a fault three commands upstream.
set_mode:
        push    ax
        mov     al, CMD_SET_USB_MODE
        call    ch_cmd
        pop     ax
        call    ch_wr
        mov     cx, 20
        call    delay_ms
        call    ch_rd
        ret

set_retry:                               ; AL = the retry byte
        push    ax
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        pop     ax
        call    ch_wr
        ret

;--------------------------------------------------------------------------
; ch_wait, recording what came back.  ctrl_in used to leave bu_st holding
; whatever the last high-level command had put there, so both the failure
; message and read_mac's "only a stall needs clearing" test were reading a
; status belonging to an unrelated operation.  FF means no interrupt at all.
;--------------------------------------------------------------------------
ch_waitst:
        call    ch_wait
        jc      short cws_none
        mov     [cs:bu_st], al
        clc
        ret
cws_none:
        mov     byte [cs:bu_st], 0xFF
        stc
        ret

; --------------------------------------------------------------------------
; A control transfer with an IN data stage.  DS:SI -> 8 setup bytes,
; ES:DI -> where the data goes, BL = how many bytes are wanted.
; CF set on failure; on success BH = bytes actually stored.
; --------------------------------------------------------------------------
ctrl_in:
        push    bp
        ; clr_ep0 before the SETUP, because that is what the reference
        ; does.  Setup8 in ch375.pas opens with ClrStall(0) on EVERY
        ; control transfer, in and out alike.
        ;
        ; This used to say the opposite -- that the Pascal clears only
        ; after a stall actually happens, and that clearing up front was
        ; what caused a bring-up to fail at step 7, then 9, then 3, always
        ; with status 2A.  The claim about the Pascal was simply wrong; it
        ; had never been checked against Setup8.  Taking the clear out did
        ; make that particular run go further, which is what made the
        ; mistake stick, but it left USBPKT unable to read the MAC at all
        ; from a device USBLINK had just finished talking to: NAK, 2A,
        ; every time, twenty tries 10 ms apart.
        call    clr_ep0
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     cx, 8
ci_setup:
        lodsb
        call    ch_wr
        loop    ci_setup

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0x80                 ; SETUP is always DATA0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_SETUP
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_waitst
        pushf
        push    ax
        mov     al, 'S'
        call    mark
        pop     ax
        push    ax
        call    markhex
        pop     ax
        popf
        jnc     short __iovr1
        jmp     near ci_fail
__iovr1:
        cmp     al, INT_SUCCESS
        je     short __iovr2
        jmp     near ci_fail
__iovr2:

        ; The data stage starts on DATA1 by spec, and the chip has to be
        ; told: it does not infer it from the SETUP that preceded it.
        mov     bh, 0                    ; stored so far
        mov     bp, 0xC0                 ; the toggle for the next IN
ci_data:
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     ax, bp
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_IN
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_waitst
        pushf
        push    ax
        mov     al, 'I'
        call    mark
        pop     ax
        push    ax
        call    markhex
        pop     ax
        popf
        jc      short ci_fail
        cmp     al, INT_SUCCESS
        jne     short ci_fail
        push    bx
        mov     cl, bl
        sub     cl, bh                   ; room left
        call    ch_read                  ; AL = stored, AH = reported
        push    ax
        mov     al, 'n'
        call    mark
        pop     ax
        push    ax
        call    markhex
        pop     ax
        mov     dl, al
        pop     bx
        add     bh, dl
        xor     bp, 0x40                 ; DATA0 <-> DATA1
        cmp     dl, 8
        jb      short ci_status          ; a short packet ends the stage
        cmp     bh, bl
        jb      short ci_data

ci_status:
        ; The status stage of an IN transfer is an OUT carrying DATA1.
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_OUT
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_waitst
        pop     bp
        clc
        ret
ci_fail:
        push    ax
        call    clr_ep0
        pop     ax
        pop     bp
        stc
        ret

; --------------------------------------------------------------------------
; Read the adapter's MAC into `mac`.  One vendor request: AX_ACCESS_MAC
; with the register in wValue and its length in wIndex, which is unusual
; enough to be worth restating at the one place it is built.
; --------------------------------------------------------------------------
setup_mac:
        db      0xC0                     ; IN, vendor, device
        db      AX_ACCESS_MAC
        dw      AX_NODE_ID               ; wValue  = the register
        dw      6                        ; wIndex  = its length
        dw      6                        ; wLength

read_mac:
        push    cs
        pop     ds

        ; Retry in software, with the chip set to report a NAK rather than
        ; keep asking.  The obvious way round is to set retry to 8F and let
        ; the CH375 be patient for us, and that is what this did first --
        ; but when our own wait then expires we walk away from a chip that
        ; is still retrying in the background, and the NEXT program to open
        ; it finds a transaction in flight that its bring-up does not
        ; expect.  That did not hang USBPKT.  It hung USBLINK, afterwards,
        ; which is a far more confusing thing to debug.
        ;
        ; With 00 the chip answers immediately and is idle between tries,
        ; so twenty attempts, 10 ms apart, cost the same patience and
        ; leave nothing outstanding when they run out.
        ; 8F -- let the CHIP absorb the NAKs.  A device that is busy
        ; answers NAK, and with 00 that is reported as a failed transfer,
        ; which is what 'did not return its MAC address, status 2A' was.
        ; Set back to 00 on every exit below, so nothing is left retrying
        ; in the background for the next program to trip over.
        mov     al, 0x8F
        call    set_retry
        mov     bp, 20
rm_try:
        push    cs
        pop     es
        mov     si, setup_mac
        mov     di, mac
        mov     bl, 6
        call    ctrl_in
        jc      short rm_again
        cmp     bh, 6
        je      short rm_good
rm_again:
        ; Again: only a stall needs clearing.  See ctrl_out_r.
        cmp     byte [cs:bu_st], INT_RET_STALL
        jne     short rm_next
        call    clr_ep0
rm_next:
        ; Wait before trying again, which this did not do.  With retry
        ; set to 00 a NAK comes back immediately, so eight attempts back
        ; to back took microseconds and asked a busy device the same
        ; question eight times in the time it needed to answer once.
        ; That is the whole of 'the adapter did not return its MAC
        ; address' after a clean USBLINK: status 2A, a NAK, every time.
        ; ctrl_out_r and ctrl_in_r have always paused here; this had
        ; simply been missed.
        mov     cx, 10
        call    delay_ms
        dec     bp
        jnz     short rm_try

        ; Out of tries.  Back to 00 and leave the endpoint clear, so
        ; whatever runs next opens a quiet chip with nothing in flight.
        xor     al, al
        call    set_retry
        call    clr_ep0
        stc
        ret
rm_good:
        xor     al, al
        call    set_retry
        clc
        ret

; --------------------------------------------------------------------------
; /V prints one letter as each stage of the bring-up is passed.  Crude on
; purpose: a hang inside a DOS program that has not installed anything is
; invisible from outside -- the machine simply stops answering -- and the
; last letter to reach the screen is the only evidence of where it stopped.
; --------------------------------------------------------------------------
markhex:                                 ; AL in hex, only under /V
        cmp     byte [cs:op_verb], 0
        je      short markhex_out
        call    puthex
markhex_out:
        ret

mark:                                    ; AL = the letter
        cmp     byte [cs:op_verb], 0
        je      short mark_out
        call    putc
mark_out:
        ret


; ==========================================================================
; USB ENUMERATION.
;
; The step the driver was missing when it still expected USBLINK to have
; gone first: reset the chip, bring the bus up, find the device, give it an
; address and select its configuration. Until that has happened the device
; is not addressable and even the first vendor request fails -- which is
; exactly how it failed, at step 1, with the register write blamed.
;
; Modelled on the sequence in USBCOMBO, which has had more hardware time
; than anything else here. The order matters and is WCH's, not mine.
; ==========================================================================

desc_buf:   times 80 db 0
ep0max:     db 8
cfg_val_e:  db 1

; CX milliseconds, near enough. The loop is calibrated by the ISA settling
; read on port 61h, the same one ch_cmd uses.
delay_ms:
        push    ax
        push    cx
        push    dx
        or      cx, cx
        je      short dm_out
dm_outer:
        push    cx
        mov     cx, 120
dm_inner:
        mov     dx, 0x61
        in      al, dx
        loop    dm_inner
        pop     cx
        loop    dm_outer
dm_out:
        pop     dx
        pop     cx
        pop     ax
        ret

; CX = the same "milliseconds" the Pascal bring-up passes to WaitInt: an
; outer count over an inner 400-poll spin, which is not a real time unit
; and is transcribed rather than reinterpreted on purpose.
;
; ch_wait's CX is a bare spin count, so the two are NOT interchangeable and
; the difference is not small -- WaitInt(600) is worth about four times
; ch_wait with CX=0xFFFF, and wait_for(300) was worth four hundred times
; what it was being given.  Approximating this is how the device descriptor
; came to be read before the device was willing to answer.
ch_waitms:
        push    bx
        push    dx
        mov     bx, cx
        mov     dx, [cs:io_cmd]
cwm_outer:
        mov     cx, 400
cwm_inner:
        in      al, dx
        test    al, 0x80
        je      short cwm_got
        loop    cwm_inner
        dec     bx
        jnz     short cwm_outer
        pop     dx
        pop     bx
        stc
        ret
cwm_got:
        pop     dx
        pop     bx
        mov     al, CMD_GET_STATUS
        call    ch_cmd
        call    ch_rd
        clc
        ret

; AH = the status wanted, CX = ms in the sense above.  CF clear if it
; arrived.  A timeout gives up at once rather than trying again: twelve
; tries are for a chip answering with the WRONG status, and a chip that
; answers with nothing at all will not change its mind.
wf_want:    db 0
wait_for:
        mov     [cs:wf_want], ah
        push    bx
        mov     bx, 12
wf_try:
        push    bx
        push    cx
        call    ch_waitms
        pop     cx
        pop     bx
        jc      short wf_none
        mov     ah, [cs:wf_want]
        cmp     al, ah
        je      short wf_got
        dec     bx
        jnz     short wf_try
wf_none:
        pop     bx
        stc
        ret
wf_got:
        pop     bx
        clc
        ret

; AL = a CH375 high-level command, AH = its single argument byte.  Issues
; it, waits, and tries again a few times if it does not come back
; successful.  Same reasoning as ctrl_out_r: the patience lives here rather
; than in the chip's retry register, so giving up leaves nothing in flight.
;
; The command and argument go to memory because ch_cmd needs DX for the
; port and there is no spare register on an 8086 worth the contortion.
chi_cmd:    db 0
chi_arg:    db 0
ch_hi:
        mov     [cs:chi_cmd], al
        mov     [cs:chi_arg], ah
        push    bp
        mov     bp, 6                    ; six tries, as BusUp does
chi_try:
        mov     al, [cs:chi_cmd]
        call    ch_cmd
        mov     al, [cs:chi_arg]
        call    ch_wr
        mov     cx, 600                  ; WaitInt(600), as GetDescrQuick does
        call    ch_waitms
        jnc     short chi_got
        mov     byte [cs:bu_st], 0xFF    ; no interrupt within the wait
        jmp     short chi_next
chi_got:
        mov     [cs:bu_st], al
        cmp     al, INT_SUCCESS
        je      short chi_ok
chi_next:
        mov     cx, 150
        call    delay_ms
        dec     bp
        jnz     short chi_try
        pop     bp
        stc
        ret
chi_ok:
        pop     bp
        clc
        ret

; Put the bus back roughly where a cold boot leaves it.
;
; A bring-up that stops half way leaves the device addressed, part
; configured, and possibly with a control transfer unfinished.  RESET_ALL
; resets the CH375 but does not cut the device's power, so the DEVICE
; remembers all of that -- and the next run then fails at the device
; descriptor instead, which blames the USB side for a fault in the adapter
; bring-up and sends the next hour in the wrong direction.  Ask me how I
; know.  Unplugging is the real cure; this is the nearest thing reachable
; from software, and it is worth doing on every failure path.
usb_down:
        ; Keep the failure that brought us here.  The teardown writes
        ; registers of its own, and without this it overwrites the very
        ; diagnostic the caller is about to print -- which had step 3
        ; reporting a register the teardown touched.
        push    ax
        mov     al, [cs:bu_reg]
        mov     ah, [cs:bu_st]
        mov     [cs:save_reg], al
        mov     [cs:save_st], ah
        pop     ax

        call    clr_ep0
        xor     al, al
        call    set_retry

        ; If the device is up and talking, take it down properly first.
        ; A bus reset alone does not do it: this adapter, left configured
        ; and running, ignores one and then ignores everything afterwards,
        ; at address 0 and at its own address alike.  From outside that is
        ; indistinguishable from a dead card, and the only cure was to
        ; remove its power.
        ;
        ; SET_CONFIGURATION 0 is the teardown the DEVICE acts on: it stops
        ; the receiver and returns it to the Addressed state, where a bus
        ; reset means what the specification says it means.  Skipped when
        ; nothing was ever brought up, because then there is nothing to
        ; tell and the attempt only costs time.
        cmp     byte [cs:dev_live], 0
        je      short ud_nodev
        mov     byte [cs:dev_live], 0
        mov     al, AX_RX_CTL            ; stop the receiver
        xor     bx, bx
        call    ax_wr16
        mov     al, CMD_SET_CONFIG       ; and unconfigure
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     cx, 100
        call    ch_waitms
        mov     cx, 50
        call    delay_ms
ud_nodev:

        mov     al, CMD_SET_USB_ADDR     ; host side back to address 0
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     al, 7                    ; hold the bus in reset
        call    set_mode
        mov     cx, 250                  ; generously: the point is that the
        call    delay_ms                 ; DEVICE notices, not the chip
        mov     al, 5                    ; then idle, as a fresh chip is
        call    set_mode
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 60
        call    delay_ms

        ; Give the caller back the failure that brought us here.  Without
        ; this the teardown's own register writes are what gets reported,
        ; and step 7 spent an evening blaming register 0B -- which is the
        ; receiver-stop three lines above, not anything step 7 touches.
        push    ax
        mov     al, [cs:save_reg]
        mov     ah, [cs:save_st]
        mov     [cs:bu_reg], al
        mov     [cs:bu_st], ah
        pop     ax
        ret

; GET_DESCR for the device descriptor at whatever address the host side is
; currently set to.  CF set if nothing answered.
adopted:    db 0

; Set once the device is enumerated and configured, cleared by usb_down.
; It is what tells a teardown whether there is anybody there to tell.
dev_live:   db 0
try_descr:
        mov     al, CMD_GET_DESCR
        mov     ah, 1
        call    ch_hi
        jc      short td_bad
        push    cs
        pop     es
        mov     di, desc_buf
        mov     cl, 64
        call    ch_read
        clc
        ret
td_bad:
        stc
        ret

usb_enum:
        ; ---- the chip itself ----
        mov     byte [cs:bu_step], 20
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 60
        call    delay_ms
        mov     al, CMD_GET_IC_VER
        call    ch_cmd
        call    ch_rd
        cmp     al, 0xB5
        jae     short __uev1
        jmp     near ue_bad
__uev1:
        cmp     al, 0xC0
        jb     short __uev2
        jmp     near ue_bad
__uev2:

        ; ---- host mode, and the first connect ----
        mov     byte [cs:bu_step], 21
        mov     al, 5
        call    set_mode
        mov     ah, INT_CONNECT
        mov     cx, 300
        call    wait_for
        jnc     short ue_conn
        ; No interrupt, so ask the chip directly -- a device already
        ; attached when the chip was reset does not always raise one.
        mov     al, CMD_TEST_CONNECT
        call    ch_cmd
        call    ch_rd
        cmp     al, INT_CONNECT
        je     short __uev3
        jmp     near ue_bad
__uev3:
ue_conn:

        ; ---- hold the bus in reset, then let it go ----
        mov     byte [cs:bu_step], 22
        mov     cx, 100
        call    delay_ms
        mov     al, 7
        call    set_mode
        ; How long the bus is held in reset decides whether a device that
        ; is already up goes back to the Default state or carries on
        ; ignoring us.  40 ms is what the Pascal uses and it is enough for
        ; a device that has just been plugged in; it is not always enough
        ; for one an earlier run left configured and busy.  Each attempt
        ; therefore holds it longer than the last: 40 ms, then 250, then
        ; 600.  The specification's minimum is 10 ms, so none of these is
        ; unreasonable -- they are just more patient than the happy path
        ; needs to be.
        mov     cx, [cs:reset_hold]
        call    delay_ms
        mov     al, 6
        call    set_mode
        mov     ah, INT_CONNECT
        mov     cx, 400
        call    wait_for                 ; a second connect is normal, and
        mov     cx, 200                  ; its absence is not fatal
        call    delay_ms

        ; Let the chip retry NAKs while enumerating: a device still waking
        ; up should be waited for, and this is what the Pascal bring-up
        ; does.  read_mac's warning about 8F stands, so ue_bad below puts
        ; it back to 00 -- the danger was never 8F itself, it was walking
        ; away from a chip still set to it.
        mov     al, 0x8F
        call    set_retry

        ; ---- the device descriptor, for the endpoint-0 packet size ----
        ;
        ; Two attempts, at two addresses, and the second one is the whole
        ; reason this program can be run twice.
        ;
        ; A bus reset is supposed to put every device back in the Default
        ; state answering at address 0.  An adapter that a previous run
        ; left configured and running does not always oblige -- the CH375's
        ; reset does not cut its power, and mode 7 does not reliably
        ; persuade a device that is already up to forget where it was.  It
        ; sits there, still at the address the last run gave it, ignoring
        ; everything sent to address 0.  From the outside that is
        ; indistinguishable from a dead adapter: no interrupt at all, and a
        ; failure at the device descriptor that blames the card.
        ;
        ; It cost a power cycle between every single test before this was
        ; understood.  So: ask at address 0, and if nothing answers, ask
        ; again at the address we would have given it.  A device that
        ; replies there is not broken, it is just already dressed.
        mov     byte [cs:bu_step], 23
        call    try_descr
        jnc     short ue_at0
        mov     al, CMD_SET_USB_ADDR
        call    ch_cmd
        mov     al, USB_ADDR
        call    ch_wr
        mov     cx, 20
        call    delay_ms
        call    try_descr
        jnc     short ue_adopt
        ; Neither address answers.  Put the host side back to 0 so the
        ; state we leave behind is the one the next attempt expects.
        mov     al, CMD_SET_USB_ADDR
        call    ch_cmd
        xor     al, al
        call    ch_wr
        jmp     near ue_bad
ue_at0:
        mov     byte [cs:adopted], 0
        jmp     short ue_gotdesc
ue_adopt:
        mov     byte [cs:adopted], 1
ue_gotdesc:
        mov     al, [cs:desc_buf + 7]
        or      al, al
        jne     short ue_ep0
        mov     al, 8
ue_ep0:
        mov     [cs:ep0max], al

        ; ---- give it an address, and tell the chip about it ----
        ; Unless it already has one and we joined it there, in which case
        ; setting it again is at best a no-op and at worst another way to
        ; upset a device that is currently working.
        cmp     byte [cs:adopted], 0
        je      short ue_doaddr
        jmp     short ue_addrdone
ue_doaddr:
        mov     byte [cs:bu_step], 24
        mov     al, CMD_SET_ADDRESS
        mov     ah, USB_ADDR
        call    ch_hi
        jnc     short __uev6
        jmp     near ue_bad
__uev6:
        mov     al, CMD_SET_USB_ADDR
        call    ch_cmd
        mov     al, USB_ADDR
        call    ch_wr
        mov     cx, 20
        call    delay_ms
ue_addrdone:

        ; ---- CDC-ECM, asked BEFORE anything is configured ----
        ;
        ; THE ORDER HERE IS LOAD-BEARING, and it was found the hard way.
        ; This used to run after the vendor configuration had been
        ; selected, and it worked intermittently -- which is the worst way
        ; for it to be wrong, because two runs of the same binary on the
        ; same adapter disagreed.
        ;
        ; The trace says why.  On a device that has not been configured the
        ; device descriptor reads `n12 03`: eighteen bytes,
        ; bNumConfigurations = 3.  Once the vendor configuration has been
        ; selected the same read gives `n12 01`, and the two configurations
        ; carrying CDC-NCM and CDC-ECM are simply not there to be found.
        ; The probe then concluded, correctly on the evidence, that this
        ; adapter has no ECM function.
        ;
        ; So: SELECTING A CONFIGURATION IS NOT A READ-ONLY ACT, and any
        ; question about what a device can do has to be asked before one is
        ; chosen.  ECMLINK never hit this because it enumerates from a bus
        ; reset every time and asks immediately.
        cmp     byte [cs:op_noecm], 0
        jne     short ue_novecm
        call    ecm_probe
        jc      short ue_novecm
        call    ecm_bring
        jc      short ue_ecmbad
        jmp     __uev10                  ; ecm_bring has already chosen its
                                         ; configuration, so skip the one
                                         ; below and join the common tail
ue_ecmbad:
        call    link_defaults
ue_novecm:

        ; ---- SR9700 / DM9601, asked next and for the same reason ----
        ;
        ; Before a configuration is chosen, because sr_probe reads the
        ; configuration descriptor to find the endpoints and SELECTING A
        ; CONFIGURATION IS NOT A READ-ONLY ACT -- the note above ecm_probe
        ; records what that cost to learn.
        ;
        ; After ECM rather than before it, because a device that offers
        ; both should use the class path: it is the one that does not
        ; depend on a table of USB IDs being right.
        call    sr_probe
        jc      short ue_nosr
        call    sr_bring
        jc      short ue_srbad
        jmp     __uev10                  ; sr_bring has chosen its own
                                         ; configuration; join the tail
ue_srbad:
        call    link_defaults
ue_nosr:

        ; ---- the configuration descriptor, for its value ----
        mov     byte [cs:bu_step], 25
        mov     al, CMD_GET_DESCR
        mov     ah, 2
        call    ch_hi
        jnc     short __uev8
        jmp     near ue_bad
__uev8:
        push    cs
        pop     es
        mov     di, desc_buf
        mov     cl, 80
        call    ch_read
        mov     al, [cs:desc_buf + 5]    ; bConfigurationValue
        or      al, al
        jne     short ue_cfgv
        mov     al, 1
ue_cfgv:
        mov     [cs:cfg_val_e], al

        ; ---- select it. Without this the device has an address and no
        ; endpoints: control transfers to endpoint 0 work perfectly and
        ; everything else times out. ----
        mov     byte [cs:bu_step], 26
        mov     al, CMD_SET_CONFIG
        mov     ah, [cs:cfg_val_e]
        call    ch_hi
        jnc     short __uev10
        jmp     near ue_bad
__uev10:
        mov     cx, 50
        call    delay_ms
        mov     byte [cs:dev_live], 1

        ; Back to reporting NAKs rather than retrying them.  This is not a
        ; tuning choice: see the note in read_mac.  A chip left on 8F is
        ; still retrying in the background after our own wait expires, and
        ; the next program to open it finds a transaction in flight.
        xor     al, al
        call    set_retry

        mov     byte [cs:bu_step], 0
        clc
        ret
ue_bad:
        call    usb_down
        stc
        ret


; ==========================================================================
; THE BRING-UP, so this is one program and not two.
;
; It used to require USBLINK to have run first. That is a fine way to
; develop and a poor thing to ship: a driver you have to prepare with a
; second program is one somebody will forget to prepare, and the failure
; when they do is a machine with no network and no clue why.
;
; All of it lives in the transient half. It runs once, at install, and goes
; back to DOS with everything else here -- there is no reason for a page of
; one-shot register writes to sit in memory for the rest of the day.
; ==========================================================================

; DS:SI -> 8 setup bytes, ES:DI -> data to send, BL = how many (0 = none).
ctrl_out_n:
        ; clr_ep0 before the SETUP, matching Setup8 in ch375.pas, which
        ; opens every control transfer with ClrStall(0).  See the longer
        ; note in ctrl_in for why this was taken out and put back.
        call    clr_ep0
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     cx, 8
co_setup:
        lodsb
        call    ch_wr
        loop    co_setup

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
        jc      short co_fail
        cmp     al, INT_SUCCESS
        jne     short co_fail

        or      bl, bl
        je      short co_status
        ; The data stage starts on DATA1 by spec and the chip has to be
        ; told: it does not infer that from the SETUP before it.
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, bl
        call    ch_wr
        push    si
        mov     si, di
        mov     cl, bl
        xor     ch, ch
co_data:
        mov     al, [es:si]
        call    ch_wr
        inc     si
        loop    co_data
        pop     si
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_OUT
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short co_fail
        cmp     al, INT_SUCCESS
        jne     short co_fail

co_status:
        ; The status stage of an OUT is an IN carrying DATA1.
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
        clc
        ret
co_fail:
        mov     [cs:bu_st], al
        cmp     al, INT_RET_STALL
        jne     short co_fail_out
        push    ax
        call    clr_ep0                  ; only a stall needs clearing
        pop     ax
co_fail_out:
        stc
        ret

bu_reg:     db 0                         ; register of the last access
bu_st:      db 0                         ; what the CH375 said about it
save_reg:   db 0                         ; ...held across a teardown
save_st:    db 0

; --------------------------------------------------------------------------
; The same control transfers, with the patience that read_mac already has.
;
; A register write lands on a device that is still digesting the one before
; it, and a busy device NAKs.  One NAK used to fail the whole bring-up --
; which is how an innocent 8-bit write to the pause watermark came to be
; blamed for a fault that was really about timing.
;
; The tempting fix is to set the chip's retry to 8F and let it be patient
; for us.  Do not: read_mac explains at length why that wedges the ADAPTER
; and shows up as a failure in the NEXT program to run, not this one.  With
; retry at 00 the chip answers immediately and sits idle between attempts,
; so the loop below costs the same patience and leaves nothing in flight
; when it gives up.
;
; Every attempt restarts at the SETUP packet, and clr_ep0 at the top of
; ctrl_out_n/ctrl_in resets the endpoint toggle, so a retry is a clean
; transfer rather than a resumption of a broken one.
; --------------------------------------------------------------------------
ctrl_out_r:
        push    bp
        ; Let the CHIP absorb NAKs for the duration, and put it back to
        ; 00 before returning.  A register access is a control transfer,
        ; and a device that is busy answers NAK -- with the chip set to
        ; report those rather than retry them, one NAK is a failed
        ; transfer.  Same fix, same reason, as read_mac; the comment
        ; above set_retry has said 'control transfers want 8F' all along.
        mov     al, 0x8F
        call    set_retry
        mov     bp, 12
cor_try:
        push    si
        push    di
        push    bx
        call    ctrl_out_n
        pop     bx
        pop     di
        pop     si
        jnc     short cor_ok
        ; Clear the endpoint ONLY after a stall.  clr_ep0 makes the CH375
        ; issue a real CLEAR_FEATURE transfer, and firing one at a device
        ; that just answered NAK -- which means "busy, ask again" -- gives
        ; it more work instead of less.  This is the same mistake that was
        ; found and fixed in the main path; it sat here on the retry path
        ; the whole time, which is why the bring-up still failed at a
        ; different step every run.
        cmp     byte [cs:bu_st], INT_RET_STALL
        jne     short cor_wait
        call    clr_ep0
cor_wait:
        mov     cx, 10
        call    delay_ms
        dec     bp
        jnz     short cor_try
        call    clr_ep0
        xor     al, al
        call    set_retry
        pop     bp
        stc
        ret
cor_ok:
        ; Let the write land before the next one is issued.  The Pascal
        ; bring-up has no retry and needs none, because it prints a trace
        ; line between every register access and that print is worth
        ; several milliseconds.  Nothing here prints, so a rapid row of
        ; writes finds the device still busy and gets a NAK -- which looks
        ; like a fault in whichever register happened to be next, rather
        ; than in the ones before it.  It read as the wake-on-LAN register,
        ; then as ANAR; it was neither.
        ;
        ; A PHY write is an MDIO transaction behind the USB one and is
        ; slower again, so this is sized for the slower of the two.
        mov     cx, 5
        call    delay_ms
        xor     al, al
        call    set_retry
        pop     bp
        clc
        ret

ctrl_in_r:
        push    bp
        ; Let the CHIP absorb NAKs for the duration, and put it back to
        ; 00 before returning.  A register access is a control transfer,
        ; and a device that is busy answers NAK -- with the chip set to
        ; report those rather than retry them, one NAK is a failed
        ; transfer.  Same fix, same reason, as read_mac; the comment
        ; above set_retry has said 'control transfers want 8F' all along.
        mov     al, 0x8F
        call    set_retry
        mov     bp, 8
cir_try:
        push    si
        push    di
        push    bx
        call    ctrl_in
        pop     bx
        pop     di
        pop     si
        jnc     short cir_ok
        ; Clear the endpoint ONLY after a stall.  clr_ep0 makes the CH375
        ; issue a real CLEAR_FEATURE transfer, and firing one at a device
        ; that just answered NAK -- which means "busy, ask again" -- gives
        ; it more work instead of less.  This is the same mistake that was
        ; found and fixed in the main path; it sat here on the retry path
        ; the whole time, which is why the bring-up still failed at a
        ; different step every run.
        cmp     byte [cs:bu_st], INT_RET_STALL
        jne     short cir_wait
        call    clr_ep0
cir_wait:
        mov     cx, 10
        call    delay_ms
        dec     bp
        jnz     short cir_try
        call    clr_ep0
        xor     al, al
        call    set_retry
        pop     bp
        stc
        ret
cir_ok:
        xor     al, al
        call    set_retry
        pop     bp
        clc
        ret

; One setup buffer serves every request, assembled on the spot.
bu_setup:   times 8 db 0
bu_data:    times 8 db 0
bu_step:    db 0

; AL = register, BL = length, payload already in bu_data.
ax_mac_wr:
        mov     [cs:bu_reg], al
        mov     [cs:bu_setup+0], byte 0x40       ; OUT, vendor, device
        mov     [cs:bu_setup+1], byte AX_ACCESS_MAC
        mov     [cs:bu_setup+2], al              ; wValue = the register
        mov     [cs:bu_setup+3], byte 0
        mov     [cs:bu_setup+4], bl              ; wIndex = its length
        mov     [cs:bu_setup+5], byte 0
        mov     [cs:bu_setup+6], bl              ; wLength
        mov     [cs:bu_setup+7], byte 0
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     si, bu_setup
        mov     di, bu_data
        call    ctrl_out_r
        ret

ax_wr16:                                 ; AL = register, BX = value
        mov     [cs:bu_data+0], bl
        mov     [cs:bu_data+1], bh
        mov     bl, 2
        call    ax_mac_wr
        ret

ax_wr8:                                  ; AL = register, BL = value
        mov     [cs:bu_data+0], bl
        mov     bl, 1
        call    ax_mac_wr
        ret

ax_phy_wr:                               ; AL = PHY register, BX = value
        mov     [cs:bu_reg], al
        mov     [cs:bu_setup+0], byte 0x40
        mov     [cs:bu_setup+1], byte AX_ACCESS_PHY
        mov     [cs:bu_setup+2], byte AX_PHY_ID  ; wValue = the PHY address
        mov     [cs:bu_setup+3], byte 0
        mov     [cs:bu_setup+4], al              ; wIndex = the register
        mov     [cs:bu_setup+5], byte 0
        mov     [cs:bu_setup+6], byte 2
        mov     [cs:bu_setup+7], byte 0
        mov     [cs:bu_data+0], bl
        mov     [cs:bu_data+1], bh
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     si, bu_setup
        mov     di, bu_data
        mov     bl, 2
        call    ctrl_out_r
        ret

ax_phy_rd:                               ; AL = PHY register -> BX
        mov     [cs:bu_setup+0], byte 0xC0       ; IN, vendor, device
        mov     [cs:bu_setup+1], byte AX_ACCESS_PHY
        mov     [cs:bu_setup+2], byte AX_PHY_ID
        mov     [cs:bu_setup+3], byte 0
        mov     [cs:bu_setup+4], al
        mov     [cs:bu_setup+5], byte 0
        mov     [cs:bu_setup+6], byte 2
        mov     [cs:bu_setup+7], byte 0
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     si, bu_setup
        mov     di, bu_data
        mov     bl, 2
        call    ctrl_in_r
        jc      short apr_bad
        mov     bl, [cs:bu_data+0]
        mov     bh, [cs:bu_data+1]
        clc
        ret
apr_bad:
        stc
        ret

; Wait for the BIOS tick counter to change AL times.  Coarse -- a tick is
; 55 ms -- and deliberately so: every delay in this sequence is a minimum
; the chip needs rather than a maximum, and the PIT has not been touched
; yet at this point.
;
; Note what AL actually buys you.  The first change can come immediately,
; so AL=1 guarantees NOTHING; AL=n guarantees n-1 whole ticks.  Callers
; here pass n+1 for that reason.  Getting this wrong cost an evening of
; intermittent step-2 failures.
delay_ticks:
        push    ax
        push    bx
        push    cx
        push    dx
        push    es
        xor     cx, cx
        mov     es, cx
        mov     cl, al
        xor     ch, ch
        jcxz    dt_out
dt_one:
        mov     bx, [es:0x46C]
dt_spin:
        mov     dx, [es:0x46C]
        cmp     dx, bx
        je      short dt_spin
        loop    dt_one
dt_out:
        pop     es
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; The whole sequence. CF set on failure, with bu_step naming the stage --
; "initialisation failed" on its own sends somebody to look at the cable.
enum_tries: db 0
reset_hold: dw 40


; ==========================================================================
; CDC-ECM -- the CLASS path.
;
; Everything above this point drives one chip family.  This drives a
; STANDARD: the device describes itself, and the same code brings up an
; adapter from any vendor that implements the class.
;
; It is here because the AX88179A made the case unanswerable.  That part
; reports 0B95:1790 -- the AX88179's own USB ID -- and its vendor path
; collects bursts and delivers no frames out of them.  The same adapter
; offers CDC-ECM as a configuration, and through it, it works.  So the
; adapter is fine and the ID is worthless; what the descriptors say is the
; only thing worth asking.
;
; NOTHING HERE IS SPECIFIC TO THAT ADAPTER.  The configuration value, both
; interface numbers, the alternate setting, both bulk endpoints and the
; MAC's string index are read out of the descriptors.  Hardcoding the ones
; this device happens to use would have worked on it alone and thrown away
; the entire point of writing a class driver.
;
; ecm.pas and ECMLINK prove the same protocol in Pascal and are where to
; debug it from: they can print, and this cannot -- it runs before anything
; is installed and its failures are a machine that stops answering.
; ==========================================================================

ECM_MAXCFG      equ 200          ; ctrl_in takes a BYTE length, so a
                                 ; configuration bigger than this cannot be
                                 ; read whole.  Real ECM configurations are
                                 ; 70-90 bytes; this is headroom, not a fit.

ecm_setup:  times 8 db 0         ; a setup packet built by hand
ecm_cfgv:   db  0                ; bConfigurationValue holding the function
ecm_ctlif:  db  0                ; the communications interface
ecm_dif:    db  0                ; the CDC-data interface
ecm_alt:    db  0                ; its alt setting that HAS endpoints
ecm_epi:    db  0                ; bulk IN endpoint number
ecm_epo:    db  0                ; bulk OUT
ecm_maci:   db  0                ; iMACAddress string index
ecm_epint:  db  0                ; interrupt IN endpoint, 0 = none
ecm_ncfg:   db  0
ecw_len:    db  0                ; bLength of the descriptor being walked
ecm_glen:   db  0                ; wLength of the descriptor being fetched

; --------------------------------------------------------------------------
; One GET_DESCRIPTOR, into rxbuf.
;   AH = type, AL = index, DX = wIndex (language id), CL = how many bytes.
; Returns BH = bytes stored, CF set on failure.
;
; rxbuf is borrowed deliberately: it is 2048 bytes of resident buffer that
; cannot be in use yet, because nothing is receiving until this finishes.
; desc_buf is 80 bytes and this adapter's ECM configuration is exactly 80 --
; which would have fitted, and would have been a trap for the next device.
; --------------------------------------------------------------------------
ecm_get:
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     di, ecm_setup
        mov     byte [di], 0x80          ; IN, standard, device
        mov     byte [di+1], 6           ; GET_DESCRIPTOR
        mov     [di+2], al               ; wValue low  = index
        mov     [di+3], ah               ; wValue high = type
        mov     [di+4], dl               ; wIndex = language, or zero
        mov     [di+5], dh
        mov     [di+6], cl               ; wLength
        mov     byte [di+7], 0
        mov     [ecm_glen], cl

        ; Retried, for the same reason read_mac is: a device that is busy
        ; answers NAK, the chip is deliberately set to REPORT that rather
        ; than absorb it, and a single attempt therefore reads a perfectly
        ; healthy device as absent.  Asking once is how the first build of
        ; this fell through to the vendor path on an adapter whose
        ; descriptors were there all along.
        mov     bp, 12
ecmg_try:
        push    bp
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     si, ecm_setup
        mov     di, rxbuf
        mov     bl, [cs:ecm_glen]
        call    ctrl_in
        pop     bp
        jnc     short ecmg_ok
        cmp     byte [cs:bu_st], INT_RET_STALL
        jne     short ecmg_wait
        call    clr_ep0
ecmg_wait:
        mov     cx, 10
        call    delay_ms
        dec     bp
        jnz     short ecmg_try
        stc
        ret
ecmg_ok:
        clc
        ret

; --------------------------------------------------------------------------
; Walk one configuration's descriptors, already in rxbuf.  CX = how many
; bytes.  CF clear if this configuration holds a usable ECM function.
; --------------------------------------------------------------------------
ecm_walk:
        mov     di, cx                   ; DI = end of the buffer
        xor     si, si                   ; SI = offset of this descriptor
        xor     dl, dl                   ; bit0 = ECM control seen
                                         ; bit1 = a data alt chosen
        xor     bx, bx                   ; BL = current interface number
                                         ; BH = current alt setting
ecw_loop:
        mov     ax, si
        inc     ax
        inc     ax
        cmp     ax, di
        ja      short ecw_fin
        mov     al, [si + rxbuf]         ; bLength
        or      al, al
        je      short ecw_fin            ; a zero length would never advance
        mov     [ecw_len], al
        xor     ah, ah
        mov     cx, si
        add     cx, ax
        cmp     cx, di
        jbe     short ecw_inb            ; this one runs off the end, so no
ecw_fin:                                 ; field in it can be trusted
        jmp     ecw_end
ecw_inb:
        mov     al, [si + rxbuf + 1]     ; bDescriptorType

        ; The dispatch goes through NEAR jumps and each arm returns through
        ; its own local trampoline.  On an 8086 every conditional jump is
        ; short -- 128 bytes -- and these arms are bigger than that, so the
        ; obvious `je short ecw_iface` stops assembling the moment one of
        ; them grows.  Writing it this way now costs three bytes an arm and
        ; means the next person to add a descriptor type does not have to
        ; rediscover it.
        cmp     al, 4                    ; INTERFACE
        jne     short ecw_d1
        jmp     ecw_iface
ecw_d1:
        test    dl, 1
        je      short ecw_next           ; nothing before the ECM control
                                         ; interface can belong to it
        cmp     al, 0x24                 ; CS_INTERFACE
        jne     short ecw_d2
        jmp     ecw_cs
ecw_d2:
        cmp     al, 5                    ; ENDPOINT
        jne     short ecw_next
        jmp     ecw_ep
ecw_next:
        mov     al, [ecw_len]
        xor     ah, ah
        add     si, ax
        jmp     short ecw_loop

ecw_iface:
        cmp     byte [ecw_len], 9
        jb      short ecwi_out
        mov     bl, [si + rxbuf + 2]     ; bInterfaceNumber
        mov     bh, [si + rxbuf + 3]     ; bAlternateSetting
        mov     al, [si + rxbuf + 5]     ; bInterfaceClass
        mov     ah, [si + rxbuf + 6]     ; bInterfaceSubClass
        cmp     al, 2                    ; Communications
        jne     short ecw_ifdata
        cmp     ah, 6                    ; Ethernet Networking Control Model
        jne     short ecw_ifdata
        or      dl, 1
        mov     [ecm_ctlif], bl
        mov     al, [rxbuf + 5]          ; bConfigurationValue, from the
        mov     [ecm_cfgv], al           ; configuration descriptor itself
ecwi_out:
        jmp     ecw_next
ecw_ifdata:
        test    dl, 1
        je      short ecwi_out
        test    dl, 2
        jne     short ecwi_out           ; keep the FIRST endpoint-bearing
                                         ; alt.  A device may offer several
                                         ; at different bandwidths, and
                                         ; without this the walk silently
                                         ; ends up on whichever came last
        cmp     al, 0x0A                 ; CDC data
        jne     short ecwi_out
        mov     al, [si + rxbuf + 4]     ; bNumEndpoints
        cmp     al, 2
        jb      short ecwi_out           ; alt 0 has NONE, by design -- an
                                         ; idle ECM device reserves no bus
                                         ; bandwidth.  Selecting it and
                                         ; wondering why nothing moves is
                                         ; the classic ECM mistake
        or      dl, 2
        mov     [ecm_dif], bl
        mov     [ecm_alt], bh
        jmp     short ecwi_out

ecw_cs:
        cmp     byte [ecw_len], 13
        jb      short ecwc_out
        mov     al, [si + rxbuf + 2]     ; bDescriptorSubtype
        cmp     al, 0x0F                 ; Ethernet Networking functional
        jne     short ecwc_out
        ; The MAC is in a STRING descriptor and this carries its index.
        ; Not a register, not a field here -- the class spec really does
        ; put a hardware address in a string, as twelve hex characters.
        mov     al, [si + rxbuf + 3]     ; iMACAddress
        mov     [ecm_maci], al
ecwc_out:
        jmp     ecw_next

ecw_ep:
        cmp     byte [ecw_len], 7
        jb      short ecwe_out
        ; The notification endpoint belongs to the CONTROL interface, not
        ; the data one, so it is taken on a different test entirely.
        mov     al, [si + rxbuf + 3]
        and     al, 3
        cmp     al, 3                    ; interrupt
        jne     short ecw_epbulk
        cmp     bl, [ecm_ctlif]
        jne     short ecwe_out
        mov     al, [si + rxbuf + 2]
        and     al, 0x0F
        mov     [ecm_epint], al
        jmp     short ecwe_out
ecw_epbulk:
        test    dl, 2
        je      short ecwe_out           ; no data alt chosen yet
        ; An endpoint descriptor belongs to whichever interface descriptor
        ; last preceded it, so BL/BH say who owns this one.  Taking any
        ; bulk endpoint that happens to appear would pick up another
        ; function's -- an endpoint number that will never answer.
        cmp     bl, [ecm_dif]
        jne     short ecwe_out
        cmp     bh, [ecm_alt]
        jne     short ecwe_out
        mov     al, [si + rxbuf + 3]     ; bmAttributes
        and     al, 3
        cmp     al, 2                    ; bulk
        jne     short ecwe_out
        mov     al, [si + rxbuf + 2]     ; bEndpointAddress
        test    al, 0x80
        jne     short ecw_epin
        and     al, 0x0F
        mov     [ecm_epo], al
ecwe_out:
        jmp     ecw_next
ecw_epin:
        and     al, 0x0F
        mov     [ecm_epi], al
        jmp     short ecwe_out

ecw_end:
        test    dl, 1
        je      short ecw_no
        cmp     byte [ecm_epi], 0
        je      short ecw_no
        cmp     byte [ecm_epo], 0
        je      short ecw_no
        clc
        ret
ecw_no:
        stc
        ret

; --------------------------------------------------------------------------
; One configuration, by INDEX in AL.  CF clear if it holds an ECM function.
; --------------------------------------------------------------------------
ecm_one:
        mov     byte [cs:ecm_epi], 0     ; per configuration, not per device:
        mov     byte [cs:ecm_epo], 0     ; a half-filled match from the one
        mov     byte [cs:ecm_maci], 0    ; before must not vote in this one
        mov     byte [cs:ecm_epint], 0

        ; Nine bytes first, for wTotalLength.  A configuration descriptor is
        ; only meaningful ENTIRE -- the interface, functional and endpoint
        ; descriptors trail it and are what all of this is looking for.
        push    ax
        mov     ah, 2                    ; CONFIGURATION
        xor     dx, dx
        mov     cl, 9
        call    ecm_get
        pop     ax
        jc      short ecm1_no
        cmp     bh, 9
        jb      short ecm1_no
        mov     cx, [cs:rxbuf + 2]       ; wTotalLength
        cmp     cx, ECM_MAXCFG
        jbe     short ecm1_len
        mov     cx, ECM_MAXCFG
ecm1_len:
        push    ax
        mov     ah, 2
        xor     dx, dx
        call    ecm_get                  ; CL is already the length
        pop     ax
        jc      short ecm1_no
        or      bh, bh
        je      short ecm1_no
        mov     cl, bh
        xor     ch, ch
        call    ecm_walk
        ret
ecm1_no:
        stc
        ret

; --------------------------------------------------------------------------
; Is there a CDC-ECM function anywhere on this device?
; CF clear = yes, and every ecm_* field above is filled in.
; --------------------------------------------------------------------------
ecm_probe:
        push    cs
        pop     ds
        mov     al, 'P'
        call    mark

        ; Let the CHIP absorb NAKs while we ask questions, and put it back
        ; to 00 on every exit below.  This is what read_mac does and the
        ; note there explains why; the first build of this file ignored it
        ; on the strength of the OPPOSITE lesson, learned in ecm.pas, and
        ; the two are about different things.
        ;
        ; On a DATA endpoint a NAK means "busy, ask again" and the chip
        ; must report it, or a transfer raises no interrupt at all.  In a
        ; CONTROL transfer the data stage has to be retried INSIDE the
        ; transfer -- restarting from the SETUP asks the question again
        ; rather than waiting for the answer.  Measured here: twelve whole
        ; transfers, 10 ms apart, every one of them S14 I2A, on a device
        ; whose descriptors were there the entire time.  The driver read
        ; that as "no ECM function" and quietly took the vendor path.
        mov     al, 0x8F
        call    set_retry

        ; How many configurations are there?  The device descriptor says,
        ; at offset 17 -- and the CH375's own CMD_GET_DESCR cannot ask for
        ; a configuration by INDEX, only ever the first, which is why all
        ; of this goes through hand-built control transfers.
        mov     ah, 1                    ; DEVICE
        xor     al, al
        xor     dx, dx
        mov     cl, 18
        call    ecm_get
        jc      short ecm_pno
        cmp     bh, 18
        jb      short ecm_pno
        mov     al, [rxbuf + 17]         ; bNumConfigurations
        or      al, al
        je      short ecm_pno
        mov     [ecm_ncfg], al
        call    markhex                  ; how many there are to look at

        xor     al, al                   ; AL = configuration INDEX
ecm_ploop:
        push    ax
        call    ecm_one
        pop     ax
        jnc     short ecm_pyes
        inc     al
        cmp     al, [ecm_ncfg]
        jb      short ecm_ploop
; Both exits RESTORE 8F rather than forcing 00, because this now runs in
; the middle of usb_enum, where 8F is the ambient policy and everything
; after it depends on that.  Forcing 00 here broke the very next step: the
; configuration descriptor read began reporting NAKs instead of waiting
; them out, and the bring-up failed at step 25 with status 2A on an adapter
; that had been working a minute earlier.  usb_enum's own tail puts the
; chip back to 00 exactly once, as it always did.
ecm_pno:
        mov     al, 'n'
        call    mark
        mov     al, 0x8F
        call    set_retry
        stc
        ret
ecm_pyes:
        mov     al, 'Y'
        call    mark
        mov     al, 0x8F
        call    set_retry
        clc
        ret

; --------------------------------------------------------------------------
; One UTF-16 character at DS:SI -> AL = its hex value.  SI advances by 2.
; --------------------------------------------------------------------------
ecm_hexn:
        mov     al, [si]
        inc     si
        inc     si
        cmp     al, '0'
        jb      short ecmh_bad
        cmp     al, '9'
        ja      short ecmh_af
        sub     al, '0'
        clc
        ret
ecmh_af:
        and     al, 0xDF
        cmp     al, 'A'
        jb      short ecmh_bad
        cmp     al, 'F'
        ja      short ecmh_bad
        sub     al, 'A' - 10
        clc
        ret
ecmh_bad:
        stc
        ret

; --------------------------------------------------------------------------
; The MAC, out of the string descriptor the functional descriptor named.
; --------------------------------------------------------------------------
ecm_mac:
        ; TWO reads: the two-byte header for its bLength, then exactly that
        ; many bytes.  Asking for "64, whatever you have" is the obvious
        ; thing and it does not work here.
        ;
        ; ctrl_in ends a data stage on a packet shorter than EIGHT, which
        ; is right for a device whose endpoint 0 carries 8 bytes and wrong
        ; for this one, which carries 64.  A 26-byte string arrives in one
        ; 26-byte packet -- short for the endpoint, not short by that test
        ; -- so ctrl_in asked for more, and the device answered status 2B.
        ; Trace: `S14 I14 n1A I2B`, twelve times, then bring-up step 62.
        ;
        ; The exact-length read sidesteps it, and every other descriptor
        ; read here is already exact by construction.  ctrl_in itself is
        ; left alone deliberately: the AX88179 path shares it, that part is
        ; not on the bench today, and a latent bug nobody is hitting is a
        ; poor reason to change code that cannot be tested.  It is written
        ; up in NEXT.md as the one-line fix it is -- `cmp dl, [ep0max]`.
        mov     al, [cs:ecm_maci]
        or      al, al
        je      short ecmac_no
        mov     ah, 3                    ; STRING
        mov     dx, 0x0409               ; en-US, and the only language any
                                         ; of these devices offers
        mov     cl, 2
        call    ecm_get
        jc      short ecmac_no
        cmp     bh, 2
        jb      short ecmac_no
        mov     cl, [cs:rxbuf]           ; bLength, the whole descriptor
        cmp     cl, 26                   ; 2 header + 12 characters x 2
        jb      short ecmac_no
        mov     al, [cs:ecm_maci]
        mov     ah, 3
        mov     dx, 0x0409
        call    ecm_get
        jc      short ecmac_no
        cmp     bh, 26
        jb      short ecmac_no
        push    cs
        pop     ds
        mov     si, rxbuf + 2
        mov     di, mac
        mov     cx, 6
ecmac_byte:
        push    cx
        call    ecm_hexn
        jc      short ecmac_pop
        mov     ah, al
        call    ecm_hexn
        jc      short ecmac_pop
        mov     cl, 4
        shl     ah, cl
        or      al, ah
        mov     [di], al
        inc     di
        pop     cx
        loop    ecmac_byte
        clc
        ret
ecmac_pop:
        pop     cx
ecmac_no:
        stc
        ret

; --------------------------------------------------------------------------
; Open the packet filter.  Never fatal: a device is allowed to STALL this
; and plenty default to a usable filter anyway.  But a device that does
; honour it and was never asked delivers NOTHING, and a silent receive path
; is a miserable thing to debug from inside a driver that cannot print.
; --------------------------------------------------------------------------
ecm_filter:
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     di, ecm_setup
        mov     byte [di], 0x21          ; OUT, class, interface
        mov     byte [di+1], 0x43        ; SET_ETHERNET_PACKET_FILTER
        mov     byte [di+2], 0x1C        ; directed | broadcast | multicast
        mov     byte [di+3], 0
        mov     al, [ecm_ctlif]
        mov     [di+4], al               ; wIndex = the control interface
        mov     byte [di+5], 0
        mov     byte [di+6], 0
        mov     byte [di+7], 0
        mov     si, ecm_setup
        xor     bl, bl
        call    ctrl_out_n
        ret                              ; the CALLER decides what a refusal
                                         ; means.  It used to `clc` here,
                                         ; which threw away the one fact
                                         ; that distinguishes "the device
                                         ; ignores filters" from "the device
                                         ; is delivering nothing because we
                                         ; never opened it"

; --------------------------------------------------------------------------
; Select the ECM function and hand the resident half what it needs.
; --------------------------------------------------------------------------
ecm_bring:
        push    cs
        pop     ds
        mov     al, 'B'
        call    mark
        mov     al, 0x8F
        call    set_retry

        mov     byte [bu_step], 60
        mov     al, CMD_SET_CONFIG
        mov     ah, [ecm_cfgv]
        call    ch_hi
        jnc     short ecb_k1
        jmp     ecb_no                   ; ecb_no is more than 128 bytes
ecb_k1:                                  ; below here, and every 8086
                                         ; conditional jump is short only
        mov     cx, 50
        call    delay_ms

        ; SET_INTERFACE to the alt setting that HAS endpoints.  Skipping
        ; this leaves a device that is perfectly healthy and completely
        ; silent, which reads as a broken driver.
        mov     byte [bu_step], 61
        push    cs
        pop     es
        mov     di, ecm_setup
        mov     byte [di], 0x01          ; OUT, standard, interface
        mov     byte [di+1], 0x0B        ; SET_INTERFACE
        mov     al, [ecm_alt]
        mov     [di+2], al               ; wValue = alternate setting
        mov     byte [di+3], 0
        mov     al, [ecm_dif]
        mov     [di+4], al               ; wIndex = the data interface
        mov     byte [di+5], 0
        mov     byte [di+6], 0
        mov     byte [di+7], 0
        mov     si, ecm_setup
        xor     bl, bl
        call    ctrl_out_n
        jnc     short ecb_k2
        jmp     ecb_no
ecb_k2:
        mov     cx, 20
        call    delay_ms

        mov     byte [bu_step], 62
        call    ecm_mac
        jnc     short ecb_k3
        jmp     ecb_no
ecb_k3:

        mov     byte [bu_step], 63
        call    ecm_filter
        pushf

        ; Print what the walk ACTUALLY chose.  Every one of these is read
        ; from the device and any of them being wrong produces the same
        ; symptom -- an endpoint that NAKs for ever -- so the numbers have
        ; to be visible or the next fault costs another evening.  The
        ; transient half is the only place they exist: they are discovery
        ; results, not driver state, and nothing resident needs them.
        mov     dx, msg_e_geom
        call    puts
        mov     al, [ecm_cfgv]
        call    puthex
        mov     dx, msg_e_ctl
        call    puts
        mov     al, [ecm_ctlif]
        call    puthex
        mov     dx, msg_e_dat
        call    puts
        mov     al, [ecm_dif]
        call    puthex
        mov     dx, msg_e_alt
        call    puts
        mov     al, [ecm_alt]
        call    puthex
        mov     dx, msg_e_eps
        call    puts
        mov     al, [ecm_epi]
        call    puthex
        mov     dx, msg_e_epo
        call    puts
        mov     al, [ecm_epo]
        call    puthex
        mov     dx, msg_e_epi
        call    puts
        mov     al, [ecm_epint]
        call    puthex
        popf
        jnc     short ecb_filtok
        mov     dx, msg_e_filt
        call    puts
ecb_filtok:
        call    crlf

        ; ---- tell the resident half which protocol it is speaking ----
        mov     byte [link_mode], LM_ECM
        mov     word [tx_hdrlen], 0
        mov     word [drv_nptr], drv_ecm
        mov     al, [ecm_epi]
        mov     [ep_in_n], al
        mov     cl, 4
        shl     al, cl
        or      al, PID_IN
        mov     [tok_in], al
        mov     al, [ecm_epo]
        mov     [ep_out_n], al
        mov     cl, 4
        shl     al, cl
        or      al, PID_OUT
        mov     [tok_out], al
        mov     al, [ecm_epint]
        mov     [ep_int_n], al
        or      al, al
        je      short ecb_noint
        mov     cl, 4
        shl     al, cl
        or      al, PID_IN
        mov     [tok_int], al
ecb_noint:
        mov     byte [dev_live], 1
        mov     byte [bu_step], 0
        xor     al, al
        call    set_retry
        clc
        ret
ecb_no:
        mov     al, 'b'
        call    mark
        mov     al, [bu_step]
        call    markhex
        mov     al, 0x8F
        call    set_retry
        call    clr_ep0
        stc
        ret

; --------------------------------------------------------------------------
; Put everything back to the AX88179 defaults, for a device that claimed a
; path and would not come up on it.  Falling back to the vendor path beats
; refusing to load: on a part that offers both, one working path is the
; entire point.
;
; Called by BOTH the ECM and the SR9700 arms, which is why it is no longer
; called ecm_undo -- a shared routine with one path's name on it is how the
; next person ends up writing a second copy.
; --------------------------------------------------------------------------
link_defaults:
        push    cs
        pop     ds
        mov     byte [link_mode], LM_AX
        mov     word [tx_hdrlen], 8
        mov     word [drv_nptr], drv_name
        mov     byte [tok_in], (EP_BULK_IN << 4) | PID_IN
        mov     byte [tok_out], (EP_BULK_OUT << 4) | PID_OUT
        mov     byte [ep_in_n], EP_BULK_IN
        mov     byte [ep_out_n], EP_BULK_OUT
        ; No SET_CONFIGURATION here.  This is now reached from inside
        ; usb_enum, BEFORE any configuration has been chosen, and the code
        ; immediately below the call site goes on to read and select the
        ; vendor one.  The earlier version re-selected cfg_val_e, which at
        ; this point has not been read yet.
        ret

; ==========================================================================
; SR9700 / DM9601.
;
; The third chipset, and the only one here chosen by USB ID rather than by
; what the device says about itself.  It has no class descriptor, no
; functional descriptor and no vendor string worth trusting -- the adapter
; this was written against introduces itself as "Gzcyc No:9700" -- so a
; table is the only thing that can identify it.
;
; The reference implementation is sr9700.pas, which drives this same part
; in both directions on real traffic.  Everything below is that unit
; translated, and where the two disagree the Pascal is right, because the
; Pascal is the one that has been measured.
; ==========================================================================

SR_RD_REGS      equ 0x00         ; vendor IN:  read registers
SR_WR_REG       equ 0x03         ; vendor OUT: write ONE register, no data
                                 ;             stage -- value in wValue
SR_NCR          equ 0x00
SR_NSR          equ 0x01
SR_RCR          equ 0x05
SR_PAR          equ 0x10         ; the MAC, six registers
SR_PRR          equ 0x1F         ; PHY reset
NCR_RST         equ 0x01
NSR_LINKST      equ 0x40
PRR_PHY_RST     equ 0x01
RCR_RXEN        equ 0x01
RCR_PRMSC       equ 0x02
RCR_ALL         equ 0x08
RCR_DIS_CRC     equ 0x10
RCR_DIS_LONG    equ 0x20

; Receive on, drop runts and oversize, drop frames whose CRC is wrong --
; and NEITHER promiscuous NOR all-multicast.  DIS_CRC means "discard a frame
; whose CRC is bad", not "strip the CRC"; the four bytes still arrive and
; rx_have_sr trims them.
;
; THE REASON IS CORRECTNESS, NOT SPEED, and that correction is worth
; leaving here because the speed argument was written first, was very
; persuasive, and was wrong.
;
; It went: this chip cannot aggregate, so a 1442-byte frame is twenty-three
; 64-byte reads and about 16 ms of an 8086-class machine, paid whether
; anything wants the frame or not -- and a listing of this segment is
; roughly 60% multicast, with the chip's own overflow counter reading B3
; after sixty seconds of it.  Every one of those facts is true.  The
; conclusion drawn from them was not.
;
; Measured, which is the whole reason /M exists: the same 5 MB download
; over the same segment took 307.9 s with this filter and 312.3 s with
; all-multicast added.  1.4%.  Multicast is simply not a large share of the
; frames arriving while a download is in progress, however large a share it
; is of an idle one.
;
; So the filter stays narrow for the ordinary reason -- a packet driver
; delivers what its clients asked for, and an application that wants
; multicast says so through set_multicast_list -- and NOT because it buys
; throughput, because it does not.
SR_WANT_RCR     equ RCR_RXEN | RCR_DIS_LONG | RCR_DIS_CRC

sr_setup:   times 8 db 0
sr_data:    db 0
sr_cfgv:    db 0                 ; bConfigurationValue to select
sr_if:      db 0                 ; the network interface number
sr_epi:     db 0                 ; bulk IN endpoint number
sr_epo:     db 0                 ; bulk OUT
sr_massif:  db 0xFF              ; the mass-storage interface, if there is
                                 ; one.  Reported, not used -- see sr_walk
sr_reg:     db 0
sr_len:     db 0
sr_rcrv:    db 0                 ; the RCR value actually written, so the
                                 ; read-back compares against what was sent
                                 ; rather than against the default

; --------------------------------------------------------------------------
; One register, one control transfer.  AL = register, BL = value.
;
; THE BLOCK FORM IS NOT USED ANYWHERE HERE, AND THAT IS DELIBERATE.  A
; multi-byte read on the clone returns the PAR block from 10h whatever
; wIndex says -- ask for eight bytes at 28h and the MAC comes back.  A
; driver that read the six MAC bytes in one go would therefore get the
; RIGHT answer for the MAC and the wrong answer for every other register,
; which is a far nastier way to be wrong than failing outright.  Six
; transfers to read a MAC costs nothing next to that.
; --------------------------------------------------------------------------
sr_wr8:
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     [sr_reg], al
        mov     di, sr_setup
        mov     byte [di+0], 0x40        ; OUT, vendor, device
        mov     byte [di+1], SR_WR_REG
        mov     [di+2], bl               ; wValue  = the VALUE
        mov     byte [di+3], 0
        mov     [di+4], al               ; wIndex  = the REGISTER
        mov     byte [di+5], 0
        mov     byte [di+6], 0           ; wLength = 0: no data stage
        mov     byte [di+7], 0
        mov     si, sr_setup
        mov     di, sr_data
        xor     bl, bl
        call    ctrl_out_r
        pushf
        ; ctrl_out_r / ctrl_in_r put the chip back to 00 on the way out.
        ; Inside usb_enum 8F is the ambient policy and the step after this
        ; one depends on it -- ecm_probe's comment records what forcing 00
        ; here did to the configuration read.  usb_enum's own tail drops it
        ; to 00 exactly once, as it always did.
        mov     al, 0x8F
        call    set_retry
        popf
        ; DS BACK TO CS BEFORE RETURNING, and this is not tidiness.  The
        ; transfer helpers below take DS:SI as the setup packet and none of
        ; them promises to put DS back, so a caller that reads one of its
        ; own variables straight after a register access is reading it out
        ; of whatever segment happened to survive.  Nothing about that
        ; fails visibly -- it reads a plausible byte from somewhere else --
        ; which is the expensive kind of wrong.
        push    cs
        pop     ds
        ret

; AL = register -> BL = value.
sr_rd8:
        push    cs
        pop     ds
        push    cs
        pop     es
        mov     [sr_reg], al
        mov     di, sr_setup
        mov     byte [di+0], 0xC0        ; IN, vendor, device
        mov     byte [di+1], SR_RD_REGS
        mov     byte [di+2], 0
        mov     byte [di+3], 0
        mov     [di+4], al               ; wIndex = the register
        mov     byte [di+5], 0
        mov     byte [di+6], 1           ; ONE byte.  See above.
        mov     byte [di+7], 0
        mov     byte [sr_data], 0
        mov     si, sr_setup
        mov     di, sr_data
        mov     bl, 1
        call    ctrl_in_r
        pushf
        mov     al, 0x8F
        call    set_retry
        popf
        push    cs
        pop     ds                       ; see sr_wr8
        jc      short sr_rd8_no
        mov     bl, [cs:sr_data]
        clc
        ret
sr_rd8_no:
        xor     bl, bl
        stc
        ret

; --------------------------------------------------------------------------
; The USB IDs.  Every one of these is the same register map; what differs
; between the genuine parts and the clones is which access FORMS they
; bother to implement, and the single-byte form above is the one they all
; have.
; --------------------------------------------------------------------------
sr_ids:
        dw 0x0FE6, 0x9700        ; CoreChip SR9700
        dw 0x0FE6, 0x9702        ; SR9700 clone, single-byte registers only
        dw 0x0FE6, 0x8101        ; DM9601 (Kontron)
        dw 0x07AA, 0x9601        ; Corega FEther USB-TXC
        dw 0x0A46, 0x9601        ; Davicom DM9601
        dw 0x0A46, 0x0268        ; Davicom DM9601
        dw 0x0A46, 0x9000        ; DM9000E
        dw 0x0A46, 0x1269        ; DM9601, another badge
        dw 0

; --------------------------------------------------------------------------
; Walk the configuration descriptor in rxbuf.  CX = how many bytes.
;
; SKIPPING THE MASS-STORAGE INTERFACE IS THE WHOLE JOB.  These adapters put
; a flash holding the driver CD FIRST, with its own bulk pair, so a walk
; that takes the first bulk endpoints it meets binds the packet driver to a
; disk.  Nothing about that fails loudly: the endpoints are real, the
; transfers succeed, and the adapter simply never delivers a frame.
;
; This mirrors FindNet in srlink.pas rather than inventing a rule, because
; FindNet is the version that has been run against the hardware.
; --------------------------------------------------------------------------
sr_walk:
        mov     byte [sr_if], 0
        mov     byte [sr_epi], 0
        mov     byte [sr_epo], 0
        mov     byte [sr_massif], 0xFF
        mov     di, cx                   ; DI = end of the buffer
        xor     si, si                   ; SI = offset of this descriptor
        mov     bl, 0xFF                 ; BL = current interface number
        mov     bh, 0                    ; BH = its class
srw_loop:
        mov     ax, si
        inc     ax
        inc     ax
        cmp     ax, di
        ja      short srw_fin
        mov     al, [si + rxbuf]         ; bLength
        or      al, al
        je      short srw_fin            ; a zero length never advances
        mov     [ecw_len], al
        xor     ah, ah
        mov     cx, si
        add     cx, ax
        cmp     cx, di
        jbe     short srw_inb            ; runs off the end: nothing in it
; A trampoline, because srw_end is a long way below and an 8086 conditional
; jump is short only.  ecm_walk needed the same thing for the same reason
; and calls it ecw_fin; it sits after a `jbe` rather than before one so
; nothing can fall into it.
srw_fin:                                 ; can be trusted
        jmp     srw_end
srw_inb:
        mov     al, [si + rxbuf + 1]     ; bDescriptorType
        cmp     al, 4
        je      short srw_iface
        cmp     al, 5
        je      short srw_ep
srw_next:
        mov     al, [ecw_len]
        xor     ah, ah
        add     si, ax
        jmp     short srw_loop

srw_iface:
        cmp     byte [ecw_len], 9
        jb      short srw_next
        mov     bl, [si + rxbuf + 2]     ; bInterfaceNumber
        mov     bh, [si + rxbuf + 5]     ; bInterfaceClass
        cmp     bh, 0x08                 ; mass storage: the driver CD
        jne     short srw_ifnet
        cmp     byte [sr_massif], 0xFF
        jne     short srw_next
        mov     [sr_massif], bl
        jmp     short srw_next
srw_ifnet:
        cmp     byte [sr_epi], 0
        jne     short srw_next           ; already settled on one
        mov     [sr_if], bl
        jmp     short srw_next

srw_ep:
        cmp     byte [ecw_len], 7
        jb      short srw_next
        cmp     bh, 0x08
        je      short srw_next           ; an endpoint belongs to whichever
                                         ; interface descriptor last
                                         ; preceded it, so this one is the
                                         ; flash's
        cmp     bl, [sr_if]
        jne     short srw_next
        mov     al, [si + rxbuf + 3]     ; bmAttributes
        and     al, 3
        cmp     al, 2                    ; bulk
        jne     short srw_next
        mov     al, [si + rxbuf + 2]     ; bEndpointAddress
        test    al, 0x80
        jne     short srw_epin
        and     al, 0x0F
        cmp     byte [sr_epo], 0
        jne     short srw_next
        mov     [sr_epo], al
        jmp     short srw_next
srw_epin:
        and     al, 0x0F
        cmp     byte [sr_epi], 0
        jne     short srw_next
        mov     [sr_epi], al
        jmp     short srw_next

srw_end:
        cmp     byte [sr_epi], 0
        je      short srw_no
        cmp     byte [sr_epo], 0
        je      short srw_no
        clc
        ret
srw_no:
        stc
        ret

; --------------------------------------------------------------------------
; Is this an SR9700 / DM9601, and where are its endpoints?
; CF clear = yes, and sr_cfgv / sr_if / sr_epi / sr_epo are filled in.
; --------------------------------------------------------------------------
sr_probe:
        push    cs
        pop     ds
        cmp     byte [op_nosr], 0
        je      short srp_go
        stc
        ret
srp_go:
        mov     al, 'D'
        call    mark

        ; The ID, out of the device descriptor usb_enum has already read.
        mov     ax, [desc_buf + 8]       ; idVendor
        mov     dx, [desc_buf + 10]      ; idProduct
        mov     si, sr_ids
srp_next:
        mov     bx, [si]
        or      bx, bx
        je      short srp_no
        cmp     bx, ax
        jne     short srp_skip
        mov     bx, [si+2]
        cmp     bx, dx
        je      short srp_hit
srp_skip:
        add     si, 4
        jmp     short srp_next
srp_no:
        mov     al, 'n'
        call    mark
        stc
        ret

srp_hit:
        ; 8F for the duration, as ecm_probe does and for the same reason: a
        ; busy device answers a control transfer with NAK, and with the
        ; chip set to REPORT those rather than absorb them one NAK reads as
        ; a device that is not there.
        mov     al, 0x8F
        call    set_retry

        ; Nine bytes first, for wTotalLength -- a configuration descriptor
        ; only means anything entire, and the interface and endpoint
        ; descriptors that this is looking for trail it.
        xor     al, al                   ; index 0
        mov     ah, 2                    ; CONFIGURATION
        xor     dx, dx
        mov     cl, 9
        call    ecm_get
        jc      short srp_bad
        cmp     bh, 9
        jb      short srp_bad
        mov     al, [cs:rxbuf + 5]       ; bConfigurationValue
        or      al, al
        jne     short srp_cfgv
        mov     al, 1
srp_cfgv:
        mov     [cs:sr_cfgv], al
        mov     cx, [cs:rxbuf + 2]       ; wTotalLength
        cmp     cx, ECM_MAXCFG
        jbe     short srp_len
        mov     cx, ECM_MAXCFG
srp_len:
        xor     al, al
        mov     ah, 2
        xor     dx, dx
        call    ecm_get                  ; CL is already the length
        jc      short srp_bad
        or      bh, bh
        je      short srp_bad
        push    cs
        pop     ds
        mov     cl, bh
        xor     ch, ch
        call    sr_walk
        jc      short srp_bad
        mov     al, 'Y'
        call    mark
        clc
        ret
srp_bad:
        mov     al, 'b'
        call    mark
        stc
        ret

; --------------------------------------------------------------------------
; Select it, wake the PHY, open the receiver, read the MAC, and tell the
; resident half which protocol it is speaking.
; --------------------------------------------------------------------------
sr_bring:
        push    cs
        pop     ds
        mov     al, 'R'
        call    mark
        mov     al, 0x8F
        call    set_retry

        mov     byte [bu_step], 70
        mov     al, CMD_SET_CONFIG
        mov     ah, [sr_cfgv]
        call    ch_hi
        jnc     short srb_k1
        jmp     srb_no                   ; srb_no is more than 128 bytes
srb_k1:                                  ; away and an 8086 conditional
        mov     cx, 50                   ; jump is short only
        call    delay_ms

        ; SET_INTERFACE to alt 0 on the NETWORK interface.  These adapters
        ; have more than one interface and the flash is first, so this is
        ; not the no-op it looks like on a single-function device.
        mov     byte [bu_step], 71
        push    cs
        pop     es
        mov     di, sr_setup
        mov     byte [di+0], 0x01        ; OUT, standard, interface
        mov     byte [di+1], 0x0B        ; SET_INTERFACE
        mov     byte [di+2], 0           ; wValue = alternate setting 0
        mov     byte [di+3], 0
        mov     al, [sr_if]
        mov     [di+4], al               ; wIndex = the interface
        mov     byte [di+5], 0
        mov     byte [di+6], 0
        mov     byte [di+7], 0
        mov     si, sr_setup
        xor     bl, bl
        call    ctrl_out_n
        push    cs
        pop     ds                       ; see sr_wr8
        ; NOT fatal.  A device with one alt setting is entitled to STALL
        ; this, and the Pascal driver ignores the answer too.
        mov     cx, 20
        call    delay_ms

        ; THE CHIP RESET IS WHAT BRINGS THE LINK UP, and the first version
        ; of this left it out.
        ;
        ; The reasoning for leaving it out was that NCR_RST resets the
        ; network chip, and on a part whose USB front end shares that reset
        ; the device would drop off the bus in the middle of its own
        ; bring-up -- which is the shape of two hangs the Pascal driver
        ; cost.  Plausible, and wrong here: the Pascal driver resets by
        ; default and comes up at 10 Mbps every time.
        ;
        ; Measured, on the same adapter minutes apart.  Without the reset
        ; the bring-up succeeds in every visible respect -- registers read
        ; and write, the RCR sticks, the MAC comes back right -- and NSR
        ; reads link DOWN and stays there through three seconds of waiting.
        ; With it, NSR reads C1: link up, 10 Mbps.  A bring-up that gets
        ; everything right except the one register nothing else depends on
        ; is a good way to lose an evening to the cable.
        mov     byte [bu_step], 72
        mov     al, SR_NCR
        mov     bl, NCR_RST
        call    sr_wr8
        jnc     short srb_krst
        jmp     srb_no
srb_krst:
        mov     cx, 20
        call    delay_ms

        ; The PHY: held in reset, released, then left alone long enough to
        ; get its own auto-negotiation started.
        ;
        ; delay_ticks, NOT delay_ms, and the ASIX bring-up learned this the
        ; expensive way a few hundred lines below: delay_ms is a calibrated
        ; spin loop and calibration is a promise, where delay_ticks waits
        ; for the BIOS counter at 0040:006C to CHANGE and is therefore a
        ; guaranteed minimum.  The AX88179's PHY reset failed
        ; intermittently, at a numbered step, with nothing to show for it,
        ; until that same substitution was made.
        ;
        ; 2 rather than 1, for the reason written there: delay_ticks 1 is
        ; anything from 0 to 55 ms depending on where in the tick we
        ; happened to arrive, so 2 is the first value that means anything.
        mov     byte [bu_step], 73
        mov     al, SR_PRR
        mov     bl, PRR_PHY_RST
        call    sr_wr8
        jnc     short srb_k2
        jmp     srb_no
srb_k2:
        mov     al, 2
        call    delay_ticks
        mov     al, SR_PRR
        xor     bl, bl
        call    sr_wr8
        jnc     short srb_k3
        jmp     srb_no
srb_k3:
        mov     al, 3
        call    delay_ticks

        mov     byte [bu_step], 74
        mov     al, SR_RCR
        mov     bl, SR_WANT_RCR
        cmp     byte [op_mcast], 0
        je      short srb_nomc
        or      bl, RCR_ALL              ; /M
srb_nomc:
        cmp     byte [op_promisc], 0
        je      short srb_rcr
        or      bl, RCR_PRMSC | RCR_ALL  ; /P implies /M: a promiscuous
                                         ; receiver that filtered multicast
                                         ; would be a strange thing
srb_rcr:
        mov     [sr_rcrv], bl
        call    sr_wr8
        jnc     short srb_k4
        jmp     srb_no
srb_k4:
        ; READ IT BACK.  A register write that does not stick is the
        ; failure that wastes the most time later, because every symptom it
        ; produces looks like a receive problem instead.
        mov     byte [bu_step], 75
        mov     al, SR_RCR
        call    sr_rd8
        jnc     short srb_k5
        jmp     srb_no
srb_k5:
        cmp     bl, [sr_rcrv]
        je      short srb_k6
        mov     byte [bu_step], 76
        jmp     srb_no
srb_k6:

        ; The MAC, six registers, six transfers.  See sr_rd8.
        mov     byte [bu_step], 77
        mov     di, mac
        mov     al, SR_PAR
srb_mac:
        push    ax
        push    di
        call    sr_rd8
        pop     di
        pop     ax
        jnc     short srb_macok
        jmp     srb_no
srb_macok:
        mov     [di], bl
        inc     di
        inc     al
        cmp     al, SR_PAR + 6
        jb      short srb_mac

        ; Say what the walk chose.  Every one of these is read from the
        ; device and any of them being wrong produces the same symptom --
        ; an endpoint that NAKs for ever -- so the numbers have to be
        ; visible or the next fault costs another evening.
        mov     dx, msg_r_geom
        call    puts
        mov     al, [sr_cfgv]
        call    puthex
        mov     dx, msg_r_if
        call    puts
        mov     al, [sr_if]
        call    puthex
        mov     dx, msg_e_eps
        call    puts
        mov     al, [sr_epi]
        call    puthex
        mov     dx, msg_e_epo
        call    puts
        mov     al, [sr_epo]
        call    puthex
        cmp     byte [sr_massif], 0xFF
        je      short srb_nomass
        mov     dx, msg_r_mass
        call    puts
        mov     al, [sr_massif]
        call    puthex
        mov     dx, msg_r_mass2
        call    puts
srb_nomass:
        call    crlf

        ; The link, for the record.  Read HERE and never again: this part
        ; reports the link in a register rather than through an interrupt
        ; endpoint, and a register read is a control transfer, which is not
        ; a thing to do from inside a timer interrupt.
        ;
        ; WAITED FOR, because the first version of this printed DOWN every
        ; time on a cable that was plainly connected.  Auto-negotiation
        ; takes a second or two and the PHY was released about eighty
        ; milliseconds earlier, so the read was simply too early -- and a
        ; driver that says DOWN at the top of its own output sends the next
        ; person to check the cable, the switch and the socket before
        ; anything else.  Three seconds spent once, at install, to avoid
        ; that is a bargain.
        mov     byte [bu_step], 78
        mov     bp, 30
srb_lwait:
        mov     al, SR_NSR
        call    sr_rd8
        jc      short srb_nolink
        test    bl, NSR_LINKST
        jne     short srb_lup
        push    bx
        mov     cx, 100
        call    delay_ms
        pop     bx
        dec     bp
        jnz     short srb_lwait
srb_lup:
        mov     dx, msg_r_link
        call    puts
        ; The RAW BYTE as well as the verdict.  A driver that prints only
        ; "DOWN" has thrown away the one fact that separates "the cable is
        ; out" from "this register is not the one I think it is", and those
        ; two took a wrong turn each before the byte was printed.
        push    bx
        mov     al, bl
        call    puthex
        mov     dx, msg_r_nsr
        call    puts
        pop     bx
        mov     dx, msg_l_down
        test    bl, NSR_LINKST
        je      short srb_lsay
        mov     dx, msg_l_up
srb_lsay:
        call    puts
        call    crlf
srb_nolink:

        ; ---- tell the resident half which protocol it is speaking ----
        mov     byte [link_mode], LM_SR
        mov     word [tx_hdrlen], SR_TX_OVERHEAD
        mov     word [drv_nptr], drv_sr
        mov     al, [sr_epi]
        mov     [ep_in_n], al
        mov     cl, 4
        shl     al, cl
        or      al, PID_IN
        mov     [tok_in], al
        mov     al, [sr_epo]
        mov     [ep_out_n], al
        mov     cl, 4
        shl     al, cl
        or      al, PID_OUT
        mov     [tok_out], al
        mov     byte [ep_int_n], 0       ; there is no notification endpoint
        mov     byte [dev_live], 1
        mov     byte [bu_step], 0
        xor     al, al
        call    set_retry
        clc
        ret
srb_no:
        mov     al, 'r'
        call    mark
        mov     al, [bu_step]
        call    markhex
        mov     al, 0x8F
        call    set_retry
        call    clr_ep0
        stc
        ret

ax_bringup:
        ; Three goes at the enumeration, with a full teardown between them.
        ; A device left configured by a bring-up that stopped half way does
        ; not answer a fresh enumeration, and the first thing that clears it
        ; is the teardown -- so the second attempt is the one that usually
        ; works.  Without this the recovery is a power cycle, which is not
        ; something a driver should ask of anybody.
        mov     byte [cs:enum_tries], 3
        mov     word [cs:reset_hold], 40
bu_again:
        call    usb_enum
        jnc     short bu_enumok
        dec     byte [cs:enum_tries]
        jz      short bu_giveup
        call    usb_down
        ; Longer each time round.
        mov     ax, [cs:reset_hold]
        cmp     ax, 250
        jae     short bu_hold600
        mov     word [cs:reset_hold], 250
        jmp     short bu_again
bu_hold600:
        mov     word [cs:reset_hold], 600
        jmp     short bu_again
bu_giveup:
        stc
        ret
bu_enumok:
        ; Did the enumeration bring this up as a CLASS device?  If so there
        ; is no vendor bring-up to do: no PHY to power, no MII to poll, no
        ; registers at all.  usb_enum decides that, because the question has
        ; to be asked before a configuration is selected -- see the long
        ; note there.
        cmp     byte [cs:link_mode], LM_AX
        je      short bu_vendor
        mov     al, 'E'
        call    mark
        mov     byte [cs:bu_step], 0
        clc
        ret
bu_vendor:
        mov     byte [cs:bu_step], 1
        ; Power the PHY. The reset line has to be seen low and then high,
        ; and the settle afterwards is not optional: before it the PHY
        ; answers MDIO with all ones.
        mov     al, AX_PHYPWR_RSTCTL
        mov     bx, 0
        call    ax_wr16
        jnc     short __buv1
        jmp     near bu_bad
__buv1:
        ; 2, not 1.  delay_ticks waits for the BIOS counter to CHANGE
        ; that many times, so 1 is anything from 0 to 55 ms depending on
        ; where in the tick we happened to arrive -- and on the short
        ; draws the PHY had not seen the reset line low yet, so the write
        ; below timed out: step 2, register 26, status 28, intermittently
        ; and with nothing to show for it.  2 is the first value that is
        ; a guaranteed minimum, and 55 ms comfortably covers the 20 ms
        ; ax179.pas has always waited here.
        mov     al, 2
        call    delay_ticks

        mov     byte [cs:bu_step], 2
        mov     al, AX_PHYPWR_RSTCTL
        mov     bx, 0x0020
        call    ax_wr16
        jnc     short __buv2
        jmp     near bu_bad
__buv2:
        ; 5 for at least 220 ms.  Before that the PHY is still coming out
        ; of reset and answers MDIO with all ones.  4 guaranteed only 165.
        mov     al, 5
        call    delay_ticks

        mov     byte [cs:bu_step], 3
        mov     al, AX_CLK_SELECT
        mov     bl, 0x03
        call    ax_wr8
        jnc     short __buv3
        jmp     near bu_bad
__buv3:
        ; 3 for at least 110 ms after the clock select, matching the 100
        ; in ax179.pas.
        mov     al, 3
        call    delay_ticks

        mov     byte [cs:bu_step], 4
        call    read_mac
        jnc     short __buv4
        jmp     near bu_bad
__buv4:

        mov     byte [cs:bu_step], 5
        ; Zeroing this register does NOT mean "no aggregation", it means NO
        ; LIMIT -- the chip then appends frames for as long as traffic
        ; arrives and the transfer never ends. 07 enables all three limits.
        mov     [cs:bu_data+0], byte 0x07
        ; 0080, which is what ax179.pas writes.  This said 0004, and the
        ; two have to agree: it is the timer that makes the adapter flush
        ; a part-full burst instead of holding it, and the flush is what
        ; produces the SHORT packet that ends a USB transfer.  Get it
        ; wrong and the transfer simply never ends -- which is exactly
        ; the symptom: full 64-byte packets for ever and no boundary.
        mov     al, [cs:op_qtimer]               ; timer low, /Q sets it
        mov     [cs:bu_data+1], al
        mov     [cs:bu_data+2], byte 0x00        ; timer high
        mov     [cs:bu_data+3], byte 0x01        ; burst size, in KB, and
                                         ; it must be SMALLER than rxbuf
                                         ; -- see ax179.pas
        mov     [cs:bu_data+4], byte 0x08        ; inter-frame gap
        mov     al, AX_RX_BULK_QCTRL
        mov     bl, 5
        call    ax_mac_wr
        jnc     short __buv5
        jmp     near bu_bad
__buv5:

        mov     byte [cs:bu_step], 6
        mov     al, AX_PAUSE_LOW
        mov     bl, 0x34
        call    ax_wr8
        jnc     short __buv6
        jmp     near bu_bad
__buv6:
        mov     al, AX_PAUSE_HIGH
        mov     bl, 0x52
        call    ax_wr8
        jnc     short __buv7
        jmp     near bu_bad
__buv7:

        mov     byte [cs:bu_step], 7
        ; Checksum offload off: it changes the frame layout on both paths.
        mov     al, AX_RXCOE_CTL
        xor     bl, bl
        call    ax_wr8
        jnc     short __buv8
        jmp     near bu_bad
__buv8:
        mov     al, AX_TXCOE_CTL
        xor     bl, bl
        call    ax_wr8
        jnc     short __buv9
        jmp     near bu_bad
__buv9:
        mov     al, AX_MONITOR_MODE
        xor     bl, bl
        call    ax_wr8
        jnc     short __buv10
        jmp     near bu_bad
__buv10:

        mov     byte [cs:bu_step], 8
        ; Start the receiver. IP_ALIGN deliberately clear: it pads every
        ; frame by two so an IP header lands aligned, which matters to a
        ; CPU that faults on unaligned access and not at all to an 8086.
        mov     al, AX_RX_CTL
        ; Promiscuous was tried here as a probe on 2026-09-09, on the
        ; theory that the missing ARP replies were being filtered out by
        ; the adapter.  It changed nothing, so that is not the reason,
        ; and it is the wrong default anyway: this machine cannot drain
        ; the traffic it already asks for.  /R mode 6 still sets it.
        mov     bx, (RX_CTL_START | RX_CTL_ACCEPT_PHY | RX_CTL_BROADCAST | RX_CTL_DROP_CRC)
        call    ax_wr16
        jnc     short __buv11
        jmp     near bu_bad
__buv11:

        mov     byte [cs:bu_step], 9
        ; Restrict what the PHY advertises rather than forcing the speed,
        ; so the far end negotiates normally instead of working out why its
        ; partner went quiet. ANAR 0061 is 10BASE-T half and full with the
        ; 802.3 selector; GBCR 0 withdraws the gigabit offer.
        cmp     byte [cs:op_giga], 0
        jne     short bu_nego
        mov     al, MII_GBCR
        mov     bx, 0
        call    ax_phy_wr
        jnc     short __buv12
        jmp     near bu_bad
__buv12:
        mov     al, MII_ANAR
        mov     bx, 0x0061
        call    ax_phy_wr
        jnc     short __buv13
        jmp     near bu_bad
__buv13:
bu_nego:
        mov     al, MII_BMCR
        mov     bx, (BMCR_ANENABLE | BMCR_ANRESTART)
        call    ax_phy_wr
        jnc     short __buv14
        jmp     near bu_bad
__buv14:

        mov     byte [cs:bu_step], 10
        ; BMSR latches link-down low, so it is read twice by convention:
        ; the first read clears the latch, the second is the current state.
        mov     cx, 120
bu_link:
        push    cx
        mov     al, 1
        call    delay_ticks
        mov     al, MII_BMSR
        call    ax_phy_rd
        mov     al, MII_BMSR
        call    ax_phy_rd
        pop     cx
        jc      short bu_bad
        test    bx, BMSR_LINK
        jnz     short bu_haslink
        loop    bu_link
        jmp     short bu_bad
bu_haslink:

        mov     byte [cs:bu_step], 11
        ; The MAC does not learn the speed by itself, and a link that is up
        ; while this register disagrees passes no traffic at all.
        mov     bx, (MED_RECEIVE_EN | MED_ALWAYS_ONE | MED_RXFLOW_EN | MED_TXFLOW_EN | MED_FULL_DUPLEX)
        cmp     byte [cs:op_giga], 0
        je      short bu_med
        or      bx, (MED_GIGA | MED_EN_125MHZ)
bu_med:
        mov     al, AX_MEDIUM_MODE
        call    ax_wr16
        jc      short bu_bad

        mov     byte [cs:bu_step], 0
        clc
        ret
bu_bad:
        call    usb_down
        stc
        ret

; --------------------------------------------------------------------------
; Output helpers.
; --------------------------------------------------------------------------
puts:                                    ; DX -> '$'-terminated
        push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret

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
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        ret

puthex:                                  ; AL
        push    cx                       ; CL is a shift count here and a
        push    ax                       ; live byte count in ctrl_in; not
        push    ax                       ; saving it is the sort of thing
        mov     cl, 4                    ; that only bites once tracing is
        shr     al, cl                   ; added to a working routine
        call    puthex1
        pop     ax
        and     al, 0x0F
        call    puthex1
        pop     ax
        pop     cx
        ret
puthex1:
        add     al, '0'
        cmp     al, '9'
        jbe     short puthex1_p
        add     al, 7
puthex1_p:
        call    putc
        ret

puthexw:                                 ; AX
        push    ax
        mov     al, ah
        call    puthex
        pop     ax
        call    puthex
        ret

putdecw:                                 ; AX
        push    ax
        push    bx
        push    cx
        push    dx
        xor     cx, cx
        mov     bx, 10
pdw_d:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jne     short pdw_d
pdw_p:
        pop     ax
        add     al, '0'
        call    putc
        loop    pdw_p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; --------------------------------------------------------------------------
; hexval: AL char -> AL value, CF on error.
; --------------------------------------------------------------------------
; A small decimal number after '=' -- the timer divisor and nothing else.
pa_decnum:
        xor     bx, bx
        jcxz    pa_dn_out
        cmp     byte [si], '='
        jne     short pa_dn_out
        inc     si
        dec     cx
pa_dn_d:
        jcxz    pa_dn_out
        mov     al, [si]
        cmp     al, '0'
        jb      short pa_dn_out
        cmp     al, '9'
        ja      short pa_dn_out
        inc     si
        dec     cx
        sub     al, '0'
        push    ax
        mov     ax, bx
        mov     bl, 10
        mul     bl
        mov     bx, ax
        pop     ax
        xor     ah, ah
        add     bx, ax
        jmp     short pa_dn_d
pa_dn_out:
        mov     al, bl
        ret

hexval:
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
; The command line.
; --------------------------------------------------------------------------
op_unload:  db 0
op_status:  db 0
op_verb:    db 0
op_help:    db 0
op_giga:    db 0
op_noecm:   db 0        ; /X -- refuse the class path even where it exists
op_nosr:    db 0        ; /D -- refuse the SR9700/DM9601 path
op_mcast:   db 0        ; /M -- accept ALL multicast (SR9700 only)
op_promisc: db 0        ; /P -- promiscuous (SR9700 only)
op_test:    db 0

; /8 -- use the portable 8086 byte loops even on a CPU that has REP INSB
; and REP OUTSB.  It exists so the fast path can be ruled in or out in one
; command, without a rebuild, on the machine where a fault would show.  The
; risk it covers is specific: REP INSB issues port reads far closer
; together than the loop it replaces, and the CH375's settling delays are
; not decoration.  If a transfer ever CRCs wrong, this is the first thing
; to try -- and if /8 fixes it, that is the answer rather than a hint.
op_no186:   db 0

; /Q -- the AX88179's bulk-in aggregation timer, low byte, decimal.
; The adapter holds a part-full burst until this expires, so it sets a
; floor under the latency of every single frame that arrives on a quiet
; link.  ax179.pas uses 80h and so did this; whether that is the right
; number for a machine that drains 64 bytes at a time is a separate
; question from whether it is the right number for Linux.
op_qtimer:  db 0x80

; /N -- take the adapter as it stands instead of bringing it up.  This is
; the old two-program arrangement, where USBLINK did the bring-up and this
; program only went resident over the top of it.  Worth keeping: it is the
; way to tell a fault in the bring-up apart from a fault in the driver,
; which is not a distinction the failure message can make on its own.
op_nobring: db 0

; Set the moment this program first speaks to the chip.  Any exit that does
; NOT go resident has to hand the chip back in a state the next program's
; bring-up can start from, and the only state that qualifies is "just
; reset".  Leaving it configured-but-idle is what wedged USBLINK on the
; following invocation -- its enumeration begins by waiting for a connect
; interrupt that a chip already past that point never raises again.
touched:    db 0

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
        jmp     near pa_more
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
        ; '?' before the upper-casing.  AND 0DFh clears bit 5, which folds
        ; letters and turns '?' (3Fh) into 1Fh -- the bug that stopped /?
        ; ever working in USBKBD.
        cmp     al, '?'
        jne     short pa_notq
        mov     byte [op_help], 1
        jmp     near pa_more
pa_notq:
        ; /8 before the fold as well -- '8' AND 0DFh is 18h, not a letter,
        ; so it has to be matched while it is still itself.
        cmp     al, '8'
        jne     short pa_not8
        mov     byte [op_no186], 1
        jmp     near pa_more
pa_not8:
        and     al, 0xDF
        cmp     al, 'U'
        jne     short pa_s2
        mov     byte [op_unload], 1
        jmp     near pa_more
pa_s2:
        cmp     al, 'S'
        jne     short pa_s3
        mov     byte [op_status], 1
        jmp     near pa_more
pa_s3:
        cmp     al, 'V'
        jne     short pa_s4
        mov     byte [op_verb], 1
        jmp     near pa_more
pa_s4:
        cmp     al, 'G'
        jne     short pa_s4x
        mov     byte [op_giga], 1
        jmp     near pa_more
pa_s4x:
        ; /X -- never use CDC-ECM, even on a device that offers it.  The
        ; only way to compare the two paths on one adapter.
        cmp     al, 'X'
        jne     short pa_s5
        mov     byte [op_noecm], 1
        jmp     near pa_more
pa_s5:
        ; /D -- never use the SR9700/DM9601 path.  The mirror of /X, and it
        ; exists for the same reason: the only honest way to show that a
        ; chipset path is the thing making a difference is to be able to
        ; turn it off on the same adapter and watch what stops.
        cmp     al, 'D'
        jne     short pa_s5d
        mov     byte [op_nosr], 1
        jmp     near pa_more
pa_s5d:
        ; /M -- accept all multicast on the SR9700.  It exists to make the
        ; claim in ADAPTERS.md testable rather than asserted: the filter is
        ; supposed to be the throughput setting on this part, and the only
        ; way to show that is to turn it the other way on the same adapter,
        ; on the same segment, and time the same download.
        cmp     al, 'M'
        jne     short pa_s5m
        mov     byte [op_mcast], 1
        jmp     near pa_more
pa_s5m:
        ; /P -- promiscuous on the SR9700.  Useful in its own right for a
        ; capture tool, and it settles the one difference left between this
        ; bring-up and SRLINK's: SRLINK writes RCR 3B and reads NSR C1,
        ; every variant of this one so far writes 31 or 39 and reads 81.
        ; The filter has no business affecting the link bit, which is
        ; precisely why the possibility is worth one run rather than an
        ; argument.
        cmp     al, 'P'
        jne     short pa_s5p
        mov     byte [op_promisc], 1
        jmp     near pa_more
pa_s5p:
        ; /A, not /N: /N already means "do not hook the timer" and has
        ; done since before this switch existed.  Taking a letter that is
        ; already spoken for makes the old switch silently do something
        ; else, which is a nasty way to break a documented option.
        cmp     al, 'A'
        jne     short pa_s5n
        mov     byte [op_nobring], 1
        jmp     near pa_more
pa_s5n:
        cmp     al, 'R'
        jne     short pa_s5r
        call    pa_decnum
        or      al, al
        je      short pa_r_done
        cmp     al, 16
        ja      short pa_r_done
        mov     [tick_n], al
pa_r_done:
        jmp     near pa_more
pa_s5r:
        cmp     al, 'Q'
        jne     short pa_s5q
        call    pa_decnum
        mov     [op_qtimer], al
        jmp     near pa_more
pa_s5q:
        cmp     al, 'T'
        jne     short pa_s6
        mov     byte [op_test], 1
        jmp     near pa_more
pa_s6:
        cmp     al, 'N'
        jne     short pa_s7
        mov     byte [op_nopoll], 1
        jmp     near pa_more
pa_s7:
        cmp     al, 'I'
        je      short pa_vec_arg
        jmp     near pa_more
pa_vec_arg:
        ; /I=nn -- the vector, in hex
        or      cx, cx
        jnz     short pa_vec_eq          ; jcxz has no near form on an 8086
        jmp     near pa_more
pa_vec_eq:
        cmp     byte [si], '='
        je      short pa_vec_go
        jmp     near pa_more
pa_vec_go:
        inc     si
        dec     cx
        xor     bx, bx
pa_vec_d:
        jcxz    pa_vec_set
        mov     al, [si]
        call    hexval
        jc      short pa_vec_set
        inc     si
        dec     cx
        push    cx
        mov     cl, 4
        shl     bx, cl
        pop     cx
        xor     ah, ah
        add     bx, ax
        jmp     short pa_vec_d
pa_vec_set:
        or      bx, bx
        jne     short pa_vec_store
        jmp     near pa_more
pa_vec_store:
        mov     [our_vec], bl
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

; --------------------------------------------------------------------------
; Is there a packet driver at vector BL?  The signature sits three bytes
; into the handler, which is the whole discovery mechanism the standard
; defines.  Returns CF set if one is there.
; --------------------------------------------------------------------------
vec_has_pkt:
        push    es
        push    ds
        push    si
        push    di
        xor     ax, ax
        mov     es, ax
        mov     al, bl
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     di, ax
        mov     ax, [es:di]              ; offset
        mov     dx, [es:di+2]            ; segment
        mov     bx, ax
        or      bx, dx
        je      short vhp_no             ; 0000:0000 is not a driver
        mov     ds, dx
        mov     si, ax
        add     si, 3
        push    cs
        pop     es
        mov     di, sig_pkt
        mov     cx, 8
        repe    cmpsb
        jne     short vhp_no
        pop     di
        pop     si
        pop     ds
        pop     es
        stc
        ret
vhp_no:
        pop     di
        pop     si
        pop     ds
        pop     es
        clc
        ret

sig_pkt:    db 'PKT DRVR'

; --------------------------------------------------------------------------
; Find a resident copy of ourselves.
;
; By looking at the one vector we would have installed on, and nowhere
; else.  A previous version walked the DOS MCB chain instead, which is how
; TSRs traditionally find themselves and is a bad trade here: it needs an
; undocumented DOS call, it reads structures this program does not own, and
; a walk that loses its place does not fail -- it loops, inside a program
; that has not installed anything yet and cannot be talked out of it.  It
; hung the machine twice.
;
; There is nothing to walk for.  If a copy is resident then our vector
; points at it, so the question is answered by one indirection: does the
; segment behind that vector carry our signature at 0103?  Constant time,
; no undocumented anything, and it cannot loop.
; --------------------------------------------------------------------------
res_seg:    dw 0

find_resident:
        push    es
        push    ds
        push    si
        push    di
        push    bx

        mov     word [cs:res_seg], 0
        xor     ax, ax
        mov     es, ax
        mov     al, [cs:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     ax, [es:bx+2]            ; the segment behind the vector
        or      ax, ax
        je      short fr_none            ; nothing there at all

        mov     ds, ax
        mov     si, SIG_OFS
        push    cs
        pop     es
        mov     di, sig_self
        mov     cx, 8
        repe    cmpsb
        jne     short fr_none
        mov     [cs:res_seg], ds         ; that is us
fr_none:
        pop     bx
        pop     di
        pop     si
        pop     ds
        pop     es
        mov     ax, [cs:res_seg]
        ret

sig_self:   db 'USBPKT01'

; ==========================================================================
; INIT
; ==========================================================================
; --------------------------------------------------------------------------
; Does this CPU have the 80186 instruction set -- REP INSB and REP OUTSB in
; particular?  Sets [has186], which the three byte-moving loops in the
; resident half read.
;
; Lifted from dosbridge's starter/cpu.pas, ORDER included, because the order
; is the part that is easy to get wrong:
;
;   1. FLAGS bits 12-15.  On the 8086/88, the V20/V30 and the 186 they read
;      back as 1 whatever is pushed; a 286 in real mode reads them as 0.
;   2. Within that group the undocumented AAD opcode (D5h) splits NEC from
;      Intel.  AAD takes a base operand: Intel honours it, NEC's parts
;      ignore it and always use 10.  With AH=1, AL=0 and base 11 an Intel
;      part answers 11 and a V20/V30 answers 10.
;   3. Only THEN the shift-count test splits 8086 from 186.  It is last on
;      purpose: sources disagree about whether the V20/V30 masks shift
;      counts, so by the time it runs, AAD has already ruled NEC out and it
;      is never asked that question.
;
; A 286 or later has the 186 instructions by definition and needs no further
; narrowing here.  Everything is restored, flags included -- this runs with
; interrupts on and must leave them that way.
; --------------------------------------------------------------------------
cpu_probe:
        push    ax
        push    cx
        pushf                            ; the caller's flags, back at the end
        pushf
        pop     ax
        and     ax, 0x0FFF               ; try to clear bits 12-15
        push    ax
        popf
        pushf
        pop     ax                       ; and see what actually stuck
        and     ax, 0xF000
        cmp     ax, 0xF000
        jne     short cpu_have           ; they cleared: 286 or later
        mov     ah, 1
        mov     al, 0
        db      0xD5, 0x0B               ; AAD with a base of 11
        cmp     al, 10
        je      short cpu_have           ; NEC V20/V30
        mov     al, 1
        mov     cl, 32
        shl     al, cl                   ; an 8086 shifts all 32 and lands on 0
        or      al, al
        jz      short cpu_none
cpu_have:
        mov     byte [has186], 1
cpu_none:
        popf                             ; caller's flags back
        pop     cx
        pop     ax
        ret

init:
        cld
        call    parse_args

        ; Before anything touches the chip: the byte-moving loops read
        ; [has186] and there is no later point at which setting it would
        ; still be early enough.
        cmp     byte [op_no186], 0
        jne     short init_no186
        call    cpu_probe
init_no186:
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
        mov     al, 'a'
        call    mark
        cmp     byte [op_status], 0
        je      short init_nostat
        jmp     near do_status
init_nostat:
        cmp     byte [op_unload], 0
        je      short init_nounload
        jmp     near do_unload
init_nounload:

        cmp     word [res_seg], 0
        je      short init_fresh
        mov     dx, msg_already
        call    puts
        mov     al, 1
        jmp     near die

init_fresh:
        ; ---- the two refusals.  Neither can be overridden, because there
        ; is no legitimate reason to want either and the cost of being
        ; wrong is a trip to the machine. ----
        cmp     byte [our_vec], 0x60
        jne     short init_not60
        mov     dx, msg_no60
        call    puts
        mov     al, 4
        jmp     near die
init_not60:
        mov     bl, [our_vec]
        call    vec_has_pkt
        jnc     short init_vecfree
        mov     dx, msg_vectaken
        call    puts
        mov     al, [our_vec]
        call    puthex
        mov     dx, msg_vectaken2
        call    puts
        mov     al, 5
        jmp     near die
init_vecfree:
        mov     al, 'b'
        call    mark

        ; ---- is the chip there ----
        mov     al, CMD_CHECK_EXIST
        call    ch_cmd
        mov     al, 0x55
        call    ch_wr
        call    ch_rd
        cmp     al, 0xAA
        je      short init_chip
        mov     dx, msg_nochip
        call    puts
        mov     al, 1
        jmp     near die
init_chip:
        mov     byte [touched], 1
        mov     al, 'c'
        call    mark

        ; ---- bring the adapter up, all of it ----
        cmp     byte [op_nobring], 0
        je      short init_dobring
        mov     dx, msg_nobring
        call    puts
        ; The MAC is still ours to read: it is what we hand to whoever
        ; calls get_address, and the adapter is the only thing that knows
        ; it.  /N skips the bring-up, not the driver's own homework.
        mov     byte [touched], 1
        xor     al, al
        call    set_retry
        call    read_mac
        jnc     short init_gotmac
        mov     dx, msg_nomac
        call    puts
        ; The status matters here.  2A is a NAK -- the device is awake
        ; and busy; 20/24/28/2C are timeouts -- it is not answering at
        ; all; 2E is a stall.  Without it this message says only that
        ; something went wrong, which is where an evening went.
        mov     dx, msg_macst
        call    puts
        mov     al, [bu_st]
        call    puthex
        mov     dx, msg_crlf
        call    puts
        mov     al, 6
        jmp     near die
init_dobring:
        mov     dx, msg_bringup
        call    puts
        call    ax_bringup
        jnc     short init_gotmac
        mov     dx, msg_bufail
        call    puts
        mov     al, [bu_step]
        xor     ah, ah
        call    putdecw
        mov     dx, msg_bureg
        call    puts
        mov     al, [bu_reg]
        call    puthex
        mov     dx, msg_bust
        call    puts
        mov     al, [bu_st]
        call    puthex
        mov     dx, msg_bufail2
        call    puts
        mov     al, 6
        jmp     near die
init_gotmac:
        ; Put both bulk endpoints back to DATA0 before the resident half
        ; starts polling, because rx_tog and tx_tog are assembled as 80h
        ; and nothing else ever resynchronises them.
        ;
        ; After our own bring-up this is a no-op: SET_CONFIGURATION has
        ; just reset every endpoint.  After /A it is the whole game.
        ; USBLINK says 'the adapter is initialised and receiving' and it
        ; means it -- frames have been arriving and the device's toggle
        ; has moved on, so the driver's first IN asked for DATA0 while
        ; the device was sending DATA1.  The CH375 does not police that
        ; on an IN token; it hands over whatever came back.  What came
        ; back was the same packet again and again: 1536 bytes of a
        ; repeating four-byte pattern, 521 bursts out of 522 rejected.
        ;
        ; CLEAR_FEATURE(ENDPOINT_HALT) resets the toggle at BOTH ends,
        ; which is exactly the handshake needed to adopt an endpoint
        ; somebody else was already using.
        mov     al, [ep_in_n]            ; the endpoint NUMBER -- ch375.pas
        call    clr_ep                   ; passes 2, not 82h.  Read from the
        mov     al, [ep_out_n]           ; variables because an ECM adapter
        call    clr_ep                   ; names its own endpoints
        mov     byte [rx_tog], 0x80
        mov     byte [tx_tog], 0x80

        mov     al, [link_mode]
        cmp     al, LM_AX
        je      short init_sayax
        cmp     al, LM_SR
        jne     short init_sayecm
        mov     dx, msg_i_sr
        call    puts
        jmp     short init_saidit
init_sayecm:
        ; No 'link up' here: ECM reports the link through its interrupt
        ; endpoint, on CHANGE, and a device that has just been configured
        ; has not changed anything yet.  Claiming a link we have not been
        ; told about would be worse than saying nothing.
        mov     dx, msg_i_ecm
        call    puts
        jmp     short init_saidit
init_sayax:
        mov     dx, msg_buok
        call    puts
init_saidit:
        mov     al, 'd'
        call    mark

        mov     dx, msg_mac
        call    puts
        mov     cx, 6
        mov     si, mac
init_macl:
        lodsb
        call    puthex
        cmp     cx, 1
        je      short init_macskip
        mov     al, ':'
        call    putc
init_macskip:
        loop    init_macl
        call    crlf

        cmp     byte [op_test], 0
        jne     short __ii
        jmp     near init_install
__ii:
        mov     dx, msg_testonly
        call    puts
        jmp     near quit
init_install:

        ; ---- hook the vector, and INT 08h for the polling ----
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [cs:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [si]
        mov     [cs:old_vec], ax
        mov     ax, [si+2]
        mov     [cs:old_vec+2], ax
        cli
        mov     word [si], pkt_entry
        mov     [si+2], cs
        ; INT 08h -- /N leaves the timer alone, which installs a driver
        ; that can be interrogated but never collects a packet.  It exists
        ; to tell an install fault from an ISR fault, because from the
        ; outside both look identical: a machine that stops answering.
        cmp     byte [cs:op_nopoll], 0
        je      short __in8
        jmp     near init_no08
__in8:
        mov     ax, [0x08*4]
        mov     [cs:old08], ax
        mov     ax, [0x08*4+2]
        mov     [cs:old08+2], ax
        mov     word [0x08*4], isr08
        mov     [0x08*4+2], cs
init_no08:
        sti
        pop     ds

        ; Speed the timer up, but only if we hooked it: /N leaves both the
        ; vector and the rate alone.
        cmp     byte [op_nopoll], 0
        jne     short init_nopit
        cmp     byte [tick_n], 2
        jb      short init_nopit         ; 1 = leave the clock alone
        call    pit_fast
init_nopit:

        mov     dx, msg_installed
        call    puts
        mov     al, [our_vec]
        call    puthex
        mov     dx, msg_installed2
        call    puts

        ; ---- go resident ----
        mov     dx, (resident_end - start + 0x100 + 15) >> 4
        mov     ax, 0x3100
        int     0x21

; ==========================================================================
; /S
; ==========================================================================
do_status:
        cmp     word [res_seg], 0
        jne     short stat_have
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     near die
stat_have:
        mov     dx, msg_isres
        call    puts
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, ver_str
        call    puts
        pop     ds
        call    crlf

        mov     es, [res_seg]

        mov     dx, msg_s_vec
        call    puts
        mov     al, [es:our_vec]
        call    puthex
        call    crlf

        mov     dx, msg_s_base
        call    puts
        mov     ax, [es:io_dat]
        call    puthexw
        call    crlf

        ; WHICH protocol, because every counter below it means something
        ; different depending on the answer -- the burst counters police a
        ; layout the class path does not have, so zeros there are correct
        ; rather than alarming.
        mov     dx, msg_s_path
        call    puts
        mov     dx, msg_p_ax
        mov     al, [es:link_mode]
        cmp     al, LM_AX
        je      short stat_path
        mov     dx, msg_p_sr
        cmp     al, LM_SR
        je      short stat_path
        mov     dx, msg_p_ecm
stat_path:
        call    puts
        call    crlf

        ; The link block belongs to ECM alone: it reports what the
        ; NOTIFICATION endpoint has said, and the SR9700 has no
        ; notification endpoint -- it keeps its link state in a register,
        ; which is a control transfer away and therefore not something to
        ; read from a status call that may run inside anything.
        cmp     byte [es:link_mode], LM_ECM
        jne     short stat_nolink
        mov     dx, msg_s_link
        call    puts
        mov     dx, msg_l_unk
        mov     al, [es:link_st]
        cmp     al, 0xFF
        je      short stat_lsay
        mov     dx, msg_l_down
        or      al, al
        je      short stat_lsay
        mov     dx, msg_l_up
stat_lsay:
        call    puts
        mov     dx, msg_l_note
        call    puts
        mov     ax, [es:n_notify]
        call    putdecw
        call    crlf

        mov     dx, msg_s_tok
        call    puts
        mov     al, [es:tok_in]
        call    puthex
        mov     dx, msg_s_tok2
        call    puts
        mov     al, [es:tok_out]
        call    puthex
        call    crlf
stat_nolink:

        mov     dx, msg_s_bmov
        call    puts
        mov     dx, msg_bmov_slow
        cmp     byte [es:has186], 0
        je      short stat_bmov
        mov     dx, msg_bmov_fast
stat_bmov:
        call    puts
        call    crlf

        mov     dx, msg_s_mac
        call    puts
        mov     cx, 6
        xor     si, si
stat_macl:
        mov     al, [es:si+mac]
        call    puthex
        cmp     cx, 1
        je      short stat_macskip
        mov     al, ':'
        call    putc
stat_macskip:
        inc     si
        loop    stat_macl
        call    crlf

        mov     dx, msg_s_handles
        call    puts
        mov     al, [es:n_handles]
        xor     ah, ah
        call    putdecw
        call    crlf

        mov     dx, msg_s_ticks
        call    puts
        mov     ax, [es:n_ticks]
        call    putdecw
        call    crlf

        mov     dx, msg_s_bursts
        call    puts
        mov     ax, [es:n_bursts]
        call    putdecw
        call    crlf

        mov     dx, msg_s_frames
        call    puts
        mov     ax, [es:n_frames]
        call    putdecw
        call    crlf

        mov     dx, msg_s_nohandle
        call    puts
        mov     ax, [es:n_nohandle]
        call    putdecw
        call    crlf

        mov     dx, msg_s_short
        call    puts
        mov     ax, [es:n_short]
        call    putdecw
        call    crlf

        mov     dx, msg_s_junk
        call    puts
        mov     ax, [es:n_junk]
        call    putdecw
        call    crlf

        mov     dx, msg_s_over
        call    puts
        mov     ax, [es:n_over]
        call    putdecw
        call    crlf

        mov     dx, msg_s_tile
        call    puts
        mov     ax, [es:n_tile]
        call    putdecw
        or      ax, ax
        je      short stat_notile
        mov     dx, msg_s_tile2
        call    puts
        mov     ax, [es:tile_di]
        call    putdecw
        mov     dx, msg_s_tile3
        call    puts
        mov     ax, [es:tile_lim]
        call    putdecw
        mov     dx, msg_s_tile4          ; the ')' belongs to the line that
        call    puts                     ; opened it.  It used to be the
                                         ; first character of the NEXT
                                         ; message, so a run with no tiling
                                         ; fault printed a bare ')' at the
                                         ; start of an unrelated counter --
                                         ; which reads as truncated output
stat_notile:
        call    crlf

        mov     dx, msg_s_junk2
        call    puts
        mov     ax, [es:junk_len]
        call    putdecw
        mov     dx, msg_s_junk3
        call    puts
        mov     ax, [es:junk_at]
        call    putdecw
        mov     dx, msg_s_junk4
        call    puts
        mov     ax, [es:junk_burst]
        call    putdecw
        mov     dx, msg_s_junk5
        call    puts
        mov     al, [es:junk_prev]
        xor     ah, ah
        call    putdecw
        mov     dx, msg_s_junk6
        call    puts
        mov     ax, [es:junk_prevleft]
        call    putdecw
        call    crlf

        mov     dx, msg_s_resync
        call    puts
        mov     ax, [es:n_resync]
        call    putdecw
        call    crlf

        mov     dx, msg_s_empty
        call    puts
        mov     ax, [es:n_empty]
        call    putdecw
        call    crlf

        mov     dx, msg_s_flush
        call    puts
        mov     ax, [es:n_flush]
        call    putdecw
        call    crlf

        mov     dx, msg_s_outside
        call    puts
        mov     ax, [es:n_outside]
        call    putdecw
        call    crlf

        mov     dx, msg_s_tog
        call    puts
        mov     ax, [es:n_toggle]
        call    putdecw
        call    crlf

        mov     dx, msg_s_rxst
        call    puts
        mov     al, [es:rx_st]
        call    puthex
        mov     dx, msg_s_rxlen
        call    puts
        mov     al, [es:rx_len]
        call    puthex
        call    crlf

        mov     dx, msg_s_sent
        call    puts
        mov     ax, [es:st_pkts_out]
        call    putdecw
        call    crlf

        mov     dx, msg_s_rate
        call    puts
        mov     al, [es:tick_n]
        xor     ah, ah
        call    putdecw
        call    crlf

        ; The peak poll.  Printed in PIT counts as well as milliseconds
        ; because the counts are what was actually measured and the
        ; milliseconds are a division done here -- if the two ever
        ; disagree with each other, the raw number is the one to trust.
        ; A dash rather than a zero when nothing was timed: 0.0 ms would
        ; read as "measured, and free", which is the opposite of the
        ; truth.
        mov     dx, msg_s_isr
        call    puts
        mov     ax, [es:isr_max]
        or      ax, ax
        jnz     short stat_isr_have
        mov     dx, msg_s_isrnone
        call    puts
        call    crlf
        jmp     short stat_isr_done
stat_isr_have:
        call    putdecw
        mov     dx, msg_s_isr2
        call    puts
        mov     ax, [es:isr_max]
        xor     dx, dx
        mov     bx, 1193                 ; counts per millisecond
        div     bx
        push    dx                       ; the remainder, for the tenth
        call    putdecw
        mov     al, '.'
        call    putc
        pop     ax
        xor     dx, dx
        mov     bx, 119
        div     bx
        call    putdecw
        mov     dx, msg_s_isr3
        call    puts
        call    crlf
stat_isr_done:

        mov     dx, msg_s_peek
        call    puts
        mov     cx, 16
        xor     si, si
stat_peek:
        mov     al, [es:si+tx_peek]
        call    puthex
        mov     al, ' '
        call    putc
        inc     si
        loop    stat_peek
        call    crlf

        mov     dx, msg_s_rxpk
        call    puts
        mov     ax, [es:rx_peeklen]
        call    putdecw
        mov     dx, msg_s_rxpk2
        call    puts
        call    crlf
        mov     cx, 64
        xor     si, si
stat_rxpeek:
        test    si, 15
        jnz     short stat_rxnowrap
        call    crlf
        mov     al, ' '
        call    putc
        mov     al, ' '
        call    putc
stat_rxnowrap:
        mov     al, [es:si+rx_peek]
        call    puthex
        mov     al, ' '
        call    putc
        inc     si
        loop    stat_rxpeek
        call    crlf

        xor     al, al
        jmp     near die

; ==========================================================================
; /U
; ==========================================================================
do_unload:
        cmp     word [res_seg], 0
        jne     short unl_have
        mov     dx, msg_notres
        call    puts
        mov     al, 1
        jmp     near die
unl_have:
        mov     es, [res_seg]

        ; Refuse if anything hooked either vector after us.  Unhooking out
        ; of order leaves whatever came later pointing into memory that is
        ; about to be handed back, and the machine dies at a moment
        ; unrelated to anything visible.
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [es:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [si+2]
        pop     ds
        mov     bx, es
        cmp     ax, bx
        je      short unl_vecok
        mov     dx, msg_hooked
        call    puts
        mov     al, 7
        jmp     near die
unl_vecok:
        cmp     byte [es:op_nopoll], 0
        jne     short unl_08ok           ; never hooked it
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     ax, [0x08*4+2]
        pop     ds
        mov     bx, es
        cmp     ax, bx
        je      short unl_08ok
        mov     dx, msg_hooked08
        call    puts
        mov     al, 7
        jmp     near die
unl_08ok:

        ; Put both back, then release the block.
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     al, [es:our_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        cli
        mov     ax, [es:old_vec]
        mov     [si], ax
        mov     ax, [es:old_vec+2]
        mov     [si+2], ax
        cmp     byte [es:op_nopoll], 0
        jne     short unl_no08
        mov     ax, [es:old08]
        mov     [0x08*4], ax
        mov     ax, [es:old08+2]
        mov     [0x08*4+2], ax
unl_no08:
        sti
        pop     ds

        ; The timer rate goes back before the memory does.  Leaving the PIT
        ; fast with our handler gone means the BIOS clock runs eight times
        ; quick and nothing on the machine knows why.
        cmp     byte [es:pit_fast_on], 0
        je      short unl_nopit
        push    es
        call    pit_slow_far
        pop     es
unl_nopit:

        ; Tear the adapter down before the memory goes.  Leaving it
        ; configured and running is not harmless: a device already past
        ; enumeration does not answer a fresh one, so unload-then-load used
        ; to fail at the device descriptor and read as a fault in the card.
        ; Use the base the RESIDENT copy is using, not our own default --
        ; they are only the same when /U was given no @base.
        push    es
        mov     ax, [es:io_cmd]
        mov     [cs:io_cmd], ax
        mov     ax, [es:io_dat]
        mov     [cs:io_dat], ax
        mov     byte [cs:touched], 1
        ; This invocation never enumerated anything -- the copy going
        ; resident did.  Say so, or the teardown skips the only part that
        ; the device itself acts on.
        mov     byte [cs:dev_live], 1
        call    usb_down
        pop     es

        mov     ah, 0x49                 ; release the resident block
        int     0x21

        mov     dx, msg_unloaded
        call    puts
        xor     al, al
        jmp     near die

; Every exit that is not "went resident" comes through here.  If the chip
; was touched, reset it: a program that leaves shared hardware half-set-up
; breaks the NEXT program, which is a much worse thing to debug than
; failing honestly on the spot.
; pit_slow lives in the resident image; call it there rather than keeping a
; second copy here that could disagree with it.
pit_slow_far:
        push    ax
        mov     al, 0x36
        out     0x43, al
        xor     al, al
        out     0x40, al
        out     0x40, al
        pop     ax
        ret

quit:
        xor     al, al
die:
        cmp     byte [cs:touched], 0
        je      short die_now
        push    ax
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        ; The chip needs a moment after a reset before it will answer
        ; again, and the next program will start by talking to it.
        mov     cx, 0xFFFF
die_wait:
        push    dx
        mov     dx, 0x61
        in      al, dx
        pop     dx
        loop    die_wait
        pop     ax
die_now:
        mov     ah, 0x4C
        int     0x21

; ==========================================================================
; MESSAGES
; ==========================================================================
msg_prog:      db 'USBPKT $'
msg_by:        db ' -- StevenC', 13, 10, '$'

msg_help:
        db 13, 10
        db 'A packet driver for a USB Ethernet adapter on a CH375 card,', 13, 10
        db 'so mTCP and anything else speaking the Crynwr interface can', 13, 10
        db 'use it.  One command: it brings the adapter up itself.', 13, 10
        db 13, 10
        db '  USBPKT          load it at vector 65h', 13, 10
        db '  USBPKT /I=6A    ...at 6Ah instead', 13, 10
        db '  USBPKT /S       report what it is doing', 13, 10
        db '  USBPKT /U       unload', 13, 10
        db 13, 10
        db 'OTHER  @nnn CH375 I/O base in hex, default 260', 13, 10
        db '       /G   leave the PHY at gigabit    /V  trace', 13, 10
        db '       /R=n timer divisor 1..16, default 1.  The poll rate is', 13, 10
        db '            18.2*n Hz and it IS the latency: 1 leaves the', 13, 10
        db '            clock alone and answers in about 55ms.  Raise it', 13, 10
        db '            for a big transfer, never in AUTOEXEC.BAT', 13, 10
        db '       /8   use the 8086 byte loops even on a CPU that has', 13, 10
        db '            REP INSB.  The fast path is the default where it', 13, 10
        db '            exists; this is how to rule it out in one command', 13, 10
        db '       /T   check the adapter and STOP, installing nothing', 13, 10
        db '       /A   take the adapter as it stands: skip the bring-up', 13, 10
        db '            because USBLINK or an earlier run already did it', 13, 10
        db '       /N   install but do not hook the timer: no packets are', 13, 10
        db '            collected, which tells an install fault from an', 13, 10
        db '            ISR one when both just look like a dead machine', 13, 10
        db 13, 10
        db 'CHIPSET  it picks one itself: CDC-ECM from the descriptors, the', 13, 10
        db '         SR9700/DM9601 from the USB ID, else the AX88179.', 13, 10
        db '       /X   never use CDC-ECM      /D  never use the SR9700', 13, 10
        db '            Turning a path off on an adapter that offers it is', 13, 10
        db '            the only honest way to show it made the difference', 13, 10
        db '       /P   SR9700 only: promiscuous -- every frame on the', 13, 10
        db '            segment, for a capture tool.  Implies /M', 13, 10
        db '       /M   SR9700 only: accept ALL multicast.  Off by default', 13, 10
        db '            because a packet driver should deliver what was', 13, 10
        db '            asked for, not everything.  Measured cost of', 13, 10
        db '            turning it on: about 1% of throughput -- NOT the', 13, 10
        db '            large number the per-frame arithmetic suggests', 13, 10
        db 13, 10
        db 'VECTOR 60h IS REFUSED, and so is any vector already holding a', 13, 10
        db 'packet driver.  On this machine 60h is the network you are', 13, 10
        db 'reading this over; installing on top of it would take the box', 13, 10
        db 'off the air with no way back in.  PKTSCAN lists what is free.', 13, 10
        db 13, 10
        db 'DO NOT PUT THIS IN AUTOEXEC.BAT.  Loaded from the prompt, a', 13, 10
        db 'mistake costs a power cycle; loaded at boot, it costs a walk', 13, 10
        db 'to the machine.', 13, 10, '$'

msg_already:   db 'USBPKT is already loaded.  /U unloads it, /S reports.', 13, 10, '$'
msg_notres:    db 'USBPKT is not loaded.', 13, 10, '$'
msg_no60:
        db 'Refusing vector 60h.', 13, 10
        db 'That is where a packet driver normally lives, and on this', 13, 10
        db 'machine it is the network everything else depends on.  Pick', 13, 10
        db 'another with /I=nn; PKTSCAN lists the free ones.', 13, 10, '$'
msg_vectaken:  db 'Refusing vector $'
msg_vectaken2:
        db 'h: a packet driver is already there.', 13, 10
        db 'Two cannot share one.  PKTSCAN lists the free vectors.', 13, 10, '$'
msg_nochip:
        db 'No CH375 answers at that address.  USBSCAN finds the card.', 13, 10, '$'
msg_nomac:
        db 'The adapter did not return its MAC address.', 13, 10, '$'
msg_macst:     db 'Chip status on the last try: $'
msg_crlf:      db 13, 10, '$'
msg_mac:       db 'MAC address: $'
msg_bringup:   db 'Bringing the adapter up...$'
msg_nobring:   db 'Taking the adapter as it stands (/A).', 13, 10, '$'
msg_buok:      db ' link up.', 13, 10, '$'
msg_bufail:    db ' FAILED at step $'
msg_bureg:     db ', register $'
msg_bust:      db ', chip status $'
msg_bufail2:
        db '.', 13, 10
        db '20-26 are the USB side: 20 chip reset, 21 host mode, 22 bus', 13, 10
        db 'reset, 23 device descriptor, 24 address, 25 config descriptor,', 13, 10
        db '26 set configuration.  1-11 are the adapter: 1-2 PHY power,', 13, 10
        db '3 clocks, 4 MAC read, 5 bulk queue, 6 pause, 7 offload off,', 13, 10
        db '8 receiver on, 9 autonegotiation, 10 link, 11 medium mode.', 13, 10
        db 13, 10
        db 13, 10
        db 'STEP 23 WITH STATUS FF is the common one, and it is almost', 13, 10
        db 'never a broken adapter.  It means the device is already', 13, 10
        db 'enumerated -- by an earlier USBPKT, or by NETID or USBLINK,', 13, 10
        db 'which enumerate it just to look at it.  A device that is', 13, 10
        db 'already configured answers nothing at address 0, and a bus', 13, 10
        db 'reset does not always persuade it otherwise.', 13, 10
        db 13, 10
        db '  The cure is to remove its power: unplug the adapter and', 13, 10
        db '  plug it back in, or power-cycle the machine, which does the', 13, 10
        db '  same thing because the card feeds it off the ISA bus.', 13, 10
        db '  Resetting the CH375 does not, which is why nothing this', 13, 10
        db '  program can do on its own always clears it.', 13, 10
        db 13, 10
        db '  To avoid it: run USBPKT FIRST, before NETID or USBLINK.  It', 13, 10
        db '  needs neither of them -- it does the whole bring-up itself.', 13, 10
        db 13, 10
        db 'Step 10 means the cable or the far end.  20-22 mean the card', 13, 10
        db 'or nothing plugged into it.  Anything else means the adapter.', 13, 10
        db 'USBLINK /V walks the same ground printing the chip status at', 13, 10
        db 'every access.', 13, 10, '$'
msg_testonly:
        db 'That is /T: everything up to reading the adapter worked, and', 13, 10
        db 'nothing was installed.  Drop /T to go resident.', 13, 10, '$'
msg_installed: db 'Resident at vector $'
msg_installed2:
        db 'h.  Point mTCP at it with PACKETINT in its', 13, 10
        db 'config -- and use a COPY of MTCP.CFG, not the one the working', 13, 10
        db 'network uses.', 13, 10, '$'
msg_unloaded:  db 'USBPKT unloaded.', 13, 10, '$'
msg_hooked:
        db 'Cannot unload: something hooked our vector after us.', 13, 10, '$'
msg_hooked08:
        db 'Cannot unload: something hooked INT 08h after us.', 13, 10, '$'

msg_isres:     db 'Loaded: USBPKT $'
msg_s_vec:     db '  vector=$'
msg_s_base:    db '  I/O base=$'
msg_e_geom:    db 'ECM: cfg $'
msg_e_ctl:     db ' ctl if $'
msg_e_dat:     db ' data if $'
msg_e_alt:     db ' alt $'
msg_e_eps:     db ' ep in $'
msg_e_epo:     db ' out $'
msg_e_epi:     db ' int $'
msg_e_filt:    db ' filter REFUSED$'
msg_s_link:    db '  link=$'
msg_l_up:      db 'UP$'
msg_l_down:    db 'DOWN$'
msg_l_unk:     db 'not stated (sent on CHANGE, so this is not "down")$'
msg_l_note:    db '  notifications=$'
msg_s_tok:     db '  tokens in=$'
msg_s_tok2:    db ' out=$'
msg_s_path:    db '  protocol=$'
msg_p_ecm:     db 'CDC-ECM (class, from the descriptors)$'
msg_p_sr:      db 'SR9700/DM9601 vendor (from the USB ID)$'
msg_r_geom:    db 'SR9700: cfg $'
msg_r_if:      db ' net if $'
msg_r_mass:    db '  (mass storage on if $'
msg_r_mass2:   db ')$'
msg_r_link:    db 'SR9700: NSR $'
msg_r_nsr:     db ' -- link $'
msg_i_sr:      db 'SR9700/DM9601 adapter - using the vendor driver.', 13, 10, '$'
msg_p_ax:      db 'AX88179 vendor$'
msg_i_ecm:     db 'CDC-ECM adapter - using the class driver.', 13, 10, '$'
msg_s_bmov:    db '  byte moves=$'
msg_bmov_fast: db 'REP INSB/OUTSB$'
msg_bmov_slow: db '8086 loops$'
msg_s_mac:     db '  MAC=$'
msg_s_handles: db '  open handles=$'
msg_s_ticks:   db '  timer ticks=$'
msg_s_bursts:  db '  bursts collected=$'
msg_s_frames:  db '  frames delivered=$'
msg_s_nohandle:db '  frames nobody wanted=$'
msg_s_short:   db '  bursts that made no sense=$'
msg_s_junk:    db '  reads with an impossible length=$'
msg_s_over:    db '  bursts too big for the buffer=$'
msg_s_tile:    db '  bursts whose frames did not tile=$'
msg_s_tile2:   db '  (last ended at $'
msg_s_tile3:   db ', wanted $'
msg_s_tile4:   db ')$'
msg_s_junk2:   db '  (last impossible length was $'
msg_s_junk3:   db ' at offset $'
msg_s_junk4:   db ' of $'
msg_s_junk5:   db '; the burst before it ended $'
msg_s_junk6:   db ' leaving $'
msg_s_resync:  db ')  bursts realigned by search=$'
msg_s_empty:   db '  empty records stepped over=$'
msg_s_flush:   db '  transfers abandoned part-read=$'
msg_s_outside: db '  frames past the frame region=$'
msg_s_tog:     db '  reads rescued by flipping the toggle=$'
msg_s_rxst:    db '  last bulk IN: status $'
msg_s_rxlen:   db ', length $'
msg_s_sent:    db '  frames sent=$'
msg_s_rate:    db '  timer divisor (/R)=$'
msg_s_isr:     db '  longest poll=$'
msg_s_isr2:    db ' counts, $'
msg_s_isr3:    db ' ms$'
msg_s_isrnone: db '-- (only timed at /R=1)$'
msg_s_peek:    db '  last frame out=$'
msg_s_rxpk:    db '  last burst rejected: len=$'
msg_s_rxpk2:   db ' data=$'
