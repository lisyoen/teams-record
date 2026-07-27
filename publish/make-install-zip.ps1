<#
  teams-record 설치 패키지 빌드 스크립트
  출력: publish\dist\teams-record-<DateStamp>.zip

  목적: 다른 Windows ID 에서 재설치할 수 있는 "설치용 스크립트" 패키지를 만든다.
        시크릿(키/DB/토큰/쿠키/원본 데이터/썸네일/로그)은 절대 포함하지 않는다(화이트리스트 방식).

  zip root: publish\, viewer\, electron\ (source and installer files only; no node_modules)

  usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File publish\make-install-zip.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File publish\make-install-zip.ps1 -DateStamp 20260713
#>
[CmdletBinding()]
param(
    [string]$DateStamp = (Get-Date -Format 'yyyyMMdd')
)

$ErrorActionPreference = 'Stop'

$PublishRoot = $PSScriptRoot
$RepoRoot    = Split-Path -Parent $PublishRoot
$DistDir     = Join-Path $PublishRoot 'dist'
$PackageName = "teams-record-$DateStamp"
$StageRoot   = Join-Path $DistDir '.stage'
$PackageRoot = Join-Path $StageRoot $PackageName
$ZipPath     = Join-Path $DistDir "$PackageName.zip"

$publishFiles = @('README.md', 'install.bat', 'install.ps1', 'setup.bat', 'setup.ps1', 'capture-key.bat', 'uninstall.bat', 'uninstall.ps1')
$workFiles    = @('decrypt_export.js', 'sqlite3.js', 'sqlite3-binding.js', 'trace.js', 'spawn_key.py', 'hook_napi.py')
$viewerFiles  = @('server.py', 'merge_archive.py', 'refresh_archive.bat', 'start_viewer.bat', 'teams-viewer.bat')
$electronFiles = @('main.js', 'package.json', 'package-lock.json', 'teams-viewer-electron.bat')

function Copy-WhiteListedFile([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "Required file is missing: $Source"
    }
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Test-ForbiddenEntry([string]$Name) {
    $normalized = $Name -replace '\\', '/'
    if ($normalized -match '(^|/)(secrets|keys|thumbs)(/|$)') { return $true }
    if ($normalized -match '(^|/)node_modules(/|$)') { return $true }
    if ($normalized -match '(^|/)(data|dumps|attachments|pictures|prd|original-data|company-data)(/|$)') { return $true }
    if ($normalized -match '(^|/)dbkey\.secret$')        { return $true }
    if ($normalized -match '\.secret$')                  { return $true }
    if ($normalized -match '\.db($|-wal$|-shm$)')        { return $true }
    if ($normalized -match '\.(key|sqlcipher-key)$')      { return $true }
    if ($normalized -match '(^|/)\.env(\.|$)')            { return $true }
    if ($normalized -match '(^|/)passphrase[^/]*$')       { return $true }
    if ($normalized -match '\.sqlite')                   { return $true }
    if ($normalized -match '\.b64$')                     { return $true }
    if ($normalized -match '\.log$')                     { return $true }
    if ($normalized -match '\.store$')                   { return $true }
    if ($normalized -match '(token|cookie|session)')     { return $true }
    return $false
}

function Test-SqliteHeader([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $buffer = New-Object byte[] 16
        if ($stream.Read($buffer, 0, 16) -ne 16) { return $false }
        return ([Text.Encoding]::ASCII.GetString($buffer) -eq "SQLite format 3`0")
    } finally { $stream.Dispose() }
}

function Test-SensitiveContent([string]$Path) {
    try { $text = [IO.File]::ReadAllText($Path) } catch { return $false }
    $credentialPattern = '(?i)(authorization\s*[:=]\s*bearer\s+[A-Za-z0-9._-]{16,}|(access[_-]?token|refresh[_-]?token)\s*[:=]\s*[A-Za-z0-9._-]{16,}|cookie\s*:\s*[^;\r\n=]+=[^;\r\n]{16,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----)'
    return ($text -match $credentialPattern)
}

$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw 'git is required to verify tracked files before packaging.' }
$trackedFiles = @(& git -C $RepoRoot ls-files)
if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed.' }
$badTracked = @($trackedFiles | Where-Object { Test-ForbiddenEntry $_ })
if ($badTracked.Count -gt 0) {
    Write-Host 'Forbidden tracked files found:'
    $badTracked | ForEach-Object { Write-Host " - $_" }
    throw 'Git contains forbidden data or dependency files.'
}
$badTrackedContent = @()
foreach ($name in $trackedFiles) {
    $path = Join-Path $RepoRoot $name
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and ((Test-SqliteHeader $path) -or (Test-SensitiveContent $path))) {
        $badTrackedContent += $name
    }
}
if ($badTrackedContent.Count -gt 0) {
    Write-Host 'Forbidden content found in Git tracked files:'
    $badTrackedContent | ForEach-Object { Write-Host " - $_" }
    throw 'Git contains SQLite data or credential material.'
}


if (Test-Path -LiteralPath $PackageRoot) {
    Remove-Item -LiteralPath $PackageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $PackageRoot -Force | Out-Null
New-Item -ItemType Directory -Path $DistDir -Force | Out-Null

foreach ($name in $publishFiles) {
    Copy-WhiteListedFile (Join-Path $PublishRoot $name) (Join-Path (Join-Path $PackageRoot 'publish') $name)
}
foreach ($name in $workFiles) {
    Copy-WhiteListedFile (Join-Path (Join-Path $PublishRoot 'work') $name) (Join-Path (Join-Path (Join-Path $PackageRoot 'publish') 'work') $name)
}
foreach ($name in $viewerFiles) {
    Copy-WhiteListedFile (Join-Path (Join-Path $RepoRoot 'viewer') $name) (Join-Path (Join-Path $PackageRoot 'viewer') $name)
}
foreach ($name in $electronFiles) {
    Copy-WhiteListedFile (Join-Path (Join-Path $RepoRoot 'electron') $name) (Join-Path (Join-Path $PackageRoot 'electron') $name)
}
Copy-WhiteListedFile (Join-Path $RepoRoot 'electron\assets\icon.ico') (Join-Path $PackageRoot 'electron\assets\icon.ico')


$stagedFiles = Get-ChildItem -LiteralPath $PackageRoot -File -Recurse
$forbidden = @()
foreach ($file in $stagedFiles) {
    $relative = $file.FullName.Substring($PackageRoot.Length + 1)
    if ((Test-ForbiddenEntry $relative) -or (Test-SqliteHeader $file.FullName) -or (Test-SensitiveContent $file.FullName)) { $forbidden += $relative }
}
if ($forbidden.Count -gt 0) {
    Write-Host "Forbidden files found in staging:"
    $forbidden | ForEach-Object { Write-Host " - $_" }
    throw 'Install zip staging contains forbidden files.'
}

if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ZipPath -Force

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entries = @($zip.Entries | Sort-Object FullName)
    $badEntries = @($entries | Where-Object { Test-ForbiddenEntry $_.FullName })
    $rootFolderEntries = @($entries | Where-Object {
        ($_.FullName -replace '\\', '/') -like "$PackageName/*"
    })
    if ($badEntries.Count -gt 0) {
        Write-Host "Forbidden entries found in zip:"
        $badEntries | ForEach-Object { Write-Host " - $($_.FullName)" }
        throw 'Install zip contains forbidden entries.'
    }
    if ($rootFolderEntries.Count -gt 0) {
        Write-Host "Unexpected package root folder entries found in zip:"
        $rootFolderEntries | ForEach-Object { Write-Host " - $($_.FullName)" }
        throw 'Install zip should contain publish/, viewer/, and electron/ at the archive root.'
    }

    Write-Host "Archive: $ZipPath"
    Write-Host "Entry count: $($entries.Count)"
    Write-Host "Entries:"
    $entries | ForEach-Object { Write-Host " - $($_.FullName)" }
} finally {
    $zip.Dispose()
}
