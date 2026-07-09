@echo off
cd /d D:\git\teams-db\viewer
start "teams-viewer" /min python server.py
timeout /t 1 /nobreak >nul
start chrome http://localhost:8799/
if errorlevel 1 start http://localhost:8799/
