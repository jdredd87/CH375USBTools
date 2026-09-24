; ==========================================================================
; I16SPY.COM -- count INT 16h calls by function and paint the totals on
;               screen, so an interactive program can be watched.
;
;   CH375Keyboard, StevenC & Claude.  Public domain (the Unlicense).
;
;   I16SPY        go resident and start counting
;   I16SPY /U     unhook and free
;   I16SPY /S     print the counters
;
; WHY THIS EXISTS.  DOS EDIT can be typed into but its menu bar cannot be
; driven by a queued keystroke, and four plausible explanations were tested
; and all four were wrong.  What was missing every time was the one fact
; that settles it: does EDIT's menu loop call INT 16h at all while it is
; sitting there ignoring us, and if so which function?
;
;   * If the counters keep climbing while the menu is stuck, EDIT IS asking
;     for keys and rejecting what it gets -- so the fault is in the value
;     or the state that comes with it.
;   * If the counters freeze, EDIT is not asking at all, and is waiting on
;     something a queued key cannot provide.  On a machine with no 8042
;     that would be the end of the road, and worth knowing.
;
; WHY IT PAINTS THE SCREEN.  A stuck interactive program cannot be asked
; anything: it holds the foreground, so nothing else runs and no output can
; be collected.  The counters therefore go straight into video memory,
; where `doscap shot` can photograph them.  That is the only channel out of
; a machine in that state.
;
; The counters sit at the right-hand end of the top line, which is the
; least interesting part of a menu bar.  EDIT will redraw over them from
; time to time; they are repainted on every INT 16h call, so they come
; straight back.
;
; ASSEMBLING
;       nasm -f bin i16spy.asm -o I16SPY.COM
; ==========================================================================

        cpu     8086
        bits    16
        org     0x100

entry:
        jmp     near init

signature:
        db      'I16SPY01'                      ; 0103

old16:  dd      0
c00:    dw      0                ; AH=00h  read, legacy
c01:    dw      0                ; AH=01h  peek, legacy
c10:    dw      0                ; AH=10h  read, enhanced
c11:    dw      0                ; AH=11h  peek, enhanced
c02:    dw      0                ; AH=02h  shift state, legacy
c12:    dw      0                ; AH=12h  shift state, enhanced
coth:   dw      0                ; anything else
vseg:   dw      0xB800
res_seg: dw     0

; --------------------------------------------------------------------------
; The hook.  Counting has to be completely transparent: INT 16h returns
; values in AX and, for the peek functions, a meaningful ZF, so every
; register and the caller's flags must arrive at the real handler exactly
; as they left the caller.  Chaining with a far jump and the original
; interrupt frame still on the stack is what makes that true -- the old
; handler's own IRET then returns straight to the caller.
; --------------------------------------------------------------------------
int16:
        push    ds
        push    bx
        push    ax
        mov     bx, cs
        mov     ds, bx

        cmp     ah, 0x00
        jne     short s_n00
        inc     word [c00]
        jmp     short s_paint
s_n00:
        cmp     ah, 0x01
        jne     short s_n01
        inc     word [c01]
        jmp     short s_paint
s_n01:
        cmp     ah, 0x10
        jne     short s_n10
        inc     word [c10]
        jmp     short s_paint
s_n10:
        cmp     ah, 0x11
        jne     short s_n11
        inc     word [c11]
        jmp     short s_paint
s_n11:
        cmp     ah, 0x02
        jne     short s_n02
        inc     word [c02]
        jmp     short s_paint
s_n02:
        cmp     ah, 0x12
        jne     short s_n12
        inc     word [c12]
        jmp     short s_paint
s_n12:
        inc     word [coth]
s_paint:
        call    paint
        pop     ax
        pop     bx
        pop     ds
        jmp     far [cs:old16]

; --------------------------------------------------------------------------
; Paint the counters at the right-hand end of row 0.
;   "00 0000 01 0000 10 0000 11 0000"  is too wide, so the labels go and
; the order is fixed: 00 01 10 11 02 12 other, four hex digits each.
; --------------------------------------------------------------------------
paint:
        push    ax
        push    bx
        push    cx
        push    di
        push    es
        mov     ax, [vseg]
        mov     es, ax
        mov     di, (0 * 80 + 45) * 2

        mov     ax, [c00]
        call    pw
        mov     ax, [c01]
        call    pw
        mov     ax, [c10]
        call    pw
        mov     ax, [c11]
        call    pw
        ; Who owns INT 09h and INT 08h right now?  Sampled here, inside
        ; the interrupted program, because that is the only moment the
        ; answer is about the program and not about DOS.
        push    ds
        xor     ax, ax
        mov     ds, ax
        mov     ax, [0x0026]             ; INT 09h vector segment
        mov     bx, [0x0022]             ; INT 08h vector segment
        pop     ds
        call    pw
        mov     ax, bx
        call    pw

        pop     es
        pop     di
        pop     cx
        pop     bx
        pop     ax
        ret

; AX as four hex digits at ES:DI, then a space.  DI advances.
pw:
        push    ax
        mov     al, ah
        call    pb
        pop     ax
        call    pb
        mov     al, ' '
        call    pc
        ret

; AL as two hex digits.
pb:
        push    ax
        push    cx
        mov     cl, 4
        shr     al, cl
        call    pn
        pop     cx
        pop     ax
        push    ax
        and     al, 0x0F
        call    pn
        pop     ax
        ret

pn:
        add     al, '0'
        cmp     al, '9'
        jbe     short pn_ok
        add     al, 7
pn_ok:
        call    pc
        ret

; AL as a character with a fixed bright attribute.
pc:
        mov     [es:di], al
        inc     di
        mov     byte [es:di], 0x1F
        inc     di
        ret

resident_end:

; ==========================================================================
; TRANSIENT
; ==========================================================================

init:
        call    parse
        mov     dx, msg_prog
        call    puts

        cmp     byte [op_help], 0
        je      short not_help
        mov     dx, msg_help
        call    puts
        jmp     near quit
not_help:
        call    find_res
        cmp     byte [op_stat], 0
        je      short not_stat
        jmp     near do_stat
not_stat:
        cmp     byte [op_unl], 0
        je      short not_unl
        jmp     near do_unl
not_unl:
        cmp     word [res_seg], 0
        je      short fresh
        mov     dx, msg_already
        call    puts
        jmp     near quit
fresh:
        ; Which video segment is live?  The card in this machine is not the
        ; same one every boot, so the mode byte decides rather than a
        ; hardcoded B800.
        push    ds
        mov     ax, 0x40
        mov     ds, ax
        mov     al, [0x49]
        pop     ds
        cmp     al, 7
        jne     short colour
        mov     word [vseg], 0xB000
colour:

        cli
        mov     ax, 0x3516
        int     0x21
        mov     [old16], bx
        mov     [old16 + 2], es
        mov     dx, int16
        mov     ax, 0x2516
        int     0x21
        sti

        mov     dx, msg_ok
        call    puts
        mov     dx, resident_end
        add     dx, 15
        mov     cl, 4
        shr     dx, cl
        mov     ax, 0x3100
        int     0x21

find_res:
        push    ds
        push    es
        push    si
        push    di
        push    cx
        mov     ax, 0x3516
        int     0x21
        mov     ax, es
        or      ax, ax
        je      short fr_no
        mov     ds, ax
        push    cs
        pop     es
        mov     si, signature
        mov     di, signature
        mov     cx, 8
        repe    cmpsb
        jne     short fr_no
        mov     ax, ds
        pop     cx
        pop     di
        pop     si
        pop     es
        pop     ds
        mov     [res_seg], ax
        ret
fr_no:
        pop     cx
        pop     di
        pop     si
        pop     es
        pop     ds
        mov     word [res_seg], 0
        ret

do_stat:
        cmp     word [res_seg], 0
        jne     short st_have
        mov     dx, msg_notres
        call    puts
        jmp     near quit
st_have:
        mov     dx, msg_counts
        call    puts
        mov     bx, c00
        mov     cx, 7
st_loop:
        push    cx
        push    bx
        push    ds
        mov     ds, [cs:res_seg]
        mov     ax, [bx]
        pop     ds
        call    putdec
        mov     al, ' '
        call    putc
        pop     bx
        add     bx, 2
        pop     cx
        loop    st_loop
        call    crlf
        jmp     near quit

do_unl:
        cmp     word [res_seg], 0
        jne     short unl_ok
        mov     dx, msg_notres
        call    puts
        jmp     near quit
unl_ok:
        mov     ax, 0x3516
        int     0x21
        mov     ax, es
        cmp     ax, [res_seg]
        je      short unl_go
        mov     dx, msg_hooked
        call    puts
        jmp     near quit
unl_go:
        cli
        push    ds
        mov     ds, [cs:res_seg]
        mov     dx, [old16]
        mov     ax, [old16 + 2]
        pop     ds
        push    ds
        mov     ds, ax
        mov     ax, 0x2516
        int     0x21
        pop     ds
        sti
        push    es
        mov     es, [res_seg]
        mov     ax, [es:0x2C]
        or      ax, ax
        je      short unl_noenv
        push    es
        mov     es, ax
        mov     ah, 0x49
        int     0x21
        pop     es
unl_noenv:
        mov     ah, 0x49
        int     0x21
        pop     es
        mov     dx, msg_unloaded
        call    puts
        jmp     near quit

parse:
        mov     si, 0x81
        mov     cl, [0x80]
        xor     ch, ch
        jcxz    pa_out
pa_loop:
        lodsb
        dec     cx
        ; '?' before the upper-casing: AND 0DFh clears bit 5, which folds
        ; letters and mangles everything else -- it turns '?' (3Fh) into
        ; 1Fh.  USBKBD had exactly this bug and /? never worked there.
        cmp     al, '?'
        jne     short pa_nq
        mov     byte [op_help], 1
pa_nq:
        and     al, 0xDF
        cmp     al, 'U'
        jne     short pa_ns
        mov     byte [op_unl], 1
pa_ns:
        cmp     al, 'S'
        jne     short pa_nx
        mov     byte [op_stat], 1
pa_nx:
        jcxz    pa_out
        jmp     short pa_loop
pa_out:
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
        push    ax
        mov     al, 13
        call    putc
        mov     al, 10
        call    putc
        pop     ax
        ret

puts:
        push    ax
        mov     ah, 9
        int     0x21
        pop     ax
        ret

putdec:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, 10
        xor     cx, cx
pd_d:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        or      ax, ax
        jne     short pd_d
pd_p:
        pop     ax
        add     al, '0'
        call    putc
        loop    pd_p
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

quit:
        mov     ax, 0x4C00
        int     0x21

op_unl:  db 0
op_stat: db 0
op_help: db 0

msg_prog:     db 'I16SPY 1.0.0 -- INT 16h call counter -- StevenC & Claude', 13, 10, '$'
msg_help:     db 13, 10
        db 'Counts INT 16h calls by function and paints the totals on', 13, 10
        db 'row 0 of the screen, so an interactive program can be watched', 13, 10
        db 'from a machine you cannot type at.', 13, 10, 13, 10
        db '  I16SPY        go resident and start counting', 13, 10
        db '  I16SPY /S     print the counters', 13, 10
        db '  I16SPY /U     unhook and free', 13, 10
        db '  I16SPY /?     this screen', 13, 10, 13, 10
        db 'Row 0 shows AH= 00 01 10 11 02 12 and everything else.  If the', 13, 10
        db 'counters climb while a program looks stuck, it IS asking for', 13, 10
        db 'keys and rejecting what it gets.  If they freeze, it is not', 13, 10
        db 'asking at all and is reading the hardware itself -- which on a', 13, 10
        db 'machine with no 8042 cannot be reached by any software driver.', 13, 10
        db 13, 10
        db 'github.com/jdredd87/CH375USBTools -- public domain', 13, 10, '$'
msg_ok:       db 'Resident.  Counts on row 0: 00 01 10 11 02 12 other.', 13, 10, '$'
msg_already:  db 'Already loaded.  /U unloads it.', 13, 10, '$'
msg_notres:   db 'Not loaded.', 13, 10, '$'
msg_unloaded: db 'Unloaded.', 13, 10, '$'
msg_hooked:   db 'Cannot unload: something hooked INT 16h after us.', 13, 10, '$'
msg_counts:   db 'AH= 00 01 10 11 02 12 other: $'
