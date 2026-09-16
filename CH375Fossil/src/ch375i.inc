; ==========================================================================
; ch375i.inc -- the CH375 transport, TRANSIENT half.
;
; Included by fossil.asm BELOW init, so none of it survives going resident.
; Bring-up and enumeration happen once; the resident half never calls in
; here.  See ch375r.inc for the provenance note that covers both files.
;
; ONE THING IS DELIBERATELY MISSING.  usbmouse.asm drops the USB bus to
; 1.5 Mbps for a low-speed device, with a long comment about where that
; command has to sit to be obeyed at all.  None of it is here: every USB
; serial adapter is a full-speed device, so the branch would never be
; taken, and carrying a copy of subtle code that cannot execute is how the
; copy and the original drift apart without anyone noticing.
; ==========================================================================

cfg_buf:  times 256 db 0
got_ep:   db    0
in_mass:  db    0               ; 1 = walking inside a mass-storage interface

; -> ZF set if a CH375 answered
chip_ask:
        mov     al, CMD_CHECK_EXIST
        call    ch_cmd
        mov     al, 0x55
        call    ch_wr
        call    ch_rd
        cmp     al, 0xAA
        ret

set_mode:                                ; AL = mode code
        push    ax
        mov     al, CMD_SET_USB_MODE
        call    ch_cmd
        pop     ax
        call    ch_wr
        mov     cx, 2000
ch_sm_w:
        call    ch_rd
        loop    ch_sm_w
        ret

; Swallow any pending interrupt so a stale one cannot be mistaken for the
; answer to the next token.
drain_int:
        push    ax
        push    cx
        push    dx
        mov     dx, [io_cmd]
        mov     cx, 8
drain_loop:
        in      al, dx
        test    al, 0x80
        jne     short drain_done
        mov     al, CMD_GET_STATUS
        call    ch_cmd
        call    ch_rd
        loop    drain_loop
drain_done:
        pop     dx
        pop     cx
        pop     ax
        ret

; CX = milliseconds, roughly.  Precision is not the point here; "long
; enough" is, and erring slow costs nothing at load time.
delay_ms:
        push    ax
        push    cx
dly_outer:
        push    cx
        mov     cx, 1000
dly_inner:
        nop
        loop    dly_inner
        pop     cx
        loop    dly_outer
        pop     cx
        pop     ax
        ret

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
        mov     cx, 10
        call    delay_ms
        dec     bx
        jne     short bu_conn_l
        pop     bx
        stc
        ret
bu_conn_y:
        pop     bx
        clc
        ret

; ==========================================================================
; Bring the chip up, enumerate whatever is plugged in, and open its port.
; CF set on any failure, with DX pointing at a message saying which.
; ==========================================================================
ch375_bringup:
        ; --- is a chip there? ---
        ;
        ; RESET AND ASK AGAIN BEFORE DECIDING THERE IS NO CARD.  A chip left
        ; mid-transaction by an earlier program fails CHECK_EXIST on a card
        ; that is fitted and working, and this driver's own /U is one way to
        ; leave it that way: it restores the vectors but does not quiesce a
        ; transfer, so the very next load can meet a chip still thinking
        ; about the last one.  Load-unload-load is exactly what testing a
        ; driver is made of.
        call    chip_ask
        je      short bu_chip
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 200
        call    delay_ms
        call    chip_ask
        je      short bu_chip
        mov     dx, m_nochip
        stc
        ret
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
        mov     dx, m_oldchip
        stc
        ret
bu_ok:
        mov     al, CMD_RESET_ALL
        call    ch_cmd
        mov     cx, 100
        call    delay_ms

        ; The bring-up order the datasheet recommends: mode 5 while idle,
        ; wait for the device to be noticed, mode 7 to hold the bus in
        ; reset, mode 6 to run, then wait for the SECOND connect interrupt.
        mov     al, 5
        call    set_mode
        mov     cx, 100
        call    delay_ms
        call    bu_conn
        jnc     short bu_present
        ; No connect interrupt.  Ask outright, in case one arrived before we
        ; were looking and was drained.
        mov     bx, 40
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
        mov     dx, m_nodev
        stc
        ret

bu_present:
        mov     cx, 100
        call    delay_ms
        mov     al, 7                        ; hold the USB bus in reset
        call    set_mode
        mov     cx, 40
        call    delay_ms
        mov     al, 6                        ; host mode, auto SOF
        call    set_mode
        call    bu_conn
        mov     cx, 200
        call    delay_ms
        call    drain_int

        call    ser_enum_ready               ; 8F while enumerating

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
        mov     cx, 200
        call    delay_ms
        dec     bx
        jne     short bu_dd
        mov     dx, m_nodescr
        stc
        ret
bu_dd_got:
        mov     di, desc_buf
        mov     bl, 18
        call    ch_read

        ; --- give it an address ---
        mov     al, CMD_SET_ADDRESS
        call    ch_cmd
        mov     al, USB_ADDR
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jnc     short bu_okp1
        jmp     near bu_failm
bu_okp1:
        cmp     al, INT_SUCCESS
        je     short bu_okp2
        jmp     near bu_failm
bu_okp2:
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
        jnc     short bu_okp3
        jmp     near bu_failm
bu_okp3:
        cmp     al, INT_SUCCESS
        je     short bu_okp4
        jmp     near bu_failm
bu_okp4:
        mov     di, cfg_buf
        mov     bl, 255
        call    ch_read
        mov     [cfg_len], cl

        call    cser_detect
        jnc     short bu_gotser
        mov     dx, m_notser
        stc
        ret
bu_gotser:
        mov     al, CMD_SET_CONFIG
        call    ch_cmd
        mov     al, [cfg_val]
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jnc     short bu_okp5
        jmp     near bu_failm
bu_okp5:
        cmp     al, INT_SUCCESS
        je     short bu_okp6
        jmp     near bu_failm
bu_okp6:
        mov     cx, 50
        call    delay_ms

        mov     al, 1                        ; open with RTS and DTR up
        call    ser_open
        jnc     short bu_opened
        mov     dx, m_noopen
        stc
        ret
bu_opened:
        mov     cx, 50
        call    delay_ms
        call    ser_poll_ready               ; belt to ser_open's braces
        mov     byte [ep_tog], 0x80
        mov     byte [ser_ctog], 0x80
        mov     byte [ch_live], 1
        clc
        ret

bu_failm:
        mov     [last_st], al
        mov     dx, m_enumfail
        stc
        ret

; ==========================================================================
; Which adapter is this, and which endpoints does it use?
;
; Chosen by USB ID, because these parts have nothing else to go on: the
; interface class is vendor-specific and the strings are not to be trusted.
;
; The endpoint walk takes the first bulk pair on an interface that is NOT
; mass storage.  Skipping class 08 matters: adapters put a driver-CD flash
; first, with its own bulk pair, and binding to it gives a driver that works
; perfectly and never sees a byte.
; ==========================================================================
cser_detect:
        mov     ax, [desc_buf + 8]
        mov     [ser_vid], ax
        mov     ax, [desc_buf + 10]
        mov     [ser_pid], ax

        mov     ax, [ser_vid]
        cmp     ax, 0x06CD                   ; Keyspan / InnoSys
        je      short sd_keyspan
        cmp     ax, 0x0403                   ; FTDI
        je      short sd_ftdi
        ; Everything else is recognised but not opened, and saying so beats
        ; pretending: an adapter whose port was never enabled delivers
        ; nothing, and "no bytes" is the one symptom that cannot be told
        ; apart from dead hardware.
        stc
        ret

sd_keyspan:
        ; THE KEYSPAN DECLARES TWO CONFIGURATIONS AND ONLY THE SECOND IS
        ; USABLE.  Its first puts INTERRUPT endpoints where the data should
        ; be; the second declares the same endpoint NUMBERS as bulk.  The
        ; CH375's GET_DESCR shortcut can only fetch configuration index 0,
        ; so the numbers come from that descriptor and the VALUE selected is
        ; the other one -- which works because the addresses agree and only
        ; the types differ.
        mov     byte [cfg_val], 2
        mov     byte [ser_hdr], 1            ; one status byte per IN packet
        ; AND THAT IS WHY THE TYPE FILTER HAS TO GO: insisting on bulk here
        ; finds nothing at all, because in the descriptor we can actually
        ; read these endpoints are declared INTERRUPT.
        mov     byte [ser_anyep], 1
        jmp     short sd_walk
sd_ftdi:
        ; TWO status bytes on the head of EVERY bulk IN packet, including
        ; the ones carrying no data -- which is how an idle FTDI answers
        ; instead of NAKing.  A reader that does not strip them gets rubbish
        ; interleaved with its data and blames the baud rate.
        mov     byte [cfg_val], 1
        mov     byte [ser_hdr], 2
        mov     byte [ser_anyep], 0

sd_walk:
        mov     ch, 0
        mov     cl, [cfg_len]
        xor     bx, bx
        mov     byte [in_mass], 0
        mov     byte [got_ep], 0
        mov     byte [ser_out], 0
        mov     byte [ser_ctl], 0
ew_loop:
        mov     ax, bx
        add     ax, 2
        cmp     ax, cx
        jbe     short ew_in_range
ew_fin:                                      ; a trampoline: ew_done is more
        jmp     ew_done                      ; than 128 bytes below, and an
ew_in_range:                                 ; 8086 conditional jump is short
        mov     di, cfg_buf
        add     di, bx
        mov     al, [di]                     ; bLength
        cmp     al, 2
        jb      short ew_fin
        mov     ah, [di+1]                   ; bDescriptorType
        cmp     ah, 4
        jne     short ew_notif
        mov     ah, [di+5]                   ; bInterfaceClass
        cmp     ah, 0x08                     ; mass storage: the driver CD
        jne     short ew_ifok
        mov     byte [in_mass], 1
        jmp     short ew_next
ew_ifok:
        mov     byte [in_mass], 0
        jmp     short ew_next
ew_notif:
        cmp     ah, 5                        ; ENDPOINT
        jne     short ew_next
        cmp     byte [in_mass], 0
        jne     short ew_next
        cmp     byte [ser_anyep], 0
        jne     short ew_typeok
        mov     al, [di+3]
        and     al, 3
        cmp     al, 2                        ; bulk
        jne     short ew_next
ew_typeok:
        mov     ah, [di+2]                   ; bEndpointAddress
        test    ah, 0x80
        jne     short ew_epin
        and     ah, 0x0F
        cmp     byte [ser_out], 0
        jne     short ew_ep2
        mov     [ser_out], ah                ; first bulk OUT: data
        jmp     short ew_next
ew_ep2:
        cmp     byte [ser_ctl], 0
        jne     short ew_next
        mov     [ser_ctl], ah                ; second bulk OUT: control
        jmp     short ew_next
ew_epin:
        cmp     byte [got_ep], 0
        jne     short ew_next
        and     ah, 0x0F
        mov     [ep_in], ah
        mov     byte [got_ep], 1
ew_next:
        mov     di, cfg_buf
        add     di, bx
        mov     al, [di]
        mov     ah, 0
        add     bx, ax
        jmp     ew_loop
ew_done:
        cmp     byte [got_ep], 0
        je      short ew_no
        cmp     byte [ser_out], 0
        je      short ew_no
        ; A part with only one bulk OUT carries its control on endpoint 0
        ; instead; the Keyspan is the one here that needs a second.
        mov     al, [ser_out]
        cmp     byte [ser_ctl], 0
        jne     short ew_ok
        mov     [ser_ctl], al
ew_ok:
        clc
        ret
ew_no:
        stc
        ret

m_nochip:   db  'No CH375 responds at that I/O address.', 13, 10, '$'
m_oldchip:  db  'CH375 revision is too old; needs B5 or later.', 13, 10, '$'
m_nodev:    db  'No USB device is plugged in.', 13, 10, '$'
m_nodescr:  db  'The device never returned its descriptor.', 13, 10, '$'
m_enumfail: db  'Enumeration failed.', 13, 10, '$'
m_notser:   db  'Not a USB serial adapter this driver can open.', 13, 10, '$'
m_noopen:   db  'The adapter enumerated but its port would not open.', 13, 10, '$'
