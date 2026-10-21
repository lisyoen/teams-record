[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'teams-record-lite'),
    [switch]$NoPopup,
    [switch]$SkipKeyCapture,
    [string]$FridaVersion = '',
    [string]$ArchivePath = ''
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$PackageRoot = Split-Path -Parent $PSScriptRoot
# Two layouts: the lite ZIP (app\ is complete) or the full repository/package (lite\ inside the repo).
$RepoLayout = -not (Test-Path -LiteralPath (Join-Path $PackageRoot 'app\merge_archive.py'))
$RepoRoot = Split-Path -Parent $PackageRoot
$VersionFile = if ($RepoLayout) { Join-Path $RepoRoot 'VERSION' } else { Join-Path $PackageRoot 'VERSION' }
$Version = (Get-Content -LiteralPath $VersionFile -Raw).Trim()
$PythonVersion = '3.11.9'
$PythonEmbedUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$PythonEmbedSha256 = '009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b'
$GetPipUrl = 'https://bootstrap.pypa.io/get-pip.py'
$RuntimeId = "py$PythonVersion-embed+frida"
$Launcher = Join-Path $InstallDir 'teams-record-lite.bat'
$script:Stage = '준비'
$script:ProxyUri = $null

Add-Type -AssemblyName System.Windows.Forms

function Show-Message([string]$Text, [string]$Caption, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    if ($NoPopup) { return 'OK' }
    return [System.Windows.Forms.MessageBox]::Show($Text, $Caption,
        [System.Windows.Forms.MessageBoxButtons]::$Buttons, [System.Windows.Forms.MessageBoxIcon]::$Icon).ToString()
}

function Set-Stage([string]$Name) {
    $script:Stage = $Name
    Write-Host ''
    Write-Host "=== $Name ==="
}

function Initialize-SystemProxy {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy
    if (-not $proxy) { return }
    $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    $probe = [Uri]'https://www.python.org/'
    if (-not $proxy.IsBypassed($probe)) {
        $resolved = $proxy.GetProxy($probe)
        if ($resolved -and $resolved.AbsoluteUri -ne $probe.AbsoluteUri) {
            $script:ProxyUri = $resolved.AbsoluteUri
            $env:HTTP_PROXY = $script:ProxyUri
            $env:HTTPS_PROXY = $script:ProxyUri
            $env:PIP_PROXY = $script:ProxyUri
            Write-Host "[확인됨] 시스템 프록시: $($resolved.Authority)"
        }
    }
}

function Invoke-Download([string]$Uri, [string]$OutFile) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $params = @{ Uri = $Uri; OutFile = $OutFile; UseBasicParsing = $true }
    if ($script:ProxyUri) { $params.Proxy = $script:ProxyUri; $params.ProxyUseDefaultCredentials = $true }
    $old = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest @params } finally { $ProgressPreference = $old }
}

function Invoke-Cli([string[]]$CliArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $Launcher @CliArgs 2>$null
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $text = ($raw | ForEach-Object { $_.ToString() }) -join "`n"
    $json = $null
    $start = $text.IndexOf('{')
    if ($start -ge 0) {
        try { $json = $text.Substring($start) | ConvertFrom-Json } catch { $json = $null }
    }
    return [pscustomobject]@{ Code = $code; Text = $text; Json = $json }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Install-Payload {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    foreach ($d in 'work', 'data', 'logs', 'setup') { New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir $d) | Out-Null }
    $app = Join-Path $InstallDir 'app'
    $old = Join-Path $InstallDir 'app.old'
    $new = Join-Path $InstallDir 'app.new'
    if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
    if (Test-Path -LiteralPath $app) {
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force }
        Move-Item -LiteralPath $app -Destination $old
    }
    if ($RepoLayout) {
        New-Item -ItemType Directory -Force -Path $app | Out-Null
        $sources = [ordered]@{
            'trlite.py' = 'lite\app\trlite.py'
            'merge_archive.py' = 'viewer\merge_archive.py'
            'decrypt_export.js' = 'publish\work\decrypt_export.js'
            'sqlite3.js' = 'publish\work\sqlite3.js'
            'sqlite3-binding.js' = 'publish\work\sqlite3-binding.js'
            'trace.js' = 'publish\work\trace.js'
            'spawn_key.py' = 'publish\work\spawn_key.py'
        }
        foreach ($name in $sources.Keys) {
            Copy-Item -LiteralPath (Join-Path $RepoRoot $sources[$name]) -Destination (Join-Path $app $name) -Force
        }
    } else {
        Copy-Item -LiteralPath (Join-Path $PackageRoot 'app') -Destination $app -Recurse -Force
    }
    Write-Utf8NoBom (Join-Path $app 'VERSION') "$Version`r`n"
    Write-Utf8NoBom (Join-Path $InstallDir 'VERSION') "$Version`r`n"
    foreach ($f in 'teams-record-lite.bat', 'uninstall.bat', 'README.md', 'AGENT.md') {
        Copy-Item -LiteralPath (Join-Path $PackageRoot $f) -Destination (Join-Path $InstallDir $f) -Force
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lite-uninstall.ps1') -Destination (Join-Path $InstallDir 'setup\lite-uninstall.ps1') -Force
    Write-Host "[설치 완료] 프로그램 파일: $app"
}

function Test-Runtime {
    $py = Join-Path $InstallDir 'runtime\python\python.exe'
    $marker = Join-Path $InstallDir 'runtime\runtime-id.txt'
    if (-not (Test-Path -LiteralPath $py) -or -not (Test-Path -LiteralPath $marker)) { return $false }
    if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne $RuntimeId) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $py -c 'import frida, sqlite3' 2>$null } finally { $ErrorActionPreference = $prev }
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Native([string]$Exe, [string[]]$NativeArgs, [string]$What) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Exe @NativeArgs 2>&1 | ForEach-Object { Write-Host "  $_" } } finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "$What 실패(exit $LASTEXITCODE)" }
}

function Install-Runtime {
    if (Test-Runtime) { Write-Host '[건너뜀] Python 실행 환경과 frida: 이미 설치됨'; return }
    $runtime = Join-Path $InstallDir 'runtime'
    $pyDir = Join-Path $runtime 'python'
    if (Test-Path -LiteralPath $runtime) { Remove-Item -LiteralPath $runtime -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $pyDir | Out-Null

    Write-Host "[설치 중] Python $PythonVersion (설치 폴더 전용, 시스템 변경 없음)"
    $zip = Join-Path $env:TEMP "python-$PythonVersion-embed-amd64.zip"
    Invoke-Download $PythonEmbedUrl $zip
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $PythonEmbedSha256) { throw "Python 다운로드 파일 검증 실패(SHA256 불일치): $zip" }
    Expand-Archive -LiteralPath $zip -DestinationPath $pyDir -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    $pth = Get-ChildItem -LiteralPath $pyDir -Filter 'python*._pth' | Select-Object -First 1
    if (-not $pth) { throw 'Python 경로 설정 파일(._pth)을 찾지 못했습니다.' }
    $lines = Get-Content -LiteralPath $pth.FullName | ForEach-Object { if ($_ -match '^\s*#\s*import site') { 'import site' } else { $_ } }
    if (-not ($lines -contains 'import site')) { $lines += 'import site' }
    Set-Content -LiteralPath $pth.FullName -Value $lines -Encoding ascii
    $py = Join-Path $pyDir 'python.exe'
    Write-Host '[설치 완료] Python'

    Write-Host '[설치 중] pip'
    $getPip = Join-Path $env:TEMP 'teams-record-lite-get-pip.py'
    Invoke-Download $GetPipUrl $getPip
    Invoke-Native $py @($getPip, '--no-warn-script-location') 'pip 설치'
    Remove-Item -LiteralPath $getPip -Force -ErrorAction SilentlyContinue
    Write-Host '[설치 완료] pip'

    Write-Host '[설치 중] frida (DB 키 캡처용)'
    $spec = if ($FridaVersion) { "frida==$FridaVersion" } else { 'frida' }
    Invoke-Native $py @('-m', 'pip', 'install', '--no-warn-script-location', $spec) 'frida 설치'
    Invoke-Native $py @('-c', 'import frida, sqlite3') 'frida 설치 확인'
    Set-Content -LiteralPath (Join-Path $runtime 'runtime-id.txt') -Value $RuntimeId -Encoding ascii
    Write-Host '[설치 완료] frida'
}

function Initialize-Config {
    $config = Join-Path $InstallDir 'config.json'
    if (-not (Test-Path -LiteralPath $config)) {
        $default = [ordered]@{
            update_url = 'https://github.com/lisyoen/teams-record/releases/latest/download/teams-record-lite-latest.json'
            auto_update = $true
            update_interval_hours = 24
            knox_root = ''
        }
        Write-Utf8NoBom $config ($default | ConvertTo-Json)
        Write-Host "[설치 완료] 설정 파일: $config"
    } else {
        Write-Host '[건너뜀] 기존 설정 파일 보존'
    }
    if ($ArchivePath) {
        $cfg = [ordered]@{}
        (Get-Content -LiteralPath $config -Raw -Encoding utf8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value }
        $cfg['archive_path'] = [System.IO.Path]::GetFullPath($ArchivePath)
        Write-Utf8NoBom $config ($cfg | ConvertTo-Json)
        Write-Host "[확인됨] Teams Viewer 와 같은 대화 아카이브 사용: $($cfg['archive_path'])"
    }
    $statePath = Join-Path $InstallDir 'state.json'
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $statePath) {
        try { (Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $state[$_.Name] = $_.Value } } catch { }
    }
    $state['runtime'] = $RuntimeId
    $state['installed_version'] = $Version
    $state['staged_update'] = $null
    Write-Utf8NoBom $statePath ($state | ConvertTo-Json)
}

function Ensure-Key {
    $key = Join-Path $InstallDir 'work\dbkey.secret'
    $legacy = Join-Path $env:USERPROFILE 'teams-record-work\dbkey.secret'
    if (Test-Path -LiteralPath $key) { Write-Host '[건너뜀] 기존 DB 키 보존'; return }
    if (Test-Path -LiteralPath $legacy) {
        Copy-Item -LiteralPath $legacy -Destination $key -Force
        Write-Host '[확인됨] 기존 Teams Record 설치의 DB 키를 재사용합니다.'
        return
    }
    if ($SkipKeyCapture) { Write-Warning 'DB 키 캡처를 건너뜁니다. 나중에 capture-key 를 실행해 주세요.'; return }
    Write-Host '[진행 중] Knox Teams 를 종료하고 DB 키를 캡처합니다. 잠시 후 Knox Teams 가 다시 실행됩니다.'
    $r = Invoke-Cli @('capture-key')
    if ($r.Code -ne 0) {
        $msg = if ($r.Json) { $r.Json.message } else { $r.Text }
        throw "DB 키 캡처 실패: $msg"
    }
    Write-Host '[설치 완료] DB 키 캡처, Knox Teams 재실행'
}

# ------------------------------------------------------------------ main
New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'logs') | Out-Null
$LogPath = Join-Path $InstallDir ("logs\install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -LiteralPath $LogPath -Append | Out-Null

$startText = "Teams Record Lite $Version 설치를 시작합니다.`r`n`r`n" +
    "관리자 권한은 필요하지 않으며, 설치 위치는 다음과 같습니다.`r`n$InstallDir`r`n`r`n" +
    "DB 키가 아직 없으면 설치 중 Knox Teams 메신저가 잠시 종료되었다가 자동으로 다시 실행됩니다. " +
    "작성 중인 메시지가 있으면 먼저 보내거나 저장해 주세요."
if ((Show-Message $startText 'Teams Record Lite 설치' 'OKCancel' 'Information') -ne 'OK') {
    Write-Host '사용자가 설치를 취소했습니다. 변경 사항이 없습니다.'
    Stop-Transcript | Out-Null
    exit 10
}

$exitCode = 0
$summary = ''
try {
    Set-Stage '1/5 네트워크 설정 확인'
    Initialize-SystemProxy

    Set-Stage '2/5 프로그램 파일 설치'
    Install-Payload

    Set-Stage '3/5 Python 실행 환경 설치'
    Install-Runtime
    Initialize-Config

    Set-Stage '4/5 DB 키 확인'
    Ensure-Key

    Set-Stage '5/5 첫 대화 내용 갱신'
    $r = Invoke-Cli @('refresh', '--no-update')
    if ($r.Code -ne 0) {
        $msg = if ($r.Json) { $r.Json.message } else { $r.Text }
        throw "첫 갱신 실패: $msg"
    }
    $kt = $r.Json.totals.TB_KtMessage
    $km = $r.Json.totals.TB_KmMessage
    $summary = "보관된 메시지: 채널 $kt 건, 대화방 $km 건"
    Write-Host "[설치 완료] $summary"
}
catch {
    $exitCode = 1
    $err = $_.Exception.Message
    Write-Host "[실패] $($script:Stage): $err"
    $knoxRunning = [bool](Get-Process -Name KnoxTeams -ErrorAction SilentlyContinue)
    $knoxText = if ($knoxRunning) { 'Knox Teams 는 실행 중입니다.' } else { 'Knox Teams 가 실행 중이 아니면 직접 실행해 주세요.' }
    [void](Show-Message ("Teams Record Lite 설치에 실패했습니다.`r`n`r`n단계: $($script:Stage)`r`n원인: $err`r`n`r`n$knoxText`r`n로그: $LogPath") 'Teams Record Lite 설치 실패' 'OK' 'Error')
}

if ($exitCode -eq 0) {
    $doneText = "Teams Record Lite $Version 설치가 완료되었습니다.`r`n`r`n$summary`r`n`r`n" +
        "설치 위치: $InstallDir`r`n대화 갱신 명령: `"$Launcher`" refresh`r`n`r`n" +
        "이후 새 버전은 갱신할 때 자동으로 확인되어, 내려받은 뒤 다음 실행부터 자동으로 적용됩니다."
    Write-Host ''
    Write-Host '설치가 완료되었습니다.'
    Write-Host "대화 갱신 명령: `"$Launcher`" refresh"
    [void](Show-Message $doneText 'Teams Record Lite 설치 완료' 'OK' 'Information')
}
Write-Host "설치 로그: $LogPath"
Stop-Transcript | Out-Null
exit $exitCode
