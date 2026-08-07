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

# Keep the token readable only by the profile account and SYSTEM.  The
# installer may be invoked through a background management service whose
# $env:USERNAME is SYSTEM, so derive the intended account from the explicit
# profile path instead of the caller environment.
$profileUser = Split-Path -Leaf $UserProfilePath.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($profileUser)) {
    throw "could not derive Windows account from UserProfilePath: $UserProfilePath"
}
$profileAccount = "$env:COMPUTERNAME\$profileUser"
$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([System.Security.Principal.NTAccount]$profileAccount)
$inheritance = [System.Security.AccessControl.InheritanceFlags]::None
$propagation = [System.Security.AccessControl.PropagationFlags]::None
$allow = [System.Security.AccessControl.AccessControlType]::Allow
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($profileAccount, 'Read', $inheritance, $propagation, $allow)))
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
$principal = New-ScheduledTaskPrincipal -UserId $profileAccount -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Refresh and securely upload the current user Teams archive' -Force | Out-Null
Write-Output "scheduled task installed: $TaskName"
