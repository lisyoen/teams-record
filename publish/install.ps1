[CmdletBinding()]
param([string]$DataBackup, [string]$InstallRoot, [string]$KnoxRoot = 'C:\mySingle\KnoxTeams', [switch]$SkipKeyCapture, [switch]$SkipDeps, [switch]$Elevated)
$ErrorActionPreference = 'Stop'
$TaskName = 'TeamsRecordViewer'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkDir = Join-Path $env:USERPROFILE 'teams-record-work'
$MarkerPath = Join-Path $WorkDir 'install-root.txt'
$KnoxExe = Join-Path $KnoxRoot 'KnoxTeams.exe'
$script:SelectedReason = ''
$script:InstallSucceeded = $false
$script:VersionVerified = $false

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Quote-Arg([string]$Value) { '"' + ($Value -replace '"', '\"') + '"' }

if (-not (Test-Admin)) {
    Write-Host '[*] Requesting administrator privileges. Continue in the UAC-approved installer window...'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-Arg $PSCommandPath),'-Elevated')
    if ($DataBackup) { $args += @('-DataBackup',(Quote-Arg $DataBackup)) }
    if ($InstallRoot) { $args += @('-InstallRoot',(Quote-Arg $InstallRoot)) }
    if ($KnoxRoot) { $args += @('-KnoxRoot',(Quote-Arg $KnoxRoot)) }
    if ($SkipKeyCapture) { $args += '-SkipKeyCapture' }
    if ($SkipDeps) { $args += '-SkipDeps' }
    $p = Start-Process powershell.exe -ArgumentList $args -Verb RunAs -Wait -PassThru
    exit $p.ExitCode
}

$LogDir = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogPath = Join-Path $LogDir (Get-Date -Format 'install-yyyyMMdd-HHmmss.log')
Start-Transcript -LiteralPath $LogPath -Force | Out-Null
function Write-Step([string]$Message) { Write-Host ''; Write-Host "==== $Message ====" -ForegroundColor Cyan }
function Write-OK([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }

function Get-DefaultInstallRoot {
    $drive = Split-Path -Qualifier $RepoRoot
    if ($drive -and $env:SystemDrive -and $drive -ine $env:SystemDrive) { return Join-Path ($drive + '\') 'teams-record' }
    Join-Path $env:LOCALAPPDATA 'teams-record'
}
function Get-TaskInstallRoot {
    try {
        $xml = [xml](& schtasks.exe /Query /TN $TaskName /XML 2>$null | Out-String)
        $text = ([string]$xml.Task.Actions.Exec.Command) + ' ' + ([string]$xml.Task.Actions.Exec.Arguments)
        if ($text -match '(?i)([A-Z]:\\[^"\r\n]*?\\viewer\\start_viewer\.bat)') { return Split-Path -Parent (Split-Path -Parent $Matches[1]) }
    } catch {}
    $null
}
function Get-ShortcutInstallRoot {
    $path = Join-Path $env:USERPROFILE 'Desktop\Teams Viewer.lnk'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $link = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
        foreach ($value in @($link.Arguments.Trim('"'), $link.TargetPath)) {
            if ($value -match '(?i)^(.*)\\electron(?:\\.*)?$') { return $Matches[1] }
        }
    } catch {}
    $null
}
function Resolve-InstallRoot {
    if ($InstallRoot) { $script:SelectedReason = 'explicit -InstallRoot'; return [IO.Path]::GetFullPath($InstallRoot) }
    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        $value = (Get-Content -LiteralPath $MarkerPath -Raw).Trim()
        if ($value) { $script:SelectedReason = "marker: $MarkerPath"; return [IO.Path]::GetFullPath($value) }
    }
    $value = Get-TaskInstallRoot
    if ($value) { $script:SelectedReason = "scheduled task: $TaskName"; return [IO.Path]::GetFullPath($value) }
    $value = Get-ShortcutInstallRoot
    if ($value) { $script:SelectedReason = 'desktop shortcut: Teams Viewer.lnk'; return [IO.Path]::GetFullPath($value) }
    $script:SelectedReason = 'default path'; Get-DefaultInstallRoot
}
function Stop-ViewerProcesses {
    Write-Step '1/7 Stop viewer and Electron'
    try { Get-NetTCPConnection -LocalPort 8799 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } } catch {}
    try { Get-CimInstance Win32_Process -Filter "Name='electron.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallRoot,[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
    Write-OK 'port 8799 listener and installed Electron processes stopped'
}
function Stop-KnoxTeams {
    Write-Step '2/7 Stop Knox Teams'
    Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 2
    Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-OK 'Knox Teams stopped (or was not running)'
}
function Start-KnoxTeams {
    if (Test-Path -LiteralPath $KnoxExe -PathType Leaf) { Start-Process -FilePath $KnoxExe | Out-Null; Write-OK 'Knox Teams relaunched' }
    else { Write-Warning "Knox Teams could not be relaunched: $KnoxExe" }
}
function Install-Frida {
    & python -c 'import frida' 2>$null
    if ($LASTEXITCODE -eq 0) { Write-OK 'frida already installed'; return }
    & python -m pip install frida
    if ($LASTEXITCODE -ne 0) { throw "frida installation failed (exit $LASTEXITCODE)" }
    & python -c 'import frida'
    if ($LASTEXITCODE -ne 0) { throw 'frida import verification failed' }
    Write-OK 'frida installed'
}

try {
    Write-Host 'teams-record one-click installer' -ForegroundColor White
    Write-Host "Log         : $LogPath"
    $InstallRoot = Resolve-InstallRoot
    Write-Host "InstallRoot : $InstallRoot"
    Write-Host "Selected by : $script:SelectedReason"
    Stop-ViewerProcesses
    Stop-KnoxTeams

    Write-Step '3/7 Install dependencies and application files'
    $setup = Join-Path $PSScriptRoot 'setup.ps1'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-Arg $setup),'-InstallRoot',(Quote-Arg $InstallRoot),'-KnoxRoot',(Quote-Arg $KnoxRoot))
    if ($DataBackup) { $args += @('-DataBackup',(Quote-Arg $DataBackup)) }
    if ($SkipDeps) { $args += '-SkipDependencies' }
    $p = Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "setup.ps1 failed with exit code $($p.ExitCode)" }
    Write-OK 'application files, task, shortcut, and Electron installed'

    Write-Step '4/7 Database key capture (verify frida first)'
    if (-not $SkipDeps) { Install-Frida }
    $key = Join-Path $WorkDir 'dbkey.secret'
    if ($SkipKeyCapture) { Write-Warning 'Key capture skipped by option.' }
    elseif (Test-Path -LiteralPath $key) { Write-OK 'existing dbkey.secret preserved; capture skipped' }
    elseif (-not (Test-Path -LiteralPath $KnoxExe)) { Write-Warning 'Knox Teams executable missing; key capture skipped.' }
    else {
        $env:KNOX_ROOT = $KnoxRoot
        & $env:ComSpec /d /c "`"$(Join-Path $PSScriptRoot 'capture-key.bat')`""
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $key)) { throw 'database key capture failed' }
        Write-OK 'dbkey.secret captured'
        Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Write-Step '5/7 First archive refresh'
    & $env:ComSpec /d /c "`"$(Join-Path $InstallRoot 'viewer\refresh_archive.bat')`""
    if ($LASTEXITCODE -ne 0) { throw "first refresh failed with exit code $LASTEXITCODE" }
    Write-OK 'first refresh completed'

    Write-Step '6/7 Start Teams Viewer and verify version'
    & $env:ComSpec /d /c "`"$(Join-Path $InstallRoot 'electron\teams-viewer-electron.bat')`""
    $expected = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
    for ($i=0; $i -lt 20; $i++) {
        try { $response = Invoke-RestMethod 'http://127.0.0.1:8799/api/version' -Proxy $null -TimeoutSec 2; if ([string]$response.local -eq $expected) { $script:VersionVerified = $true; break } } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $script:VersionVerified) { throw "viewer version verification failed; expected $expected" }
    Write-OK "viewer /api/version matches package VERSION $expected"

    Write-Step '7/7 Save installation marker'
    Set-Content -LiteralPath $MarkerPath -Value $InstallRoot -Encoding UTF8
    $script:InstallSucceeded = $true
} catch {
    Write-Host "[FAILED] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $LogPath"
} finally {
    Write-Host ''; Write-Host '==== Result summary ====' -ForegroundColor White
    Write-Host "InstallRoot      : $InstallRoot"
    Write-Host "Selection reason : $script:SelectedReason"
    Write-Host "Version verified : $script:VersionVerified"
    Write-Host "Log              : $LogPath"
    Start-KnoxTeams
    try { Stop-Transcript | Out-Null } catch {}
}
if ($script:InstallSucceeded) { Write-Host '[SUCCESS] Installation completed.' -ForegroundColor Green; exit 0 }
exit 1
