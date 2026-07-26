# 架构总图 + 决策树

> 这是 host-rig-bridge 体系的**第一页**。回答「这是个啥、几条路径、该走哪条」三个问题。

## 一、体系位置

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         主机 Claude Code (Windows)                          │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  ~/.claude.json: mcpServers                                          │  │
│  │    "remote-rig" → ssh -T rig → python -u server.py                   │  │
│  │    "remote-rig2" → ssh -T rig2 → ...                                 │  │
│  │    "home" → 本机反向 SSH (链路 A 涉及)                                │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  主机侧诊断守护 host-rig-watchdog (5min 一次)                          │  │
│  │    → SSH 连通 / MCP server 进程 / 任务完成 / 沙箱磁盘                  │  │
│  │    → 异常推飞书                                                       │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────┬────────────────────────────────────────┘
                                     │ stdio over SSH (BatchMode + RequestTTY no)
                                     │
        ┌────────────────────────────┼────────────────────────────────┐
        │                            │                                │
        ▼                            ▼                                ▼
┌──────────────┐            ┌──────────────┐                ┌──────────────┐
│  分机 #1     │            │  分机 #2     │                │  分机 #N     │
│  mcp-rig 账 │            │  mcp-rig 账 │                │  mcp-rig 账 │
│  沙箱 C:/   │            │  沙箱 C:/   │                │  ...        │
└──────────────┘            └──────────────┘                └──────────────┘

外部世界 (主人手机 / 外网电脑)
        │
        ▼  反向 SSH (链路 A, frp 中转)
┌──────────────────────────────────────────┐
│  阿里云 VPS frps :7000                    │
│        │                                  │
│        ▼  frpc (主机侧计划任务)            │
│  主机 sshd :22 → Claude Code              │
└──────────────────────────────────────────┘
```

**核心组件**:
- **主机侧**: `~/.claude.json`(MCP 注册) + `~/.ssh/config`(SSH 别名) + `rigs.local.yaml`(分机清单) + `host-rig-watchdog`(诊断守护)
- **分机侧**: Windows 本地账号 `mcp-rig`(密码=随机 GUID, 只走 pubkey)+ OpenSSH forced command + MCP server 进程 + 沙箱目录 + 白名单二进制
- **链路 A(反向)**: VPS frps + 主机 frpc + sshd + Termux/外网 Win key

## 二、三场景对照

| | 场景 1: 主机 → 分机同步 | 场景 2: 分机 → 主机反向 | 场景 3: 主机 → 分机异步 |
|---|---|---|---|
| **触发方** | 主机 Claude 调工具 | 主人从外网 SSH | 主机 Claude 调工具 |
| **触达方向** | 主机 → 分机 | 外网 → 主机 | 主机 → 分机 |
| **协议** | stdio over SSH | SSH 反向 (frp) | stdio over SSH (异步) |
| **端口** | 无 (stdio over SSH) | VPS :6000 → 主机 :22 | 无 |
| **凭证** | 主机 key → 分机账号 | 主人 key → 主机 sshd | 同场景 1 |
| **落地** | `server/server.py` (sync tools) | `frp/` 子模块 | `server/tasks.py` |
| **同步/异步** | 同步阻塞 (≤30min) | 全双工 | 异步 (≤2h, 持久化) |

**使用边界**:
- 场景 1: 分钟级同步编译 / 烧录(超时 1800s)
- 场景 2: 主人从外网远程操作 Claude
- 场景 3: 长跑任务(综合 30min+ / 仿真过夜 / 批量回归)

## 三、决策树

### Q1: 我要从主机 Claude 调一个分机工具(iverilog / Quartus / 烧录)?

```
调一次, 几分钟内能完 → 场景 1: run_command
调一次, 可能跑半小时以上 → 场景 3: start_task + 后续轮询
调一批, 互相独立 → 场景 3: 多 start_task 并发
想拿工具输出做后续处理 → 场景 3: start_task + task_output_stream
只是想读分机上一个文件 → 场景 1: read_file (无需异步)
想写一个文件到分机 → 场景 1: write_file
```

### Q2: 我要从外网/手机远程操作 Claude?

```
家里电脑主机 Claude 在跑 → 场景 2: ssh home (链路 A)
主机没在跑 → 先 cc-launcher 起主机(参考 ~/.claude/scripts/cc-launcher.ps1)
手机 Termux → ~/.ssh/config 的 home 别名段已配 ControlMaster 复用
```

### Q3: 我要加一台新分机?

```
准备:
  1. 在 rigs.local.yaml 加这台机的清单
  2. 主机生成/复用 id_claude_mcp key

主机侧:
  pwsh scripts/register-rig.ps1 -RigAlias newrig

分机侧 (Windows):
  iwr -useb .../install.ps1 | iex

握手:
  ssh -o StrictHostKeyChecking=accept-new newrig

验证:
  pwsh scripts/verify.ps1 -Rig newrig

Claude:
  重启 Claude Code → /mcp 看 newrig connected
```

### Q4: 我要在分机上做一件 MCP 没覆盖的事(临时命令)?

```
不要! 通过 mcp-rig-debug 账号登(无 forced command)
  ssh -i ~/.ssh/id_claude_mcp mcp-rig-debug@<rig>
或直接拿主人账号上分机(无 MCP 限制)
```

### Q5: 链路挂了怎么办?

```
watchdog 收到飞书告警 → 看告警级别:
  WARN → 自己查 (5min 内复跑)
  CRIT → 立刻处理
        → ssh -v <rig> 看握手
        → ssh -T <rig> "pgrep -af server.py" 看进程
        → cat C:/Users/mcp-rig/mcp-server/access.log 看审计
        → 看 watchdog 告警消息里的具体探针失败原因
```

## 四、四层抽象

| 层 | 形态 | 谁维护 |
|---|---|---|
| **配置 / 凭证** | `~/.ssh/config` + `~/.ssh/id_claude_mcp` + `rigs.local.yaml` + 主机 `~/.claude.json` | 主人 (1-3 台分机手动) |
| **服务器模板** | `server/` 模块(白名单 + 沙箱 + env 净化 + 异步任务) | host-rig-bridge 仓统一维护 |
| **部署脚本集** | `scripts/` (install / setup / register / verify) | host-rig-bridge 仓统一维护 |
| **诊断 / 监控** | `watchdog/` 主机侧守护 + 飞书告警 | host-rig-bridge 仓统一维护 |

## 五、与历史产物的关系

- **`2026-07-21_SSH远程接入ClaudeCode.md`**: 链路 A 完整记录 → 本仓 `frp/` 子模块 + `docs/01-scenarios.md` 场景 2 章节引用
- **`2026-07-26_MCP远程外机工具链.md`**: 链路 B 完整记录 → 本仓 `server/` 拆分升级母版
- **`memory/project/home-ssh-tunnel.md`**: 链路 A 决策权威来源, 本仓直接引用, 不重复
- **`memory/knowledge/windows-python-mcp-pipe.md`**: MCP 跨进程三坑, 引用为权威

## 六、什么时候升级本体系?

- 加新场景: 编辑 `docs/01-scenarios.md` 加章节 + 在 `server/` 加工具
- 加新分机: 编辑 `rigs.local.yaml` + 跑 `register-rig.ps1` + 跑 `install.ps1`
- 改安全策略: 编辑 `docs/02-security-model.md` + 同步改 `server/sandbox.py`
- 升级 MCP 协议: 参考 `mcp[server]>=1.0,<2.0` 版本约束, 跨大版本需 `cavecrew-reviewer` 走一轮

## 下一步

- 三场景使用手册: [`01-scenarios.md`](./01-scenarios.md)
- 安全模型: [`02-security-model.md`](./02-security-model.md)
- 分机清单 schema: [`03-rigs-format.md`](./03-rigs-format.md)