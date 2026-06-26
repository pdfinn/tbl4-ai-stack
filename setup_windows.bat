@echo off
REM Double-click this file to run setup on Windows.
REM It calls setup_windows.ps1 with an execution-policy bypass so there
REM is no need to change system settings or unblock the script.
REM
REM EnableDelayedExpansion + !PS1! (not %PS1%) inside the if block: when
REM the script lives under a path containing parentheses -- e.g. Windows'
REM auto-suffixed re-download path "tbl4-ai-stack-master (2)\..." -- the
REM literal '(' in the expanded variable collides with the if (...) block
REM delimiters and cmd bails out with "...setup_windows.ps1 was unexpected
REM at this time."
setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM Resolve the script next to THIS .bat using an absolute path. A relative
REM -File path breaks when the shell's working directory isn't the repo
REM folder (a common cause of "the argument ... does not exist").
set "PS1=%~dp0setup_windows.ps1"
if not exist "!PS1!" (
    echo.
    echo [ERR] Could not find setup_windows.ps1 next to this file.
    echo       Expected: !PS1!
    echo.
    echo This usually means the ZIP was extracted into a nested folder.
    echo Open the folder that actually contains setup_windows.ps1 and run
    echo setup_windows.bat from there.
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!PS1!"
echo.
pause
