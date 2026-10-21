[CmdletBinding()]
param(
    [ValidateSet('', 'viewer', 'cli')][string]$Mode = '',
    [string]$DataBackup,
    [string]$InstallRoot,
    [string]$KnoxRoot,
    [string]$CliInstallDir,
    [switch]$SkipKeyCapture,
    [switch]$SkipDeps,
    [switch]$NoPopup
)
# Asks whether to install the Teams Viewer.
#   Yes -> Viewer (publish\install.ps1) + CLI sharing the viewer archive
#   No  -> CLI only (lite\setup\lite-install.ps1, per-user, no administrator rights)
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

function Show-Box([string]$Text, [string]$Caption, [string]$Buttons, [string]$Icon) {
    [System.Windows.Forms.MessageBox]::Show($Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::$Buttons, [System.Windows.Forms.MessageBoxIcon]::$Icon).ToString()
}

function Invoke-Installer([string]$Script, [string[]]$ScriptArgs) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @ScriptArgs
    return $LASTEXITCODE
}

if (-not $Mode) {
    if ($NoPopup) {
        $Mode = 'cli'
    } else {
        $question = "Teams Viewer(대화 열람 화면)도 함께 설치할까요?`r`n`r`n" +
            "예: Teams Viewer + 명령줄 도구(CLI) 설치`r`n" +
            "     관리자 권한(UAC) 승인이 필요하며 Python·Node.js·Electron 을 설치합니다.`r`n`r`n" +
            "아니오: 명령줄 도구(CLI)만 설치`r`n" +
            "     관리자 권한 없이 설치되며, 에이전트가 대화 내용을 갱신할 때 사용합니다.`r`n`r`n" +
            "취소: 설치하지 않음"
        $answer = Show-Box $question 'Teams Record 설치 유형 선택' 'YesNoCancel' 'Question'
        if ($answer -eq 'Cancel') { Write-Host '[취소됨] 설치하지 않았습니다.'; exit 0 }
        $Mode = if ($answer -eq 'Yes') { 'viewer' } else { 'cli' }
    }
}
Write-Host "[선택] 설치 유형: $(if ($Mode -eq 'viewer') { 'Teams Viewer + CLI' } else { 'CLI 만' })"

$cliArgs = @('-InstallDir', $CliInstallDir)
if ($SkipKeyCapture) { $cliArgs += '-SkipKeyCapture' }

if ($Mode -eq 'cli') {
    if ($NoPopup) { $cliArgs += '-NoPopup' }
    exit (Invoke-Installer $CliInstaller $cliArgs)
}

# Viewer first; it handles UAC, dependencies, key capture and Knox Teams restart.
$viewerArgs = @()
if ($DataBackup) { $viewerArgs += @('-DataBackup', $DataBackup) }
if ($InstallRoot) { $viewerArgs += @('-InstallRoot', $InstallRoot) }
if ($KnoxRoot) { $viewerArgs += @('-KnoxRoot', $KnoxRoot) }
if ($SkipKeyCapture) { $viewerArgs += '-SkipKeyCapture' }
if ($SkipDeps) { $viewerArgs += '-SkipDeps' }
$started = Get-Date
$viewerExit = Invoke-Installer $ViewerInstaller $viewerArgs
$viewerDone = (Test-Path -LiteralPath $MarkerPath) -and ((Get-Item -LiteralPath $MarkerPath).LastWriteTime -ge $started.AddSeconds(-2))
if ($viewerExit -ne 0 -or -not $viewerDone) {
    Write-Host '[건너뜀] Teams Viewer 설치가 완료되지 않아 CLI 설치를 진행하지 않습니다.'
    exit $(if ($viewerExit -ne 0) { $viewerExit } else { 1 })
}

# CLI shares the viewer's archive and key, so both always see the same conversations.
$viewerRoot = (Get-Content -LiteralPath $MarkerPath -Raw).Trim()
$cliArgs += @('-NoPopup', '-ArchivePath', (Join-Path $viewerRoot 'teams-archive.db'))
Write-Host ''
Write-Host '[설치 중] 명령줄 도구(CLI)'
$cliExit = Invoke-Installer $CliInstaller $cliArgs
if ($cliExit -eq 0) {
    $text = "명령줄 도구(CLI)도 함께 설치했습니다.`r`n`r`n대화 갱신 명령: `"$CliLauncher`" refresh`r`n`r`nCLI 는 Teams Viewer 와 같은 대화 아카이브를 사용합니다."
    if (-not $NoPopup) { [void](Show-Box $text 'Teams Record CLI 설치 완료' 'OK' 'Information') }
    Write-Host "[설치 완료] CLI: $CliLauncher"
} else {
    $text = "Teams Viewer 는 설치되었지만 명령줄 도구(CLI) 설치에 실패했습니다.`r`n`r`n로그: $CliInstallDir\logs"
    if (-not $NoPopup) { [void](Show-Box $text 'Teams Record CLI 설치 실패' 'OK' 'Warning') }
    Write-Host "[실패] CLI 설치 (exit $cliExit). 로그: $CliInstallDir\logs"
}
exit $cliExit
