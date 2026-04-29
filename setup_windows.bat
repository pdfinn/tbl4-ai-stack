@echo off
REM Double-click this file to run setup on Windows.
REM It calls setup_windows.ps1 with an execution-policy bypass so there
REM is no need to change system settings or unblock the script.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "setup_windows.ps1"
echo.
pause
