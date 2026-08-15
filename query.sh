#!/bin/bash
# ============================================================
# 查询节点信息 + 网络诊断
# 用法: bash query.sh
# ============================================================
set -uo pipefail

SUB_FILE="/root/sub.txt"
SB_DIR="/etc/sing-box"
SB_PORT="8001"

if [ -f "$SUB_FILE" ]; then
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║            网络学习节点信息                               ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  cat "$SUB_FILE"
else
  echo "[WARN] 未找到 $SUB_FILE，仅显示诊断信息"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  运行状态"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SB_RUNNING="未运行"
CF_RUNNING="未运行"

if pgrep -f 'sing-box' >/dev/null 2>&1; then
  SB_RUNNING="运行中 (PID: $(pgrep -f 'sing-box' | head -1))"
fi
if pgrep -f 'cloudflared' >/dev/null 2>&1; then
  CF_RUNNING="运行中 (PID: $(pgrep -f 'cloudflared' | head -1))"
fi
echo "  sing-box:    $SB_RUNNING"
echo "  cloudflared: $CF_RUNNING"

# 端口检查
echo ""
echo "  端口 $SB_PORT:  $([ "$(python3 -c "import socket; s=socket.socket(); r=s.connect_ex(('127.0.0.1',$SB_PORT)); print('OPEN' if r==0 else 'CLOSED'); s.close()" 2>/dev/null)" = "OPEN" ] && echo '✅ 通' || echo '❌ 不通')"

# IPv6 诊断
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  /etc/hosts 诊断"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
HOSTS_OUT=$(grep localhost /etc/hosts 2>/dev/null || echo "")
echo "  $HOSTS_OUT"

if echo "$HOSTS_OUT" | grep -q '::1'; then
  echo ""
  echo "  ⚠️  检测到 ::1 localhost！"
  echo "     cloudflared 可能连 IPv6 而 sing-box 只监听 IPv4"
  echo "     修复: sed -i '/^::1.*localhost/d' /etc/hosts"
  echo "     然后重启 cloudflared"
else
  echo "  ✅ /etc/hosts 正常（仅 IPv4）"
fi

# cloudflared 错误检查
if [ -f /tmp/cloudflared-tunnel.log ]; then
  ERR_COUNT=$(grep -c "ERR" /tmp/cloudflared-tunnel.log 2>/dev/null || echo 0)
  REFUSED=$(grep -c "connection refused" /tmp/cloudflared-tunnel.log 2>/dev/null || echo 0)
  echo ""
  echo "  cloudflared 日志: ERR=$ERR_COUNT, connection_refused=$REFUSED"
  [ "$REFUSED" -gt 0 ] && echo "  ⚠️  有 connection refused，需修复 /etc/hosts"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  外网连通性测试（从本机回环）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CF_HOST=$(grep "CF_HOST=" /root/cf-tunnel.conf 2>/dev/null | cut -d'"' -f2 || echo "")
WS_PATH=$(grep "WS_PATH=" /root/cf-tunnel.conf 2>/dev/null | cut -d'"' -f2 || echo "")

if [ -n "$CF_HOST" ] && [ -n "$WS_PATH" ]; then
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$CF_HOST$WS_PATH" 2>/dev/null || echo "FAIL")
  echo "  https://$CF_HOST$WS_PATH → HTTP $HTTP_CODE"
  [ "$HTTP_CODE" = "403" ] && echo "  ✅ 隧道到 sing-box 全链路通" || echo "  ⚠️  异常，请检查日志"
else
  echo "  /root/cf-tunnel.conf 未找到，跳过外网测试"
fi