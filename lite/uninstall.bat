@echo off
REM teams-record-lite uninstaller. Options: -RemoveData ^| -KeepData ^| -NoPopup
setlocal
set "TMPPS=%TEMP%\teams-record-lite-uninstall.ps1"
copy /y "%~dp0setup\lite-uninstall.ps1" "%TMPPS%" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%TMPPS%" -InstallDir "%~dp0." %*
