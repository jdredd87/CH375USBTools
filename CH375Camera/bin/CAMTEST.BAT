@ECHO OFF
REM CAMTEST.BAT -- every test CH375Camera has, one after another.
REM CH375Camera, StevenC.  Public domain (the Unlicense).
REM
REM   CAMTEST          all of it, including the two button tests, which
REM                    beep when it is time to press.  Nothing ever waits
REM                    for a key: a button test nobody answers reports
REM                    NOT PRESSED and the run carries on.
REM   CAMTEST AUTO     skips the button tests.
REM
REM Run it in the directory holding the CAM*.EXE files, with the IBM PC
REM Camera plugged into the CH375.  It writes its pictures here too
REM (CT*.BMP and CT*.RAW) -- open them afterwards to see what it saw.
REM
REM Each step prints PASS, FAIL or SKIP; the last line sums it up.  One IF
REM per line throughout: COMMAND.COM 6.22 drops a chained IF's external
REM command without a word.
REM
REM NO ENVIRONMENT VARIABLES.  A first version kept its state in SET
REM variables, and run over DOSBridge -- whose jobs get a small environment
REM -- every SET failed with "Out of environment space": AUTO was never
REM recorded, the test stopped at a PAUSE, and nobody was there to press a
REM key.  So AUTO is %1 tested where it matters, and failures go into a
REM file, CTFAIL.TXT, listed at the end.
REM
REM Instructions go to CON, so they reach the screen even when the output
REM is being captured (COMMAND /C CAMTEST > FILE, which is how DOSBridge
REM runs it).  There is no PAUSE anywhere: an earlier version paused before
REM each part that wanted a person, and a run nobody was watching waited at
REM the first one forever.

IF NOT EXIST CAMSNAP.EXE GOTO NOEXE
IF NOT EXIST CAMLIVE.EXE GOTO NOEXE
IF NOT EXIST CAMBTN.EXE GOTO NOEXE
IF NOT EXIST FASTTEST.EXE GOTO NOEXE

ECHO.
ECHO ===== CH375Camera test run =====
IF "%1"=="AUTO" ECHO (AUTO: the button tests are skipped)
ECHO.

REM ---- leftovers from an earlier run would make the checks lie
IF EXIST CT176.BMP DEL CT176.BMP
IF EXIST CT320.BMP DEL CT320.BMP
IF EXIST CT352.BMP DEL CT352.BMP
IF EXIST CT176.RAW DEL CT176.RAW
IF EXIST CT320.RAW DEL CT320.RAW
IF EXIST CT352.RAW DEL CT352.RAW
IF EXIST CTB1.BMP DEL CTB1.BMP
IF EXIST CTB2.BMP DEL CTB2.BMP
IF EXIST CTB3.BMP DEL CTB3.BMP
IF EXIST CTFAIL.TXT DEL CTFAIL.TXT

REM ================================================================
ECHO ----- 1. the assembly, checked against Pascal (no camera needed)
FASTTEST
IF ERRORLEVEL 1 GOTO F1
ECHO PASS  1 FASTTEST
GOTO S2
:F1
ECHO FAIL  1 FASTTEST -- a drawing routine disagrees with its Pascal
ECHO FASTTEST >> CTFAIL.TXT

REM ================================================================
:S2
ECHO.
ECHO ----- 2. a still in each of the camera's three modes
CAMSNAP /M=176 /O=CT176
IF ERRORLEVEL 1 GOTO F2A
IF NOT EXIST CT176.BMP GOTO F2A
ECHO PASS  2a 176x144 -- CT176.BMP
GOTO S2B
:F2A
ECHO FAIL  2a 176x144
ECHO SNAP176 >> CTFAIL.TXT
:S2B
CAMSNAP /M=320 /O=CT320
IF ERRORLEVEL 1 GOTO F2B
IF NOT EXIST CT320.BMP GOTO F2B
ECHO PASS  2b 320x240 -- CT320.BMP
GOTO S2C
:F2B
ECHO FAIL  2b 320x240
ECHO SNAP320 >> CTFAIL.TXT
:S2C
CAMSNAP /M=352 /O=CT352
IF ERRORLEVEL 1 GOTO F2C
IF NOT EXIST CT352.BMP GOTO F2C
ECHO PASS  2c 352x288 -- CT352.BMP
GOTO S3
:F2C
ECHO FAIL  2c 352x288
ECHO SNAP352 >> CTFAIL.TXT

REM ================================================================
:S3
ECHO.
ECHO ----- 3. the camera's button
IF "%1"=="AUTO" GOTO SKIP3
ECHO Listen for the beeps: a countdown, then THREE HIGH BEEPS -- then > CON
ECHO press the button on the camera a few times.  A long low beep: stop. > CON
CAMBTN /S=20
IF ERRORLEVEL 1 GOTO P3
ECHO ----  3 button NOT PRESSED -- nobody pressed it after the beeps
GOTO S4
:P3
ECHO PASS  3 button -- presses counted above
GOTO S4
:SKIP3
ECHO SKIP  3 button (AUTO)

REM ================================================================
:S4
ECHO.
ECHO ----- 4. every display, one picture each
ECHO Each view shows a picture for a few seconds and moves on. > CON
:T4
CAMLIVE /D=X /N=1 /H=3
IF ERRORLEVEL 1 GOTO F4X
ECHO PASS  4 mode X, 320x240
GOTO T4B
:F4X
ECHO FAIL  4 mode X
ECHO X >> CTFAIL.TXT
:T4B
CAMLIVE /D=13 /N=1 /H=3
IF ERRORLEVEL 1 GOTO F413
ECHO PASS  4 mode 13h
GOTO T4C
:F413
ECHO FAIL  4 mode 13h
ECHO 13H >> CTFAIL.TXT
:T4C
CAMLIVE /D=12 /N=1 /H=3
IF ERRORLEVEL 1 GOTO F412
ECHO PASS  4 mode 12h, 640x480 greys
GOTO T4D
:F412
ECHO FAIL  4 mode 12h
ECHO 12H >> CTFAIL.TXT
:T4D
CAMLIVE /D=T50 /N=1 /H=3
IF ERRORLEVEL 1 GOTO F4T5
ECHO PASS  4 80x50 text
GOTO T4E
:F4T5
ECHO FAIL  4 80x50 text
ECHO T50 >> CTFAIL.TXT
:T4E
CAMLIVE /D=T25 /C /N=1 /H=3
IF ERRORLEVEL 1 GOTO F4T2
ECHO PASS  4 80x25 text, colour
GOTO T4F
:F4T2
ECHO FAIL  4 80x25 text
ECHO T25 >> CTFAIL.TXT
:T4F
CAMLIVE /D=ASCII /N=1 /H=3
IF ERRORLEVEL 1 GOTO F4AS
ECHO PASS  4 ASCII
GOTO T4G
:F4AS
ECHO FAIL  4 ASCII
ECHO ASCII >> CTFAIL.TXT
:T4G
REM VESA 640x480 exists on some boots of some cards and not others, so
REM "not available" (exit 13) is a SKIP, not a failure
CAMLIVE /D=VESA /N=1 /H=3
IF ERRORLEVEL 14 GOTO F4VE
IF ERRORLEVEL 13 GOTO K4VE
IF ERRORLEVEL 1 GOTO F4VE
ECHO PASS  4 VESA 640x480
GOTO T4H
:K4VE
ECHO SKIP  4 VESA 640x480 -- not offered by the card this boot
GOTO T4H
:F4VE
ECHO FAIL  4 VESA
ECHO VESA >> CTFAIL.TXT
:T4H
CAMLIVE /M=176 /N=1 /H=3
IF ERRORLEVEL 1 GOTO F4M1
ECHO PASS  4 176x144 on the best display
GOTO T4I
:F4M1
ECHO FAIL  4 176x144 live
ECHO LIVE176 >> CTFAIL.TXT
:T4I
CAMLIVE /M=352 /N=1 /H=3
IF ERRORLEVEL 1 GOTO F4M3
ECHO PASS  4 352x288 on the best display
GOTO S5
:F4M3
ECHO FAIL  4 352x288 live
ECHO LIVE352 >> CTFAIL.TXT

REM ================================================================
:S5
ECHO.
ECHO ----- 5. the button saving a picture from the live view
IF "%1"=="AUTO" GOTO SKIP5
ECHO After THREE HIGH BEEPS, press the camera button ONCE.  A short chirp > CON
ECHO a few seconds later means the picture was saved. > CON
CAMLIVE /D=X /K /N=4 /H=3 /O=CTB
IF ERRORLEVEL 1 GOTO F5
IF NOT EXIST CTB1.BMP GOTO N5
ECHO PASS  5 button saved CTB1.BMP
GOTO DONE
:N5
ECHO ----  5 button NOT PRESSED -- the live view ran, nothing was saved
GOTO DONE
:F5
ECHO FAIL  5 the live view failed
ECHO BUTTONSAVE >> CTFAIL.TXT
GOTO DONE
:SKIP5
ECHO SKIP  5 button save (AUTO)

REM ================================================================
:DONE
ECHO.
IF NOT EXIST CTFAIL.TXT GOTO ALLOK
ECHO ===== FAILED:
TYPE CTFAIL.TXT
GOTO END
:ALLOK
ECHO ===== ALL PASSED
GOTO END

:NOEXE
ECHO CAMTEST: run this in the directory with CAMSNAP.EXE, CAMLIVE.EXE,
ECHO CAMBTN.EXE and FASTTEST.EXE.

:END
