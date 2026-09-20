@echo off
REM  PicoMEM1 -- build the PicoMEM 1.x card tools into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd info       ...then PM1INFO on the DOS machine
REM    build.cmd cfg        ...then PM1CFG, the whole configuration
REM    build.cmd mem        ...then PM1MEM, the live memory map
REM    build.cmd dev        ...then PM1DEV, the emulated devices
REM    build.cmd stat       ...then PM1STAT, the USB and disk answers
REM    build.cmd opl        ...then PM1OPL, a scale through the card AdLib
REM    build.cmd bench      ...then PM1BENCH, command and memory timing
REM    build.cmd dump       ...then PM1DUMP, and fetch PM1DUMP.BIN here
REM    build.cmd mouse      ...then PM1MOUSE, watching a USB mouse for 15 s
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  Every target that runs something on the DOS machine needs DOSBridge to
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge
REM
REM  THE PICOMEM MAY BE THE BOOT DISK.  These tools send the card only
REM  read-only queries, enforced in pm1card.pas -- read its header before
REM  adding a command.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

for %%T in (pm1info pm1cfg pm1mem pm1dev pm1stat pm1opl pm1bench pm1dump pm1mouse) do (
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
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PM1INFO.EXE
exit /b %ERRORLEVEL%

:runcfg
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PM1CFG.EXE
exit /b %ERRORLEVEL%

:runmem
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PM1MEM.EXE
exit /b %ERRORLEVEL%

:rundev
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PM1DEV.EXE
exit /b %ERRORLEVEL%

:runstat
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PM1STAT.EXE
exit /b %ERRORLEVEL%

:runopl
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PM1OPL.EXE
exit /b %ERRORLEVEL%

:runbench
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PM1BENCH.EXE
exit /b %ERRORLEVEL%

:runmouse
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\PM1MOUSE.EXE /S=15
exit /b %ERRORLEVEL%

:rundump
python "%DOSBRIDGE%\dosctl.py" run --timeout 90 bin\PM1DUMP.EXE C:\WORK\PM1DUMP.BIN
if errorlevel 1 exit /b %ERRORLEVEL%
python "%DOSBRIDGE%\dosctl.py" pull C:\WORK\PM1DUMP.BIN --out PM1DUMP.BIN
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
