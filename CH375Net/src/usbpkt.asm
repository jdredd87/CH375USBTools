; ==========================================================================
; USBPKT.COM -- a Crynwr packet driver for an ASIX AX88179 USB Ethernet
;              adapter reached through a CH375 in host mode.
;
;   CH375Net, StevenC.  Public domain (the Unlicense).
;
;   USBPKT [@260] [/I=65] [/S] [/U] [/V] [/G] [/?]
;
;     @nnn    CH375 I/O base in hex, default 260
;     /I=nn   interrupt vector in hex, default 65.  60h is REFUSED
;     /S      status of the copy already loaded
;     /U      unload
;     /V      trace the bring-up
;     /G      leave the PHY at gigabit; the default forces 10BASE-T
;
;   Once resident, anything that speaks the packet driver interface can use
;   it -- mTCP, WATTCP, NCSA Telnet -- by being pointed at the vector.  The
;   whole reason for targeting this interface rather than inventing one is
;   that the DOS networking ecosystem already exists and none of it needs a
;   TCP stack written here.
;
; --------------------------------------------------------------------------
; NOT LOSING THE MACHINE
;
;   The box this was written on is administered over its own network, and
;   that network is a packet driver at INT 60h loaded from AUTOEXEC.BAT.
;   Installing on top of it takes the machine off the air with no way in to
;   undo it, so two refusals are built in rather than written down:
;
;     * vector 60h is rejected outright, whatever is or is not there;
;     * any vector already carrying the "PKT DRVR" signature is rejected.
;
;   Neither can be overridden by a switch.  There is no legitimate reason
;   to want either, and the cost of being wrong is a drive to the machine.
;
;   Do NOT put this in AUTOEXEC.BAT.  A resident driver that hangs during
;   boot cannot be recovered remotely at any price, whereas one loaded from
;   the prompt is undone by a power cycle -- AUTOEXEC reloads the working
;   driver and the machine comes back exactly as it was.
; --------------------------------------------------------------------------
;
; HOW RECEIVE GETS CPU TIME
;
;   The CH375 has no interrupt line wired here, so packets have to be
;   collected by polling, and a packet driver has nowhere of its own to run.
;   INT 08h is the only reliable heartbeat, so the driver hooks it.
;
;   The timer is NOT reprogrammed.  USBMOUSE and USBCOMBO multiply the PIT
;   rate because a mouse feels slow at 18 Hz; nothing here does, and leaving
;   the clock alone is one fewer interaction with the working network
;   driver, which is the thing that must not break.
;
;   The budget is adaptive, and that matters more than it sounds.  A poll
;   that comes back NAK costs about 1.2 ms and finding nothing is the normal
;   case -- so the first read of each tick is speculative and a NAK ends the
;   tick immediately.  Only when data actually arrives does the driver keep
;   draining, up to RX_BUDGET reads.  Idle costs about 2% of the machine;
;   busy costs more, and by then it is doing something useful with it.
;
; 8086 ONLY.  No near conditional jumps: where one cannot reach, the test is
; inverted over an unconditional `jmp near`.  Those are not stylistic.
; ==========================================================================

        cpu     8086
        org     0x100

SIG_OFS         equ 0x0103
VER_OFS         equ 0x010B

; Twelve, and the ceiling is arithmetic rather than taste.  A byte off the
; CH375 costs two settling reads plus the read itself -- call it 3.5us on
; this bus -- so a 64-byte packet is about 224us and the tick is 6.9ms at
; 145 Hz.  Twenty-four reads was already 5.4ms of a 6.9ms tick; thirty-one
; plus an upcall does not fit at all, and a receive loop that overruns its
; own tick leaves the foreground no time to run.  The machine does not
; crash when that happens, it simply stops getting anywhere, which looks
; exactly like a hang and took a power cycle to clear.
; Big enough for a whole burst, because half a burst is worth nothing:
; the remainder has to be thrown away to find the next boundary, so a
; budget that stops short of a typical burst discards ALL the traffic,
; not some of it.  Measured at 12: an overflow every single tick, 1159
; of them in eight seconds, and two frames delivered.
;
; 31 reads is RXBUF_SZ less one packet, and it does not fit in a 145 Hz
; tick -- which is why tick_n now defaults to 2 rather than 8.  The two
; constants are a pair: raise the budget without slowing the tick and the
; interrupt overruns its own period and the machine stops dead.
RX_BUDGET       equ 31           ; 64-byte reads per tick once data flows
; These two are deliberately tiny, and the reason is worth stating: this
; loop runs inside the timer interrupt, 145 times a second, not in a
; program's main loop.  ax179.pas can afford 2000 NAK retries and a 1024
; read drain because it is a foreground program and the worst it can do
; is take a while.  The same numbers here ate more than a tick each time
; round, so the machine stopped making forward progress the instant a
; client opened a handle -- not a crash, just no time left for anything
; else.  A mid-burst NAK on a 12 Mbps link clears in microseconds; if it
; has not cleared in four, the next tick can have another go.
RX_NAKWAIT      equ 200          ; mid-burst NAKs to wait out, in one go
; The same budget as a normal tick, and it was a mistake to make it less.
; The hunt is precisely when reading FAST matters -- there is a backlog
; and nothing useful happens until it is gone.  At four reads a tick this
; drained 9KB/s while the normal path managed 71KB/s, so a hunt that
; started never finished and the adapter never recovered.
RX_DRAINMAX     equ 64           ; reads to spend emptying a burst we cannot use
RXBUF_SZ        equ 2048         ; one burst; the chip is held to small ones
TXBUF_SZ        equ 1536         ; 8-byte header plus a full frame
MAXHANDLE       equ 4

; ---- CH375 commands ----
CMD_GET_IC_VER   equ 0x01
CMD_SET_SPEED    equ 0x04
CMD_RESET_ALL    equ 0x05
CMD_CHECK_EXIST  equ 0x06
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
INT_RET_NAK      equ 0x2A
INT_RET_STALL    equ 0x2E
INT_RET_TOGGLE   equ 0x2B         ; the device sent the other DATAx

PID_OUT          equ 0x01
PID_IN           equ 0x09
PID_SETUP_R      equ 0x0D

USB_ADDR         equ 0x02

; ---- AX88179 ----
AX_ACCESS_MAC    equ 0x01
AX_ACCESS_PHY    equ 0x02
AX_RX_CTL        equ 0x0B
AX_NODE_ID       equ 0x10
AX_MEDIUM_MODE   equ 0x22
AX_MONITOR_MODE  equ 0x24
AX_PHYPWR_RSTCTL equ 0x26
AX_RX_BULK_QCTRL equ 0x2E
AX_CLK_SELECT    equ 0x33
AX_RXCOE_CTL     equ 0x34
AX_TXCOE_CTL     equ 0x35
AX_PAUSE_HIGH    equ 0x54
AX_PAUSE_LOW     equ 0x55
AX_PHY_ID        equ 0x03

; ---- RX_CTL bits, the same set ax179.pas carries for the Pascal side ----
RX_CTL_PROMISC   equ 0x0001
RX_CTL_ALLMULTI  equ 0x0002
RX_CTL_BROADCAST equ 0x0008
RX_CTL_MULTICAST equ 0x0010
RX_CTL_ACCEPT_PHY equ 0x0020
RX_CTL_START     equ 0x0080
RX_CTL_DROP_CRC  equ 0x0100

; ---- MEDIUM_MODE bits ----
MED_GIGA         equ 0x0001
MED_FULL_DUPLEX  equ 0x0002
MED_ALWAYS_ONE   equ 0x0004
MED_EN_125MHZ    equ 0x0008
MED_RXFLOW_EN    equ 0x0010
MED_TXFLOW_EN    equ 0x0020
MED_RECEIVE_EN   equ 0x0100

; ---- the standard MII registers, for the autonegotiation step ----
MII_BMCR         equ 0
MII_BMSR         equ 1
MII_ANAR         equ 4
MII_GBCR         equ 9
BMCR_ANRESTART   equ 0x0200
BMCR_ANENABLE    equ 0x1000
BMSR_LINK        equ 0x0004

EP_BULK_IN       equ 2
EP_BULK_OUT      equ 3

; ---- packet driver error codes ----
E_BAD_HANDLE     equ 1
E_NO_CLASS       equ 2
E_NO_TYPE        equ 3
E_NO_NUMBER      equ 4
E_BAD_TYPE       equ 5
E_NO_MULTICAST   equ 6
E_CANT_TERMINATE equ 7
E_BAD_MODE       equ 8
E_NO_SPACE       equ 9
E_TYPE_INUSE     equ 10
E_BAD_COMMAND    equ 11
E_CANT_SEND      equ 12
E_CANT_SET       equ 13
E_BAD_IOCTL      equ 14

start:
        jmp     near init

; --------------------------------------------------------------------------
; The published block.  Same convention as the other drivers here: an
; eight-byte signature at 0103 and an ASCII version at 010B, so a second
; copy can find the first and say what it is without guessing.
; --------------------------------------------------------------------------
        db      'USBPKT01'                      ; 0103
ver_str:
        db      '1.0.0$'                        ; 010B

; ---- hardware ----
io_dat:     dw  0x260
io_cmd:     dw  0x261
our_vec:    db  0x65
old_vec:    dd  0
old08:      dd  0
mac:        times 6 db 0
rx_tog:     db  0x80
tx_tog:     db  0x80
; How many bytes the current OUT packet carries.  It cannot be kept in AX
; across the call: bulk_out uses AX for command bytes, so `sub cx, ax`
; afterwards was subtracting a leftover CH375 opcode from the bytes
; remaining.
tx_chunk:   dw  0

; The first 16 bytes of the last frame handed to send_pkt, kept so /S can
; show them.  The chip accepting a transfer says nothing about whether what
; went out was a valid frame -- 11 ARP requests left this driver, were
; counted, and no machine on the segment learned our address from any of
; them.  The only way to tell a send that failed from a send that carried
; rubbish is to look at the bytes.
tx_peek:    times 16 db 0

; And the same for a burst the parser threw away.  A counter says how often
; something went wrong; it never says what.  These sixteen bytes plus the
; length are the difference between "546 bursts made no sense" and knowing
; which field of the AX88179 trailer disagreed with the data.
rx_peek:    times 64 db 0     ; a whole bulk packet, not a glimpse of one
rx_peeklen: dw  0

cfg_val:    db  1

; --------------------------------------------------------------------------
; WHICH PROTOCOL THIS ADAPTER SPEAKS.
;
; Two data paths share every line of the chip access below, because at the
; USB level they are the same transfers: 64-byte bulk reads accumulated
; until a short packet ends them, and 64-byte bulk writes with a
; zero-length packet when the total lands on a multiple of 64.
;
; What differs is only what those bytes MEAN.  The AX88179 packs several
; frames into one burst behind an 8-byte header, with an entry array and a
; trailer to unpick.  CDC-ECM carries ONE RAW FRAME and nothing else -- no
; header, no trailer, no entry array, no tiling, no padding.  So the ECM
; path is the vendor path with the parser removed, which is why adding it
; costs so little: rx_have skips rx_deliver, and psend skips the header.
;
; A THIRD layout now: the SR9700/DM9601 puts THREE bytes in front of each
; frame -- a status byte and a 16-bit length -- and sends ONE frame per USB
; transfer, exactly as ECM does.  So it is the ECM path with a header to
; step over and a CRC to trim, and not the ASIX path at all.  That is worth
; saying plainly because the layout READS like the ASIX one from a
; distance, and building a tiling parser for it would be a week spent
; solving a problem the device does not have.
;
; link_mode is set by the bring-up in usbpktini.inc.  ECM is chosen from
; what the device's own descriptors say; the SR9700 has no class descriptor
; to give it away, so that one -- alone here -- is chosen by USB ID.
;
; It is a VALUE and not a flag, and every test on it names the mode it
; wants.  The two-way version tested `<> 0` and meant "ECM", which is the
; sort of thing that keeps working right up until somebody adds a third.
LM_AX       equ 0            ; AX88179 vendor layout: burst, entries, trailer
LM_ECM      equ 1            ; CDC-ECM: one raw frame, no header at all
LM_SR       equ 2            ; SR9700/DM9601: one frame behind 3 header bytes

; The SR9700's framing, in one place because the receive parser and the
; bring-up both need it and a number written twice is a number that will
; disagree with itself.  RX: status, length low, length high -- and the
; length COUNTS the four-byte Ethernet CRC.  TX: length low, high, and
; that length counts only the frame.
SR_RX_OVERHEAD equ 3
SR_TX_OVERHEAD equ 2
link_mode:   db  LM_AX

; The endpoint TOKENS, held as data rather than assembled into the
; instruction.  They used to be immediates -- (EP_BULK_IN << 4) | PID_IN --
; which was correct for exactly one chip family.  An ECM adapter states its
; endpoint numbers in its descriptors and is entitled to any of them; this
; one happens to use the same 2 and 3, and relying on that would have been
; a coincidence dressed up as a design.  The cost is a memory read instead
; of an immediate, inside an operation that then waits microseconds for a
; USB transaction.
tok_in:     db  (EP_BULK_IN << 4) | PID_IN
tok_out:    db  (EP_BULK_OUT << 4) | PID_OUT
ep_in_n:    db  EP_BULK_IN                ; bare number, for CLEAR_FEATURE
ep_out_n:   db  EP_BULK_OUT

; The interrupt endpoint, where an ECM device reports its link.  This is
; not decoration: a down link and a broken receive path produce exactly the
; same symptom -- an endpoint that NAKs for ever -- and nothing else here
; can tell them apart.  ECMLINK has the same read for the same reason.
;
; Notifications are sent on CHANGE, so link_st stays FF until the device
; says something, and FF means "it has not told us", never "down".
ep_int_n:   db  0                    ; 0 = no interrupt endpoint
tok_int:    db  0
int_tog:    db  0x80
int_ctr:    db  1
link_st:    db  0xFF                 ; FF unknown, 0 down, 1 up
n_notify:   dw  0

; Bytes of vendor header in front of a transmitted frame: 8 for the
; AX88179, 0 for ECM, 2 for the SR9700.  A length rather than a flag because three separate
; places need the number, and a flag tested three times is how the two
; halves of a decision drift apart.
tx_hdrlen:  dw  8

; Bytes from one SR9700 record to the next, held across the call into the
; application's receiver, which is free to clobber every register.
sr_stride:  dw  0

; Does this CPU have the 80186 string I/O instructions?  REP INSB and REP
; OUTSB move a byte between a port and memory in ONE instruction, where the
; portable loops below need three or more -- and on an 8086 they are invalid
; opcodes that do something undefined rather than faulting, so this cannot be
; guessed.  Probed at install time by cpu_probe; /8 forces it to 0.
;
; The development machine is a NEC V30, which has the 186 instruction set,
; and this is the arrangement dosbridge's cpu.pas already established: probe
; at run time, keep the portable loop, emit the fast one as db bytes because
; the assembler targets 8086 and is right to refuse it as source.  NEVER
; delete the portable path -- it is the one that runs everywhere.
has186:     db  0

; The longest single poll, in PIT counts of 0.838 us.  This is the whole
; justification for the REP INSB path above, so it is measured rather than
; asserted: the driver is round-trip-bound at the default poll rate, which
; means a faster read buys almost nothing in throughput and everything it
; buys is here -- the share of the machine one interrupt takes while
; traffic is flowing.  A burst read that costs 10 ms of a 55 ms tick is a
; fifth of the machine, and that is what wedged MS-DOS EDIT at /R=8.
isr_t0:     dw  0
isr_max:    dw  0

; ---- state ----
; The PIT divisor.  1 leaves the timer alone at 18.2 Hz; 8 gives 145 Hz.
;
; Latency here is the poll interval and nothing else, and there is a clean
; measurement of it: the same gateway, one hop away, answers in 4.25 ms
; through the machine's interrupt-driven NE2000 and about 50 ms through
; this driver at 18.2 Hz.  The wire is not the difference; waiting up to
; 55 ms for the next tick is.
;
; USBMOUSE and USBCOMBO already do this and the arrangement is theirs: the
; PIT runs fast, and the handler that was in the vector before us is called
; only every nth tick, so the BIOS clock and everything hooked in ahead of
; us still see 18.2 Hz.
; 1 -- LEAVE THE PIT ALONE.  This is a compatibility default, and it was
; not always the default; the story is worth keeping.
;
; Speeding the timer up is worth a great deal to this driver.  Measured
; with PKTTEST /N=200, which times the round trip itself:
;
;     /R=1  ~55ms   /R=4  13ms   /R=8  6ms   /R=16  6ms   NE2000 1ms
;
; and 1 MB over HTTP goes from 71s at /R=1 to 36s at /R=8.  So 8 was
; made the default.  That was wrong, and MS-DOS EDIT is what proved it:
; with the timer at 145 Hz, EDIT wedged the machine hard enough to need
; the power switch.
;
; The reason is the interrupt chain.  We hook INT 08h and reprogram the
; PIT, then chain to whoever was there 1 tick in 8, so the BIOS clock
; and INT 1Ch stay honest -- TICKCHK confirms 145 Hz on 08h and 18 Hz
; on 1Ch.  But a program that hooks INT 08h AFTER us sits in FRONT of
; us and sees all 145 interrupts, and a program that reprograms the PIT
; for itself leaves our 1-in-8 chaining dividing the wrong thing --
; which starves the BIOS clock by a factor of eight and looks exactly
; like a hang.  Neither is something a packet driver gets to do to the
; rest of the machine by default.
;
; So the default touches nothing, and /R is there for when you know
; what else is running.  /R=8 while shifting a large file is a fine
; idea; /R=8 in AUTOEXEC.BAT on a machine somebody uses is not.
tick_n:     db  1
tick_ctr:   db  0
pit_fast_on: db 0                ; did we actually change the timer

chip_busy:  db  0                ; the foreground is mid-transaction with
                                 ; the CH375 -- the timer must keep off it
in_isr:     db  0                ; re-entry guard: the ISR can take
                                 ; milliseconds and the next tick will
                                 ; arrive on top of it
rcv_mode:   dw  3                ; 3 = our address + broadcast

; RESIDENT, and it has to be: /U reads this out of the loaded copy to decide
; whether to put INT 08h back.  It started life in the transient half, where
; the offset /U reads lands in memory DOS has already taken back -- so the
; answer was whatever happened to be lying there.  In the /N case that
; garbage was non-zero and skipped a restore that was correctly skippable,
; which is the worst kind of wrong: right by accident.
op_nopoll:  db  0
n_handles:  db  0

; ---- one row per handle: in use, packet type length, the type bytes, and
;      the application's receiver ----
h_used:     times MAXHANDLE db 0
h_typelen:  times MAXHANDLE db 0
h_type:     times MAXHANDLE*8 db 0
h_rcv:      times MAXHANDLE dd 0

; ---- statistics ----
; SEVEN consecutive 32-bit counters in exactly this order, because
; get_statistics hands the caller a pointer to the block and the caller
; reads it as a struct.  Getting the order or the count wrong is not a
; cosmetic fault: mTCP's pkttool reported "Errors out: 65557" off a driver
; that had sent nothing, because the previous layout had five counters in
; a different order and pkttool read two variables past the end of it.
st_pkts_in:   dd  0
st_pkts_out:  dd  0
st_bytes_in:  dd  0
st_bytes_out: dd  0
st_err_in:    dd  0
st_err_out:   dd  0
st_lost:      dd  0

; ---- counters of our own, for /S ----
n_ticks:    dw  0
n_bursts:   dw  0
n_frames:   dw  0
n_short:    dw  0
n_nohandle: dw  0
n_junk:     dw  0            ; reads the chip claimed were impossibly long
n_over:     dw  0            ; bursts bigger than the buffer, drained
rx_naks:    dw  0
bi_flip:    db  0            ; already retried this read with the other PID
n_toggle:   dw  0            ; reads recovered by flipping the toggle
rx_pos:     dw  0            ; bytes of a part-read burst carried between
                             ; ticks -- see rx_go
n_empty:    dw  0            ; SR9700 records with no frame in them
junk_len:   dw  0            ; the last impossible length, and its context
junk_at:    dw  0
junk_burst: dw  0
n_resync:   dw  0            ; bursts recovered by finding the boundary
sr_carry:   dw  0            ; bytes of a record still owed from the
                             ; last burst -- the phase across transfers
junk_prev:  db  0            ; the previous burst's outcome, latched
junk_prevleft: dw 0
sr_end_why: db  0            ; how this burst's parse ended
sr_prev_why: db 0            ; ...and how the one before it ended
sr_end_left: dw 0
sr_prev_left: dw 0
n_flush:    dw  0            ; times we have had to go hunting

; Did the frames in a burst actually TILE it?  The layout puts the frames
; first and the entry array straight after the last one, so walking every
; frame must land exactly on the entry array's offset.  Landing anywhere
; else means the walk mis-strided, and every frame after the point where it
; went wrong was handed up from the wrong place.
;
; This exists because two register-preservation bugs were found by reading,
; fixed, and did NOT stop the corruption -- at which point guessing has to
; stop and the parser has to be asked directly whether it is the one doing
; it.  If this counter stays at zero while a download still comes back
; wrong, the burst parser is exonerated and the fault is above the driver.
rx_flimit:  dw  0            ; where the frames must end
n_tile:     dw  0            ; bursts whose frames did not tile it
tile_di:    dw  0            ; ...and where the last such walk ended
tile_lim:   dw  0            ; ...against where it should have

; Frames whose end runs past the frame region.  COUNTED ONLY -- the
; behaviour is deliberately unchanged, because a check that rejects a
; legitimate frame breaks networking and my model of this layout has not
; earned that much trust yet.  Measure first: if this stays at zero across
; healthy traffic then the bound is safe to enforce, and if it fires then
; it is evidence rather than a regression.
n_outside:  dw  0
rx_st:      db  0            ; status the last bulk IN reported
rx_len:     db  0            ; length the last RD_USB_DATA claimed
; Somewhere to throw a drained packet.  256 rather than 64 because the fast
; drain in ch_read_over is a single REP INSB and has to have room for the
; largest length the chip can report -- the length is one byte, so 255 is the
; worst case and 256 cannot be overrun.  The flush sampler still copies only
; the first 64 into rx_peek.
rx_scratch: times 256 db 0

; Scratch the receive path keeps across the upcall.  It has to live in CS
; memory rather than in registers or on the stack: the receiver is the
; application's code, called from inside a timer interrupt, and nothing may
; be assumed about any register once it has run.
rx_frofs:   dw  0
rx_frlen:   dw  0
rx_handle:  dw  0
rcv_tmp:    dd  0

drv_name:   db  'AX88179/CH375', 0
drv_ecm:    db  'CDC-ECM/CH375', 0
drv_sr:     db  'SR9700/CH375', 0

; driver_info hands back a name, and PKTDRV and NETID both print it. It is
; the only place a user finds out WHICH of the two paths came up, so it has
; to follow the bring-up rather than the binary.
drv_nptr:   dw  drv_name

rxbuf:      times RXBUF_SZ db 0
txbuf:      times TXBUF_SZ db 0

; ==========================================================================
; CH375 PORT LAYER.  Lifted from USBCOMBO, which has had the most hardware
; time of anything here.  The two reads of port 61h are the ISA settling
; delay -- port 61h is harmless to read and two of them are comfortably
; longer than the chip needs between a command and its data byte.
; ==========================================================================
ch_cmd:                                  ; AL = command
        push    dx
        push    ax
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     ax
        mov     dx, [cs:io_cmd]
        out     dx, al
        mov     dx, 0x61
        in      al, dx
        in      al, dx
        pop     dx
        ret

ch_wr:                                   ; AL = data
        push    dx
        mov     dx, [cs:io_dat]
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
        mov     dx, [cs:io_dat]
        in      al, dx
        pop     dx
        ret

; Wait for the chip's interrupt then read the status.  CX = spin limit.
; CF set on timeout, else AL = status.
ch_wait:
        push    dx
        mov     dx, [cs:io_cmd]
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

; Read the chip buffer into ES:DI, at most CL bytes.  AH = length the chip
; reported, AL = bytes stored.  Everything is read out of the chip even
; when the caller cannot take it: bytes left behind desynchronise the next
; read, which is a fault that shows up much later and looks like nothing.
; CL = how many bytes the caller has room for.  Returns AL = bytes
; stored, and CF set if the chip reported MORE than CL -- which for a
; bulk read means the length cannot be believed.
;
; The check earns its place.  When the CH375 stops driving the ISA data
; bus every read returns FF, so the length byte reads as 255: this
; drained 255 bytes, stored the first 64, and told the caller it had a
; full 64-byte packet.  rx_poll then kept asking for more until its
; 24-read budget ran out, and handed up 1536 bytes of FF as a burst.
; 4657 bursts out of 4659 in one run, all of them manufactured here.
ch_read:
        push    bx
        push    cx
        push    dx
        mov     al, CMD_RD_USB_DATA
        call    ch_cmd
        call    ch_rd                    ; the length, with its full delay
        mov     [cs:rx_len], al
        mov     bl, al
        xor     bh, bh
        cmp     bl, cl
        ja      short ch_read_over
        or      bl, bl
        je      short ch_read_done

        ; The payload, inline and without the port 61h settling pair.
        ;
        ; ch_rd keeps that pair and so does every other caller; it is only
        ; dropped HERE, in the one loop that runs 64 times per packet and
        ; thousands of times a second.  The call version cost about 150
        ; clocks a byte -- call, push, two settling reads, the read, pop,
        ; ret, and the caller's own bookkeeping -- which works out at 19us
        ; a byte and caps the whole driver near 50 KB/s however fast the
        ; wire is.
        ;
        ; Dropping the delay is safe because of how slow this loop is
        ; anyway.  IN is 14 clocks with the bus wait states, STOSB 11,
        ; LOOP 17: about 5us between consecutive reads at 8 MHz with no
        ; help at all, already far longer than the chip needs.  On a
        ; faster machine this wants the delay back.
        ;
        ; And on a machine that has REP INSB the whole loop collapses to
        ; one instruction: ES:DI, DX and CX are already exactly what it
        ; wants.  The point is NOT throughput -- at the default poll rate
        ; this driver is round-trip-bound, and inlining the loop above
        ; moved 1 MB by 2 seconds in 73.  The point is that a burst read
        ; is ~10 ms of a 55 ms tick, a fifth of the machine while traffic
        ; flows, and that is what wedged EDIT at /R=8.  A quieter driver
        ; is the goal, not a bigger number.
        ;
        ; DF is not saved here because it cannot be wrong: the timer ISR
        ; does CLD on entry and so does pkt_go, which are the only two
        ; ways into this code, and the STOSB below has always depended on
        ; that.
        mov     dx, [cs:io_dat]
        mov     cl, bl
        xor     ch, ch
        mov     bh, bl                   ; all of it lands in the buffer
        cmp     byte [cs:has186], 0
        je      short ch_read_slow
        db      0xF3, 0x6C               ; REP INSB
        jmp     short ch_read_done
ch_read_slow:
        in      al, dx
        stosb
        loop    ch_read_slow

ch_read_done:
        mov     al, bh
        pop     dx
        pop     cx
        pop     bx
        clc
        ret

; Drain what it claimed anyway -- bytes left behind desynchronise every
; later read -- but store none of them and say so.
ch_read_over:
        mov     dx, [cs:io_dat]
        mov     cl, bl
        xor     ch, ch
        cmp     byte [cs:has186], 0
        je      short ch_read_ovl
        ; REP INSB has to put the bytes SOMEWHERE, and it cannot be the
        ; caller's buffer -- being too small for them is how we got here.
        ; rx_scratch is 256 bytes and the count came out of a byte, so
        ; this cannot overrun whatever the chip claims.
        push    es
        push    di
        push    cs
        pop     es
        mov     di, rx_scratch
        db      0xF3, 0x6C               ; REP INSB
        pop     di
        pop     es
        jmp     short ch_read_ovdone
ch_read_ovl:
        in      al, dx
        loop    ch_read_ovl
ch_read_ovdone:
        xor     al, al
        pop     dx
        pop     cx
        pop     bx
        stc
        ret

; --------------------------------------------------------------------------
; One IN token on the bulk endpoint.  ES:DI = where, CL = room.
; Returns AL = bytes stored, AH = chip status, CF set if the status was
; anything but success.
; --------------------------------------------------------------------------
bulk_in:
        mov     byte [cs:bi_flip], 0
bulk_in_go:
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, [cs:rx_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, [cs:tok_in]
        call    ch_wr
        push    cx
        mov     cx, 0x3000
        call    ch_wait
        pop     cx
        jc      short bulk_in_bad
        mov     [cs:rx_st], al           ; whatever it was, on the record
        cmp     al, INT_SUCCESS
        jne     short bulk_in_status
        mov     ah, al
        call    ch_read                  ; AL = stored, CF = not believable
        jc      short bulk_in_junk
        push    ax
        xor     byte [cs:rx_tog], 0x40
        pop     ax
        clc
        ret

; The toggle is deliberately NOT advanced here.  Advancing it on a read
; that was never a packet is what turned a single bad read into a dead
; adapter: from then on every IN asked for the wrong DATAx, so nothing
; ever matched again and the garbage was permanent.  Leaving it alone
; means the next real packet still lines up.
bulk_in_junk:
        inc     word [cs:n_junk]
        mov     ah, 0                    ; not a NAK -- do not retry it
        stc
        ret
bulk_in_status:
        ; A toggle mismatch is not a lost packet.  The device sent the
        ; other DATAx, meaning our idea of the toggle has drifted from
        ; its own -- the data is still sitting there, we simply asked
        ; with the wrong PID.  Flip and ask again; the packet arrives.
        ;
        ; Worth saying how this stayed hidden.  CLR_STALL was being given
        ; 82h, the USB endpoint address, where the CH375 wants the bare
        ; endpoint number 2 -- so the resynchronise did nothing, the chip
        ; never reported the mismatch, and every read came back as a
        ; successful 64 bytes of FF instead.  Fixing the endpoint number
        ; turned a silent wedge into this, which says exactly what is
        ; wrong.  Once only: if flipping does not help, it is not this.
        cmp     al, INT_RET_TOGGLE
        jne     short bulk_in_st2
        cmp     byte [cs:bi_flip], 0
        jne     short bulk_in_st2
        mov     byte [cs:bi_flip], 1
        inc     word [cs:n_toggle]
        xor     byte [cs:rx_tog], 0x40
        jmp     short bulk_in_go
bulk_in_st2:
        mov     ah, al
        xor     al, al
        stc
        ret
bulk_in_bad:
        mov     byte [cs:rx_st], 0xFF    ; no interrupt at all
        mov     ah, 0
        xor     al, al
        stc
        ret

; --------------------------------------------------------------------------
; One OUT token.  DS:SI = data, CL = length (0..64).
; CF set unless the chip reported success.
; --------------------------------------------------------------------------
; A NAK on an OUT means "busy, ask again", exactly as it does on an IN, and
; the chip is deliberately set to report NAKs rather than retry them itself
; -- see read_mac for why.  So the patience has to live here.  Without it
; every single send failed: 25 errors out, 0 packets out, and mTCP timing
; out waiting for an ARP reply to a request that never left the machine.
;
; A retry has to rewind SI, because LODSB has already walked it through the
; data on the attempt that got NAKed.
bulk_out:
        push    cx
        push    bp
        push    si
        mov     bp, 256
bo_retry:
        pop     si
        push    si
        push    cx
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, cl
        call    ch_wr
        or      cl, cl
        je      short bulk_out_sent
        cmp     byte [cs:has186], 0
        je      short bulk_out_loop
        ; The biggest of the three per-byte loops by a long way.  The read
        ; loop above was inlined; this one never was, so every byte still
        ; pays a call, a push/pop, two settling reads of port 61h and the
        ; caller's own bookkeeping -- about 160 clocks against REP OUTSB's
        ; ten or so.
        ;
        ; CX is free: bo_retry pushed it and the pop after ch_wait puts it
        ; back, so clearing CH here costs nothing.  DS:SI is txbuf in CS,
        ; set up by psend, and REP OUTSB advances SI by exactly what the
        ; LODSB loop would -- which is what bo_retry's rewind depends on.
        push    dx
        xor     ch, ch
        mov     dx, [cs:io_dat]
        db      0xF3, 0x6E               ; REP OUTSB
        pop     dx
        jmp     short bulk_out_sent
bulk_out_loop:
        lodsb
        call    ch_wr
        dec     cl
        jne     short bulk_out_loop
bulk_out_sent:
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, [cs:tx_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, [cs:tok_out]
        call    ch_wr
        mov     cx, 0x3000
        call    ch_wait
        pop     cx                       ; the caller's length
        jc      short bo_bad
        cmp     al, INT_SUCCESS
        je      short bo_good
        cmp     al, INT_RET_NAK
        jne     short bo_bad
        dec     bp
        jnz     short bo_retry           ; busy; rewind and ask again
bo_bad:
        pop     si
        pop     bp
        pop     cx
        stc
        ret
bo_good:
        xor     byte [cs:tx_tog], 0x40
        ; DISCARD the saved SI rather than restoring it.  LODSB has walked
        ; SI through the bytes just sent, and a caller splitting a frame
        ; across several 64-byte packets needs that advance to survive --
        ; restoring it makes every packet after the first re-send the
        ; beginning of the frame.
        ;
        ; This was invisible on ARP and fatal on everything else. A 60-byte
        ; ARP request is 68 bytes with the header: 64 plus 4, and the four
        ; repeated bytes land in the padding nobody reads, so ARP resolved
        ; perfectly. A 74-byte ping is 82: 64 plus 18, and those eighteen
        ; repeated bytes are real header, so the router dropped every one
        ; in silence.
        add     sp, 2
        pop     bp
        pop     cx
        clc
        ret

; ==========================================================================
; The timer rate.  Both of these are resident because unload has to put the
; PIT back, and unload runs long after the transient half is gone.
; ==========================================================================
pit_fast:
        push    ax
        push    bx
        push    dx
        mov     al, 0x36
        out     0x43, al
        mov     bl, [cs:tick_n]
        xor     bh, bh
        xor     dx, dx
        mov     ax, 0
        dec     ax                       ; 65535: close enough, and it
        div     bx                       ; cannot divide by zero
        out     0x40, al
        mov     al, ah
        out     0x40, al
        mov     byte [cs:pit_fast_on], 1
        pop     dx
        pop     bx
        pop     ax
        ret

; PIT channel 0's live count, which runs DOWN at 1.193 MHz.  Latching it
; first (command 00h) freezes the value in a holding register, so the two
; byte reads cannot be torn apart by the counter advancing between them --
; which is the whole reason the latch command exists and the reason this is
; safe to do from inside an interrupt.  Read-only: nothing here disturbs
; the count, the mode, or anybody else's timing.
pit_read:
        push    dx
        mov     al, 0
        out     0x43, al                 ; latch counter 0
        mov     dx, 0x40
        in      al, dx
        mov     ah, al                   ; low byte comes out first...
        in      al, dx
        xchg    al, ah                   ; ...then high.  AX = the count
        pop     dx
        ret

pit_slow:
        push    ax
        mov     al, 0x36
        out     0x43, al
        xor     al, al
        out     0x40, al                 ; divisor 0 = 65536 = 18.2 Hz
        out     0x40, al
        mov     byte [cs:pit_fast_on], 0
        pop     ax
        ret

; ==========================================================================
; A control transfer that survives going resident.
;
; set_rcv_mode has to reprogram the adapter's RX_CTL register, and that is
; a vendor control transfer.  The transient half has a full one, but it is
; gone by the time an application calls us, so this minimal version -- one
; register, one 16-bit value -- lives in the resident image.
;
; It is only ever reached from the INT 65h handler, never from the ISR: it
; takes milliseconds, and a millisecond inside a timer interrupt is not a
; cost worth paying for a call that happens once per program.
; ==========================================================================
setup_buf:  times 8 db 0
val_buf:    dw 0

; AL = endpoint address, direction bit included.  The resident twin of
; clr_ep in the transient half.
res_clr_ep:
        push    ax
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        pop     ax
        call    ch_wr
        mov     cx, 0x4000
        call    ch_wait
        ret

res_clr_ep0:
        mov     al, CMD_CLR_STALL
        call    ch_cmd
        xor     al, al
        call    ch_wr
        mov     cx, 0x4000
        call    ch_wait
        ret

; AL = MAC register, BX = value.  CF set if any stage failed.
res_mac_wr16:
        push    si
        mov     [cs:setup_buf+0], byte 0x40      ; OUT, vendor, device
        mov     [cs:setup_buf+1], byte AX_ACCESS_MAC
        mov     [cs:setup_buf+2], al             ; wValue  = the register
        mov     [cs:setup_buf+3], byte 0
        mov     [cs:setup_buf+4], byte 2         ; wIndex  = its length
        mov     [cs:setup_buf+5], byte 0
        mov     [cs:setup_buf+6], byte 2         ; wLength
        mov     [cs:setup_buf+7], byte 0
        mov     [cs:val_buf], bx

        call    res_clr_ep0

        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 8
        call    ch_wr
        mov     si, setup_buf
        mov     cx, 8
rmw_setup:
        mov     al, [cs:si]
        call    ch_wr
        inc     si
        loop    rmw_setup

        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, 0x80                 ; SETUP is always DATA0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, PID_SETUP_R
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short rmw_bad
        cmp     al, INT_SUCCESS
        jne     short rmw_bad

        ; data stage: two bytes OUT, and it starts on DATA1
        mov     al, CMD_WR_USB_DATA7
        call    ch_cmd
        mov     al, 2
        call    ch_wr
        mov     al, [cs:val_buf]
        call    ch_wr
        mov     al, [cs:val_buf+1]
        call    ch_wr
        mov     al, CMD_SET_ENDP7
        call    ch_cmd
        mov     al, 0xC0
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, (0 << 4) | PID_OUT
        call    ch_wr
        mov     cx, 0xFFFF
        call    ch_wait
        jc      short rmw_bad
        cmp     al, INT_SUCCESS
        jne     short rmw_bad

        ; status stage: an IN carrying DATA1
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
        pop     si
        clc
        ret
rmw_bad:
        call    res_clr_ep0
        pop     si
        stc
        ret

; ==========================================================================
; THE INT 08h HOOK -- where receive actually happens.
; ==========================================================================
isr08:
        push    ax

        ; A heartbeat used to live here, poking the top-left character cell
        ; of both video buffers so a machine that had stopped answering the
        ; bridge could still be seen to be running.  It did its job -- and
        ; it is gone, because a resident driver that scribbles on somebody
        ; else's screen forever is not a diagnostic, it is a defect.  If it
        ; is ever needed again it belongs behind a switch that is off.

        ; Re-entry guard.  A tick that finds data can spend milliseconds
        ; draining it, and the next one will arrive on top.  Without this
        ; the second entry would use the same buffer and the same toggle as
        ; the first and both would be wrong.
        cmp     byte [cs:in_isr], 0
        jne     short isr_tick           ; busy: skip the poll, still count
        mov     byte [cs:in_isr], 1
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
        cld                              ; the direction flag belongs to
                                         ; whoever we interrupted, and five
                                         ; string operations below assume
                                         ; forward
        inc     word [n_ticks]

        ; Time it, but ONLY while the PIT is at its power-on divisor of
        ; 65536.  There the counter wraps at exactly the place 16-bit
        ; arithmetic does, so BEFORE minus AFTER is exact for anything up
        ; to one full period -- 54.9 ms, which is five times the longest
        ; poll ever measured.  Past that it aliases and would read SMALL,
        ; which is the wrong direction to be wrong in; nothing here can
        ; detect it, so treat a suspiciously low peak alongside skipped
        ; ticks with suspicion.  Once /R has reloaded the counter with
        ; something smaller, the wrap and the arithmetic no longer agree
        ; at all and the reading is simply not taken.
        ;
        ; Skipping it there costs nothing worth having: the poll does the
        ; same work per burst whatever the tick rate, so the figure taken
        ; at /R=1 is the figure at /R=8 as well.  What changes with /R is
        ; how often it is paid, and that is arithmetic.
        cmp     byte [pit_fast_on], 0
        jne     short isr_notimed
        call    pit_read
        mov     [isr_t0], ax
        call    rx_poll
        call    pit_read
        mov     bx, [isr_t0]
        sub     bx, ax                   ; it counts DOWN, so before-after
        cmp     bx, [isr_max]
        jbe     short isr_timed
        mov     [isr_max], bx
isr_timed:
        jmp     short isr_polled
isr_notimed:
        call    rx_poll
isr_polled:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        mov     byte [cs:in_isr], 0

        ; Only every nth interrupt goes downstream, so whoever was in the
        ; vector before us still sees 18.2 Hz however fast the PIT is now
        ; running.  On the ticks we keep, the interrupt has to be
        ; acknowledged here, because the handler that would have done it is
        ; not being called.
isr_tick:
        mov     al, [cs:tick_ctr]
        inc     al
        cmp     al, [cs:tick_n]
        jb      short isr_ours
        xor     al, al
        mov     [cs:tick_ctr], al
        pop     ax
        jmp     far [cs:old08]
isr_ours:
        mov     [cs:tick_ctr], al
        mov     al, 0x20
        out     0x20, al
        pop     ax
        iret

; --------------------------------------------------------------------------
; Read the rest of a transfer that is not going to be used, so the chip is
; left on a packet boundary.  Bounded, and it has to be: the adapter can
; stream without a short packet for a long time, and an unbounded loop in
; here is an unbounded loop inside a timer interrupt.
; --------------------------------------------------------------------------
; CLEAR_FEATURE(ENDPOINT_HALT) on the bulk IN, which resets the data
; toggle at BOTH ends and is the only thing that restarts an endpoint the
; device has given up on.  Without it the hunt below never finds a
; boundary: the chip keeps reporting a successful full 64-byte packet
; whose contents are entirely FF, for as long as you care to ask, and no
; amount of reading gets past it.
;
; It is a real control transfer and it costs milliseconds inside a timer
; interrupt, so it happens once when the hunt starts and not once per
; tick of it.
rx_unwedge:
        push    ax
        push    cx
        ; The bare endpoint NUMBER, not the USB address with the direction
        ; bit on it.  ch375.pas calls ClrStall(AX_EP_BULK_IN) and that
        ; constant is 2, not 82h.  Passing 82h here asked the chip to clear
        ; an endpoint that does not exist, which is why the unwedge below
        ; never unwedged anything.
        mov     al, [cs:ep_in_n]
        call    res_clr_ep
        mov     byte [cs:rx_tog], 0x80
        pop     cx
        pop     ax
        ret

; CF clear = a boundary was reached, CF set = still mid-stream, come back
; next tick.
rx_drain:
        push    di
        push    dx
        push    bp
        push    cs
        pop     es
        mov     dx, RX_DRAINMAX
rx_dr_loop:
        mov     di, rx_scratch
        mov     cl, 64
        call    bulk_in
        jc      short rx_dr_edge         ; NAK or error: nothing left
        ; Keep a copy of what the hunt is wading through.  Whether this
        ; is real traffic we are simply too slow for, or the same bytes
        ; over and over, is the difference between a throughput problem
        ; and a lost-sync one, and they need opposite fixes.
        push    ax
        push    cx
        push    si
        push    di
        push    ds
        push    cs
        pop     ds
        mov     si, rx_scratch
        mov     di, rx_peek
        mov     cx, 64
        cld
        rep     movsb
        mov     word [cs:rx_peeklen], 0xFFFF   ; marker: a flush sample
        pop     ds
        pop     di
        pop     si
        pop     cx
        pop     ax
        cmp     al, 64
        jb      short rx_dr_edge         ; short packet: boundary reached
        dec     dx
        jnz     short rx_dr_loop
        pop     bp
        pop     dx
        pop     di
        stc
        ret
rx_dr_edge:
        pop     bp
        pop     dx
        pop     di
        clc
        ret

; --------------------------------------------------------------------------
; Collect at most one burst, then hand each frame in it to whoever asked.
; The first read is speculative: NAK means the wire is quiet, which is the
; usual answer, and the tick ends there having cost about a millisecond.
; --------------------------------------------------------------------------
rx_poll:
        ; A send is a long conversation with the chip: write 64 bytes,
        ; issue a token, wait for the interrupt.  The timer fires 145
        ; times a second and lands in the middle of it, and then two
        ; transactions are interleaved on one chip -- which loses the
        ; reply to whatever was just sent, and often the next several.
        ; in_isr below only stops the ISR re-entering ITSELF; it says
        ; nothing about the foreground.  Measured: an ARP request went
        ; out correctly -- the far end learned our address -- and the
        ; reply was never seen, along with every broadcast for seconds
        ; afterwards.
        cmp     byte [chip_busy], 0
        je      short rx_free
        ret
rx_free:
        ; The ECM link notification, rarely -- it is an event, not data, and
        ; a transaction per tick for something that changes twice an hour
        ; would be pure cost inside a timer interrupt.
        cmp     byte [link_mode], LM_ECM
        jne     short rx_nonote
        cmp     byte [ep_int_n], 0
        je      short rx_nonote
        dec     byte [int_ctr]
        jnz     short rx_nonote
        mov     byte [int_ctr], 16
        call    ecm_note
rx_nonote:

        ; Poll even when nobody is listening, and throw the result away.
        ;
        ; This used to return here without touching the chip, on the
        ; reasoning that an idle driver should cost nothing.  What it
        ; actually costs is the adapter: with nothing draining it the
        ; AX88179 keeps filling, and by the time a client opens a handle
        ; the driver starts already behind and never catches up.  Closing
        ; that gap by hand -- loading and opening a handle back to back
        ; with no pause -- took frames delivered in a fifteen second run
        ; from 2 to 18.
        ;
        ; An idle poll is a NAK and returns almost at once, so the price
        ; is the couple of percent this driver already spends looking.
rx_live:
rx_go:
        ; One burst, start to finish, inside this one call -- exactly as
        ; AxRxBurst does it, because that is the version that works.
        ;
        ; This used to spread a burst over several ticks, saving the
        ; position and carrying on next time.  It seemed the polite thing to
        ; do from inside an interrupt, and it is why the adapter wedged: it
        ; puts 27ms and a return to the foreground in the MIDDLE of a USB
        ; transfer, every time.  ax179.pas never does that, and PKTTICK
        ; settled the question -- it ran AxRxBurst itself from a hook on
        ; INT 08h and got 9 bursts and 0 errors, so interrupt context was
        ; never the problem.  Finishing what we start is.
        ;
        ; So a NAK part-way through is waited out HERE rather than deferred.
        ; A NAK does not end a bulk transfer -- only a short packet does --
        ; and one comes back in microseconds, so the wait is cheap even
        ; though the count looks large.
        push    cs
        pop     es
        mov     di, rxbuf
        xor     bp, bp                   ; BP = bytes collected
        mov     dx, RX_BUDGET
        mov     word [rx_naks], RX_NAKWAIT
rx_loop:
        mov     cl, 64
        call    bulk_in
        jnc     short rx_got

        or      bp, bp
        je      short rx_done            ; nothing in hand: the wire is idle,
                                         ; which is the usual answer
        cmp     ah, INT_RET_NAK
        jne     short rx_wedged
        dec     word [rx_naks]
        jnz     short rx_loop            ; not ready yet -- ask again

rx_wedged:
        ; Out of patience, or a real error, with a transfer half read.
        ; Only a STALL gets CLEAR_FEATURE, which is what ax179.pas does and
        ; all it does.
        inc     word [cs:n_flush]
        cmp     ah, INT_RET_STALL
        jne     short rx_wedged_go
        call    rx_unwedge
rx_wedged_go:
        call    rx_drain
        ret

rx_got:
        xor     ah, ah
        add     bp, ax
        mov     word [rx_naks], RX_NAKWAIT   ; progress: patience resets
        cmp     al, 64
        jb      short rx_have            ; short packet ends the transfer
        cmp     bp, RXBUF_SZ - 64
        jae     short rx_full            ; no room for another
        dec     dx
        jnz     short rx_loop

rx_full:
        ; Out of room, or out of budget, with the transfer still running.
        ; Read the rest and drop it: half a burst is worth nothing, and a
        ; transfer left part-read is what poisons every burst after it.
        inc     word [cs:n_over]
        call    rx_drain
        xor     bp, bp
        ret

rx_have:
        or      bp, bp
        je      short rx_done
        inc     word [n_bursts]
        cmp     byte [n_handles], 0
        je      short rx_done            ; drained, and nobody wants it
        mov     cx, bp
        mov     al, [link_mode]
        cmp     al, LM_AX
        je      short rx_have_burst
        cmp     al, LM_SR
        je      short rx_have_sr

        ; CDC-ECM: what we just accumulated IS the frame.  The transfer
        ; ended because the device sent a short packet, and that short
        ; packet is the only frame delimiter the class has -- there is
        ; nothing to parse, so there is nothing that can mis-parse.
        ;
        ; Every counter below rx_deliver -- bursts that made no sense,
        ; reads with an impossible length, frames that did not tile, frames
        ; past the frame region -- exists to police a layout this path does
        ; not have.  They stay at zero in ECM mode and that is correct
        ; rather than suspicious.
        cmp     cx, 14
        jb      short rx_done            ; shorter than an Ethernet header
        xor     di, di                   ; offset 0: the frame starts there
        inc     word [n_frames]
        call    rx_one
        ret
rx_have_burst:
        call    rx_deliver
rx_done:
        ret

; --------------------------------------------------------------------------
; SR9700/DM9601 receive: records laid end to end, each one
;
;   [status] [len low] [len high] [ ---- frame ---- ] [ FCS ]
;
; and the length counts the FCS, which the chip hands over rather than
; stripping -- the same trap the ASIX path documents at length, and it
; hides the same way: ARP reads fixed offsets and does not care, so the
; link comes up and every ping times out.
;
; THIS LOOPS, AND THE FIRST VERSION DID NOT.  That version delivered the
; first record and returned, on the finding that this chip sends one frame
; per USB transfer exactly as CDC-ECM does.  The finding was real -- 5,054
; frames went by without a single burst disagreeing with its own header --
; and it was wrong.  At 26,000 frames the counter had caught 229 of them:
; bursts of 268 bytes carrying a 64-byte record, with two hundred bytes of
; perfectly good frames behind it that were being dropped on the floor.
;
; It tiles when the frames are SMALL, which is why a download of full-size
; frames looked like proof of the opposite.  That is the whole argument for
; counting an assumption instead of trusting it: the counter cost four
; lines, it was written specifically because this was the thing most likely
; to be wrong, and it is the only reason the fault was ever seen -- nothing
; else reported anything. TCP retransmitted what was lost and the file
; still arrived byte-exact, so the download that would have "verified" this
; driver would have passed either way.
;
; The residue check at the end stays for the same reason the first counter
; did: it is now the thing most likely to be wrong.
; --------------------------------------------------------------------------
rx_have_sr:
        ; HOW DID THE LAST BURST END?  A burst that begins mid-record can
        ; only have been preceded by one that ended mid-record, so these
        ; two numbers have to agree -- and they do not: rejections at
        ; offset 0 run at 4% while truncations sit at 1 in 4,000.  Exactly
        ; one of those counters is wrong, and latching the previous
        ; outcome is what says which, rather than a third hypothesis.
        ;   0 clean   1 truncated   2 impossible length   3 residue left
        mov     al, [cs:sr_end_why]
        mov     [cs:sr_prev_why], al
        mov     byte [cs:sr_end_why], 0
        mov     ax, [cs:sr_end_left]
        mov     [cs:sr_prev_left], ax
        mov     word [cs:sr_end_left], 0

        mov     bp, cx                   ; BP = bytes the burst delivered
        xor     di, di                   ; DI = offset of this record

        ; CARRY THE PHASE ACROSS BURSTS.  A USB transfer ends where the
        ; chip's buffer happens to run dry, NOT on a record boundary, so
        ; the records are a continuous stream and a burst routinely begins
        ; part-way through one.  sr9700.pas has always modelled it that way
        ; -- SrRecv counts bytes against the header's total and keeps
        ; pulling packets until it has them all -- and this parser did not.
        ;
        ; Getting that wrong does not cost one frame, it costs a CASCADE:
        ; the first header read in each burst is garbage, so the burst is
        ; thrown away, and the next one is still out of phase.  The
        ; attribution latch is what showed it -- "the burst before it ended
        ; 2", impossible length, following impossible length -- and it is
        ; also why the truncation counter sat at zero while 6% of bursts
        ; were being rejected: the parse never got far enough to notice a
        ; record was short, because it never found a valid header at all.
        mov     ax, [cs:sr_carry]
        or      ax, ax
        je      short rx_sr_inphase
        cmp     ax, bp
        jb      short rx_sr_partway
        ; the whole burst is the tail of a record we already gave up on
        sub     ax, bp
        mov     [cs:sr_carry], ax
        ret
rx_sr_partway:
        mov     di, ax                   ; skip the continuation
        mov     word [cs:sr_carry], 0
rx_sr_inphase:
rx_sr_next:
        mov     ax, bp
        sub     ax, di
        ; The smallest thing a record can be is a header plus an empty one:
        ; 3 + 4.  This used to demand 3 + 14 + 4, which meant a whole
        ; 7-byte transfer exited here before its header was ever read --
        ; so the empty-record branch below could never fire, and every one
        ; of them was reported as unparsed residue instead.
        cmp     ax, SR_RX_OVERHEAD + 4
        jb      short rx_sr_end          ; too little left to be a record

        mov     bx, di
        add     bx, rxbuf
        mov     ax, [bx + 1]             ; the length, FCS included

        ; A LENGTH OF 4 IS NOT A FAULT, IT IS THE CHIP SAYING "NOTHING
        ; HERE" -- the length counts the FCS, so 4 is a record with no
        ; frame in it, and this part emits them routinely.  sr9700.pas has
        ; said so all along; this parser was written with a floor of 18 and
        ; counted every one of them as garbage.
        ;
        ; It showed up as 212 "impossible length" rejections in 4,347
        ; bursts against exactly 1 genuine truncation, and as a stream of
        ; SEVEN-byte bursts that the residue counter kept reporting -- 7
        ; being a 3-byte header in front of a 4-byte empty record, which is
        ; the whole transfer.  Reading those as a loss of synchronisation
        ; sent the diagnosis at the wire; the wire was fine and the floor
        ; was wrong.
        cmp     ax, 4
        jb      short rx_sr_junk

        ; BOUND IT BEFORE DOING ARITHMETIC ON IT.  Without this an FFFF in
        ; the header adds 3 to 0002 and sails through the "does it fit"
        ; test below, because the test then compares 2 against the bytes
        ; that arrived -- and rx_one is handed CX = FFFB and copies 64 KB
        ; out of a 2 KB buffer into the application's frame buffer.
        ;
        ; Malformed headers really do arrive: one burst in 5,556 during a
        ; 5 MB download read length 0 behind 1,453 bytes of real data, and
        ; a header reading FFFF is the same event with different rubbish
        ; in it.  A frame cannot exceed 1514 bytes plus its FCS.
        cmp     ax, 1514 + 4
        ja      short rx_sr_junk

        mov     bx, ax
        add     bx, SR_RX_OVERHEAD
        mov     [cs:sr_stride], bx       ; where the next record starts
        add     bx, di
        cmp     bx, bp
        jbe     short rx_sr_fits
        jmp     rx_sr_bad                ; a trampoline: rx_sr_bad is now
                                         ; more than 128 bytes below and an
                                         ; 8086 conditional jump is short
                                         ; only.  Same reason ecm_walk and
                                         ; sr_walk each grew one.
rx_sr_fits:                              ; the header claims more than
                                         ; arrived: a truncated burst, and
                                         ; delivering it would hand the
                                         ; application stale bytes from an
                                         ; earlier one -- rxbuf is never
                                         ; cleared

        ; Empty, or too short to be an Ethernet frame: step over it and
        ; carry on.  Counted rather than ignored, because "the chip emits
        ; these routinely" is a claim about the hardware and claims about
        ; the hardware are what this driver keeps getting wrong.
        cmp     ax, 4 + 14
        jb      short rx_sr_empty

        sub     ax, 4                    ; drop the FCS
        mov     cx, ax
        add     di, SR_RX_OVERHEAD       ; the frame, not the header
        inc     word [n_frames]

        ; DI AND BP ARE PUSHED BECAUSE rx_one CANNOT PROMISE TO GIVE THEM
        ; BACK.  It ends in `call far [cs:rcv_tmp]` -- the application's own
        ; receiver, somebody else's code, reached from inside a timer
        ; interrupt.  The ASIX loop above learned this twice, the second
        ; time when BP came back holding a C compiler's frame pointer.
        push    bp
        push    di
        call    rx_one
        pop     di
        pop     bp

        sub     di, SR_RX_OVERHEAD       ; back to the record
        add     di, [cs:sr_stride]       ; on to the next
        jmp     short rx_sr_next

rx_sr_empty:
        inc     word [cs:n_empty]
        add     di, [cs:sr_stride]
        jmp     short rx_sr_next

rx_sr_end:
        ; Anything left over is a record we could not read.
        mov     ax, bp
        sub     ax, di
        mov     [cs:sr_end_left], ax
        mov     byte [cs:sr_end_why], 3
        or      ax, ax
        jne     short rx_sr_resid
        mov     byte [cs:sr_end_why], 0
rx_sr_resid:
        ; Zero left over is the expected answer, and the counter exists to
        ; say so rather than to be believed.
        cmp     di, bp
        je      short rx_sr_done
        inc     word [cs:n_tile]
        mov     [cs:tile_di], di
        mov     [cs:tile_lim], bp
rx_sr_done:
        ret
; TWO WAYS TO FAIL, AND THEY MEAN OPPOSITE THINGS.  Lumping them into one
; counter is what left 1,308 rejected bursts in 25,761 unexplained for a
; whole campaign, and it was the second time in one session that the
; instrument, not the driver, was the thing in the way.
;
;   rx_sr_junk  the header's length is impossible -- under 18 or over 1518.
;               The read is landing somewhere that is not a record header,
;               so this is a SYNCHRONISATION fault.
;   rx_sr_bad   the header is plausible and the burst is shorter than it
;               says.  The transfer ended part-way through a frame, so this
;               is a REASSEMBLY fault, and the fix is to keep reading
;               rather than to resynchronise.
;
; The Pascal driver reassembles across transfer boundaries for exactly that
; reason -- sr9700.pas's SrRecv counts bytes against the header's total and
; keeps pulling packets until it has them all.  If this counter is the one
; that moves, that is the code to port.
; RESYNCHRONISE INSTEAD OF THROWING THE BURST AWAY.
;
; Four mechanisms were proposed for these rejections and every one measured
; at zero -- a drain leaving the pipe misaligned, the chip's empty-record
; convention, a straddling record, and a lost phase carried across bursts.
; They cascade (the attribution latch shows impossible-length following
; impossible-length), so whatever starts one is rare and the cost is all in
; the run that follows.
;
; So stop explaining the cause and recover from the effect.  The evidence is
; specific and strong: the rejected burst that was captured held a VALID
; record at offset 7 whose length ran to exactly the end of the burst --
; 10 + 1518 = 1528.  A record boundary can therefore be found by search,
; and the test is sharp: a length in range that lands exactly on the end of
; the burst is not something random bytes produce often.
;
; Costs nothing when alignment is fine, because this runs only after a
; header has already been rejected.
rx_sr_junk:
        mov     word [cs:sr_carry], 0
        mov     byte [cs:sr_end_why], 2

        ; Scan forward from the byte after the one that failed.
        push    ax
        mov     cx, di
        inc     cx                       ; CX = candidate offset
rx_sr_scan:
        mov     ax, bp
        sub     ax, cx
        cmp     ax, SR_RX_OVERHEAD + 4
        jb      short rx_sr_noscan       ; ran out of burst
        mov     bx, cx
        add     bx, rxbuf
        mov     ax, [bx + 1]             ; candidate length
        cmp     ax, 4
        jb      short rx_sr_scannext
        cmp     ax, 1514 + 4
        ja      short rx_sr_scannext
        mov     bx, ax
        add     bx, SR_RX_OVERHEAD
        add     bx, cx
        cmp     bx, bp
        jne     short rx_sr_scannext     ; must land exactly on the end
        ; Found it.
        mov     di, cx
        pop     ax
        inc     word [cs:n_resync]
        jmp     rx_sr_next
rx_sr_scannext:
        inc     cx
        jmp     short rx_sr_scan
rx_sr_noscan:
        pop     ax
        ; LATCH WHAT WAS ACTUALLY THERE.  Two hypotheses for these have now
        ; been proposed, implemented and measured at zero -- a drain leaving
        ; the pipe misaligned, then the chip's empty-record convention --
        ; and both were guesses dressed up as reasoning.  The length that
        ; was rejected, where in the burst it was, and how big the burst
        ; was are three numbers that settle it, and none of them was being
        ; kept.
        mov     [cs:junk_len], ax        ; the impossible length itself
        mov     [cs:junk_at], di         ; where in the burst it was read
        mov     [cs:junk_burst], bp      ; how much the burst delivered
        mov     al, [cs:sr_prev_why]     ; and how the burst BEFORE it ended
        mov     [cs:junk_prev], al
        mov     ax, [cs:sr_prev_left]
        mov     [cs:junk_prevleft], ax
        mov     cx, bp
        call    rx_keep
        inc     word [n_junk]
        ret
; The header is plausible and the record runs past the end of the burst.
; That is the normal case, not an error: the rest of it is in the next
; transfer.  Remember how much is still owed so the next burst can step
; over it and carry on IN PHASE.
;
; The straddling frame itself is still lost -- assembling it would need a
; staging buffer and the frame is one of several thousand -- but every
; record behind it in the next burst is recovered, and that is where the
; cost was.
rx_sr_bad:
        mov     byte [cs:sr_end_why], 1
        mov     ax, di
        add     ax, [cs:sr_stride]
        sub     ax, bp                   ; bytes of this record still to come
        mov     [cs:sr_carry], ax
        mov     [cs:sr_end_left], ax
        inc     word [n_short]
        ret

; --------------------------------------------------------------------------
; One read of the ECM interrupt endpoint.  A NAK is the normal answer and
; costs a few microseconds; anything else is a notification.
;
; The only one acted on is NETWORK_CONNECTION (bNotification 00), whose
; wValue is 1 for up and 0 for down.  Everything else is counted and
; dropped -- CONNECTION_SPEED_CHANGE is the other common one and this
; driver has nothing to do with the answer.
; --------------------------------------------------------------------------
ecm_note:
        mov     al, CMD_SET_ENDP6
        call    ch_cmd
        mov     al, [cs:int_tog]
        call    ch_wr
        mov     al, CMD_ISSUE_TOKEN
        call    ch_cmd
        mov     al, [cs:tok_int]
        call    ch_wr
        push    cx
        mov     cx, 0x1000
        call    ch_wait
        pop     cx
        jc      short ecn_out
        cmp     al, INT_SUCCESS
        jne     short ecn_out
        push    es
        push    di
        push    cs
        pop     es
        mov     di, rx_scratch
        mov     cl, 16
        call    ch_read
        pop     di
        pop     es
        jc      short ecn_out
        xor     byte [cs:int_tog], 0x40
        inc     word [cs:n_notify]
        cmp     al, 8
        jb      short ecn_out
        cmp     byte [cs:rx_scratch + 1], 0      ; NETWORK_CONNECTION
        jne     short ecn_out
        mov     al, [cs:rx_scratch + 2]          ; wValue low
        mov     [cs:link_st], al
ecn_out:
        ret

; --------------------------------------------------------------------------
; Pull the frames out of a burst and pass them up.  CX = bytes in rxbuf.
;
; The layout is the one USBRECV established on the hardware:
;   [frame][pad to 8][frame][pad to 8]...[entry][entry]...[trailer]
; trailer = last 4 bytes, low word the packet count and high word the
; offset of the entry array; each entry is 4 bytes and bits 16..28 of it
; are the frame length; frames start at offset 0 and each is padded up to
; an 8-byte boundary.
; --------------------------------------------------------------------------
rx_deliver:
        cmp     cx, 8
        jae     short rxd_ok
        call    rx_keep
        inc     word [n_short]
        ret

; A trampoline, because rxd_bad is now more than 128 bytes below the three
; conditional jumps in rxd_ok and an 8086 conditional jump is short only.
; It sits after the ret above, so nothing can fall into it.
rxd_ok_bad:
        jmp     near rxd_bad
rxd_ok:
        mov     si, rxbuf
        add     si, cx
        sub     si, 4                    ; SI -> trailer
        mov     ax, [si]                 ; low word  = packet count
        mov     bx, [si+2]               ; high word = entry array offset
        or      ax, ax
        je      short rxd_ok_bad
        cmp     ax, 32
        ja      short rxd_ok_bad
        mov     dx, cx
        sub     dx, 4
        cmp     bx, dx
        ja      short rxd_ok_bad         ; entry array outside the buffer
        mov     [cs:rx_flimit], bx       ; ...and where the frames must end

        ; Entry stride, worked out from the data rather than assumed: the
        ; space between the array and the trailer over the packet count.
        push    ax
        sub     dx, bx                   ; DX = bytes of entry array
        xchg    ax, dx                   ; AX = bytes, DX = count
        xor     bp, bp
        or      dx, dx
        je      short rxd_pop_bad
        div     dl                       ; AL = bytes per entry
        xor     ah, ah
        mov     bp, ax                   ; BP = stride
        pop     ax                       ; AX = packet count
        or      bp, bp
        je      short rxd_bad

        mov     di, 0                    ; DI = offset of this frame
        mov     dx, ax                   ; DX = frames left
        mov     si, rxbuf
        add     si, bx                   ; SI -> first entry
rxd_next:
        push    dx
        push    si
        mov     ax, [si+2]               ; high word of the entry
        and     ax, 0x1FFF               ; ...bits 16..28 are the length
        mov     cx, ax

        ; THE LENGTH INCLUDES THE ETHERNET FCS.  RX_CTL_DROP_CRC means
        ; "discard frames whose CRC is wrong", not "strip the CRC", and
        ; the four bytes are handed to us with the frame.  Passing them up
        ; makes every frame four bytes too long.
        ;
        ; ARP survives that -- it reads fixed offsets and ignores the tail
        ; -- which is exactly why this hid for so long: ARP resolved, the
        ; router answered, and then every ping timed out.  A capture made
        ; it obvious in one line: a 42-byte ARP request padded to the
        ; 60-byte minimum arrived as 64 bytes, with four non-zero bytes
        ; after the padding.
        ;
        ; The frame that follows is still spaced on the FULL length rounded
        ; up to eight, so the step below uses the untrimmed value.
        sub     cx, 4
        cmp     cx, 14
        jb      short rxd_skip
        ; Does this frame actually fit in the region the frames occupy?
        ; The old check was against RXBUF_SZ -- the BUFFER -- which cannot
        ; catch a frame running past the bytes this burst delivered, and
        ; rxbuf is never cleared, so past the data is stale payload from
        ; an earlier burst.  Counted, not enforced; see n_outside.
        mov     bx, di
        add     bx, cx
        add     bx, 4                    ; the FCS is in the burst too
        cmp     bx, [cs:rx_flimit]
        jbe     short rxd_inside
        inc     word [cs:n_outside]
rxd_inside:
        cmp     bx, RXBUF_SZ
        ja      short rxd_skip
        ; CX IS PUSHED BECAUSE rx_one CANNOT PROMISE TO GIVE IT BACK.
        ;
        ; rx_one ends up in `call far [cs:rcv_tmp]` -- the application's
        ; own receiver, somebody else's code, reached from inside a timer
        ; interrupt.  The comment above that call already says nothing may
        ; be assumed about any register once it returns, and then this
        ; loop went on to assume CX: the stride to the NEXT frame is
        ; computed from it three instructions below.  DI was pushed and CX
        ; was not, which is the whole of the bug.
        ;
        ; A receiver that leaves them alone hides it completely, which is
        ; why this worked for a long time and then did not.  When it does
        ; not, DI lands somewhere other than the next frame and everything
        ; parsed after it in the burst comes out of the wrong place --
        ; frames assembled from the middle of their neighbours.
        ;
        ; BP IS THE ONE THAT MATTERS MOST, and it was the last to be
        ; noticed.  It carries the ENTRY STRIDE for the whole burst and is
        ; read as `add si, bp` at the bottom of this loop, so losing it
        ; walks the entry array at the wrong pitch and every remaining
        ; frame in the burst is given the wrong length and offset.  It is
        ; also the register a C compiler is most likely to be using as a
        ; frame pointer, which makes an application receiver the LIKELIEST
        ; thing in the machine to clobber it.
        ;
        ; SI and DX are pushed at the top of the loop, so with these three
        ; the loop no longer depends on any register surviving somebody
        ; else's code.  That is the actual rule, and it is worth stating
        ; because the fix was made twice: CX first, then BP two runs later
        ; when the corruption came back.
        push    bp
        push    cx
        push    di
        call    rx_one                   ; DI = offset, CX = length
        pop     di
        pop     cx
        pop     bp
        inc     word [n_frames]
rxd_skip:
        ; On to the next frame.  The stride is the length AS THE CHIP
        ; REPORTED IT -- FCS included -- rounded up to eight, so the four
        ; bytes trimmed above have to be added back before rounding.
        add     cx, 4
        add     cx, 7
        and     cx, 0xFFF8
        add     di, cx
        pop     si
        add     si, bp
        pop     dx
        dec     dx
        jnz     short rxd_next
        ; Every frame walked.  DI should now be sitting exactly on the
        ; entry array; anywhere else and the stride went wrong somewhere.
        cmp     di, [cs:rx_flimit]
        je      short rxd_tiled
        inc     word [cs:n_tile]
        mov     [cs:tile_di], di         ; how far off, and which way
        mov     bx, [cs:rx_flimit]
        mov     [cs:tile_lim], bx
rxd_tiled:
        ret
rxd_pop_bad:
        pop     ax
rxd_bad:
        call    rx_keep
        inc     word [n_short]
        ret

; Keep CX and the first 16 bytes of the burst for /S.  Only called on a
; rejection, so it may clobber what it likes.
rx_keep:
        mov     [cs:rx_peeklen], cx
        push    cs
        pop     es
        push    cs
        pop     ds
        mov     si, rxbuf
        mov     di, rx_peek
        mov     cx, 64
        cld
        rep     movsb
        ret

; --------------------------------------------------------------------------
; One frame, at CS:rxbuf+DI, CX bytes.  Find a handle that wants it and do
; the two-call handshake the packet driver standard defines:
;
;   call the receiver with AX=0 and CX=length; it returns ES:DI, the buffer
;   to put the frame in, or 0:0 to say it does not want it.  Copy, then call
;   again with AX=1 and DS:SI pointing at the same buffer.
;
; Getting that wrong is not a subtle failure -- an application that is
; handed a buffer it never asked for writes over whatever was there.
; --------------------------------------------------------------------------
rx_one:
        mov     [rx_frofs], di
        mov     [rx_frlen], cx
        mov     bx, di
        add     bx, rxbuf                ; BX -> the frame itself
        mov     dx, [bx+12]              ; the type field.  Big-endian on
                                         ; the wire and left that way: the
                                         ; handle's stored copy is too, so
                                         ; the two compare without swapping
        xor     si, si                   ; SI = handle index
rx_find:
        cmp     byte [si+h_used], 0
        je      short rx_findnext
        mov     al, [si+h_typelen]
        or      al, al
        je      short rx_found           ; length 0 = wants everything
        cmp     al, 2
        jne     short rx_findnext        ; only 2-byte types are matched
        push    si
        shl     si, 1
        shl     si, 1
        shl     si, 1                    ; index * 8 into h_type
        mov     ax, [si+h_type]
        pop     si
        cmp     ax, dx
        je      short rx_found
rx_findnext:
        inc     si
        cmp     si, MAXHANDLE
        jb      short rx_find
        inc     word [n_nohandle]
        add     word [st_lost], 1
        adc     word [st_lost+2], 0
        ret

; --------------------------------------------------------------------------
; The two-call handshake, which is the part an application's memory depends
; on getting right.
;
;   AX=0, BX=handle, CX=length  ->  the application returns ES:DI, somewhere
;                                   to put the frame, or 0:0 to decline it
;   copy it there
;   AX=1, BX=handle, CX=length, DS:SI = that same buffer
;
; Skipping the first call and writing into a buffer nobody offered is not a
; subtle bug: it lands on whatever the application had there.  Skipping the
; second means the application never learns the frame arrived and the buffer
; leaks.  The receiver is somebody else's code called from inside a timer
; interrupt, so nothing may be assumed about any register after it returns,
; and everything worth keeping is in CS memory before the call.
; --------------------------------------------------------------------------
rx_found:
        mov     [rx_handle], si
        mov     ax, si
        shl     ax, 1
        shl     ax, 1
        mov     bx, ax
        mov     ax, [bx+h_rcv]
        mov     [rcv_tmp], ax
        mov     ax, [bx+h_rcv+2]
        mov     [rcv_tmp+2], ax

        mov     bx, [rx_handle]
        mov     cx, [rx_frlen]
        xor     ax, ax                   ; first call: "do you want it?"
        call    far [cs:rcv_tmp]

        push    cs
        pop     ds                       ; the receiver owned DS; take it back
        mov     ax, es
        or      ax, di
        jne     short rx_wanted
        inc     word [n_nohandle]        ; declined, and that is allowed
        add     word [st_lost], 1
        adc     word [st_lost+2], 0
        ret
rx_wanted:
        push    es
        push    di
        mov     si, [rx_frofs]
        add     si, rxbuf
        mov     cx, [rx_frlen]
        cld
        rep     movsb                    ; CS:rxbuf+ofs -> the app's buffer
        pop     di
        pop     es

        mov     ax, es                   ; second call: DS:SI = that buffer
        mov     ds, ax
        mov     si, di
        mov     cx, [cs:rx_frlen]
        mov     bx, [cs:rx_handle]
        mov     ax, 1
        call    far [cs:rcv_tmp]

        push    cs
        pop     ds
        add     word [st_pkts_in], 1
        adc     word [st_pkts_in+2], 0
        mov     ax, [rx_frlen]
        add     word [st_bytes_in], ax
        adc     word [st_bytes_in+2], 0
        ret

; ==========================================================================
; THE PACKET DRIVER ENTRY POINT
; ==========================================================================
pkt_entry:
        jmp     short pkt_go
        nop
        db      'PKT DRVR', 0            ; the signature, at entry+3, which
                                         ; is the whole discovery mechanism
                                         ; the standard defines
pkt_go:
        sti
        cld
        cmp     ah, 1
        jne     short __ovr1
        jmp     near pkt_info
__ovr1:
        cmp     ah, 2
        jne     short __ovr2
        jmp     near pkt_access
__ovr2:
        cmp     ah, 3
        jne     short __ovr3
        jmp     near pkt_release
__ovr3:
        cmp     ah, 4
        jne     short __ovr4
        jmp     near pkt_send
__ovr4:
        cmp     ah, 5
        jne     short __ovr5
        jmp     near pkt_terminate
__ovr5:
        cmp     ah, 6
        jne     short __ovr6
        jmp     near pkt_getaddr
__ovr6:
        cmp     ah, 7
        jne     short __ovr7
        jmp     near pkt_reset
__ovr7:
        cmp     ah, 20
        jne     short __ovr8
        jmp     near pkt_setmode
__ovr8:
        cmp     ah, 21
        jne     short __ovr9
        jmp     near pkt_getmode
__ovr9:
        cmp     ah, 24
        jne     short __ovr10
        jmp     near pkt_stats
__ovr10:
        mov     dh, E_BAD_COMMAND
        stc
        retf    2

; ---- 1: driver_info ----
pkt_info:
        push    cs
        pop     ds
        mov     si, [drv_nptr]
        mov     bx, 1                    ; version
        mov     ch, 1                    ; class 1 = DIX Ethernet
        mov     dx, 0                    ; type: unregistered
        mov     cl, 0                    ; interface number
        mov     al, 2                    ; basic plus extended
        clc
        retf    2

; ---- 6: get_address ----
pkt_getaddr:
        cmp     cx, 6
        jae     short pga_ok
        mov     dh, E_NO_SPACE
        stc
        retf    2
pga_ok:
        push    si
        push    ds
        push    cs
        pop     ds
        mov     si, mac
        mov     cx, 6
        rep     movsb
        pop     ds
        pop     si
        mov     cx, 6
        clc
        retf    2

; ---- 21: get_rcv_mode ----
pkt_getmode:
        mov     ax, [cs:rcv_mode]
        clc
        retf    2

; ---- 20: set_rcv_mode ----
; It used to store the mode and stop there, which made get_rcv_mode agree
; with itself and the adapter carry on doing whatever it had been doing.
; An application asking for promiscuous mode and not getting it is a
; particularly unhelpful way to fail, because everything looks fine and
; simply no interesting frames arrive.
pkt_setmode:
        cmp     cx, 1
        jb      short psm_bad
        cmp     cx, 6
        ja      short psm_bad
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        mov     bx, RX_CTL_DROP_CRC
        cmp     cx, 1
        je      short psm_write          ; 1 = receiver off
        or      bx, (RX_CTL_START | RX_CTL_ACCEPT_PHY)
        cmp     cx, 2
        je      short psm_write          ; 2 = our address only
        or      bx, RX_CTL_BROADCAST
        cmp     cx, 3
        je      short psm_write          ; 3 = ...and broadcast
        or      bx, RX_CTL_MULTICAST
        cmp     cx, 4
        je      short psm_write          ; 4 = ...and some multicast
        or      bx, RX_CTL_ALLMULTI
        cmp     cx, 5
        je      short psm_write          ; 5 = ...and all multicast
        or      bx, RX_CTL_PROMISC       ; 6 = everything on the wire
psm_write:
        mov     al, AX_RX_CTL
        call    res_mac_wr16
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        jc      short psm_hw
        mov     [cs:rcv_mode], cx
        clc
        retf    2
psm_hw:
        mov     dh, E_CANT_SET
        stc
        retf    2
psm_bad:
        mov     dh, E_BAD_MODE
        stc
        retf    2

; ---- 7: reset_interface ----
pkt_reset:
        clc
        retf    2

; ---- 24: get_statistics ----
pkt_stats:
        push    cs
        pop     ds
        mov     si, st_pkts_in
        clc
        retf    2

; ---- 2: access_type ----
; AL = class, BX = type, DL = number, DS:SI -> type bytes, CX = type length,
; ES:DI -> receiver.  Returns AX = handle.
pkt_access:
        cmp     al, 1                    ; class 1, DIX Ethernet
        je      short pa_class_ok
        mov     dh, E_NO_CLASS
        stc
        retf    2
pa_class_ok:
        cmp     cx, 8
        jbe     short pa_len_ok
        mov     dh, E_BAD_TYPE
        stc
        retf    2
pa_len_ok:
        push    bx
        push    cx
        push    si
        push    di
        push    es
        push    ds
        ; find a free row
        xor     bx, bx
pa_find:
        cmp     byte [cs:bx+h_used], 0
        je      short pa_got
        inc     bx
        cmp     bx, MAXHANDLE
        jb      short pa_find
        pop     ds
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     bx
        mov     dh, E_NO_SPACE
        stc
        retf    2
pa_got:
        mov     byte [cs:bx+h_used], 1
        mov     al, cl
        mov     [cs:bx+h_typelen], al
        ; copy the type bytes
        push    bx
        push    di
        mov     ax, bx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        mov     di, ax
        add     di, h_type
        push    cs
        pop     es
        jcxz    pa_nocopy
        rep     movsb                    ; DS:SI -> type, ES:DI -> our row
pa_nocopy:
        pop     di
        pop     bx
        ; store the receiver
        pop     ds
        pop     es                       ; ES:DI is the receiver again
        push    es
        push    ds
        mov     ax, bx
        shl     ax, 1
        shl     ax, 1
        mov     si, ax
        mov     [cs:si+h_rcv], di
        mov     ax, es
        mov     [cs:si+h_rcv+2], ax
        inc     byte [cs:n_handles]
        pop     ds
        pop     es
        pop     di
        pop     si
        pop     cx
        pop     ax                       ; the pushed BX
        mov     ax, bx                   ; handle = row index
        clc
        retf    2

; ---- 3: release_type ----
pkt_release:
        cmp     bx, MAXHANDLE
        jb      short prl_ok
prl_bad:
        mov     dh, E_BAD_HANDLE
        stc
        retf    2
prl_ok:
        cmp     byte [cs:bx+h_used], 0
        je      short prl_bad
        mov     byte [cs:bx+h_used], 0
        dec     byte [cs:n_handles]
        clc
        retf    2

; ---- 5: terminate ----
; Refused.  Unloading has to put INT 08h back as well, and doing that from
; inside a call made by the program being unloaded is how a machine ends up
; with a vector pointing at freed memory.  USBPKT /U does it properly, from
; the command line, with the checks that need a transient copy to make.
pkt_terminate:
        mov     dh, E_CANT_TERMINATE
        stc
        retf    2

; ---- 4: send_pkt ----
; DS:SI -> frame, CX = length.
pkt_send:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp
        push    ds
        push    es
        cmp     cx, 14
        jae     short __ovr11
        jmp     near psend_bad
__ovr11:
        cmp     cx, 1514
        jbe     short __ovr12
        jmp     near psend_bad
__ovr12:
        ; Claim the chip before touching it.  Setting the flag with one
        ; instruction is enough: the timer can only land between
        ; instructions, so it either sees the flag and leaves, or it ran
        ; to completion before we started.
        mov     byte [cs:chip_busy], 1

        ; Build the 8-byte header in front of a copy of the frame.  Two
        ; little-endian 32-bit words: the length, then zero -- except when
        ; the total lands on an exact multiple of the 64-byte packet size,
        ; when bits 15 and 31 are set.  That case ALSO needs a zero-length
        ; packet to end the USB transfer, which is a separate requirement
        ; that happens to arise at the same moment.
        push    cs
        pop     es
        mov     di, txbuf
        mov     bx, cx
        add     bx, [cs:tx_hdrlen]       ; BX = what goes on the wire
        mov     al, [cs:link_mode]
        cmp     al, LM_AX
        je      short psend_axhdr
        cmp     al, LM_SR
        jne     short psend_body         ; ECM sends the frame and nothing
                                         ; else.  The zero-length packet at
                                         ; the end is still needed and is
                                         ; still decided by BX below, which
                                         ; is why the length is computed
                                         ; before the branch rather than
                                         ; inside each arm.
        ; SR9700: two bytes, little-endian, and that is the whole header.
        ; It does NOT count itself -- the chip is being told how long the
        ; Ethernet frame is, which is why CX rather than BX goes in.
        mov     ax, cx
        stosw
        jmp     short psend_body
psend_axhdr:
        mov     ax, cx
        stosw                            ; length, low word
        xor     ax, ax
        stosw                            ; length, high word
        test    bx, 0x003F
        jnz     short psend_nopad
        mov     ax, 0x8000
        stosw
        mov     ax, 0x8000
        stosw
        jmp     short psend_body
psend_nopad:
        xor     ax, ax
        stosw
        stosw
psend_body:
        push    cx
        rep     movsb                    ; DS:SI -> caller's frame
        pop     cx

        ; Snapshot what we are about to put on the wire, from txbuf rather
        ; than from the caller's buffer, so it shows the bytes as assembled.
        push    cx
        push    si
        push    di
        push    ds
        push    cs
        pop     ds
        mov     si, txbuf
        add     si, [cs:tx_hdrlen]
        mov     di, tx_peek
        mov     cx, 16
        rep     movsb
        pop     ds
        pop     di
        pop     si
        pop     cx
        mov     cx, bx                   ; CX = total to push out

        push    cs
        pop     ds
        mov     si, txbuf
psend_loop:
        mov     ax, cx
        cmp     ax, 64
        jbe     short psend_last
        mov     ax, 64
psend_last:
        mov     [cs:tx_chunk], ax
        push    cx
        mov     cl, al
        call    bulk_out
        pop     cx
        jc      short psend_fail
        sub     cx, [cs:tx_chunk]
        jnz     short psend_loop

        ; the terminating zero-length packet, when it is needed
        test    bx, 0x003F
        jnz     short psend_ok
        xor     cl, cl
        call    bulk_out
        jc      short psend_fail
psend_ok:
        mov     byte [cs:chip_busy], 0
        add     word [cs:st_pkts_out], 1
        adc     word [cs:st_pkts_out+2], 0
        sub     bx, [cs:tx_hdrlen]       ; BX was length + header
        add     word [cs:st_bytes_out], bx
        adc     word [cs:st_bytes_out+2], 0
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        clc
        retf    2
psend_fail:
        add     word [cs:st_err_out], 1
        adc     word [cs:st_err_out+2], 0
psend_bad:
        mov     byte [cs:chip_busy], 0
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        mov     dh, E_CANT_SEND
        stc
        retf    2

resident_end:

; ==========================================================================
; TRANSIENT -- everything below here is released when the driver goes
; resident, and none of it may be reached from the ISR.
; ==========================================================================
%include "usbpktini.inc"
