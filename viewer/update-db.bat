@echo off
REM update-db.bat - on-demand refresh launcher
REM Runs the existing refresh (snapshot live Knox DB -> decrypt -> merge -> thumbs)
REM to update the two plaintext DBs in the DB dir (parent of this viewer folder):
REM   teams-decrypted.db : decrypted snapshot of current Knox retention
REM   teams-archive.db   : cumulative master that the viewer/search reads
REM Target DB dir = parent of this script. e.g. D:\git\teams-db\viewer\update-db.bat -> D:\git\teams-db
REM Reuses refresh_archive.bat; prints before/after message counts.
REM Prereq: Knox login history + dbkey.secret + KnoxTeams.exe (same as refresh_archive.bat)

setlocal
for %%I in ("%~dp0..") do set "DBDIR=%%~fI"

echo teams-record update-db (on-demand refresh)
echo Target DB dir: %DBDIR%
echo(

echo ==== BEFORE ====
call :counts
echo(

echo ==== REFRESH (snapshot -^> decrypt -^> merge -^> thumbs) ====
call "%~dp0refresh_archive.bat"
set "RC=%ERRORLEVEL%"
echo(

echo ==== AFTER ====
call :counts
echo(

if "%RC%"=="0" (
  echo update-db done. Both plaintext DBs are refreshed.
) else (
  echo update-db FAILED. refresh_archive.bat exit code = %RC%
  echo   ^( 2 = dbkey.secret missing / decrypt failed, 3 = merge failed, 1 = snapshot/other ^)
)
endlocal & exit /b %RC%

:counts
python "%~dp0_dbcount.py" "%DBDIR%\teams-decrypted.db" "%DBDIR%\teams-archive.db"
exit /b 0
