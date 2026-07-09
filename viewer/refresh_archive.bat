@echo off
REM teams-record: snapshot live DB -> decrypt -> merge into cumulative archive.
REM Company-PC local only. Requires teams-record-work (decrypt_export.js, sqlite3.js, dbkey.secret)
REM and D:\git\teams-db\viewer\merge_archive.py.
setlocal
set WORK=C:\Users\lisyoen\teams-record-work
set LIVE=%APPDATA%\KnoxTeams\prd\1981808420339ad58f2346268bcf36946ea83764d65ae27ed59baa102daa9e06.db
set DBDIR=D:\git\teams-db
set KEXE=C:\mySingle\KnoxTeams\KnoxTeams.exe

echo [1/3] snapshot live DB (+wal +shm)...
copy /y "%LIVE%" "%WORK%\snap.db" >nul 2>&1
if exist "%LIVE%-wal" (copy /y "%LIVE%-wal" "%WORK%\snap.db-wal" >nul 2>&1) else (del /q "%WORK%\snap.db-wal" 2>nul)
if exist "%LIVE%-shm" (copy /y "%LIVE%-shm" "%WORK%\snap.db-shm" >nul 2>&1) else (del /q "%WORK%\snap.db-shm" 2>nul)
if not exist "%WORK%\snap.db" (echo   ERROR: snapshot failed & endlocal & exit /b 1)

echo [2/3] decrypt snapshot -> teams-decrypted.db...
set ELECTRON_RUN_AS_NODE=1
"%KEXE%" "%WORK%\decrypt_export.js"
if not exist "%DBDIR%\teams-decrypted.db" (echo   ERROR: decrypt failed & endlocal & exit /b 2)

echo [3/4] merge into cumulative archive teams-archive.db...
python "%DBDIR%\viewer\merge_archive.py" "%DBDIR%\teams-decrypted.db" "%DBDIR%\teams-archive.db"
if errorlevel 1 (echo   ERROR: merge failed & endlocal & exit /b 3)

echo [4/4] accumulate image thumbnails (app evicts old ones; keep forever)...
set THUMBSRC=%APPDATA%\KnoxTeams\prd\thumbs
set THUMBDST=%DBDIR%\thumbs
if not exist "%THUMBDST%" mkdir "%THUMBDST%"
if exist "%THUMBSRC%" (xcopy /y /q /i "%THUMBSRC%\*" "%THUMBDST%\" >nul 2>&1)

echo refresh done.
endlocal
