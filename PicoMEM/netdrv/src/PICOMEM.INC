PicoMEM Equ 1
PM_8Bit Equ 1
; PM_NoPause 1: no dummy I/O before each NIC register access. A real
; DP8390 needs four bus clocks between chip selects; the PicoMEM emulates
; the chip and answers each cycle itself, and REP INSB already goes
; back to back on the data port. 0 builds the original timing.
PM_NoPause Equ 1
