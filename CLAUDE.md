# host-rig-bridge

> Claude Code 进入本仓时的硬规则与触发情景。

## 仓库性质

「主机 Claude Code ↔ 多台分机账号」协作体系的**单一可发布仓库**。收编三条场景:
1. 主机 → 分机(同步工具链调用)
2. 分机 → 主机(反向 SSH, frp 中转)
3. 主机 → 分机(异步长任务, sqlite 持久化)

## Claude 在本仓的硬规则

1. **本文档是唯一真相源**。`README.md` 是人类入口, `docs/` 是分层手册。任何修改协议/流程必须先改对应文档, 再改代码。
2. **不要从零写**。新文件遵循 `docs/` 已有结构。新增条目先 review 是否能合并到现有文件。
3. **进度追踪义务**。每次 commit / 阶段切换 / 完成度变化 → 同步 `plans/进度追踪.md`。变更日志加新行。
4. **入仓白名单**:`docs/` / `server/` / `scripts/` / `frp/` / `watchdog/` / `examples/` / `README.md` / `CLAUDE.md` / `LICENSE` / `plans/` / `rigs.yaml` / `rigs.local.yaml.example` / `.gitignore`。
5. **入仓黑名单**(写入 `.gitignore`):`*.key` / `*.pub` / `**/.env*` / `**/__pycache__/` / `**/.venv/` / `**/*.bak*` / `**/tmp_*.ps1` / `rigs.local.yaml`(主人私有清单)。
6. **路径硬编码禁止**。所有外机路径(`C:/Users/mcp-rig/...`)/主机路径(`$HOME\.ssh\...`)必须通过 `rigs.local.yaml` 或环境变量注入。
7. **PowerShell 调用**: pwsh 7 走 `-File` 模式, 临时 ps1 用 `C:\Users\WuKong\.claude\scripts\tmp_<task>_<ts>.ps1`, 跑完即删。
8. **Python 调用**: 主机绝对路径 `C:/Users/WuKong/AppData/Local/Python/bin/python.exe`, 外机 venv 用 `C:/Users/<rig-user>/mcp-server/.venv/Scripts/python.exe`。
9. **变更 review**: 任何 `server/server.py` 改动必须先经 `cavecrew-reviewer` 走一轮(参考 2026-07-26 v1 8🔴 教训)。
10. **不要自动 git push**。本地写完等主人确认再推。

## 触发情景

主人在本目录(cwd = `D:\WuKong\Desktop\host-rig-bridge\`)或上层任一子目录下, 提出「跟分机/SSH/MCP/frp/凭证相关」需求时:
1. 先匹配现有 Phase 任务(`plans/进度追踪.md` 看当前阶段)
2. 改代码前先改对应文档章节
3. 完成后同步进度 + 变更日志

## 与历史产物的关系

| 历史 | 去向 |
|---|---|
| `claude-optimization/mcp-remote-rig/` (2026-07-26 链路 B 产物) | Phase B 升级迁移, Phase E 归档原目录 |
| `claude-optimization/2026-07-21_SSH远程接入ClaudeCode.md` (链路 A) | 收编为 `frp/` 子模块 + `docs/01-scenarios.md` 场景 2 章节 |
| `memory/project/home-ssh-tunnel.md` | 引用为权威决策来源, 不重复 |
| `memory/knowledge/windows-python-mcp-pipe.md` | 引用为权威, 不重复 |
| `~/.claude/scripts/feishu.ps1` | 复用, 不重写 |

## 阶段状态

查看 `plans/进度追踪.md` 顶部「整体状态」段。