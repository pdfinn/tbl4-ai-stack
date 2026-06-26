@echo off
REM EnableDelayedExpansion + !PS1! (not %PS1%) inside the if block so
REM parentheses in the install path don't collide with the if (...) block
REM delimiters. See the matching comment in setup_windows.bat.
setlocal EnableDelayedExpansion
cd /d "%~dp0"
set "PS1=%~dp0teardown_windows.ps1"
if not exist "!PS1!" (
    echo.
    echo [ERR] Could not find teardown_windows.ps1 next to this file.
    echo       Expected: !PS1!
    echo.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!PS1!"
echo.
pause
