"""server.py — host-rig-bridge MCP server 入口 (10 工具).

6 同步(run_command / read_file / write_file / delete_file / list_dir / mkdir)
+ 4 异步(start_task / task_status / task_cancel / task_output_stream).

所有沙箱/白名单/env 净化走 sandbox.py.
所有审计走 audit.py.
所有 sqlite 走 tasks_store.py.

走法: 既支持 'python -m server' (相对导入), 也支持 forced command
绝对路径 'python -u server.py' (sys.path 兜底). 下面 sys.path 兼容两种.
"""
from __future__ import annotations

import os
import sys

# 兼容 forced command 走绝对路径: 把本文件所在目录 (server/) 加 sys.path,
# 让绝对导入 audit/sandbox/tasks/tasks_store 能找到.
_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)

import asyncio
import json
import time
from hashlib import sha256

from mcp.server.fastmcp import FastMCP

import audit
import sandbox
import tasks
from tasks_store import init_db

# 启动时 init tasks db
init_db()

mcp = FastMCP("host-rig-bridge")


# ===== 同步工具 =====

@mcp.tool()
async def run_command(
    cmd: str,
    cwd: str | None = None,
    timeout: int = 600,
) -> str:
    """跑白名单命令: iverilog / vvp / quartus_sh / openFPGALoader.

    timeout 单位秒, 上限 1800s. 同步等结果.
    """
    if timeout > sandbox.SYNC_TIMEOUT_MAX:
        raise ValueError(f"timeout > {sandbox.SYNC_TIMEOUT_MAX}s not allowed")
    argv = sandbox.validate_argv(cmd)
    work = sandbox.validate_cwd(cwd)
    cmd_hash = sha256(cmd.encode()).hexdigest()[:16]

    t0 = time.monotonic()
    bytes_in = len(cmd)
    try:
        async with sandbox.get_sync_sema():
            proc = await asyncio.create_subprocess_exec(
                *argv,
                cwd=work,
                env=sandbox.SANE_ENV,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                limit=sandbox.STDOUT_CAP,
            )
            try:
                out, err = await asyncio.wait_for(
                    proc.communicate(), timeout=timeout
                )
            except asyncio.TimeoutError:
                proc.kill()
                await proc.wait()
                raise TimeoutError(f"command timeout after {timeout}s")
        out_s = out.decode(errors="replace")[:sandbox.STDOUT_CAP]
        err_s = err.decode(errors="replace")[:sandbox.STDOUT_CAP]
        # 截断时附 marker, 主人看到知道
        if len(out) > sandbox.STDOUT_CAP:
            out_s += f"\n...[truncated {len(out) - sandbox.STDOUT_CAP} bytes, use start_task for full]"
        if len(err) > sandbox.STDOUT_CAP:
            err_s += f"\n...[truncated {len(err) - sandbox.STDOUT_CAP} bytes, use start_task for full]"
        result = json.dumps(
            {"rc": proc.returncode, "stdout": out_s, "stderr": err_s},
            ensure_ascii=False,
        )
        audit.audit(
            "run_command",
            {"cmd_hash": cmd_hash, "cwd": work, "timeout": timeout},
            int((time.monotonic() - t0) * 1000), bytes_in, len(result),
            proc.returncode == 0,
        )
        return result
    except Exception:
        audit.audit(
            "run_command",
            {"cmd_hash": cmd_hash},
            int((time.monotonic() - t0) * 1000), bytes_in, 0, False,
        )
        raise


@mcp.tool()
async def read_file(path: str, offset: int = 0, size: int = sandbox.READ_CHUNK) -> str:
    """读文件, ≤64KB/chunk, 沙箱内. 沙箱外或软链拒."""
    if offset < 0 or size < 0 or size > sandbox.READ_CHUNK:
        raise ValueError(f"offset/size out of range")
    if not sandbox.in_sandbox(path):
        raise PermissionError("path escapes sandbox")
    t0 = time.monotonic()
    try:
        with sandbox.safe_open(path, "r") as f:
            f.seek(offset)
            content = f.read(size)
        audit.audit(
            "read_file",
            {"path": path, "offset": offset, "size": size},
            int((time.monotonic() - t0) * 1000), 0, len(content), True,
        )
        return content
    except Exception:
        audit.audit(
            "read_file", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, False,
        )
        raise


@mcp.tool()
async def write_file(path: str, content: str) -> None:
    """写文件, 沙箱内, ≤1MB. O_TRUNC 覆盖原内容."""
    if len(content) > sandbox.WRITE_CAP:
        raise ValueError(f"content too large (> {sandbox.WRITE_CAP} bytes)")
    if not sandbox.in_sandbox(path):
        raise PermissionError("path escapes sandbox")
    t0 = time.monotonic()
    try:
        with sandbox.safe_open(path, "w") as f:
            f.write(content)
        audit.audit(
            "write_file", {"path": path},
            int((time.monotonic() - t0) * 1000), len(content), 0, True,
        )
    except Exception:
        audit.audit(
            "write_file", {"path": path},
            int((time.monotonic() - t0) * 1000), len(content), 0, False,
        )
        raise


@mcp.tool()
async def delete_file(path: str) -> None:
    """删文件, 沙箱内, 拒删沙箱根."""
    t0 = time.monotonic()
    try:
        sandbox.safe_unlink(path)
        audit.audit(
            "delete_file", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, True,
        )
    except Exception:
        audit.audit(
            "delete_file", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, False,
        )
        raise


@mcp.tool()
async def list_dir(path: str = ".") -> list[str]:
    """列目录, 沙箱内. base 本身是 symlink 拒(指向沙箱外)."""
    t0 = time.monotonic()
    try:
        result = sandbox.safe_listdir(path)
        audit.audit(
            "list_dir", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, True,
        )
        return result
    except Exception:
        audit.audit(
            "list_dir", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, False,
        )
        raise


@mcp.tool()
async def mkdir(path: str) -> None:
    """建目录(含中间), 沙箱内."""
    t0 = time.monotonic()
    try:
        sandbox.safe_mkdir(path)
        audit.audit(
            "mkdir", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, True,
        )
    except Exception:
        audit.audit(
            "mkdir", {"path": path},
            int((time.monotonic() - t0) * 1000), 0, 0, False,
        )
        raise


# ===== 异步任务工具 (4) =====
# 转调 tasks.py, server.py 仅暴露入口, 逻辑都在 tasks.py.

@mcp.tool()
async def start_task(
    cmd: str,
    cwd: str | None = None,
    timeout: int = 7200,
) -> dict:
    """后台起任务, 立即返 task_id. 复用 sandbox.validate_argv + cwd.

    适用: Quartus 综合 30min+ / 仿真过夜 / 批量回归.
    timeout 单位秒, 上限 sandbox.ASYNC_TIMEOUT_MAX(默认 7200s).
    """
    return await tasks.start_task(cmd, cwd=cwd, timeout=timeout)


@mcp.tool()
async def task_status(task_id: str) -> dict:
    """查任务当前状态. running 时 ps 二次确认."""
    return await tasks.task_status(task_id)


@mcp.tool()
async def task_cancel(task_id: str, force: bool = False) -> dict:
    """取消任务. SIGTERM → 等 5s → SIGKILL(force=True 跳过宽限期)."""
    return await tasks.task_cancel(task_id, force=force)


@mcp.tool()
async def task_output_stream(
    task_id: str,
    stream: str = "stdout",
    offset: int = 0,
    max_bytes: int = sandbox.READ_CHUNK,
) -> dict:
    """拉增量输出. 默认 stdout, 可改 stderr. 拉多次续接 offset."""
    return await tasks.task_output_stream(
        task_id, stream=stream, offset=offset, max_bytes=max_bytes,
    )


if __name__ == "__main__":
    mcp.run()