#!/usr/bin/env bash
# uninstall-rig.sh — 外机反操作: 删账号 + 沙箱 + server 目录
# 用法: sudo bash uninstall-rig.sh
set -euo pipefail

RIG_USER="${RIG_USER:-mcp-rig}"

echo "⚠️  即将删除 ${RIG_USER} 账号 + /home/${RIG_USER}/ 全部内容"
echo "   包括: mcp-server/ (server.py + venv + tasks.db)"
echo "         projects/ (沙箱)"
echo "         .ssh/ (authorized_keys)"
read -p "确认? 输入 YES 继续: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "已取消"
    exit 0
fi

if id "${RIG_USER}" &>/dev/null; then
    userdel -r "${RIG_USER}"
    echo "✅ 账号 ${RIG_USER} 已删 (含 /home/${RIG_USER}/)"
else
    echo "账号 ${RIG_USER} 不存在, 跳过"
fi