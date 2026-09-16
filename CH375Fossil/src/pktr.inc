; ==========================================================================
; pktr.inc -- the packet-driver transport, RESIDENT half.  ARP and the
;             handle lifecycle; TCP sits on top of this and is not here yet.
;
; Included by fossil.asm ABOVE the rings.
;
; WHY THIS EXISTS AT ALL.  A packet driver is a published interrupt API on
; one vector in 60h..80h, and every driver that implements it looks the
; same from up here -- NE2000.COM, PicoMEM's pm2000, and CH375Net's own
; USBPKT, which installs a Crynwr driver over a USB Ethernet adapter.  So
; this transport binds to a VECTOR, not to a card, and a BBS running on it
; neither knows nor can tell what the frames leave through.
;
; THE HANDLE IS THE DANGEROUS PART, and the rule was already paid for.
; docs/network.md, on PKTCAP:
;
;     A frame delivered to your handle is not delivered to mTCP's [...] an
;     unqualified capture can quietly starve the link you are working over
;     [...] the bridge runs over that network, so recovery needs hands on
;     the keyboard.
;
; Hence three things here, none of them optional:
;
;   * THE VECTOR MUST BE NAMED.  There is no "find the first packet driver"
;     path, because on this machine the first one is the bridge's own.
;
;   * THE HANDLE IS BOUND TO THE SESSION, NOT TO THE DRIVER.  Nothing is
;     taken at load time; function 04h binds and function 05h releases.  A
;     loaded-but-idle FOSSIL is harmless, which is what makes it safe to
;     leave resident on a machine reached over the same card.
;
;   * A WATCHDOG RELEASES IT ANYWAY.  If the application stops talking to
;     us for WD_SECS, the handles go back on their own.  That is what turns
;     "the test program crashed" from a trip to the keyboard into a pause,
;     and it is the same class of fault as the dangling PS/2 callback that
;     made one crash get inherited by the next program.
;
; TWO HANDLES, DIFFERENT TYPES, AT THE SAME TIME.  0800 for IP and 0806 for
; ARP, held together.  The spec lets a driver refuse a second access_type
; for a type ALREADY IN USE -- same type, not any type -- and net.pas now
; holds both concurrently for the same reason this must: answering ARP is
; not optional.  A box that does not answer ARP stops being reachable the
; moment its neighbour's cache expires, and that was the cause of the
; transport stall that took weeks to find.
; ==========================================================================

FRM_MAX         equ 1518
WD_TICKS        equ 8700        ; about 60 seconds at the default tick rate

pkt_vec:   db   0               ; 0 = none named, and none will be guessed
pkt_entry: dd   0               ; the driver's handler, copied from the IVT
h_ip:      dw   0xFFFF          ; access_type handle for 0800, FFFF = none
h_arp:     dw   0xFFFF          ; and for 0806
pkt_bound: db   0

my_ip:     db   0, 0, 0, 0
gw_ip:     db   0, 0, 0, 0
peer_ip:   db   0, 0, 0, 0
my_mac:    times 6 db 0
peer_mac:  times 6 db 0
peer_ok:   db   0               ; 1 = peer_mac is resolved

wd_left:   dw   0               ; ticks until the handles are given back
in_svc:    db   0               ; pt_service is running; do not nest
svc_last:  dw   0               ; tick_cnt when it last ran
svc_delta: dw   0               ; ticks since then, which drives every timer

pk_arpin:  dw   0               ; ARP frames seen
pk_arpout: dw   0               ; ARP frames sent
pk_drop:   dw   0               ; frames refused because the buffer was busy
pk_err:    dw   0               ; send_pkt failures
pk_ip:     dw   0               ; IP frames seen
pk_mine:   dw   0               ; ...of which were addressed to us
pk_aband:  dw   0               ; buffers asked for and then never filled
wd_fired:  dw   0               ; times the watchdog took the handles back

; ---- the receive ring ----
; A SINGLE BUFFER IS NOT ENOUGH, and the ARP test proved it before TCP could
; suffer from it: three frames arrived while the tick had not yet looked at
; the last one, and all three were refused.  ARP shrugs that off because it
; retries; TCP would retransmit instead, and a connection that loses every
; burst is one that crawls for reasons no counter would explain.
;
; Slots are offered to the driver round-robin.  State is 0 free, 1 being
; filled right now, 2 ready for the tick.
; EIGHT, not four.  We hold the handle for ethertype 0800, so every IP
; broadcast on the segment is delivered to us as well as the traffic we
; care about -- and a burst of those can fill the ring between two ticks.
; When it is full the frame we refuse may be an ACK, and a refused ACK is a
; retransmission a second later.  That is how `dropped 3` and `rexmit 5`
; turned out to be the same fault seen from two ends.
FRM_SLOTS  equ  8
FRM_DRAIN  equ  8      ; frames per service pass; see pt_service
frm_state: times FRM_SLOTS db 0
frm_lens:  times FRM_SLOTS dw 0
frm_fill:  db   0               ; the slot handed out by the AX=0 call
frm_rd:    db   0               ; the next slot the tick should look at
frm_wr:    db   0               ; where to start hunting for a free one
frm_bufs:  times FRM_SLOTS * FRM_MAX db 0
arp_tx:    times 60 db 0

et_ip:     db   0x08, 0x00
et_arp:    db   0x08, 0x06

; --------------------------------------------------------------------------
; Call the packet driver.  The INT opcode takes an immediate, so the vector
; is reached with PUSHF and a far CALL, which leaves the stack exactly as
; INT would and unwinds correctly on the driver's IRET.
;
; The driver returns with DS pointing at ITS segment, so every global here
; is unreachable until DS is put back.  PUSH/POP do not touch the flags, so
; the carry the driver returned is still valid afterwards.
; --------------------------------------------------------------------------
pkt_call:
        pushf
        call    far [cs:pkt_entry]
        push    cs
        pop     ds
        ret

; --------------------------------------------------------------------------
; The receiver.  The driver calls it twice per frame, at interrupt time,
; with DS belonging to the driver:
;
;   AX = 0   it wants a buffer of CX bytes -- return ES:DI, or 0:0 to drop
;   AX = 1   the frame has been copied in
;
; While frm_busy is set we return 0:0 and count a drop rather than
; overwriting a frame the tick has not looked at yet.
; --------------------------------------------------------------------------
pkt_recv:
        or      ax, ax
        jne     short prv_have

        push    cs
        pop     ds
        cmp     cx, FRM_MAX
        ja      short prv_drop

        push    bx
        push    dx

        ; A buffer asked for and never filled -- an aborted frame, a CRC
        ; error -- would otherwise sit in the "being filled" state for ever
        ; and leak a slot.  Only one is ever outstanding, so being asked for
        ; another means the last one is finished with either way.
        mov     bl, [frm_fill]
        mov     bh, 0
        cmp     byte [bx+frm_state], 1
        jne     short prv_hunt0
        mov     byte [bx+frm_state], 0
        mov     [frm_wr], bl
        inc     word [pk_aband]

prv_hunt0:
        mov     bl, [frm_wr]
        mov     dl, FRM_SLOTS
prv_hunt:
        mov     bh, 0
        cmp     byte [bx+frm_state], 0
        je      short prv_got
        inc     bl
        cmp     bl, FRM_SLOTS
        jb      short prv_h2
        xor     bl, bl
prv_h2:
        dec     dl
        jne     short prv_hunt
        pop     dx
        pop     bx
        jmp     short prv_drop
prv_got:
        mov     byte [bx+frm_state], 1
        mov     [frm_fill], bl
        mov     bh, 0
        shl     bx, 1
        mov     [bx+frm_lens], cx
        shr     bx, 1
        call    slot_addr
        mov     di, ax

        ; THE WRITE INDEX MUST MOVE PAST THE SLOT JUST TAKEN.
        ;
        ; It used to be left pointing AT it, so once the drain had freed
        ; that slot the next frame was put straight back into it -- while
        ; the drain, which reads strictly in order at frm_rd, had already
        ; moved on to the next slot and found it empty.  It then stopped and
        ; never came back: the ring quietly ceased draining, and every frame
        ; after that was refused.  One fault, three symptoms -- a drop count
        ; that would not go down, a six per cent retransmit rate, and a
        ; second call whose handshake ACK was thrown away.
        inc     bl
        cmp     bl, FRM_SLOTS
        jb      short prv_wr
        xor     bl, bl
prv_wr:
        mov     [frm_wr], bl

        pop     dx
        pop     bx
        push    cs
        pop     es
        retf

prv_drop:
        inc     word [pk_drop]
        xor     di, di
        mov     es, di
        retf

prv_have:
        push    cs
        pop     ds
        push    bx
        mov     bl, [frm_fill]
        mov     bh, 0
        mov     byte [bx+frm_state], 2
        pop     bx
        retf

; --------------------------------------------------------------------------
; Take the two handles.  CF set if either is refused, with both released
; again so a partial bind can never be left behind.
; --------------------------------------------------------------------------
pkt_bind:
        cmp     byte [pkt_bound], 0
        je      short pb_go
        clc
        ret
pb_go:
        cmp     byte [pkt_vec], 0
        jne     short pb_vec
        stc
        ret
pb_vec:
        ; Copy the handler out of the interrupt table.
        push    es
        xor     ax, ax
        mov     es, ax
        mov     al, [pkt_vec]
        xor     ah, ah
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     ax, [es:si]
        mov     [pkt_entry], ax
        mov     ax, [es:si+2]
        mov     [pkt_entry+2], ax
        pop     es

        ; access_type for IP
        mov     ax, 0x0200                   ; AH=02h, AL=1 (DIX Ethernet)
        mov     al, 1
        mov     bx, 0xFFFF                   ; any type
        mov     dl, 0                        ; interface 0
        push    cs
        pop     ds
        mov     si, et_ip
        mov     cx, 2
        push    cs
        pop     es
        mov     di, pkt_recv
        call    pkt_call
        jc      short pb_fail
        mov     [h_ip], ax

        ; access_type for ARP
        mov     ah, 0x02
        mov     al, 1
        mov     bx, 0xFFFF
        mov     dl, 0
        push    cs
        pop     ds
        mov     si, et_arp
        mov     cx, 2
        push    cs
        pop     es
        mov     di, pkt_recv
        call    pkt_call
        jc      short pb_fail2
        mov     [h_arp], ax

        ; get_address: our own MAC, which every frame we build needs
        mov     ah, 0x06
        mov     bx, [h_ip]
        push    cs
        pop     es
        mov     di, my_mac
        mov     cx, 6
        call    pkt_call

        mov     byte [pkt_bound], 1
        call    frm_reset
        mov     byte [peer_ok], 0
        mov     word [wd_left], WD_TICKS
        clc
        ret

pb_fail2:
        mov     ah, 0x03
        mov     bx, [h_ip]
        call    pkt_call
pb_fail:
        mov     word [h_ip], 0xFFFF
        mov     word [h_arp], 0xFFFF
        inc     word [pk_err]
        stc
        ret

; --------------------------------------------------------------------------
; Give the handles back.  Safe to call when nothing is held, because that is
; exactly what the watchdog and the unload path both do.
; --------------------------------------------------------------------------
pkt_unbind:
        cmp     byte [pkt_bound], 0
        je      short pu_out
        cmp     word [h_arp], 0xFFFF
        je      short pu_ip
        mov     ah, 0x03
        mov     bx, [h_arp]
        call    pkt_call
        mov     word [h_arp], 0xFFFF
pu_ip:
        cmp     word [h_ip], 0xFFFF
        je      short pu_done
        mov     ah, 0x03
        mov     bx, [h_ip]
        call    pkt_call
        mov     word [h_ip], 0xFFFF
pu_done:
        mov     byte [pkt_bound], 0
        mov     byte [peer_ok], 0
pu_out:
        ret

; BL = slot number -> AX = the address of that slot's buffer.
;
; This has to be a 16-bit multiply.  `mul bl` is an EIGHT-bit one -- AX =
; AL * BL -- so with FRM_MAX in AX it silently multiplied by the low byte of
; 1518 and handed back an address in the middle of nowhere.  Both the
; receiver and the poll loop had their own copy of that line, and both were
; wrong the same way.
slot_addr:
        push    bx
        push    dx
        mov     bh, 0
        mov     ax, FRM_MAX
        mul     bx
        add     ax, frm_bufs
        pop     dx
        pop     bx
        ret

frm_reset:
        push    bx
        push    cx
        mov     bx, 0
        mov     cx, FRM_SLOTS
fr_z:
        mov     byte [bx+frm_state], 0
        inc     bx
        loop    fr_z
        mov     byte [frm_rd], 0
        mov     byte [frm_wr], 0
        mov     byte [frm_fill], 0
        pop     cx
        pop     bx
        ret

; DS:SI = frame, CX = length.
pkt_send:
        mov     ah, 0x04
        call    pkt_call
        jnc     short ps_out
        inc     word [pk_err]
ps_out:
        ret

; --------------------------------------------------------------------------
; Ask who has peer_ip.
; --------------------------------------------------------------------------
arp_request:
        push    cs
        pop     es
        mov     di, arp_tx
        mov     cx, 60
        xor     al, al
        cld
        rep     stosb

        mov     di, arp_tx
        mov     cx, 6                        ; destination: broadcast
        mov     al, 0xFF
        rep     stosb
        mov     si, my_mac                   ; source
        mov     cx, 6
        push    cs
        pop     ds
        rep     movsb
        mov     al, 0x08                     ; ethertype 0806
        stosb
        mov     al, 0x06
        stosb

        mov     al, 0x00                     ; htype 0001
        stosb
        mov     al, 0x01
        stosb
        mov     al, 0x08                     ; ptype 0800
        stosb
        mov     al, 0x00
        stosb
        mov     al, 6                        ; hlen
        stosb
        mov     al, 4                        ; plen
        stosb
        mov     al, 0x00                     ; op 0001, request
        stosb
        mov     al, 0x01
        stosb
        mov     si, my_mac                   ; sender hardware address
        mov     cx, 6
        rep     movsb
        mov     si, my_ip                    ; sender protocol address
        mov     cx, 4
        rep     movsb
        mov     cx, 6                        ; target hardware address: unknown
        xor     al, al
        rep     stosb
        mov     si, peer_ip                  ; target protocol address
        mov     cx, 4
        rep     movsb

        push    cs
        pop     ds
        mov     si, arp_tx
        mov     cx, 60
        call    pkt_send
        inc     word [pk_arpout]
        ret

; --------------------------------------------------------------------------
; Handle one received ARP frame.  cur_ptr points at it, cur_len is its size.
;
; ANSWERING IS THE LOAD-BEARING HALF.  A box that only ASKS looks fine until
; its neighbour's cache expires, and then it silently stops being reachable
; -- which is the shape of the transport stall in docs/network.md that took
; weeks to find, because `arp -a` prints a `dynamic` entry for an address
; whose neighbour state is Unreachable.  The tool could not express the
; answer, so the answer read as "no".
; --------------------------------------------------------------------------
arp_service:
        inc     word [pk_arpin]
        cmp     word [cur_len], 42
        jb      short as_out
        mov     bx, [cur_ptr]
        cmp     byte [bx + 20], 0                ; opcode, big-endian
        jne     short as_out
        cmp     byte [bx + 21], 1
        je      short as_req
        cmp     byte [bx + 21], 2
        je      short as_reply
as_out:
        ret

as_reply:
        ; Sender protocol address is at 28, sender hardware address at 22.
        mov     si, [cur_ptr]
        add     si, 28
        mov     di, peer_ip
        mov     cx, 4
        push    cs
        pop     es
        cld
        repe    cmpsb
        jne     short as_out
        mov     si, [cur_ptr]
        add     si, 22
        mov     di, peer_mac
        mov     cx, 6
        rep     movsb
        mov     byte [peer_ok], 1
        ret

as_req:
        ; Is the target protocol address, at 38, ours?
        mov     si, [cur_ptr]
        add     si, 38
        mov     di, my_ip
        mov     cx, 4
        push    cs
        pop     es
        cld
        repe    cmpsb
        jne     short as_out

        mov     di, arp_tx
        mov     cx, 60
        xor     al, al
        rep     stosb

        mov     di, arp_tx
        mov     si, [cur_ptr]
        add     si, 6                            ; their MAC becomes our dest
        mov     cx, 6
        rep     movsb
        mov     si, my_mac
        mov     cx, 6
        rep     movsb
        mov     al, 0x08
        stosb
        mov     al, 0x06
        stosb
        mov     al, 0x00
        stosb
        mov     al, 0x01
        stosb
        mov     al, 0x08
        stosb
        mov     al, 0x00
        stosb
        mov     al, 6
        stosb
        mov     al, 4
        stosb
        mov     al, 0x00                         ; op 0002, reply
        stosb
        mov     al, 0x02
        stosb
        mov     si, my_mac
        mov     cx, 6
        rep     movsb
        mov     si, my_ip
        mov     cx, 4
        rep     movsb
        mov     si, [cur_ptr]
        add     si, 22                           ; back to the asker
        mov     cx, 6
        rep     movsb
        mov     si, [cur_ptr]
        add     si, 28
        mov     cx, 4
        rep     movsb

        push    cs
        pop     ds
        mov     si, arp_tx
        mov     cx, 60
        call    pkt_send
        inc     word [pk_arpout]
        ret

cur_ptr:   dw   0
cur_len:   dw   0

; --------------------------------------------------------------------------
; The transport entry points
; --------------------------------------------------------------------------
pt_open:
        call    pkt_bind
        jc      short pto_out
        call    tcp_listen
        call    arp_request
pto_out:
        ret

pt_close:
        call    tcp_shutdown
        call    pkt_unbind
        ret


; --------------------------------------------------------------------------
; THE TIMER'S ONLY JOB HERE IS THE WATCHDOG.
;
; Everything else -- draining frames, sending segments, retransmitting --
; moved to pt_service, which runs from INT 14h.  The reason is that sending
; means calling the packet driver, and a packet driver commonly enables
; interrupts during its own IRQ so as not to block the clock.  Do it from a
; timer interrupt and our tick can land inside the driver and call send_pkt
; re-entrantly; most drivers are not re-entrant, and this machine hung hard
; enough to need the plug pulled.  Twice.
;
; A BBS calls function 03h continuously, so INT 14h is a livelier clock than
; the timer for this purpose anyway.
;
; The watchdog stays here on purpose, and it is the ONE driver call still
; made from interrupt context.  It exists for the case where the application
; has DIED -- which is exactly when INT 14h stops being called, so a
; watchdog driven from there could never fire.  It runs once, long after any
; foreground code has stopped touching the driver.
; --------------------------------------------------------------------------
pt_tick:
        cmp     byte [pkt_bound], 0
        je      short ptk_out
        cmp     word [wd_left], 0
        je      short ptk_expire
        dec     word [wd_left]
        jne     short ptk_out
ptk_expire:
        inc     word [wd_fired]
        call    tcp_shutdown
        call    pkt_unbind
ptk_out:
        ret

; --------------------------------------------------------------------------
; Service the transport.  Foreground only, from INT 14h.
; --------------------------------------------------------------------------
pt_service:
        inc     word [st_tick]                   ; "polls" in /S means SERVICE
        cmp     byte [pkt_bound], 0              ; passes now, not timer ticks
        je      short psv_out
        cmp     byte [in_svc], 0
        jne     short psv_out
        mov     byte [in_svc], 1

        ; How many timer ticks since the last time round?  Every timer in
        ; the transport is driven from this rather than from "once per
        ; call", because INT 14h is called at whatever rate the application
        ; feels like and a per-call countdown would run wild.
        mov     ax, [tick_cnt]
        mov     bx, ax
        sub     ax, [svc_last]
        mov     [svc_last], bx
        mov     [svc_delta], ax

        ; Drain the whole ring in one pass.
        ;
        ; This budget was two for a while, and the reason is worth keeping
        ; because the reason is now gone.  Each frame handled here can send
        ; a segment, and sending calls the packet driver; while this ran
        ; from the TIMER that meant a tick could land inside a driver which
        ; had enabled interrupts during its own IRQ, and re-enter it.  Most
        ; are not re-entrant, and the machine wedged hard enough to need the
        ; plug pulled -- twice.  A small budget was the mitigation.
        ;
        ; pt_service runs from INT 14h now, in the foreground, where calling
        ; the driver is simply a call.  The cap has nothing left to protect
        ; against, and a ring that can only be emptied a fraction at a time
        ; is just a slower ring.
        mov     cx, FRM_DRAIN
ptp_next:
        push    cx
        mov     bl, [frm_rd]
        mov     bh, 0
        cmp     byte [bx+frm_state], 2
        jne     short ptp_none
        call    slot_addr
        mov     [cur_ptr], ax
        shl     bx, 1
        mov     ax, [bx+frm_lens]
        mov     [cur_len], ax
        shr     bx, 1

        ; frm_dispatch and everything under it use BX freely, so the slot
        ; number has to survive on the stack.
        push    bx
        call    frm_dispatch
        pop     bx

        mov     byte [bx+frm_state], 0
        inc     bl
        cmp     bl, FRM_SLOTS
        jb      short ptp_adv
        xor     bl, bl
ptp_adv:
        mov     [frm_rd], bl
        pop     cx
        loop    ptp_next
        jmp     short ptp_tick
ptp_none:
        pop     cx
ptp_tick:
        call    tcp_tick
        mov     byte [in_svc], 0
psv_out:
        ret

; Refreshed by the INT 14h functions a live session actually calls, so an
; application that has stopped calling us is what the watchdog notices --
; not merely one that has stopped receiving.
wd_kick:
        cmp     byte [pkt_bound], 0
        je      short wk_out
        mov     word [wd_left], WD_TICKS
wk_out:
        ret

; Which protocol is this frame?  Ethertype sits at offset 12.
frm_dispatch:
        mov     bx, [cur_ptr]
        cmp     byte [bx + 12], 0x08
        jne     short fd_out
        cmp     byte [bx + 13], 0x06
        je      short fd_arp
        cmp     byte [bx + 13], 0x00
        je      short fd_ip
fd_out:
        ret
fd_arp:
        jmp     near arp_service
fd_ip:
        jmp     near tcp_rx_frame
