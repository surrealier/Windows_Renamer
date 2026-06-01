@echo off
setlocal EnableExtensions
title win_rename uninstaller
echo(
echo  ============================================
echo    win_rename  -  uninstaller
echo  ============================================
echo(

REM 1) stop the running compiled app (if any)
taskkill /IM win_rename.exe /F >nul 2>&1
if %errorlevel%==0 (echo  [x] Stopped win_rename.exe) else (echo  [-] win_rename.exe was not running)

REM 2) remove the "Start with Windows" shortcut
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\win_rename.lnk"
if exist "%LNK%" (del /f /q "%LNK%" & echo  [x] Removed startup shortcut) else (echo  [-] No startup shortcut found)

REM 3) remove the registry marker
reg query "HKCU\Software\win_rename" >nul 2>&1
if %errorlevel%==0 (reg delete "HKCU\Software\win_rename" /f >nul 2>&1 & echo  [x] Removed registry key HKCU\Software\win_rename) else (echo  [-] No registry key found)

echo(
echo  win_rename has been removed from startup and the registry.
echo  ^(Using the .ahk script instead of the .exe? Just quit it from its tray icon: Exit.^)
echo(

REM 4) optionally delete the program file sitting next to this uninstaller
if not exist "%~dp0win_rename.exe" goto keep
choice /C YN /N /M "  Also delete win_rename.exe from this folder? [Y/N] "
if errorlevel 2 goto keep
del /f /q "%~dp0win_rename.exe" >nul 2>&1
echo  [x] Deleted win_rename.exe
echo(
echo  Fully uninstalled. Removing this uninstaller too...
timeout /t 2 >nul
(goto) 2>nul & del /f /q "%~f0"

:keep
echo(
echo  Done. Delete any remaining win_rename files manually if you wish.
echo(
pause
endlocal
