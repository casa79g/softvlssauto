#!/bin/bash
# ============================================================
# 卸载 CF Tunnel + VLESS 部署
# 用法: bash /root/softvlssauto/uninstall.sh
# ============================================================

echo "╔══════════════════════════════════════════════╗"
echo "║      CF Tunnel + VLESS 卸载程序              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
read -rp "确认卸载？此操作不可恢复 [Y/n]: " CONFIRM
[ "${CONFIRM:-Y}" = "n" ] && echo "已取消" && exit 0

echo ""
echo "[1/6] 停止服务..."
systemctl stop sing-box-vless cloudflared-tunnel 2>/dev/null
systemctl disable sing-box-vless cloudflared-tunnel 2>/dev/null

echo "[2/6] 删除 systemd 服务..."
rm -f /etc/systemd/system/sing-box-vless.service
rm -f /etc/systemd/system/cloudflared-tunnel.service
systemctl daemon-reload 2>/dev/null

echo "[3/6] 删除二进制文件..."
rm -f /usr/local/bin/sing-box /usr/local/bin/cloudflared

echo "[4/6] 删除配置文件..."
rm -rf /etc/sing-box /root/sub.txt /root/cf-tunnel.conf

echo "[5/6] 清理脚本目录..."
rm -rf /root/softvlssauto

echo "[6/6] 清理完成 ✓"
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║         卸载成功，再见！                       ║"
echo "╚══════════════════════════════════════════════╝"