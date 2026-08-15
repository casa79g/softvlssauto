#!/bin/bash
# ============================================================
# 重新生成 sub.txt（两条链接，URL相同，标签区分用途）
# 用法:
#   bash gen_links.sh                  # 从现有配置读取
#   bash gen_links.sh <新优选域名>     # 手动指定优选域名
# ============================================================
set -euo pipefail

SB_DIR="/etc/sing-box"
SUB_FILE="/root/sub.txt"
[ ! -f "$SB_DIR/sb.json" ] && { echo "[ERROR] sing-box 未安装，请先运行 install.sh"; exit 1; }

# 从 sb.json 读取参数
UUID=$(python3 -c "import json; c=json.load(open('$SB_DIR/sb.json')); print(c['inbounds'][0]['users'][0]['uuid'])" 2>/dev/null)
WS_PATH=$(python3 -c "import json; c=json.load(open('$SB_DIR/sb.json')); print(c['inbounds'][0]['transport']['path'])" 2>/dev/null)

# 从 cf-tunnel.conf 读取 CF_HOST
CF_HOST=$(grep CF_HOST /root/cf-tunnel.conf | cut -d'"' -f2 2>/dev/null)
[ -z "$CF_HOST" ] && { echo "[ERROR] 无法读取 CF_HOST"; exit 1; }

# 优选域名（默认用 CF_HOST，可手动指定）
PREF_DOMAIN="${1:-$CF_HOST}"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")

VLESS_URL="vless://${UUID}@${PREF_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${PREF_DOMAIN}&path=${WS_PATH}&sni=${PREF_DOMAIN}&fp=chrome"
VLESS_LINK1="${VLESS_URL}#配置一-无分片"
VLESS_LINK2="${VLESS_URL}#配置二-分片"

cat > "$SUB_FILE" << SUBEOF
========================================
  网络学习节点 - 自动生成 $(date '+%Y-%m-%d %H:%M:%S')
  隧道: $(grep TUNNEL_NAME /root/cf-tunnel.conf | cut -d'"' -f2 2>/dev/null) | CF域名: $CF_HOST
  VPS:  $PUBLIC_IP
========================================

【配置一】VLESS + WS（无分片，直接粘贴使用）
  地址:  $PREF_DOMAIN
  端口:  443
  协议:  VLESS
  UUID:  $UUID
  传输:  WebSocket
  Host:  $PREF_DOMAIN
  SNI:   $PREF_DOMAIN
  路径:  $WS_PATH
  TLS:   true
  指纹:  chrome
  分片:  无

--- 分享链接（V2RayN / Karing 直接粘贴）---
$VLESS_LINK1

========================================

【配置二】VLESS + WS（需开启 Fragment 分片）
  地址:  $PREF_DOMAIN
  端口:  443
  协议:  VLESS
  UUID:  $UUID
  传输:  WebSocket
  Host:  $PREF_DOMAIN
  SNI:   $PREF_DOMAIN
  路径:  $WS_PATH
  TLS:   true
  指纹:  chrome
  分片:  tlshello 100-200 / 10-20ms
          ← 在V2RayN此节点高级设置中开启Fragment

--- 分享链接（V2RayN / Karing 直接粘贴）---
$VLESS_LINK2

--- 后续操作 ---
  查询节点信息:  cat /root/sub.txt
  换优选域名:    bash gen_links.sh <新域名>

========================================
SUBEOF

chmod 600 "$SUB_FILE"
echo "[OK] sub.txt 已更新"
cat "$SUB_FILE"