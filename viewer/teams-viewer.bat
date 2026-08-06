@echo off
REM Refresh cumulative archive, then open the installed Electron viewer.
cd /d "%~dp0"
call "%~dp0refresh_archive.bat"
if errorlevel 1 (
  echo.
  echo teams-record refresh failed. Fix the message above, then run Teams Viewer again.
  pause
  exit /b %errorlevel%
)
call "%~dp0update-check.bat"
call "%~dp0..\electron\teams-viewer-electron.bat"
