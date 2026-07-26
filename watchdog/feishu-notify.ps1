# feishu-notify.ps1 — host-rig-bridge watchdog 飞书薄封装
# 复用 ~/.claude/scripts/feishu.ps1 wrapper, 不重写
# 失败: stderr 打印 + 不抛 (守护不因告警失败停)

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Rig,
    [Parameter(Mandatory)]
    [ValidateSet("INFO", "WARN", "CRIT")]
    [string]$Level,
    [Parameter(Mandatory)]
    [string]$Msg,
    [string]$Probe = ""
)

$ErrorActionPreference = "Continue"
$emoji = switch ($Level) {
    "INFO" { "🟢" }
    "WARN" { "🟡" }
    "CRIT" { "🔴" }
}

$text = "[host-rig-bridge] $emoji $Level $Rig`: $Msg"
if ($Probe) { $text += "`n  probe: $Probe" }

$feishu = Join-Path $HOME ".claude\scripts\feishu.ps1"
if (-not (Test-Path $feishu)) {
    Write-Error "feishu.ps1 not found at $feishu"
    exit 0
}

try {
    & $feishu im send -to "18167703692" -text $text 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "feishu im send exit=$LASTEXITCODE"
    }
} catch {
    Write-Error "feishu im send threw: $_"
}
exit 0