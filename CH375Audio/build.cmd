@echo off
REM  CH375Audio -- build the USB audio tools into bin\
REM  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then decode the attached audio device
REM    build.cmd vol        ...then read the mixer out
REM    build.cmd mute       ...mute, pause, unmute
REM    build.cmd ramp       ...sweep the volume end to end
REM    build.cmd keys       ...watch the speaker's own buttons
REM    build.cmd iso        ...demonstrate why playback cannot work
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

for %%T in (daprobe davol dakeys daiso) do (
  echo --- %%T
  fpc -Tmsdos -Pi8086 -WmLarge -Fu"%TOOLS%" -FEbin -FUbin src\%%T.pas >nul
  if errorlevel 1 goto failed
)

REM  The .a/.o/.ppu are intermediates; bin\ is what ships, so keep it to
REM  the four EXEs. .gitignore covers these too, belt and braces.
if exist bin\*.a   del /q bin\*.a
if exist bin\*.o   del /q bin\*.o
if exist bin\*.ppu del /q bin\*.ppu

echo.
echo built into bin\
if "%1"=="" exit /b 0
goto run%1

:runprobe
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\DAPROBE.EXE
exit /b %ERRORLEVEL%

:runvol
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\DAVOL.EXE
exit /b %ERRORLEVEL%

:runmute
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\DAVOL.EXE /M=1 /W=3 /M=0
exit /b %ERRORLEVEL%

:runramp
python "%DOSBRIDGE%\dosctl.py" run --timeout 180 bin\DAVOL.EXE /RAMP
exit /b %ERRORLEVEL%

:runkeys
python "%DOSBRIDGE%\dosctl.py" run --timeout 180 bin\DAKEYS.EXE /S=60
exit /b %ERRORLEVEL%

:runiso
python "%DOSBRIDGE%\dosctl.py" run --timeout 120 bin\DAISO.EXE
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
