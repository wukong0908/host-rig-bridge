# register-rig.ps1
# 主机侧: 一条命令注册一台分机 (key + SSH config + mcpServers)
# 跑法:
#   pwsh register-rig.ps1 -RigAlias rig -RigHost 192.168.x.x -RigUser mcp-rig
# 或读 ~/.claude/host-rig-bridge/rigs.local.yaml 默认值

[CmdletBinding()]
param(
    [string]$RigAlias = "",
    [string]$RigHost = "",
    [string]$RigUser = "",
    [string]$KeyPath = "$HOME\.ssh\id_claude_mcp",
    [string]$ConfigPath = "$HOME\.ssh\config",
    [string]$ClaudeCfg = "$HOME\.claude.json",
    [string]$RigsYaml = "$HOME\.claude\host-rig-bridge\rigs.local.yaml",
    [string]$ServerPath = "/home/mcp-rig/mcp-server/server.py"
)

$ErrorActionPreference = "Stop"

# ===== 简化: 不强制读 rigs.local.yaml (Phase D 加), 当前走命令行参数 =====
if ([string]::IsNullOrWhiteSpace($RigAlias) -or
    [string]::IsNullOrWhiteSpace($RigHost) -or
    [string]::IsNullOrWhiteSpace($RigUser)) {
    Write-Host "用法: pwsh register-rig.ps1 -RigAlias <alias> -RigHost <ip> -RigUser <user>" -ForegroundColor Yellow
    Write-Host "示例: pwsh register-rig.ps1 -RigAlias rig -RigHost 192.168.x.x -RigUser mcp-rig" -ForegroundColor Yellow
    exit 1
}

Write-Host "[1/5] 装 SSH dir"
if (-not (Test-Path "$HOME\.ssh")) {
    New-Item -ItemType Directory -Path "$HOME\.ssh" | Out-Null
}

Write-Host "[2/5] 生成 SSH key (ed25519, 无密码, 跳过若已存在)"
if (Test-Path $KeyPath) {
    Write-Host "    key 已存在: $KeyPath"
} else {
    ssh-keygen -t ed25519 -f $KeyPath -N "" -C "claude-mcp@$env:COMPUTERNAME"
}

Write-Host "[3/5] 追加 SSH config 段 (Host $RigAlias)"
# 幂等: 已存在则跳过
$existingConfig = if (Test-Path $ConfigPath) {
    Get-Content $ConfigPath -Raw
} else { "" }
$hostMarker = "Host $RigAlias"
if ($existingConfig -match "(?m)^Host $RigAlias\s*$") {
    Write-Host "    Host $RigAlias 段已存在, 跳过"
} else {
    $rigBlock = @"

# host-rig-bridge (added by register-rig.ps1)
Host $RigAlias
  HostName $RigHost
  User $RigUser
  IdentityFile $KeyPath
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $HOME\.ssh\known_hosts.$RigAlias
  ServerAliveInterval 60
  ServerAliveCountMax 3
  BatchMode yes
  RequestTTY no
  SendEnv none
  LogLevel ERROR
"@
    Add-Content -Path $ConfigPath -Value $rigBlock -Encoding UTF8
    Write-Host "    追加 Host $RigAlias 段到 $ConfigPath"
}

Write-Host "[4/5] 写 MCP 配置到 ~/.claude.json"
$pubKey = Get-Content "$KeyPath.pub" -Raw

$rigArgs = @(
    "-T", $RigAlias,
    "/home/$RigUser/mcp-server/.venv/bin/python -u $ServerPath"
)

if (Test-Path $ClaudeCfg) {
    $existing = Get-Content $ClaudeCfg -Raw | ConvertFrom-Json
    if (-not $existing.mcpServers) {
        $existing | Add-Member -NotePropertyName mcpServers -NotePropertyValue (@{})
    }
    $existing.mcpServers.$RigAlias = @{
        command = "ssh"
        args    = $rigArgs
    }
    $existing | ConvertTo-Json -Depth 10 | Set-Content $ClaudeCfg -Encoding UTF8
} else {
    $mcpConfig = @{
        mcpServers = @{
            $RigAlias = @{
                command = "ssh"
                args    = $rigArgs
            }
        }
    } | ConvertTo-Json -Depth 10
    $mcpConfig | Set-Content $ClaudeCfg -Encoding UTF8
}

Write-Host "[5/5] 输出公钥 + forced command 整行"
Write-Host "---- 主机公钥 BEGIN ----"
Write-Host $pubKey.Trim()
Write-Host "---- 主机公钥 END ----"

$nextSteps = @"

========================================
✅ Rig $RigAlias 注册完成.

下一步:
  1. 把上面的公钥贴到外机 $RigHost authorized_keys:
     外机 root 跑:
       sudo -u $RigUser tee -a /home/$RigUser/.ssh/authorized_keys <<< 'command="/home/$RigUser/mcp-server/.venv/bin/python -u /home/$RigUser/mcp-server/server.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $($pubKey.Trim())'

  2. 首次 SSH 验握手:
       ssh -o StrictHostKeyChecking=accept-new $RigAlias
     (接受 fingerprint)

  3. 重启主机 Claude Code, /mcp 看 $RigAlias connected.

  4. 验证 (Phase D 加): pwsh verify.ps1 -Rig $RigAlias
"@
Write-Host $nextSteps