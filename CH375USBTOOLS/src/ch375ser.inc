; ==========================================================================
; ch375ser.inc -- the SET_RETRY split, a vendor request on endpoint 0,
;                 and a bulk OUT with its own data toggle.
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

;       145 Hz timer and the machine spends its life in the interrupt.  It
;       made DOS unusable here and needed a reboot.
;
; Every occurrence had the same cause: a new code path that polls an
; endpoint somewhere the existing call did not reach.  So the call now
; belongs to the thing that OPENS A PORT rather than to each caller --
; ser_poll_ready is invoked from ser_open's tail, where no new family or
; new branch can miss it.
; --------------------------------------------------------------------------
set_retry_n:                             ; AL = the retry byte
        push    ax
        mov     al, CMD_SET_RETRY
        call    ch_cmd
        mov     al, 0x25
        call    ch_wr
        pop     ax
        call    ch_wr
        ret

ser_enum_ready:                          ; about to enumerate
        mov     al, 0x8F
        jmp     short set_retry_n

ser_poll_ready:                          ; about to poll an endpoint
        xor     al, al
        jmp     short set_retry_n

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
%ifdef CH375_COUNTERS
        mov     [last_st], al
        inc     word [ch_err]
%endif
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
%ifdef CH375_COUNTERS
        inc     word [ch_err]
%endif
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
