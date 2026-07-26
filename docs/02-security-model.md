# 安全模型详述

> host-rig-bridge 体系的**第三页**。讲清楚"为什么这些约束必须存在, 哪些可以放宽"。

## 一、纵深防御五层

```
┌───────────────────────────────────────────────────────────────┐
│ Layer 5: 审计与告警                                            │
│   access.log (sha256[:16] + bytes, 不写路径/参数)              │
│   host-rig-watchdog → 飞书告警                                  │
├───────────────────────────────────────────────────────────────┤
│ Layer 4: 应用层 (MCP server)                                   │
│   argv 白名单二次校验 + shlex.split                             │
│   shell=False (no shell injection)                             │
│   沙箱 in_sandbox (relpath 防前缀绕过)                          │
│   O_NOFOLLOW (防软链逃逸)                                       │
│   WRITE_CAP=1MB / STDOUT_CAP=64KB                              │
│   asyncio.Semaphore(4) 并发限                                  │
│   per-tool timeout (默认 600s, 异步 7200s, 上限 1800/7200)     │
├───────────────────────────────────────────────────────────────┤
│ Layer 3: SSH 强制命令 (账号层)                                  │
│   authorized_keys: command="python -u server.py",              │
│     no-port-forwarding, no-X11-forwarding,                     │
│     no-agent-forwarding, no-pty                                │
│   账号 Windows 本地账号 (OpenSSH forced command 锁死)             │
│   账号只能跑 server.py, 跑别的也回到 server.py                  │
├───────────────────────────────────────────────────────────────┤
│ Layer 2: 环境净化                                              │
│   子进程 env = {PATH, HOME, LANG, LC_ALL}                      │
│   阻 LD_PRELOAD / PYTHONPATH / GIT_SSH_COMMAND 等注入          │
├───────────────────────────────────────────────────────────────┤
│ Layer 1: 凭证隔离                                              │
│   主机一把 ed25519 key → 多分机账号                             │
│   授权粒度在账号层 (每账号独立 forced command)                   │
│   账号间互不可见 (chmod 700 ~/.ssh, 文件 mode 600)             │
└───────────────────────────────────────────────────────────────┘
```

**任一层失守, 下一层兜底**。最严的洞来自 review, 不是设计。

---

## 二、为什么这些约束必须存在

### 2.1 SSH config 必须 `BatchMode=yes` + `RequestTTY=no`

**why**: stdio over SSH 走 MCP 时, 任何 TTY 申请都会破坏 MCP framing(LSP/JSON-RPC over stdin/stdout), 让 Claude 收到乱七八糟的提示符/进度条/转义序列。

**踩坑**: `ssh <rig> python3 ...` 在没强制 RequestTTY=no 时, Linux SSH 默认会申请 PTY。MCP 客户端发的 `initialize` 请求可能被 PTY 的回显/控制序列污染。

**fix**: SSH config 段必须有 `BatchMode yes` + `RequestTTY no`。任何 wrapper 中间层(脚本、别名)都不能 fork TTY。

### 2.2 MCP server 工具 argv 必须二次校验

**why**: 即使白名单第一关过了, 也可能被 PATH 劫持、相对路径、奇怪的 escape 绕过。

**fix**:
```python
argv = shlex.split(cmd)                      # shell=False, 不会有注入
head = os.path.basename(argv[0])             # 提命令名
if head not in WHITELIST:
    raise PermissionError(f"not in whitelist: {head}")
argv[0] = WHITELIST[head]                    # 强制用绝对路径
await asyncio.create_subprocess_exec(*argv, env=SANE_ENV)
```

### 2.3 沙箱必须用 `os.path.relpath` 而非前缀匹配

**踩坑**:
```python
# ❌ 错: 前缀匹配, C:/Users/mcp-rig/projects_evil/ 也算"在沙箱内"
def in_sandbox(path):
    return os.path.realpath(path).startswith(SANDBOX)

# ✅ 对: relpath 必须以 . 开头才在沙箱内
def in_sandbox(path):
    rel = os.path.relpath(os.path.realpath(path), SANDBOX)
    return not rel.startswith("..") and not os.path.isabs(rel)
```

### 2.4 文件打开必须 `O_NOFOLLOW` + 二次 realpath

**why**: TOCTOU 攻击 + 软链逃逸。

**踩坑**:
```python
# ❌ 错: 先 realpath 再 open, 中间可被换软链
real = os.path.realpath(path)
if in_sandbox(real):
    with open(real) as f:   # 此时 realpath 可能已被换
        return f.read()

# ✅ 对: 拿 fd 后再 realpath, 软链拒跟
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
try:
    real = os.path.realpath("/proc/self/fd/" + str(fd))
    if not in_sandbox(real):
        raise PermissionError("escaped sandbox")
    with os.fdopen(fd) as f:
        return f.read()
except:
    os.close(fd)
    raise
```

### 2.5 env 必须净化

**why**: 哪怕白名单严格, `LD_PRELOAD=/tmp/evil.so iverilog` 仍能劫持。`PYTHONPATH` 改 site-packages 路径, `GIT_SSH_COMMAND` 配任意 proxy。

**fix**:
```python
SANE_ENV = {
    "PATH": "C:/Windows/System32;C:/Windows;C:/iverilog/bin;C:/altera/quartus/bin64;C:/openFPGALoader",
    "SYSTEMROOT": "C:/Windows",
    "USERPROFILE": "C:/Users/mcp-rig",
    "TEMP": "C:/Users/mcp-rig/AppData/Local/Temp",
    # 注意: 不设 LANG (Windows native 工具不认 POSIX locale, 设了反而拒启)
}
subprocess_exec(..., env=SANE_ENV)   # 不是 os.environ
```

### 2.6 账号必须 OpenSSH forced command 锁死

**why**: 纵深防御最后一层。即使 MCP server 自身有 bug, Windows 本地账号 + OpenSSH forced command 仍限制损伤面。

**fix**:
```bash
New-LocalUser + icacls (OpenSSH 锁死 forced command) mcp-rig
# authorized_keys:
command="C:/Users/mcp-rig/mcp-server/.venv/bin/python -u C:/Users/mcp-rig/mcp-server/src/server/server.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...
```

任何用 `mcp-rig` 账号的 SSH 都会被强制转走 server.py, 跑别的命令也只是把别的命令的参数传给 server.py(若 server.py 拒收, 啥都不发生)。

### 2.7 stdout 必须 64KB 截断

**why**: 单 message 64KB 是 MCP framing 的安全上限, 超过会触发重传/丢包。Quartus 综合输出能轻松到几 MB。

**fix**:
```python
if len(stdout) > STDOUT_CAP:
    stdout = stdout[:STDOUT_CAP] + b"\n... [truncated, use task_output_stream]"
```

长输出走场景 3 的 task_output_stream。

### 2.8 审计日志必须去敏感

**why**: 日志本身会变成敏感资产。若写原始路径 `C:/Users/mcp-rig/projects/secret-project/...`, 日志泄露 = 项目结构泄露。

**fix**:
```python
def audit(tool, args, duration_ms, bytes_in, bytes_out, ok):
    args_hash = hashlib.sha256(repr(args).encode()).hexdigest()[:16]
    log_entry = f"{ts} tool={tool} args={args_hash} dur={duration_ms}ms in={bytes_in}B out={bytes_out}B ok={ok}\n"
```

只记 16 位 hash 前缀 + 字节数 + 耗时, 不写路径/参数本体。

---

## 三、白名单为什么只有这 5 项

| 命令 | 白名单 | 理由 |
|---|---|---|
| `iverilog` | ✅ | iverilog 编译 |
| `vvp` | ✅ | iverilog 仿真 |
| `quartus_sh` | ✅ | Quartus 综合/烧录 |
| `openFPGALoader` | ✅ | 通用 FPGA 烧录 |
| `ls` | ✅ | 列目录(白名单中唯一非工具链) |

### 被砍掉的危险命令(及为什么)

| 命令 | 危险 | 替代 |
|---|---|---|
| `git` | `git config core.sshCommand '<rce>'` 逃逸 | 不用 git 同步(走主机 git push) |
| `echo` | `echo xxx > C:/Users/mcp-rig/.ssh/authorized_keys` 写任意文件 | 用 `write_file` |
| `make` | `Makefile` 可写任意 shell | 不用 make |
| `cat` | 读 `/etc/shadow` / `~/.ssh/id_*` | 用 `read_file` |
| `rm` / `mv` / `cp` / `mkdir` | 沙箱破坏 / 改名绕过沙箱 | 用 `delete_file` / `write_file` / `mkdir` |

任何加白名单命令必须先经 `cavecrew-reviewer` 走一轮, 看 argv 注入面。

---

## 四、凭证模型

### 4.1 一把 key 走多个账号

主机一把 ed25519 `id_claude_mcp` → 分机的 `mcp-rig` 账号 + 必要时 `mcp-rig-debug` 账号。

**why 简单**:
- 主人机器少(1-3 台主机, 3-5 台分机), 多 key 维护成本不划算
- 授权粒度在**账号层**, 跟 key 解耦 — 换 key 不影响授权

**why 安全**:
- 任何分机被攻破, 损伤面 = 这个账号能干啥
- 账号层有 forced command 兜底

### 4.2 不加 passphrase

**why**: 加了 passphrase, 主机 Claude 调用要手工解锁。破坏"自动化"语义。

**why 风险可控**:
- key 在主机硬盘, 主机的访问控制 = key 的访问控制
- Windows 主机靠 DPAPI 保护私钥(默认 0600)
- 定期轮换(见 §4.4)

### 4.3 不加 source IP 限制

**why**: 主人有时在笔记本(192.168.x.x), 有时在主机(127.0.0.1), 有时 SSH 隧道进(10.x.x.x)。固定 IP 太死。

**风险**: 笔记本丢了, key 落到别人手里, IP 段内可登。缓解: 笔记本登 bitlocker + DPAPI。

### 4.4 定期轮换

**节奏**: 每 6 个月换一次 key。

**流程**:
1. 主机 `ssh-keygen -t ed25519 -f ~/.ssh/id_claude_mcp_2026H2 -N ""`
2. 主机 `register-rig.ps1 -KeyPath ~/.ssh/id_claude_mcp_2026H2` 把新 key 推到所有分机
3. 主人验收所有分机 SSH 通, 删旧 key:
   - 主机: `rm ~/.ssh/id_claude_mcp ~/.ssh/id_claude_mcp.pub`
   - 各分机: 从 authorized_keys 删旧 key 行
4. 把新 key 重命名成 `id_claude_mcp` 替换

详见 `docs/04-key-rotation.md`(Phase D 加)。

---

## 五、不污染 MCP server

**原则**: watchdog 不调用 MCP 工具, server 不为 watchdog 开任何接口。

**why**:
- server 简洁, 不为外部监控做妥协
- watchdog 是纯外部探针, 挂了不影响 server

**watchdog 看啥**:
- SSH BatchMode 直连
- `pgrep -af server.py` 进程存在性
- 沙箱磁盘 / inode
- `~/.claude.json` 端到端 round-trip

**watchdog 不看啥**:
- MCP stdio 流量(那是 Claude 独占)
- server 内存/CPU(server 是 SSH 子进程, 跟 SSH 同生命周期, 不需要单独监控)

---

## 六、威胁模型

### 6.1 假设的攻击面

| 攻击者 | 入口 | 想干啥 | 防护 |
|---|---|---|---|
| 主人笔记本丢了 | 主机 key + DPAPI | 登分机 / 改代码 | DPAPI / BitLocker / forced command |
| 主人手机丢了 | Termux key | 反向 SSH 回主机 | home key 失效 / 主人机 sshd 重发 key |
| 分机被管理员 | 任何账号 | 改 server.py / 读 access.log | 本地账号 + OpenSSH forced command 阻交互, server.py 需 mcp-rig 启动权限 |
| MCP client bug | Claude 调用 | 跑白名单外命令 / 写沙箱外 | argv 二次校验 + 沙箱 + env 净化 |
| 恶意 verilog | 主人上传 | 利用 iverilog 漏洞 | iverilog 跑在沙箱内, 失败被白名单拦, env 净化 |
| 网络嗅探 | 中间人 | 看 MCP 流量 | SSH 加密 + 主机 key 校验 |

### 6.2 不防什么

- **主人自己搞自己**: 主人 root, 想绕所有防御都行。体系防的是"主人在跑 Claude 时, 意外被 Claude 误调用拖入洞"。
- **MCP server 代码自身漏洞**: server.py 是 Python, 有 GIL, 受 Python 标准库安全保证。代码 review 由 `cavecrew-reviewer` 把关。
- **物理接触**: 笔记本丢了靠 OS 加密, 不在本体系范围。

---

## 七、review 与审计节奏

- **每次 server.py 改动**: 走 `cavecrew-reviewer` 一轮
- **每月**: 看 `access.log` 异常条目(高频失败、异常大字节数)
- **每季**: 轮换 key(见 §4.4)
- **每年**: 复查 v2 已修的 8 个 🔴 仍是修复状态, 没被新代码回归

详见 `docs/05-watchdog.md` 的告警聚合 + 审计节奏。

---

## 下一步

- 分机清单 schema: [`03-rigs-format.md`](./03-rigs-format.md)
- 异步任务接口契约: [`04-async-tasks.md`](./04-async-tasks.md)
- 诊断守护: [`05-watchdog.md`](./05-watchdog.md)