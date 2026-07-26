# setup-host.ps1 — 主机一次性 setup (链路 B 第一阶段)
# 用法 (PowerShell 7.1+):
#   pwsh scripts/setup-host.ps1
#
# 目的:
#   1. 生成主机 SSH key (id_claude_mcp, ed25519, 无 passphrase)
#   2. 输出主机公钥 (永久; 以后所有外机共享)
#
# 行为 (幂等):
#   - key 已存在 → 跳过生成, 复用
#   - 写 ~\.ssh\config (没有则建空文件)
#
# 不写 ~/.claude.json mcpServers (那是加外机时 register-rig 的事)
# 不写 ~/.ssh/config Host 段 (同上)
#
# 跑完输出主机公钥 + forced command 模板, 主人复制带去外机用.

[CmdletBinding()]
param(
    [string]$KeyPath = "$HOME\.ssh\id_claude_mcp"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          host-rig-bridge 主机 setup                          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "目的: 生成主机 SSH key (链路 B 第一阶段)" -ForegroundColor Cyan
Write-Host ""

# 1. SSH dir
Write-Host "[1/3] 装 ~/.ssh" -ForegroundColor Cyan
if (-not (Test-Path "$HOME\.ssh")) {
    New-Item -ItemType Directory -Path "$HOME\.ssh" | Out-Null
    Write-Host "    已建"
} else {
    Write-Host "    已存在"
}

# 2. SSH key
Write-Host "[2/3] 检查 / 生成 id_claude_mcp (ed25519, 无 passphrase)" -ForegroundColor Cyan
if (Test-Path $KeyPath) {
    Write-Host "    key 已存在: $KeyPath"
} else {
    ssh-keygen -t ed25519 -f $KeyPath -N "" -C "claude-mcp@$env:COMPUTERNAME"
    Write-Host "    key 已生成: $KeyPath"
}

$pubKey = Get-Content "$KeyPath.pub" -Raw

# 3. 输出公钥 + forced command 模板
Write-Host ""
Write-Host "[3/3] 输出主机公钥 (永久, 以后所有外机共享)" -ForegroundColor Cyan
Write-Host ""
Write-Host "==== 主机公钥 BEGIN ====" -ForegroundColor Yellow
Write-Host $pubKey.Trim() -ForegroundColor Yellow
Write-Host "==== 主机公钥 END ====" -ForegroundColor Yellow
Write-Host ""

# forced command 模板 — 主人按外机真实路径填
$forcedCmd = 'command="C:/Users/mcp-rig/mcp-server/.venv/Scripts/python.exe -u C:/Users/mcp-rig/mcp-server/src/server/server.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty'

Write-Host "==== forced command 模板 BEGIN ====" -ForegroundColor Yellow
Write-Host $forcedCmd -ForegroundColor Yellow
Write-Host "==== forced command 模板 END ====" -ForegroundColor Yellow
Write-Host ""

Write-Host "下一步 (主人手动):" -ForegroundColor Cyan
Write-Host "  1. 复制'主机公钥' + 上面'forced command 模板'拼成整行:" -ForegroundColor Cyan
Write-Host "       $forcedCmd <主机公钥>" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2. 去每台外机 (管理员 PowerShell) 跑 install-rig-bundle, 带 `$RIG_HOST_PUBKEY=<上面整行>" -ForegroundColor Cyan
Write-Host ""
Write-Host "  3. 外机装完后, 回主机跑 register-rig 加外机:" -ForegroundColor Cyan
Write-Host "       pwsh scripts/register-rig.ps1 -RigAlias <alias> -RigHost <VPS> -RigPort <port> -RigUser mcp-rig" -ForegroundColor Cyan
Write-Host ""