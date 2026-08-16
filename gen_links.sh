#!/bin/bash
# gen_links.sh — 切换 CF 优选域名（v2.1 适配）
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

# 从 sub.txt 读取配置（匹配实际格式 "  Key:  Value"）
CF_HOST=$(grep "^  Host:" "$SUB_FILE" | head -1 | sed 's/^  Host: *//')
WS_PATH=$(grep "^  路径:" "$SUB_FILE" | head -1 | sed 's/^  路径: *//')
UUID=$(grep "^  UUID:" "$SUB_FILE" | head -1 | sed 's/^  UUID: *//')

# 兜底：如果解析失败，尝试从 ecosystem.json 或生成新值
[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)
[ -z "$CF_HOST" ] && CF_HOST="cf-tunnel.example.com"
[ -z "$WS_PATH" ] && WS_PATH="/proxy-default"

# 重新生成 sub.txt
VLESS_URL="vless://${UUID}@${NEW_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")

cat > "$SUB_FILE" << EOF
========================================
  VLESS Tunnel Deploy Toolkit v2.1（优选域名已更新）
  生成: $(date '+%Y-%m-%d %H:%M:%S')
  优选域名: $NEW_DOMAIN | VPS: $PUBLIC_IP
========================================

【配置一】VLESS + WS（无分片）
  地址:  $NEW_DOMAIN
  端口:  443
  协议:  VLESS
  UUID:  $UUID
  传输:  WebSocket
  Host:  $CF_HOST
  SNI:   $CF_HOST
  路径:  $WS_PATH
  TLS:   true
  指纹:  chrome

  分享链接:
  $VLESS_URL#配置一-无分片

【配置二】VLESS + WS（开启 Fragment 分片）
  与配置一相同，在客户端开启:
  分片: tlshello 100-200 / 10-20ms

  分享链接:
  $VLESS_URL#配置二-分片

========================================
EOF

echo "已切换到: $NEW_DOMAIN"
echo "分享链接:"
echo "$VLESS_URL#配置一-无分片"
echo ""
echo "提示：优选域名选择离客户端本地近的服务商，不是离 VPS 近的。"