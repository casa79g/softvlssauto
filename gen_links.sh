#!/bin/bash
# gen_links.sh — 切换 CF 优选域名（v2.2）
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
CF_HOST=$(grep "^  Host:" "$SUB_FILE" | head -1 | sed 's/^  Host: *//')
WS_PATH=$(grep "^  路径:" "$SUB_FILE" | head -1 | sed 's/^  路径: *//')
UUID=$(grep "^  UUID:" "$SUB_FILE" | head -1 | sed 's/^  UUID: *//')

[ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)
[ -z "$CF_HOST" ] && CF_HOST="cf-tunnel.example.com"
[ -z "$WS_PATH" ] && WS_PATH="/proxy-default"

# 生成两个链接：真实隧道域名 + 优选域名
VLESS_REAL="vless://${UUID}@${CF_HOST}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"
VLESS_PREF="vless://${UUID}@${NEW_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")

cat > "$SUB_FILE" << EOF
========================================
  网络学习节点 v3.5（优选域名已更新）
  生成: $(date '+%Y-%m-%d %H:%M:%S')
  优选域名: $NEW_DOMAIN | VPS: $PUBLIC_IP
========================================

【配置一】VLESS + WS — 真实隧道域名（连通测试用，TLS握手必通）
  地址:  $CF_HOST
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
  $VLESS_REAL#真实域名-连通测试

【配置二】VLESS + WS — 优选域名（延迟可能更低，需先测试）
  与配置一唯一区别：地址栏换优选域名
  地址:  $NEW_DOMAIN
  Host/SNI: 保持 $CF_HOST 不变

  分享链接:
  $VLESS_PREF#优选域名

========================================
EOF

echo "已切换到: $NEW_DOMAIN"
echo "分享链接（真实域名）: $VLESS_REAL#真实域名-连通测试"
echo "分享链接（优选域名）: $VLESS_PREF#优选域名"
echo ""
echo "提示：优选域名选择离客户端本地近的服务商，不是离 VPS 近的。"
echo "建议先用真实域名链接测试连通性，再试优选域名。"