; ==========================================================================
; FOSSIL.COM -- a FOSSIL driver (FSC-0015) for DOS, with pluggable
;               transports underneath the INT 14h API.
;
;   Version 0.1.0                                                  StevenC
;   Public domain (the Unlicense).  Do anything you like with it.
;
;   FOSSIL [/L] [/R=n] [/B=n] [/S] [/U]
;       /L      loopback transport (the default, and the only one so far)
;       /R=n    timer divisor, PIT rate = 18.2 * n Hz.  Default 8 (145 Hz)
;       /B=n    loopback bytes moved per tick.  Default 16, which at the
;               default rate is about 2330 B/s -- roughly 19200 baud
;       /S      report the status of an already-loaded copy
;       /U      unload
;
; ASSEMBLING -- both of these produce a BYTE-IDENTICAL image, verified:
;       nasm -f bin fossil.asm -o FOSSIL.COM -I src/ -I <CH375USBTOOLS>/src/
;       MNASMFIX -O9 -f bin -o FOSDOS.COM FOSSIL.ASM      (on the DOS box)
;
; The CH375 register layer is SHARED with CH375Mouse and lives in
; CH375USBTOOLS/src -- ch375def.inc, ch375io.inc, ch375ser.inc.  nasm is
; given -I for them; mininasm has no include path, so on the DOS box all
; eight files have to sit in the current directory and it must be run from
; there.  Only the packet-driver transport builds without them.
; Every jump carries an explicit short/near at its natural size, because
; mininasm shortens jumps on every pass and a forced-long jump never
; converges.  Do not widen one to fix a range error -- add a trampoline.
;
; WHY LOOPBACK EXISTS, AND WHY IT IS NOT A TOY
;
; A FOSSIL is two things welded together: a large, fiddly, entirely
; deterministic API, and a transport that is none of those.  Debugging them
; at the same time means every wrong answer has two possible owners, and on
; this machine the transport is a USB host controller reached over a bus
; with a measured packet ceiling -- the expensive half to be wrong about.
;
; So the transport is three near pointers in a table, and the first thing to
; fill them is a loopback: bytes written to the transmit ring are moved into
; the receive ring by the timer tick, a fixed number per tick, exactly as a
; real port would deliver them.  That exercises both rings, the tick, the
; buffer accounting, the status bits and the blocking paths, and it cannot
; fail for a reason outside this file.  When CH375 arrives, anything that
; still passes here and fails there belongs to the transport, and that is
; the whole point of building it this way round.
;
; The loopback also ties DCD to DTR, so raising and lowering DTR with
; function 06h moves the carrier bit function 03h reports.  That is the one
; piece of modem-control behaviour that can be tested without a modem.
;
; TWO DELIBERATE DEVIATIONS FROM THE SPEC, both for the same reason: on this
; machine a wedged program is indistinguishable from a wedged machine, and
; it needs hands on the keyboard.
;
;   * Function 08h (flush output, "wait until everything is sent") gives up
;     after about five seconds and returns anyway.  No correct caller can
;     tell the difference, because on a working port the wait is bounded by
;     the baud rate; only a broken transport reaches the timeout, and on a
;     broken transport the spec-compliant behaviour is to hang for ever.
;
;   * Function 02h (receive with wait) is NOT bounded -- it blocks, as the
;     spec requires, because real BBS software depends on it.  The hazard is
;     documented rather than designed away: check function 03h for RDA first
;     if a hang would cost you a trip to the machine.
;
; Interrupts are enabled inside every blocking wait.  The only thing that
; can end one of those waits is the timer tick, so a CLI in there is a hung
; machine, not a slow one.
; ==========================================================================

        cpu     8086
        bits    16
        org     0x100

MAXFUNC         equ 0x1B        ; highest INT 14h function we answer
SPECREV         equ 5           ; FSC-0015 revision we claim

RX_SIZE         equ 4096
RX_MASK         equ 4095
TX_SIZE         equ 2048
TX_MASK         equ 2047

TICK_MAX        equ 8           ; slots in the function 16h tick chain
APP_MAX         equ 4           ; slots in the function 7Eh application table

; Offsets into the register image INT 14h builds on the stack.  Every
; function reads its arguments from here and writes its results here, so the
; entry and exit sequences are the only code that touches real registers and
; nothing can leak.  BP-relative addressing is SS-relative, which is why
; these stay readable after a called routine has changed DS.
F_AX            equ 0
F_BX            equ 2
F_CX            equ 4
F_DX            equ 6
F_SI            equ 8
F_DI            equ 10
F_BP            equ 12
F_ES            equ 14
F_DS            equ 16

; ==========================================================================
; RESIDENT IMAGE
; ==========================================================================

entry:
        jmp     near init                       ; 0100

; An already-resident copy is found by following INT 14h to its segment and
; looking for this string at a fixed offset.  It must stay at 0103 -- /U and
; /S both depend on it, and installing a second copy over the first would
; leak the interrupt vectors of the one underneath.
signature:
        db      'FOSSIL01'                      ; 0103

; The version in ASCII, '$'-terminated so it prints as it stands.  Resident,
; and immediately after the signature, so /S reports the version of the copy
; that is ALREADY LOADED rather than its own -- which is the interesting
; number when two builds are in play.
ver_str:
        db      '0.1.0$'                        ; 010B

; ---- saved vectors ----
old14:  dd      0
old08:  dd      0

; ---- timer ----
tick_n:   db    8               ; divisor asked for on the command line
tick_use: db    8               ; the divisor actually in force
tick_c:   db    8               ; countdown to the next downstream tick
in_poll:  db    0               ; transport re-entrancy guard

; ---- port state ----
fos_open: db    0               ; function 04h has been called
baud_cd:  db    0xE3            ; function 00h encoding: 9600 8N1
dtr_on:   db    1               ; function 06h
brk_on:   db    0               ; function 1Ah
flow_ctl: db    0               ; function 0Fh
ctlck:    db    0               ; function 10h
wdog:     db    0               ; function 14h
ovrun:    db    0               ; receive overrun since the last status read
cbrk_seg: dw    0               ; ES:CX handed to function 04h
cbrk_ofs: dw    0
app_ptr:  dd    0               ; scratch for the function 7Eh dispatch
wait_dl:  dw    0               ; deadline for the two bounded waits, kept in
                                ; MEMORY because pumping the transport
                                ; clobbers every register it feels like
dcd_st:   db    1               ; carrier, as the CURRENT transport reports it
tp_ch:    db    0               ; 1 = the CH375 transport is the live one
tp_pk:    db    0               ; 1 = the packet-driver transport is
tick_cnt: dw    0               ; timer ticks, the time base every transport
                                ; timer is measured against

; ---- loopback transport ----
loop_rate: dw   16              ; bytes moved per tick

; ---- statistics, for /S ----
; THIRTY-TWO BITS, because sixteen is a lie on any real transfer.  A single
; 128 KB download wraps a Word four times, and a counter that silently
; restarts is worse than no counter: it reads as a plausible small number.
st_rx:    dd    0               ; bytes delivered into the receive ring
st_tx:    dd    0               ; bytes accepted into the transmit ring
st_lost:  dw    0               ; bytes dropped because the receive ring was full
st_tick:  dw    0               ; transport polls run

; ---- rings ----
; Single producer, single consumer: the tick owns rx_head and tx_tail, the
; foreground owns rx_tail and tx_head.  The foreground still masks interrupts
; around its index updates, because an 8086 word access is two bus cycles and
; is not atomic against a tick landing between them.
rx_head:  dw    0
rx_tail:  dw    0
tx_head:  dw    0
tx_tail:  dw    0

; ---- function 16h tick chain, and function 7Eh applications ----
tick_tab: times TICK_MAX * 4 db 0       ; offset, segment
app_tab:  times APP_MAX * 6 db 0        ; code, offset, segment

; ---- the transport vtable ----
; Three near pointers.  Swapping transports is swapping these.
tp_poll:  dw    loop_poll
tp_open:  dw    loop_open
tp_close: dw    loop_close

; ---- the function 1Bh driver information block ----
info_blk:
        dw      19              ; +0   strsiz
        db      SPECREV         ; +2   majver
        db      0               ; +3   minver, driver revision
        dw      ident_str       ; +4   ident, offset
        dw      0               ; +6   ident, segment -- patched at install
        dw      RX_SIZE         ; +8   ibufr
        dw      0               ; +10  ifree
        dw      TX_SIZE         ; +12  obufr
        dw      0               ; +14  ofree
        db      80              ; +16  swidth
        db      25              ; +17  sheight
        db      0               ; +18  baud
info_end:

ident_str:
        db      'FOSSIL 0.1.0 (StevenC)', 0

; ==========================================================================
; INT 14h
;
; The signature FSC-0015 requires is the word 1954h at offset 6 from the
; handler entry, with the highest supported function number in the byte
; after it.  That is what lets a program ask whether a FOSSIL is present
; WITHOUT calling one -- the BIOS INT 14h defines AH=00h..03h and nothing
; else, so a blind AH=04h on a machine with no driver is a call into
; undefined ROM.  The layout below is load-bearing; insert nothing above
; i14_go.
; ==========================================================================
int14:
        jmp     short i14_go                    ; +0, two bytes
        db      'FOS', 0                        ; +2
        dw      0x1954                          ; +6
        db      MAXFUNC                         ; +8

i14_go:                                         ; +9
        push    ds
        push    es
        push    bp
        push    di
        push    si
        push    dx
        push    cx
        push    bx
        push    ax
        mov     bp, sp

        mov     ax, cs
        mov     ds, ax

        ; THE TRANSPORT IS DRIVEN FROM HERE, NOT FROM THE TIMER.  Sending
        ; means calling the packet driver, and doing that from a timer
        ; interrupt can re-enter a driver that is not re-entrant.  A BBS
        ; calls function 03h continuously, so this is the livelier clock in
        ; any case.
        call    fos_pump

        mov     al, [bp+F_AX+1]                 ; AH, the function
        cmp     al, MAXFUNC
        ja      short i14_high

        mov     bl, al
        xor     bh, bh
        shl     bx, 1
        jmp     word [bx+disp_tab]

i14_high:
        cmp     al, 0x7E
        jne     short i14_h1
        jmp     near f7e
i14_h1:
        cmp     al, 0x7F
        jne     short i14_h2
        jmp     near f7f
i14_h2:
        cmp     al, 0x80
        jb      short i14_done
        jmp     near f_appcall

; Every function lands here.  Nothing below this point may assume a register
; survived the call.
i14_done:
        pop     ax
        pop     bx
        pop     cx
        pop     dx
        pop     si
        pop     di
        pop     bp
        pop     es
        pop     ds
        iret

disp_tab:
        dw      f00, f01, f02, f03, f04, f05, f06, f07
        dw      f08, f09, f0a, f0b, f0c, f0d, f0e, f0f
        dw      f10, f11, f12, f13, f14, f15, f16, f17
        dw      f18, f19, f1a, f1b

; -> AX = the BIOS tick at 0040:006C, with ES put back.
;
; Every bounded wait in here reads the clock through this rather than
; holding a segment across the loop.  The waits call fos_pump, fos_pump
; eventually reaches tcp_send_seg, and that sets ES to our own segment --
; so a loop that cached ES=0 to reach the BIOS data area was reading the
; driver's own code as if it were the clock.  Function 05h then decided its
; two-second grace had already elapsed, gave the packet handles back before
; the FIN had been transmitted, and left the caller's connection hanging
; with nothing ever closing it.
bios_tick:
        push    es
        xor     ax, ax
        mov     es, ax
        mov     ax, [es:0x046C]
        pop     es
        ret

; Give the transport a turn.  Safe to call as often as you like: pt_service
; measures its own timers against the tick counter rather than against the
; number of times it has been called, and refuses to nest.
fos_pump:
        cmp     byte [tp_pk], 0
        je      short fpm_out
        call    pt_service
fpm_out:
        ret

; --------------------------------------------------------------------------
; Ring helpers.  All near, all through registers, none of them touch the
; saved-register image.
; --------------------------------------------------------------------------

; -> AX = bytes waiting in the receive ring
rx_count:
        mov     ax, [rx_head]
        sub     ax, [rx_tail]
        and     ax, RX_MASK
        ret

; -> AX = bytes waiting in the transmit ring
tx_count:
        mov     ax, [tx_head]
        sub     ax, [tx_tail]
        and     ax, TX_MASK
        ret

; -> AX = room left in the transmit ring.  One slot is always kept empty, so
;    head == tail means empty and can never also mean full.
tx_free:
        call    tx_count
        neg     ax
        add     ax, TX_SIZE - 1
        ret

; -> AX = room left in the receive ring
rx_free:
        call    rx_count
        neg     ax
        add     ax, RX_SIZE - 1
        ret

; AL = byte to put in the transmit ring.  CF set if there was no room.
tx_put:
        push    bx
        push    dx
        mov     dl, al
        call    tx_free
        or      ax, ax
        je      short txp_full
        pushf
        cli
        mov     bx, [tx_head]
        mov     [bx+tx_buf], dl
        inc     bx
        and     bx, TX_MASK
        mov     [tx_head], bx
        popf
        add     word [st_tx], 1
        adc     word [st_tx+2], 0
        clc
        pop     dx
        pop     bx
        ret
txp_full:
        stc
        pop     dx
        pop     bx
        ret

; -> AL = byte taken from the receive ring.  CF set if it was empty.
rx_get:
        push    bx
        call    rx_count
        or      ax, ax
        je      short rxg_none
        pushf
        cli
        mov     bx, [rx_tail]
        mov     al, [bx+rx_buf]
        inc     bx
        and     bx, RX_MASK
        mov     [rx_tail], bx
        popf
        clc
        pop     bx
        ret
rxg_none:
        stc
        pop     bx
        ret

; AL = byte to deliver into the receive ring; called from the tick only.  A
; full ring drops the byte and records an overrun, which is what a real UART
; does and what the OVRN status bit exists to report.
rx_put:
        push    ax
        push    bx
        push    dx
        mov     dl, al
        call    rx_free
        or      ax, ax
        je      short rxp_full
        mov     bx, [rx_head]
        mov     [bx+rx_buf], dl
        inc     bx
        and     bx, RX_MASK
        mov     [rx_head], bx
        add     word [st_rx], 1
        adc     word [st_rx+2], 0
        jmp     short rxp_out
rxp_full:
        mov     byte [ovrun], 1
        inc     word [st_lost]
rxp_out:
        pop     dx
        pop     bx
        pop     ax
        ret

; -> AX = the status word function 03h reports.
;    AH bit 0 RDA, bit 1 OVRN, bit 5 THRE, bit 6 TSRE
;    AL bit 3 always set, bit 7 DCD
status_word:
        push    bx
        xor     bx, bx
        call    rx_count
        or      ax, ax
        je      short sw_nord
        or      bh, 0x01
sw_nord:
        cmp     byte [ovrun], 0
        je      short sw_noovr
        or      bh, 0x02
sw_noovr:
        call    tx_free
        or      ax, ax
        je      short sw_nothre
        or      bh, 0x20
sw_nothre:
        call    tx_count
        or      ax, ax
        jne     short sw_notsre
        or      bh, 0x40
sw_notsre:
        or      bl, 0x08                        ; always set, per the spec
        cmp     byte [dcd_st], 0                ; whatever the transport says
        je      short sw_nodcd
        or      bl, 0x80
sw_nodcd:
        mov     ax, bx
        pop     bx
        ret

; Store the status word into the saved AX.
set_status:
        call    status_word
        mov     [bp+F_AX], ax
        ret

; --------------------------------------------------------------------------
; 00h  set baud rate.  The encoding is the BIOS one: the top three bits of AL
;      select the rate.  With a loopback there is nothing to program, so it is
;      recorded and reported back through 1Bh -- which is what a caller reads.
; --------------------------------------------------------------------------
baud_tab: dw  19200, 38400, 300, 600, 1200, 2400, 4800, 9600

f00:
        mov     al, [bp+F_AX]
        mov     [baud_cd], al

        mov     bl, al                          ; top three bits: the rate
        mov     cl, 5
        shr     bl, cl
        and     bl, 7
        xor     bh, bh
        shl     bx, 1
        mov     ax, [bx+baud_tab]
        mov     [ser_baud], ax

        mov     ah, [baud_cd]                   ; bits 0-1: data bits, as -5
        mov     al, ah
        and     al, 3
        add     al, 5
        mov     [ser_bits], al

        mov     al, ah                          ; bit 2: two stop bits
        and     al, 4
        mov     byte [ser_stop], 1
        je      short f00_par
        mov     byte [ser_stop], 2
f00_par:
        mov     al, ah                          ; bits 3-4: parity
        mov     cl, 3
        shr     al, cl
        and     al, 3
        cmp     al, 1
        je      short f00_odd
        cmp     al, 3
        je      short f00_even
        xor     al, al
        jmp     short f00_setp
f00_odd:
        mov     al, 1
        jmp     short f00_setp
f00_even:
        mov     al, 2
f00_setp:
        mov     [ser_par], al

        cmp     byte [tp_ch], 0
        je      short f00_done
        ; The foreground is about to run a register sequence on the CH375.
        ; fg_busy makes the tick skip its poll until we are done; one byte
        ; is enough because there is one CPU, so while this code runs no
        ; interrupt handler is running to see it half-set.
        mov     byte [fg_busy], 1
        mov     al, 1
        call    ser_open
        mov     byte [fg_busy], 0
f00_done:
        call    set_status
        jmp     near i14_done

; --------------------------------------------------------------------------
; 01h  transmit with wait.  Blocks until the ring has room; only the tick can
;      make room, so interrupts stay on.
; --------------------------------------------------------------------------
f01:
        sti
f01_wait:
        call    fos_pump
        call    tx_free
        or      ax, ax
        jne     short f01_go
        jmp     short f01_wait
f01_go:
        mov     al, [bp+F_AX]
        call    tx_put
        call    set_status
        jmp     near i14_done

; --------------------------------------------------------------------------
; 02h  receive with wait.  This one really does block for ever, because the
;      spec says so and BBS software depends on it.  See the header.
; --------------------------------------------------------------------------
f02:
        sti
f02_wait:
        call    fos_pump
        call    rx_get
        jnc     short f02_got
        jmp     short f02_wait
f02_got:
        mov     [bp+F_AX], al
        mov     byte [bp+F_AX+1], 0
        jmp     near i14_done

; --------------------------------------------------------------------------
; 03h  request status.  The function every caller polls, so it does no work
;      beyond reading the two ring counts.
; --------------------------------------------------------------------------
f03:
        call    set_status
        mov     byte [ovrun], 0                 ; reading clears it
        cmp     byte [tp_pk], 0
        je      short f03_out
        call    wd_kick
f03_out:
        jmp     near i14_done

; --------------------------------------------------------------------------
; 04h  initialize.  Returns the magic, the highest function and the spec
;      revision.  ES:CX, if given, is a far pointer to a byte the driver may
;      set when it sees a ^C; it is recorded, but this driver never writes it,
;      because nothing here reads the keyboard behind the caller's back.
; --------------------------------------------------------------------------
f04:
        mov     byte [fg_busy], 1
        mov     ax, [bp+F_ES]
        mov     [cbrk_seg], ax
        mov     ax, [bp+F_CX]
        mov     [cbrk_ofs], ax

        pushf
        cli
        mov     ax, [rx_head]
        mov     [rx_tail], ax
        mov     ax, [tx_head]
        mov     [tx_tail], ax
        popf
        mov     byte [ovrun], 0
        mov     byte [fos_open], 1
        mov     byte [dtr_on], 1

        call    word [tp_open]
        mov     byte [fg_busy], 0

        mov     word [bp+F_AX], 0x1954
        mov     byte [bp+F_BX], MAXFUNC         ; BL
        mov     byte [bp+F_BX+1], SPECREV       ; BH
        jmp     near i14_done

; --------------------------------------------------------------------------
; 05h  deinitialize.  The transport gives its resources back here -- which for
;      a future packet-driver transport is where the handle is released, and
;      is the whole reason this driver may stay resident between sessions
;      without starving anything else on the card.
; --------------------------------------------------------------------------
f05:
        ; On a packet transport the FIN is queued rather than sent, so give
        ; the tick a bounded moment to actually put it on the wire before the
        ; handles go back.  fg_busy is NOT held across that wait: the tick is
        ; the only thing that can finish the close, and blocking it here
        ; would be waiting for something we had just switched off.
        cmp     byte [tp_pk], 0
        je      short f05_plain
        mov     byte [fg_busy], 1
        call    tcp_shutdown
        mov     byte [fg_busy], 0
        sti
        call    bios_tick
        add     ax, 55                          ; about three seconds
        mov     [wait_dl], ax
f05_wait:
        call    fos_pump
        cmp     byte [tcp_state], TS_LISTEN
        je      short f05_done
        cmp     byte [tcp_state], TS_CLOSED
        je      short f05_done
        call    bios_tick
        sub     ax, [wait_dl]
        js      short f05_wait
f05_done:
f05_plain:
        mov     byte [fg_busy], 1
        call    word [tp_close]
        mov     byte [fg_busy], 0
        mov     byte [fos_open], 0
        jmp     near i14_done

; --------------------------------------------------------------------------
; 06h  raise or lower DTR.  Loopback ties DCD to it, so this is visible in the
;      status word.
; --------------------------------------------------------------------------
f06:
        mov     al, [bp+F_AX]
        mov     [dtr_on], al
        cmp     byte [tp_pk], 0
        jne     short f06_pk
        cmp     byte [tp_ch], 0
        jne     short f06_ch
        mov     [dcd_st], al                    ; loopback ties DCD to DTR
        jmp     near i14_done
f06_pk:
        ; On a real line DCD is the far end's business, so it is never set
        ; from here.  Dropping DTR, though, IS hanging up -- which is exactly
        ; how BBS software ends a call, and it has no idea it is closing a
        ; TCP connection.
        or      al, al
        jne     short f06_pkout
        mov     byte [fg_busy], 1
        call    tcp_shutdown
        mov     byte [fg_busy], 0
f06_pkout:
        jmp     near i14_done
f06_ch:
        mov     byte [fg_busy], 1
        mov     al, [dtr_on]
        call    ser_lines
        mov     byte [fg_busy], 0
        jmp     near i14_done

; --------------------------------------------------------------------------
; 07h  timer tick parameters.  AL is the interrupt we hang off, AH the rate in
;      hertz, DX the period in milliseconds.
; --------------------------------------------------------------------------
f07:
        mov     byte [bp+F_AX], 0x08
        mov     al, [tick_use]
        xor     ah, ah
        mov     bx, ax
        mov     ax, 182
        mul     bx
        mov     bx, 10
        xor     dx, dx
        div     bx                              ; AX = ticks per second
        mov     [bp+F_AX+1], al
        or      ax, ax
        jne     short f07_ms
        mov     ax, 1
f07_ms:
        mov     bx, ax
        mov     ax, 1000
        xor     dx, dx
        div     bx                              ; AX = milliseconds per tick
        mov     [bp+F_DX], ax
        jmp     near i14_done

; --------------------------------------------------------------------------
; 08h  flush output -- wait until the transmit ring has drained.  Bounded at
;      about five seconds; see the header for why that is deliberate.
; --------------------------------------------------------------------------
f08:
        sti
        call    bios_tick
        add     ax, 91                          ; ~5 seconds
        mov     [wait_dl], ax
f08_wait:
        call    fos_pump
        call    tx_count
        or      ax, ax
        je      short f08_done
        call    bios_tick
        sub     ax, [wait_dl]
        js      short f08_wait
f08_done:
        jmp     near i14_done

; --------------------------------------------------------------------------
; 09h / 0Ah  purge the output or input ring.
; --------------------------------------------------------------------------
f09:
        pushf
        cli
        mov     ax, [tx_head]
        mov     [tx_tail], ax
        popf
        jmp     near i14_done

f0a:
        pushf
        cli
        mov     ax, [rx_head]
        mov     [rx_tail], ax
        popf
        mov     byte [ovrun], 0
        jmp     near i14_done

; --------------------------------------------------------------------------
; 0Bh  transmit, no wait.  AX = 1 if the byte was taken, 0 if not.
; --------------------------------------------------------------------------
f0b:
        mov     al, [bp+F_AX]
        call    tx_put
        jc      short f0b_no
        mov     word [bp+F_AX], 1
        jmp     near i14_done
f0b_no:
        mov     word [bp+F_AX], 0
        jmp     near i14_done

; --------------------------------------------------------------------------
; 0Ch  non-destructive read-ahead.  FFFFh when the ring is empty.
; --------------------------------------------------------------------------
f0c:
        call    rx_count
        or      ax, ax
        je      short f0c_none
        mov     bx, [rx_tail]
        mov     al, [bx+rx_buf]
        mov     [bp+F_AX], al
        mov     byte [bp+F_AX+1], 0
        jmp     near i14_done
f0c_none:
        mov     word [bp+F_AX], 0xFFFF
        jmp     near i14_done

; --------------------------------------------------------------------------
; 0Dh / 0Eh  keyboard, without and with wait.  Straight through to INT 16h.
; --------------------------------------------------------------------------
f0d:
        mov     ah, 1
        int     0x16
        jnz     short f0d_key
        mov     word [bp+F_AX], 0xFFFF
        jmp     near i14_done
f0d_key:
        xor     ah, ah
        int     0x16
        mov     [bp+F_AX], ax
        jmp     near i14_done

f0e:
        sti
        xor     ah, ah
        int     0x16
        mov     [bp+F_AX], ax
        jmp     near i14_done

; --------------------------------------------------------------------------
; 0Fh  flow control.  Recorded.  A loopback has no wire to assert and TCP
;      would do its own, so what matters here is that the setting round-trips,
;      not that it does something.
; --------------------------------------------------------------------------
f0f:
        mov     al, [bp+F_AX]
        mov     [flow_ctl], al
        jmp     near i14_done

; --------------------------------------------------------------------------
; 10h  extended ^C/^K checking and transmit on/off.
; --------------------------------------------------------------------------
f10:
        mov     al, [bp+F_AX]
        mov     [ctlck], al
        xor     ah, ah
        and     ax, 0x0001
        mov     [bp+F_AX], ax
        jmp     near i14_done

; --------------------------------------------------------------------------
; 11h / 12h  cursor position, through the BIOS.
; --------------------------------------------------------------------------
f11:
        mov     dx, [bp+F_DX]
        mov     ah, 0x02
        xor     bh, bh
        int     0x10
        jmp     near i14_done

f12:
        mov     ah, 0x03
        xor     bh, bh
        int     0x10
        mov     [bp+F_DX], dx
        jmp     near i14_done

; --------------------------------------------------------------------------
; 13h / 15h  write a character to the screen.  13h is specified as "with ANSI
;      processing"; we do BIOS teletype for both and say so in the README.
;      Writing an ANSI interpreter is a project of its own, callers that need
;      one overwhelmingly ship their own, and a documented lie is smaller than
;      pretending the driver is absent.
; --------------------------------------------------------------------------
f13:
f15:
        mov     al, [bp+F_AX]
        mov     ah, 0x0E
        xor     bh, bh
        mov     bl, 7
        int     0x10
        jmp     near i14_done

; --------------------------------------------------------------------------
; 14h  watchdog.  Recorded.  With a loopback the carrier never drops, so it
;      can never fire -- which is the only reason it is safe to have this
;      enabled on a machine reached over a network.
; --------------------------------------------------------------------------
f14:
        mov     al, [bp+F_AX]
        mov     [wdog], al
        jmp     near i14_done

; --------------------------------------------------------------------------
; 16h  add or remove a routine on the timer tick chain.  ES:DX is the routine;
;      AL = 1 adds, AL = 0 removes.  AX = 0 on success, FFFFh on failure.
;
;      A registered routine is called from inside a hardware interrupt with
;      this driver's DS, so it must set up its own addressing and must not
;      call DOS.  It also MUST be removed before the program that owns it
;      exits: a stale entry is a far call into memory DOS has since handed to
;      something else, and that fault is inherited by whatever runs next
;      rather than by the program that caused it.
; --------------------------------------------------------------------------
f16:
        mov     si, tick_tab
        mov     cx, TICK_MAX
        mov     al, [bp+F_AX]
        or      al, al
        je      short f16_del

f16_add:
        cmp     word [si+2], 0
        je      short f16_slot
        add     si, 4
        loop    f16_add
        jmp     short f16_fail
f16_slot:
        mov     ax, [bp+F_DX]
        pushf
        cli
        mov     [si], ax
        mov     ax, [bp+F_ES]
        mov     [si+2], ax
        popf
        jmp     short f16_ok

f16_del:
        mov     ax, [bp+F_DX]
        cmp     [si], ax
        jne     short f16_dnext
        mov     ax, [bp+F_ES]
        cmp     [si+2], ax
        jne     short f16_dnext
        pushf
        cli
        mov     word [si+2], 0
        mov     word [si], 0
        popf
        jmp     short f16_ok
f16_dnext:
        add     si, 4
        loop    f16_del
        jmp     short f16_fail

f16_ok:
        mov     word [bp+F_AX], 0
        jmp     near i14_done
f16_fail:
        mov     word [bp+F_AX], 0xFFFF
        jmp     near i14_done

; --------------------------------------------------------------------------
; 17h  reboot.  AL = 0 cold, 1 warm.  Implemented because the spec has it;
;      never call it over the bridge, because a job that reboots cannot report
;      back.
; --------------------------------------------------------------------------
f17:
        mov     al, [bp+F_AX]
        xor     bx, bx
        mov     es, bx
        or      al, al
        je      short f17_cold
        mov     word [es:0x0472], 0x1234        ; warm: skip the memory test
        jmp     short f17_go
f17_cold:
        mov     word [es:0x0472], 0
f17_go:
        jmp     0xFFFF:0x0000

; --------------------------------------------------------------------------
; 18h  read a block.  ES:DI is the buffer, CX the maximum.  AX comes back with
;      how many were actually moved, which may be zero.
; --------------------------------------------------------------------------
f18:
        cld
        mov     cx, [bp+F_CX]
        mov     es, [bp+F_ES]
        mov     di, [bp+F_DI]
        xor     dx, dx
        or      cx, cx
        je      short f18_out
f18_loop:
        call    rx_get
        jc      short f18_out
        stosb
        inc     dx
        loop    f18_loop
f18_out:
        mov     [bp+F_AX], dx
        jmp     near i14_done

; --------------------------------------------------------------------------
; 19h  write a block.  Same shape.  This and 18h are the hot path -- every
;      file transfer protocol worth the name uses them rather than moving one
;      byte at a time through 01h and 02h.
; --------------------------------------------------------------------------
f19:
        cld
        mov     cx, [bp+F_CX]
        mov     es, [bp+F_ES]
        mov     di, [bp+F_DI]
        xor     dx, dx
        or      cx, cx
        je      short f19_out
f19_loop:
        mov     al, [es:di]
        call    tx_put
        jc      short f19_out
        inc     di
        inc     dx
        loop    f19_loop
f19_out:
        mov     [bp+F_AX], dx
        jmp     near i14_done

; --------------------------------------------------------------------------
; 1Ah  break on or off.  Recorded; a loopback has no line to break.
; --------------------------------------------------------------------------
f1a:
        mov     al, [bp+F_AX]
        mov     [brk_on], al
        jmp     near i14_done

; --------------------------------------------------------------------------
; 1Bh  driver information.  The live fields are filled in first, then as much
;      of the block as the caller asked for is copied out.  ifree and ofree
;      are how a well-written caller throttles itself, so they have to be the
;      truth rather than a constant.
; --------------------------------------------------------------------------
f1b:
        call    rx_free
        mov     [info_blk+10], ax
        call    tx_free
        mov     [info_blk+14], ax
        mov     al, [baud_cd]
        mov     [info_blk+18], al

        cld
        mov     cx, [bp+F_CX]
        cmp     cx, info_end - info_blk
        jbe     short f1b_size
        mov     cx, info_end - info_blk
f1b_size:
        mov     es, [bp+F_ES]
        mov     di, [bp+F_DI]
        mov     si, info_blk
        mov     dx, cx
        rep     movsb
        mov     [bp+F_AX], dx
        jmp     near i14_done

; --------------------------------------------------------------------------
; 7Eh / 7Fh  install and remove an external application function, and the
;      dispatch for AH >= 80h that makes them worth having.  The same lifetime
;      rule as function 16h applies, for the same reason.
; --------------------------------------------------------------------------
f7e:
        mov     dl, [bp+F_AX]                   ; the code being claimed
        mov     si, app_tab
        mov     cx, APP_MAX
f7e_scan:
        cmp     word [si+4], 0
        je      short f7e_slot
        add     si, 6
        loop    f7e_scan
        mov     byte [bp+F_BX+1], 1             ; BH = failed
        jmp     short f7e_out
f7e_slot:
        mov     [si], dl
        mov     ax, [bp+F_DX]
        pushf
        cli
        mov     [si+2], ax
        mov     ax, [bp+F_ES]
        mov     [si+4], ax
        popf
        mov     byte [bp+F_BX+1], 0
f7e_out:
        mov     word [bp+F_AX], 0x1954
        mov     [bp+F_BX], dl
        jmp     near i14_done

f7f:
        mov     dl, [bp+F_AX]
        mov     si, app_tab
        mov     cx, APP_MAX
f7f_scan:
        cmp     word [si+4], 0
        je      short f7f_next
        cmp     [si], dl
        jne     short f7f_next
        pushf
        cli
        mov     word [si+4], 0
        mov     word [si+2], 0
        popf
        mov     byte [bp+F_BX+1], 0
        jmp     short f7f_out
f7f_next:
        add     si, 6
        loop    f7f_scan
        mov     byte [bp+F_BX+1], 1
f7f_out:
        mov     word [bp+F_AX], 0x1954
        mov     [bp+F_BX], dl
        jmp     near i14_done

; AH >= 80h: hand it to whichever application claimed that code.  The far
; pointer is copied out of the table first, because by the time the call is
; made every register belongs to the caller again.
f_appcall:
        mov     dl, [bp+F_AX+1]
        mov     si, app_tab
        mov     cx, APP_MAX
fa_scan:
        cmp     word [si+4], 0
        je      short fa_next
        cmp     [si], dl
        je      short fa_hit
fa_next:
        add     si, 6
        loop    fa_scan
        jmp     near i14_done
fa_hit:
        mov     ax, [si+2]
        mov     [app_ptr], ax
        mov     ax, [si+4]
        mov     [app_ptr+2], ax

        mov     ax, [bp+F_AX]
        mov     bx, [bp+F_BX]
        mov     cx, [bp+F_CX]
        mov     dx, [bp+F_DX]
        mov     si, [bp+F_SI]
        mov     di, [bp+F_DI]
        mov     es, [bp+F_ES]
        push    bp
        call    far [cs:app_ptr]
        pop     bp
        ; BP-relative is SS-relative, so the frame is still reachable even
        ; though the application owns DS now.
        mov     [bp+F_AX], ax
        mov     [bp+F_BX], bx
        mov     [bp+F_CX], cx
        mov     [bp+F_DX], dx
        mov     [bp+F_SI], si
        mov     [bp+F_DI], di
        mov     [bp+F_ES], es
        jmp     near i14_done

; ==========================================================================
; The loopback transport
;
; Bytes leave the transmit ring and arrive in the receive ring at a fixed
; number per tick, which is what makes this a port and not a wire: a caller
; that writes faster than the rate has to wait, exactly as it would on a real
; one, and the buffer accounting it reads through 1Bh is real.
;
; A FULL RECEIVE RING DOES NOT STOP THE DRAIN, and that is deliberate -- the
; first version of this checked rx_free before dequeuing, so when the
; application stopped reading, the transmit ring backed up and nothing was
; ever dropped.  That is not what a serial port does.  Bytes arrive off the
; wire whether or not anyone has room for them; the UART drops them and
; raises OVRN, and there is no back-pressure from a receive buffer to a
; remote sender.  Modelling it the wrong way round made the drop path
; UNREACHABLE from a test -- and that path is exactly the one that matters
; when the CH375 delivers faster than the application reads.  So the byte is
; always taken from the transmit ring, and rx_put decides whether there is
; anywhere to put it.
; ==========================================================================
loop_open:
        ret

loop_close:
        ret

loop_poll:
        inc     word [st_tick]
        mov     cx, [loop_rate]
        or      cx, cx
        je      short lp_out
lp_move:
        push    cx
        call    tx_count
        or      ax, ax
        je      short lp_pop
        mov     bx, [tx_tail]
        mov     al, [bx+tx_buf]
        inc     bx
        and     bx, TX_MASK
        mov     [tx_tail], bx
        call    rx_put
        pop     cx
        loop    lp_move
        jmp     short lp_out
lp_pop:
        pop     cx
lp_out:
        ret

; ==========================================================================
; INT 08h
;
; The PIT is divided so the transport is polled far more often than 18.2 Hz,
; and the original handler is still called every nth tick, so BIOS
; timekeeping, DOS's own clock and anything else chained on INT 08h see
; exactly the rate they expect.
; ==========================================================================
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

        inc     word [tick_cnt]

        cmp     byte [in_poll], 0
        jne     short i08_chain
        mov     byte [in_poll], 1
        call    word [tp_poll]
        mov     byte [in_poll], 0

i08_chain:
        call    tick_chain

        dec     byte [tick_c]
        jz      short i08_down

        mov     al, 0x20
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

i08_down:
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
        jmp     far [cs:old08]

; Call everything on the function 16h chain.  Each entry gets our DS and ES
; back afterwards, because a routine that clobbers them would take the rest of
; this handler down with it.
tick_chain:
        mov     si, tick_tab
        mov     cx, TICK_MAX
tc_loop:
        cmp     word [si+2], 0
        je      short tc_next
        push    cx
        push    si
        push    ds
        push    es
        call    far [si]
        pop     es
        pop     ds
        pop     si
        pop     cx
tc_next:
        add     si, 4
        loop    tc_loop
        ret

%include "ch375r.inc"
%include "pktr.inc"
%include "tcpr.inc"

; ---- the rings ----
; Last in the resident image, so their size is the only thing that moves when
; the buffers are retuned.  They are ABOVE init, which is what keeps them
; inside the block the TSR call keeps; putting them below it would hand them
; back to DOS and leave the driver writing into whatever loaded next.
rx_buf:   times RX_SIZE db 0
tx_buf:   times TX_SIZE db 0

; ==========================================================================
; TRANSIENT -- everything below here is discarded when the driver goes
; resident, so nothing above may call into it.
; ==========================================================================
init:
        mov     ax, cs
        mov     ds, ax
        mov     es, ax

        mov     dx, m_banner
        call    say

        call    parse_cmd

        cmp     byte [op_unload], 0
        je      short in_notu
        jmp     near do_unload
in_notu:
        cmp     byte [op_status], 0
        je      short in_nots
        jmp     near do_status
in_nots:

        ; Refuse to stack a second copy on top of the first.
        call    find_res
        jc      short in_fresh
        mov     dx, m_already
        call    say
        mov     al, 1
        jmp     near quit

in_fresh:
        mov     [info_blk+6], cs                ; the identifier's segment

        ; The transport is brought up BEFORE any vector is taken, so a
        ; failure here exits with the machine exactly as it was found.
        cmp     byte [op_pkt], 0
        je      short in_notpk
        cmp     byte [pkt_vec], 0
        jne     short in_pkok
        mov     dx, m_novec
        call    say
        mov     al, 5
        jmp     near quit
in_pkok:
        mov     word [tp_poll], pt_tick
        mov     word [tp_open], pt_open
        mov     word [tp_close], pt_close
        mov     byte [tp_pk], 1
in_notpk:

        cmp     byte [op_ch375], 0
        je      short in_notch
        call    ch375_bringup
        jnc     short in_chok
        call    say                             ; DX points at the reason
        mov     al, 4
        jmp     near quit
in_chok:
        mov     word [tp_poll], ct_poll
        mov     word [tp_open], ct_open
        mov     word [tp_close], ct_close
        mov     byte [tp_ch], 1
in_notch:

        mov     al, [tick_n]
        mov     [tick_use], al
        mov     [tick_c], al

        mov     ax, 0x3514
        int     0x21
        mov     [old14], bx
        mov     ax, es
        mov     [old14+2], ax

        mov     ax, 0x3508
        int     0x21
        mov     [old08], bx
        mov     ax, es
        mov     [old08+2], ax

        push    ds
        mov     ax, cs
        mov     ds, ax
        mov     dx, int14
        mov     ax, 0x2514
        int     0x21
        mov     dx, int08
        mov     ax, 0x2508
        int     0x21
        pop     ds

        call    set_pit

        mov     dx, m_ok
        call    say
        cmp     byte [tp_pk], 0
        je      short in_notsaypk
        mov     dx, m_tpk
        call    say
        mov     al, [pkt_vec]
        xor     ah, ah
        call    say_hex
        mov     dx, m_tpk2
        call    say
        mov     si, my_ip
        call    say_ip
        mov     dx, m_tpk3
        call    say
        mov     si, peer_ip
        call    say_ip
        mov     dx, m_tpk4
        call    say
        mov     ax, [tcp_lport]
        call    say_num
        mov     dx, m_crlf
        call    say
        jmp     near in_gores
in_notsaypk:

        cmp     byte [tp_ch], 0
        je      short in_sayloop

        mov     dx, m_tch
        call    say
        mov     ax, [ser_vid]
        call    say_hex
        mov     dx, m_colon
        call    say
        mov     ax, [ser_pid]
        call    say_hex
        mov     dx, m_tep
        call    say
        mov     al, [ep_in]
        xor     ah, ah
        call    say_num
        mov     dx, m_tepo
        call    say
        mov     al, [ser_out]
        xor     ah, ah
        call    say_num
        mov     dx, m_tepc
        call    say
        mov     al, [ser_ctl]
        xor     ah, ah
        call    say_num
        mov     dx, m_tbaud
        call    say
        mov     ax, [ser_baud]
        call    say_num
        mov     dx, m_tbatch
        call    say
        mov     al, [ser_batch]
        xor     ah, ah
        call    say_num
        mov     dx, m_crlf
        call    say
        jmp     short in_gores

in_sayloop:
        mov     dx, m_tloop
        call    say
        mov     dx, m_rate
        call    say
        mov     al, [tick_use]
        xor     ah, ah
        call    say_num
        mov     dx, m_rate2
        call    say
        mov     ax, [loop_rate]
        call    say_num
        mov     dx, m_rate3
        call    say

in_gores:
        mov     dx, (init - entry + 0x100 + 15) >> 4
        mov     ax, 0x3100
        int     0x21

; --------------------------------------------------------------------------
do_status:
        call    find_res
        jnc     short st_have
        mov     dx, m_none
        call    say
        mov     al, 2
        jmp     near quit
st_have:
        mov     [res_seg], ax

        mov     dx, m_found
        call    say
        push    ds
        mov     ds, ax
        mov     dx, ver_str
        mov     ah, 9
        int     0x21
        pop     ds
        mov     dx, m_crlf
        call    say

        mov     es, [res_seg]
        mov     dx, m_stats
        call    say
        mov     ax, [es:st_rx]
        mov     dx, [es:st_rx+2]
        call    say_num32
        mov     es, [res_seg]
        mov     dx, m_stats2
        call    say
        mov     ax, [es:st_tx]
        mov     dx, [es:st_tx+2]
        call    say_num32
        mov     es, [res_seg]
        mov     dx, m_stats3
        call    say
        mov     ax, [es:st_lost]
        call    say_num
        mov     es, [res_seg]
        mov     dx, m_stats4
        call    say
        mov     ax, [es:st_tick]
        call    say_num

        mov     es, [res_seg]
        cmp     byte [es:tp_ch], 0
        je      short st_nochf
        mov     dx, m_crlf
        call    say
        mov     dx, m_chpk
        call    say
        mov     es, [res_seg]
        mov     ax, [es:ch_rx_pk]
        call    say_num
        mov     dx, m_chpk2
        call    say
        mov     es, [res_seg]
        mov     ax, [es:ch_tx_pk]
        call    say_num
        mov     dx, m_chpk3
        call    say
        mov     es, [res_seg]
        mov     ax, [es:ch_err]
        call    say_num
        mov     dx, m_chpk4
        call    say
        mov     es, [res_seg]
        mov     al, [es:last_st]
        xor     ah, ah
        call    say_hex
st_nochf:
        mov     es, [res_seg]
        cmp     byte [es:tp_pk], 0
        jne     short st_pkf
        jmp     near st_nopkf
st_pkf:
        mov     dx, m_crlf
        call    say
        mov     dx, m_pkarp
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_arpin]
        call    say_num
        mov     dx, m_pkarp2
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_arpout]
        call    say_num
        mov     dx, m_pkarp3
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_drop]
        call    say_num
        mov     dx, m_pkarp4
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_err]
        call    say_num
        mov     dx, m_pkbound
        call    say
        mov     es, [res_seg]
        mov     al, [es:pkt_bound]
        xor     ah, ah
        call    say_num
        mov     dx, m_pkwd
        call    say
        mov     es, [res_seg]
        mov     ax, [es:wd_fired]
        call    say_num
        mov     dx, m_pkab
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_aband]
        call    say_num
        mov     dx, m_pkip
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_ip]
        call    say_num
        mov     dx, m_pkmine
        call    say
        mov     es, [res_seg]
        mov     ax, [es:pk_mine]
        call    say_num
        mov     dx, m_pkmac
        call    say
        mov     es, [res_seg]
        mov     si, peer_mac
        call    say_mac
        mov     dx, m_crlf
        call    say
        mov     dx, m_tcp
        call    say
        mov     es, [res_seg]
        mov     al, [es:tcp_state]
        xor     ah, ah
        call    say_num
        mov     dx, m_tcp2
        call    say
        mov     es, [res_seg]
        mov     ax, [es:tc_conn]
        call    say_num
        mov     dx, m_tcp3
        call    say
        mov     es, [res_seg]
        mov     ax, [es:tc_in]
        call    say_num
        mov     dx, m_tcp4
        call    say
        mov     es, [res_seg]
        mov     ax, [es:tc_out]
        call    say_num
        mov     dx, m_tcp5
        call    say
        mov     es, [res_seg]
        mov     ax, [es:tc_rex]
        call    say_num
        mov     dx, m_tcp6
        call    say
        mov     es, [res_seg]
        mov     ax, [es:tc_bad]
        call    say_num
st_nopkf:
        mov     dx, m_crlf
        call    say
        xor     al, al
        jmp     near quit

; --------------------------------------------------------------------------
do_unload:
        call    find_res
        jnc     short un_have
        mov     dx, m_none
        call    say
        mov     al, 2
        jmp     near quit
un_have:
        mov     [res_seg], ax

        ; Refuse if somebody hooked INT 08h or INT 14h after us -- unhooking
        ; from underneath them would leave their handler chained into memory
        ; we are about to give back.
        mov     ax, 0x3508
        int     0x21
        mov     ax, es
        cmp     ax, [res_seg]
        jne     short un_busy
        mov     ax, 0x3514
        int     0x21
        mov     ax, es
        cmp     ax, [res_seg]
        jne     short un_busy

        ; DEINITIALIZE THROUGH THE API BEFORE FREEING ANYTHING.  INT 14h
        ; still points at the resident copy, so function 05h runs ITS
        ; tp_close -- which is what hands a packet driver handle back and
        ; drops a modem's DTR.  Freeing the memory first would leave the
        ; packet driver holding a far pointer into a block DOS has just
        ; handed to something else, and the next matching frame jumps into
        ; it.  That is a box with no network, and the bridge runs over that
        ; network.
        mov     ah, 0x05
        xor     dx, dx
        int     0x14

        ; Lift the saved vectors out of the resident copy before touching
        ; anything, so the restore below needs nothing from it.
        mov     es, [res_seg]
        mov     ax, [es:old14]
        mov     [sv14o], ax
        mov     ax, [es:old14+2]
        mov     [sv14s], ax
        mov     ax, [es:old08]
        mov     [sv08o], ax
        mov     ax, [es:old08+2]
        mov     [sv08s], ax

        cli
        mov     al, 0x36                        ; PIT back to 18.2 Hz
        out     0x43, al
        xor     al, al
        out     0x40, al
        out     0x40, al
        sti

        push    ds
        mov     dx, [sv14o]
        mov     ax, [sv14s]
        mov     ds, ax
        mov     ax, 0x2514
        int     0x21
        pop     ds

        push    ds
        mov     dx, [sv08o]
        mov     ax, [sv08s]
        mov     ds, ax
        mov     ax, 0x2508
        int     0x21
        pop     ds

        mov     es, [res_seg]
        mov     ah, 0x49
        int     0x21

        mov     dx, m_unload
        call    say
        xor     al, al
        jmp     near quit

un_busy:
        mov     dx, m_busy
        call    say
        mov     al, 3
        jmp     near quit

; --------------------------------------------------------------------------
; Find an already-resident copy: follow INT 14h to its segment and look for
; the signature at 0103.  -> AX = segment, CF clear.  CF set if none.
; --------------------------------------------------------------------------
find_res:
        push    bx
        push    cx
        push    si
        push    di
        push    es
        mov     ax, 0x3514
        int     0x21
        mov     ax, es
        or      ax, ax
        je      short fr_no

        mov     es, ax
        mov     si, signature
        mov     di, 0x103
        mov     cx, 8
        push    ax
        push    ds
        push    cs
        pop     ds
        cld
        repe    cmpsb
        pop     ds
        pop     ax
        jne     short fr_no

        pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        clc
        ret
fr_no:
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        stc
        ret

; --------------------------------------------------------------------------
set_pit:
        mov     al, [tick_use]
        xor     ah, ah
        cmp     ax, 1
        jne     short sp_div
        xor     ax, ax                          ; divisor 1 -> reload 0
        jmp     short sp_prog
sp_div:
        mov     bx, ax
        mov     dx, 1
        xor     ax, ax
        div     bx
sp_prog:
        push    ax
        cli
        mov     al, 0x36
        out     0x43, al
        pop     ax
        out     0x40, al
        mov     al, ah
        out     0x40, al
        sti
        ret

; --------------------------------------------------------------------------
; Command line, out of the PSP at 0080.
; --------------------------------------------------------------------------
parse_cmd:
        mov     si, 0x81
        mov     cl, [0x80]
        xor     ch, ch
pc_loop:
        or      cx, cx
        jne     short pc_have
        jmp     near pc_done
pc_have:
        lodsb
        dec     cx
        cmp     al, '@'
        je      short pc_at
        cmp     al, '/'
        je      short pc_sw
        cmp     al, '-'
        je      short pc_sw
        jmp     short pc_loop
pc_at:
        call    pc_hex
        or      ax, ax
        je      short pc_loop
        mov     [io_dat], ax
        inc     ax
        mov     [io_cmd], ax
        jmp     short pc_loop
pc_sw:
        or      cx, cx
        jne     short pc_swh
        jmp     near pc_done
pc_swh:
        lodsb
        dec     cx
        and     al, 0xDF                        ; upper case
        cmp     al, 'U'
        jne     short pc_ns
        mov     byte [op_unload], 1
        jmp     short pc_loop
pc_ns:
        cmp     al, 'S'
        jne     short pc_nl
        mov     byte [op_status], 1
        jmp     short pc_loop
pc_nl:
        cmp     al, 'L'
        je      short pc_loop                   ; loopback is the default
        cmp     al, 'R'
        jne     short pc_nb
        call    pc_value
        or      ax, ax
        je      short pc_loop
        cmp     ax, 16
        ja      short pc_loop
        mov     [tick_n], al
        jmp     short pc_loop
pc_nb:
        cmp     al, 'B'
        jne     short pc_nc
        call    pc_value
        mov     [loop_rate], ax
        jmp     short pc_loop
pc_nc:
        cmp     al, 'C'
        jne     short pc_nd
        mov     byte [op_ch375], 1
        jmp     short pc_loop
pc_nd:
        cmp     al, 'D'
        jne     short pc_np
        call    pc_value
        or      ax, ax
        je      short pc_l2
        mov     [ser_baud], ax
pc_l2:
        jmp     near pc_loop
pc_np:
        cmp     al, 'P'
        jne     short pc_nv
        mov     byte [op_pkt], 1
        jmp     near pc_loop
pc_nv:
        cmp     al, 'V'
        jne     short pc_ni
        call    pc_skipeq
        call    pc_hex
        mov     [pkt_vec], al
        jmp     near pc_loop
pc_ni:
        cmp     al, 'I'
        jne     short pc_nh
        call    pc_skipeq
        mov     di, my_ip
        call    pc_ipv
        jmp     near pc_loop
pc_nh:
        cmp     al, 'H'
        jne     short pc_nt
        call    pc_skipeq
        mov     di, peer_ip
        call    pc_ipv
        jmp     near pc_loop
pc_nt:
        cmp     al, 'T'
        jne     short pc_ng
        call    pc_value
        or      ax, ax
        je      short pc_l3
        mov     [tcp_lport], ax
        jmp     near pc_loop
pc_ng:
        cmp     al, 'G'
        jne     short pc_l3
        call    pc_skipeq
        mov     di, gw_ip
        call    pc_ipv
pc_l3:
        jmp     near pc_loop
pc_done:
        ret

pc_skipeq:
        or      cx, cx
        je      short pse_out
        cmp     byte [si], '='
        jne     short pse_out
        inc     si
        dec     cx
pse_out:
        ret

; Read a dotted quad into CS:DI.
pc_ipv:
        push    bx
        mov     bx, 4
piv_part:
        call    pc_value
        mov     [di], al
        inc     di
        or      cx, cx
        je      short piv_out
        cmp     byte [si], '.'
        jne     short piv_out
        inc     si
        dec     cx
        dec     bx
        jne     short piv_part
piv_out:
        pop     bx
        ret

; Read a hexadecimal number.  -> AX
pc_hex:
        push    bx
        xor     bx, bx
ph_loop:
        or      cx, cx
        je      short ph_out
        mov     al, [si]
        cmp     al, '0'
        jb      short ph_out
        cmp     al, '9'
        jbe     short ph_dig
        and     al, 0xDF
        cmp     al, 'A'
        jb      short ph_out
        cmp     al, 'F'
        ja      short ph_out
        sub     al, 'A' - 10 - '0'
ph_dig:
        sub     al, '0'
        inc     si
        dec     cx
        mov     ah, 4
ph_shift:
        shl     bx, 1
        dec     ah
        jne     short ph_shift
        xor     ah, ah
        add     bx, ax
        jmp     short ph_loop
ph_out:
        mov     ax, bx
        pop     bx
        ret

; Skip '=' and read a decimal number.  -> AX
pc_value:
        push    bx
        xor     bx, bx
        or      cx, cx
        je      short pv_out
        cmp     byte [si], '='
        jne     short pv_digits
        inc     si
        dec     cx
pv_digits:
        or      cx, cx
        je      short pv_out
        mov     al, [si]
        cmp     al, '0'
        jb      short pv_out
        cmp     al, '9'
        ja      short pv_out
        inc     si
        dec     cx
        sub     al, '0'
        xor     ah, ah
        push    ax
        mov     ax, bx
        mov     bx, 10
        mul     bx
        mov     bx, ax
        pop     ax
        add     bx, ax
        jmp     short pv_digits
pv_out:
        mov     ax, bx
        pop     bx
        ret

; --------------------------------------------------------------------------
; Output.  Through DOS, so it is captured over the bridge.
; --------------------------------------------------------------------------
say:
        push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret

; AX = value, printed as decimal.
say_num:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
sn_div:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jne     short sn_div
sn_out:
        pop     dx
        add     dl, '0'
        mov     ah, 2
        int     0x21
        loop    sn_out
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ES:SI = six bytes, printed as a MAC address.
say_mac:
        push    ax
        push    cx
        push    dx
        mov     cx, 6
smc_b:
        mov     al, [es:si]
        inc     si
        push    cx
        mov     cl, 4
        shr     al, cl
        pop     cx
        call    smc_dig
        mov     al, [es:si-1]
        and     al, 15
        call    smc_dig
        dec     cx
        je      short smc_out
        mov     dl, ':'
        mov     ah, 2
        int     0x21
        jmp     short smc_b
smc_out:
        pop     dx
        pop     cx
        pop     ax
        ret
smc_dig:
        cmp     al, 10
        jb      short smd_n
        add     al, 'A' - 10 - '0'
smd_n:
        add     al, '0'
        mov     dl, al
        mov     ah, 2
        int     0x21
        ret

; CS:SI = four bytes, printed as a dotted quad.
say_ip:
        push    ax
        push    bx
        push    cx
        mov     cx, 4
sip_b:
        mov     al, [si]
        inc     si
        xor     ah, ah
        call    say_num
        dec     cx
        je      short sip_out
        mov     dl, '.'
        mov     ah, 2
        int     0x21
        jmp     short sip_b
sip_out:
        pop     cx
        pop     bx
        pop     ax
        ret

; DX:AX = value, printed as decimal.  The double division is the standard
; 32-by-16 trick: the first DIV leaves its remainder in DX, which the second
; then consumes as the high half.
num32:  dd      0
say_num32:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     [num32], ax
        mov     [num32+2], dx
        xor     cx, cx
sn32_d:
        mov     bx, 10
        mov     ax, [num32+2]
        xor     dx, dx
        div     bx
        mov     [num32+2], ax
        mov     ax, [num32]
        div     bx
        mov     [num32], ax
        push    dx
        inc     cx
        mov     ax, [num32]
        or      ax, [num32+2]
        jne     short sn32_d
sn32_o:
        pop     dx
        add     dl, '0'
        mov     ah, 2
        int     0x21
        loop    sn32_o
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; AX = value, printed as four hex digits.
say_hex:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, ax
        mov     cx, 4
sh_dig:
        mov     ax, bx
        mov     dx, cx
        dec     dx
        push    cx
        mov     cl, 4
        mul_sh:
        or      dx, dx
        je      short sh_have
        shr     ax, cl
        dec     dx
        jmp     short mul_sh
sh_have:
        pop     cx
        and     ax, 15
        cmp     al, 10
        jb      short sh_num
        add     al, 'A' - 10 - '0'
sh_num:
        add     al, '0'
        mov     dl, al
        mov     ah, 2
        int     0x21
        loop    sh_dig
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

quit:
        mov     ah, 0x4C
        int     0x21

; --------------------------------------------------------------------------
op_unload: db   0
op_status: db   0
op_ch375:  db   0
op_pkt:    db   0
res_seg:   dw   0
sv14o:     dw   0
sv14s:     dw   0
sv08o:     dw   0
sv08s:     dw   0

m_banner:  db   'FOSSIL 0.1.0 -- StevenC', 13, 10, '$'
m_ok:      db   'Installed.  ', '$'
m_tloop:   db   'Transport: loopback.', 13, 10, '$'
m_tch:     db   'Transport: CH375, adapter ', '$'
m_colon:   db   ':', '$'
m_tep:     db   '  IN ep ', '$'
m_tepo:    db   '  OUT ep ', '$'
m_tepc:    db   '  ctl ep ', '$'
m_tbaud:   db   '  baud ', '$'
m_tbatch:  db   '  batch ', '$'
m_tpk:     db   'Transport: packet driver at INT ', '$'
m_tpk2:    db   'h  ip ', '$'
m_tpk3:    db   '  peer ', '$'
m_tpk4:    db   '  listening on port ', '$'
m_novec:   db   'With /P you must name the vector, e.g. /V=60 -- this driver', 13, 10
           db   'will not take the first packet driver it finds, because on a', 13, 10
           db   'bridge machine that is the link you are working over.', 13, 10, '$'
m_rate:    db   '  PIT divisor ', '$'
m_rate2:   db   ', loopback ', '$'
m_rate3:   db   ' bytes per tick', 13, 10, '$'
m_already: db   'A FOSSIL driver is already resident; not loading a second.', 13, 10, '$'
m_none:    db   'No resident FOSSIL driver found.', 13, 10, '$'
m_found:   db   'Resident FOSSIL, version $'
m_unload:  db   'Unloaded.', 13, 10, '$'
m_busy:    db   'Cannot unload: INT 08h or INT 14h was hooked after us.', 13, 10, '$'
m_stats:   db   '  rx ', '$'
m_stats2:  db   '  tx ', '$'
m_stats3:  db   '  lost ', '$'
m_stats4:  db   '  polls ', '$'
m_chpk:    db   '  CH375 IN packets ', '$'
m_chpk2:   db   '  OUT packets ', '$'
m_chpk3:   db   '  errors ', '$'
m_chpk4:   db   '  last status ', '$'
m_pkarp:   db   '  ARP in ', '$'
m_pkarp2:  db   '  out ', '$'
m_pkarp3:  db   '  dropped ', '$'
m_pkarp4:  db   '  errors ', '$'
m_pkbound: db   '  handles held ', '$'
m_pkwd:    db   '  watchdog fired ', '$'
m_pkab:    db   '  abandoned ', '$'
m_pkip:    db   '  IP frames ', '$'
m_pkmine:  db   '  for us ', '$'
m_pkmac:   db   '  peer MAC ', '$'
m_tcp:     db   '  TCP state ', '$'
m_tcp2:    db   '  calls ', '$'
m_tcp3:    db   '  seg in ', '$'
m_tcp4:    db   '  out ', '$'
m_tcp5:    db   '  rexmit ', '$'
m_tcp6:    db   '  bad ', '$'
m_crlf:    db   13, 10, '$'

%include "ch375i.inc"
