@echo off
REM Refresh cumulative archive from live DB, then open the viewer.
cd /d "%~dp0"
call "%~dp0refresh_archive.bat"
if errorlevel 1 (
  echo.
  echo teams-record refresh failed. Fix the message above, then run Teams Viewer again.
  pause
  exit /b %errorlevel%
)
start "" pythonw "%~dp0server.py"
timeout /t 1 /nobreak >nul
start chrome http://localhost:8799/
if errorlevel 1 start http://localhost:8799/
