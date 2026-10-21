@echo off
setlocal
title teams-record installer
REM Installs Teams Viewer (desktop shortcut) and the CLI. No installation-type question.
REM Options: -NoPopup -InstallRoot ... -CliInstallDir ... -KnoxRoot ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish\install-select.ps1" %*
set "INSTALL_EXIT=%ERRORLEVEL%"
if not "%INSTALL_EXIT%"=="0" (
  echo.
  echo Installation could not start or failed. See the installer window and log.
  pause
)
exit /b %INSTALL_EXIT%
