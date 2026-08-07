[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\git\teams-record',
    [string]$ServerUrl = 'https://teams-record.craftbay.io',
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]{1,64}$')][string]$Username,
    [string]$UserProfilePath = $env:USERPROFILE,
    [string]$SecretPath = '',
    [string]$ProxyUrl = $env:HTTPS_PROXY
)

$ErrorActionPreference = 'Stop'
$env:USERPROFILE = $UserProfilePath
$env:APPDATA = Join-Path $UserProfilePath 'AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $UserProfilePath 'AppData\Local'
if ([string]::IsNullOrWhiteSpace($SecretPath)) {
    $SecretPath = Join-Path $env:LOCALAPPDATA 'teams-record\remote-upload.token'
}
$refresh = Join-Path $InstallRoot 'viewer\update-db.bat'
$database = Join-Path $InstallRoot 'teams-archive.db'
$uploader = Join-Path $InstallRoot 'remote_web\upload_db.py'

if (-not (Test-Path -LiteralPath $refresh -PathType Leaf)) {
    throw "refresh script not found: $refresh"
}
if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    throw "upload token file not found: $SecretPath"
}
if (-not (Test-Path -LiteralPath $uploader -PathType Leaf)) {
    throw "upload helper not found: $uploader"
}

$process = Start-Process -FilePath $env:ComSpec `
    -ArgumentList @('/d', '/c', ('"' + $refresh + '"')) `
    -WorkingDirectory $InstallRoot -WindowStyle Hidden -Wait -PassThru
if ($process.ExitCode -ne 0) {
    throw "teams-record refresh failed: exit $($process.ExitCode)"
}
if (-not (Test-Path -LiteralPath $database -PathType Leaf)) {
    throw "archive database not found after refresh: $database"
}

$uploadArgs = @(
    $uploader,
    '--server', $ServerUrl,
    '--username', $Username,
    '--database', $database,
    '--token-file', $SecretPath,
    '--timeout', '120'
)
if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
    $uploadArgs += @('--proxy', $ProxyUrl)
}
$uploadOutput = & python @uploadArgs
if ($LASTEXITCODE -ne 0) {
    throw "teams-record upload failed: exit $LASTEXITCODE"
}
$result = ($uploadOutput -join "`n") | ConvertFrom-Json
Write-Output ("teams-record upload complete: user={0} bytes={1} updatedAt={2}" -f `
    $Username, $result.bytes, $result.updatedAt)
