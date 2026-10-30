[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$taskName = 'CampusNet AutoConnect'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    if ($task.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host '已关闭登录 Windows 后自动运行。'
}
else {
    Write-Host '没有找到开机自动运行任务。'
}

Write-Host '本机配置和加密密码仍保留在 %LOCALAPPDATA%\CampusNet-AutoConnect。'
Write-Host '确认不再需要后，可手动删除这个文件夹。'
