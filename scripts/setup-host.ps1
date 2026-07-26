# setup-host.ps1
# 主机一次性 setup: SSH key + SSH config + MCP 配置
# 跑法 (管理员 PowerShell 7):
#   "C:\Program Files\PowerShell\7\pwsh.exe" -ExecutionPolicy Bypass -NoProfile -File setup-host.ps1

$ErrorActionPreference = "Stop"

# ===== 配置 =====
$RigHost    = "192.168.x.x"   # ← 改成外机 IP
$RigUser    = "mcp-rig"
$KeyPath    = "$HOME\.ssh\id_claude_mcp"
$ConfigPath = "$HOME\.ssh\config"
$ClaudeCfg  = "$HOME\.claude.json"   # Claude Code 全局 MCP 配置
$ServerPath = "/home/mcp-rig/mcp-server/server.py"

Write-Host "[1/5] 装 SSH dir"
if (-not (Test-Path "$HOME\.ssh")) {
    New-Item -ItemType Directory -Path "$HOME\.ssh" | Out-Null
}

Write-Host "[2/5] 生成 SSH key (ed25519, 无密码)"
if (Test-Path $KeyPath) {
    Write-Host "    key 已存在, 跳过"
} else {
    ssh-keygen -t ed25519 -f $KeyPath -N "" -C "claude-mcp@$env:COMPUTERNAME"
}

Write-Host "[3/5] 追加 SSH config 段 (Host rig)"
$rigBlock = @"

# claude-mcp remote rig (added by setup-host.ps1)
Host rig
  HostName $RigHost
  User $RigUser
  IdentityFile $KeyPath
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $HOME\.ssh\known_hosts.rig
  ServerAliveInterval 60
  ServerAliveCountMax 3
  BatchMode yes
  RequestTTY no
  SendEnv none
  LogLevel ERROR
"@
Add-Content -Path $ConfigPath -Value $rigBlock -Encoding UTF8

Write-Host "[4/5] 写 MCP 配置到 ~/.claude.json"
$pubKey = Get-Content "$KeyPath.pub" -Raw

$rigArgs = @(
    "-T", "rig",
    "/home/mcp-rig/mcp-server/.venv/bin/python -u $ServerPath"
)

if (Test-Path $ClaudeCfg) {
    $existing = Get-Content $ClaudeCfg -Raw | ConvertFrom-Json
    if (-not $existing.mcpServers) {
        $existing | Add-Member -NotePropertyName mcpServers -NotePropertyValue (@{})
    }
    $existing.mcpServers."remote-rig" = @{
        command = "ssh"
        args    = $rigArgs
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content $ClaudeCfg -Encoding UTF8
} else {
    $mcpConfig = @{
        mcpServers = @{
            "remote-rig" = @{
                command = "ssh"
                args    = $rigArgs
            }
        }
    } | ConvertTo-Json -Depth 10
    $mcpConfig | Set-Content $ClaudeCfg -Encoding UTF8
}

Write-Host "[5/5] 输出公钥, 你要贴到外机 authorized_keys"
Write-Host "---- 主机公钥 BEGIN ----"
Write-Host $pubKey.Trim()
Write-Host "---- 主机公钥 END ----"

$nextSteps = @"

========================================
✅ 主机 setup 完成.

下一步:
  1. 把上面的公钥 (ssh-ed25519 ...) 拷贝到外机:
       ssh $RigUser@$RigHost   (密码登一次, 或用临时口令)
       退出后, 在外机 root:
         mkdir -p /home/$RigUser/.ssh
         printf 'command="/home/$RigUser/mcp-server/.venv/bin/python -u $ServerPath",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty %s\n' `$(cat /tmp/host_pubkey) >> /home/$RigUser/.ssh/authorized_keys
         chown -R $RigUser:$RigUser /home/$RigUser/.ssh
         chmod 700 /home/$RigUser/.ssh
         chmod 600 /home/$RigUser/.ssh/authorized_keys
  2. 首次 SSH 验握手:
       ssh -o StrictHostKeyChecking=accept-new rig
     (接受 fingerprint, 写进 known_hosts.rig)
  3. 重启主机 Claude Code, /mcp 看 remote-rig 是否 connected
  4. 验证: Claude 调 list_dir() 沙箱内应能列目录

"@
Write-Host $nextSteps