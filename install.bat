@echo off
setlocal
title teams-record installer
REM Asks whether to install the Teams Viewer; "No" installs only the CLI.
REM Options: -Mode viewer^|cli -NoPopup -InstallRoot ... -CliInstallDir ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish\install-select.ps1" %*
set "INSTALL_EXIT=%ERRORLEVEL%"
if not "%INSTALL_EXIT%"=="0" (
  echo.
  echo Installation could not start or failed. See the installer window and log.
  pause
)
exit /b %INSTALL_EXIT%
