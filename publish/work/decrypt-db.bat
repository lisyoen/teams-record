@echo off
REM decrypt-db.bat — 독립 SQLCipher 복호화 런처 (원본 보호: 입력을 임시 복사본으로 떠서 복호화)
REM 사용법:
REM   decrypt-db.bat <입력암호화db> [출력평문db] [--key <값|파일>]
REM 예:
REM   decrypt-db.bat "%USERPROFILE%\teams-record-work\snap.db" D:\tmp\out.plain.db
REM   decrypt-db.bat C:\path\enc.db                (출력 생략 시 <입력>.plain.db)
REM 기본 키: %USERPROFILE%\teams-record-work\dbkey.secret (없으면 --key 로 지정)
setlocal EnableDelayedExpansion
if "%~1"=="" (
  echo usage: decrypt-db.bat ^<encrypted.db^> [plaintext.db] [--key ^<value^|file^>]
  endlocal & exit /b 2
)
set "WORK=%USERPROFILE%\teams-record-work"
if not exist "%WORK%\decrypt_db.js" (
  echo ERROR: %WORK%\decrypt_db.js not found. Install teams-record first ^(publish\setup.bat^).
  endlocal & exit /b 3
)
if not defined KNOX_ROOT (
  if exist "C:\mySingle\KnoxTeams\KnoxTeams.exe" set "KNOX_ROOT=C:\mySingle\KnoxTeams"
)
if not defined KNOX_ROOT (
  for /f "delims=" %%I in ('where KnoxTeams.exe 2^>nul') do if not defined KNOX_ROOT for %%J in ("%%~dpI.") do set "KNOX_ROOT=%%~fJ"
)
if not defined KNOX_ROOT (
  echo ERROR: KnoxTeams.exe not found. Set KNOX_ROOT to the KnoxTeams install directory.
  endlocal & exit /b 4
)
set "KEXE=%KNOX_ROOT%\KnoxTeams.exe"
if not exist "%KEXE%" (
  echo ERROR: KnoxTeams.exe not found: %KEXE%
  endlocal & exit /b 4
)

REM ---- 인자 분리: %1=입력, %2=출력(옵션 아니면), 나머지 통과 ----
set "IN=%~1"
if not exist "%IN%" (
  echo ERROR: input db not found: %IN%
  endlocal & exit /b 2
)
set "OUT="
set "REST="
if not "%~2"=="" (
  set "A2=%~2"
  if "!A2:~0,2!"=="--" ( set "REST=%2 %3 %4 %5 %6" ) else ( set "OUT=%~2" & set "REST=%3 %4 %5 %6" )
)

REM ---- 원본 보호: 임시 복사본 생성 ----
set "TMP1=%TEMP%\trdec_%RANDOM%%RANDOM%.db"
copy /y "%IN%" "%TMP1%" >nul 2>&1
if not exist "%TMP1%" (
  echo ERROR: failed to stage temp copy of input.
  endlocal & exit /b 5
)
if exist "%IN%-wal" copy /y "%IN%-wal" "%TMP1%-wal" >nul 2>&1
if exist "%IN%-shm" copy /y "%IN%-shm" "%TMP1%-shm" >nul 2>&1

set ELECTRON_RUN_AS_NODE=1
if defined OUT (
  "%KEXE%" "%WORK%\decrypt_db.js" "%TMP1%" "%OUT%" !REST!
) else (
  REM 출력 미지정: 입력 옆이 아니라 입력 파일명 기반으로 <입력>.plain.db 생성
  "%KEXE%" "%WORK%\decrypt_db.js" "%TMP1%" "%IN%.plain.db" !REST!
)
set RC=%ERRORLEVEL%

REM ---- 임시 복사본 정리 ----
del /q "%TMP1%" "%TMP1%-wal" "%TMP1%-shm" >nul 2>&1
endlocal & exit /b %RC%
