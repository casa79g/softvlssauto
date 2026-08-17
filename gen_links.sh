#!/bin/bash
# gen_links.sh — 切换 CF 优选域名（v3.0，支持 VMess）
# 用法: bash gen_links.sh <新优选域名>
# 示例: bash gen_links.sh cf.godns.cc
set -o pipefail

error() { echo "ERROR: $1" >&2; exit 1; }

[ $# -lt 1 ] && { echo "用法: bash gen_links.sh <新优选域名>"; echo "示例: bash gen_links.sh cf.godns.cc"; exit 1; }
NEW_DOMAIN="$1"
SUB_FILE="/root/sub.txt"
ECOSYS="/root/cf-tunnel-ecosystem.json"

[ -f "$ECOSYS" ] || error "未找到 $ECOSYS，请先运行 install.sh 部署"
[ -f "$SUB_FILE" ] || error "未找到 $SUB_FILE，请先运行 install.sh 部署"

# 从 sub.txt 读取配置
CF_HOST=$(grep "^  Host/SNI:" "$SUB_FILE" | head -1 | sed 's/^  Host\/SNI: *//')
WS_PATH=$(grep "^  路径:" "$SUB_FILE" | head -1 | sed 's/^  路径: *//')
UUID=$(grep "^  UUID:" "$SUB_FILE" | head -1 | sed 's/^  UUID: *//')

[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)
[ -z "$CF_HOST" ] && CF_HOST="cf-tunnel.example.com"
[ -z "$WS_PATH" ] && WS_PATH="/proxy-default"

# 从 sub.txt 读取 VMess 路径（如果存在）
VMESS_PATH=$(grep "VMess" "$SUB_FILE" -A20 | grep "路径:" | head -1 | sed 's/^  路径: *//')
[ -z "$VMESS_PATH" ] && VMESS_PATH="/vmess-f229df"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")

# ── VLESS 分享链接 ──
VLESS_REAL="vless://${UUID}@${CF_HOST}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"
VLESS_PREF="vless://${UUID}@${NEW_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"

# ── VMess 分享链接（base64） ──
VMESS_REAL_JSON=$(cat << VJSON
{
  "v": "2",
  "ps": "真实域名-VMess",
  "add": "${CF_HOST}",
  "port": "443",
  "type": "ws",
  "id": "${UUID}",
  "aid": "0",
  "net": "ws",
  "host": "${CF_HOST}",
  "path": "${VMESS_PATH}",
  "tls": "tls",
  "sni": "${CF_HOST}",
  "fp": "chrome"
}
VJSON
)
VMESS_PREF_JSON=$(echo "$VMESS_REAL_JSON" | sed "s|真实域名-VMess|${NEW_DOMAIN}-VMess|; s|\"add\": \"${CF_HOST}\"|\"add\": \"${NEW_DOMAIN}\"|")

VMESS_PREF_B64=$(printf '%s' "$VMESS_PREF_JSON" | base64 -w0 2>/dev/null || printf '%s' "$VMESS_PREF_JSON" | base64 | tr -d '\n')
VMESS_REAL_B64=$(printf '%s' "$VMESS_REAL_JSON" | base64 -w0 2>/dev/null || printf '%s' "$VMESS_REAL_JSON" | base64 | tr -d '\n')

cat > "$SUB_FILE" << EOF
========================================
  网络学习节点 v4.0（优选域名已更新）
  生成: $(date '+%Y-%m-%d %H:%M:%S')
  优选域名: $NEW_DOMAIN | VPS: $PUBLIC_IP
========================================

【推荐配置】VMess + WS — 优选域名（主推，稳定性最好）
  地址:  $NEW_DOMAIN
  端口:  443
  协议:  VMess
  UUID:  $UUID
  AlterID: 0
  传输:  WebSocket
  Host/SNI: $CF_HOST
  路径:  $VMESS_PATH
  TLS:   true
  指纹:  chrome
  分片(Fragment): 包长 100-200，间隔 10-20ms（客户端手动开启）

  分享链接:
  vmess://${VMESS_PREF_B64}#优选域名-VMess

【备选配置一】VLESS + WS — 优选域名（分片优化）
  与推荐配置区别：协议不同，地址同为优选域名
  地址:  $NEW_DOMAIN
  Host/SNI: 保持 $CF_HOST 不变
  分片(Fragment): 包长 100-200，间隔 10-20ms

  分享链接:
  $VLESS_PREF#优选域名-VLESS-分片

【备选配置二】VLESS + WS — 真实隧道域名（连通测试用）
  地址:  $CF_HOST
  用途:  TLS 握手必通，用于验证隧道连通性

  分享链接:
  $VLESS_REAL#真实域名-VLESS-连通测试

========================================
EOF

echo "已切换到: $NEW_DOMAIN"
echo ""
echo "VMess 分享链接（优选域名）:"
echo "vmess://${VMESS_PREF_B64}#优选域名-VMess"
echo ""
echo "VLESS 分享链接（优选域名）:"
echo "$VLESS_PREF#优选域名-VLESS-分片"
echo ""
echo "VLESS 分享链接（真实域名）:"
echo "$VLESS_REAL#真实域名-VLESS-连通测试"
echo ""
echo "提示：优选域名选择离客户端本地近的服务商，不是离 VPS 近的。"
echo "建议先用真实域名链接测试连通性，再试优选域名。"
