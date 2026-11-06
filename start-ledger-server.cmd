@echo off
setlocal
rem Open the desktop status window. Minimize it to keep syncing.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ledger-app\server\ledger-desktop.ps1" %*
set "ledger_exit=%ERRORLEVEL%"
echo.
echo Ledger server exit code: %ledger_exit%
if not "%ledger_exit%"=="0" pause
exit /b %ledger_exit%
