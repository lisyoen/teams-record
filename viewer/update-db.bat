@echo off
REM update-db.bat — 온디맨드 refresh 실행기
REM
REM 기존 refresh 기능(live Knox DB 스냅샷 -> 복호화 -> 누적 아카이브 병합 -> 썸네일)을
REM 그대로 실행하여, DB 디렉토리의 평문 파일 2개를 최신 상태로 갱신한다.
REM   - teams-decrypted.db : 현재 Knox 보존분의 복호화 스냅샷
REM   - teams-archive.db   : 위 스냅샷을 누적 병합한 마스터(뷰어/검색이 읽는 본체)
REM
REM 대상 DB 디렉토리는 이 스크립트(viewer\)의 부모다. 예: D:\git\teams-db\viewer\update-db.bat -> D:\git\teams-db
REM refresh_archive.bat 를 재사용하며, 실행 전/후 메시지 건수를 출력해 갱신 결과를 보여준다.
REM
REM 사용법:  update-db.bat        (viewer 폴더에 두고 실행)
REM 사전조건: Knox Teams 로그인 이력 + dbkey.secret + KnoxTeams.exe (refresh_archive.bat 와 동일)

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
  echo   ( 2 = dbkey.secret missing / decrypt failed, 3 = merge failed, 1 = snapshot/other )
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
