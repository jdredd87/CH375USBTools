@echo off
REM  CH375Camera -- build the IBM PC Camera tools into bin\
REM  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd snap       ...then take a 320x240 colour still, fetch SNAP.BMP
REM    build.cmd live       ...then five minutes of pictures on the screen
REM    build.cmd text       ...the same in 80x50 text
REM    build.cmd ascii      ...one picture, printed back here as ASCII art
REM    build.cmd button     ...30 s watching for the camera's button
REM    build.cmd probe      ...the raw isochronous probe
REM    build.cmd test       ...check the assembly against Pascal on the box
REM    build.cmd alltests   ...copy everything to C:\WORK\CAM and run
REM                         CAMTEST AUTO there: every test that needs
REM                         nobody at the keyboard.  At the keyboard,
REM                         plain CAMTEST also does the button
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  The CH375 layer is ch375.pas in ..\CH375USBTOOLS\src, found with -Fu.
REM  Its .ppu is compiled into THIS project's bin\, so the two projects
REM  share source and never a compiled unit.
REM
REM  Every target that runs something on the DOS machine needs DOSBridge to
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

for %%T in (camsnap camlive cambtn camprobe camcal fasttest) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)

if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
echo built into bin\
if "%1"=="" exit /b 0
goto run%1

:runsnap
python "%DOSBRIDGE%\dosctl.py" run --timeout 180 bin\CAMSNAP.EXE /O=C:\WORK\SNAP
if errorlevel 1 exit /b %ERRORLEVEL%
python "%DOSBRIDGE%\dosctl.py" pull C:\WORK\SNAP.BMP --out SNAP.BMP
exit /b %ERRORLEVEL%

:runlive
python "%DOSBRIDGE%\dosctl.py" run --timeout 400 bin\CAMLIVE.EXE /S=300
exit /b %ERRORLEVEL%

:runtext
python "%DOSBRIDGE%\dosctl.py" run --timeout 400 bin\CAMLIVE.EXE /D=T50 /S=300
exit /b %ERRORLEVEL%

:runascii
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\CAMLIVE.EXE /D=ASCII /N=1 /H=0 /A
exit /b %ERRORLEVEL%

:runbutton
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\CAMBTN.EXE /S=30
exit /b %ERRORLEVEL%

:runprobe
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\CAMPROBE.EXE /N=1000 /D=2
exit /b %ERRORLEVEL%

:runalltests
python "%DOSBRIDGE%\dosctl.py" exec "IF NOT EXIST C:\WORK\CAM\NUL MD C:\WORK\CAM"
for %%F in (CAMSNAP CAMLIVE CAMBTN FASTTEST) do (
  python "%DOSBRIDGE%\dosctl.py" deploy bin\%%F.EXE C:\WORK\CAM
  if errorlevel 1 exit /b 1
)
python "%DOSBRIDGE%\dosctl.py" deploy bin\CAMTEST.BAT C:\WORK\CAM
if errorlevel 1 exit /b 1
REM  COMMAND /C, not the batch by name: a batch named in a batch never
REM  returns (so the result is never sent), and a batch's own output
REM  ignores redirection -- CALL CAMTEST came back empty.  A child
REM  COMMAND.COM runs it to the end with everything captured.
python "%DOSBRIDGE%\dosctl.py" exec --timeout 900 "CD C:\WORK\CAM" "COMMAND /C CAMTEST AUTO"
exit /b %ERRORLEVEL%

:runtest
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\FASTTEST.EXE
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
