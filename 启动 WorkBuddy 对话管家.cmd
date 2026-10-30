@echo off
rem WorkBuddy Keeper launcher (double-click me)
setlocal
cd /d "%~dp0"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

start "" /min "%PS%" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "app.ps1"
exit /b 0
