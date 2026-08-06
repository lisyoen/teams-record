@echo off
REM Refresh cumulative archive, update viewer sources, then run viewer server.
cd /d "%~dp0viewer"
call "%~dp0viewer\refresh_archive.bat"
call "%~dp0viewer\update-check.bat"
start "" pythonw "%~dp0viewer\server.py"
