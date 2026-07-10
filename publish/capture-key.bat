@echo off
setlocal
set "WORK=%USERPROFILE%\teams-record-work"
set "LOG=%WORK%\key_spawn.log"
set "KEY=%WORK%\dbkey.secret"

if not defined KNOX_ROOT (
  if exist "C:\mySingle\KnoxTeams\KnoxTeams.exe" set "KNOX_ROOT=C:\mySingle\KnoxTeams"
)
if not defined KNOX_ROOT (
  for /f "delims=" %%I in ('where KnoxTeams.exe 2^>nul') do if not defined KNOX_ROOT for %%J in ("%%~dpI.") do set "KNOX_ROOT=%%~fJ"
)
if not defined KNOX_ROOT (
  echo ERROR: KnoxTeams.exe was not found. Set KNOX_ROOT to the KnoxTeams install directory.
  exit /b 1
)
if not exist "%KNOX_ROOT%\KnoxTeams.exe" (
  echo ERROR: KnoxTeams.exe was not found: %KNOX_ROOT%\KnoxTeams.exe
  exit /b 1
)

if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

python -c "import frida" >nul 2>&1
if errorlevel 1 (
  echo Frida is not installed. Installing frida...
  python -m pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org frida
  if errorlevel 1 (
    echo ERROR: Frida install failed. Install it manually, then rerun this file.
    exit /b 1
  )
)

echo Recapturing dbkey.secret for the current Knox Teams login on this Windows installation.
echo KnoxTeams must be installed and signed in. The key is written only to %KEY%.
python "%WORK%\spawn_key.py"
if errorlevel 1 (
  echo ERROR: spawn_key.py failed.
  exit /b 1
)

python -c "import pathlib,re,sys; log=pathlib.Path(sys.argv[1]); key=pathlib.Path(sys.argv[2]); text=log.read_text(encoding='utf-8', errors='ignore') if log.exists() else ''; found=re.findall(r\"PRAGMA\\s+key\\s*=\\s*'([^']+)'\", text, re.I); sys.exit('PRAGMA key was not captured. Log: '+str(log)) if not found else key.write_text(found[-1], encoding='utf-8')" "%LOG%" "%KEY%"
if errorlevel 1 exit /b 1

for %%A in ("%KEY%") do echo Captured dbkey.secret: %%~fA
echo Key capture done.
endlocal
