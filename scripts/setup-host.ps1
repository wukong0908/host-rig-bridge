# setup-host.ps1 — 主机一次性 setup (链路 B 第一阶段)
# 用法 (PowerShell 7.1+):
#   pwsh scripts/setup-host.ps1 -Vps 8.163.106.31 -FrpToken "<token>" -RemotePort 6001
#
# 目的:
#   1. 生成主机 SSH key (id_claude_mcp, ed25519, 无 passphrase)
#   2. 输出可直接复制到外机的一键命令块 (env var 已填好)
#
# 行为 (幂等):
#   - key 已存在 → 跳过生成, 复用
#   - 写 ~\.ssh\config (没有则建空文件)
#
# 不写 ~/.claude.json mcpServers (那是加外机时 register-rig 的事)
# 不写 ~/.ssh/config Host 段 (同上)
#
# 跑完输出整段外机一键命令, 主人复制粘贴到外机跑即可.

[CmdletBinding()]
param(
    [string]$KeyPath = "$HOME\.ssh\id_claude_mcp",
    [Parameter(Mandatory)]
    [string]$Vps,
    [Parameter(Mandatory)]
    [string]$FrpToken,
    [Parameter(Mandatory)]
    [int]$RemotePort
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║          host-rig-bridge 主机 setup                          ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "参数:" -ForegroundColor Cyan
Write-Host "  VPS:         $Vps"
$tokenPreview = if ($FrpToken.Length -gt 8) { $FrpToken.Substring(0, 8) + "..." } else { $FrpToken }
Write-Host "  frp token:   $tokenPreview"
Write-Host "  remote port: $RemotePort"
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

# forced command 模板
$forcedCmd = 'command="C:/Users/mcp-rig/mcp-server/.venv/Scripts/python.exe -u C:/Users/mcp-rig/mcp-server/src/server/server.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty'

# 完整外机一键命令块 (env var 已填好, 主人直接复制)
$rigCmd = @"
`$env:RIG_VPS         = '$Vps'
`$env:RIG_FRP_TOKEN   = '$FrpToken'
`$env:RIG_REMOTE_PORT = '$RemotePort'
`$env:RIG_HOST_PUBKEY = '$forcedCmd $($pubKey.Trim())'

iex (iwr -useb 'https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install-rig-bundle.ps1').Content
"@

# 3. 输出
Write-Host ""
Write-Host "[3/3] 主机公钥 + 外机一键命令 (整段复制)" -ForegroundColor Cyan
Write-Host ""
Write-Host "==== 主机公钥 BEGIN ====" -ForegroundColor Yellow
Write-Host $pubKey.Trim() -ForegroundColor Yellow
Write-Host "==== 主机公钥 END ====" -ForegroundColor Yellow
Write-Host ""
Write-Host "==== 外机一键命令 BEGIN (复制以下整段到外机管理员 PowerShell 粘贴跑) ====" -ForegroundColor Yellow
Write-Host ""
Write-Host $rigCmd -ForegroundColor Yellow
Write-Host ""
Write-Host "==== 外机一键命令 END ====" -ForegroundColor Yellow
Write-Host ""

Write-Host "外机跑完后 (10 min), 回主机加外机:" -ForegroundColor Cyan
Write-Host "       pwsh scripts/register-rig.ps1 -RigAlias rig -RigHost $Vps -RigPort $RemotePort -RigUser mcp-rig" -ForegroundColor Cyan
Write-Host ""

Write-Host "以后再加外机 (port 用 6002/6003...):" -ForegroundColor DarkGray
Write-Host "       pwsh scripts/setup-host.ps1 -Vps $Vps -FrpToken '<同 token>' -RemotePort 6002" -ForegroundColor DarkGray
Write-Host ""