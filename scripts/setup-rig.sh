#!/usr/bin/env bash
# setup-rig.sh — DEPRECATED, 推荐用 install.sh
# ┌────────────────────────────────────────────────────────┐
# │ ⚠️  本脚本为旧用法兼容入口, 新部署请走 install.sh:        │
# │                                                        │
# │   curl -fsSL https://raw.githubusercontent.com/ \      │
# │       wukong0908/host-rig-bridge/main/scripts/install.sh│
# │       | bash -s -- --user mcp-rig                       │
# │                                                        │
# │ 与 install.sh 区别: 本脚本期望 server.py 已通过 scp    │
# │ 传过来 (/tmp/server.py), 不走 git clone.                │
# │ 保留为旧用法兼容入口, 后续 Phase E 会删除.               │
# └────────────────────────────────────────────────────────┘
set -euo pipefail

echo "⚠️  setup-rig.sh DEPRECATED. 推荐用 install.sh:"
echo "    curl -fsSL https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install.sh | bash -s -- --user mcp-rig"
echo ""

RIG_USER="${RIG_USER:-mcp-rig}"
SERVER_DIR="/home/${RIG_USER}/mcp-server"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REPO="${REPO:-wukong0908/host-rig-bridge}"
BRANCH="${BRANCH:-main}"

echo "[1/6] 建账号 ${RIG_USER} (nologin)"
if ! id "${RIG_USER}" &>/dev/null; then
    useradd -m -s /usr/sbin/nologin "${RIG_USER}"
else
    echo "    账号已存在, 跳过"
fi

echo "[2/6] 建 server 目录 + 拷 server.py"
mkdir -p "${SERVER_DIR}"
chown -R "${RIG_USER}:${RIG_USER}" "${SERVER_DIR}"

if [[ ! -f /tmp/server.py ]]; then
    echo "❌ /tmp/server.py 不存在. 两条路:"
    echo "   A. 主机 scp: scp server.py rig:/tmp/server.py (旧用法)"
    echo "   B. 推荐 install.sh: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | bash -s -- --user ${RIG_USER}"
    exit 1
fi
cp /tmp/server.py "${SERVER_DIR}/server.py"
chown "${RIG_USER}:${RIG_USER}" "${SERVER_DIR}/server.py"
chmod 644 "${SERVER_DIR}/server.py"

echo "[3/6] 建 venv + 装 mcp SDK"
sudo -u "${RIG_USER}" "${PYTHON_BIN}" -m venv "${SERVER_DIR}/.venv"
sudo -u "${RIG_USER}" "${SERVER_DIR}/.venv/bin/pip" install --upgrade pip
sudo -u "${RIG_USER}" "${SERVER_DIR}/.venv/bin/pip" install "mcp[server]>=1.0,<2.0"

echo "[4/6] 建沙箱目录"
SANDBOX="/home/${RIG_USER}/projects"
mkdir -p "${SANDBOX}"
chown -R "${RIG_USER}:${RIG_USER}" "${SANDBOX}"

echo "[5/6] 准备 .ssh 目录"
sudo -u "${RIG_USER}" mkdir -p "/home/${RIG_USER}/.ssh"
sudo -u "${RIG_USER}" chmod 700 "/home/${RIG_USER}/.ssh"

echo "[6/6] 验证 mcp SDK 可导入"
sudo -u "${RIG_USER}" "${SERVER_DIR}/.venv/bin/python" -c \
    "from mcp.server.fastmcp import FastMCP; print('mcp SDK OK')"

cat <<EOF

========================================
✅ 外机 setup 完成 (兼容模式).

下一步:
  1. 主机: ssh-keygen -t ed25519 -f ~/.ssh/id_claude_mcp -N "" (若尚未有)
  2. 把主机公钥写到外机:
     sudo -u ${RIG_USER} tee -a /home/${RIG_USER}/.ssh/authorized_keys
     整行格式 (一行):
       command="${SERVER_DIR}/.venv/bin/python -u ${SERVER_DIR}/server.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...
     把 ssh-ed25519 替换为主机真实公钥.

EOF