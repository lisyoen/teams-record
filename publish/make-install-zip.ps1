<#
  teams-record 설치 패키지 빌드 스크립트
  출력: publish\dist\teams-record-<DateStamp>.zip

  목적: 다른 Windows ID 에서 재설치할 수 있는 "설치용 스크립트" 패키지를 만든다.
        시크릿(키/DB/토큰/쿠키/원본 데이터/썸네일/로그)은 절대 포함하지 않는다(화이트리스트 방식).

  zip 루트 구조:
    publish\  install.bat install.ps1 setup.bat setup.ps1 capture-key.bat README.md
    publish\work\  decrypt_export.js decrypt_db.js decrypt-db.bat sqlite3.js sqlite3-binding.js trace.js spawn_key.py hook_napi.py
    viewer\  server.py merge_archive.py refresh_archive.bat start_viewer.bat teams-viewer.bat gen_favicon.py

  사용법:
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

$publishFiles = @('README.md', 'install.bat', 'install.ps1', 'setup.bat', 'setup.ps1', 'capture-key.bat')
$workFiles    = @('decrypt_export.js', 'decrypt_db.js', 'decrypt-db.bat', 'sqlite3.js', 'sqlite3-binding.js', 'trace.js', 'spawn_key.py', 'hook_napi.py')
$viewerFiles  = @('server.py', 'merge_archive.py', 'refresh_archive.bat', 'start_viewer.bat', 'teams-viewer.bat', 'gen_favicon.py')

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
    if ($normalized -match '(^|/)(secrets|thumbs)(/|$)') { return $true }
    if ($normalized -match '(^|/)dbkey\.secret$')        { return $true }
    if ($normalized -match '\.secret$')                  { return $true }
    if ($normalized -match '\.db($|-wal$|-shm$)')        { return $true }
    if ($normalized -match '\.sqlite')                   { return $true }
    if ($normalized -match '\.b64$')                     { return $true }
    if ($normalized -match '\.log$')                     { return $true }
    if ($normalized -match '\.store$')                   { return $true }
    if ($normalized -match '(token|cookie|session)')     { return $true }
    return $false
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

$stagedFiles = Get-ChildItem -LiteralPath $PackageRoot -File -Recurse
$forbidden = @()
foreach ($file in $stagedFiles) {
    $relative = $file.FullName.Substring($PackageRoot.Length + 1)
    if (Test-ForbiddenEntry $relative) { $forbidden += $relative }
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
        throw 'Install zip should contain publish/ and viewer/ at the archive root.'
    }

    Write-Host "Archive: $ZipPath"
    Write-Host "Entry count: $($entries.Count)"
    Write-Host "Entries:"
    $entries | ForEach-Object { Write-Host " - $($_.FullName)" }
} finally {
    $zip.Dispose()
}
