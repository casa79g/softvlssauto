#!/bin/bash
# ============================================================
# 卸载 CF Tunnel + VLESS 部署（v2.1）
# 用法: bash /root/softvlssauto/uninstall.sh
# ============================================================

echo "╔══════════════════════════════════════════════╗"
echo "║      CF Tunnel + VLESS 卸载程序              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
read -rp "确认卸载？此操作不可恢复 [Y/n]: " CONFIRM
[ "${CONFIRM:-Y}" = "n" ] && echo "已取消" && exit 0

echo ""

# ── 停止所有进程 ──
echo "[1/7] 停止 PM2 进程..."
if command -v pm2 >/dev/null 2>&1 || [ -f /usr/local/bin/pm2 ]; then
    PM2_BIN=$(command -v pm2 2>/dev/null || /usr/local/bin/pm2)
    "$PM2_BIN" stop sing-box-vless cloudflared-tunnel 2>/dev/null || true
    "$PM2_BIN" delete sing-box-vless cloudflared-tunnel 2>/dev/null || true
fi

echo "[2/7] 停止 systemd 服务..."
systemctl stop sing-box-vless cloudflared-tunnel 2>/dev/null || true
systemctl disable sing-box-vless cloudflared-tunnel 2>/dev/null || true

echo "[3/7] 删除 systemd 服务文件..."
rm -f /etc/systemd/system/sing-box-vless.service
rm -f /etc/systemd/system/cloudflared-tunnel.service
systemctl daemon-reload 2>/dev/null || true

echo "[4/7] 删除 PM2 启动脚本..."
rm -f /root/start-sing-box.sh /root/start-cloudflared.sh
rm -f /root/cf-tunnel-ecosystem.json

echo "[5/7] 删除二进制文件..."
rm -f /usr/local/bin/sing-box /usr/local/bin/cloudflared

echo "[6/7] 删除配置文件..."
rm -rf /etc/sing-box /root/sub.txt /root/cf-tunnel.conf

echo "[7/7] 清理脚本目录..."
rm -rf /root/softvlssauto

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║         卸载成功，再见！                       ║"
echo "╚══════════════════════════════════════════════╝"