@echo off
REM teams-record-lite CLI launcher. Usage: teams-record-lite.bat refresh ^| status ^| update [--check] ^| capture-key ^| logs ^| version
setlocal
set "ROOT=%~dp0"
set "PY=%ROOT%runtime\python\python.exe"

REM Roll back to the previous app version when requested by "update --rollback".
if exist "%ROOT%rollback.request" (
  if exist "%ROOT%app.old\trlite.py" (
    if exist "%ROOT%app.bad" rmdir /s /q "%ROOT%app.bad"
    move "%ROOT%app" "%ROOT%app.bad" >nul 2>&1
    move "%ROOT%app.old" "%ROOT%app" >nul 2>&1
    if not exist "%ROOT%app\trlite.py" move "%ROOT%app.bad" "%ROOT%app" >nul 2>&1
  )
  del /q "%ROOT%rollback.request" >nul 2>&1
)

REM Apply a staged update (downloaded and verified by a previous run).
if exist "%ROOT%app.new\trlite.py" (
  if exist "%ROOT%app.old" rmdir /s /q "%ROOT%app.old"
  move "%ROOT%app" "%ROOT%app.old" >nul 2>&1
  move "%ROOT%app.new" "%ROOT%app" >nul 2>&1
  if not exist "%ROOT%app\trlite.py" move "%ROOT%app.old" "%ROOT%app" >nul 2>&1
)

if not exist "%PY%" (
  echo {"ok": false, "error_code": 2, "message": "runtime python missing; run install.bat again"}
  endlocal & exit /b 2
)
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "TRLITE_ROOT=%ROOT:~0,-1%"
"%PY%" "%ROOT%app\trlite.py" %*
set "RC=%errorlevel%"
endlocal & exit /b %RC%
