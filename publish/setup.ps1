[CmdletBinding()]
param(
    [string]$KeyBackup,
    [string]$DataBackup,
    [switch]$ShortcutOnly
)

$ErrorActionPreference = 'Stop'

$TaskName = 'TeamsRecordViewer'
$InstallRoot = 'D:\git\teams-db'
$ViewerDir = Join-Path $InstallRoot 'viewer'
$ThumbsDir = Join-Path $InstallRoot 'thumbs'
$WorkDir = 'C:\Users\lisyoen\teams-record-work'
$DesktopShortcut = Join-Path $env:USERPROFILE 'Desktop\Teams 뷰어.lnk'
$ViewerBat = Join-Path $ViewerDir 'teams-viewer.bat'
$StartBat = Join-Path $ViewerDir 'start_viewer.bat'
$RepoRoot = Split-Path -Parent $PSScriptRoot

$Summary = New-Object System.Collections.Generic.List[string]
$Warnings = New-Object System.Collections.Generic.List[string]

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
    if ($KeyBackup) { $args += @('-KeyBackup', "`"$KeyBackup`"") }
    if ($DataBackup) { $args += @('-DataBackup', "`"$DataBackup`"") }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs
    exit
}

function Ensure-Directory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Copy-RequiredFile([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required source file is missing: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Refresh-EnvironmentPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Get-PythonVersion {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $line = (& python --version 2>&1 | Select-Object -First 1).ToString()
        if ($line -match 'Python\s+(\d+)\.(\d+)\.(\d+)') {
            return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
    } catch {
        return $null
    }
    return $null
}

function Install-Python311 {
    $version = Get-PythonVersion
    if ($version -and $version.Major -eq 3 -and $version.Minor -eq 11) {
        Add-Summary "Python $version already available"
        return
    }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        Write-Host "Installing Python 3.11 using winget..."
        & winget install -e --id Python.Python.3.11 --accept-package-agreements --accept-source-agreements
    } else {
        Write-Host "winget is not available. Downloading Python 3.11 installer..."
        $installer = Join-Path $env:TEMP 'python-3.11-amd64.exe'
        $url = 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-amd64.exe'
        Invoke-WebRequest -Uri $url -OutFile $installer
        Start-Process -FilePath $installer -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0' -Wait
    }

    Refresh-EnvironmentPath
    $version = Get-PythonVersion
    if (-not $version -or $version.Major -ne 3 -or $version.Minor -ne 11) {
        throw 'Python 3.11 install completed, but python --version is still not Python 3.11.'
    }
    Add-Summary "Python $version installed"
}

function Install-Files {
    Ensure-Directory $ViewerDir
    Ensure-Directory $ThumbsDir
    Ensure-Directory $WorkDir

    $viewerFiles = @('server.py', 'merge_archive.py', 'refresh_archive.bat', 'start_viewer.bat', 'teams-viewer.bat')
    foreach ($name in $viewerFiles) {
        Copy-RequiredFile (Join-Path (Join-Path $RepoRoot 'viewer') $name) (Join-Path $ViewerDir $name)
    }

    $workFiles = @('decrypt_export.js', 'sqlite3.js', 'sqlite3-binding.js', 'spawn_key.py', 'hook_napi.py')
    foreach ($name in $workFiles) {
        Copy-RequiredFile (Join-Path (Join-Path $PSScriptRoot 'work') $name) (Join-Path $WorkDir $name)
    }

    if (-not (Test-Path -LiteralPath $ViewerBat)) {
        throw "Viewer batch was not installed: $ViewerBat"
    }
    Add-Summary "viewer and decrypt runtime files deployed"
}

function Restore-Key {
    $dest = Join-Path $WorkDir 'dbkey.secret'
    $packaged = Join-Path (Join-Path $PSScriptRoot 'secrets') 'dbkey.secret'

    if (Test-Path -LiteralPath $packaged) {
        Copy-Item -LiteralPath $packaged -Destination $dest -Force
        Add-Summary "dbkey.secret restored from publish\secrets"
        return
    }

    if ($KeyBackup) {
        if (-not (Test-Path -LiteralPath $KeyBackup)) {
            throw "KeyBackup does not exist: $KeyBackup"
        }
        Copy-Item -LiteralPath $KeyBackup -Destination $dest -Force
        Add-Summary "dbkey.secret restored from KeyBackup"
        return
    }

    if (Test-Path -LiteralPath $dest) {
        Add-Summary "existing dbkey.secret kept in WORK"
        return
    }

    Add-WarningLine "dbkey.secret is missing. After KnoxTeams login, run publish\capture-key.bat to recapture it."
}

function Restore-Data {
    if (-not $DataBackup) {
        Add-WarningLine "DataBackup was not provided. First refresh will rebuild from the live KnoxTeams DB retention window."
        return
    }
    if (-not (Test-Path -LiteralPath $DataBackup)) {
        throw "DataBackup does not exist: $DataBackup"
    }

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

    & schtasks /Query /TN $TaskName *> $null
    if ($LASTEXITCODE -eq 0) {
        & schtasks /Delete /TN $TaskName /F | Out-Null
    }

    $taskRun = "cmd /c `"$StartBat`""
    & schtasks /Create /TN $TaskName /SC ONLOGON /TR $taskRun /RU 'lisyoen' /RL HIGHEST /F | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register scheduled task: $TaskName"
    }
    Add-Summary "scheduled task registered: $TaskName"
}

function New-DesktopShortcut {
    Ensure-Directory (Split-Path -Parent $DesktopShortcut)
    $targetPath = $ViewerBat
    $workingDir = $ViewerDir
    if ($ShortcutOnly -and -not (Test-Path -LiteralPath $targetPath)) {
        $legacyViewerBat = Join-Path $InstallRoot 'teams-viewer.bat'
        if (Test-Path -LiteralPath $legacyViewerBat) {
            $targetPath = $legacyViewerBat
            $workingDir = $InstallRoot
        }
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($DesktopShortcut)
    $shortcut.TargetPath = $targetPath
    $shortcut.WorkingDirectory = $workingDir
    $shortcut.Description = 'teams-record viewer'
    if (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\shell32.dll')) {
        $shortcut.IconLocation = "$env:WINDIR\System32\shell32.dll,220"
    }
    $shortcut.Save()
    Add-Summary "desktop shortcut created: $DesktopShortcut"
}

if ($ShortcutOnly) {
    New-DesktopShortcut
    Write-Host "ShortcutOnly complete."
    exit
}

Ensure-Admin

Write-Host "teams-record setup"
Write-Host "RepoRoot: $RepoRoot"

Install-Python311
Install-Files
Restore-Key
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
