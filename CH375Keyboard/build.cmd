@echo off
REM  CH375Keyboard -- build the driver and its tools into bin\
REM  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd raw        ...then watch reports without loading anything
REM    build.cmd test       ...then load the driver, run KBDTST, unload
REM    build.cmd load       ...then load the driver and leave it resident
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM    nasm   ships with Free Pascal; both must be on PATH
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

echo --- USBKBD.COM
nasm -f bin src\usbkbd.asm -o bin\USBKBD.COM
if errorlevel 1 goto failed

echo --- I16SPY.COM
nasm -f bin src\i16spy.asm -o bin\I16SPY.COM

for %%T in (kbdraw kbdtst kbdbios kbcinj kbd16) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
dir /b bin
echo.

if /I "%1"=="raw"  goto runraw
if /I "%1"=="test" goto runtest
if /I "%1"=="load" goto runload
echo Built.  "build.cmd raw" watches reports without loading anything.
exit /b 0

:runraw
python "%DOSBRIDGE%\dosctl.py" run bin\KBDRAW.EXE /S=25 /R=25 /L
exit /b %ERRORLEVEL%

REM  Staged with `run` rather than `deploy` so a single command both copies
REM  and proves the binary works; /S does not go resident.
:runtest
python "%DOSBRIDGE%\dosctl.py" run bin\USBKBD.COM /S >nul
python "%DOSBRIDGE%\dosctl.py" run bin\KBDTST.EXE /Q >nul
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBKBD.COM" "C:\WORK\KBDTST.EXE" "C:\WORK\USBKBD.COM /U" --timeout 200
exit /b %ERRORLEVEL%

:runload
python "%DOSBRIDGE%\dosctl.py" run bin\USBKBD.COM /V
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
