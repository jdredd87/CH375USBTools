@echo off
REM  netdrv -- build PM2000.COM, the PicoMEM packet driver, from src\
REM
REM    build.cmd            assemble on the DOS box, link here -> bin\PM2000.COM
REM    build.cmd orig       the same from orig\, which must reproduce
REM                         orig\PM2000.COM byte for byte (the toolchain check)
REM
REM  NEEDS
REM    DOSBridge, with a DOS box that has Borland TASM at C:\BP\BIN\TASM.EXE.
REM      The source is Crynwr TASM/MASM syntax; NASM cannot read it, and TASM
REM      is what built the shipped binary, so it is what builds this one.
REM    tools\jwlink\JWlink.exe (Windows).  TLINK is a DPMI program and will not
REM      run on an 8086-class box, so the link happens here instead:
REM      https://github.com/Baron-von-Riedesel/jwlink/releases  (JWlinkb_v20_win32.zip)
REM    zip.exe on PATH, or the one Free Pascal ships.
REM
REM  Set DOSBOX to the box to assemble on (default v30) and DOSBRIDGE if the
REM  bridge is not in C:\dosbridge.
REM
REM  HW_INT_NO: TAIL.ASM declares it EXTRN and nothing defines or uses it.
REM  TLINK never saw it because TASM drops unreferenced externals; JWlink
REM  does see it, so the link runs with UNDEFSOK.  It is never referenced.

setlocal
cd /d "%~dp0"
if "%DOSBRIDGE%"=="" set DOSBRIDGE=C:\dosbridge
if "%DOSBOX%"=="" set DOSBOX=v30
set SRC=src
set OUT=bin
if /i "%1"=="orig" set SRC=orig
if /i "%1"=="orig" set OUT=build\orig
set ZIPEXE=zip.exe
where zip.exe >nul 2>nul || set ZIPEXE=C:\FPC\3.2.2\bin\i386-Win32\zip.exe
set DOSCTL=python "%DOSBRIDGE%\dosctl.py" --box %DOSBOX%

if not exist build mkdir build
if not exist %OUT% mkdir %OUT%
del /q build\PMSRC.ZIP build\*.OBJ 2>nul

pushd %SRC%
"%ZIPEXE%" -q -9 -X ..\build\PMSRC.ZIP *.ASM *.INC || (popd & goto fail)
popd

%DOSCTL% exec "IF NOT EXIST C:\PMNET\NUL MD C:\PMNET" "IF EXIST C:\PMNET\*.OBJ DEL C:\PMNET\*.OBJ" || goto fail
%DOSCTL% deploy "%~dp0build\PMSRC.ZIP" C:\PMNET || goto fail
%DOSCTL% exec --timeout 600 "CD C:\PMNET" "C:\SOFTWARE\PKZIP\PKUNZIP.EXE -o PMSRC.ZIP > NUL" "C:\BP\BIN\TASM.EXE HEAD" "C:\BP\BIN\TASM.EXE PM2000" "C:\BP\BIN\TASM.EXE TAIL" || goto fail
for %%F in (HEAD PM2000 TAIL) do (
  %DOSCTL% pull C:\PMNET\%%F.OBJ --out "%~dp0build\%%F.OBJ" || goto fail
)

tools\jwlink\JWlink.exe format dos com file build\HEAD.OBJ,build\PM2000.OBJ,build\TAIL.OBJ name %OUT%\PM2000.COM option map=%OUT%\PM2000.MAP,quiet,undefsok || goto fail
echo.
echo built %OUT%\PM2000.COM
if /i "%1"=="orig" fc /b %OUT%\PM2000.COM orig\PM2000.COM >nul && echo IDENTICAL to orig\PM2000.COM || if /i "%1"=="orig" echo DIFFERS from orig\PM2000.COM
exit /b 0

:fail
echo build FAILED
exit /b 1
