# install-watchdog.ps1 — 一键注册 Windows 计划任务 host-rig-watchdog
# SYSTEM + Highest + AtStartup + RepetitionInterval 5min + RepetitionDuration 3650d
# RestartCount 3 + RestartInterval 1min
# 幂等: 已注册跳过

[CmdletBinding()]
param(
    [string]$ScriptPath = "",
    [string]$TaskName = "host-rig-watchdog"
)

$ErrorActionPreference = "Stop"

if (-not $ScriptPath) {
    $ScriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "host-rig-watchdog.ps1"
}

if (-not (Test-Path $ScriptPath)) {
    throw "watchdog script not found: $ScriptPath"
}

$pwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
if (-not (Test-Path $pwsh)) {
    throw "pwsh 7 not found at $pwsh"
}

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Warning "task '$TaskName' already registered, removing old first"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute $pwsh `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Repetition = (New-ScheduledTaskTriggerSet -RepetitionInterval (New-TimeSpan -Minutes 5) `
    -RepetitionDuration (New-TimeSpan -Days 3650)) | ForEach-Object Repetition

# AtStartup trigger needs to be combined with repetition via Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "host-rig-bridge watchdog: SSH/MCP/disk/claude.json 探针, 5min 一次" | Out-Null

# AtStartup + RepetitionInterval 同时设: 需 PostTrigger 二次注入
$task = Get-ScheduledTask -TaskName $TaskName
$task.Triggers[0].Repetition.Interval = "PT5M"
$task.Triggers[0].Repetition.Duration = "P3650D"
$task | Set-ScheduledTask | Out-Null

Write-Output "registered: $TaskName"
Write-Output "  script:  $ScriptPath"
Write-Output "  trigger: AtStartup + Repetition 5min/3650d"
Write-Output ""
Write-Output "verify: Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
Write-Output "uninstall: Unregister-ScheduledTask -TaskName $TaskName -Confirm:`$false"
Write-Output "run-now: Start-ScheduledTask -TaskName $TaskName"