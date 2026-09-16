; ==========================================================================
; ch375io.inc -- the register primitives: command, data, status, and the
;                bounded wait for the chip's interrupt.
;
; SHARED between CH375Mouse's USBMOUSE.COM and the FOSSIL driver in
; DOSBridge's projects/fossil.  It was duplicated in both for a while, on
; the deliberate grounds that usbmouse.asm was working, shipped code and a
; new driver had not yet earned the right to put it at risk.  The FOSSIL
; driver has earned it, so there is one copy now.
;
; THE REASON THIS MATTERS is not tidiness.  The SET_RETRY split has been
; rediscovered FIVE times across these projects, each time as a machine that
; had become unusably slow, because the knowledge lived in three places and
; only one of them had been fixed.  A rule written down once can only be
; wrong once.
;
; Each include sits at the exact position its code held before, so that
; assembling the mouse driver still produces a BYTE-IDENTICAL USBMOUSE.COM.
; That is the check that the extraction changed nothing, and for a pure move
; it is stronger than any hardware test: identical bytes are the same
; program.  Anything a caller needs that the mouse does not is behind an
; %ifdef for the same reason.
;
;   CH375_COUNTERS   define it to have failed transfers recorded in
;                    last_st and ch_err.  The caller declares both.
; ==========================================================================

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
