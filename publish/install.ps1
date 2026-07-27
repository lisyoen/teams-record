<#
  teams-record 원클릭 통합 설치 스크립트
  다른 Windows ID(계정)에서도 재설치하여 사용할 수 있도록 아래 순서로 수행한다.

    1. 의존성 우선 설치      : Python 3.11, Node.js LTS, npm/Electron, frida (키 캡처용)
    2. 백엔드 + 바탕화면 바로가기 : 뷰어/복호화 런타임 배치, Teams Viewer 바로가기
                               (키 캡처 시 Knox Teams 자동 종료 -> 재실행)
    3. 부팅 후 데이터 자동 업데이트 : TeamsRecordViewer 로그온 스케줄 등록

  기존 setup.ps1 의 검증된 함수(경로 계산/파일 배치/스케줄 등록/바로가기)를 재사용하되,
  frida 의존성과 Knox 자동 재기동, 부팅 자동 업데이트까지 하나의 흐름으로 묶은 상위 진입점이다.

  사용법 (관리자 권한 자동 승격):
    publish\install.bat
    publish\install.bat -KnoxRoot C:\mySingle\KnoxTeams -InstallRoot D:\teams-record
    publish\install.bat -SkipKeyCapture      (키 캡처만 나중에 수동으로)
    publish\install.bat -DataBackup C:\backup\teams-db  (이전 이력 복원)
#>
[CmdletBinding()]
param(
    [string]$DataBackup,
    [string]$InstallRoot,
    [string]$KnoxRoot,
    [switch]$SkipKeyCapture,
    [switch]$SkipDeps
)

$ErrorActionPreference = 'Stop'
$PublishRoot = $PSScriptRoot
$SetupPs1    = Join-Path $PublishRoot 'setup.ps1'
$CaptureBat  = Join-Path $PublishRoot 'capture-key.bat'
$TaskName    = 'TeamsRecordViewer'

if (-not $KnoxRoot) { $KnoxRoot = 'C:\mySingle\KnoxTeams' }
$KnoxExe = Join-Path $KnoxRoot 'KnoxTeams.exe'
$WorkDir = Join-Path $env:USERPROFILE 'teams-record-work'
$KeyPath = Join-Path $WorkDir 'dbkey.secret'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-Admin) { return }
    Write-Host '[*] Requesting administrator privileges...'
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
    if ($DataBackup)     { $a += @('-DataBackup',"`"$DataBackup`"") }
    if ($InstallRoot)    { $a += @('-InstallRoot',"`"$InstallRoot`"") }
    if ($KnoxRoot)       { $a += @('-KnoxRoot',"`"$KnoxRoot`"") }
    if ($SkipKeyCapture) { $a += '-SkipKeyCapture' }
    if ($SkipDeps)       { $a += '-SkipDeps' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs
    exit
}

function Write-Step([string]$msg) { Write-Host ''; Write-Host "==== $msg ====" -ForegroundColor Cyan }
function Write-OK([string]$msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg){ Write-Warning $msg }

function Get-PythonVersion {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $line = (& python --version 2>&1 | Select-Object -First 1).ToString()
        if ($line -match 'Python\s+(\d+)\.(\d+)\.(\d+)') {
            return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
    } catch {}
    return $null
}

function Install-Frida {
    Write-Host '[*] Checking frida (used only for one-time DB key capture)...'
    & python -c "import frida" 2>$null
    if ($LASTEXITCODE -eq 0) { Write-OK 'frida already installed'; return }
    Write-Host '[*] Installing frida via pip...'
    & python -m pip install --trusted-host pypi.org --trusted-host files.pythonhosted.org frida
    if ($LASTEXITCODE -ne 0) {
        throw 'frida install failed. Install manually: python -m pip install frida'
    }
    & python -c "import frida" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'frida import still fails after install.' }
    Write-OK 'frida installed'
}

function Stop-KnoxTeams {
    $procs = Get-Process -Name 'KnoxTeams' -ErrorAction SilentlyContinue
    if (-not $procs) { Write-Host '[*] Knox Teams is not running (nothing to stop).'; return $false }
    Write-Host "[*] Knox Teams is running ($($procs.Count) process). Closing it before key capture..."
    foreach ($p in $procs) {
        try { $p.CloseMainWindow() | Out-Null } catch {}
    }
    Start-Sleep -Seconds 2
    $still = Get-Process -Name 'KnoxTeams' -ErrorAction SilentlyContinue
    if ($still) {
        Write-Host '[*] Forcing remaining Knox Teams processes to close...'
        $still | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
    Write-OK 'Knox Teams stopped'
    return $true
}

function Start-KnoxTeams {
    if (Test-Path -LiteralPath $KnoxExe) {
        Write-Host '[*] Relaunching Knox Teams...'
        Start-Process -FilePath $KnoxExe | Out-Null
        Write-OK 'Knox Teams relaunched (please sign in if prompted)'
    } else {
        Write-Warn2 "KnoxTeams.exe not found at $KnoxExe; relaunch manually and sign in."
    }
}

# ============================================================
# 0. 사전 점검
# ============================================================
Ensure-Admin

Write-Host 'teams-record one-click installer' -ForegroundColor White
Write-Host "PublishRoot : $PublishRoot"
Write-Host "KnoxRoot    : $KnoxRoot"
Write-Host "WorkDir     : $WorkDir"

if (-not (Test-Path -LiteralPath $SetupPs1)) {
    throw "setup.ps1 not found next to install.ps1: $SetupPs1"
}

# ============================================================
# 1. 의존성 우선 설치 (Python 3.11 + Node.js/npm + frida)
# ============================================================
Write-Step '1. Dependencies'
if ($SkipDeps) {
    Write-Warn2 'SkipDeps set: dependency install is skipped (assumes Python 3.11 + Node.js/npm + frida already present).'
} else {
    $pv = Get-PythonVersion
    if ($pv -and $pv.Major -eq 3 -and $pv.Minor -eq 11) {
        Write-OK "Python $pv already available (setup.ps1 will re-verify)"
    } else {
        Write-Host '[*] Python 3.11 and Node.js LTS will be installed by setup.ps1 in the next step.'
    }
}

# ============================================================
# 2. 백엔드 + 바탕화면 바로가기 + 부팅 자동 업데이트 (setup.ps1)
# ============================================================
Write-Step '2. Backend + Electron app + desktop shortcut + logon task (via setup.ps1)'
$setupArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$SetupPs1`"",'-KnoxRoot',"`"$KnoxRoot`"")
if ($DataBackup)  { $setupArgs += @('-DataBackup',"`"$DataBackup`"") }
if ($InstallRoot) { $setupArgs += @('-InstallRoot',"`"$InstallRoot`"") }
if ($SkipDeps)    { $setupArgs += '-SkipDependencies' }
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList $setupArgs -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    throw "setup.ps1 failed with exit code $($p.ExitCode)."
}
Write-OK 'setup.ps1 completed (files, Electron dependencies, shortcut, and logon task in place)'

if (-not $SkipDeps) { Install-Frida }

# ============================================================
# 2b. DB 키 캡처 (Knox Teams 자동 종료 -> 재실행)
# ============================================================
Write-Step '2b. Database key capture'
if ($SkipKeyCapture) {
    Write-Warn2 'SkipKeyCapture set: run publish\capture-key.bat manually after Knox Teams login.'
} elseif (Test-Path -LiteralPath $KeyPath) {
    Write-OK 'dbkey.secret already present; key capture skipped.'
} elseif (-not (Test-Path -LiteralPath $KnoxExe)) {
    Write-Warn2 "KnoxTeams.exe not found at $KnoxExe. Skipping key capture. Install/sign in to Knox Teams, then run publish\capture-key.bat."
} else {
    $wasRunning = Stop-KnoxTeams
    try {
        Write-Host '[*] Capturing SQLCipher key from a fresh Knox Teams instance (frida spawn)...'
        $env:KNOX_ROOT = $KnoxRoot
        $c = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d','/c',"`"$CaptureBat`"") -Wait -PassThru -NoNewWindow
        if ($c.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $KeyPath)) {
            Write-Warn2 "Key capture did not complete (exit $($c.ExitCode)). You can retry later: publish\capture-key.bat (Knox must be signed in)."
        } else {
            Write-OK 'dbkey.secret captured'
        }
    } finally {
        Stop-KnoxTeams | Out-Null
        Start-KnoxTeams
    }
}

# ============================================================
# 3. 부팅 후 데이터 자동 업데이트 확인
# ============================================================
Write-Step '3. Boot-time auto-update (scheduled task) verification'
$q = & $env:ComSpec /d /c "schtasks.exe /Query /TN `"$TaskName`" >nul 2>nul"
if ($LASTEXITCODE -eq 0) {
    Write-OK "scheduled task '$TaskName' is registered (runs at logon: refresh archive + start viewer)"
} else {
    Write-Warn2 "scheduled task '$TaskName' not found. Re-run publish\setup.bat."
}

# ============================================================
# 완료 안내
# ============================================================
Write-Host ''
Write-Host '==== Install finished ====' -ForegroundColor White
Write-Host 'Next:'
Write-Host '  - Desktop shortcut "Teams Viewer" opens the Electron app'
Write-Host '  - On each logon, TeamsRecordViewer refreshes the archive and starts the viewer.'
if ($SkipKeyCapture -or -not (Test-Path -LiteralPath $KeyPath)) {
    Write-Host '  - If data does not decrypt, sign in to Knox Teams and run publish\capture-key.bat once.'
}
Write-Host '  - Verify anytime with:  publish\setup.bat -CheckOnly'
