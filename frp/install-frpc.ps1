# install-frpc.ps1 — 主机侧下载 frpc + 注册计划任务
# 跑法 (管理员 PowerShell 7):
#   "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoProfile -File install-frpc.ps1

[CmdletBinding()]
param(
    [string]$FrpVersion = "0.61.1",
    [string]$InstallDir = "C:\frp",
    [string]$ConfigPath = "C:\frp\frpc.toml",
    [string]$TaskName = "frpc-bg"
)

$ErrorActionPreference = "Stop"

# 踩坑: 系统自带 zip 半覆盖 → 用 Expand-Archive 重装 OpenSSH
# 踩坑: SCM 静默拒启 → 用 Register-ScheduledTask, SYSTEM + RestartCount 3

$frpcExe = Join-Path $InstallDir "frpc.exe"
$frpcUrl = "https://github.com/fatedier/frp/releases/download/v$FrpVersion/frp_${FrpVersion}_windows_amd64.zip"

Write-Host "[1/4] 建 $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

if (-not (Test-Path $frpcExe)) {
    Write-Host "[2/4] 下载 frpc v$FrpVersion"
    $zipPath = Join-Path $env:TEMP "frpc.zip"
    Invoke-WebRequest -Uri $frpcUrl -OutFile $zipPath -UseBasicParsing
    Write-Host "    解压到 $InstallDir"
    Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
    Remove-Item $zipPath
    # 解压后目录结构: $InstallDir\frp_${FrpVersion}_windows_amd64\frpc.exe
    $subDir = Get-ChildItem $InstallDir -Directory | Where-Object { $_.Name -like "frp_*" } | Select-Object -First 1
    if ($subDir) {
        Get-ChildItem $subDir.FullName | Move-Item -Destination $InstallDir -Force
        Remove-Item $subDir.FullName -Recurse
    }
} else {
    Write-Host "[2/4] frpc.exe 已存在, 跳过下载"
}

Write-Host "[3/4] 检查配置 $ConfigPath"
if (-not (Test-Path $ConfigPath)) {
    Write-Host "❌ $ConfigPath 不存在. 复制本仓 frpc.toml.example 改:"
    Write-Host "   cp frp/frpc.toml.example $ConfigPath"
    Write-Host "   然后改 serverAddr / auth.token / [[proxies]]"
    exit 1
}

Write-Host "[4/4] 注册计划任务 $TaskName"
$action = New-ScheduledTaskAction -Execute $frpcExe -Argument "-c $ConfigPath"
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# 幂等: 已存在先删
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "host-rig-bridge frpc — 反向 SSH 隧道"

Write-Host ""
Write-Host "✅ frpc 安装完成." -ForegroundColor Green
Write-Host "  计划任务: $TaskName (AtStartup, SYSTEM, RestartCount 3)"
Write-Host "  手动启动: Start-ScheduledTask -TaskName $TaskName"
Write-Host "  看日志  : Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"