@echo off
REM  CH375Mouse -- build everything into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd test       ...then run the INT 33h and event-handler suites
REM                         on the DOS machine
REM    build.cmd diag       ...then run the CH375 diagnostic there
REM    build.cmd ps2        ...then run the PS/2 BIOS emulation test
REM    build.cmd demo       ...then drive the on-screen cursor for 25 seconds
REM    build.cmd click      ...then watch the button path for 30 seconds.
REM                         Click the mouse while it runs; it beeps at you.
REM    build.cmd dosbuild   ...then assemble the driver on the DOS machine as
REM                         well, with tools\MNASMFIX.COM, and check the two
REM                         images are identical
REM
REM  NEEDS
REM    fpc    Free Pascal cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086)
REM    nasm   ships with Free Pascal; both must be on PATH
REM
REM  The build needs nothing else.  Every target that runs something on the
REM  DOS machine additionally needs DOSBridge to reach it -- set DOSBRIDGE if
REM  it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge
REM
REM  The driver also assembles on the DOS machine itself, byte for byte
REM  identically, using the patched mininasm in tools\:
REM    MNASMFIX -O9 -f bin -o USBMOUSE.COM USBMOUSE.ASM
REM  -O9 matters; without it some jumps stay in their long form.
REM
REM  The CH375 register primitives, the SET_RETRY split and the USB
REM  transfer helpers now live in CH375USBTOOLS\src and are shared with
REM  DOSBridge's FOSSIL driver, so nasm is given -I for them. Assembling
REM  on the DOS box needs those three .inc files beside the .asm.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
REM  chtool.pas -- the shared banner, version and /? convention -- lives in
REM  CH375USBTOOLS\src and is found with -Fu.  Its .ppu is compiled into
REM  THIS project's bin\, so the projects share source and never a
REM  compiled unit.
set TOOLS=%~dp0..\CH375USBTOOLS\src
REM  dser.pas -- the USB-to-serial adapter layer -- lives in CH375Serial
REM  and is shared rather than copied, for the reason the serial mouse
REM  tools exist at all: the mouse half must not know which adapter it
REM  is behind.
set SERIAL=%~dp0..\CH375Serial\src
if not exist bin mkdir bin

echo --- USBMOUSE.COM
nasm -f bin src\usbmouse.asm -o bin\USBMOUSE.COM -I "%TOOLS%/"
if errorlevel 1 goto failed

for %%T in (chdiag mousetst evtest ps2test tickchk clkchk mdemo clicktst) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)


REM  The SERIAL mouse tools.  They need dser as well, so they build in their
REM  own pass rather than widening the -Fu of everything above.
for %%T in (mouprobe) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -Fu"%SERIAL%" -Fusrc -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)

if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
dir /b bin
echo.

if /I "%1"=="test"     goto runtest
if /I "%1"=="diag"     goto rundiag
if /I "%1"=="ps2"      goto runps2
if /I "%1"=="demo"     goto rundemo
if /I "%1"=="click"    goto runclick
if /I "%1"=="dosbuild" goto rundosbuild
echo Built.  "build.cmd test" runs the suites on the DOS machine.
exit /b 0

:runtest
call :push USBMOUSE.COM
call :push MOUSETST.EXE
call :push EVTEST.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM" "C:\WORK\MOUSETST.EXE" "C:\WORK\EVTEST.EXE" "C:\WORK\USBMOUSE.COM /U"
exit /b %ERRORLEVEL%

:rundiag
python "%DOSBRIDGE%\dosctl.py" run bin\CHDIAG.EXE
exit /b %ERRORLEVEL%

:runps2
call :push USBMOUSE.COM
call :push PS2TEST.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM /W" "C:\WORK\PS2TEST.EXE 8" "C:\WORK\USBMOUSE.COM /U"
exit /b %ERRORLEVEL%

:rundemo
call :push USBMOUSE.COM
call :push MDEMO.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM" "C:\WORK\MDEMO.EXE 25" "C:\WORK\USBMOUSE.COM /U"
exit /b %ERRORLEVEL%

:runclick
call :push USBMOUSE.COM
call :push CLICKTST.EXE
echo.
echo Click the mouse while this runs -- it beeps when it starts watching.
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBMOUSE.COM" "C:\WORK\CLICKTST.EXE 30" "C:\WORK\USBMOUSE.COM /U" --timeout 240
exit /b %ERRORLEVEL%

REM  Assemble the driver on the DOS machine with the patched mininasm and
REM  prove the image matches the one nasm just built.  Two assemblers, two
REM  machines, one binary -- the check is the point, not the build.
:rundosbuild
echo --- assembling on the DOS machine
python "%DOSBRIDGE%\dosctl.py" deploy src\usbmouse.asm C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" deploy tools\MNASMFIX.COM C:\WORK
if errorlevel 1 exit /b 1
REM  The CH375 layer is shared and lives in CH375USBTOOLS\src. mininasm has
REM  NO include path -- -I does nothing -- so the includes must go to C:\WORK
REM  too, and it has to run FROM there with plain filenames rather than the
REM  absolute ones this used to pass.
for %%I in (ch375def.inc ch375io.inc ch375ser.inc) do (
  python "%DOSBRIDGE%\dosctl.py" deploy "%TOOLS%\%%I" C:\WORK
  if errorlevel 1 exit /b 1
)
python "%DOSBRIDGE%\dosctl.py" exec "CD C:\WORK" "C:\WORK\MNASMFIX.COM -O9 -f bin -o UMDOS.COM USBMOUSE.ASM"
python "%DOSBRIDGE%\dosctl.py" pull C:\WORK\UMDOS.COM --out bin\UMDOS.COM
if errorlevel 1 exit /b 1
echo.
fc /b bin\USBMOUSE.COM bin\UMDOS.COM >nul
if errorlevel 1 goto dosdiff
echo IDENTICAL: nasm and MNASMFIX -O9 produce the same image.
del /q bin\UMDOS.COM
exit /b 0
:dosdiff
echo DIFFERENT.  bin\UMDOS.COM kept for comparison.
echo If mininasm was run without -O9 it leaves jumps in their long form.
exit /b 1

:push
python "%DOSBRIDGE%\dosctl.py" deploy bin\%1 C:\WORK
if errorlevel 1 exit /b 1
goto :eof

:failed
echo.
echo BUILD FAILED
exit /b 1
