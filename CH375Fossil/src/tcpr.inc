; ==========================================================================
; tcpr.inc -- just enough TCP to be a modem, and telnet on top of it.
;
; Included by fossil.asm ABOVE the rings, after pktr.inc.
;
; IT LISTENS; IT DOES NOT DIAL.  A BBS waits for a call, and that maps onto
; modem semantics so exactly that unmodified BBS software needs no telnet
; awareness at all:
;
;       listening              ->  no carrier
;       connection accepted    ->  DCD goes high, a call
;       connection closed      ->  DCD drops, the caller hung up
;       application drops DTR  ->  we send FIN, which IS hanging up
;
; WHAT THIS DELIBERATELY IS NOT.  It is one connection, stop-and-wait, with
; no reassembly queue: a segment arriving out of order is dropped and
; re-ACKed rather than held, so the sender retransmits it.  That is correct
; TCP -- just slow under loss -- and on a LAN carrying a terminal session at
; a few hundred bytes a second it costs nothing measurable.  The alternative
; is a reassembly queue and a send window, which is a great deal more code
; whose failure mode is silent corruption rather than a visible stall.  This
; project has a written rule about which of those two to prefer.
;
; The checksum is summed as LITTLE-endian words even though the protocol
; defines big-endian ones.  That is not a shortcut: RFC 1071 section 2(B)
; says the sum may be computed in either byte order, and the result stored
; in the same order is identical.  It saves a byte swap on every word of
; every packet, on a machine where that is the whole budget.
; ==========================================================================

TS_CLOSED       equ 0
TS_LISTEN       equ 1
TS_SYNRCVD      equ 2
TS_ESTAB        equ 3
TS_LASTACK      equ 4
TS_FINWAIT      equ 5

TF_FIN          equ 0x01
TF_SYN          equ 0x02
TF_RST          equ 0x04
TF_PSH          equ 0x08
TF_ACK          equ 0x10

TCP_MSS         equ 512
; About 300 ms at the default tick rate, not a flat second.
;
; Measured from the caller's end, a 4 KB download arrived in chunks whose
; MEDIAN gap was 80 ms and whose worst was 1067 ms -- one round trip is fast
; and the occasional loss cost a full RTO, and those stalls were most of the
; elapsed time.  Segment size was not the problem (510 bytes, our MSS) and
; neither was the peer's delayed ACK.  So the timer comes down to roughly
; three times the observed round trip, and backs off from there instead of
; starting there.
RTO_TICKS       equ 44
RTO_MAX_SHIFT   equ 5           ; 300 ms doubling to about 10 s
MAX_RETRY       equ 8

tcp_state: db   TS_CLOSED
tcp_lport: dw   2323            ; the port we answer on, /T= overrides
tcp_rport: dw   0
tcp_rip:   times 4 db 0
tcp_rmac:  times 6 db 0

snd_una:   dd   0
snd_nxt:   dd   0
rcv_nxt:   dd   0

seg_len:   dw   0               ; payload bytes in the unacked segment
seg_ring:  dw   0               ; ring bytes it consumed, which differ when
                                ; an IAC had to be doubled
seg_fin:   db   0               ; the unacked segment carried our FIN
rto_left:  dw   0
retries:   db   0
fin_want:  db   0               ; the application has hung up; FIN when clear
ip_id:     dw   0x1234

tc_conn:   dw   0               ; calls answered
tc_in:     dw   0               ; segments accepted
tc_out:    dw   0               ; segments sent
tc_rex:    dw   0               ; retransmissions
tc_rst:    dw   0               ; resets seen or sent
tc_bad:    dw   0               ; segments dropped on checksum or state

tcp_tx:    times 600 db 0
pseudo:    times 12 db 0

; The telnet negotiation we open a call with.  It goes out as its own
; segment and is NOT escaped, which is why it cannot simply be pushed into
; the transmit ring: everything from the ring has its 0FFh bytes doubled,
; and these bytes ARE 0FFh on purpose.
tn_hello:  db   255, 251, 1     ; IAC WILL ECHO
           db   255, 251, 3     ; IAC WILL SUPPRESS-GO-AHEAD
           db   255, 253, 3     ; IAC DO   SUPPRESS-GO-AHEAD
           db   255, 251, 0     ; IAC WILL BINARY   -- 8-bit, for transfers
           db   255, 253, 0     ; IAC DO   BINARY
TN_HELLO_N equ  15
tn_pend:   db   0               ; the hello still owes a send

tn_st:     db   0               ; inbound telnet parser state
tn_cmd:    db   0

; Telnet replies are QUEUED, never sent from inside the receive path.
;
; The first version answered a negotiation by calling tcp_send_seg there and
; then, which put three bytes on the wire at snd_nxt and left snd_nxt where
; it was.  The peer accepted them and moved on; the next data segment went
; out at the SAME sequence number, so the peer trimmed the overlap and threw
; away exactly as many bytes of real output as we had sent in replies.
;
; The symptom was three to six characters missing from the very start of the
; session and nothing wrong anywhere after it -- which reads as a startup
; race, not as a sequencing fault, and sent the search in the wrong
; direction.  Anything that occupies sequence space has to go through the
; one path that advances it.
tn_oq:     times 24 db 0
tn_on:     db   0

; WHAT WE HAVE ALREADY SAID ABOUT EACH OPTION.
;
; RFC 854's loop-prevention rule is that a party must NOT acknowledge an
; acknowledgement -- reply only when the state actually changes.  Without
; it: we send WILL ECHO, the far end answers DO ECHO, we read that as a
; fresh request and send WILL ECHO again, and so on for ever.
;
; That is not hypothetical.  It produced THIRTY THOUSAND segments for two
; and a half kilobytes of real output, drowned the data so thoroughly that
; only eight bytes reached the application, and looked from the outside
; like a driver that intermittently would not answer.  Adding BINARY to the
; agreeable list tripled the rate of it.
TN_OPTS    equ  32
tn_us:     times TN_OPTS db 0   ; we have stated our WILL/WONT for this option
tn_them:   times TN_OPTS db 0   ; we have stated our DO/DONT for it

; ==========================================================================
; Byte-order and 32-bit helpers.  Sequence numbers are the only 32-bit
; arithmetic here, and they are held in DX:AX with DX as the high half.
; ==========================================================================

; DS:SI -> DX:AX, big-endian
get32be:
        mov     dh, [si]
        mov     dl, [si+1]
        mov     ah, [si+2]
        mov     al, [si+3]
        ret

; DX:AX -> ES:DI, big-endian
put32be:
        mov     [di], dh
        mov     [di+1], dl
        mov     [di+2], ah
        mov     [di+3], al
        ret

; DS:SI -> AX, big-endian
get16be:
        mov     ah, [si]
        mov     al, [si+1]
        ret

; ==========================================================================
; The internet checksum.  BX carries the running sum between calls.
; ==========================================================================
csum_blk:                                ; DS:SI, CX bytes, BX = running sum
        push    cx
        shr     cx, 1
        jcxz    cb_odd
cb_loop:
        lodsw
        add     bx, ax
        adc     bx, 0
        loop    cb_loop
cb_odd:
        pop     cx
        test    cx, 1
        je      short cb_out
        ; The pad byte is the HIGH half of the big-endian word, which is the
        ; LOW half once the sum is being taken little-endian.
        mov     al, [si]
        xor     ah, ah
        add     bx, ax
        adc     bx, 0
cb_out:
        ret

; ==========================================================================
; Build and send one segment.
;   AL = flags, SI = payload (0 for none), CX = payload length
; ==========================================================================
tcp_send_seg:
        push    cs
        pop     es
        mov     [ss_flags], al
        mov     [ss_len], cx
        mov     [ss_src], si

        ; ---- Ethernet ----
        mov     di, tcp_tx
        mov     si, tcp_rmac
        mov     cx, 6
        cld
        rep     movsb
        mov     si, my_mac
        mov     cx, 6
        rep     movsb
        mov     al, 0x08
        stosb
        xor     al, al
        stosb

        ; ---- IP ----
        mov     di, tcp_tx + 14
        mov     al, 0x45
        stosb
        xor     al, al
        stosb                            ; TOS
        mov     ax, [ss_len]
        add     ax, 40                   ; IP + TCP headers
        mov     [ss_iplen], ax
        mov     [di], ah                 ; total length, big-endian
        mov     [di+1], al
        add     di, 2
        mov     ax, [ip_id]
        inc     word [ip_id]
        mov     [di], ah
        mov     [di+1], al
        add     di, 2
        mov     al, 0x40                 ; don't fragment
        stosb
        xor     al, al
        stosb
        mov     al, 64                   ; TTL
        stosb
        mov     al, 6                    ; TCP
        stosb
        xor     ax, ax                   ; checksum, filled in below
        stosw
        mov     si, my_ip
        mov     cx, 4
        rep     movsb
        mov     si, tcp_rip
        mov     cx, 4
        rep     movsb

        ; IP header checksum over the 20 bytes just written
        xor     bx, bx
        mov     si, tcp_tx + 14
        mov     cx, 20
        call    csum_blk
        not     bx
        mov     [tcp_tx + 14 + 10], bx

        ; ---- TCP ----
        mov     di, tcp_tx + 34
        mov     ax, [tcp_lport]
        mov     [di], ah
        mov     [di+1], al
        mov     ax, [tcp_rport]
        mov     [di+2], ah
        mov     [di+3], al
        add     di, 4
        mov     si, snd_nxt
        call    get32be
        call    put32be
        add     di, 4
        mov     si, rcv_nxt
        call    get32be
        call    put32be
        add     di, 4
        mov     al, 0x50                 ; data offset 5, no options
        stosb
        mov     al, [ss_flags]
        stosb
        ; Advertise what the receive ring can actually take, which is how a
        ; well-behaved sender is told to slow down.
        call    rx_free
        cmp     ax, 1024
        jbe     short ss_win
        mov     ax, 1024
ss_win:
        mov     [di], ah
        mov     [di+1], al
        add     di, 2
        xor     ax, ax
        stosw                            ; checksum
        stosw                            ; urgent pointer

        ; ---- payload ----
        mov     cx, [ss_len]
        jcxz    ss_nopay
        mov     si, [ss_src]
        rep     movsb
ss_nopay:

        ; ---- TCP checksum, over the pseudo-header then the segment ----
        mov     di, pseudo
        mov     si, my_ip
        mov     cx, 4
        rep     movsb
        mov     si, tcp_rip
        mov     cx, 4
        rep     movsb
        xor     al, al
        stosb
        mov     al, 6
        stosb
        mov     ax, [ss_len]
        add     ax, 20
        mov     [di], ah
        mov     [di+1], al

        xor     bx, bx
        mov     si, pseudo
        mov     cx, 12
        call    csum_blk
        mov     si, tcp_tx + 34
        mov     cx, [ss_len]
        add     cx, 20
        call    csum_blk
        not     bx
        mov     [tcp_tx + 34 + 16], bx

        ; ---- send it ----
        push    cs
        pop     ds
        mov     si, tcp_tx
        mov     cx, [ss_iplen]
        add     cx, 14
        cmp     cx, 60                   ; the wire has a minimum
        jae     short ss_go
        mov     cx, 60
ss_go:
        call    pkt_send
        inc     word [tc_out]
        ret

ss_flags: db    0
ss_len:   dw    0
ss_src:   dw    0
ss_iplen: dw    0

; ==========================================================================
; State transitions
; ==========================================================================
tcp_listen:
        mov     byte [tcp_state], TS_LISTEN
        mov     byte [fin_want], 0
        mov     byte [dcd_st], 0
        mov     word [seg_len], 0
        mov     word [seg_ring], 0
        mov     byte [seg_fin], 0
        mov     byte [tn_pend], 0
        mov     byte [tn_st], 0
        mov     byte [retries], 0
        ret

; Hang up: send FIN if there is anything to hang up on.
; Hanging up asks for a FIN; it does not send one.
;
; The first version sent it here and then, from foreground code, and in
; doing so overwrote the tracking of whatever data segment was still
; unacknowledged -- so a last segment that happened to be lost could never
; be retransmitted, and the closing line of a session went missing.  The FIN
; has to queue behind the data like everything else, which means the tick
; sends it once the ring is empty and nothing is outstanding.
tcp_shutdown:
        cmp     byte [tcp_state], TS_ESTAB
        jne     short tsd_reset
        mov     byte [fin_want], 1
        ret
tsd_reset:
        mov     byte [dcd_st], 0
        ret

seq_bump1:
        mov     si, snd_nxt
        call    get32be
        add     ax, 1
        adc     dx, 0
        push    cs
        pop     es
        mov     di, snd_nxt
        call    put32be
        ret

; ==========================================================================
; A frame arrived and the ethertype said IP.
; ==========================================================================
tcp_rx_frame:
        inc     word [pk_ip]
        mov     bx, [cur_ptr]
        cmp     word [cur_len], 54
        jb      short trf_bad
        mov     al, [bx + 14]
        and     al, 0xF0
        cmp     al, 0x40                 ; IPv4
        jne     short trf_bad
        cmp     byte [bx + 14 + 9], 6    ; TCP
        jne     short trf_out

        ; is it for us?
        mov     si, bx
        add     si, 14 + 16
        mov     di, my_ip
        mov     cx, 4
        push    cs
        pop     es
        cld
        repe    cmpsb
        jne     short trf_out

        inc     word [pk_mine]

        ; TCP starts after the IP header, whose length is in the low nibble
        mov     al, [bx + 14]
        and     al, 0x0F
        mov     cl, 2
        shl     al, cl                   ; IHL in bytes
        xor     ah, ah
        add     ax, 14
        mov     [tcp_off], ax

        ; the port we answer on
        mov     si, [cur_ptr]
        add     si, [tcp_off]
        add     si, 2
        call    get16be
        cmp     ax, [tcp_lport]
        jne     short trf_out

        jmp     near tcp_input
trf_bad:
        inc     word [tc_bad]
trf_out:
        ret

tcp_off:  dw    0
seg_flags: db   0
seg_seq:  dd    0
seg_ack:  dd    0
seg_dlen: dw    0
seg_doff: dw    0

tcp_input:
        inc     word [tc_in]
        mov     bx, [cur_ptr]
        add     bx, [tcp_off]

        mov     al, [bx + 13]
        mov     [seg_flags], al

        mov     si, bx
        add     si, 4
        call    get32be
        push    cs
        pop     es
        mov     di, seg_seq
        call    put32be
        mov     si, bx
        add     si, 8
        call    get32be
        mov     di, seg_ack
        call    put32be

        ; payload offset and length
        mov     al, [bx + 12]
        mov     cl, 4
        shr     al, cl
        mov     ah, 0
        shl     ax, 1
        shl     ax, 1                    ; TCP header length in bytes
        mov     dx, ax
        mov     ax, [tcp_off]
        add     ax, dx
        mov     [seg_doff], ax           ; payload offset within the frame

        ; IP total length tells us the truth; the Ethernet frame may be padded
        mov     si, [cur_ptr]
        add     si, 14 + 2
        call    get16be                  ; IP total length
        add     ax, 14
        sub     ax, [seg_doff]
        jnc     short ti_dl
        xor     ax, ax
ti_dl:
        mov     [seg_dlen], ax

        ; RST at any time puts the line back on the hook.
        test    byte [seg_flags], TF_RST
        je      short ti_st
        inc     word [tc_rst]
        jmp     near tcp_listen

ti_st:
        mov     al, [tcp_state]
        cmp     al, TS_LISTEN
        jne     short ti_d1
        jmp     near ti_listen
ti_d1:
        cmp     al, TS_SYNRCVD
        jne     short ti_d2
        jmp     near ti_synrcvd
ti_d2:
        cmp     al, TS_ESTAB
        jne     short ti_d3
        jmp     near ti_estab
ti_d3:
        cmp     al, TS_LASTACK
        jne     short ti_d4
        jmp     near ti_lastack
ti_d4:
        cmp     al, TS_FINWAIT
        jne     short ti_d5
        jmp     near ti_finwait
ti_d5:
        ret

; ---- LISTEN: a call is coming in ----
ti_listen:
        test    byte [seg_flags], TF_SYN
        je      short ti_out
        test    byte [seg_flags], TF_ACK
        jne     short ti_out

        ; Remember who is calling: MAC, IP and port, so the reply goes back
        ; the way it came rather than through an ARP lookup we may not have.
        mov     si, [cur_ptr]
        add     si, 6
        mov     di, tcp_rmac
        mov     cx, 6
        push    cs
        pop     es
        cld
        rep     movsb
        mov     si, [cur_ptr]
        add     si, 14 + 12
        mov     di, tcp_rip
        mov     cx, 4
        rep     movsb
        mov     si, [cur_ptr]
        add     si, [tcp_off]
        call    get16be
        mov     [tcp_rport], ax

        ; rcv_nxt = their ISS + 1
        mov     si, seg_seq
        call    get32be
        add     ax, 1
        adc     dx, 0
        mov     di, rcv_nxt
        call    put32be

        ; our ISS: anything that is not the last one will do here
        mov     dx, [ip_id]
        mov     ax, [st_tick]
        mov     di, snd_nxt
        call    put32be
        mov     di, snd_una
        call    put32be

        mov     al, TF_SYN | TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
        call    seq_bump1
        mov     byte [tcp_state], TS_SYNRCVD
ti_out:
        ret

; ---- SYNRCVD: their ACK completes the handshake ----
ti_synrcvd:
        test    byte [seg_flags], TF_ACK
        je      short ti_out
        mov     si, seg_ack
        call    get32be
        push    cs
        pop     es
        mov     di, snd_una
        call    put32be
        mov     byte [tcp_state], TS_ESTAB
        mov     byte [dcd_st], 1         ; THE CALL IS UP.  This is the only
        inc     word [tc_conn]           ; thing a BBS needs to be told.
        mov     byte [tn_pend], 1
        mov     byte [tn_st], 0
        mov     byte [tn_on], 0
        mov     byte [fin_want], 0
        call    tn_reset
        ; A new caller must not inherit the last one's half-typed line.
        pushf
        cli
        mov     ax, [rx_head]
        mov     [rx_tail], ax
        mov     ax, [tx_head]
        mov     [tx_tail], ax
        popf
        mov     word [seg_len], 0
        mov     word [seg_ring], 0
        ; and the ACK may already carry data
        jmp     near ti_data

; ---- ESTABLISHED ----
ti_estab:
        test    byte [seg_flags], TF_ACK
        je      short ti_data
        call    ti_ackcheck
ti_data:
        ; Only in-order data is taken.  Anything else is dropped and the ACK
        ; we send re-states what we actually want next, which is what makes
        ; the sender resend it.
        cmp     word [seg_dlen], 0
        jne     short ti_haved
        jmp     near ti_fin
ti_haved:
        mov     si, seg_seq
        call    get32be
        mov     cx, ax
        mov     bx, dx
        mov     si, rcv_nxt
        call    get32be
        cmp     dx, bx
        jne     short ti_dupack
        cmp     ax, cx
        jne     short ti_dupack

        call    tcp_take_data
        mov     al, TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
        jmp     short ti_fin
ti_dupack:
        mov     al, TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
ti_fin:
        test    byte [seg_flags], TF_FIN
        je      short ti_eout
        ; They hung up.  Acknowledge the FIN, send ours, and wait for the
        ; last ACK before putting the line back on the hook.
        mov     si, rcv_nxt
        call    get32be
        add     ax, 1
        adc     dx, 0
        push    cs
        pop     es
        mov     di, rcv_nxt
        call    put32be
        mov     al, TF_FIN | TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
        call    seq_bump1
        mov     byte [tcp_state], TS_LASTACK
        mov     byte [dcd_st], 0         ; carrier lost, which is the hang-up
ti_eout:
        ret

ti_lastack:
ti_finwait:
        test    byte [seg_flags], TF_ACK
        je      short ti_fw_out
        ; Close enough: they have acknowledged something after our FIN, so
        ; the line is free.  A full TIME-WAIT would hold the port for two
        ; minutes, and a BBS with one line cannot afford to refuse the next
        ; caller for that long.
        test    byte [seg_flags], TF_FIN
        je      short ti_fw_done
        mov     si, rcv_nxt
        call    get32be
        add     ax, 1
        adc     dx, 0
        push    cs
        pop     es
        mov     di, rcv_nxt
        call    put32be
        mov     al, TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
ti_fw_done:
        jmp     near tcp_listen
ti_fw_out:
        ret

; Has their ACK covered the segment we are holding for retransmission?
ti_ackcheck:
        cmp     word [seg_len], 0
        jne     short tac_have
        cmp     byte [seg_fin], 0
        je      short tac_out
tac_have:
        mov     si, seg_ack
        call    get32be
        mov     cx, ax
        mov     bx, dx
        mov     si, snd_nxt
        call    get32be
        ; acked if seg_ack >= snd_nxt, which with one segment in flight is
        ; the only case that matters
        cmp     bx, dx
        jb      short tac_out
        ja      short tac_done
        cmp     cx, ax
        jb      short tac_out
tac_done:
        push    cs
        pop     es
        mov     di, snd_una
        mov     dx, bx
        mov     ax, cx
        call    put32be
        ; the ring bytes it carried are now safely delivered
        mov     cx, [seg_ring]
        jcxz    tac_nr
        call    tx_skipn
tac_nr:
        mov     word [seg_len], 0
        mov     word [seg_ring], 0
        mov     byte [seg_fin], 0
        mov     byte [retries], 0
tac_out:
        ret

; Forget every option position, then re-state the three the hello announces:
; we say WILL on BINARY, ECHO and SGA, and DO on BINARY and SGA.  Recording
; that here is what stops the far end's agreement being read as a new
; request.
tn_reset:
        push    bx
        push    cx
        xor     bx, bx
        mov     cx, TN_OPTS
tnr_z:
        mov     byte [bx+tn_us], 0
        mov     byte [bx+tn_them], 0
        inc     bx
        loop    tnr_z
        mov     byte [tn_us + 0], 1      ; WILL BINARY
        mov     byte [tn_us + 1], 1      ; WILL ECHO
        mov     byte [tn_us + 3], 1      ; WILL SGA
        mov     byte [tn_them + 0], 1    ; DO BINARY
        mov     byte [tn_them + 3], 1    ; DO SGA
        pop     cx
        pop     bx
        ret

; ==========================================================================
; Inbound payload: strip telnet, push the rest into the receive ring.
; ==========================================================================
tcp_take_data:
        mov     si, [cur_ptr]
        add     si, [seg_doff]
        mov     cx, [seg_dlen]
        jcxz    ttd_out
ttd_byte:
        push    cx
        lodsb
        push    si
        call    telnet_in
        pop     si
        pop     cx
        loop    ttd_byte
ttd_out:
        ; rcv_nxt advances by what ARRIVED, not by what survived the telnet
        ; stripping -- the sequence space counts wire bytes.
        mov     si, rcv_nxt
        call    get32be
        add     ax, [seg_dlen]
        adc     dx, 0
        push    cs
        pop     es
        mov     di, rcv_nxt
        call    put32be
        ret

; AL = one received byte
telnet_in:
        mov     ah, [tn_st]
        or      ah, ah
        jne     short tin_notnorm
        cmp     al, 255
        je      short tin_iac
        jmp     near rx_put
tin_iac:
        mov     byte [tn_st], 1
        ret
tin_notnorm:
        cmp     ah, 1
        jne     short tin_opt
        ; after IAC
        cmp     al, 255
        je      short tin_lit
        cmp     al, 250                  ; SB, a subnegotiation follows
        je      short tin_sb
        cmp     al, 251                  ; WILL
        jb      short tin_done
        cmp     al, 254                  ; DONT
        ja      short tin_done
        mov     [tn_cmd], al
        mov     byte [tn_st], 2
        ret
tin_lit:
        mov     byte [tn_st], 0
        jmp     near rx_put
tin_sb:
        mov     byte [tn_st], 3
        ret
tin_done:
        mov     byte [tn_st], 0
        ret
tin_opt:
        cmp     ah, 2
        je      short tin_isopt
        jmp     near tin_sub
tin_isopt:
        ; AL is the option being negotiated.  Refuse everything except
        ; suppress-go-ahead and echo, which together are what puts a telnet
        ; client into character-at-a-time mode -- and a BBS that only gets
        ; whole lines is a BBS with no menus.
        mov     byte [tn_st], 0
        mov     ah, [tn_cmd]
        cmp     ah, 253                  ; DO x
        je      short tin_do
        cmp     ah, 251                  ; WILL x
        je      short tin_towill
        ret
tin_towill:
        jmp     near tin_will
tin_do:
        ; Have we already told them what we will do about this option?  If
        ; so this is their acknowledgement, and answering it starts a loop.
        cmp     al, TN_OPTS
        jae     short tin_do_new
        push    bx
        mov     bl, al
        mov     bh, 0
        cmp     byte [bx+tn_us], 0
        pop     bx
        jne     short tin_quiet
        push    bx
        mov     bl, al
        mov     bh, 0
        mov     byte [bx+tn_us], 1
        pop     bx
tin_do_new:
        cmp     al, 0                    ; BINARY: a file transfer needs it
        je      short tin_agree_will
        cmp     al, 1                    ; ECHO
        je      short tin_agree_will
        cmp     al, 3                    ; SUPPRESS-GO-AHEAD
        je      short tin_agree_will
        mov     ah, 252                  ; WONT
        jmp     short tin_reply
tin_agree_will:
        mov     ah, 251                  ; WILL
        jmp     short tin_reply
tin_quiet:
        ret
tin_will:
        cmp     al, TN_OPTS
        jae     short tin_will_new
        push    bx
        mov     bl, al
        mov     bh, 0
        cmp     byte [bx+tn_them], 0
        pop     bx
        jne     short tin_quiet
        push    bx
        mov     bl, al
        mov     bh, 0
        mov     byte [bx+tn_them], 1
        pop     bx
tin_will_new:
        cmp     al, 0                    ; BINARY
        je      short tin_agree_do
        cmp     al, 3
        je      short tin_agree_do
        mov     ah, 254                  ; DONT
        jmp     short tin_reply
tin_agree_do:
        mov     ah, 253                  ; DO
tin_reply:
        push    bx
        mov     bl, [tn_on]
        cmp     bl, 24 - 3
        ja      short tir_full                   ; drop it; the peer retries
        mov     bh, 0
        mov     byte [bx+tn_oq], 255
        inc     bx
        mov     [bx+tn_oq], ah
        inc     bx
        mov     [bx+tn_oq], al
        inc     bx
        mov     [tn_on], bl                      ; the three INCs counted them
tir_full:
        pop     bx
        ret
tin_sub:
        ; inside a subnegotiation: swallow until IAC SE
        cmp     al, 255
        jne     short tin_sub_out
        mov     byte [tn_st], 4
tin_sub_out:
        ret

; ==========================================================================
; The timer: retransmit what is outstanding, or send what is waiting.
; ==========================================================================
tcp_tick:
        cmp     byte [tcp_state], TS_CLOSED
        je      short tt_ret
        cmp     byte [tcp_state], TS_LISTEN
        jne     short tt_live
tt_ret:
        ret
tt_live:
        ; anything outstanding?
        cmp     word [seg_len], 0
        jne     short tt_wait
        cmp     byte [seg_fin], 0
        jne     short tt_wait
        jmp     near tt_fresh
tt_wait:
        ; The retransmit timer counts TICKS, not calls.  This runs from
        ; INT 14h now, at whatever rate the application happens to poll, so
        ; a per-call countdown would expire almost immediately on a busy BBS
        ; and never on an idle one.
        mov     ax, [rto_left]
        or      ax, ax
        je      short tt_rex
        sub     ax, [svc_delta]
        jnc     short tt_rsave
        xor     ax, ax
tt_rsave:
        mov     [rto_left], ax
        or      ax, ax
        jne     short tt_ret
tt_rex:
        inc     byte [retries]
        cmp     byte [retries], MAX_RETRY
        jb      short tt_again
        ; The far end has stopped answering.  Put the line down rather than
        ; retransmitting into a hole for ever -- which for a BBS means the
        ; next caller can get in.
        jmp     near tcp_listen
tt_again:
        inc     word [tc_rex]
        call    tcp_resend
        call    rto_backoff
        ret

; Each retry waits twice as long as the last, so a genuinely unreachable
; peer is given up on slowly while a single dropped ACK costs 300 ms rather
; than a second.  A flat timer has to choose between those two and gets
; whichever it chose wrong.
rto_backoff:
        push    ax
        push    cx
        mov     ax, RTO_TICKS
        mov     cl, [retries]
        cmp     cl, RTO_MAX_SHIFT
        jbe     short rb_shift
        mov     cl, RTO_MAX_SHIFT
rb_shift:
        or      cl, cl
        je      short rb_done
rb_loop:
        shl     ax, 1
        dec     cl
        jne     short rb_loop
rb_done:
        mov     [rto_left], ax
        pop     cx
        pop     ax
        ret

tt_fresh:
        cmp     byte [tcp_state], TS_ESTAB
        je      short tt_f1
        ret
tt_f1:
        cmp     byte [tn_pend], 0
        je      short tt_f_oq
        ; The telnet hello, unescaped, as its own segment.
        ;
        ; IT IS COPIED INTO seg_buf FIRST, and that is not tidiness.
        ; tcp_resend always retransmits from seg_buf, so a segment sent from
        ; anywhere else is one that comes back as whatever seg_buf happened
        ; to hold -- stale data, or zeros on the very first call.  Anything
        ; retransmissible has to live where the retransmitter looks.
        mov     byte [tn_pend], 0
        push    cs
        pop     es
        mov     di, seg_buf
        mov     si, tn_hello
        mov     cx, TN_HELLO_N
        cld
        rep     movsb
        push    cs
        pop     ds
        mov     si, seg_buf
        mov     cx, TN_HELLO_N
        mov     al, TF_ACK | TF_PSH
        call    tcp_send_seg
        mov     word [seg_len], TN_HELLO_N
        mov     word [seg_ring], 0
        mov     word [rto_left], RTO_TICKS
        call    seq_advance
        ret

tt_fin_go:
        ; Everything the application wrote has been sent AND acknowledged,
        ; so the line can come down.
        mov     byte [fin_want], 0
        mov     al, TF_FIN | TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
        call    seq_bump1                ; a FIN takes one sequence number
        mov     byte [seg_fin], 1
        mov     word [seg_len], 0
        mov     word [seg_ring], 0
        mov     word [rto_left], RTO_TICKS
        mov     byte [retries], 0
        mov     byte [tcp_state], TS_FINWAIT
        mov     byte [dcd_st], 0
        ret

tt_f_oq:
        ; Queued negotiation replies, through the same tracked path as
        ; everything else so that they advance the sequence number.
        cmp     byte [tn_on], 0
        je      short tt_data
        push    cs
        pop     es
        mov     di, seg_buf
        mov     si, tn_oq
        mov     cl, [tn_on]
        mov     ch, 0
        cld
        rep     movsb
        mov     cl, [tn_on]
        mov     ch, 0
        mov     byte [tn_on], 0
        push    cx
        push    cs
        pop     ds
        mov     si, seg_buf
        mov     al, TF_ACK | TF_PSH
        call    tcp_send_seg
        pop     cx
        mov     [seg_len], cx
        mov     word [seg_ring], 0
        mov     word [rto_left], RTO_TICKS
        mov     byte [retries], 0
        call    seq_advance
        ret

tt_data:
        call    tx_count
        or      ax, ax
        jne     short tt_d_send
        ; nothing left to send -- so if a hang-up is pending, now is its turn
        cmp     byte [fin_want], 0
        je      short tt_d_ret
        jmp     near tt_fin_go
tt_d_send:
        call    tcp_fill
        or      cx, cx
        je      short tt_d_ret
        push    cx
        push    cs
        pop     ds
        mov     si, seg_buf
        mov     al, TF_ACK | TF_PSH
        call    tcp_send_seg
        pop     cx
        mov     [seg_len], cx
        mov     word [rto_left], RTO_TICKS
        mov     byte [retries], 0
        call    seq_advance
tt_d_ret:
        ret

; snd_nxt += seg_len
seq_advance:
        mov     si, snd_nxt
        call    get32be
        add     ax, [seg_len]
        adc     dx, 0
        push    cs
        pop     es
        mov     di, snd_nxt
        call    put32be
        ret

; Re-send the segment we are still holding, from the sequence number it had.
tcp_resend:
        cmp     byte [seg_fin], 0
        je      short tr_data
        mov     al, TF_FIN | TF_ACK
        xor     cx, cx
        xor     si, si
        push    word [snd_nxt]
        push    word [snd_nxt+2]
        mov     si, snd_una
        call    get32be
        push    cs
        pop     es
        mov     di, snd_nxt
        call    put32be
        mov     al, TF_FIN | TF_ACK
        xor     cx, cx
        xor     si, si
        call    tcp_send_seg
        pop     word [snd_nxt+2]
        pop     word [snd_nxt]
        ret
tr_data:
        mov     si, snd_una
        call    get32be
        push    cs
        pop     es
        push    word [snd_nxt]
        push    word [snd_nxt+2]
        mov     di, snd_nxt
        call    put32be
        mov     cx, [seg_len]
        push    cs
        pop     ds
        mov     si, seg_buf
        mov     al, TF_ACK | TF_PSH
        call    tcp_send_seg
        pop     word [snd_nxt+2]
        pop     word [snd_nxt]
        ret

; --------------------------------------------------------------------------
; Take up to one segment's worth out of the transmit ring, doubling any 0FFh
; on the way because that is what telnet means by a literal 255.  The ring
; bytes consumed and the wire bytes produced therefore differ, and both have
; to be remembered: one to advance the ring when the ACK comes, the other to
; advance the sequence number now.
; --------------------------------------------------------------------------
seg_buf:   times TCP_MSS + 8 db 0

tcp_fill:
        call    tx_count
        mov     bx, ax                   ; ring bytes available
        mov     si, [tx_tail]
        mov     di, seg_buf
        xor     cx, cx                   ; wire bytes
        xor     dx, dx                   ; ring bytes
tf_byte:
        or      bx, bx
        je      short tf_done
        cmp     cx, TCP_MSS - 2
        jae     short tf_done
        push    bx
        mov     bx, si
        mov     al, [bx+tx_buf]
        pop     bx
        mov     [di], al
        inc     di
        inc     cx
        cmp     al, 255
        jne     short tf_adv
        mov     byte [di], 255
        inc     di
        inc     cx
tf_adv:
        inc     si
        and     si, TX_MASK
        inc     dx
        dec     bx
        jmp     short tf_byte
tf_done:
        mov     [seg_ring], dx
        ret
