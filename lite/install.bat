@echo off
REM teams-record-lite one-step installer (per-user, no administrator rights required).
REM Options are passed to setup\lite-install.ps1, e.g. -NoPopup -InstallDir D:\tr-lite
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\lite-install.ps1" %*
set "RC=%errorlevel%"
if not "%RC%"=="0" if not "%RC%"=="10" pause
endlocal & exit /b %RC%
