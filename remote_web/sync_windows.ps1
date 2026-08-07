[CmdletBinding()]
param(
    [string]$InstallRoot = 'D:\git\teams-record',
    [string]$ServerUrl = 'https://teams-record.craftbay.io',
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]{1,64}$')][string]$Username,
    [string]$SecretPath = "$env:LOCALAPPDATA\teams-record\remote-upload.token",
    [string]$ProxyUrl = $env:HTTPS_PROXY
)

$ErrorActionPreference = 'Stop'
$refresh = Join-Path $InstallRoot 'viewer\update-db.bat'
$database = Join-Path $InstallRoot 'teams-archive.db'

if (-not (Test-Path -LiteralPath $refresh -PathType Leaf)) {
    throw "refresh script not found: $refresh"
}
if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    throw "upload token file not found: $SecretPath"
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

$token = (Get-Content -LiteralPath $SecretPath -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($token)) {
    throw 'upload token file is empty'
}

$headers = @{
    Authorization = "Bearer $token"
    'X-Teams-Record-User' = $Username
}
$arguments = @{
    Uri = ($ServerUrl.TrimEnd('/') + '/api/upload')
    Method = 'Post'
    InFile = $database
    ContentType = 'application/vnd.sqlite3'
    Headers = $headers
    UseBasicParsing = $true
    TimeoutSec = 60
}
if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
    $arguments.Proxy = $ProxyUrl
    $arguments.ProxyUseDefaultCredentials = $true
}

try {
    $response = Invoke-WebRequest @arguments
    $result = $response.Content | ConvertFrom-Json
    if (-not $result.ok) {
        throw 'server did not acknowledge the upload'
    }
    Write-Output ("teams-record upload complete: user={0} bytes={1} updatedAt={2}" -f `
        $Username, $result.bytes, $result.updatedAt)
}
finally {
    $token = $null
    $headers.Authorization = $null
}

