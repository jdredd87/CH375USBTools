@echo off
REM  emm -- build PMEMM.EXE, the PicoMEM EMS driver, from src\
REM  StevenC & Claude, 2026
REM
REM    build.cmd            assemble on the DOS box, link here -> bin\PMEMM.EXE
REM    build.cmd orig       the same from orig\, which must reproduce the load
REM                         image of the shipped orig\PMEMM.EXE byte for byte
REM
REM  NEEDS  the same as ..\netdrv\build.cmd: DOSBridge, Borland TASM on the
REM  DOS box at C:\BP\BIN\TASM.EXE, and JWlink in ..\netdrv\tools\jwlink\.
REM  Set DOSBOX (default v30) and DOSBRIDGE (default C:\dosbridge).

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
if "%DOSBOX%"=="" set DOSBOX=v30
set SRC=src
set OUT=bin
set TASMOPT=/m2
if /i "%1"=="orig" set SRC=orig
if /i "%1"=="orig" set OUT=build\orig
REM  the shipped binary was assembled in ONE pass: its forward jumps carry NOP padding
if /i "%1"=="orig" set TASMOPT=
set ZIPEXE=zip.exe
where zip.exe >nul 2>nul || set ZIPEXE=C:\FPC\3.2.2\bin\i386-Win32\zip.exe
set DOSCTL=python "%DOSBRIDGE%\dosctl.py" --box %DOSBOX%
set JWLINK=..\netdrv\tools\jwlink\JWlink.exe

if not exist build mkdir build
if not exist %OUT% mkdir %OUT%
del /q build\EMSRC.ZIP build\PMEMM.OBJ 2>nul

pushd %SRC%
"%ZIPEXE%" -q -9 -X ..\build\EMSRC.ZIP PMEMM.ASM PMEMM.INC LTEMM.MAC || (popd & goto fail)
popd

%DOSCTL% exec "IF NOT EXIST C:\PMEMM\NUL MD C:\PMEMM" "IF EXIST C:\PMEMM\PMEMM.OBJ DEL C:\PMEMM\PMEMM.OBJ" || goto fail
%DOSCTL% deploy "%~dp0build\EMSRC.ZIP" C:\PMEMM || goto fail
%DOSCTL% exec --timeout 600 "CD C:\PMEMM" "C:\SOFTWARE\PKZIP\PKUNZIP.EXE -o EMSRC.ZIP > NUL" "C:\BP\BIN\TASM.EXE %TASMOPT% PMEMM" || goto fail
%DOSCTL% pull C:\PMEMM\PMEMM.OBJ --out "%~dp0build\PMEMM.OBJ" || goto fail

%JWLINK% format dos file build\PMEMM.OBJ name %OUT%\PMEMM.EXE option map=%OUT%\PMEMM.MAP,quiet || goto fail
echo.
echo built %OUT%\PMEMM.EXE
python cmpimg.py --sys %OUT%\PMEMM.EXE %OUT%\PMEMM.SYS || goto fail
if /i "%1"=="orig" python cmpimg.py %OUT%\PMEMM.EXE orig\PMEMM.EXE
exit /b 0

:fail
echo build FAILED
exit /b 1
