# setup-host.ps1 — 主机一次性 setup (兼容老路径, 推荐用 register-rig.ps1)
# 现在等价于: register-rig.ps1 -RigAlias rig -RigHost <ip> -RigUser mcp-rig
# 推荐做法: 编辑 ~/.claude/host-rig-bridge/rigs.local.yaml, 然后跑 register-rig.ps1
#
# 用法 (兼容老脚本):
#   "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoProfile -File setup-host.ps1
#   # 或修改本文件第 13-14 行的 RigHost / RigUser 后跑

[CmdletBinding()]
param(
    [string]$RigHost = "192.168.x.x",    # ← 改成外机 IP, 或用 register-rig.ps1 读 yaml
    [string]$RigUser = "mcp-rig"
)

$ErrorActionPreference = "Stop"

# 转调 register-rig.ps1 (新路径), 行为 100% 等价
$register = Join-Path $PSScriptRoot "register-rig.ps1"
if (-not (Test-Path $register)) {
    throw "register-rig.ps1 not found next to setup-host.ps1"
}

Write-Host "[setup-host] deprecated: 推荐用 register-rig.ps1 + rigs.local.yaml" -ForegroundColor Yellow
Write-Host "[setup-host] 转调 register-rig.ps1 -RigAlias rig -RigHost $RigHost -RigUser $RigUser" -ForegroundColor Yellow
Write-Host ""

& $register -RigAlias rig -RigHost $RigHost -RigUser $RigUser