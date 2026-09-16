@ECHO OFF
REM ======================================================================
REM  GO.BAT -- run a DOS BBS on the FOSSIL driver, over TCP.
REM
REM  EDIT THESE TWO LINES for whichever BBS is installed. Everything below
REM  them is the same whatever the BBS is, because the BBS believes it is
REM  talking to a modem and none of this is its business.
REM ======================================================================

SET BBSDIR=C:\RENEGADE
SET BBSEXE=RENEGADE.EXE

REM ======================================================================
REM  The driver presents a TCP listener to the BBS as a modem: a caller
REM  connecting IS the carrier appearing, and closing the connection drops
REM  it. Configure the BBS for a FOSSIL. It needs no modem init, dial or
REM  answer strings at all, and the COM port number does not matter --
REM  this driver ignores it.
REM
REM  WHILE THIS RUNS, THIS MACHINE IS OFF THE DOSBRIDGE NETWORK. The driver
REM  holds the packet driver's handle for as long as the line is open, and
REM  that is the same network the bridge reaches this machine over. It is
REM  expected, not a fault. If the BBS dies without cleaning up, the driver
REM  hands the handle back on its own after about a minute.
REM
REM  The addresses below belong to THIS machine. Change all three if you
REM  move it: /I is our own IP, /H only seeds one ARP at startup, and /V is
REM  the packet driver's vector in hex -- run PKTDRV to find it. The driver
REM  will not guess the vector, because the first packet driver on a bridge
REM  machine is the bridge's own link.
REM
REM  IT CHANGES THE CURRENT DIRECTORY AND PUTS IT BACK AT THE END, and that
REM  second half is not tidiness: run from the DOSBridge agent's job batch,
REM  a BBS batch that wandered off and stayed there left the agent loop
REM  somewhere it did not expect, and the machine went off the air until it
REM  was power-cycled. For the same reason, invoke this with CALL from
REM  another batch, or control never comes back to the caller.
REM ======================================================================

C:
CD %BBSDIR%

IF NOT EXIST %BBSEXE% GOTO NOBBS
IF NOT EXIST FOSSIL.COM GOTO NODRV

ECHO Loading the FOSSIL driver...
FOSSIL.COM /P /V=60 /I=192.168.50.66 /H=192.168.50.46 /T=2323
IF ERRORLEVEL 2 GOTO BADLOAD
IF ERRORLEVEL 1 GOTO BORROWED
SET FOSMINE=1
GOTO RUNBBS

:BORROWED
ECHO A FOSSIL driver was already resident. Using it, and leaving it
ECHO loaded when we finish.
GOTO RUNBBS

:RUNBBS
ECHO.
ECHO %BBSEXE% is answering on port 2323.
ECHO Callers:  telnet 192.168.50.66 2323
ECHO.
%BBSEXE% %1 %2 %3 %4
ECHO.
ECHO The BBS has exited.
IF NOT "%FOSMINE%"=="1" GOTO DONE
FOSSIL.COM /U
SET FOSMINE=
GOTO DONE

:BADLOAD
ECHO.
ECHO The FOSSIL driver would not load. Things to check, cheapest first:
ECHO   PKTDRV            is the packet driver really at INT 60h?
ECHO   FOSSIL.COM /S     is a copy already resident?
ECHO   FOSSIL.COM /U     unload a stuck one
ECHO.
GOTO DONE

:NOBBS
ECHO.
ECHO %BBSEXE% is not in %BBSDIR%. Install the BBS first, then set
ECHO BBSDIR and BBSEXE at the top of this file.
ECHO.
GOTO DONE

:NODRV
ECHO.
ECHO FOSSIL.COM is not in %BBSDIR%. Copy it there.
ECHO.

:DONE
CD \
