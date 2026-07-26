# register-rig.ps1 — 主机侧: 一条命令注册一台分机 (key + SSH config + mcpServers)
# 跑法 (任一):
#   pwsh register-rig.ps1 -RigAlias rig                                   # 缺参从 rigs.local.yaml 读
#   pwsh register-rig.ps1                                                # 跑 rigs.local.yaml 全清单
#   pwsh register-rig.ps1 -RigAlias rig -RigHost 1.2.3.4 -RigUser mcp-rig # 命令行覆盖
#
# 行为 (幂等):
#   1. 装 ~/.ssh (若无)
#   2. 生成 ed25519 key (若已存在跳过)
#   3. 追加 ~/.ssh/config Host 段 (幂等)
#   4. 写 ~/.claude.json mcpServers (幂等)
#   5. 输出公钥 + forced command 整行 (供外机 root 贴 authorized_keys)

[CmdletBinding()]
param(
    [string]$RigAlias = "",
    [string]$RigHost = "",
    [string]$RigUser = "",
    [string]$RigKey = "",
    [string]$RigSandbox = "",
    [string]$RigServer = "",
    [string]$RigVenv = "",
    [string]$KeyPath = "$HOME\.ssh\id_claude_mcp",
    [string]$ConfigPath = "$HOME\.ssh\config",
    [string]$ClaudeCfg = "$HOME\.claude.json",
    [string]$RigsYaml = (Join-Path $HOME ".claude\host-rig-bridge\rigs.local.yaml")
)

$ErrorActionPreference = "Stop"

# dot-source 共享函数
. (Join-Path $PSScriptRoot "lib\ssh-helpers.ps1")
. (Join-Path $PSScriptRoot "lib\claude-config.ps1")
. (Join-Path $PSScriptRoot "lib\rigs-yaml.ps1")

# ===== 加载 rigs 清单 (命令行 < yaml) =====
$yamlRigs = @()
if (Test-Path $RigsYaml) {
    try { $yamlRigs = Read-RigsLocal -Path $RigsYaml }
    catch { Write-Warning "rigs.local.yaml 解析失败 (忽略, 走命令行): $_" }
}

# 决定目标 rig 列表
$targets = @()
if ($RigAlias) {
    # 显式指定一台
    $fromYaml = $null
    if ($yamlRigs) { try { $fromYaml = Find-Rig -Rigs $yamlRigs -Alias $RigAlias } catch {} }  # 找不到不抛, 后面兜底
    $r = [pscustomobject]@{
        alias = $RigAlias
        host = if ($RigHost) { $RigHost } elseif ($fromYaml) { $fromYaml.host } else { "" }
        user = if ($RigUser) { $RigUser } elseif ($fromYaml) { $fromYaml.user } else { "" }
        key  = if ($RigKey)  { Expand-HomePath $RigKey } elseif ($fromYaml -and $fromYaml.key) { $fromYaml.key } else { $KeyPath }
        sandbox = if ($RigSandbox) { $RigSandbox } elseif ($fromYaml) { $fromYaml.sandbox } else { "" }
        server  = if ($RigServer)  { $RigServer } elseif ($fromYaml) { $fromYaml.server } else { "/home/mcp-rig/mcp-server/server.py" }
        venv    = if ($RigVenv)    { $RigVenv } elseif ($fromYaml) { $fromYaml.venv } else { "/home/mcp-rig/mcp-server/.venv" }
    }
    if (-not $r.host -or -not $r.user) {
        throw "rig '$RigAlias' host/user 缺, 在 rigs.local.yaml 也没找到. 用 -RigHost / -RigUser 命令行覆盖"
    }
    $targets = @($r)
} elseif ($yamlRigs) {
    $targets = @($yamlRigs)
} else {
    throw "未指定 -RigAlias 且 rigs.local.yaml 不存在. 用法: pwsh register-rig.ps1 -RigAlias <alias> -RigHost <ip> -RigUser <user>"
}

Write-Host "[1/5] 装 SSH dir"
if (-not (Test-Path "$HOME\.ssh")) {
    New-Item -ItemType Directory -Path "$HOME\.ssh" | Out-Null
}

Write-Host "[2/5] 生成 SSH key (ed25519, 无密码) — 跳过若已存在"
if (Test-Path $KeyPath) {
    Write-Host "    key 已存在: $KeyPath"
} else {
    ssh-keygen -t ed25519 -f $KeyPath -N "" -C "claude-mcp@$env:COMPUTERNAME"
}

$pubKey = Get-Content "$KeyPath.pub" -Raw

foreach ($r in $targets) {
    Write-Host ""
    Write-Host "=== rig $($r.alias) ($($r.host) / $($r.user)) ===" -ForegroundColor Cyan

    Write-Host "[3/5] 追加 SSH config 段 (Host $($r.alias))"
    $kh = Join-Path $HOME ".ssh\known_hosts.$($r.alias)"
    $added = Append-SshConfigBlock -ConfigPath $ConfigPath `
        -Alias $r.alias -HostName $r.host -User $r.user -KeyPath $KeyPath -KnownHostsFile $kh
    if ($added) {
        Write-Host "    追加 Host $($r.alias) 段到 $ConfigPath"
    } else {
        Write-Host "    Host $($r.alias) 段已存在, 跳过"
    }

    Write-Host "[4/5] 写 MCP 配置到 ~/.claude.json (mcpServers.$($r.alias))"
    $rigArgs = @(
        "-T", $r.alias,
        "$($r.venv)/bin/python -u $($r.server)"
    )
    Add-McprigServer -ClaudeCfg $ClaudeCfg -Alias $r.alias -Args $rigArgs
    Write-Host "    mcpServers.$($r.alias) 已注入"
}

Write-Host ""
Write-Host "[5/5] 输出公钥 + forced command 整行"
Write-Host "---- 主机公钥 BEGIN ----"
Write-Host $pubKey.Trim()
Write-Host "---- 主机公钥 END ----"

Write-Host ""
Write-Host "下一步 (每台 rig):" -ForegroundColor Yellow
Write-Host "  1. 把上面公钥贴到外机 $($targets[0].host) authorized_keys:" -ForegroundColor Yellow
Write-Host "     外机 root 跑:" -ForegroundColor Yellow
foreach ($r in $targets) {
    $cmd = "command=`"$($r.venv)/bin/python -u $($r.server)`",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $($pubKey.Trim())"
    Write-Host "       sudo -u $($r.user) tee -a /home/$($r.user)/.ssh/authorized_keys <<< '$cmd'" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  2. 首次 SSH 验握手 (rig '$($r.alias)'):" -ForegroundColor Yellow
    Write-Host "       ssh -o StrictHostKeyChecking=accept-new $($r.alias)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  3. 重启主机 Claude Code, /mcp 看 $($r.alias) connected" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  4. 验证: pwsh verify.ps1 -Rig $($r.alias)" -ForegroundColor Yellow
    Write-Host ""
}