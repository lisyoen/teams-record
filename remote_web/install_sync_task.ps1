[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9_.-]{1,64}$')][string]$Username,
    [string]$InstallRoot = 'D:\git\teams-record',
    [string]$ServerUrl = 'https://teams-record.craftbay.io',
    [string]$UserProfilePath = $env:USERPROFILE,
    [string]$SecretPath = '',
    [string]$TaskName = 'TeamsRecordRemoteSync',
    [int]$Minutes = 10
)

$ErrorActionPreference = 'Stop'
if ($Minutes -lt 5) { throw 'Minutes must be at least 5' }
if ([string]::IsNullOrWhiteSpace($SecretPath)) {
    $SecretPath = Join-Path $UserProfilePath 'AppData\Local\teams-record\remote-upload.token'
}
$script = Join-Path $InstallRoot 'remote_web\sync_windows.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "sync script not found: $script"
}
if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    throw "upload token file not found: $SecretPath"
}

# Keep the token readable only by the current Windows account and SYSTEM.
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([System.Security.Principal.NTAccount]$env:USERNAME)
$inheritance = [System.Security.AccessControl.InheritanceFlags]::None
$propagation = [System.Security.AccessControl.PropagationFlags]::None
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, 'Read', $inheritance, $propagation, $allow)))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM', 'FullControl', $inheritance, $propagation, $allow)))
Set-Acl -LiteralPath $SecretPath -AclObject $acl

$quotedScript = '"' + $script + '"'
$quotedRoot = '"' + $InstallRoot + '"'
$quotedUrl = '"' + $ServerUrl + '"'
$quotedSecret = '"' + $SecretPath + '"'
$quotedProfile = '"' + $UserProfilePath + '"'
$taskArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedScript -Username $Username -InstallRoot $quotedRoot -ServerUrl $quotedUrl -UserProfilePath $quotedProfile -SecretPath $quotedSecret"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArgs
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $Minutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Refresh and securely upload the current user Teams archive' -Force | Out-Null
Write-Output "scheduled task installed: $TaskName"
