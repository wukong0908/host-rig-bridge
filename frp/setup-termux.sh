#!/usr/bin/env bash
# setup-termux.sh — 手机 Termux 端配置
# 用法: 在 Termux 跑 bash setup-termux.sh

set -euo pipefail

echo "[1/4] 装 openssh"
pkg install -y openssh

mkdir -p ~/.ssh
chmod 700 ~/.ssh

echo "[2/4] 生成 ed25519 key"
if [[ ! -f ~/.ssh/home_claude_termux ]]; then
    ssh-keygen -t ed25519 -f ~/.ssh/home_claude_termux -N "" -C "termux@claude-mcp"
fi

echo "[3/4] ~/.ssh/config (Termux 端)"
cat >> ~/.ssh/config <<'EOF'

# host-rig-bridge (Termux)
Host home
  HostName 8.163.106.31
  Port 6000
  User WuKong
  IdentityFile ~/.ssh/home_claude_termux
  IdentitiesOnly yes
  ServerAliveInterval 30
  ServerAliveCountMax 6
  StrictHostKeyChecking accept-new
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
EOF

echo "[4/4] 输出公钥, 发给主机主人粘到 administrators_authorized_keys"
echo "---- Termux 公钥 BEGIN ----"
cat ~/.ssh/home_claude_termux.pub
echo "---- Termux 公钥 END ----"

cat <<EOF

========================================
✅ Termux 配置完成.

下一步:
  1. 把上面的公钥 (ssh-ed25519 ...) 发给主机主人.
  2. 主机主人粘到 C:\\ProgramData\\ssh\\administrators_authorized_keys
     (注意: icacls /inheritance:r /grant SYSTEM:F /grant BUILTIN\\Administrators:F)
  3. Termux 端验握手:
       ssh -o StrictHostKeyChecking=accept-new home
  4. 跑 Claude Code:
       ssh home
       claude

EOF