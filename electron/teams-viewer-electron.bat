@echo off
setlocal
REM Launch the installed Electron Teams Viewer. Electron starts/waits for server.py.
cd /d "%~dp0"
set "ELECTRON_EXE=%~dp0node_modules\electron\dist\electron.exe"
if not exist "%ELECTRON_EXE%" (
  echo ERROR: Electron is not installed.
  echo Run publish\install.bat again.
  pause
  endlocal & exit /b 1
)
call "%~dp0..\viewer\update-check.bat"
start "" "%ELECTRON_EXE%" "%~dp0"
endlocal
