@echo off
setlocal
title teams-record installer
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish\install.ps1" %*
set "INSTALL_EXIT=%ERRORLEVEL%"
echo.
if not "%INSTALL_EXIT%"=="0" echo Installation failed. See the log path above.
pause
exit /b %INSTALL_EXIT%
