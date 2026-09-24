@echo off
REM  CH375USBTOOLS -- build every probe tool into bin\
REM  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd info       ...then probe whatever is plugged into the card
REM    build.cmd scan       ...then look for the card itself
REM    build.cmd hid        ...then decode the HID report descriptor
REM    build.cmd poll       ...then watch the first interrupt IN endpoint
REM    build.cmd reg        ...then dump the chip's register map
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  The build needs nothing else.  Every target that runs something on the
REM  DOS machine additionally needs DOSBridge to reach it -- set DOSBRIDGE if
REM  it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
if not exist bin mkdir bin

for %%T in (usbinfo hidrep usbpoll usbctl chreg usbscan usbmon) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
dir /b bin
echo.

if /I "%1"=="info" goto runinfo
if /I "%1"=="scan" goto runscan
if /I "%1"=="hid"  goto runhid
if /I "%1"=="poll" goto runpoll
if /I "%1"=="reg"  goto runreg
echo Built.  "build.cmd info" probes whatever is plugged in.
exit /b 0

:runinfo
python "%DOSBRIDGE%\dosctl.py" run bin\USBINFO.EXE
exit /b %ERRORLEVEL%
:runscan
python "%DOSBRIDGE%\dosctl.py" run bin\USBSCAN.EXE /D
exit /b %ERRORLEVEL%
:runhid
python "%DOSBRIDGE%\dosctl.py" run bin\HIDREP.EXE
exit /b %ERRORLEVEL%
:runpoll
python "%DOSBRIDGE%\dosctl.py" run bin\USBPOLL.EXE /S=20 /R=25
exit /b %ERRORLEVEL%
:runreg
python "%DOSBRIDGE%\dosctl.py" run bin\CHREG.EXE /U
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
