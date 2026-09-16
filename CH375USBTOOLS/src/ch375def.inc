; ==========================================================================
; ch375def.inc -- CH375 command codes, statuses and token PIDs.
;                 Constants only: it emits no bytes and may sit anywhere.
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

; ---- CH375 commands ----
CMD_GET_IC_VER   equ 0x01
CMD_RESET_ALL    equ 0x05
CMD_CHECK_EXIST  equ 0x06
CMD_SET_RETRY    equ 0x0B
CMD_SET_USB_ADDR equ 0x13
CMD_SET_USB_MODE equ 0x15
CMD_TEST_CONNECT equ 0x16
CMD_ABORT_NAK    equ 0x17
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

PID_OUT          equ 0x01
PID_IN           equ 0x09
PID_SETUP        equ 0x0D

USB_ADDR         equ 2            ; address we give the mouse
