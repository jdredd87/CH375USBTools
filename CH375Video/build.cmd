@echo off
REM  CH375Video -- USB display adapters over a CH375, built into bin\
REM  StevenC & Claude -- https://github.com/jdredd87/CH375USBTools
REM  Public domain (the Unlicense); see LICENSE.
REM
REM    build.cmd            build only
REM    build.cmd probe      ...then identify the adapter on the DOS machine
REM    build.cmd read       ...then probe it WITHOUT writing anything to it
REM    build.cmd bench      ...then measure throughput
REM    build.cmd demo       ...then run the bouncing-sprite demo
REM    build.cmd cube       ...then the rotating 3D wireframe cube
REM    build.cmd stars      ...then the starfield
REM    build.cmd bars       ...then the sliding colour bars
REM    build.cmd raster     ...then FULL-SCREEN raster bars
REM    build.cmd lowres     ...then the same at 320x200, which is the only
REM                         demo low resolution actually speeds up
REM    build.cmd con        ...then the text console demonstration page
REM    build.cmd life       ...then Conway's Life, which sends a delta
REM    build.cmd fract      ...then a Mandelbrot in fixed point
REM    build.cmd img        ...then C:\WORK\TEST.BMP scaled to fit
REM    build.cmd dash       ...then the colour dashboard
REM    build.cmd live       ...then the dashboard, reading the keyboard
REM    build.cmd trace      ...then probe it narrating every control stage
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
REM  reach it -- set DOSBRIDGE if it is not in C:\dosbridge.
REM      https://github.com/jdredd87/DOSBridge

setlocal
cd /d "%~dp0"
REM  C:\dosbridgeDEV is the git repo and the one dosd runs from;
REM  C:\dosbridge is an older runtime copy.  Prefer DEV when it is there,
REM  and let DOSBRIDGE override both.
if "%DOSBRIDGE%"=="" if exist C:\dosbridgeDEV\dosctl.py set DOSBRIDGE=C:\dosbridgeDEV
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
set TOOLS=%~dp0..\CH375USBTOOLS\src
if not exist bin mkdir bin

for %%T in (dlprobe dltest dlbench dldemo dlcon dlfract dlimg dlscr dldash) do (
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

if /I "%1"=="probe" goto runprobe
if /I "%1"=="read"  goto runread
if /I "%1"=="trace" goto runtrace
if /I "%1"=="bench" goto runbench
if /I "%1"=="demo"  goto rundemo
if /I "%1"=="cube"  goto runcube
if /I "%1"=="stars" goto runstars
if /I "%1"=="bars"  goto runbars
if /I "%1"=="raster" goto runraster
if /I "%1"=="lowres" goto runlowres
if /I "%1"=="con"   goto runcon
if /I "%1"=="fract" goto runfract
if /I "%1"=="img"   goto runimg
if /I "%1"=="dash"  goto rundash
if /I "%1"=="live"  goto runlive
if /I "%1"=="life"  goto runlife
echo Built.  "build.cmd probe" identifies whatever is plugged in.
exit /b 0

:runprobe
python "%DOSBRIDGE%\dosctl.py" run --timeout 300 bin\DLPROBE.EXE
exit /b %ERRORLEVEL%

REM  /K holds back the channel unlock, which is the only write DLPROBE
REM  makes.  Use this one when the adapter's state must not be disturbed.
:runread
python "%DOSBRIDGE%\dosctl.py" run --timeout 300 bin\DLPROBE.EXE -K
exit /b %ERRORLEVEL%

:runtrace
python "%DOSBRIDGE%\dosctl.py" run --timeout 300 bin\DLPROBE.EXE -V -T -E=4
exit /b %ERRORLEVEL%

:runbench
python "%DOSBRIDGE%\dosctl.py" run --timeout 500 bin\DLBENCH.EXE
exit /b %ERRORLEVEL%

:rundemo
python "%DOSBRIDGE%\dosctl.py" run --timeout 200 bin\DLDEMO.EXE -D=balls -S=20
exit /b %ERRORLEVEL%

:runcube
python "%DOSBRIDGE%\dosctl.py" run --timeout 200 bin\DLDEMO.EXE -D=cube -S=20
exit /b %ERRORLEVEL%

:runstars
python "%DOSBRIDGE%\dosctl.py" run --timeout 200 bin\DLDEMO.EXE -D=stars -S=20
exit /b %ERRORLEVEL%

:runbars
python "%DOSBRIDGE%\dosctl.py" run --timeout 200 bin\DLDEMO.EXE -D=bars -S=20
exit /b %ERRORLEVEL%

REM  The only demo that repaints the WHOLE screen, so the only one whose
REM  frame rate is set by the mode's pixel count rather than by how much
REM  of the picture moved.
:runraster
python "%DOSBRIDGE%\dosctl.py" run --timeout 200 bin\DLDEMO.EXE -D=raster -S=20
exit /b %ERRORLEVEL%

REM  The same effect at 320x200, which is 4.8x fewer pixels and about 3.5x
REM  the frame rate.  Letterboxed: the frame is padded to 449 lines to keep
REM  hsync above the 30 kHz a monitor wants.
:runlowres
python "%DOSBRIDGE%\dosctl.py" run --timeout 200 bin\DLDEMO.EXE -M=6 -D=raster -S=20
exit /b %ERRORLEVEL%

:runcon
python "%DOSBRIDGE%\dosctl.py" run --timeout 250 bin\DLCON.EXE -D -S=5
exit /b %ERRORLEVEL%

REM  The one tool here that is COMPUTE-bound rather than transfer-bound,
REM  and it times the two halves apart to prove it.
REM  The only demo that sends a DELTA rather than a picture, so its cost
REM  is the CHANGE and not the screen.
:runlife
python "%DOSBRIDGE%\dosctl.py" run --timeout 250 bin\DLDEMO.EXE -D=life -S=25
exit /b %ERRORLEVEL%

REM  Needs a BMP on the DOS box first:
REM     dosdeploy PICTURE.BMP C:\WORK
REM  Keep it small -- a 3 MB file wedged the transport.
REM  The dirty-tracking colour screen: panels, gauges, a ticker.
:rundash
python "%DOSBRIDGE%\dosctl.py" run --timeout 300 bin\DLDASH.EXE -S=60
exit /b %ERRORLEVEL%

REM  The same, reading the machine's OWN keyboard: TAB / +- / L / R / ESC.
:runlive
python "%DOSBRIDGE%\dosctl.py" run --timeout 400 bin\DLDASH.EXE -K -S=180
exit /b %ERRORLEVEL%

:runimg
python "%DOSBRIDGE%\dosctl.py" run --timeout 400 bin\DLIMG.EXE C:\WORK\TEST.BMP -S=8
exit /b %ERRORLEVEL%

:runfract
python "%DOSBRIDGE%\dosctl.py" run --timeout 400 bin\DLFRACT.EXE -W=160 -I=16 -S=5
exit /b %ERRORLEVEL%

:failed
echo.
echo BUILD FAILED
exit /b 1
