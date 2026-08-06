@echo off
setlocal EnableExtensions
set "VIEWER_DIR=%~dp0"
set "UPDATE_LOG=%VIEWER_DIR%update.log"
set "REMOTE_VERSION="
for /f "usebackq delims=" %%V in (`curl.exe -fsS --ssl-no-revoke -m 6 https://raw.githubusercontent.com/lisyoen/teams-record/main/VERSION 2^>nul`) do if not defined REMOTE_VERSION set "REMOTE_VERSION=%%V"
if not defined REMOTE_VERSION goto :eof

set "LOCAL_VERSION="
if exist "%VIEWER_DIR%VERSION" set /p LOCAL_VERSION=<"%VIEWER_DIR%VERSION"
if "%LOCAL_VERSION%"=="%REMOTE_VERSION%" goto :eof

set "UPDATE_TGZ=%TEMP%\tr-update.tgz"
set "UPDATE_DIR=%TEMP%\tr-update"
if exist "%UPDATE_TGZ%" del /q "%UPDATE_TGZ%" >nul 2>&1
if exist "%UPDATE_DIR%" rmdir /s /q "%UPDATE_DIR%" >nul 2>&1
mkdir "%UPDATE_DIR%" >nul 2>&1

curl.exe -fsSL --ssl-no-revoke -m 60 -o "%UPDATE_TGZ%" https://codeload.github.com/lisyoen/teams-record/tar.gz/refs/heads/main
if errorlevel 1 goto :download_failed
tar -xf "%UPDATE_TGZ%" -C "%UPDATE_DIR%"
if errorlevel 1 goto :extract_failed
if not exist "%UPDATE_DIR%\teams-record-main\viewer\server.py" goto :extract_failed

xcopy /E /Y /I "%UPDATE_DIR%\teams-record-main\viewer\*" "%VIEWER_DIR%" >nul
if errorlevel 1 goto :copy_failed
copy /Y "%UPDATE_DIR%\teams-record-main\VERSION" "%VIEWER_DIR%VERSION" >nul
if errorlevel 1 goto :copy_failed
call :log OK %LOCAL_VERSION% to %REMOTE_VERSION%
goto :cleanup

:download_failed
call :log FAIL download %REMOTE_VERSION%
goto :cleanup
:extract_failed
call :log FAIL extract %REMOTE_VERSION%
goto :cleanup
:copy_failed
call :log FAIL copy %REMOTE_VERSION%

:cleanup
if exist "%UPDATE_TGZ%" del /q "%UPDATE_TGZ%" >nul 2>&1
if exist "%UPDATE_DIR%" rmdir /s /q "%UPDATE_DIR%" >nul 2>&1
goto :eof

:log
>>"%UPDATE_LOG%" echo [%date% %time%] %*
goto :eof
