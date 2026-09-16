; ==========================================================================
; ch375r.inc -- the CH375 transport, RESIDENT half.
;
; Included by fossil.asm ABOVE the rings, so everything here stays inside
; the block the TSR call keeps.
;
; PROVENANCE.  The CH375 primitives, the enumeration order, the endpoint
; walk and the per-family open sequences are adapted from
; CH375Mouse/src/usbmouse.asm and CH375Serial/src/dser.pas, both of which
; are verified on this hardware.  They are COPIED rather than shared, which
; is a deliberate choice and not laziness: usbmouse.asm is working, shipped
; code that took a long time to get right, and refactoring it to be
; includable would put that at risk to save duplication in a driver that
; has not yet proved itself.  If this transport earns its place, the two
; should be unified then -- and the CH375Serial README's rule applies, that
; the serial half must not know which adapter it is behind.
;
; WHAT IS DIFFERENT FROM THE MOUSE DRIVER, and why
;
;   * It TRANSMITS.  A mouse never sends, so usbmouse.asm's bulk_out_ser is
;     used only to configure a Keyspan and lives in its transient section.
;     Here it is the hot path in one direction and has to be resident.
;
;   * Bytes are taken out of the transmit ring WITHOUT being consumed, and
;     the tail only moves once the CH375 reports the packet went.  A failed
;     bulk OUT therefore costs a retry rather than the data.
;
;   * The baud rate is not 1200.  A mouse is 1200 and nothing else, so the
;     mouse driver hardcodes every divisor; a FOSSIL has to honour function
;     00h, so the divisors are computed and ser_open is resident.
;
;   * No power cycle on open.  usbmouse.asm drops RTS and DTR and raises
;     them again because a serial MOUSE is powered from those lines and
;     picks its protocol when they come up.  A modem is not, and doing it
;     anyway would hang up a live call.
;
; THE ONE GENUINELY NEW HAZARD.  In the mouse driver only the timer tick
; ever touched the CH375.  Here INT 14h touches it too -- function 00h
; reprograms the adapter and function 06h moves the control lines -- and a
; tick landing in the middle of one of those would interleave two register
; sequences on one chip.  fg_busy is the interlock: the foreground sets it
; before it starts, and the tick skips its poll while it is set.  A single
; byte is enough because there is one CPU: while foreground code is running
; no interrupt handler is, so the flag can never be set half way.
; ==========================================================================

; CH375 command codes, statuses and token PIDs, shared -- see ch375def.inc.
%include "ch375def.inc"

; Ask the shared code to record failures; this file declares both counters.
%define CH375_COUNTERS 1

SER_RBUFSZ       equ 72          ; one bulk IN packet, with room to spare
SER_TBUFSZ       equ 64          ; one bulk OUT packet

; ---- CH375 state ----
io_dat:   dw    0x260
io_cmd:   dw    0x261
ch_live:  db    0               ; 1 = enumerated and pollable
fg_busy:  db    0               ; the foreground owns the chip right now
ep_in:    db    0               ; bulk IN endpoint
ep_tog:   db    0x80            ; SET_ENDP6 argument: bit 6 is the toggle
ser_out:  db    0               ; bulk OUT carrying data
ser_ctl:  db    0               ; bulk OUT carrying the port control message
ser_ctog: db    0x80            ; toggle for the OUT endpoint
ser_hdr:  db    0               ; status bytes at the head of every IN packet
ser_anyep: db   0               ; take endpoints whatever type they claim
ser_vid:  dw    0
ser_pid:  dw    0
ser_bits: db    8               ; data bits
ser_par:  db    0               ; 0 none, 1 odd, 2 even
ser_stop: db    1
ser_baud: dw    9600            ; the rate the port is open at
ser_batch: db   32              ; RXFWDLEN: bytes the adapter gathers per packet
cfg_val:  db    1
cfg_len:  db    0
ic_ver:   db    0
last_st:  db    0               ; last non-success CH375 status

ch_rx_pk: dw    0               ; IN packets that carried data
ch_tx_pk: dw    0               ; OUT packets sent
ch_err:   dw    0               ; transfers the chip refused

ser_rbuf: times SER_RBUFSZ db 0
ser_tbuf: times SER_TBUFSZ db 0
ser_msg:  times 34 db 0         ; the Keyspan control block
desc_buf: times 18 db 0         ; device descriptor

; ==========================================================================
; CH375 primitives.  Every OUT is followed by one `jmp short $+2` hop: the
; vendor driver measured that a CH375 on an ISA card needs the gap after a
; command write, and going to zero there risks silent corruption for about
; 1.5% of throughput we do not need.
; ==========================================================================
; The CH375 register primitives, shared -- see ch375io.inc.
%include "ch375io.inc"
; --------------------------------------------------------------------------
; The SET_RETRY split, the endpoint-0 vendor request and the bulk OUT are
; shared with CH375Mouse -- see ch375ser.inc.  CH375_COUNTERS is defined
; above, so failures land in last_st and ch_err.
;
; Note it does NOT issue CLD, because the mouse driver's copy never did and
; the extraction had to stay byte-identical.  Callers here clear the
; direction flag themselves; bulk_out_ser walks its buffer with LODSB.
; --------------------------------------------------------------------------
%include "ch375ser.inc"
; --------------------------------------------------------------------------
; 32-bit by 16-bit divide.  DX:AX / BX -> DX:AX, because the FTDI divisor
; is 24,000,000/baud and at 300 baud that is 80,000, which does not fit in
; one DIV.
; --------------------------------------------------------------------------
div32:
        push    si
        push    cx
        mov     cx, ax
        mov     ax, dx
        xor     dx, dx
        div     bx                       ; AX = high quotient
        mov     si, ax
        mov     ax, cx
        div     bx                       ; AX = low quotient
        mov     dx, si
        pop     cx
        pop     si
        ret

; --------------------------------------------------------------------------
; How many bytes should the adapter gather into one USB packet?
;
; Aim for roughly 30 packets a second, NOT the 110 the first version of
; CH375Serial tried.  The measured ceiling on this card is 110-138
; packets/s, and aiming just under it leaves no headroom at all: any moment
; the host spends not reading -- a screen scroll, a repaint, a disk access
; -- overruns the adapter and characters are lost.  In a terminal the lost
; bytes include line feeds, so the symptom is lines overwriting one another
; rather than obviously missing text, which is much harder to read as data
; loss.
;
; baud/300 gives 32 characters a packet at 9600 and holds the packet rate
; near 30/s across the range.  The cap is 48 because a 64-byte packet has
; to carry the per-packet header too.  -> AL
; --------------------------------------------------------------------------
ser_batch_for:
        mov     ax, [ser_baud]
        mov     bx, 300
        xor     dx, dx
        div     bx
        cmp     ax, 8
        jae     short sbf_hi
        mov     ax, 8
sbf_hi:
        cmp     ax, 48
        jbe     short sbf_out
        mov     ax, 48
sbf_out:
        mov     [ser_batch], al
        ret

; --------------------------------------------------------------------------
; Open the port at ser_baud / ser_bits / ser_par / ser_stop, and raise RTS
; and DTR if AL is non-zero on entry.
;
; NO POWER CYCLE.  usbmouse.asm drops the lines and raises them again
; because a serial mouse is powered from RTS and DTR and picks its protocol
; when they come up.  A modem is not, and doing it anyway hangs up a call.
; --------------------------------------------------------------------------
ser_open:
        mov     [so_en], al
        call    ser_batch_for
        cmp     word [ser_vid], 0x06CD       ; Keyspan / InnoSys
        je      short so_keyspan
        cmp     word [ser_vid], 0x0403       ; FTDI
        je      short so_ftdi_t
        stc                                  ; recognised, not opened
        ret
so_ftdi_t:
        jmp     near so_ftdi

; ---- Keyspan usa90: a flat 34-byte block on its own bulk OUT endpoint ----
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

so_keyspan:
        push    cs
        pop     es
        mov     di, ser_msg
        mov     cx, KS_LEN
        xor     al, al
        cld
        rep     stosb                        ; zeros change nothing

        ; 14,769,231 / (baud * 16) -- computed as 923077/baud, which is the
        ; same number and keeps the dividend inside one 32-bit value.
        mov     dx, 0x000E
        mov     ax, 0x1645                   ; 923077
        mov     bx, [ser_baud]
        call    div32
        or      ax, ax
        jne     short so_ks_dv
        mov     ax, 1
so_ks_dv:
        mov     [ser_msg + KS_BAUDLO], al
        mov     [ser_msg + KS_BAUDHI], ah

        ; The 16550 LCR: data bits in 0-1 as (bits - 5), stop in 2, parity
        ; above.  NOT the same as FTDI's, which wants the bit COUNT itself.
        mov     al, [ser_bits]
        sub     al, 5
        and     al, 3
        cmp     byte [ser_stop], 2
        jb      short so_ks_p
        or      al, 0x04
so_ks_p:
        cmp     byte [ser_par], 1
        jne     short so_ks_pe
        or      al, 0x08
        jmp     short so_ks_lcr
so_ks_pe:
        cmp     byte [ser_par], 2
        jne     short so_ks_lcr
        or      al, 0x18
so_ks_lcr:
        mov     [ser_msg + KS_LCR], al

        mov     byte [ser_msg + KS_SETCLOCK], 1
        mov     byte [ser_msg + KS_SETLCR], 1
        mov     byte [ser_msg + KS_SETRXMODE], 1
        mov     byte [ser_msg + KS_SETTXMODE], 1
        mov     byte [ser_msg + KS_SETTXFLOW], 1
        mov     byte [ser_msg + KS_SETRXFLOW], 1
        mov     byte [ser_msg + KS_SETRTS], 1
        mov     byte [ser_msg + KS_SETDTR], 1
        mov     al, [so_en]
        mov     [ser_msg + KS_RTS], al
        mov     [ser_msg + KS_DTR], al
        mov     [ser_msg + KS_PORTEN], al
        mov     al, [ser_batch]
        mov     [ser_msg + KS_RXFWDLEN], al
        mov     byte [ser_msg + KS_RXFWDTMO], 16
        mov     byte [ser_msg + KS_TXACK], 1
        mov     byte [ser_msg + KS_RXFLUSH], 1
        mov     byte [ser_msg + KS_RETSTATUS], 1

        push    cs
        pop     ds
        mov     si, ser_msg
        mov     cl, KS_LEN
        mov     al, [ser_ctl]
        call    bulk_out_ser
        pushf
        call    ser_poll_ready
        popf
        ret

; ---- FTDI: four vendor requests on endpoint 0 ----
;
; The divisor is 3,000,000/baud held in eighths so the fraction survives,
; with the fractional part encoded into the top bits of wIndex through a
; lookup that is not in numeric order.
ftdi_frac: dw   0, 3, 2, 4, 1, 5, 6, 7

so_ftdi:
        mov     al, 0x00                     ; SIO_RESET, both directions
        xor     bx, bx
        xor     dx, dx
        call    ser_ctrl
        jnc     short so_ftdi_go             ; the divisor maths below puts
        jmp     near so_ftdi_no              ; so_ftdi_no out of short reach
so_ftdi_go:

        ; (3,000,000 * 8) / baud
        mov     dx, 0x016E
        mov     ax, 0x3600                   ; 24,000,000
        mov     bx, [ser_baud]
        call    div32
        mov     bx, ax                       ; low word of the quotient
        and     bx, 7                        ; the fraction
        shl     bx, 1
        mov     si, [bx+ftdi_frac]
        ; quotient >> 3, 32 bits
        mov     cl, 3
        shr     ax, cl
        mov     bx, dx
        and     bx, 7
        shr     dx, cl
        mov     cl, 13
        shl     bx, cl
        or      ax, bx                       ; AX = low 16 of (Dv >> 3)
        ; wValue is the low 14 bits; bit 0 of wIndex says the 15th is set
        push    ax
        and     ax, 0x3FFF
        mov     bx, ax                       ; wValue
        pop     ax
        mov     cl, 14
        shr     ax, cl
        or      ax, dx                       ; anything above bit 13?
        mov     cl, 14
        mov     dx, si
        shl     dx, cl                       ; the fraction, at the top
        or      ax, ax
        je      short so_ftdi_bd
        or      dx, 1
so_ftdi_bd:
        mov     al, 0x03                     ; SET_BAUD_RATE
        call    ser_ctrl
        jc      short so_ftdi_no

        ; data characteristics: length in 0-7, parity in 8-10, stop in 11-13
        mov     bl, [ser_bits]               ; FTDI wants the COUNT
        mov     bh, [ser_par]
        cmp     byte [ser_stop], 2
        jb      short so_ftdi_lc
        or      bh, 0x10                     ; stop bits field = 2
so_ftdi_lc:
        mov     al, 0x04
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no

        ; modem control: each line has a value bit and a "change me" mask
        mov     al, 0x01
        mov     bx, 0x0300
        cmp     byte [so_en], 0
        je      short so_ftdi_mc
        mov     bx, 0x0303
so_ftdi_mc:
        xor     dx, dx
        call    ser_ctrl
        jc      short so_ftdi_no

        ; The latency timer is the FTDI's version of RXFWDLEN: how long it
        ; will hold a partial packet before sending it anyway.
        mov     al, 0x09
        mov     bl, 16
        mov     bh, 0
        xor     dx, dx
        call    ser_ctrl

        call    ser_poll_ready
        clc
        ret
so_ftdi_no:
        call    ser_poll_ready
        stc
        ret

so_en:  db      1

; --------------------------------------------------------------------------
; Move the control lines only, for function 06h.  AL = 0 lower, 1 raise.
; --------------------------------------------------------------------------
ser_lines:
        mov     [so_en], al
        cmp     word [ser_vid], 0x0403
        je      short sl_ftdi
        cmp     word [ser_vid], 0x06CD
        je      short sl_keyspan
        ret
sl_ftdi:
        mov     al, 0x01
        mov     bx, 0x0300
        cmp     byte [so_en], 0
        je      short sl_f2
        mov     bx, 0x0303
sl_f2:
        xor     dx, dx
        call    ser_ctrl
        ret
sl_keyspan:
        mov     al, [so_en]
        jmp     near ser_open                ; the block carries the lines

; ==========================================================================
; The transport entry points
; ==========================================================================

ct_open:
        ret

ct_close:
        ; Drop the lines, which for a modem is the hang-up.
        cmp     byte [ch_live], 0
        je      short ctc_out
        mov     byte [fg_busy], 1
        xor     al, al
        call    ser_lines
        mov     byte [fg_busy], 0
ctc_out:
        ret

; Take N bytes from the transmit ring into ser_tbuf WITHOUT consuming them.
; CX = count on entry.
tx_peekn:
        push    cx
        push    si
        push    di
        mov     si, [tx_tail]
        mov     di, ser_tbuf
tp_byte:
        mov     bx, si
        mov     al, [bx+tx_buf]
        mov     [di], al
        inc     di
        inc     si
        and     si, TX_MASK
        loop    tp_byte
        pop     di
        pop     si
        pop     cx
        ret

; Consume CX bytes from the transmit ring.
tx_skipn:
        mov     ax, [tx_tail]
        add     ax, cx
        and     ax, TX_MASK
        mov     [tx_tail], ax
        ret

; --------------------------------------------------------------------------
; The poll.  Transmit first, because a byte the application has already
; handed us is more urgent than one that has not arrived yet, and because a
; modem that is being talked to usually answers.
; --------------------------------------------------------------------------
ct_poll:
        cmp     byte [ch_live], 1
        je      short ctp_go
        ret
ctp_go:
        cmp     byte [fg_busy], 0
        je      short ctp_run
        ret
ctp_run:
        inc     word [st_tick]
        call    ct_tx
        call    ct_rx
        ret

ct_tx:
        mov     byte [tx_bud], 2
ctt_loop:
        call    tx_count
        or      ax, ax
        je      short ctt_out
        cmp     ax, SER_TBUFSZ
        jbe     short ctt_have
        mov     ax, SER_TBUFSZ
ctt_have:
        mov     cx, ax
        call    tx_peekn
        push    cx
        push    cs
        pop     ds
        mov     si, ser_tbuf
        mov     al, [ser_out]
        cld                                  ; bulk_out_ser walks with LODSB
        call    bulk_out_ser
        pop     cx
        jc      short ctt_out                ; leave the bytes for next time
        call    tx_skipn
        inc     word [ch_tx_pk]
        dec     byte [tx_bud]
        jne     short ctt_loop
ctt_out:
        ret

ct_rx:
        mov     byte [rx_bud], 4
ctr_again:
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
        mov     cx, 1500                     ; about 3 ms, then give this tick up
        call    ch_wait
        jc      short ctr_out
        cmp     al, INT_SUCCESS
        je      short ctr_got
        mov     [last_st], al
        cmp     al, 0x2E                     ; STALL: clear it and resync
        jne     short ctr_out
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        mov     al, [ep_in]
        or      al, 0x80
        call    ch_wr
        mov     cx, 1500
        call    ch_wait
        mov     byte [ep_tog], 0x80
        ret
ctr_got:
        mov     di, ser_rbuf
        mov     bl, SER_RBUFSZ
        call    ch_read
        xor     byte [ep_tog], 0x40
        ; ch_read hands back what the CHIP said, not what it stored, so a
        ; packet bigger than the buffer would send us off the end of it.
        cmp     cl, SER_RBUFSZ
        jbe     short ctr_fits
        mov     cl, SER_RBUFSZ
ctr_fits:
        ; The FTDI puts two status bytes on the head of EVERY packet,
        ; including the empty ones -- which is how it answers instead of
        ; NAKing.  Byte 0 carries the modem lines; bit 7 is carrier.
        cmp     byte [ser_hdr], 2
        jne     short ctr_nodcd
        cmp     cl, 2
        jb      short ctr_nodcd
        mov     al, [ser_rbuf]
        and     al, 0x80
        mov     byte [dcd_st], 0
        je      short ctr_nodcd
        mov     byte [dcd_st], 1
ctr_nodcd:
        ; A SUCCESSFUL READ IS NOT A READ WITH SOMETHING IN IT.  The Keyspan
        ; NAKs when it has nothing, so "drain until it NAKs" is a complete
        ; stopping rule for that part.  An FTDI never NAKs, so without this
        ; test the drain spends its whole budget every tick, for ever, on an
        ; idle line -- inside a timer interrupt.
        mov     al, [ser_hdr]
        cmp     cl, al
        jbe     short ctr_out                ; header only: the pipe is empty
        mov     ah, 0
        mov     si, ser_rbuf
        add     si, ax
        sub     cl, al
        mov     ch, 0
        inc     word [ch_rx_pk]
        cld
ctr_push:
        lodsb
        call    rx_put
        loop    ctr_push
        dec     byte [rx_bud]
        je      short ctr_out
        jmp     near ctr_again
ctr_out:
        ret

tx_bud:   db    0
rx_bud:   db    0
