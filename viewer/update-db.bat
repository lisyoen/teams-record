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
set "PY=python"

echo teams-record update-db (on-demand refresh)
echo Target DB dir: %DBDIR%
echo(

echo ==== BEFORE ====
call :counts "%DBDIR%\teams-decrypted.db" teams-decrypted.db
call :counts "%DBDIR%\teams-archive.db"   teams-archive.db
echo(

echo ==== REFRESH (snapshot -^> decrypt -^> merge -^> thumbs) ====
call "%~dp0refresh_archive.bat"
set "RC=%ERRORLEVEL%"
echo(

echo ==== AFTER ====
call :counts "%DBDIR%\teams-decrypted.db" teams-decrypted.db
call :counts "%DBDIR%\teams-archive.db"   teams-archive.db
echo(

if "%RC%"=="0" (
  echo update-db done. Both plaintext DBs are refreshed.
) else (
  echo update-db FAILED. refresh_archive.bat exit code = %RC%
  echo   ^( 2 = dbkey.secret missing / decrypt failed, 3 = merge failed, 1 = snapshot/other ^)
)
endlocal & exit /b %RC%

:counts
REM %1 = db path, %2 = label
if not exist "%~1" (
  echo   %~2 : (missing)
  exit /b 0
)
%PY% -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);q=c.cursor();kt=q.execute('select count(*) from TB_KtMessage').fetchone()[0];km=q.execute('select count(*) from TB_KmMessage').fetchone()[0];c.close();print('   {0} : channel(TB_KtMessage)={1}  dm/group(TB_KmMessage)={2}'.format(sys.argv[2],kt,km))" "%~1" "%~2" 2>nul
if errorlevel 1 echo   %~2 : (count failed - encrypted or locked?)
exit /b 0
