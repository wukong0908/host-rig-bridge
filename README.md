# host-rig-bridge

> 主机 Claude Code ↔ 多台分机账号协作体系 — 单一可发布仓库。

## 这是啥

一套让「主机 Claude Code」能安全触达「多台分机(实验室装机机、家庭服务器、烧录器等)」的协作基建。收编三条场景, 共用一套配置 + 凭证 + 诊断守护:

| 场景 | 流向 | 形态 | 仓内路径 |
|---|---|---|---|
| 1. 同步工具链 | 主机 → 分机 | stdio over SSH + MCP server | `server/` + `scripts/` |
| 2. 反向 SSH 接入 | 分机 → 主机 | frp 中转 + sshd | `frp/` |
| 3. 异步长任务 | 主机 → 分机 | start_task / status / cancel / output_stream | `server/tasks.py` |

## 怎么用

### 主人侧(快速链接)

- **架构总览** + 决策树: [`docs/00-architecture.md`](./docs/00-architecture.md)
- **三场景使用手册**: [`docs/01-scenarios.md`](./docs/01-scenarios.md)
- **安全模型详述**: [`docs/02-security-model.md`](./docs/02-security-model.md)
- **分机清单 schema**: [`docs/03-rigs-format.md`](./docs/03-rigs-format.md)
- **异步任务接口契约**: [`docs/04-async-tasks.md`](./docs/04-async-tasks.md)
- **诊断守护**: [`docs/05-watchdog.md`](./docs/05-watchdog.md)

### 加一台新分机(30 秒)

主机:
```powershell
# 1. 在 rigs.local.yaml 加这台机的清单(模板见 rigs.local.yaml.example)
# 2. 跑通用注册脚本
pwsh scripts/register-rig.ps1 -RigAlias newrig
```

外机:
```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install.sh | bash -s -- --user mcp-rig
```

主机:
```powershell
# 3. 重启 Claude Code, /mcp 看 newrig connected
# 4. 跑端到端验证
pwsh scripts/verify.ps1 -Rig newrig
```

## 仓库结构

```
host-rig-bridge/
├── CLAUDE.md            # Claude 进入本仓的硬规则
├── README.md            # 本文件
├── LICENSE              # MIT
├── .gitignore
├── rigs.yaml            # 分机清单公开版示例
├── rigs.local.yaml.example
├── docs/                # 文档六层
├── server/              # MCP server 代码 (场景 1+3 共用)
├── scripts/             # 通用化部署脚本
├── frp/                 # 场景 2 反向 SSH 子模块
├── watchdog/            # 主机侧诊断守护
├── examples/            # 配置示例
└── plans/               # 进度追踪
```

## 凭证模型(一句话)

主机一把 ed25519 key → 多分机账号;授权粒度在**账号层**(SSH authorized_keys 的 `command=` 强制命令)。

## 当前状态

🟡 **Phase A 进行中** — 文档先行, 主体代码未动。

详见 [`plans/进度追踪.md`](./plans/进度追踪.md)。

## 入仓策略

- GitHub: `wukong0908/host-rig-bridge` (private)
- 走 PAT 形式(参考 `memory/github-pat.md`)
- 白名单: 见 `CLAUDE.md` §4
- 黑名单: 见 `CLAUDE.md` §5

## 致谢

本仓收编自两条历史链路:
- `2026-07-21_SSH远程接入ClaudeCode.md` (链路 A, 反向 SSH)
- `2026-07-26_MCP远程外机工具链.md` (链路 B, MCP 直触工具链)

详见 `claude-optimization/` 仓库归档。