#!/usr/bin/env bash
# install.sh — 外机一键安装
# 用法: curl -fsSL https://raw.githubusercontent.com/wukong0908/host-rig-bridge/main/scripts/install.sh | bash -s -- --user mcp-rig
#
# 行为:
#   1. 建 nologin 账号 (默认 mcp-rig)
#   2. git clone 拉代码到 /home/<user>/mcp-server/
#   3. 建 venv + 装 mcp[server] + 复制 server 模块
#   4. 建沙箱 /home/<user>/projects/
#   5. 不写 authorized_keys (需主机公钥, 留给 register-rig.ps1 提示)
#   6. 不注册 systemd (走 SSH forced command, 无需常驻)
set -euo pipefail

REPO="${REPO:-wukong0908/host-rig-bridge}"
BRANCH="${BRANCH:-main}"
USER_NAME="mcp-rig"
SANDBOX_BASE=""
SERVER_DIR=""

usage() {
    cat <<EOF
用法: $0 [选项]

  --user NAME        分机账号名 (默认 mcp-rig)
  --repo OWNER/REPO  GitHub 仓 (默认 wukong0908/host-rig-bridge)
  --branch BRANCH    Git 分支 (默认 main)
  -h, --help         显示本帮助
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) USER_NAME="$2"; shift 2 ;;
        --repo) REPO="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知选项: $1"; usage; exit 1 ;;
    esac
done

if [[ "$USER_NAME" == "root" ]]; then
    echo "❌ 不能用 root 作为分机账号"; exit 1
fi

SERVER_DIR="/home/${USER_NAME}/mcp-server"
SANDBOX_BASE="/home/${USER_NAME}/projects"

echo "[1/6] 检查 / 建账号 ${USER_NAME} (nologin)"
if id "${USER_NAME}" &>/dev/null; then
    echo "    账号已存在, 跳过"
else
    useradd -m -s /usr/sbin/nologin "${USER_NAME}"
fi

echo "[2/6] 建 server 目录"
mkdir -p "${SERVER_DIR}"
chown -R "${USER_NAME}:${USER_NAME}" "${SERVER_DIR}"

echo "[3/6] git clone 拉代码 (depth 1, ${BRANCH})"
TMP_DIR=$(mktemp -d)
trap "rm -rf ${TMP_DIR}" EXIT
sudo -u "${USER_NAME}" git clone \
    --depth 1 --branch "${BRANCH}" \
    "https://github.com/${REPO}.git" "${TMP_DIR}/hrb"

echo "[4/6] 复制 server 模块 + 建 venv + 装依赖"
cp -r "${TMP_DIR}/hrb/server/." "${SERVER_DIR}/"
chown -R "${USER_NAME}:${USER_NAME}" "${SERVER_DIR}"

# 复制 pyproject 用于 pip install
cp "${TMP_DIR}/hrb/server/pyproject.toml" "${SERVER_DIR}/pyproject.toml"
chown "${USER_NAME}:${USER_NAME}" "${SERVER_DIR}/pyproject.toml"

sudo -u "${USER_NAME}" python3 -m venv "${SERVER_DIR}/.venv"
sudo -u "${USER_NAME}" "${SERVER_DIR}/.venv/bin/pip" install --upgrade pip
sudo -u "${USER_NAME}" "${SERVER_DIR}/.venv/bin/pip" install "${SERVER_DIR}"

echo "[5/6] 建沙箱目录"
mkdir -p "${SANDBOX_BASE}"
chown -R "${USER_NAME}:${USER_NAME}" "${SANDBOX_BASE}"

echo "[6/6] 准备 .ssh 目录"
sudo -u "${USER_NAME}" mkdir -p "/home/${USER_NAME}/.ssh"
sudo -u "${USER_NAME}" chmod 700 "/home/${USER_NAME}/.ssh"

# 验证 SDK 可导入
sudo -u "${USER_NAME}" "${SERVER_DIR}/.venv/bin/python" -c \
    "from mcp.server.fastmcp import FastMCP; print('mcp SDK OK')"

cat <<EOF

========================================
✅ 外机 ${USER_NAME} 安装完成.

下一步:
  1. 在主机生成 SSH key (若尚未有):
       ssh-keygen -t ed25519 -f ~/.ssh/id_claude_mcp -N ""
  2. 把主机公钥贴到外机 authorized_keys (一行, 带 forced command):
       command="${SERVER_DIR}/.venv/bin/python -u ${SERVER_DIR}/server.py",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-ed25519 AAAA...

     外机 root 跑:
       sudo -u ${USER_NAME} tee -a /home/${USER_NAME}/.ssh/authorized_keys
       (粘贴上面那行, Ctrl+D 结束)

  3. 主机首次 SSH 验握手:
       ssh -o StrictHostKeyChecking=accept-new ${USER_NAME}@<rig-host>
  4. 重启主机 Claude Code, /mcp 看 remote-rig connected.

EOF