@echo off
REM  CH375Combo -- build the combined keyboard+mouse driver into bin\
REM  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd test       ...then run the driver's own /T self-test on the
REM                         DOS machine.  Needs no keypress and no mouse
REM    build.cmd suite      ...then load it, run COMBOTST, unload
REM    build.cmd trace      ...then bring it up with /V, report /S, unload
REM    build.cmd watch      ...then watch the mouse endpoint for 20 seconds.
REM                         MOVE THE MOUSE while it runs -- this is the one
REM                         thing the automated tests cannot check
REM    build.cmd load       ...then just load it and leave it resident
REM    build.cmd status     ...then report on the copy already loaded
REM    build.cmd unload     ...then unload the copy already loaded
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
REM  The shared ch375 unit lives in CH375USBTOOLS next door and is found
REM  with -Fu.  Its .ppu is compiled into THIS project's bin\, so the two
REM  projects never share a compiled unit -- only the source.
REM
REM  ALWAYS UNLOAD BEFORE DEPLOYING A NEW BUILD.  The version string does
REM  not change between development builds, so two different images that
REM  both say 1.0.0 pass the /S and /U version check and then read each
REM  other's data at the wrong offsets.  Every target below that loads the
REM  driver unloads any previous copy first, for exactly that reason.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

echo --- USBCOMBO.COM
nasm -f bin src\usbcombo.asm -o bin\USBCOMBO.COM
if errorlevel 1 goto failed

for %%T in (combotst) do (
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

if /I "%1"=="test"   goto runtest
if /I "%1"=="suite"  goto runsuite
if /I "%1"=="trace"  goto runtrace
if /I "%1"=="watch"  goto runwatch
if /I "%1"=="load"   goto runload
if /I "%1"=="status" goto runstatus
if /I "%1"=="unload" goto rununload
echo Built.  "build.cmd test" runs the self-test; "build.cmd suite" the rest.
exit /b 0

:runtest
call :push USBCOMBO.COM
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /U"
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /T"
exit /b %ERRORLEVEL%

:runsuite
call :push USBCOMBO.COM
call :push COMBOTST.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /U"
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM" "C:\WORK\COMBOTST.EXE" "C:\WORK\USBCOMBO.COM /U"
exit /b %ERRORLEVEL%

:runtrace
call :push USBCOMBO.COM
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /U"
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /V" "C:\WORK\USBCOMBO.COM /S" "C:\WORK\USBCOMBO.COM /U"
exit /b %ERRORLEVEL%

:runwatch
call :push USBCOMBO.COM
call :push COMBOTST.EXE
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /U"
echo.
echo MOVE THE MOUSE while this runs.  A real boot report is three bytes;
echo anything five bytes long is the chip inventing one.  See the README.
echo.
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM" "C:\WORK\COMBOTST.EXE /W=20" "C:\WORK\USBCOMBO.COM /U"
exit /b %ERRORLEVEL%

:runload
call :push USBCOMBO.COM
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /U"
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /V"
exit /b %ERRORLEVEL%

:runstatus
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /S"
exit /b %ERRORLEVEL%

:rununload
python "%DOSBRIDGE%\dosctl.py" exec "C:\WORK\USBCOMBO.COM /U"
exit /b %ERRORLEVEL%

:push
python "%DOSBRIDGE%\dosctl.py" deploy bin\%1 C:\WORK
if errorlevel 1 exit /b 1
goto :eof

:failed
echo.
echo BUILD FAILED
exit /b 1
