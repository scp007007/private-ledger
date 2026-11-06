@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0ledger-app\server\check-ledger-connection.ps1" %*
set "ledger_exit=%ERRORLEVEL%"
echo.
pause
exit /b %ledger_exit%
