@echo off
REM Boot/logon auto-start: refresh cumulative archive, then run viewer server (no browser).
REM Registered as a Scheduled Task (logon trigger) so it survives session detach.
call D:\git\teams-db\viewer\refresh_archive.bat
cd /d D:\git\teams-db\viewer
start "teams-viewer" /min python server.py
