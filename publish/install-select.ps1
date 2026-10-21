[CmdletBinding()]
param(
    [string]$DataBackup,
    [string]$InstallRoot,
    [string]$KnoxRoot,
    [string]$CliInstallDir,
    [switch]$SkipKeyCapture,
    [switch]$SkipDeps,
    [switch]$NoPopup
)
# Always installs Teams Viewer (publish\install.ps1, desktop shortcut included)
# and then the CLI (lite\setup\lite-install.ps1) sharing the viewer archive and key.
# No installation-type question: the package can be installed unattended (e.g. by an agent).
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
Add-Type -AssemblyName System.Windows.Forms

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ViewerInstaller = Join-Path $PSScriptRoot 'install.ps1'
$CliInstaller = Join-Path $RepoRoot 'lite\setup\lite-install.ps1'
$MarkerPath = Join-Path $env:USERPROFILE 'teams-record-work\install-root.txt'
if (-not $CliInstallDir) { $CliInstallDir = Join-Path $env:LOCALAPPDATA 'teams-record-lite' }
$CliLauncher = Join-Path $CliInstallDir 'teams-record-lite.bat'

function Show-Box([string]$Text, [string]$Caption, [string]$Icon) {
    if ($NoPopup) { return }
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::$Icon)
}

function Invoke-Installer([string]$Script, [string[]]$ScriptArgs) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs
    return $LASTEXITCODE
}

Write-Host '[설치 유형] Teams Viewer(바탕화면 바로가기 포함) + 명령줄 도구(CLI)'

# 1) Teams Viewer: UAC, dependencies, key capture, desktop shortcut, Knox Teams restart.
$viewerArgs = @()
if ($DataBackup) { $viewerArgs += @('-DataBackup', $DataBackup) }
if ($InstallRoot) { $viewerArgs += @('-InstallRoot', $InstallRoot) }
if ($KnoxRoot) { $viewerArgs += @('-KnoxRoot', $KnoxRoot) }
if ($SkipKeyCapture) { $viewerArgs += '-SkipKeyCapture' }
if ($SkipDeps) { $viewerArgs += '-SkipDeps' }
if ($NoPopup) { $viewerArgs += '-NoPopup' }
$started = Get-Date
$viewerExit = Invoke-Installer $ViewerInstaller $viewerArgs
$viewerDone = (Test-Path -LiteralPath $MarkerPath) -and ((Get-Item -LiteralPath $MarkerPath).LastWriteTime -ge $started.AddSeconds(-2))
if ($viewerExit -ne 0 -or -not $viewerDone) {
    Write-Host '[건너뜀] Teams Viewer 설치가 완료되지 않아 CLI 설치를 진행하지 않습니다.'
    exit $(if ($viewerExit -ne 0) { $viewerExit } else { 1 })
}

# 2) CLI: shares the viewer archive and key, so both always see the same conversations.
$viewerRoot = (Get-Content -LiteralPath $MarkerPath -Raw).Trim()
$cliArgs = @('-InstallDir', $CliInstallDir, '-NoPopup', '-ArchivePath', (Join-Path $viewerRoot 'teams-archive.db'))
if ($SkipKeyCapture) { $cliArgs += '-SkipKeyCapture' }
Write-Host ''
Write-Host '[설치 중] 명령줄 도구(CLI)'
$cliExit = Invoke-Installer $CliInstaller $cliArgs
if ($cliExit -eq 0) {
    Show-Box "명령줄 도구(CLI)도 함께 설치했습니다.`r`n`r`n대화 갱신 명령: `"$CliLauncher`" refresh`r`n`r`nCLI 는 Teams Viewer 와 같은 대화 아카이브를 사용합니다." 'Teams Record CLI 설치 완료' 'Information'
    Write-Host "[설치 완료] CLI: $CliLauncher"
} else {
    Show-Box "Teams Viewer 는 설치되었지만 명령줄 도구(CLI) 설치에 실패했습니다.`r`n`r`n로그: $CliInstallDir\logs" 'Teams Record CLI 설치 실패' 'Warning'
    Write-Host "[실패] CLI 설치 (exit $cliExit). 로그: $CliInstallDir\logs"
}
exit $cliExit
