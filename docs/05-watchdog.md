# 主机侧诊断守护

> `watchdog/` 模块的设计、监控项、告警触发、飞书推送。

## 一、定位

watchdog 是**纯外部探针**, 不调用 MCP 工具, 不进 MCP stdio。挂在主机侧, 周期性检查:
- 分机 SSH 可达性
- 分机 MCP server 进程存活
- 异步任务异常
- 沙箱磁盘 / inode

异常 → 飞书告警(聚合防风暴)。

## 二、部署

| 项 | 值 |
|---|---|
| 脚本路径 | `C:\Users\WuKong\.claude\scripts\host-rig-watchdog.ps1` |
| 注册方式 | Windows 计划任务 `host-rig-watchdog` |
| 触发器 | `RepetitionInterval 5min` + `RepetitionDuration 3650days` |
| 主体 | `SYSTEM` + `Highest` |
| 自愈 | `RestartCount 3` + `RestartInterval 1min` |
| 启动时机 | `AtStartup` |

由 `watchdog/install-watchdog.ps1` 一键注册。

**为什么不污染 MCP server**:
- server.py 简洁, 不为外部监控做妥协
- watchdog 挂了不影响 server
- watchdog 看啥是「主机可观察到的分机状态」, 不需要 server 开任何接口

## 三、监控项

| 监控项 | 探针 | 触发条件 | 级别 |
|---|---|---|---|
| SSH 连通 | `ssh -T -o BatchMode=yes -o ConnectTimeout=5 <rig> "echo OK"` | 失败 / 超时 | 🟡 WARN |
| MCP server 进程 | `ssh <rig> "powershell Get-Process python \| Where-Object CommandLine -like '*server.py*'"` | 返回空 | 🔴 CRIT |
| 异步任务失败 | 读 `tasks.db` state=exited rc≠0 | 出现 1 次 | 🟡 WARN |
| 异步任务异常退出 | state=exited rc=0 但 stderr 非空 | 出现 | 🟢 INFO(可关) |
| 沙箱磁盘 | `ssh <rig> "powershell Get-PSDrive -Name C \| % used"` | >85% WARN, >95% CRIT | — |
| 主机 ~/.claude.json 注册 | `Get-Content $HOME\.claude.json` 解析 + 含 mcpServers.<rig> | 解析失败 / 缺 rig | 🟡 WARN |
| 端到端 round-trip | 任意 MCP 工具调用失败(由主人手动跑 verify.ps1 测) | 失败 | 🔴 CRIT |

## 四、飞书推送

**复用**: `~\.claude\scripts\feishu.ps1` wrapper(主人已有, 不重写)。

**封装**: `watchdog/feishu-notify.ps1` 是薄封装:
```powershell
& "$HOME\.claude\scripts\feishu.ps1" im send `
    -to "18167703692" `
    -text "[host-rig-bridge] $level ${rig}: ${msg}"
```

**告警聚合**(防风暴):
- 5min 一次, 同一 `rig + level + msg` 在 1h 内只推一次
- 状态: `watchdog/state/<rig>.<level>.<msg-hash>.last_sent`
- 状态文件过期(>1h)允许重推

**告警消息格式**:
```
[host-rig-bridge] 🔴 CRIT  rig-192.168.x.x:
MCP server 进程消失
  → ssh rig "pgrep -af server.py" 返回空
  → 最近一次访问: 2026-07-26 14:30:22 (audit log)
  → 排查: ssh <rig> 检查 server 状态, 或跑 pwsh scripts/verify.ps1 -Rig <rig>
```

## 五、告警级别语义

| 级别 | 含义 | 主人动作 |
|---|---|---|
| 🟢 INFO | 信息, 不一定有问题 | 看一眼 |
| 🟡 WARN | 可能影响使用, 但还能跑 | 5min 内自查 |
| 🔴 CRIT | 链路断了 / 任务失败 / 资源耗尽 | 立刻处理 |

## 六、关闭告警(主人可关)

每条告警可单独关。在 `rigs.local.yaml` 加:
```yaml
watchdog:
  disabled_alerts:
    - rig.async_task_stderr           # 关掉「异步任务 stderr 非空」告警
    - rig.sandbox_inode_warn          # 关掉「沙箱 inode >85%」告警
```

默认开启: `ssh_disconnect` / `mcp_server_down` / `sandbox_disk_crit` / `e2e_round_trip_fail`。

## 七、watchdog 不看啥

- **MCP stdio 流量** — 那是 Claude 独占, watchdog 不窥探
- **server.py 内存/CPU** — server 是 SSH 子进程, 跟 SSH 同生命周期, 不需要单独监控
- **主人手动跑的临时命令** — 走主人机审计, 不归 host-rig-bridge

## 八、相关文件

- `watchdog/host-rig-watchdog.ps1` — 主脚本
- `watchdog/install-watchdog.ps1` — 注册计划任务
- `watchdog/feishu-notify.ps1` — 飞书封装
- `watchdog/state/` — 告警聚合状态(gitignored, 运行时生成)

## 下一步

- 回 [`01-scenarios.md`](./01-scenarios.md) 看三场景使用
- 回 [`02-security-model.md`](./02-security-model.md) 看威胁模型与审计节奏