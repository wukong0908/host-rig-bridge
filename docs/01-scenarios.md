# 三场景使用手册

> 这是 host-rig-bridge 体系的**第二页**。按场景给「怎么用、踩什么坑、典型流程」。

---

## 场景 1: 主机 → 分机(同步工具链调用)

### 何时用

- 分钟级同步编译(`iverilog` / `quartus_sh` 综合)
- FPGA 烧录(`openFPGALoader`)
- 读 / 写 / 列分机沙箱内文件
- 单次跑命令, 几秒到几十分钟能完

### 工具集(MCP 暴露)

| 工具 | 用途 | 典型签名 |
|---|---|---|
| `run_command` | 跑白名单二进制(同步等结果) | `(cmd: str, cwd: str \| None, timeout: int = 600) -> str` |
| `read_file` | 读沙箱内文件(分块) | `(path: str, offset: int = 0, size: int = 65536) -> str` |
| `write_file` | 写沙箱内文件(≤1MB) | `(path: str, content: str) -> None` |
| `delete_file` | 删沙箱内文件(拒删沙箱根) | `(path: str) -> None` |
| `list_dir` | 列沙箱目录 | `(path: str = ".") -> list[str]` |
| `mkdir` | 建沙箱内子目录 | `(path: str) -> None` |

### 典型流程(从主机 Claude 端)

```
主人: "帮我把 C:/Users/mcp-rig/projects/fpga/blink.v 用 iverilog 编译, 输出 vvp"

主机 Claude:
  1. write_file("C:/Users/mcp-rig/projects/fpga/blink.v", <verilog 源码>)
  2. run_command("iverilog -o C:/Users/mcp-rig/projects/fpga/blink.vvp C:/Users/mcp-rig/projects/fpga/blink.v")
     → 返回 {"rc": 0, "stdout": "", "stderr": ""} 或错误
  3. 主人: "跑 vvp 仿真"
     → run_command("vvp C:/Users/mcp-rig/projects/fpga/blink.vvp")
  4. 主人: "烧到板子"
     → run_command("openFPGALoader -b cy10_eval kit C:/Users/mcp-rig/projects/fpga/blink.vvp")
```

### 限制与坑

- **同步等结果** — 若超时(默认 600s, 最长 1800s)直接 kill。需要长跑走场景 3。
- **stdout 64KB 截断** — Quartus 综合输出可能爆, 走场景 3。
- **沙箱限** `/home/<rig-user>/projects/` — 沙箱外路径 `read_file("/etc/passwd")` 被拒。
- **白名单限** — `iverilog` / `vvp` / `quartus_sh` / `openFPGALoader` / `ls`, 其它命令被拒。
- **路径 realpath 防前缀绕过** — `/home/<rig-user>/projects_evil/` 不在沙箱内(用 `os.path.relpath` 判定)。

### 排查

```
ssh <rig>                                           # 登入分机(mcp-rig-debug 账号)
ls -la C:/Users/mcp-rig/mcp-server/                    # 看 server.py 状态
tail -f C:/Users/mcp-rig/mcp-server/access.log         # 看审计日志(去敏感)
pgrep -af server.py                                  # 看进程在不在
C:/Users/mcp-rig/mcp-server/.venv/bin/python -c \
  "from mcp.server.fastmcp import FastMCP; print('OK')"  # 验 SDK
```

---

## 场景 2: 分机 → 主机(反向 SSH, frp 中转)

### 何时用

- 主人在外网(手机 Termux / 办公室电脑 / 老家电脑)想远程操作家里的 Claude
- 主人在路上, 主机 Claude 在跑, 想发个新任务

### 形态

```
主人手机/Termux
  │  ssh home
  ▼
阿里云 VPS (8.163.106.31, frps :6000)
  │  frp 隧道
  ▼
主机家里 (frpc 任务计划 → sshd :22 → Claude)
```

### 现有资产

- **阿里云 ECS**: Ubuntu 22.04 UEFI, 公网 `8.163.106.31`, 到期 2027-07-22
- **frps**: `/etc/systemd/system/frps.service`, `0.0.0.0:7000`
- **主机 frpc**: 任务计划 `frpc-bg`, `SYSTEM` + `Highest` + `RestartCount 3`
- **sshd**: OpenSSH 重装到 `C:\Program Files\OpenSSH`(避坑: 系统自带 zip 半覆盖)
- **default shell**: pwsh 7
- **凭证**: `~/.ssh/home_claude_key`(主人 Win), `~/.ssh/home_claude_termux`(手机)
- **上锁**: `PasswordAuthentication no`, 旧 `cf_test_key` 已删

### 完整决策与踩坑

权威来源: `memory/project/home-ssh-tunnel.md` 和 `2026-07-21_SSH远程接入ClaudeCode.md`。

本仓 `frp/` 子模块提供:
- `frpc.toml.example` — frpc 配置模板
- `install-frpc.ps1` — 主机侧下载 frpc + 注册计划任务
- `sshd-config.fragment` — sshd_config 锁片段
- `setup-termux.sh` — Termux 端 key 安装

### 加一台新客户端(手机/外网 Win)

```
主人 Win / 外网 Win:
  1. 复用 ~/.ssh/home_claude_key 或新生成 ed25519
  2. 把公钥发给主机主人, 主机主人粘到:
     C:\ProgramData\ssh\administrators_authorized_keys
     (注意 ACL 收紧: icacls /inheritance:r /grant SYSTEM:F /grant BUILTIN\Administrators:F)
  3. ~/.ssh/config 加:
     Host home
       HostName 8.163.106.31
       Port 6000
       User WuKong
       IdentityFile ~/.ssh/home_claude_key
       IdentitiesOnly yes
       ServerAliveInterval 30
       ServerAliveCountMax 6
       StrictHostKeyChecking accept-new
       ControlMaster auto
       ControlPath ~/.ssh/cm-%r@%h:%p
       ControlPersist 10m
  4. ssh home 验握手

手机 Termux:
  pkg install openssh
  生成 ed25519, 公钥同上粘法
  ~/.ssh/config 同上(ControlMaster 复用)
```

### 链路维护

```
frpc 进程死了:
  → 任务计划应自动重启(RestartCount 3)
  → 5min 内连不上 → 飞书告警(链路 2 的监控不在本仓, 沿用现有 frpc-bg 计划任务)

VPS frps 挂了:
  → systemd status frps
  → VPS 控制台远程重启

sshd 配置改了:
  → 必须在 OpenSSH 自己的 sshd_config (C:\ProgramData\ssh\sshd_config)
  → 不能动系统自带的(避坑)

需要换 VPS:
  → 新建 ECS, 装 frps
  → 主机 frpc.toml 改 serverAddr
  → 注册任务计划刷新
```

---

## 场景 3: 主机 → 分机(异步长任务)

### 何时用

- Quartus 综合跑半小时以上
- 仿真过夜
- 批量回归测试(几十上百次编译/烧录/验证)
- 跑长流程, 主人不想守着

### 工具集(MCP 暴露, 在场景 1 6 工具基础上加 4 个)

| 工具 | 用途 | 典型签名 |
|---|---|---|
| `start_task` | 后台起任务, 立即返回 task_id | `(cmd, cwd=None, timeout=7200, stream_chunk=4096) -> {task_id, pid, state, log_path}` |
| `task_status` | 查任务当前状态 | `(task_id) -> {task_id, pid, state, rc, started_at, ended_at, duration_ms, stdout_bytes, stderr_bytes}` |
| `task_cancel` | 取消任务 (SIGTERM → 5s → SIGKILL) | `(task_id, force=False) -> {state, signal}` |
| `task_output_stream` | 拉增量输出 | `(task_id, offset=0, max_bytes=65536, follow=False, follow_timeout=30) -> {offset, chunk, state, eof}` |

### 异步 vs 同步的区别

| | run_command (场景 1) | start_task (场景 3) |
|---|---|---|
| 阻塞 | 同步等结果 (≤1800s) | 立即返回 |
| 输出 | 一次性返回 (64KB 截断) | 增量流式拉 (分多次) |
| 持久化 | 无 | sqlite (`/home/<rig-user>/mcp-server/tasks.db`) |
| 取消 | 不支持 | `task_cancel` |
| 适用 | 分钟级 | 小时级 / 过夜 |

### 典型流程

```
主人: "在分机上跑一个 Quartus 综合, 跑完告诉我"

主机 Claude:
  1. start_task("quartus_sh --flow compile C:/Users/mcp-rig/projects/fpga/blink",
                cwd="C:/Users/mcp-rig/projects/fpga",
                timeout=7200)
     → {task_id: "ts-20260726-143022-a1b2c3",
        pid: 12345,
        state: "running",
        log_path: "C:/Users/mcp-rig/mcp-server/tasks/ts-20260726-143022-a1b2c3/stdout.log"}

  2. 主人: "看下进度"
     → task_status("ts-20260726-143022-a1b2c3")
     → {state: "running", duration_ms: 1834000, stdout_bytes: 48921, stderr_bytes: 0}

  3. 主人: "拉最后 64KB 输出"
     → task_output_stream("ts-20260726-143022-a1b2c3", offset=0, max_bytes=65536)
     → {offset: 48921, chunk: "<base64>", state: "running", eof: false}

  4. (5 分钟后) 飞书收到告警: "[host-rig-bridge] task ts-... exited rc=0"
     → 主人: "再看一次"
     → task_status(...)
     → {state: "exited", rc: 0, duration_ms: 18000000}

  5. 主人: "取消" (若还在跑)
     → task_cancel("ts-...", force=False)
     → {state: "cancelled", signal: "SIGTERM"}
```

### 限制与坑

- **follow 阻塞最长 30s** — 防 MCP framing 卡死。长输出分多次拉, 不一次 follow 到底。
- **stdout/stderr 分别 tee** — 主人看 stderr 才知道错误。
- **sqlite 文件 mode 0600** — `mcp-rig` 账号独占读写, 防其他账号看任务记录。
- **timeout 默认 7200s(2h)** — 超过自动 SIGTERM。需更长传 timeout 参数。
- **取消有 5s 宽限期** — SIGTERM 后等 5s 还活着才 SIGKILL(`force=True` 跳过宽限期)。

### 排查

```
ssh <rig>
sqlite3 C:/Users/mcp-rig/mcp-server/tasks.db \
  "SELECT task_id, state, rc, started_at FROM tasks ORDER BY started_at DESC LIMIT 10"
  → 看最近 10 个任务状态

ls -la C:/Users/mcp-rig/mcp-server/tasks/ts-*/
  → 看每个任务的 log 文件

cat C:/Users/mcp-rig/mcp-server/tasks/ts-*/stderr.log | tail -50
  → 看错误输出
```

---

## 三个场景共同的安全约束

- **SSH config 全部带**: `BatchMode yes` + `RequestTTY no` + `SendEnv none` + 独立 `known_hosts.<alias>`
- **账号层 forced command** — `mcp-rig` 账号只能跑 MCP server, 想临时调试用 `mcp-rig-debug` 账号(无 forced command)
- **审计日志** — sha256[:16] + 字节数, 不写原始路径/参数(避免日志变敏感资产)
- **env 净化** — 子进程只继承 `PATH` / `HOME` / `LANG` / `LC_ALL`, 阻 `LD_PRELOAD` 注入

详见 [`02-security-model.md`](./02-security-model.md)。

---

## 下一步

- 安全模型详述: [`02-security-model.md`](./02-security-model.md)
- 分机清单 schema: [`03-rigs-format.md`](./03-rigs-format.md)
- 异步任务接口契约: [`04-async-tasks.md`](./04-async-tasks.md)
- 诊断守护: [`05-watchdog.md`](./05-watchdog.md)