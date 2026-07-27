<#
  Removes only teams-record components deployed by publish\install.bat.
  Data is preserved unless -DeleteData is explicitly supplied.
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$DeleteData
)

$ErrorActionPreference = 'Stop'
$TaskName = 'TeamsRecordViewer'

function Get-DefaultInstallRoot {
    $scriptDrive = Split-Path -Qualifier $PSScriptRoot
    if ($scriptDrive -and $env:SystemDrive -and $scriptDrive -ieq $env:SystemDrive) {
        return (Join-Path $env:LOCALAPPDATA 'teams-record')
    }
    if ($scriptDrive) { return (Join-Path ($scriptDrive + '\') 'teams-record') }
    return (Join-Path $env:LOCALAPPDATA 'teams-record')
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Admin {
    if (Test-Admin) { return }
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($InstallRoot) { $args += @('-InstallRoot', "`"$InstallRoot`"") }
    if ($DeleteData) { $args += '-DeleteData' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs
    exit
}

function Remove-FileIfPresent([string]$Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "[REMOVED] $Path"
    }
}

function Remove-EmptyDirectory([string]$Path) {
    if ((Test-Path -LiteralPath $Path -PathType Container) -and
        -not (Get-ChildItem -LiteralPath $Path -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "[REMOVED] empty directory $Path"
    }
}

if (-not $InstallRoot) { $InstallRoot = Get-DefaultInstallRoot }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$installParent = Split-Path -Parent $InstallRoot
if (-not $installParent -or $InstallRoot -eq [IO.Path]::GetPathRoot($InstallRoot)) {
    throw "Refusing unsafe InstallRoot: $InstallRoot"
}

Ensure-Admin

$ViewerDir = Join-Path $InstallRoot 'viewer'
$ElectronDir = Join-Path $InstallRoot 'electron'
$ElectronExe = Join-Path $ElectronDir 'node_modules\electron\dist\electron.exe'
$WorkDir = Join-Path $env:USERPROFILE 'teams-record-work'
$ShortcutPath = Join-Path $env:USERPROFILE 'Desktop\Teams Viewer.lnk'

# Stop only processes whose command or executable points at this installation.
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.ExecutablePath -and $_.ExecutablePath -ieq $ElectronExe) -or
    ($_.CommandLine -and $_.CommandLine.IndexOf((Join-Path $ViewerDir 'server.py'), [StringComparison]::OrdinalIgnoreCase) -ge 0)
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "[STOPPED] process $($_.ProcessId)"
}

& $env:ComSpec /d /c "schtasks.exe /Query /TN `"$TaskName`" >nul 2>nul"
if ($LASTEXITCODE -eq 0) {
    & $env:ComSpec /d /c "schtasks.exe /Delete /TN `"$TaskName`" /F >nul 2>nul"
    if ($LASTEXITCODE -ne 0) { throw "Failed to delete scheduled task: $TaskName" }
    Write-Host "[REMOVED] scheduled task $TaskName"
}

# Do not delete a same-named shortcut if the user replaced it with another target.
if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($ShortcutPath)
    $knownTargets = @($ElectronExe, (Join-Path $ElectronDir 'teams-viewer-electron.bat'), (Join-Path $ViewerDir 'teams-viewer.bat'))
    if ($knownTargets -icontains $shortcut.TargetPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        Write-Host "[REMOVED] $ShortcutPath"
    } else {
        Write-Warning "Shortcut was preserved because its target is not an installed Teams Viewer target: $($shortcut.TargetPath)"
    }
}

foreach ($name in @('server.py', 'merge_archive.py', 'refresh_archive.bat', 'start_viewer.bat', 'teams-viewer.bat')) {
    Remove-FileIfPresent (Join-Path $ViewerDir $name)
}

$nodeModules = Join-Path $ElectronDir 'node_modules'
if (Test-Path -LiteralPath $nodeModules -PathType Container) {
    Remove-Item -LiteralPath $nodeModules -Recurse -Force
    Write-Host "[REMOVED] installer-created Electron node_modules"
}
foreach ($name in @('main.js', 'package.json', 'package-lock.json', 'teams-viewer-electron.bat')) {
    Remove-FileIfPresent (Join-Path $ElectronDir $name)
}
Remove-FileIfPresent (Join-Path $ElectronDir 'assets\icon.ico')
Remove-EmptyDirectory (Join-Path $ElectronDir 'assets')

foreach ($name in @('decrypt_export.js', 'sqlite3.js', 'sqlite3-binding.js', 'trace.js', 'spawn_key.py', 'hook_napi.py')) {
    Remove-FileIfPresent (Join-Path $WorkDir $name)
}

if ($DeleteData) {
    Write-Warning 'DeleteData was explicitly selected: local databases, archive, thumbnails, key, logs, snapshots, and work backups will be deleted.'
    foreach ($name in @('teams-archive.db', 'teams-archive.db-wal', 'teams-archive.db-shm', 'teams-decrypted.db', 'teams-decrypted.db-wal', 'teams-decrypted.db-shm')) {
        Remove-FileIfPresent (Join-Path $InstallRoot $name)
    }
    $thumbs = Join-Path $InstallRoot 'thumbs'
    if (Test-Path -LiteralPath $thumbs -PathType Container) { Remove-Item -LiteralPath $thumbs -Recurse -Force }
    if (Test-Path -LiteralPath $WorkDir -PathType Container) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
} else {
    Write-Host '[PRESERVED] teams-archive.db, teams-decrypted.db, thumbs, dbkey.secret, snapshots, logs, and work/backup data'
    Write-Host 'Use -DeleteData only when permanent local data deletion is intended.'
}

Remove-EmptyDirectory $ViewerDir
Remove-EmptyDirectory $ElectronDir
Remove-EmptyDirectory $InstallRoot
Write-Host 'Uninstall complete.'
