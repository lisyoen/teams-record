[CmdletBinding()]
param(
    [string]$DataBackup,
    [string]$InstallRoot,
    [string]$KnoxRoot,
    [switch]$ShortcutOnly,
    [switch]$SkipDependencies,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding

$TaskName = 'TeamsRecordViewer'

function Get-DefaultInstallRoot {
    $scriptDrive = Split-Path -Qualifier $PSScriptRoot
    $sysDrive = $env:SystemDrive

    if ($scriptDrive -and $sysDrive -and $scriptDrive -ieq $sysDrive) {
        return (Join-Path $env:LOCALAPPDATA 'teams-record')
    }
    if ($scriptDrive) {
        return (Join-Path ($scriptDrive + '\') 'teams-record')
    }
    return (Join-Path $env:LOCALAPPDATA 'teams-record')
}

if (-not $InstallRoot) {
    $InstallRoot = Get-DefaultInstallRoot
}
if (-not $KnoxRoot) { $KnoxRoot = 'C:\mySingle\KnoxTeams' }
$ViewerDir = Join-Path $InstallRoot 'viewer'
$ElectronDir = Join-Path $InstallRoot 'electron'
$ThumbsDir = Join-Path $InstallRoot 'thumbs'
$WorkDir = Join-Path $env:USERPROFILE 'teams-record-work'
$DesktopShortcut = Join-Path $env:USERPROFILE 'Desktop\Teams Viewer.lnk'
$ViewerBat = Join-Path $ViewerDir 'teams-viewer.bat'
$StartBat = Join-Path $ViewerDir 'start_viewer.bat'
$ElectronLauncher = Join-Path $ElectronDir 'teams-viewer-electron.bat'
$ElectronExe = Join-Path $ElectronDir 'node_modules\electron\dist\electron.exe'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$CurrentUser = (& whoami).Trim()

$Summary = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]
$script:PythonExe = $null
$script:NodeExe = $null
$script:NpmExe = $null
$script:ProxyUri = $null

function Invoke-SchtasksQuiet([string]$ArgumentLine) {
    & $env:ComSpec /d /c "schtasks.exe $ArgumentLine >nul 2>nul"
    return $LASTEXITCODE
}

function Add-Summary([string]$Message) {
    $Summary.Add($Message) | Out-Null
    Write-Host "[확인됨] $Message"
}

function Write-ComponentStatus([string]$Component, [string]$Status, [string]$Detail = '') {
    $suffix = if ($Detail) { ": $Detail" } else { '' }
    Write-Host ("[{0}] {1}{2}" -f $Status, $Component, $suffix)
}

function Add-WarningLine([string]$Message) {
    $Warnings.Add($Message) | Out-Null
    Write-Warning $Message
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-Admin) { return }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($DataBackup) { $args += @('-DataBackup', "`"$DataBackup`"") }
    if ($InstallRoot) { $args += @('-InstallRoot', "`"$InstallRoot`"") }
    if ($KnoxRoot) { $args += @('-KnoxRoot', "`"$KnoxRoot`"") }
    if ($ShortcutOnly) { $args += '-ShortcutOnly' }
    if ($SkipDependencies) { $args += '-SkipDependencies' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs
    exit
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-RequiredSources {
    $items = @()

    $viewerSource = Join-Path $RepoRoot 'viewer'
    foreach ($name in @('server.py', 'merge_archive.py', 'refresh_archive.bat', 'start_viewer.bat', 'teams-viewer.bat', 'update-check.bat')) {
        $items += [pscustomobject]@{
            Group = 'viewer'
            Name = $name
            Source = Join-Path $viewerSource $name
            Destination = Join-Path $ViewerDir $name
        }
    }

    $items += [pscustomobject]@{
        Group = 'viewer'; Name = 'VERSION'; Source = Join-Path $RepoRoot 'VERSION'; Destination = Join-Path $ViewerDir 'VERSION'
    }

    $workSource = Join-Path $PSScriptRoot 'work'
    foreach ($name in @('decrypt_export.js', 'sqlite3.js', 'sqlite3-binding.js', 'trace.js', 'spawn_key.py', 'hook_napi.py')) {
        $items += [pscustomobject]@{
            Group = 'work'
            Name = $name
            Source = Join-Path $workSource $name
            Destination = Join-Path $WorkDir $name
        }
    }

    $electronSource = Join-Path $RepoRoot 'electron'
    foreach ($name in @('main.js', 'package.json', 'package-lock.json', 'teams-viewer-electron.bat')) {
        $items += [pscustomobject]@{
            Group = 'electron'
            Name = $name
            Source = Join-Path $electronSource $name
            Destination = Join-Path $ElectronDir $name
        }
    }
    $items += [pscustomobject]@{
        Group = 'electron'
        Name = 'assets\icon.ico'
        Source = Join-Path $electronSource 'assets\icon.ico'
        Destination = Join-Path $ElectronDir 'assets\icon.ico'
    }

    return $items
}

function Test-Prerequisites([switch]$Quiet) {
    $missing = @()
    foreach ($item in Get-RequiredSources) {
        if (-not (Test-Path -LiteralPath $item.Source -PathType Leaf)) {
            $missing += $item
        }
    }

    if ($missing.Count -eq 0) {
        if (-not $Quiet) { Add-Summary "required source files are present" }
        return $true
    }

    Write-Host "[MISSING] required source files"
    foreach ($item in $missing) {
        Write-Host " - [$($item.Group)] $($item.Source)"
    }
    return $false
}

function Copy-RequiredFile([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required source file is missing: $Source"
    }
    Ensure-Directory (Split-Path -Parent $Destination)
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Refresh-EnvironmentPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $current = $env:Path
    $env:Path = (@($machine, $user, $current) | Where-Object { $_ }) -join ';'
}

function Resolve-Executable([string]$Command, [string[]]$FallbackPaths) {
    foreach ($candidate in $FallbackPaths) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    $found = Get-Command $Command -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.Source }
    return $null
}

function Resolve-DependencyExecutables {
    Refresh-EnvironmentPath
    $script:PythonExe = Resolve-Executable 'python.exe' @(
        (Join-Path $env:ProgramFiles 'Python311\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe')
    )
    $nodeRoot = Join-Path $env:ProgramFiles 'nodejs'
    $script:NodeExe = Resolve-Executable 'node.exe' @((Join-Path $nodeRoot 'node.exe'))
    $script:NpmExe = Resolve-Executable 'npm.cmd' @((Join-Path $nodeRoot 'npm.cmd'))
}

function Initialize-SystemProxy {
    $proxy = [System.Net.WebRequest]::DefaultWebProxy
    if (-not $proxy) { return }
    $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    $probe = [Uri]'https://nodejs.org/'
    if (-not $proxy.IsBypassed($probe)) {
        $resolved = $proxy.GetProxy($probe)
        if ($resolved -and $resolved.AbsoluteUri -ne $probe.AbsoluteUri) {
            $script:ProxyUri = $resolved.AbsoluteUri
            $env:HTTP_PROXY = $script:ProxyUri
            $env:HTTPS_PROXY = $script:ProxyUri
            $env:PIP_PROXY = $script:ProxyUri
            $env:NPM_CONFIG_PROXY = $script:ProxyUri
            $env:NPM_CONFIG_HTTPS_PROXY = $script:ProxyUri
            Write-ComponentStatus '시스템 프록시' '확인됨' $resolved.Authority
        }
    }
}

function Invoke-SystemDownload([string]$Uri, [string]$OutFile = '') {
    $params = @{ Uri = $Uri; UseBasicParsing = $true }
    if ($OutFile) { $params.OutFile = $OutFile }
    if ($script:ProxyUri) {
        $params.Proxy = $script:ProxyUri
        $params.ProxyUseDefaultCredentials = $true
    }
    Invoke-WebRequest @params
}

function Get-PythonVersionLine {
    if (-not $script:PythonExe) { Resolve-DependencyExecutables }
    if (-not $script:PythonExe) { return $null }
    try {
        return (& $script:PythonExe --version 2>&1 | Select-Object -First 1).ToString()
    } catch {
        return $null
    }
}

function Get-PythonVersion {
    $line = Get-PythonVersionLine
    if ($line -and $line -match 'Python\s+(\d+)\.(\d+)\.(\d+)') {
        return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    }
    return $null
}

function Install-Python311FromInstaller {
    Write-ComponentStatus 'Python 3.11' '설치 중' 'python.org 설치 파일 다운로드'
    $installer = Join-Path $env:TEMP 'python-3.11-amd64.exe'
    $url = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe'
    Invoke-SystemDownload -Uri $url -OutFile $installer

    $process = Start-Process -FilePath $installer -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0' -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Python 3.11 installer failed with exit code $($process.ExitCode)."
    }
}

function Install-Python311 {
    $version = Get-PythonVersion
    if ($version -and $version.Major -eq 3 -and $version.Minor -eq 11) {
        Write-ComponentStatus 'Python 3.11' '건너뜀' "이미 확인됨 ($version)"
        Add-Summary "Python $version 확인됨"
        return
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-ComponentStatus 'Python 3.11' '설치 중' 'winget 사용'
        & winget install -e --id Python.Python.3.11 --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Add-WarningLine "winget Python 설치 실패(종료 코드 $LASTEXITCODE). python.org 설치 파일로 다시 시도합니다."
            Install-Python311FromInstaller
        }
    } else {
        Write-ComponentStatus 'winget' '건너뜀' '사용할 수 없어 python.org 설치 파일을 사용합니다'
        Install-Python311FromInstaller
    }

    Resolve-DependencyExecutables
    $version = Get-PythonVersion
    if (-not $version -or $version.Major -ne 3 -or $version.Minor -ne 11) {
        throw 'Python 3.11 install completed, but python --version is still not Python 3.11.'
    }
    Write-ComponentStatus 'Python 3.11' '설치 완료' $script:PythonExe
    Add-Summary "Python $version 설치 완료"
}

function Get-NodeVersion {
    if (-not $script:NodeExe) { Resolve-DependencyExecutables }
    if (-not $script:NodeExe) { return $null }
    try {
        $line = (& $script:NodeExe --version 2>&1 | Select-Object -First 1).ToString()
        if ($line -match 'v(\d+)\.(\d+)\.(\d+)') {
            return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
    } catch {}
    return $null
}

function Install-NodeFromOfficialMsi {
    Write-ComponentStatus 'Node.js 22 LTS' '설치 중' 'nodejs.org 설치 파일 다운로드 및 SHA256 검증'
    $baseUrl = 'https://nodejs.org/dist/latest-v22.x'
    $sums = (Invoke-SystemDownload -Uri "$baseUrl/SHASUMS256.txt").Content
    $match = [regex]::Match($sums, '(?m)^([0-9a-f]{64})\s+(node-v([0-9.]+)-x64\.msi)$')
    if (-not $match.Success) { throw 'Could not resolve the latest Node.js 22 x64 MSI.' }
    $fileName = $match.Groups[2].Value
    $expectedHash = $match.Groups[1].Value
    $installer = Join-Path $env:TEMP $fileName
    Invoke-SystemDownload -Uri "$baseUrl/$fileName" -OutFile $installer
    $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Node.js installer checksum mismatch: $installer" }
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$installer`"", '/qn', '/norestart') -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Node.js installer failed with exit code $($process.ExitCode)." }
}

function Install-NodeLts {
    $version = Get-NodeVersion
    if ($version -and $version.Major -ge 18 -and $script:NpmExe) {
        Write-ComponentStatus 'Node.js/npm' '건너뜀' "이미 확인됨 ($version)"
        Add-Summary "Node.js $version 및 npm 확인됨"
        return
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-ComponentStatus 'Node.js 22 LTS' '설치 중' 'winget 사용'
        & winget install -e --id OpenJS.NodeJS.LTS --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Add-WarningLine "winget Node.js 설치 실패(종료 코드 $LASTEXITCODE). nodejs.org 설치 파일로 다시 시도합니다."
            Install-NodeFromOfficialMsi
        }
    } else {
        Install-NodeFromOfficialMsi
    }
    Resolve-DependencyExecutables
    $version = Get-NodeVersion
    if (-not $version -or $version.Major -lt 18) { throw 'Node.js 18 or newer is required.' }
    if (-not $script:NpmExe) { throw 'Node.js 설치 후 npm.cmd를 찾을 수 없습니다.' }
    Write-ComponentStatus 'Node.js/npm' '설치 완료' $script:NodeExe
    Add-Summary "Node.js $version 및 npm 설치 완료"
}

function Install-ElectronDependencies {
    if (-not (Test-Path -LiteralPath (Join-Path $ElectronDir 'package-lock.json'))) {
        throw "Electron package-lock.json is missing: $ElectronDir"
    }
    Write-ComponentStatus 'Electron' '설치 중' 'npm ci 실행'
    Push-Location $ElectronDir
    try {
        # Contract equivalent: npm.cmd ci --include=dev --no-audit --no-fund
        & $script:NpmExe ci --include=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath $ElectronExe -PathType Leaf)) {
        throw "Electron executable was not installed: $ElectronExe"
    }
    Write-ComponentStatus 'Electron' '설치 완료' $ElectronExe
    Add-Summary "Electron npm 의존성 설치 및 확인 완료"
}

function Install-Files {
    if (-not (Test-Prerequisites -Quiet)) {
        throw 'Required source file check failed.'
    }

    Ensure-Directory $ViewerDir
    Ensure-Directory $ElectronDir
    Ensure-Directory $ThumbsDir
    Ensure-Directory $WorkDir

    foreach ($item in Get-RequiredSources) {
        Copy-RequiredFile $item.Source $item.Destination
    }

    if (-not (Test-Path -LiteralPath $ViewerBat)) {
        throw "Viewer batch was not installed: $ViewerBat"
    }
    Add-Summary "viewer, Electron app, and decrypt runtime files deployed"
}

function Notice-Key {
    $dest = Join-Path $WorkDir 'dbkey.secret'

    if (Test-Path -LiteralPath $dest) {
        Add-Summary "existing dbkey.secret kept in WORK"
        Write-Host "No key is copied from publish or git."
        return
    }

    Add-WarningLine "dbkey.secret is missing. This is expected on first install. After KnoxTeams login, run publish\capture-key.bat once before opening Teams Viewer."
}

function Test-KnoxRoot {
    $knoxExe = Join-Path $KnoxRoot 'KnoxTeams.exe'
    if (Test-Path -LiteralPath $knoxExe -PathType Leaf) {
        Add-Summary "KnoxTeams found: $knoxExe"
        return
    }
    Add-WarningLine "KnoxTeams was not found at $knoxExe. If Knox Teams is installed elsewhere, rerun setup with -KnoxRoot or set KNOX_ROOT before refresh/capture."
}

function Test-DataBackupPath {
    if (-not $DataBackup) { return }
    if (-not (Test-Path -LiteralPath $DataBackup)) {
        throw "DataBackup does not exist: $DataBackup"
    }

    $dataRoot = (Resolve-Path -LiteralPath $DataBackup).Path.TrimEnd('\')
    $publishRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
    if ($dataRoot.Equals($publishRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $dataRoot.StartsWith("$publishRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "DataBackup must be an external backup folder, not a path under publish: $DataBackup"
    }
}

function Restore-Data {
    if (-not $DataBackup) {
        Add-WarningLine "DataBackup was not provided. First refresh will rebuild from the live KnoxTeams DB retention window."
        return
    }
    Test-DataBackupPath

    $archive = Join-Path $DataBackup 'teams-archive.db'
    if ((Test-Path -LiteralPath $archive) -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'teams-archive.db'))) {
        Copy-Item -LiteralPath $archive -Destination (Join-Path $InstallRoot 'teams-archive.db') -Force
        Add-Summary "teams-archive.db restored"
    } elseif (Test-Path -LiteralPath (Join-Path $InstallRoot 'teams-archive.db')) {
        Add-Summary "existing teams-archive.db preserved"
    } else {
        Add-WarningLine "DataBackup does not contain teams-archive.db"
    }

    $backupThumbs = Join-Path $DataBackup 'thumbs'
    if (Test-Path -LiteralPath $backupThumbs) {
        Ensure-Directory $ThumbsDir
        Get-ChildItem -LiteralPath $backupThumbs -File -Recurse | ForEach-Object {
            $relative = $_.FullName.Substring($backupThumbs.Length).TrimStart('\')
            $destination = Join-Path $ThumbsDir $relative
            if (-not (Test-Path -LiteralPath $destination)) {
                Ensure-Directory (Split-Path -Parent $destination)
                Copy-Item -LiteralPath $_.FullName -Destination $destination
            }
        }
        Add-Summary "missing thumbs restored; existing files preserved"
    } else {
        Add-WarningLine "DataBackup does not contain thumbs"
    }
}

function Register-ViewerTask {
    if (-not (Test-Path -LiteralPath $StartBat)) {
        throw "Scheduled task action is missing: $StartBat"
    }

    if ((Invoke-SchtasksQuiet "/Query /TN `"$TaskName`"") -eq 0) {
        [void](Invoke-SchtasksQuiet "/Delete /TN `"$TaskName`" /F")
    }

    $taskRun = "cmd /c `"`"$StartBat`"`""
    $createArgs = "/Create /TN `"$TaskName`" /SC ONLOGON /TR `"$taskRun`" /RU `"$CurrentUser`" /RL HIGHEST /F"
    if ((Invoke-SchtasksQuiet $createArgs) -ne 0) {
        throw "Failed to register scheduled task: $TaskName"
    }
    Add-Summary "scheduled task registered: $TaskName"
}

function New-DesktopShortcut {
    if (-not (Test-Path -LiteralPath $ElectronExe -PathType Leaf)) {
        throw "Electron executable is missing: $ElectronExe"
    }
    Ensure-Directory (Split-Path -Parent $DesktopShortcut)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($DesktopShortcut)
    $shortcut.TargetPath = $ElectronExe
    $shortcut.Arguments = "`"$ElectronDir`""
    $shortcut.WorkingDirectory = $ElectronDir
    $shortcut.Description = 'Teams Viewer Electron app'
    $icon = Join-Path $ElectronDir 'assets\icon.ico'
    if (Test-Path -LiteralPath $icon -PathType Leaf) { $shortcut.IconLocation = $icon }
    $shortcut.Save()
    Add-Summary "desktop Electron shortcut created: $DesktopShortcut"
}

function Write-CheckLine([string]$Status, [string]$Message) {
    Write-Host ("[{0}] {1}" -f $Status, $Message)
}

function Test-PathWritableStatus([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Container) {
        try {
            [void][System.IO.Directory]::GetAccessControl($Path)
            return 'exists; ACL readable (write not modified)'
        } catch {
            return "exists; ACL check failed: $($_.Exception.Message)"
        }
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
        return "missing; parent exists: $parent"
    }
    return 'missing; parent path is also missing'
}

function Invoke-CheckOnly {
    Write-Host "teams-record setup CheckOnly"
    Write-Host "RepoRoot: $RepoRoot"
    Write-Host "InstallRoot: $InstallRoot"
    Write-Host "WorkDir: $WorkDir"
    Write-Host "KnoxRoot: $KnoxRoot"
    Write-Host "ScheduledTaskUser: $CurrentUser"
    Write-Host "No files, folders, shortcuts, Python packages, or scheduled tasks are changed in this mode."
    Write-Host ""

    if (Test-Admin) {
        Write-CheckLine 'OK' 'administrator privileges: current process is elevated'
    } else {
        Write-CheckLine 'WARN' 'administrator privileges: current process is not elevated'
    }

    $pyLine = Get-PythonVersionLine
    $pyVer = Get-PythonVersion
    if ($pyVer -and $pyVer.Major -eq 3 -and $pyVer.Minor -eq 11) {
        Write-CheckLine 'OK' "Python 3.11: $pyLine"
    } elseif ($pyLine) {
        Write-CheckLine 'WARN' "Python 3.11: different python found ($pyLine)"
    } else {
        Write-CheckLine 'MISSING' 'Python 3.11: python command not found'
    }

    $nodeVer = Get-NodeVersion
    if ($nodeVer -and $nodeVer.Major -ge 18) {
        Write-CheckLine 'OK' "Node.js: $nodeVer"
    } else {
        Write-CheckLine 'MISSING' 'Node.js 18 or newer: node command not found or too old'
    }
    if (Get-Command npm.cmd -ErrorAction SilentlyContinue) {
        Write-CheckLine 'OK' "npm: $(& npm.cmd --version)"
    } else {
        Write-CheckLine 'MISSING' 'npm.cmd not found'
    }
    if (Test-Path -LiteralPath $ElectronExe -PathType Leaf) {
        Write-CheckLine 'OK' "Electron executable: $ElectronExe"
    } else {
        Write-CheckLine 'MISSING' "Electron executable: $ElectronExe"
    }

    if (Test-Prerequisites -Quiet) {
        Write-CheckLine 'OK' 'required source files: all present'
    } else {
        Write-CheckLine 'MISSING' 'required source files: see missing list above'
    }

    foreach ($path in @($ViewerDir, $ElectronDir, $ThumbsDir, $WorkDir)) {
        $status = Test-PathWritableStatus $path
        if ($status -like 'exists*') {
            Write-CheckLine 'OK' "target path: $path ($status)"
        } else {
            Write-CheckLine 'WARN' "target path: $path ($status)"
        }
    }

    $knoxExe = Join-Path $KnoxRoot 'KnoxTeams.exe'
    if (Test-Path -LiteralPath $knoxExe -PathType Leaf) {
        Write-CheckLine 'OK' "KnoxTeams: $knoxExe"
    } else {
        Write-CheckLine 'WARN' "KnoxTeams: not found at $knoxExe; use -KnoxRoot or KNOX_ROOT if installed elsewhere"
    }

    if ((Invoke-SchtasksQuiet "/Query /TN `"$TaskName`"") -eq 0) {
        Write-CheckLine 'OK' "scheduled task exists: $TaskName"
    } else {
        Write-CheckLine 'MISSING' "scheduled task missing: $TaskName"
    }

    if (Test-Path -LiteralPath $DesktopShortcut -PathType Leaf) {
        Write-CheckLine 'OK' "desktop shortcut exists: $DesktopShortcut"
    } else {
        Write-CheckLine 'MISSING' "desktop shortcut missing: $DesktopShortcut"
    }

    $keyPath = Join-Path $WorkDir 'dbkey.secret'
    if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
        Write-CheckLine 'OK' "dbkey.secret exists in WORK (value hidden): $keyPath"
    } else {
        Write-CheckLine 'MISSING' "dbkey.secret missing in WORK. Run publish\capture-key.bat after KnoxTeams login."
    }

    exit 0
}

if ($CheckOnly) {
    Invoke-CheckOnly
}

if ($ShortcutOnly) {
    New-DesktopShortcut
    Write-Host "ShortcutOnly complete."
    exit
}

Ensure-Admin
Initialize-SystemProxy
Resolve-DependencyExecutables

Write-Host "teams-record setup"
Write-Host "RepoRoot: $RepoRoot"

if (-not (Test-Prerequisites)) {
    throw 'Required source file check failed.'
}

if ($SkipDependencies) {
    $pythonVersion = Get-PythonVersion
    $nodeVersion = Get-NodeVersion
    if (-not $pythonVersion -or $pythonVersion.Major -ne 3 -or $pythonVersion.Minor -ne 11) { throw 'SkipDependencies requires Python 3.11.' }
    if (-not $nodeVersion -or $nodeVersion.Major -lt 18 -or -not $script:NpmExe) { throw 'SkipDependencies requires Node.js 18+ and npm.' }
    Add-Summary "dependency installation skipped; existing Python $pythonVersion and Node.js $nodeVersion verified"
} else {
    Install-Python311
    Install-NodeLts
}
Install-Files
Install-ElectronDependencies
Test-KnoxRoot
Notice-Key
Restore-Data
Register-ViewerTask
New-DesktopShortcut

Write-Host ""
Write-Host "Summary"
$Summary | ForEach-Object { Write-Host " - $_" }

if ($Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Pending"
    $Warnings | ForEach-Object { Write-Host " - $_" }
    Write-Host " - KnoxTeams must be installed and signed in before refresh can collect data."
}
