# 异步任务接口契约

> 场景 3 的 4 个 MCP 工具(start_task / task_status / task_cancel / task_output_stream)详细规范。

## 一、为什么需要异步

场景 1 的 `run_command` 是**同步阻塞**, 最长 1800s。FPGA 工具链的几个常见场景超出:

- Quartus 综合 30 分钟+
- 仿真过夜(8 小时)
- 批量回归(几十次 iverilog + vvp + diff)
- 模型训练(数小时)

主人在这种时长下不应阻塞等结果, 应**起任务 → 干别的 → 回头查**。

## 二、任务生命周期

```
       start_task                进程退出                  output EOF
   ────────────────►  running  ─────────────►  exited   ───────────►
                       │       ◄───────────                cleaned
                       │   task_cancel
                       │
                       ▼
                   cancelled
```

- `running` — 进程在跑, stdout/stderr 在增长
- `exited` — 进程退出, rc 已知
- `cancelled` — 主人显式 cancel, signal 已知(SIGTERM 或 SIGKILL)

## 三、4 个工具详细签名

### 3.1 `start_task`

```python
async def start_task(
    cmd: str,                    # 同 run_command, 走 WHITELIST + 沙箱 + env 净化
    cwd: str | None = None,      # 沙箱内相对路径, None = sandbox root
    timeout: int = 7200,         # 默认 2h, 上限 86400s (24h)
    stream_chunk: int = 4096,    # 输出分片大小 (bytes), 默认 4KB
) -> dict:
    """
    返回:
      {
        "task_id": "ts-20260726-143022-a1b2c3",
        "pid": 12345,
        "state": "running",
        "started_at": "2026-07-26T14:30:22Z",
        "log_path": "C:/Users/mcp-rig/mcp-server/tasks/ts-20260726-143022-a1b2c3/",
        "cmd_audit": "iverilog -o ... blink.v"   # 仅头 80 字 + hash[:16]
      }
    """
```

**行为**:
1. argv 白名单校验(复用 sandbox.py)
2. 生成 task_id: `ts-YYYYMMDD-HHMMSS-<6位hex>`
3. tasks.db INSERT(state=running, pid=NULL, cmd_hash)
4. 建目录 `C:/Users/mcp-rig/mcp-server/tasks/<id>/`
5. `asyncio.create_subprocess_exec` → Popen, stdout/stderr tee 到 `stdout.log` / `stderr.log`
6. 后台 `asyncio.create_task(watcher)` 监听进程退出 → UPDATE state=exited/<rc>
7. 立即返回(不阻塞)

**错误**:
- `cmd` 不在白名单 → `PermissionError("not in whitelist")`
- `cwd` 沙箱外 → `PermissionError("cwd escapes sandbox")`
- tasks.db 写入失败 → `RuntimeError("db error")`

### 3.2 `task_status`

```python
async def task_status(task_id: str) -> dict:
    """
    返回:
      {
        "task_id": "ts-20260726-143022-a1b2c3",
        "pid": 12345,                        # None 若已退出
        "state": "running" | "exited" | "cancelled",
        "rc": 0 | None,                      # 退出码, exited 后才有
        "signal": None | "SIGTERM" | "SIGKILL",  # 仅 cancelled 有
        "started_at": "2026-07-26T14:30:22Z",
        "ended_at": null | "2026-07-26T14:35:00Z",
        "duration_ms": 278000,
        "stdout_bytes": 48921,
        "stderr_bytes": 128
      }
    """
```

**行为**:
1. db SELECT
2. 若 state=running: 额外 `ps -p <pid>` 二次确认
   - 若 ps 显示已死但 db 未更新 → UPDATE state=exited, 返回最终 state
3. 返回结构化 dict

**错误**:
- `task_id` 不存在 → `LookupError("task not found")`

### 3.3 `task_cancel`

```python
async def task_cancel(task_id: str, force: bool = False) -> dict:
    """
    返回:
      {
        "task_id": "ts-...",
        "state": "cancelled",
        "signal": "SIGTERM" | "SIGKILL",
        "previous_state": "running" | "exited",
        "cancelled_at": "2026-07-26T14:32:00Z"
      }
    """
```

**行为**:
1. db SELECT 拿 pid + 当前 state
2. 若 state != running → 报错(已退出不可 cancel)
3. force=False: 发 SIGTERM, 等 5s, 还活着才 SIGKILL
4. force=True: 直接 SIGKILL
5. db UPDATE state=cancelled, signal=<sig>

**错误**:
- `task_id` 不存在 → `LookupError
- 进程已退出 → `RuntimeError("task already exited")`

**审计**: cancel 是高敏操作, 写 `access.log` 加 `args_hash` + reason(可空)

### 3.4 `task_output_stream`

```python
async def task_output_stream(
    task_id: str,
    offset: int = 0,             # 字节偏移, 默认 0 (从头读)
    max_bytes: int = 65536,      # 默认 64KB, 同 run_command
    follow: bool = False,        # True 时阻塞追新输出
    follow_timeout: int = 30,    # follow 阻塞最长 30s (防 MCP framing 卡死)
) -> dict:
    """
    返回:
      {
        "task_id": "ts-...",
        "offset": <new_offset>,           # 客户端下次传这个 offset
        "chunk": "<base64 encoded bytes>",
        "state": "running" | "exited" | "cancelled",
        "eof": bool,                       # stdout 是否已关闭
        "bytes_remaining": int | None      # 估算剩余字节数 (eof=False 时)
      }
    """
```

**行为**:
1. db SELECT 拿 log_path + state
2. 打开 `stdout.log` (或 stderr, Phase D 加 stream 参数) seek(offset) → read(max_bytes)
3. 若 follow=True: 在循环里 poll inode 变化 + tail-f 逻辑
   - EOF 或 follow_timeout 到期 → 返回
   - state=exited → 立即返回(不阻塞)
4. 返回新 offset + chunk + 当前 state

**关键设计**:
- `chunk` 用 base64(避免 UTF-8 边界问题, 二进制输出如 verilog 仿真波形可能含 raw bytes)
- `offset` 持久化在客户端, server 不存(简化, 多次调用客户端自管)
- `follow_timeout` 默认 30s, 上限 300s(防 framing 卡死 + 主人意外)
- 长输出**必须**分多次拉, 不一次 follow 到底

**错误**:
- `task_id` 不存在 → `LookupError
- offset 超过文件大小 → 返 `eof=True, chunk=""`
- max_bytes > 1MB → 报错(单 message 上限)

## 四、sqlite schema

文件: `C:/Users/mcp-rig/mcp-server/tasks.db`, mode `0600`, owner `mcp-rig:mcp-rig`

```sql
CREATE TABLE tasks (
    task_id      TEXT PRIMARY KEY,           -- ts-YYYYMMDD-HHMMSS-<6hex>
    cmd_audit    TEXT NOT NULL,              -- 仅头 80 字 (截断, 不写完整命令)
    cmd_hash     TEXT NOT NULL,              -- sha256(cmd)[:16]
    cwd          TEXT,
    pid          INTEGER,
    state        TEXT NOT NULL,              -- running | exited | cancelled
    rc           INTEGER,
    signal       TEXT,                       -- SIGTERM | SIGKILL | NULL
    started_at   TEXT NOT NULL,              -- ISO 8601 UTC
    ended_at     TEXT,
    timeout      INTEGER NOT NULL,           -- 秒
    log_dir      TEXT NOT NULL,              -- C:/Users/mcp-rig/mcp-server/tasks/<id>/
    stdout_bytes INTEGER DEFAULT 0,
    stderr_bytes INTEGER DEFAULT 0
);

CREATE INDEX idx_tasks_state ON tasks(state);
CREATE INDEX idx_tasks_started_at ON tasks(started_at DESC);
```

**手工查询**:
```bash
sqlite3 C:/Users/mcp-rig/mcp-server/tasks.db \
  "SELECT task_id, state, rc, started_at, ended_at FROM tasks ORDER BY started_at DESC LIMIT 10"
```

## 五、并发与资源限制

- **Semaphore(4)**: 同一分机最多 4 个并发任务(同 run_command 共用)
- **总任务数不限**: 但建议定期 `cleanup` (Phase D 加)
- **磁盘**: 每个 task 用 log 文件, 主人设 quota(走 watchdog 监控沙箱磁盘, >85% WARN, >95% CRIT)
- **内存**: server.py 本身不缓存 task 数据, 全在 sqlite

## 六、与 run_command 的关系

```
run_command("iverilog ...")        (场景 1, 同步)
   │
   └─► 内部实现 (Phase B 改):
       task_id = await start_task("iverilog ...")
       while True:
           status = await task_status(task_id)
           if status.state in ("exited", "cancelled"):
               break
           await asyncio.sleep(1)           # 轮询 1s
           if timeout:
               await task_cancel(task_id)   # 超时强杀
       stdout = await task_output_stream(task_id, max_bytes=65536)
       return {"rc": status.rc, "stdout": stdout, "stderr": ""}
```

**优点**: 同步/异步共享同一 argv 校验 + 沙箱 + env 净化 + 日志路径, **无重复代码**。
**权衡**: run_command 每次轮询 DB 有微开销(分钟级编译轮询 ~60 次, 可接受)。

## 七、watchdog 与异步任务告警

watchdog 读 `tasks.db`, 检测:
- `state=exited 且 rc≠0` → 🟡 WARN 推飞书
- `state=exited 且 rc=0 但 stderr_bytes > 0` → 🟢 INFO(可关)
- `state=exited 但 ended_at IS NULL`(异常) → 🔴 CRIT

详见 [`05-watchdog.md`](./05-watchdog.md)。

## 下一步

- 诊断守护: [`05-watchdog.md`](./05-watchdog.md)
- 回 [`01-scenarios.md`](./01-scenarios.md) 看场景 3 典型流程