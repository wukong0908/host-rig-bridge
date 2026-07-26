# host-rig-bridge watchdog

主机侧分机诊断守护, 5min 一次, 4 类探针:

| 探针 | 触发 | 级别 |
|---|---|---|
| SSH 连通 | `ssh -T echo OK` 失败/超时 | 🟡 WARN |
| MCP server 进程 | `pgrep -af server.py` 空 | 🔴 CRIT |
| 沙箱磁盘 | `df -P <sandbox>` >85%/95% | 🟡/🔴 |
| 主机 claude.json | 解析失败/缺 mcpServers.<rig> | 🟡 WARN |

详见 [`docs/05-watchdog.md`](../docs/05-watchdog.md)。

## 一键注册

```powershell
pwsh watchdog/install-watchdog.ps1
```

注册计划任务 `host-rig-watchdog` (SYSTEM + Highest + AtStartup + 5min 循环 3650d)。

## 手动跑

```powershell
pwsh watchdog/host-rig-watchdog.ps1                       # 跑 rigs.local.yaml 全清单
pwsh watchdog/host-rig-watchdog.ps1 -RigAlias rig          # 只跑一台
pwsh watchdog/host-rig-watchdog.ps1 -DryRun                # 不发飞书, 仅打印告警
```

## 卸载

```powershell
Unregister-ScheduledTask -TaskName host-rig-watchdog -Confirm:$false
```

## 状态目录

`watchdog/state/` 运行时生成 `*.last_sent` (gitignored), 1h 内同告警去重。