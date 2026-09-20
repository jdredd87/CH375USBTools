@echo off
REM  PicoMEM2 -- build the PicoMEM card tools into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then PMPROBE on the DOS machine
REM    build.cmd usb        ...then PMUSB watching the USB host for 30 s
REM    build.cmd dump       ...then PMDUMP, and fetch PMDUMP.BIN here
REM    build.cmd tick       ...then PMTICK: the PC clock around a command
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  Every target that runs something on the DOS machine needs DOSBridge to
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge
REM
REM  THE PICOMEM MAY BE THE BOOT DISK.  These tools send the card only
REM  three read-only queries, enforced in pmcard.pas -- read its header
REM  before adding a command.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

for %%T in (pmprobe pmusb pmdump pmcmdt pmtick) do (
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

:runprobe
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMPROBE.EXE
exit /b %ERRORLEVEL%

:runusb
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMUSB.EXE /S=30
exit /b %ERRORLEVEL%

:rundump
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMDUMP.EXE C:\WORK\PMDUMP.BIN
if errorlevel 1 exit /b %ERRORLEVEL%
python "%DOSBRIDGE%\dosctl.py" pull C:\WORK\PMDUMP.BIN --out PMDUMP.BIN
exit /b %ERRORLEVEL%

:runtick
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMTICK.EXE
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
