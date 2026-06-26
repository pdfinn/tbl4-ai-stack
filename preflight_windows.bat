@echo off
REM Right-click this file and choose "Run as administrator".
REM It runs preflight_windows.ps1, which enables WSL2 + the required
REM Windows features and updates the WSL kernel. The .ps1 will prompt
REM for elevation itself if you forget, so a plain double-click also works.
setlocal
cd /d "%~dp0"
set "PS1=%~dp0preflight_windows.ps1"
if not exist "%PS1%" (
    echo.
    echo [ERR] Could not find preflight_windows.ps1 next to this file.
    echo       Expected: %PS1%
    echo.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
pause
