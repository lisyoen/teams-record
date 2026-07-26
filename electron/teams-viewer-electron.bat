@echo off
REM Launch the Electron Teams Viewer (thin wrapper over local server 127.0.0.1:8799).
cd /d "%~dp0"
if not exist "%~dp0node_modules\.bin\electron.cmd" (
  echo Electron is not installed. Run: cd /d "%~dp0"  and then  npm install
  pause
  exit /b 1
)
start "" "%~dp0node_modules\.bin\electron.cmd" "%~dp0"
