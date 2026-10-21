[CmdletBinding()]
param([string]$DataBackup, [string]$InstallRoot, [string]$KnoxRoot = 'C:\mySingle\KnoxTeams', [switch]$SkipKeyCapture, [switch]$SkipDeps, [switch]$Elevated)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
$TaskName = 'TeamsRecordViewer'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$WorkDir = Join-Path $env:USERPROFILE 'teams-record-work'
$MarkerPath = Join-Path $WorkDir 'install-root.txt'
$KnoxExe = Join-Path $KnoxRoot 'KnoxTeams.exe'
$script:SelectedReason = ''
$script:InstallSucceeded = $false
$script:VersionVerified = $false
$script:FailedStage = ''
$script:FailureMessage = ''
$script:KnoxRestartResult = '재실행하지 않음'
$script:PythonExe = $null
$script:ProxyUri = $null

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Quote-Arg([string]$Value) { '"' + ($Value -replace '"', '\"') + '"' }

Add-Type -AssemblyName System.Windows.Forms
function Show-InstallerMessage([string]$Text, [string]$Caption, [System.Windows.Forms.MessageBoxButtons]$Buttons, [System.Windows.Forms.MessageBoxIcon]$Icon) {
    [System.Windows.Forms.MessageBox]::Show($Text, $Caption, $Buttons, $Icon)
}

if (-not $Elevated) {
    $startText = "Teams Record 설치를 시작합니다.`r`n`r`n다음 단계에서 관리자 권한(UAC) 승인 창이 나타나면 [예]를 눌러 주세요.`r`n`r`n설치 중 Knox Teams 메신저가 잠시 종료되었다가 설치가 끝나면 자동으로 다시 실행됩니다. 작성 중인 메시지가 있으면 먼저 보내거나 저장해 주세요."
    $answer = Show-InstallerMessage $startText 'Teams Record 설치' ([System.Windows.Forms.MessageBoxButtons]::OKCancel) ([System.Windows.Forms.MessageBoxIcon]::Information)
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        Write-Host '[취소됨] 사용자가 설치를 취소했습니다. 변경된 항목이 없습니다.'
        exit 0
    }
}

if (-not (Test-Admin)) {
    Write-Host '[설치 중] 관리자 권한을 요청합니다. UAC 창에서 [예]를 눌러 주세요.'
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
function Write-OK([string]$Message) { Write-Host "[확인됨] $Message" -ForegroundColor Green }
function Set-InstallStage([string]$Stage) { $script:FailedStage = $Stage; Write-Step $Stage }

function Refresh-EnvironmentPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user, $env:Path) | Where-Object { $_ }) -join ';'
}
function Resolve-PythonExecutable {
    Refresh-EnvironmentPath
    $found = Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $script:PythonExe = $found.Source; return }
    foreach ($candidate in @(
        (Join-Path $env:ProgramFiles 'Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe')
    )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $script:PythonExe = $candidate; return }
    }
    throw 'Python 3.11 실행 파일을 PATH 또는 표준 설치 경로에서 찾을 수 없습니다.'
}
function Initialize-SystemProxy {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy
    if (-not $proxy) { return }
    $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    $probe = [Uri]'https://pypi.org/'
    if (-not $proxy.IsBypassed($probe)) {
        $resolved = $proxy.GetProxy($probe)
        if ($resolved -and $resolved.AbsoluteUri -ne $probe.AbsoluteUri) {
            $script:ProxyUri = $resolved.AbsoluteUri
            $env:HTTP_PROXY = $script:ProxyUri
            $env:HTTPS_PROXY = $script:ProxyUri
            $env:PIP_PROXY = $script:ProxyUri
            Write-OK "시스템 프록시 전달: $($resolved.Authority)"
        }
    }
}

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
    Set-InstallStage '1/7 Teams Viewer 종료'
    try { Get-NetTCPConnection -LocalPort 8799 -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } } catch {}
    try { Get-CimInstance Win32_Process -Filter "Name='electron.exe'" | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($InstallRoot,[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } } catch {}
    Write-OK 'Teams Viewer 및 Electron 종료 완료'
}
function Stop-KnoxTeams {
    Set-InstallStage '2/7 Knox Teams 종료'
    Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 2
    Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-OK 'Knox Teams 종료 완료(실행 중이 아니었던 경우 포함)'
}
function Start-KnoxTeams {
    if (Test-Path -LiteralPath $KnoxExe -PathType Leaf) {
        try { Start-Process -FilePath $KnoxExe | Out-Null; $script:KnoxRestartResult = '재실행 완료'; Write-OK 'Knox Teams 재실행 완료' }
        catch { $script:KnoxRestartResult = "재실행 실패: $($_.Exception.Message)"; Write-Warning $script:KnoxRestartResult }
    } else { $script:KnoxRestartResult = "재실행 불가(파일 없음): $KnoxExe"; Write-Warning $script:KnoxRestartResult }
}
function Install-Frida {
    Resolve-PythonExecutable
    & $script:PythonExe -c 'import frida' 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Host '[건너뜀] frida: 이미 확인됨'; return }
    Write-Host '[설치 중] frida: pip 설치'
    & $script:PythonExe -m pip install frida
    if ($LASTEXITCODE -ne 0) { throw "frida installation failed (exit $LASTEXITCODE)" }
    & $script:PythonExe -c 'import frida'
    if ($LASTEXITCODE -ne 0) { throw 'frida import verification failed' }
    Write-Host '[설치 완료] frida'
}

try {
    Write-Host 'Teams Record 원클릭 설치 프로그램' -ForegroundColor White
    Write-Host "로그 경로    : $LogPath"
    Initialize-SystemProxy
    $InstallRoot = Resolve-InstallRoot
    Write-Host "설치 경로    : $InstallRoot"
    Write-Host "경로 선택 근거: $script:SelectedReason"
    Stop-ViewerProcesses
    Stop-KnoxTeams

    Set-InstallStage '3/7 의존성 및 프로그램 파일 설치'
    $setup = Join-Path $PSScriptRoot 'setup.ps1'
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Quote-Arg $setup),'-InstallRoot',(Quote-Arg $InstallRoot),'-KnoxRoot',(Quote-Arg $KnoxRoot))
    if ($DataBackup) { $args += @('-DataBackup',(Quote-Arg $DataBackup)) }
    if ($SkipDeps) { $args += '-SkipDependencies' }
    $p = Start-Process powershell.exe -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw "setup.ps1 실패(종료 코드 $($p.ExitCode))" }
    Resolve-PythonExecutable
    Write-Host '[설치 완료] 프로그램 파일, 자동 실행 작업, 바로가기, Electron'

    # Database key capture
    Set-InstallStage '4/7 데이터베이스 키 확인 및 캡처'
    if (-not $SkipDeps) { Install-Frida }
    $key = Join-Path $WorkDir 'dbkey.secret'
    if ($SkipKeyCapture) { Write-Warning '옵션에 따라 키 캡처를 건너뜁니다.' }
    elseif (Test-Path -LiteralPath $key) { Write-Host '[건너뜀] 기존 dbkey.secret을 보존합니다.' }
    elseif (-not (Test-Path -LiteralPath $KnoxExe)) { Write-Warning 'Knox Teams 실행 파일이 없어 키 캡처를 건너뜁니다.' }
    else {
        $env:KNOX_ROOT = $KnoxRoot
        & $env:ComSpec /d /c "`"$(Join-Path $PSScriptRoot 'capture-key.bat')`""
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $key)) { throw 'database key capture failed' }
        Write-OK 'dbkey.secret captured'
        Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    Set-InstallStage '5/7 첫 대화 내용 갱신'
    & $env:ComSpec /d /c "`"$(Join-Path $InstallRoot 'viewer\refresh_archive.bat')`""
    if ($LASTEXITCODE -ne 0) { throw "first refresh failed with exit code $LASTEXITCODE" }
    Write-OK '첫 대화 내용 갱신 완료'

    Set-InstallStage '6/7 Teams Viewer 실행 및 버전 확인'
    & $env:ComSpec /d /c "`"$(Join-Path $InstallRoot 'electron\teams-viewer-electron.bat')`""
    $expected = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
    for ($i=0; $i -lt 20; $i++) {
        try { $response = Invoke-RestMethod 'http://127.0.0.1:8799/api/version' -Proxy $null -TimeoutSec 2; if ([string]$response.local -eq $expected) { $script:VersionVerified = $true; break } } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $script:VersionVerified) { throw "viewer version verification failed; expected $expected" }
    Write-OK "viewer /api/version matches package VERSION $expected"

    Set-InstallStage '7/7 설치 정보 저장'
    Set-Content -LiteralPath $MarkerPath -Value $InstallRoot -Encoding UTF8
    $script:InstallSucceeded = $true
} catch {
    $script:FailureMessage = $_.Exception.Message
    Write-Host "[실패] $script:FailureMessage" -ForegroundColor Red
    Write-Host "로그 경로: $LogPath"
} finally {
    Write-Host ''; Write-Host '==== 설치 결과 요약 ====' -ForegroundColor White
    Write-Host "설치 경로          : $InstallRoot"
    Write-Host "경로 선택 근거     : $script:SelectedReason"
    Write-Host "버전 확인          : $script:VersionVerified"
    Write-Host "로그 경로          : $LogPath"
    Start-KnoxTeams
    Write-Host "Knox Teams        : $script:KnoxRestartResult"
    try { Stop-Transcript | Out-Null } catch {}
}
$exitCode = 1
if ($script:InstallSucceeded) {
    $packageVersion = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim()
    Write-Host '[설치 완료] Teams Record 설치가 완료되었습니다.' -ForegroundColor Green
    $completeText = "Teams Record 설치가 완료되었습니다.`r`n`r`n바탕화면의 [Teams Viewer] 바로가기로 실행할 수 있습니다.`r`n`r`n이후에는 로그인할 때마다 대화 내용이 자동으로 갱신되고, 새 버전이 나오면 뷰어에서 자동으로 알려 주며 업데이트 버튼으로 바로 갱신됩니다.`r`n`r`n설치 버전: $packageVersion"
    [void](Show-InstallerMessage $completeText 'Teams Record 설치 완료' ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Information))
    $exitCode = 0
} else {
    $failureText = "Teams Record 설치에 실패했습니다.`r`n`r`n실패 단계: $script:FailedStage`r`n원인: $script:FailureMessage`r`n로그 경로: $LogPath`r`nKnox Teams: $script:KnoxRestartResult"
    [void](Show-InstallerMessage $failureText 'Teams Record 설치 실패' ([System.Windows.Forms.MessageBoxButtons]::OK) ([System.Windows.Forms.MessageBoxIcon]::Error))
}
exit $exitCode
