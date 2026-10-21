[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'teams-record-lite'),
    [switch]$RemoveData,
    [switch]$KeepData,
    [switch]$NoPopup
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.Windows.Forms
$InstallDir = [System.IO.Path]::GetFullPath($InstallDir)

if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'teams-record-lite.bat'))) {
    Write-Host "설치된 Teams Record Lite 를 찾지 못했습니다: $InstallDir"
    exit 2
}

$removeAll = $RemoveData.IsPresent
if (-not $RemoveData -and -not $KeepData -and -not $NoPopup) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Teams Record Lite 를 제거합니다.`r`n`r`n보관된 대화 아카이브(data)와 DB 키도 함께 삭제할까요?`r`n`r`n예: 모두 삭제`r`n아니오: 대화 아카이브와 DB 키는 남기고 프로그램만 삭제`r`n취소: 제거하지 않음",
        'Teams Record Lite 제거',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question).ToString()
    if ($answer -eq 'Cancel') { Write-Host '제거를 취소했습니다.'; exit 10 }
    $removeAll = ($answer -eq 'Yes')
}

$keep = if ($removeAll) { @() } else { @('data', 'work', 'config.json') }
Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $keep -notcontains $_.Name -and $_.Name -ne 'uninstall.bat' } | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
if (-not $removeAll) {
    Get-ChildItem -LiteralPath (Join-Path $InstallDir 'work') -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'dbkey.secret' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# uninstall.bat is still running; remove it (and the folder when everything goes) after it exits.
$target = if ($removeAll) { "rmdir /s /q `"$InstallDir`"" } else { "del /q `"$(Join-Path $InstallDir 'uninstall.bat')`"" }
Start-Process -FilePath $env:ComSpec -ArgumentList "/d /c ping -n 3 127.0.0.1 >nul & $target" -WindowStyle Hidden

$msg = if ($removeAll) { 'Teams Record Lite 를 모두 제거했습니다.' } else { "프로그램을 제거했습니다. 대화 아카이브와 DB 키는 남겨 두었습니다.`r`n$InstallDir" }
Write-Host $msg
if (-not $NoPopup) {
    [void][System.Windows.Forms.MessageBox]::Show($msg, 'Teams Record Lite 제거 완료',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
}
exit 0
