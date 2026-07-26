"""tasks.py — 异步任务: start_task / task_status / task_cancel / task_output_stream.

四工具共用 sandbox.py 的 argv 校验 + safe_* 防护.
持久化在 tasks_store.py.
并发池与 run_command 隔离(sandbox.get_async_sema).
"""
from __future__ import annotations

import asyncio
import base64
import os
import secrets
import signal
import time
from datetime import datetime, timezone
from hashlib import sha256

from . import audit, sandbox, tasks_store


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _gen_task_id() -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    return f"ts-{ts}-{secrets.token_hex(3)}"


def _safe_update_state(task_id: str, new_state: str, **kwargs) -> None:
    """防 race: 仅在 db 当前 state == 'running' 时才 UPDATE.

    避免 task_cancel 写 'cancelled' 后 _watch_task 退出又写 'exited' 覆盖.
    主人 task_status 看到 'exited' 误判正常退出.
    """
    row = tasks_store.get(task_id)
    if row is None:
        return
    if row["state"] != "running":
        return  # 已被 task_cancel / 其它路径写终态, 跳过
    tasks_store.update_state(task_id, new_state, **kwargs)


# ===== start_task =====
async def start_task(
    cmd: str,
    cwd: str | None = None,
    timeout: int = sandbox.ASYNC_TIMEOUT_MAX,
) -> dict:
    """后台起任务, 立即返 task_id.

    复用 sandbox.validate_argv + validate_cwd, 与 run_command 同套安全约束.
    """
    argv = sandbox.validate_argv(cmd)
    work = sandbox.validate_cwd(cwd)

    if timeout > sandbox.ASYNC_TIMEOUT_MAX:
        raise ValueError(f"timeout > {sandbox.ASYNC_TIMEOUT_MAX}s not allowed")
    if timeout <= 0:
        raise ValueError("timeout must be > 0")

    task_id = _gen_task_id()
    log_dir = os.path.join(tasks_store.TASKS_DIR, task_id)
    os.makedirs(log_dir, exist_ok=True)
    os.chmod(log_dir, 0o700)

    cmd_audit = cmd[:80] + ("..." if len(cmd) > 80 else "")
    cmd_hash = sha256(cmd.encode()).hexdigest()[:16]
    started_at = _now_iso()

    tasks_store.insert(
        task_id=task_id,
        cmd_audit=cmd_audit,
        cmd_hash=cmd_hash,
        cwd=work,
        timeout=timeout,
        log_dir=log_dir,
        started_at=started_at,
    )

    stdout_path = os.path.join(log_dir, "stdout.log")
    stderr_path = os.path.join(log_dir, "stderr.log")

    t0 = time.monotonic()
    bytes_in = len(cmd)
    try:
        # 起子进程, 不等结果
        proc = await asyncio.create_subprocess_exec(
            *argv,
            cwd=work,
            env=sandbox.SANE_ENV,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            limit=sandbox.STDOUT_CAP,
        )
        tasks_store.update_pid(task_id, proc.pid)

        # 后台 watcher: 等进程退出 → UPDATE state
        asyncio.create_task(
            _watch_task(task_id, proc, stdout_path, stderr_path, timeout)
        )

        audit.audit(
            "start_task",
            {"cmd_hash": cmd_hash, "cwd": work, "timeout": timeout},
            int((time.monotonic() - t0) * 1000),
            bytes_in,
            0,
            True,
        )
        return {
            "task_id": task_id,
            "pid": proc.pid,
            "state": "running",
            "started_at": started_at,
            "log_dir": log_dir,
            "cmd_audit": cmd_audit,
        }
    except Exception:
        tasks_store.update_state(task_id, "failed", ended_at=_now_iso())
        audit.audit(
            "start_task",
            {"cmd_hash": cmd_hash},
            int((time.monotonic() - t0) * 1000),
            bytes_in,
            0,
            False,
        )
        raise


async def _watch_task(
    task_id: str,
    proc: asyncio.subprocess.Process,
    stdout_path: str,
    stderr_path: str,
    timeout: int,
) -> None:
    """后台 watcher: 等进程退出, tee stdout/stderr 到 log 文件, UPDATE state."""
    t0 = time.monotonic()
    stdout_f = open(stdout_path, "wb")
    stderr_f = open(stderr_path, "wb")
    stdout_bytes = 0
    stderr_bytes = 0
    try:
        async with sandbox.get_async_sema():
            try:
                # 流式 tee, 不一次收完(防大输出阻塞)
                while True:
                    elapsed = time.monotonic() - t0
                    if elapsed > timeout:
                        proc.kill()
                        await proc.wait()
                        _safe_update_state(
                            task_id, "cancelled", signal="SIGKILL",
                            ended_at=_now_iso(),
                            stdout_bytes=stdout_bytes,
                            stderr_bytes=stderr_bytes,
                        )
                        return
                    try:
                        out_chunk = await asyncio.wait_for(
                            proc.stdout.read(4096), timeout=1.0
                        )
                    except asyncio.TimeoutError:
                        out_chunk = None
                    if out_chunk:
                        stdout_f.write(out_chunk)
                        stdout_f.flush()
                        stdout_bytes += len(out_chunk)
                    try:
                        err_chunk = await asyncio.wait_for(
                            proc.stderr.read(4096), timeout=0.1
                        )
                    except asyncio.TimeoutError:
                        err_chunk = None
                    if err_chunk:
                        stderr_f.write(err_chunk)
                        stderr_f.flush()
                        stderr_bytes += len(err_chunk)
                    if proc.returncode is not None and not out_chunk and not err_chunk:
                        break
                await proc.wait()
            except Exception:
                proc.kill()
                await proc.wait()
                _safe_update_state(
                    task_id, "failed", ended_at=_now_iso(),
                    stdout_bytes=stdout_bytes,
                    stderr_bytes=stderr_bytes,
                )
                return
        _safe_update_state(
            task_id, "exited", rc=proc.returncode,
            ended_at=_now_iso(),
            stdout_bytes=stdout_bytes,
            stderr_bytes=stderr_bytes,
        )
    finally:
        stdout_f.close()
        stderr_f.close()


# ===== task_status =====
async def task_status(task_id: str) -> dict:
    """查任务当前状态. running 时 ps 二次确认."""
    row = tasks_store.get(task_id)
    if row is None:
        raise LookupError(f"task not found: {task_id}")
    state = row["state"]
    pid = row["pid"]
    # 二次确认: 若 db 说是 running 但进程不在, 修正 db
    if state == "running" and pid:
        try:
            os.kill(pid, 0)
        except (OSError, ProcessLookupError):
            # 进程不在了, 修正状态
            tasks_store.update_state(
                task_id, "exited", rc=None,
                ended_at=_now_iso(),
            )
            row = tasks_store.get(task_id)
            state = row["state"] if row else state
    return {
        "task_id": task_id,
        "pid": row["pid"] if row else pid,
        "state": state,
        "rc": row["rc"] if row else None,
        "signal": row["signal"] if row else None,
        "started_at": row["started_at"] if row else None,
        "ended_at": row["ended_at"] if row else None,
        "stdout_bytes": row["stdout_bytes"] if row else 0,
        "stderr_bytes": row["stderr_bytes"] if row else 0,
    }


# ===== task_cancel =====
async def task_cancel(task_id: str, force: bool = False) -> dict:
    """取消任务. SIGTERM → 等 5s → SIGKILL."""
    row = tasks_store.get(task_id)
    if row is None:
        raise LookupError(f"task not found: {task_id}")
    if row["state"] != "running":
        raise RuntimeError(f"task already {row['state']}, cannot cancel")
    pid = row["pid"]
    sig = "SIGKILL" if force else "SIGTERM"
    try:
        os.kill(pid, signal.SIGTERM if not force else signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    if not force:
        # 等 5s 给机会 graceful
        for _ in range(5):
            try:
                os.kill(pid, 0)
            except (OSError, ProcessLookupError):
                break
            await asyncio.sleep(1)
        else:
            try:
                os.kill(pid, signal.SIGKILL)
                sig = "SIGKILL"
            except (OSError, ProcessLookupError):
                pass
    tasks_store.update_state(
        task_id, "cancelled", signal=sig, ended_at=_now_iso(),
    )
    audit.audit(
        "task_cancel",
        {"task_id_hash": sha256(task_id.encode()).hexdigest()[:16],
         "force": force},
        0, 0, 0, True,
    )
    return {
        "task_id": task_id,
        "state": "cancelled",
        "signal": sig,
        "cancelled_at": _now_iso(),
    }


# ===== task_output_stream =====
async def task_output_stream(
    task_id: str,
    stream: str = "stdout",       # "stdout" | "stderr"
    offset: int = 0,
    max_bytes: int = sandbox.READ_CHUNK,
) -> dict:
    """拉增量输出. 默认 stdout, 可改 stderr. 拉多次续接 offset.

    max_bytes 上限 sandbox.READ_CHUNK(64KB). base64 编码后 wire ~85KB.
    若 len(chunk) == max_bytes, 表示可能还有更多, 客户端续 read 拿后续.
    """
    if max_bytes <= 0 or max_bytes > sandbox.READ_CHUNK:
        raise ValueError(f"max_bytes must be 0 < max_bytes <= {sandbox.READ_CHUNK}")
    row = tasks_store.get(task_id)
    if row is None:
        raise LookupError(f"task not found: {task_id}")
    if stream not in ("stdout", "stderr"):
        raise ValueError("stream must be 'stdout' or 'stderr'")
    log_path = os.path.join(row["log_dir"], f"{stream}.log")
    if not os.path.exists(log_path):
        return {
            "task_id": task_id,
            "offset": offset,
            "chunk": "",
            "truncated": False,
            "state": row["state"],
            "eof": row["state"] != "running",
            "bytes_remaining": None,
        }
    fd = os.open(log_path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.lseek(fd, offset, os.SEEK_SET)
        chunk = os.read(fd, max_bytes)
        new_offset = offset + len(chunk)
        truncated = len(chunk) == max_bytes
        eof = row["state"] != "running" and not truncated
        return {
            "task_id": task_id,
            "offset": new_offset,
            "chunk": base64.b64encode(chunk).decode() if chunk else "",
            "truncated": truncated,
            "state": row["state"],
            "eof": eof,
            "bytes_remaining": os.fstat(fd).st_size - new_offset if not eof else 0,
        }
    finally:
        os.close(fd)


__all__ = [
    "start_task", "task_status", "task_cancel", "task_output_stream",
]