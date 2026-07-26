# ssh-helpers.ps1 — 共享 SSH 工具函数
# 供 setup-host.ps1 / register-rig.ps1 / verify.ps1 复用

function Test-SshBatchMode {
    param([string]$Alias, [int]$TimeoutSec = 5)
    ssh -T -o BatchMode=yes -o RequestTTY=no -o "ConnectTimeout=$TimeoutSec" $Alias "echo SSH_OK"
}

function Read-KnownHosts {
    param([string]$Path = "$HOME\.ssh\known_hosts")
    if (Test-Path $Path) { Get-Content $Path } else { @() }
}

function Append-SshConfigBlock {
    param(
        [string]$ConfigPath = "$HOME\.ssh\config",
        [string]$Alias,
        [string]$HostName,
        [string]$User,
        [int]$Port = 22,
        [string]$KeyPath,
        [string]$KnownHostsFile
    )
    $existing = if (Test-Path $ConfigPath) {
        Get-Content $ConfigPath -Raw
    } else { "" }
    if ($existing -match "(?m)^Host $Alias\s*$") {
        return $false  # 已存在
    }
    # Port != 22 时写一行 (链路 B 走 VPS frp, 端口是 6001 等; 默认 LAN 22 不写)
    $portLine = if ($Port -ne 22) { "  Port $Port`n" } else { "" }
    $block = @"

# host-rig-bridge (added by register-rig.ps1)
Host $Alias
  HostName $HostName
$portLine  User $User
  IdentityFile $KeyPath
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $KnownHostsFile
  ServerAliveInterval 60
  ServerAliveCountMax 3
  BatchMode yes
  RequestTTY no
  SendEnv none
  LogLevel ERROR
"@
    Add-Content -Path $ConfigPath -Value $block -Encoding UTF8
    return $true
}