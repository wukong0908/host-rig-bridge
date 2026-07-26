# 场景 2 子模块: 反向 SSH (frp 中转)

> 链路 A: 外网(手机/办公室电脑)→ 阿里云 VPS frps → 主机家里 sshd → Claude Code。

## 当前资产(已落地,本仓只维护配置模板)

| 资产 | 位置 | 备注 |
|---|---|---|
| 阿里云 ECS | `8.163.106.31` (公网), `172.18.107.42` (私网) | Ubuntu 22.04 UEFI, `ecs-c1m1.large`, 到期 2027-07-22 |
| frps | `/etc/systemd/system/frps.service` | systemd unit, `0.0.0.0:7000` |
| frpc (主机) | 计划任务 `frpc-bg` | SYSTEM + Highest + RestartCount 3 |
| sshd (主机) | OpenSSH 重装到 `C:\Program Files\OpenSSH` | 避坑: 系统自带 zip 半覆盖 |
| 默认 shell | pwsh 7 (`HKLM:\SOFTWARE\OpenSSH\DefaultShell`) | |
| 主机凭证 | `~/.ssh/home_claude_key` (主人 Win/外网 Win), `~/.ssh/home_claude_termux` (Termux) | 管理员账户走 `administrators_authorized_keys` |
| 上锁 | `PasswordAuthentication no`, 旧 `cf_test_key` 已删 | |
| 延迟 | frp ≈ 150-200ms (亚太直连 VPS) | CF Tunnel 已于 2026-07-22 移除, 归档到 `claude-optimization/archives/cf-tunnel-removed-20260722/` |

## 本仓提供(增量维护)

| 文件 | 用途 |
|---|---|
| `frpc.toml.example` | frpc 配置模板 (踩坑: 顶层不加 heartbeat/tcpKeepalive) |
| `install-frpc.ps1` | 主机侧下载 frpc + 注册计划任务 (幂等) |
| `sshd-config.fragment` | sshd_config 锁片段 (密码禁, 审计开) |
| `setup-termux.sh` | Termux 端 key 安装 + SSH config |
| `README.md` | 本文件 |

## 部署新客户端(手机/外网 Win)

**手机 Termux**:
```bash
# Termux 跑
bash setup-termux.sh
# 公钥发给主机主人粘到 administrators_authorized_keys
```

**外网 Win**:
```powershell
# 复用 ~/.ssh/home_claude_key 或新生成 ed25519
ssh-keygen -t ed25519 -f $HOME\.ssh\home_claude_newkey -N ""

# ~/.ssh/config 加:
# Host home
#   HostName 8.163.106.31
#   Port 6000
#   User WuKong
#   IdentityFile ~/.ssh/home_claude_newkey
#   IdentitiesOnly yes
#   ServerAliveInterval 30
#   ServerAliveCountMax 6
#   StrictHostKeyChecking accept-new
#   ControlMaster auto
#   ControlPath ~/.ssh/cm-%r@%h:%p
#   ControlPersist 10m

ssh -o StrictHostKeyChecking=accept-new home
```

## 维护流程

### frpc 进程死了
```
# 计划任务应自动重启 (RestartCount 3)
Start-ScheduledTask -TaskName frpc-bg
Get-ScheduledTask -TaskName frpc-bg | Get-ScheduledTaskInfo
```

### VPS frps 挂了
```bash
# VPS 端
systemctl status frps
systemctl restart frps
```

### sshd 配置改了
```
# 必须在 C:\ProgramData\ssh\sshd_config (OpenSSH 自己的)
# 不能动系统自带的 (避坑)
Restart-Service sshd
```

### 换 VPS
```
1. 新建 ECS, 装 frps (systemd unit 沿用)
2. 主机 frpc.toml 改 serverAddr
3. 注册任务计划刷新
4. known_hosts 删旧 fingerprint, 重 SSH 验握手
```

## 关键踩坑(转自 home-ssh-tunnel.md)

- OpenSSH zip 半覆盖 → 必须重装
- 管理员 authorized_keys 位置 → `administrators_authorized_keys`, ACL 收紧
- Termux SSL_CERT_FILE → 不要 export
- `sc create` 静默失败 → 用 `Register-ScheduledTask`
- frpc.toml 顶层不能加 `heartbeatInterval` / `tcpKeepalive`(v0.61 报错)
- SSH config 不能加 `ControlPath none`(破坏 Connection Sharing)
- Bash 调 PowerShell `$env:TEMP` 转义 → 单引号包整字符串

## 完整决策

参考 `~\.claude\memory\project\home-ssh-tunnel.md` 完整决策 + 踩坑清单。
本仓不重复, 维护时增量更新 `frpc.toml.example` / `sshd-config.fragment` 即可。