rem c:\work\usbcombo.com 
@ECHO OFF
PATH=C:\WINDOWS;C:\;C:\DOS;C:\NETWORK\MTCP;c:\drivers;c:\software\pkzip;c:\bp\bin;c:\ai
SET mtcpcfg=c:\network\mtcp\mtcp.cfg 
SET TEMP=C:\WINDOWS\TEMP
doskey 
REM ctmouse /S1 /M /3 
C:\drivers\pm2000.com 0x60
REM ---- USB Ethernet adapter on the CH375 card.  StevenC & Claude.
REM ---- pm2000 above keeps 60h and loads FIRST no matter what, so the
REM ---- network this box is administered over survives anything here.
REM ---- USBPKT brings the adapter up itself.  USBLINK is NOT used at
REM ---- boot: USBLINK is what used to hang the machine.
REM
REM ---- The flag is the safety net, and it is the trick AI.BAT already
REM ---- uses for staged drivers.  IF ERRORLEVEL catches a bring-up that
REM ---- FAILS; nothing catches one that HANGS, and a hang here happens
REM ---- before the agent starts, so the box would need hands on the
REM ---- keyboard.  So drop a flag before trying and delete it after.  A
REM ---- boot that finds the flag still there knows the last attempt
REM ---- never came back, skips the lot, and comes up reachable.  Worst
REM ---- case is one power cycle -- never a walk to the machine.
REM ---- Delete from here to :NETOK to go back to the NE2000 alone.
IF EXIST C:\CH375\TRYING.FLG GOTO USBWEDGED
ECHO trying > C:\CH375\TRYING.FLG
C:\CH375\USBPKT.COM /I=65
IF ERRORLEVEL 1 GOTO NOUSB
DEL C:\CH375\TRYING.FLG
REM ---- Only now, with the adapter actually up, is mTCP pointed at it,
REM ---- and at a COPY of the config -- never the one the working
REM ---- network uses.  DOSBridge does not read this file at all: it has
REM ---- its own C:\AI\NET.CFG and stays on the NE2000 regardless.
SET MTCPCFG=C:\CH375\MTCPAX.CFG
ECHO USB Ethernet ready - mTCP now uses it (packetint 0x65).
GOTO NETOK
:USBWEDGED
DEL C:\CH375\TRYING.FLG
ECHO Last boot hung bringing the USB adapter up - skipped this time.
ECHO Staying on the NE2000.  C:\CH375\NET.BAT tries it by hand.
GOTO NETOK
:NOUSB
IF EXIST C:\CH375\TRYING.FLG DEL C:\CH375\TRYING.FLG
ECHO USB adapter did not come up - staying on the NE2000.
:NETOK
cd \AI
CALL AI.bat

