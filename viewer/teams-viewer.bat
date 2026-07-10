@echo off
REM Refresh cumulative archive from live DB, then open the viewer.
cd /d "%~dp0"
call "%~dp0refresh_archive.bat"
start "teams-viewer" /min python "%~dp0server.py"
timeout /t 1 /nobreak >nul
start chrome http://localhost:8799/
if errorlevel 1 start http://localhost:8799/
