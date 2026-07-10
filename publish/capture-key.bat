@echo off
setlocal
set WORK=C:\Users\lisyoen\teams-record-work
set LOG=%WORK%\key_spawn.log
set KEY=%WORK%\dbkey.secret

if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

python -c "import frida" >nul 2>&1
if errorlevel 1 (
  echo Frida is not installed. Installing frida and frida-tools...
  python -m pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org frida frida-tools
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

python -c "import pathlib,re,sys; log=pathlib.Path(r'%LOG%'); key=pathlib.Path(r'%KEY%'); text=log.read_text(encoding='utf-8', errors='ignore') if log.exists() else ''; found=re.findall(r\"PRAGMA key='([^']+)'\", text); sys.exit('PRAGMA key was not captured. Log: %LOG%') if not found else key.write_text(found[-1], encoding='utf-8')"
if errorlevel 1 exit /b 1

for %%A in ("%KEY%") do echo Captured dbkey.secret: %%~fA
echo Key capture done.
endlocal
