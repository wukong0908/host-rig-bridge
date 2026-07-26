# rigs.yaml 字段定义

> 分机清单 schema 与加载规则。

## 文件位置

- **公开版示例**(入仓): `rigs.yaml` + `rigs.local.yaml.example`(仓库根)
- **真实清单**(主人私有): `~/.claude/host-rig-bridge/rigs.local.yaml`(gitignored)

## schema(version: 1)

```yaml
version: 1                          # 必填, 当前 1
default_rig: rig                    # 可选, Claude Code 不指定时连哪台

rigs:                               # 必填, 数组
  - alias: rig                      # 必填, 唯一, ssh 别名 + mcp server 名
    host: 192.168.x.x               # 必填, IP 或域名
    user: mcp-rig                   # 必填, 分机账号
    key: ~/.ssh/id_claude_mcp       # 必填, 主机私钥路径
    sandbox: /home/mcp-rig/projects # 必填, 路径沙箱根
    server: /home/mcp-rig/mcp-server/server.py  # 必填, server.py 绝对路径
    venv: /home/mcp-rig/mcp-server/.venv         # 必填, venv bin 路径

    capabilities: [sync, async]     # 可选, 默认 [sync]
                                   # sync  → run_command / read_file / write_file / delete_file / list_dir / mkdir
                                   # async → start_task / task_status / task_cancel / task_output_stream
                                   # 二者都加 → 10 个工具

    tools:                          # 可选, 默认空数组(若空则白名单为空)
      - iverilog
      - vvp
      - quartus_sh
      - openFPGALoader
      - ls

    notes: "实验室装机机"            # 可选, 自由备注
```

## 字段细节

### `alias`(必填)

- **唯一** — 数组内不能重复
- **字符集** — 小写字母 + 数字 + 中划线(`-`), 不超过 32 字符
- **冲突检测** — 跟 `~/.ssh/config` 现有 `Host <alias>` 段冲突时, `register-rig.ps1` 提示确认
- **MCP server 名** — 在 `~/.claude.json` 中作为 `mcpServers.<alias>` 的 key

### `host`(必填)

- IP(`192.168.x.x`) 或 域名(`rig.example.com`)
- **不要**写带端口 — 端口走 `~/.ssh/config` 段(默认 22)
- IPv6 用标准格式(`2001:db8::1`)

### `user`(必填)

- 分机账号名(典型 `mcp-rig`)
- **必须**是 nologin + forced command 配过的账号
- 多账号不同权限 → 多个 rig 条目, alias 加后缀(`rig` / `rig-debug`)

### `key`(必填)

- 主机私钥路径, `~` 开头
- 默认 `~/.ssh/id_claude_mcp`
- 同一主机一把 key, 不同 rig 共用(主人确认的设计)

### `sandbox`(必填)

- 路径沙箱根, 绝对路径, **不要**带尾部 `/`
- server.py 校验所有路径 `os.path.relpath` 在此目录之下
- 典型 `/home/mcp-rig/projects`

### `server`(必填)

- server.py 绝对路径
- 典型 `/home/mcp-rig/mcp-server/server.py`
- 由 `install.sh` 自动布置

### `venv`(必填)

- venv bin 路径(放 `python -u`)
- 典型 `/home/mcp-rig/mcp-server/.venv`
- 由 `install.sh` 自动布置

### `capabilities`(可选, 默认 `[sync]`)

- `sync` — 6 个同步工具
- `async` — 4 个异步工具
- 二者都加 — 10 个工具

注: 当前版本 server.py **总会暴露所有 10 工具**, capabilities 仅用于文档/审计,**不**做运行时拦截。Phase B 末会加运行时拦截(尊重 rig 声明)。

### `tools`(可选, 默认 `[]`)

- run_command 的 argv 白名单
- 每个名字必须存在于 server.py 的内置 `WHITELIST` 常量
- 典型 FPGA 工具链: `iverilog` / `vvp` / `quartus_sh` / `openFPGALoader` / `ls`
- **空数组 = 拒绝所有 run_command 调用**(其他文件操作仍可用)

### `notes`(可选)

- 自由备注, 不影响行为
- 例: "实验室装机机" / "备用编译机" / "退役, 仅 read"

## 加载规则

**优先级**(高 → 低):
1. 命令行参数 `-Rig <alias>`
2. `rigs.local.yaml` 的 `default_rig`
3. 报错退出

**加载失败处理**:
- `rigs.local.yaml` 不存在 → 报错, 提示 `cp rigs.local.yaml.example ~/.claude/host-rig-bridge/rigs.local.yaml`
- YAML 解析错 → 报错, 指出第几行
- 字段缺失 → 报错, 指出哪个 rig 哪个字段

## 校验

`scripts/verify-rig.ps1 -Rig <alias>` 会:
1. 加载 rigs.local.yaml
2. 找到对应 alias
3. SSH BatchMode 验握手(`ssh -o BatchMode=yes -o ConnectTimeout=5 <alias> "echo OK"`)
4. SSH 上跑 `test -f <server>` / `test -d <venv>` / `test -d <sandbox>`
5. SSH 上跑 `pgrep -af server.py` 看进程在不在
6. 端到端 MCP 工具调用(若 Claude 已重启加载 mcpServers)

详见 `scripts/verify.ps1` 实现。

## 扩展(未来)

- `version: 2` — 加 `tags: [fpga, esp32, build]` 等元数据, 主人按 tag 选 rig
- `health_check` — 周期性自检(由 watchdog 用), 而非外部探针
- `notify` — 告警通道覆盖(默认走主机 watchdog, 也可单 rig 单独推)

## 下一步

- 异步任务接口契约: [`04-async-tasks.md`](./04-async-tasks.md)
- 诊断守护: [`05-watchdog.md`](./05-watchdog.md)