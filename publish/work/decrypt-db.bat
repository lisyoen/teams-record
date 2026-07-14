@echo off
REM decrypt-db.bat — 독립 SQLCipher 복호화 런처
REM 사용법:
REM   decrypt-db.bat <입력암호화db> [출력평문db] [--key <값|파일>]
REM 예:
REM   decrypt-db.bat "%USERPROFILE%\teams-record-work\snap.db" D:\tmp\out.plain.db
REM   decrypt-db.bat C:\path\enc.db                (출력 생략 시 <입력>.plain.db)
REM 기본 키: %USERPROFILE%\teams-record-work\dbkey.secret (없으면 --key 로 지정)
setlocal
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
set ELECTRON_RUN_AS_NODE=1
"%KEXE%" "%WORK%\decrypt_db.js" %*
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%
