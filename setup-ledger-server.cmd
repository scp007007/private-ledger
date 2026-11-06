@echo off
setlocal
pushd "%~dp0ledger-app\server" || exit /b 1
if not exist ".venv\Scripts\python.exe" (
    py -3.12 -m venv .venv
    if errorlevel 1 goto failed
)
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto failed
popd
echo Setup complete. Open start-ledger-server.cmd.
pause
exit /b 0
:failed
popd
echo Setup failed. Check that Python 3.12 and network access are available.
pause
exit /b 1
