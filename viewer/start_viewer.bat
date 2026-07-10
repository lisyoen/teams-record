@echo off
REM Boot/logon auto-start: refresh cumulative archive, then run viewer server (no browser).
REM Registered as a Scheduled Task (logon trigger) so it survives session detach.
cd /d "%~dp0"
call "%~dp0refresh_archive.bat"
start "teams-viewer" /min python "%~dp0server.py"
