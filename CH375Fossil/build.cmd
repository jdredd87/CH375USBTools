@echo off
REM  CH375Fossil -- build everything into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd test       ...then run the loopback suite on the DOS machine.
REM                         57 checks, and it needs no hardware at all
REM    build.cmd modem      ...then talk to a modem through the CH375
REM    build.cmd wdog       ...then prove the watchdog gives the packet
REM                         driver handles back when the application dies.
REM                         This takes the machine off the network for 75
REM                         seconds ON PURPOSE -- see the README
REM    build.cmd dosbuild   ...then assemble the driver on the DOS machine as
REM                         well, with MNASMFIX, and check the two images are
REM                         identical
REM
REM  NEEDS
REM    nasm   for the driver.  Ships with Free Pascal
REM    fpc    cross-compiling to MS-DOS real mode (-Tmsdos -Pi8086), for the
REM           test programs.  The DRIVER needs only nasm
REM
REM  The CH375 register layer is shared with CH375Mouse and lives in
REM  CH375USBTOOLS\src, so nasm is given -I for it.  chtool.pas comes from
REM  the same place with -Fu; its .ppu is compiled into THIS project's bin\,
REM  so the projects share source and never a compiled unit.
REM
REM  Every target that runs something on the DOS machine additionally needs
REM  DOSBridge to reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

echo --- FOSSIL.COM
nasm -f bin src\fossil.asm -o bin\FOSSIL.COM -I "src/" -I "%TOOLS%/"
if errorlevel 1 goto failed

for %%T in (fosdet fostest fosat fospkt fosbbs foswdog) do (
  echo --- %%T.exe
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -Fusrc -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)

echo.
echo Built bin\FOSSIL.COM and six test programs.

if /I "%1"=="test"     goto runtest
if /I "%1"=="modem"    goto runmodem
if /I "%1"=="wdog"     goto runwdog
if /I "%1"=="dosbuild" goto rundosbuild
exit /b 0

REM ----------------------------------------------------------------------
REM  The loopback suite.  No CH375, no packet driver, no modem: the driver
REM  feeds its own transmit ring back into its receive ring, which is what
REM  makes the whole INT 14h surface testable with nothing plugged in.
REM ----------------------------------------------------------------------
:runtest
echo.
echo --- loopback suite on the DOS machine
python "%DOSBRIDGE%\dosctl.py" deploy bin\FOSSIL.COM C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" deploy bin\FOSTEST.EXE C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" exec --timeout 300 "C:\WORK\FOSSIL.COM" "C:\WORK\FOSTEST.EXE" "C:\WORK\FOSSIL.COM /U"
exit /b %ERRORLEVEL%

REM ----------------------------------------------------------------------
:runmodem
echo.
echo --- modem through the CH375
python "%DOSBRIDGE%\dosctl.py" deploy bin\FOSSIL.COM C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" deploy bin\FOSAT.EXE C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" exec --timeout 400 "C:\WORK\FOSSIL.COM /C /D=19200" "C:\WORK\FOSAT.EXE" "C:\WORK\FOSSIL.COM /S" "C:\WORK\FOSSIL.COM /U"
exit /b %ERRORLEVEL%

REM ----------------------------------------------------------------------
REM  This one is its own proof.  FOSWDOG opens the line -- taking the packet
REM  driver's handles, which are the network DOSBridge reaches this machine
REM  over -- and then goes silent for 75 seconds.  If the watchdog works the
REM  handles come back on their own and this job's result is delivered.  If
REM  it does not, nothing is ever heard from the machine again.
REM ----------------------------------------------------------------------
:runwdog
echo.
echo --- watchdog: the machine goes off the network for 75 seconds
python "%DOSBRIDGE%\dosctl.py" deploy bin\FOSSIL.COM C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" deploy bin\FOSWDOG.EXE C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" exec --timeout 300 "C:\WORK\FOSSIL.COM /P /V=60 /I=192.168.50.66 /H=192.168.50.46" "C:\WORK\FOSWDOG.EXE" "C:\WORK\FOSSIL.COM /S" "C:\WORK\FOSSIL.COM /U"
exit /b %ERRORLEVEL%

REM ----------------------------------------------------------------------
REM  mininasm has NO include path -- -I does nothing -- so the shared
REM  includes have to go to C:\WORK with the source, and it has to be run
REM  FROM there with plain filenames.
REM ----------------------------------------------------------------------
:rundosbuild
echo.
echo --- assembling on the DOS machine
python "%DOSBRIDGE%\dosctl.py" deploy src\fossil.asm C:\WORK
if errorlevel 1 exit /b 1
for %%I in (ch375r.inc ch375i.inc pktr.inc tcpr.inc) do (
  python "%DOSBRIDGE%\dosctl.py" deploy "src\%%I" C:\WORK
  if errorlevel 1 exit /b 1
)
for %%I in (ch375def.inc ch375io.inc ch375ser.inc) do (
  python "%DOSBRIDGE%\dosctl.py" deploy "%TOOLS%\%%I" C:\WORK
  if errorlevel 1 exit /b 1
)
python "%DOSBRIDGE%\dosctl.py" deploy ..\CH375Mouse\tools\MNASMFIX.COM C:\WORK
if errorlevel 1 exit /b 1
python "%DOSBRIDGE%\dosctl.py" exec --timeout 500 "CD C:\WORK" "C:\WORK\MNASMFIX.COM -O9 -f bin -o FOSDOS.COM FOSSIL.ASM"
python "%DOSBRIDGE%\dosctl.py" pull C:\WORK\FOSDOS.COM --out bin\FOSDOS.COM
if errorlevel 1 exit /b 1
echo.
fc /b bin\FOSSIL.COM bin\FOSDOS.COM >nul
if errorlevel 1 goto dosdiff
echo IDENTICAL: nasm and MNASMFIX -O9 produce the same image.
del /q bin\FOSDOS.COM
exit /b 0

:dosdiff
echo DIFFERENT.  bin\FOSDOS.COM kept for comparison.
echo If mininasm was run without -O9 it leaves jumps in their long form.
exit /b 1

:failed
echo.
echo BUILD FAILED
exit /b 1
