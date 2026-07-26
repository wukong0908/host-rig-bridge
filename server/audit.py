"""audit.py — 去敏感审计日志.

写 access.log, 失败 fail-fast. 不写原始路径/参数, 只记 hash[:16] + 字节数 + 耗时.
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
from pathlib import Path

from .sandbox import LOG_PATH

# ===== 启动校验: 日志目录必须可写, 否则 fail-fast =====
_log_dir = os.path.dirname(LOG_PATH)
if _log_dir:
    Path(_log_dir).mkdir(parents=True, exist_ok=True)
    if not os.access(_log_dir, os.W_OK):
        raise RuntimeError(f"audit log directory not writable: {_log_dir}")
# 测试文件可创建
try:
    Path(LOG_PATH).touch()
except OSError as e:
    raise RuntimeError(f"audit log file not writable: {LOG_PATH}: {e}") from e

logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("host-rig-bridge")


def audit(
    tool: str,
    args: dict,
    duration_ms: int,
    bytes_in: int,
    bytes_out: int,
    ok: bool,
) -> None:
    """去敏感日志. args 仅用于 hash 化, 不落原始值.

    ok=False 含异常 + 执行失败(超时/被杀/退出码!=0). 主人在告警里看的是这条.
    """
    arg_hash = hashlib.sha256(
        json.dumps(args, sort_keys=True, default=str).encode()
    ).hexdigest()[:16]
    log.info(
        f"tool={tool} hash={arg_hash} dur_ms={duration_ms} "
        f"in={bytes_in} out={bytes_out} ok={ok}"
    )


__all__ = ["audit"]