@echo off
REM teams-record: snapshot live DB -> decrypt -> merge into cumulative archive.
REM Company-PC local only. Requires teams-record-work (decrypt_export.js, sqlite3.js, dbkey.secret)
REM and this viewer directory's merge_archive.py.
setlocal
set "WORK=%USERPROFILE%\teams-record-work"
for %%I in ("%~dp0..") do set "DBDIR=%%~fI"

if not defined KNOX_ROOT (
  if exist "C:\mySingle\KnoxTeams\KnoxTeams.exe" set "KNOX_ROOT=C:\mySingle\KnoxTeams"
)
if not defined KNOX_ROOT (
  for /f "delims=" %%I in ('where KnoxTeams.exe 2^>nul') do if not defined KNOX_ROOT for %%J in ("%%~dpI.") do set "KNOX_ROOT=%%~fJ"
)
if not defined KNOX_ROOT (
  echo ERROR: KnoxTeams.exe was not found. Set KNOX_ROOT to the KnoxTeams install directory.
  endlocal & exit /b 1
)
set "KEXE=%KNOX_ROOT%\KnoxTeams.exe"
if not exist "%KEXE%" (
  echo ERROR: KnoxTeams.exe was not found: %KEXE%
  endlocal & exit /b 1
)

for /f "usebackq delims=" %%I in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "$prd=Join-Path $env:APPDATA 'KnoxTeams\prd'; if(!(Test-Path -LiteralPath $prd)){ exit 1 }; $db=Get-ChildItem -LiteralPath $prd -Filter '*.db' -File | Sort-Object @{Expression={if($_.BaseName -match '^[0-9a-fA-F]{64}$'){0}else{1}}}, @{Expression='Length';Descending=$true} | Select-Object -First 1; if($db){$db.FullName}else{exit 1}"`) do set "LIVE=%%I"
if not defined LIVE (
  echo ERROR: live KnoxTeams message DB was not found under %%APPDATA%%\KnoxTeams\prd.
  endlocal & exit /b 1
)

echo [1/3] snapshot live DB (+wal +shm)...
if not exist "%WORK%" mkdir "%WORK%"
if not exist "%WORK%\dbkey.secret" (
  echo   ERROR: dbkey.secret is missing.
  echo   Run publish\capture-key.bat once after Knox Teams login, then open Teams Viewer again.
  endlocal & exit /b 2
)
copy /y "%LIVE%" "%WORK%\snap.db" >nul 2>&1
if exist "%LIVE%-wal" (copy /y "%LIVE%-wal" "%WORK%\snap.db-wal" >nul 2>&1) else (del /q "%WORK%\snap.db-wal" 2>nul)
if exist "%LIVE%-shm" (copy /y "%LIVE%-shm" "%WORK%\snap.db-shm" >nul 2>&1) else (del /q "%WORK%\snap.db-shm" 2>nul)
if not exist "%WORK%\snap.db" (echo   ERROR: snapshot failed & endlocal & exit /b 1)

echo [2/3] decrypt snapshot -> teams-decrypted.db...
set ELECTRON_RUN_AS_NODE=1
set "TEAMS_DB_DIR=%DBDIR%"
del /q "%DBDIR%\teams-decrypted.db" 2>nul
"%KEXE%" "%WORK%\decrypt_export.js"
if errorlevel 1 (echo   ERROR: decrypt failed with exit code %errorlevel% & endlocal & exit /b 2)
if not exist "%DBDIR%\teams-decrypted.db" (echo   ERROR: decrypt produced no output & endlocal & exit /b 2)

echo [3/4] merge into cumulative archive teams-archive.db...
python "%~dp0merge_archive.py" "%DBDIR%\teams-decrypted.db" "%DBDIR%\teams-archive.db"
if errorlevel 1 (echo   ERROR: merge failed & endlocal & exit /b 3)

echo [4/4] accumulate image thumbnails (app evicts old ones; keep forever)...
set THUMBSRC=%APPDATA%\KnoxTeams\prd\thumbs
set THUMBDST=%DBDIR%\thumbs
if not exist "%THUMBDST%" mkdir "%THUMBDST%"
if exist "%THUMBSRC%" (xcopy /y /q /i "%THUMBSRC%\*" "%THUMBDST%\" >nul 2>&1)

echo refresh done.
endlocal
