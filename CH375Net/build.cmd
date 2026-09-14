@echo off
REM  CH375Net -- USB Ethernet over a CH375, built into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then bring the adapter up on the DOS machine
REM    build.cmd trace      ...then bring it up printing every register
REM    build.cmd giga       ...then bring it up WITHOUT forcing 10BASE-T
REM    build.cmd recv       ...then watch frames arrive, promiscuous
REM    build.cmd raw        ...then watch them without interpreting the
REM                         buffer at all, hex only
REM    build.cmd send       ...then ARP the router and wait to be answered
REM    build.cmd ecm        ...then bring the adapter up as CDC-ECM and prove
REM                         it can TRANSMIT, by ARPing a host and being
REM                         answered.  Nothing in it is specific to the
REM                         adapter it was written against
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM
REM  The CH375 layer is ch375.pas and the banner/help convention is
REM  chtool.pas, both in ..\CH375USBTOOLS\src, found with -Fu.  Their .ppu
REM  files are compiled into THIS project's bin\, so the projects share
REM  source and never a compiled unit.
REM
REM  Every target that runs something on the DOS machine needs DOSBridge to
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.  USBGET and
REM  USBVFY also COMPILE against it, for its Net and Tftp units.
REM      https://github.com/jdredd87/DOSBridge

setlocal
cd /d "%~dp0"
REM  C:\dosbridgeDEV is the git repo and the one dosd runs from;
REM  C:\dosbridge is an older runtime copy whose CLAUDE.md is empty,
REM  so an assistant pointed at it starts with no project context.
REM  Prefer DEV when it is there, and let DOSBRIDGE override both.
if "%DOSBRIDGE%"=="" if exist C:\dosbridgeDEV\dosctl.py set DOSBRIDGE=C:\dosbridgeDEV
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

echo --- USBPKT.COM
nasm -f bin -Isrc\ src\usbpkt.asm -o bin\USBPKT.COM
if errorlevel 1 goto failed

for %%T in (netid usblink usbrecv usbsend pktscan pkttest pkttick rampchk ecmlink srlink dmprobe) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)

REM  USBGET and USBVFY drive the PACKET DRIVER rather than the CH375, so
REM  they link DOSBridge's own Net and Tftp units and need a second -Fu.
REM  They are the instruments the corruption hunt was measured with, not
REM  part of the adapter driver, which is why they build separately.
for %%T in (usbget usbvfy) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -Fu"%DOSBRIDGE%\starter" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
dir /b bin
echo.

if /I "%1"=="probe" goto runprobe
if /I "%1"=="trace" goto runtrace
if /I "%1"=="giga"  goto rungiga
if /I "%1"=="recv"  goto runrecv
if /I "%1"=="raw"   goto runraw
if /I "%1"=="send"  goto runsend
if /I "%1"=="ecm"   goto runecm
echo Built.  "build.cmd probe" brings the adapter up on the DOS machine.
exit /b 0

:runprobe
python "%DOSBRIDGE%\dosctl.py" run bin\USBLINK.EXE
exit /b %ERRORLEVEL%
:runtrace
python "%DOSBRIDGE%\dosctl.py" run bin\USBLINK.EXE /V
exit /b %ERRORLEVEL%
:rungiga
python "%DOSBRIDGE%\dosctl.py" run bin\USBLINK.EXE /G
exit /b %ERRORLEVEL%
:runrecv
python "%DOSBRIDGE%\dosctl.py" run bin\USBRECV.EXE /A /S=20
exit /b %ERRORLEVEL%
:runraw
python "%DOSBRIDGE%\dosctl.py" run bin\USBRECV.EXE /A /S=20 /N=3 /X /R
exit /b %ERRORLEVEL%
:runsend
python "%DOSBRIDGE%\dosctl.py" run bin\USBSEND.EXE
exit /b %ERRORLEVEL%
:runecm
REM  USBPKT owns the CH375 through a timer hook while it is loaded, so it has
REM  to be out of the way first -- two programs driving one chip is not a race
REM  anybody wins.  /U is harmless if it was never loaded.
python "%DOSBRIDGE%\dosctl.py" exec "C:\CH375\USBPKT.COM /U"
python "%DOSBRIDGE%\dosctl.py" run bin\ECMLINK.EXE
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
