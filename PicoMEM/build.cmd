@echo off
REM  PicoMEM -- build the PicoMEM card tools into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd info       ...then PMINFO on the DOS machine
REM    build.cmd cfg        ...then PMCFG, the whole configuration
REM    build.cmd mem        ...then PMMEM, the live memory map
REM    build.cmd dev        ...then PMDEV, the emulated devices
REM    build.cmd stat       ...then PMSTAT, the USB and disk answers
REM    build.cmd opl        ...then PMOPL, a scale through the card AdLib
REM    build.cmd bench      ...then PMBENCH, command and memory timing
REM    build.cmd mouse      ...then PMMTEST, watching a USB mouse
REM    build.cmd watch      ...then PMWATCH, every byte of shared memory
REM    build.cmd dump       ...then PMDUMP, and fetch PMDUMP.BIN here
REM    build.cmd tick       ...then PMTICK: the PC clock around a command
REM    build.cmd cmdt       ...then PMCMDT: N queries in a row
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  Every target that runs something on the DOS machine needs DOSBridge to
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge
REM
REM  THE PICOMEM IS THE BOOT DISK.  These tools send it read-only queries
REM  and two mouse switches, enforced in pmcard.pas -- read its header
REM  before adding a command.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

for %%T in (pminfo pmcfg pmmem pmdev pmstat pmopl pmbench pmdump pmmtest pmwatch pmcmdt pmtick) do (
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

:runinfo
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMINFO.EXE
exit /b %ERRORLEVEL%
:runcfg
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMCFG.EXE
exit /b %ERRORLEVEL%
:runmem
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PMMEM.EXE
exit /b %ERRORLEVEL%
:rundev
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMDEV.EXE
exit /b %ERRORLEVEL%
:runstat
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMSTAT.EXE
exit /b %ERRORLEVEL%
:runopl
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PMOPL.EXE
exit /b %ERRORLEVEL%
:runbench
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PMBENCH.EXE
exit /b %ERRORLEVEL%
:runmouse
python "%DOSBRIDGE%\dosctl.py" run --timeout 150 bin\PMMTEST.EXE /S=20
exit /b %ERRORLEVEL%
:runwatch
python "%DOSBRIDGE%\dosctl.py" run --timeout 150 bin\PMWATCH.EXE /T /S=20
exit /b %ERRORLEVEL%
:runtick
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMTICK.EXE
exit /b %ERRORLEVEL%
:runcmdt
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PMCMDT.EXE
exit /b %ERRORLEVEL%
:rundump
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PMDUMP.EXE C:\WORK\PMDUMP.BIN
if errorlevel 1 exit /b %ERRORLEVEL%
python "%DOSBRIDGE%\dosctl.py" pull C:\WORK\PMDUMP.BIN --out PMDUMP.BIN
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
