#!/bin/bash
# ============================================================
# 查询节点信息
# 用法: bash query.sh
# ============================================================
set -euo pipefail

SUB_FILE="/root/sub.txt"

if [ -f "$SUB_FILE" ]; then
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║            网络学习节点信息                               ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  cat "$SUB_FILE"
else
  echo "[ERROR] 未找到 $SUB_FILE，请先运行 install.sh 部署"
  exit 1
fi

echo ""
echo "--- 运行状态 ---"
echo "  sing-box:    $(systemctl is-active sing-box-vless 2>/dev/null || echo 'N/A')"
echo "  cloudflared: $(systemctl is-active cloudflared-tunnel 2>/dev/null || echo 'N/A')"