#!/bin/bash
# query.sh — 节点信息查询与诊断（v2.1）
# 用法: bash query.sh
set -o pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
SUB="/root/sub.txt"
SB_CONF="/etc/sing-box/sb.json"
ECOSYS="/root/cf-tunnel-ecosystem.json"
SB_DIR="/etc/sing-box"

if [ -f "$SUB" ]; then
    echo -e "\n  ┌─── 节点配置 ───────────────────────────────────────┐"
    echo -e "  │ 文件: $SUB"
    echo -e "  └─────────────────────────────────────────────────────┘"
    cat "$SUB"
else
    echo "  ⚠️  未找到 sub.txt"
fi

if [ -f "$SB_CONF" ]; then
    echo -e "\n  ┌─── sing-box 配置 ──────────────────────────────────┐"
    echo -e "  │ UUID: $(grep uuid "$SB_CONF" | head -1 | sed 's/.*"uuid": "//' | sed 's/".*//')"
    echo -e "  │ 端口: $(grep listen_port "$SB_CONF" | head -1 | sed 's/.*: //')"
    echo -e "  │ 路径: $(grep path "$SB_CONF" | head -1 | sed 's/.*"path": "//' | sed 's/".*//')"
    echo -e "  └─────────────────────────────────────────────────────┘"
fi

echo -e "\n  ┌─── 进程状态 ──────────────────────────────────────┐"

# 检查 PM2
if command -v pm2 >/dev/null 2>&1 || command -v /usr/local/bin/pm2 >/dev/null 2>&1; then
    PM2_BIN=$(command -v pm2 2>/dev/null || /usr/local/bin/pm2)
    if "$PM2_BIN" list 2>/dev/null | grep -q "sing-box\|cloudflared"; then
        echo -e "  │ PM2 进程列表:"
        "$PM2_BIN" list 2>/dev/null
        echo -e "  │"
        echo -e "  │ 实时日志: pm2 logs"
    else
        echo -e "  │ PM2 运行中，但未找到相关进程"
    fi
else
    echo -e "  │ PM2 未安装或未运行"
fi

# 检查进程是否活着
for PROC in "sing-box" "cloudflared"; do
    PIDS=$(pgrep -f "$PROC" 2>/dev/null || true)
    if [ -n "$PIDS" ]; then
        echo -e "  │ $PROC: ${GREEN}运行中${NC} (PID: $(echo $PIDS | tr '\n' ' '))"
    else
        echo -e "  │ $PROC: ${RED}未运行${NC}"
    fi
done
echo -e "  └─────────────────────────────────────────────────────┘"

# /etc/hosts 检查
echo -e "\n  ┌─── /etc/hosts IPv6 检查 ──────────────────────────┐"
if grep -q '^[[:space:]]*::1.*localhost' /etc/hosts 2>/dev/null; then
    echo -e "  │ ${RED}⚠️  /etc/hosts 中存在 ::1 localhost${NC}"
    echo -e "  │ 可能导致 cloudflared 连接 sing-box 被拒绝"
    echo -e "  │ 修复: sed -i '/^::1.*localhost/d' /etc/hosts"
else
    echo -e "  │ ${GREEN}✓ /etc/hosts 正常${NC}"
fi
echo -e "  └─────────────────────────────────────────────────────┘"

echo -e "\n  ┌─── 端口监听检查 ──────────────────────────────────┐"
for P in 8001 8002 8080; do
    if ss -tlnp "sport = :$P" 2>/dev/null | grep -q "."; then
        PID=$(ss -tlnp "sport = :$P" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1 || true)
        CMD=$(cat /proc/"${PID:-0}"/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-40 || echo "")
        echo -e "  │ 端口 $P: ${GREEN}监听中${NC} (PID:$PID $CMD)"
    else
        echo -e "  │ 端口 $P: ${YELLOW}未监听${NC}"
    fi
done
echo -e "  └─────────────────────────────────────────────────────┘"

echo -e "\n  ┌─── 本地回环测试 ──────────────────────────────────┐"
SB_PORT=$(grep listen_port "$SB_CONF" 2>/dev/null | head -1 | sed 's/.*: //')
if [ -n "$SB_PORT" ]; then
    R=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SB_PORT/" 2>/dev/null || echo "FAIL")
    echo -e "  │ 127.0.0.1:$SB_PORT → HTTP $R (404=正常)"
fi
echo -e "  └─────────────────────────────────────────────────────┘"

echo -e "\n  ┌─── 配置文件权限 ──────────────────────────────────┐"
for f in "$SUB" "$SB_CONF" "$ECOSYS" "/root/cf-tunnel.conf"; do
    if [ -f "$f" ]; then
        PERM=$(stat -c "%a" "$f" 2>/dev/null || ls -l "$f" | awk '{print $1}')
        echo -e "  │ $f → $PERM"
    fi
done
echo -e "  └─────────────────────────────────────────────────────┘"

echo ""
