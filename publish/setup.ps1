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

function Invoke-SchtasksQuiet([string]$ArgumentLine) {
    & $env:ComSpec /d /c "schtasks.exe $ArgumentLine >nul 2>nul"
    return $LASTEXITCODE
}

function Add-Summary([string]$Message) {
    $Summary.Add($Message) | Out-Null
    Write-Host "[OK] $Message"
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
    foreach ($name in @('server.py', 'merge_archive.py', 'refresh_archive.bat', 'start_viewer.bat', 'teams-viewer.bat')) {
        $items += [pscustomobject]@{
            Group = 'viewer'
            Name = $name
            Source = Join-Path $viewerSource $name
            Destination = Join-Path $ViewerDir $name
        }
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
    $env:Path = "$machine;$user"
}

function Get-PythonVersionLine {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        return (& python --version 2>&1 | Select-Object -First 1).ToString()
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
    Write-Host "Downloading Python 3.11 installer..."
    $installer = Join-Path $env:TEMP 'python-3.11-amd64.exe'
    $url = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe'
    Invoke-WebRequest -Uri $url -OutFile $installer

    $process = Start-Process -FilePath $installer -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0' -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "Python 3.11 installer failed with exit code $($process.ExitCode)."
    }
}

function Install-Python311 {
    $version = Get-PythonVersion
    if ($version -and $version.Major -eq 3 -and $version.Minor -eq 11) {
        Add-Summary "Python $version already available"
        return
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Installing Python 3.11 using winget source..."
        & winget install -e --id Python.Python.3.11 --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Add-WarningLine "winget Python install failed with exit code $LASTEXITCODE. Falling back to the python.org installer."
            Install-Python311FromInstaller
        }
    } else {
        Write-Host "winget is not available."
        Install-Python311FromInstaller
    }

    Refresh-EnvironmentPath
    $version = Get-PythonVersion
    if (-not $version -or $version.Major -ne 3 -or $version.Minor -ne 11) {
        throw 'Python 3.11 install completed, but python --version is still not Python 3.11.'
    }
    Add-Summary "Python $version installed"
}

function Get-NodeVersion {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $line = (& node --version 2>&1 | Select-Object -First 1).ToString()
        if ($line -match 'v(\d+)\.(\d+)\.(\d+)') {
            return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
    } catch {}
    return $null
}

function Install-NodeFromOfficialMsi {
    Write-Host "Downloading Node.js 22 LTS installer..."
    $baseUrl = 'https://nodejs.org/dist/latest-v22.x'
    $sums = (Invoke-WebRequest -Uri "$baseUrl/SHASUMS256.txt").Content
    $match = [regex]::Match($sums, '(?m)^([0-9a-f]{64})\s+(node-v([0-9.]+)-x64\.msi)$')
    if (-not $match.Success) { throw 'Could not resolve the latest Node.js 22 x64 MSI.' }
    $fileName = $match.Groups[2].Value
    $expectedHash = $match.Groups[1].Value
    $installer = Join-Path $env:TEMP $fileName
    Invoke-WebRequest -Uri "$baseUrl/$fileName" -OutFile $installer
    $actualHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw "Node.js installer checksum mismatch: $installer" }
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$installer`"", '/qn', '/norestart') -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Node.js installer failed with exit code $($process.ExitCode)." }
}

function Install-NodeLts {
    $version = Get-NodeVersion
    if ($version -and $version.Major -ge 18 -and (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
        Add-Summary "Node.js $version and npm already available"
        return
    }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Installing Node.js LTS using winget..."
        & winget install -e --id OpenJS.NodeJS.LTS --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
        if ($LASTEXITCODE -ne 0) {
            Add-WarningLine "winget Node.js install failed with exit code $LASTEXITCODE. Falling back to nodejs.org."
            Install-NodeFromOfficialMsi
        }
    } else {
        Install-NodeFromOfficialMsi
    }
    Refresh-EnvironmentPath
    $version = Get-NodeVersion
    if (-not $version -or $version.Major -lt 18) { throw 'Node.js 18 or newer is required.' }
    if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'npm.cmd was not installed with Node.js.' }
    Add-Summary "Node.js $version and npm installed"
}

function Install-ElectronDependencies {
    if (-not (Test-Path -LiteralPath (Join-Path $ElectronDir 'package-lock.json'))) {
        throw "Electron package-lock.json is missing: $ElectronDir"
    }
    Write-Host "Installing/verifying Electron dependencies with npm ci..."
    Push-Location $ElectronDir
    try {
        & npm.cmd ci --include=dev --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }
    if (-not (Test-Path -LiteralPath $ElectronExe -PathType Leaf)) {
        throw "Electron executable was not installed: $ElectronExe"
    }
    Add-Summary "Electron npm dependencies installed and verified"
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
    if (Test-Path -LiteralPath $archive) {
        Copy-Item -LiteralPath $archive -Destination (Join-Path $InstallRoot 'teams-archive.db') -Force
        Add-Summary "teams-archive.db restored"
    } else {
        Add-WarningLine "DataBackup does not contain teams-archive.db"
    }

    $backupThumbs = Join-Path $DataBackup 'thumbs'
    if (Test-Path -LiteralPath $backupThumbs) {
        Ensure-Directory $ThumbsDir
        Copy-Item -Path (Join-Path $backupThumbs '*') -Destination $ThumbsDir -Recurse -Force -ErrorAction SilentlyContinue
        Add-Summary "thumbs restored"
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

Write-Host "teams-record setup"
Write-Host "RepoRoot: $RepoRoot"

if (-not (Test-Prerequisites)) {
    throw 'Required source file check failed.'
}

if ($SkipDependencies) {
    $pythonVersion = Get-PythonVersion
    $nodeVersion = Get-NodeVersion
    if (-not $pythonVersion -or $pythonVersion.Major -ne 3 -or $pythonVersion.Minor -ne 11) { throw 'SkipDependencies requires Python 3.11.' }
    if (-not $nodeVersion -or $nodeVersion.Major -lt 18 -or -not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) { throw 'SkipDependencies requires Node.js 18+ and npm.' }
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
