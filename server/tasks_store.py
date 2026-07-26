"""tasks_store.py — 异步任务 sqlite 持久化.

单文件 /home/mcp-rig/mcp-server/tasks.db, mode 0600.
server 重启不丢任务, 可手工 sqlite3 查.
"""
from __future__ import annotations

import os
import sqlite3
from pathlib import Path

DB_PATH = os.environ.get(
    "HRB_TASKS_DB", "/home/mcp-rig/mcp-server/tasks.db"
)
TASKS_DIR = os.environ.get(
    "HRB_TASKS_DIR", "/home/mcp-rig/mcp-server/tasks"
)


_SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    task_id      TEXT PRIMARY KEY,
    cmd_audit    TEXT NOT NULL,
    cmd_hash     TEXT NOT NULL,
    cwd          TEXT,
    pid          INTEGER,
    state        TEXT NOT NULL,
    rc           INTEGER,
    signal       TEXT,
    started_at   TEXT NOT NULL,
    ended_at     TEXT,
    timeout      INTEGER NOT NULL,
    log_dir      TEXT NOT NULL,
    stdout_bytes INTEGER DEFAULT 0,
    stderr_bytes INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tasks_state ON tasks(state);
CREATE INDEX IF NOT EXISTS idx_tasks_started_at ON tasks(started_at DESC);
"""


def init_db() -> None:
    """启动时 init. 文件 mode 0600, 目录可写校验."""
    db_dir = os.path.dirname(DB_PATH)
    if db_dir:
        Path(db_dir).mkdir(parents=True, exist_ok=True)
        if not os.access(db_dir, os.W_OK):
            raise RuntimeError(f"tasks db dir not writable: {db_dir}")
    # mode 0600
    conn = sqlite3.connect(DB_PATH)
    try:
        os.chmod(DB_PATH, 0o600)
        conn.executescript(_SCHEMA)
        conn.commit()
    finally:
        conn.close()


def get_conn() -> sqlite3.Connection:
    """每次调用返新 connection. row_factory=Row 方便按列访问."""
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    return conn


def insert(
    task_id: str,
    cmd_audit: str,
    cmd_hash: str,
    cwd: str | None,
    timeout: int,
    log_dir: str,
    started_at: str,
) -> None:
    conn = get_conn()
    try:
        conn.execute(
            "INSERT INTO tasks (task_id, cmd_audit, cmd_hash, cwd, pid, state, "
            "timeout, log_dir, started_at) "
            "VALUES (?, ?, ?, ?, NULL, 'running', ?, ?, ?)",
            (task_id, cmd_audit, cmd_hash, cwd, timeout, log_dir, started_at),
        )
        conn.commit()
    finally:
        conn.close()


def update_pid(task_id: str, pid: int) -> None:
    conn = get_conn()
    try:
        conn.execute("UPDATE tasks SET pid = ? WHERE task_id = ?", (pid, task_id))
        conn.commit()
    finally:
        conn.close()


def update_state(
    task_id: str,
    state: str,
    rc: int | None = None,
    signal: str | None = None,
    ended_at: str | None = None,
    stdout_bytes: int | None = None,
    stderr_bytes: int | None = None,
) -> None:
    fields = ["state = ?"]
    values: list = [state]
    if rc is not None:
        fields.append("rc = ?")
        values.append(rc)
    if signal is not None:
        fields.append("signal = ?")
        values.append(signal)
    if ended_at is not None:
        fields.append("ended_at = ?")
        values.append(ended_at)
    if stdout_bytes is not None:
        fields.append("stdout_bytes = ?")
        values.append(stdout_bytes)
    if stderr_bytes is not None:
        fields.append("stderr_bytes = ?")
        values.append(stderr_bytes)
    values.append(task_id)
    conn = get_conn()
    try:
        conn.execute(f"UPDATE tasks SET {', '.join(fields)} WHERE task_id = ?", values)
        conn.commit()
    finally:
        conn.close()


def get(task_id: str) -> sqlite3.Row | None:
    conn = get_conn()
    try:
        return conn.execute(
            "SELECT * FROM tasks WHERE task_id = ?", (task_id,)
        ).fetchone()
    finally:
        conn.close()


__all__ = [
    "DB_PATH", "TASKS_DIR", "init_db", "get_conn",
    "insert", "update_pid", "update_state", "get",
]