@echo off
REM  CH375Serial -- build the USB-to-serial tools into bin\
REM  StevenC -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then identify the attached adapter
REM    build.cmd bulk       ...select the bulk configuration and report
REM    build.cmd watch      ...and poll the status pipe for 20 seconds
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

for %%T in (serprobe sertalk serterm) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)

REM  Intermediates; bin\ is what ships.
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
echo built into bin\
if "%1"=="" exit /b 0
goto run%1

:runprobe
python "%DOSBRIDGE%\dosctl.py" run --timeout 150 bin\SERPROBE.EXE
exit /b %ERRORLEVEL%

REM  Configuration INDEX 1 on the reference adapter is the one whose IN
REM  endpoints are bulk rather than interrupt. See the README.
:runbulk
python "%DOSBRIDGE%\dosctl.py" run --timeout 150 bin\SERPROBE.EXE /C=1
exit /b %ERRORLEVEL%

:runwatch
python "%DOSBRIDGE%\dosctl.py" run --timeout 250 bin\SERPROBE.EXE /C=1 /S=20
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1

:runtalk
python "%DOSBRIDGE%\dosctl.py" run --timeout 250 bin\SERTALK.EXE /X
exit /b %ERRORLEVEL%

:runloop
python "%DOSBRIDGE%\dosctl.py" run --timeout 250 bin\SERTALK.EXE /L /X
exit /b %ERRORLEVEL%

:runsweep
python "%DOSBRIDGE%\dosctl.py" run --timeout 450 bin\SERTALK.EXE /W
exit /b %ERRORLEVEL%

:runlines
python "%DOSBRIDGE%\dosctl.py" run --timeout 250 bin\SERTALK.EXE /M
exit /b %ERRORLEVEL%

:runterm
python "%DOSBRIDGE%\dosctl.py" run --timeout 300 bin\SERTERM.EXE /I=ATI7 /S=20
exit /b %ERRORLEVEL%
