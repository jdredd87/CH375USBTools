@ECHO OFF
REM  NET    -- load the packet driver for the USB Ethernet adapter.
REM  NET U  -- unload it again.
REM  StevenC & Claude.  Public domain.  DO NOT put this in AUTOEXEC.BAT:
REM  loaded from the prompt a mistake costs a power cycle, loaded
REM  at boot it costs a walk to the machine.
REM
REM  One program does the whole job now -- enumerate the device over
REM  the CH375, bring the adapter up, and go resident -- the way
REM  NE2000.COM does.  USBLINK is still there and still useful, but
REM  it is a diagnostic, not a prerequisite.
IF "%1"=="U" GOTO UNLOAD
IF "%1"=="u" GOTO UNLOAD
C:\CH375\USBPKT.COM
IF ERRORLEVEL 1 GOTO NOPE
ECHO.
ECHO Ready.  Point mTCP at it for this session with:
ECHO     SET MTCPCFG=C:\CH375\MTCPAX.CFG
ECHO and put it back afterwards with:
ECHO     SET MTCPCFG=c:\network\mtcp\mtcp.cfg
GOTO END
:UNLOAD
C:\CH375\USBPKT.COM /U
GOTO END
:NOPE
ECHO.
ECHO It did not come up.  NETID says what is plugged in; USBLINK /V
ECHO walks the same sequence printing the chip status at every access.
:END
