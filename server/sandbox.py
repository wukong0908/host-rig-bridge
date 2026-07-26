"""sandbox.py — 沙箱 + 白名单 + env 净化(单一真相源).

所有路径校验、argv 校验、文件 IO、env 设置都走这里.
任何文件 IO 工具(read/write/delete/mkdir/list)必须用本模块的 safe_* 函数,
不能 inline os.open / os.unlink / os.makedirs / os.listdir.
"""
from __future__ import annotations

import os
import shlex
import asyncio
import hashlib
import json
import time
from pathlib import Path

# ===== 配置 (单一真相源) =====
SANDBOX = os.environ.get("HRB_SANDBOX", "C:/Users/mcp-rig/projects")
LOG_PATH = os.environ.get("HRB_LOG_PATH", "C:/Users/mcp-rig/mcp-server/access.log")

# 白名单: 仅可执行文件绝对路径(防 PATH 劫持).
# Windows 外机: OpenSSH 把路径转成 /c/.../...exe 或 C:\\...\\...exe, 两种都收.
# .exe 后缀走 basename 校验后允许.
# 注意: ls 不在白名单 — 列目录走 list_dir(), 不在 run_command 暴露.
WHITELIST = {
    "iverilog": os.environ.get("HRB_IVERILOG", "C:/iverilog/bin/iverilog.exe"),
    "iverilog.exe": os.environ.get("HRB_IVERILOG", "C:/iverilog/bin/iverilog.exe"),
    "vvp": os.environ.get("HRB_VVP", "C:/iverilog/bin/vvp.exe"),
    "vvp.exe": os.environ.get("HRB_VVP", "C:/iverilog/bin/vvp.exe"),
    "quartus_sh": os.environ.get("HRB_QUARTUS_SH", "C:/altera/quartus/bin64/quartus_sh.exe"),  # TODO: 按外机 datasheet/实测
    "quartus_sh.exe": os.environ.get("HRB_QUARTUS_SH", "C:/altera/quartus/bin64/quartus_sh.exe"),
    "openFPGALoader": os.environ.get("HRB_OPENFPGALOADER", "C:/openFPGALoader/openFPGALoader.exe"),
    "openFPGALoader.exe": os.environ.get("HRB_OPENFPGALOADER", "C:/openFPGALoader/openFPGALoader.exe"),
}

# 净化 env: 仅注入必要变量, 阻 LD_PRELOAD / PYTHONPATH / LD_LIBRARY_PATH.
# Windows 下 PYTHONPATH 也是注入攻击面, 一并删.
# USERPROFILE/TEMP 用系统变量不要硬编 (不同用户名 / 系统盘不同会错)
SANE_ENV = {
    "PATH": os.environ.get("HRB_PATH", "C:/Windows/System32;C:/Windows;C:/iverilog/bin;C:/altera/quartus/bin64;C:/openFPGALoader"),
    "SYSTEMROOT": os.environ.get("SYSTEMROOT", "C:/Windows"),
    "USERPROFILE": os.environ.get("USERPROFILE", "C:/Users/mcp-rig"),
    "TEMP": os.environ.get("TEMP", "C:/Users/mcp-rig/AppData/Local/Temp"),
    # Windows 子进程 (iverilog / quartus_sh) 多为 native Win32, 不读 POSIX locale.
    # 设 C.UTF-8 反致一些工具拒启. 留空 (Windows 默认 codepage).
    # TODO: quartus_sh 需要 QUARTUS_ROOTDIR / LM_LICENSE_FILE,
    #       需主人提供外机实测路径(CLAUDE.md 硬规则: datasheet/实测来源).
}

STDOUT_CAP = 64 * 1024           # 单 message ≤ 64KB, 防 framing 阻塞
READ_CHUNK = 64 * 1024           # read_file 默认分块
WRITE_CAP = 1 * 1024 * 1024     # write_file 上限 1MB
SYNC_TIMEOUT_MAX = 1800         # run_command timeout 上限(秒)
ASYNC_TIMEOUT_MAX = int(os.environ.get("HRB_ASYNC_TIMEOUT_MAX", "7200"))  # 2h 默认

# 并发池大小: 同步 8 / 异步 4 隔离, 防长跑任务饿死同步.
SYNC_SEMA_SIZE = 8
ASYNC_SEMA_SIZE = 4

# 惰性创建的并发池(放本模块, server.py / tasks.py 各自惰性 init).
_sema_sync: asyncio.Semaphore | None = None
_sema_async: asyncio.Semaphore | None = None


def get_sync_sema() -> asyncio.Semaphore:
    """惰性创建同步池. 首次调用绑当前 event loop.

    ⚠️ WARNING: 单 loop 绑定. MCP 改 SSE 或多 loop 部署会 RuntimeError.
       当前 stdio over SSH 单 loop 场景 OK. 多 loop 时改 sync 入口一次性创建.
    """
    global _sema_sync
    if _sema_sync is None:
        _sema_sync = asyncio.Semaphore(SYNC_SEMA_SIZE)
    return _sema_sync


def get_async_sema() -> asyncio.Semaphore:
    """惰性创建异步池. 首次调用绑当前 event loop. 同 get_sync_sema 警告."""
    global _sema_async
    if _sema_async is None:
        _sema_async = asyncio.Semaphore(ASYNC_SEMA_SIZE)
    return _sema_async


# ===== 路径校验 =====
def in_sandbox(path: str) -> bool:
    """检查路径在沙箱内. 防前缀匹配绕过(C:/Users/mcp-rig/projects_evil)."""
    try:
        real = os.path.realpath(path)
        base = os.path.realpath(SANDBOX)
        if real == base:
            return True
        rel = os.path.relpath(real, base)
        return not (rel == ".." or rel.startswith(".." + os.sep))
    except (OSError, ValueError):
        return False


def safe_open(path: str, mode: str):
    """O_NOFOLLOW 开文件, fd 拿到后再校验 realpath 仍在沙箱内.

    mode: "r" / "w"(O_TRUNC 写) / "a"(append) / "x"(O_EXCL 独占创建).
    O_NOFOLLOW 拒软链, fd realpath 兜底 TOCTOU.
    Windows 无 /proc/self/fd, 改用 os.path.realpath 直接验 (fd 已 O_NOFOLLOW 拒软链).
    """
    flags = os.O_NOFOLLOW
    if "r" in mode and "w" not in mode and "a" not in mode and "x" not in mode:
        flags |= os.O_RDONLY
    elif "x" in mode:
        flags |= os.O_WRONLY | os.O_CREAT | os.O_EXCL
    elif "a" in mode:
        flags |= os.O_WRONLY | os.O_CREAT | os.O_APPEND
    else:
        flags |= os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    mode_perm = 0o644
    if "x" in mode:
        mode_perm = 0o644
    fd = os.open(path, flags, mode_perm)
    try:
        real = os.path.realpath(path)
        if not in_sandbox(real):
            os.close(fd)
            raise PermissionError(f"path escapes sandbox: {real}")
    except Exception:
        os.close(fd)
        raise
    return os.fdopen(fd, mode)


def safe_unlink(path: str) -> None:
    """删文件. 沙箱内, 拒删沙箱根. 不走 fd-level 防护(主人电脑场景).

    TODO: 中间目录 symlink 防护需 *at() 系列 — 主人电脑场景暂不做.
    """
    if not in_sandbox(path):
        raise PermissionError("path escapes sandbox")
    if os.path.realpath(path) == os.path.realpath(SANDBOX):
        raise PermissionError("refuse to delete sandbox root")
    os.unlink(path)


def safe_mkdir(path: str) -> None:
    """建目录(含中间). 沙箱内. 不走 fd-level 防护(主人电脑场景).

    TODO: 中间目录 symlink 防护需 O_NOFOLLOW|O_DIRECTORY 父目录打开后 mkdirat.
    """
    if not in_sandbox(path):
        raise PermissionError("path escapes sandbox")
    os.makedirs(path, exist_ok=True)


def safe_listdir(path: str) -> list[str]:
    """列目录. 沙箱内. 跟 base 本身的 symlink(用 in_sandbox 拒)."""
    base = SANDBOX if path == "." else path
    if not in_sandbox(base):
        raise PermissionError("path escapes sandbox")
    return sorted(os.listdir(base))


# ===== argv 校验 (供 run_command + start_task 复用) =====
def validate_argv(cmd: str) -> list[str]:
    """shlex.split + argv[0] 二次校验 + 替换绝对路径. 供同步/异步共享.

    ⚠️ WARNING: 仅校验 argv[0] 名称, argv[1:] 的路径参数不校验.
       白名单二进制自身的参数可逃逸沙箱:
       - iverilog -o C:/Windows/System32/evil   (写沙箱外)
       - quartus_sh -t C:/Users/admin/evil.tcl  (任意 Tcl 执行)
       - vvp -M /path/to/plugin                  (插件路径)
       主人电脑单用户场景下风险可接受, 部署到多用户机需加 bwrap/seccomp/argv 子命令白名单.

    返回: 已替换 argv[0] 为绝对路径的列表.
    抛: ValueError(empty cmd) / PermissionError(不在白名单).
    """
    argv = shlex.split(cmd)
    if not argv:
        raise ValueError("empty command")
    head = os.path.basename(argv[0])
    # Windows: OpenSSH 收到 "iverilog" / "iverilog.exe" / "C:/iverilog/bin/iverilog.exe" 都行
    head_exe = head if head.lower().endswith(".exe") else head + ".exe"
    if head in WHITELIST:
        argv[0] = WHITELIST[head]
    elif head_exe in WHITELIST:
        argv[0] = WHITELIST[head_exe]
    else:
        raise PermissionError(f"command not allowed: {head}")
    return argv


def validate_cwd(cwd: str | None) -> str:
    """校验 cwd 在沙箱内, 返回绝对路径.

    None -> 返回 SANDBOX 根.
    """
    work = SANDBOX if cwd is None else cwd
    if not in_sandbox(work):
        raise PermissionError("cwd escapes sandbox")
    return work


# ===== 审计 (本模块暴露工具, 实现在 audit.py) =====
# 这里仅占位, 实际 audit 函数在 audit.py 避免循环依赖.
# server.py / tasks.py 各自 import audit 后调 audit.audit(...).
__all__ = [
    "SANDBOX", "LOG_PATH", "WHITELIST", "SANE_ENV",
    "STDOUT_CAP", "READ_CHUNK", "WRITE_CAP",
    "SYNC_TIMEOUT_MAX", "ASYNC_TIMEOUT_MAX",
    "get_sync_sema", "get_async_sema",
    "in_sandbox", "safe_open", "safe_unlink", "safe_mkdir", "safe_listdir",
    "validate_argv", "validate_cwd",
]