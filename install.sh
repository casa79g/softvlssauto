#!/bin/bash
# ============================================================
# CF Tunnel + VLESS 自动部署脚本 v1.1
# 网络学习节点部署工具
# 用法: bash install.sh
# ============================================================
set -euo pipefail

# ── 颜色 ──
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "  ${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "  ${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "  ${CYAN}$1${NC}"; echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ── 检查 root ──
[ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行"

# ── 全局变量 ──
TUNNEL_NAME=""; CF_TOKEN=""; CF_HOST=""; SB_PORT=""; WS_PATH=""; UUID=""
PREF_DOMAIN=""; USE_GRPC="n"
ARCH=$(uname -m)
NOW=$(date +%Y-%m-%d_%H%M%S)
SB_DIR="/etc/sing-box"
SUB_FILE="/root/sub.txt"

print_banner() {
cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║        CF Tunnel + VLESS  自动部署脚本 v1.1                  ║
║        网络学习节点部署工具                                  ║
╚══════════════════════════════════════════════════════════════╝
EOF
}

# ================================================================
# Step 1 — 系统检测
# ================================================================
step "Step 1/10 — 系统检测"
detect_sys() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    SYS="$PRETTY_NAME"
  else
    SYS=$(uname -s)
  fi
  DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
  DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
  echo -e "  ${GREEN}[INFO]${NC} 系统: $SYS"
  echo -e "  ${GREEN}[INFO]${NC} 架构: $ARCH"
  echo -e "  ${GREEN}[INFO]${NC} 内核: $(uname -r)"
  echo -e "  ${GREEN}[INFO]${NC} 磁盘: 可用 $DISK_FREE / 总计 $DISK_TOTAL"
  echo -e "  ${GREEN}[INFO]${NC} 用户: $(whoami)"
}

install_deps() {
  for cmd in curl wget jq python3 file; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "缺少 $cmd，正在安装..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq "$cmd" >/dev/null 2>&1 || true
      elif command -v yum >/dev/null 2>&1; then
        yum install -y "$cmd" >/dev/null 2>&1 || true
      fi
    fi
  done
}

detect_sys
install_deps

# ================================================================
# Step 2 — 端口扫描
# ================================================================
step "Step 2/10 — 端口扫描"

scan_port() {
  if ss -tlnp "sport = :$1" >/dev/null 2>&1; then
    return 0  # occupied
  else
    return 1  # free
  fi
}

scan_all_ports() {
  printf "  ${GREEN}[INFO]${NC} 正在扫描常用端口...\n\n"
  printf "  %s┌──────────┬────────┬──────────────────────┐%s\n" "${BOLD}" "${NC}"
  printf "  %s│  端口    │ 状态   │ 用途建议              │%s\n" "${BOLD}" "${NC}"
  printf "  %s├──────────┼────────┼──────────────────────┤%s\n" "${BOLD}" "${NC}"

  for PORT in 80 443 8001 8002 8080 8443 3000; do
    if scan_port "$PORT"; then
      STATUS="${RED}已占用${NC}"
    else
      STATUS="${GREEN}空闲${NC}"
    fi
    printf "  %s│ %6d │ %-6s │ %-20s │%s\n" "${BOLD}" "$PORT" "$STATUS" "${NC}" "${NC}"
  done

  printf "  %s└──────────┴────────┴──────────────────────┘%s\n" "${BOLD}" "${NC}"
}

# 建议主端口
SUGGEST_PORT=""
for PORT in 8001 8002 8080 8443 3000; do
  if ! scan_port "$PORT"; then
    SUGGEST_PORT="$PORT"; break
  fi
done
[ -z "$SUGGEST_PORT" ] && SUGGEST_PORT="8001"

scan_all_ports

# 用户选择监听端口
echo ""
read -rp "  sing-box 监听端口（推荐 ${CYAN}${SUGGEST_PORT}${NC}，回车使用默认）: ["$SUGGEST_PORT"]" SB_PORT
SB_PORT="${SB_PORT:-$SUGGEST_PORT}"

# 验证端口
if scan_port "$SB_PORT"; then
  error "端口 $SB_PORT 已被占用，请释放后重试或换其他端口"
fi

info "sing-box 将监听端口: $SB_PORT"

# ================================================================
# Step 3 — 下载二进制
# ================================================================
step "Step 3/10 — 下载二进制"

get_latest_release() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "$2"
}

# 下载 sing-box
SB_VERSION=$(get_latest_release "SagerNet/sing-box" "v1.13.0")
SB_VERSION="${SB_VERSION:-v1.13.0}"
SB_TAG="${SB_VERSION#v}"
SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VERSION}/sing-box-${SB_TAG}-linux-${ARCH}"
if [ "$ARCH" = "aarch64" ]; then SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VERSION}/sing-box-${SB_TAG}-linux-arm64"; fi

info "下载 sing-box $SB_VERSION ..."
DOWNLOAD_URLS=(
  "$SB_URL"
  "https://github.com/SagerNet/sing-box/releases/latest/download/sing-box-${SB_TAG}-linux-${ARCH}"
)
SB_DOWNLOAD_OK=0
for try_url in "${DOWNLOAD_URLS[@]}"; do
  curl -sL -o /usr/local/bin/sing-box "$try_url" 2>/dev/null
  if [ -f /usr/local/bin/sing-box ] && file /usr/local/bin/sing-box | grep -qi "ELF"; then
    SB_DOWNLOAD_OK=1
    break
  fi
done
[ "$SB_DOWNLOAD_OK" -eq 0 ] && error "sing-box 下载失败，请检查网络或架构 (当前: $ARCH)"
chmod +x /usr/local/bin/sing-box
info "sing-box 下载完成: $(sing-box version 2>&1 | head -1)"

# 下载 cloudflared
info "下载 cloudflared ..."
CF_URLS=(
  "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}.deb"
)
if [ "$ARCH" = "aarch64" ]; then
  CF_URLS=("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb")
fi

mkdir -p /tmp/cf-deb
CF_DEB_OK=0
for try_url in "${CF_URLS[@]}"; do
  curl -sL -o /tmp/cf-deb/cloudflared.deb "$try_url" 2>/dev/null
  if [ -f /tmp/cf-deb/cloudflared.deb ] && file /tmp/cf-deb/cloudflared.deb | grep -qi "deb\|archive"; then
    CF_DEB_OK=1
    break
  fi
done
if [ "$CF_DEB_OK" -eq 0 ]; then
  error "cloudflared .deb 下载失败，请检查网络或架构 (当前: $ARCH)"
fi

dpkg -x /tmp/cf-deb/cloudflared.deb /tmp/cf-deb/ 2>/dev/null || true
if [ -f /tmp/cf-deb/usr/bin/cloudflared ] && file /tmp/cf-deb/usr/bin/cloudflared | grep -qi "ELF"; then
  cp /tmp/cf-deb/usr/bin/cloudflared /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
else
  # 回退：直接下载裸二进制
  for try_url in "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" \
                 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"; do
    curl -sL -o /usr/local/bin/cloudflared "$try_url" 2>/dev/null
    if [ -f /usr/local/bin/cloudflared ] && file /usr/local/bin/cloudflared | grep -qi "ELF"; then
      chmod +x /usr/local/bin/cloudflared
      break
    fi
  done
  if [ ! -f /usr/local/bin/cloudflared ] || ! file /usr/local/bin/cloudflared | grep -qi "ELF"; then
    error "cloudflared 下载失败，请检查网络或架构 (当前: $ARCH)"
  fi
fi
rm -rf /tmp/cf-deb
info "cloudflared 下载完成: $(cloudflared --version 2>&1 | head -1)"

# ================================================================
# Step 4 — 参数配置
# ================================================================
step "Step 4/10 — 参数配置"

read -rp "  1. 隧道名称（CF面板中的名字）: [arnegowl]" TUNNEL_NAME
TUNNEL_NAME="${TUNNEL_NAME:-arnegowl}"

# 优先使用环境变量 CF_TOKEN，否则手动输入（单次，不回显）
if [ -n "${CF_TOKEN:-}" ]; then
  info "已检测到环境变量 CF_TOKEN，直接使用"
else
  echo ""
  warn "提示：Token 较长（约200字符），请整段复制后粘贴，不要手动输入"
  echo -n "  2. 隧道 Token（eyJh... 开头，不回显，粘贴后回车）: "
  read -r CF_TOKEN
  if [ -z "$CF_TOKEN" ]; then
    error "Token 不能为空"
  fi
fi
[ -z "$CF_TOKEN" ] && error "Token 不能为空"

read -rp "  3. CF 隧道域名（CF面板 ingress 的 hostname）: " CF_HOST
[ -z "$CF_HOST" ] && error "CF 域名不能为空"

# 自动检测端口（若用户没在 step 2 输入则自动设8001）
SB_PORT="${SB_PORT:-8001}"

# WebSocket 路径
RANDOM_PATH="/proxy-$(openssl rand -hex 3 2>/dev/null || echo $((RANDOM*RANDOM % 99999)))"
read -rp "  4. WebSocket 路径（回车自动生成 $CYAN$RANDOM_PATH${NC}）: ["$RANDOM_PATH"]" WS_PATH
WS_PATH="${WS_PATH:-$RANDOM_PATH}"

# UUID
AUTO_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)")
read -rp "  5. UUID（回车自动生成）: ["$AUTO_UUID"]" UUID
UUID="${UUID:-$AUTO_UUID}"

# CF优选域名（地址/Host/SNI 统一用此域名）
read -rp "  6. CF优选域名（地址/Host/SNI均使用，默认 ${CYAN}cf.godns.cc${NC}）: ["cf.godns.cc"]" PREF_DOMAIN
PREF_DOMAIN="${PREF_DOMAIN:-cf.godns.cc}"

# gRPC
read -rp "  7. 是否启用 gRPC 入口？${YELLOW}(推荐 N，VLESS 已够用)${NC} [N]: " USE_GRPC
USE_GRPC="${USE_GRPC:-n}"

echo ""
echo "  ${BOLD}配置确认:${NC}"
echo "  ┌──────────────┬──────────────────────────────┐"
echo "  │ 隧道名称     │ $TUNNEL_NAME"
echo "  │ CF 域名      │ $CF_HOST"
echo "  │ 监听端口     │ $SB_PORT"
echo "  │ WS 路径      │ $WS_PATH"
echo "  │ UUID         │ $UUID"
echo "  │ CF优选域名 │ $PREF_DOMAIN"
echo "  │ gRPC         │ $USE_GRPC"
echo "  └──────────────┴──────────────────────────────┘"
read -rp "  确认开始部署？[Y/n]: " CONFIRM
[ "${CONFIRM:-Y}" = "n" ] && error "部署已取消"

# ================================================================
# Step 5 — 生成配置
# ================================================================
step "Step 5/10 — 生成 sing-box 配置"

mkdir -p "$SB_DIR"

# 生成 sing-box 配置
cat > "$SB_DIR/sb.json" << SBEOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "tag": "vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": $SB_PORT,
      "sniff": true,
      "sniff_override_destination": true,
      "protocol": "vless",
      "udp": true,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": { "Host": "$CF_HOST" }
      }
    }
SBEOF

# 如果启用 gRPC
if [ "$USE_GRPC" = "y" ] || [ "$USE_GRPC" = "Y" ]; then
  # 检查 sing-box 是否支持 grpc
  if sing-box version 2>&1 | grep -qi grpc; then
    cat >> "$SB_DIR/sb.json" << GRPEOF
    ,
    {
      "tag": "vless-grpc-in",
      "listen": "127.0.0.1",
      "listen_port": 8002,
      "protocol": "vless",
      "udp": true,
      "users": [
        { "uuid": "$UUID" }
      ],
      "transport": {
        "type": "grpc",
        "service_name": "network-learning"
      }
    }
GRPEOF
    info "已添加 gRPC 入口 (8002)"
  else
    warn "sing-box 不支持 gRPC（未编译 with_grpc 标签），跳过"
    USE_GRPC="n"
  fi
fi

cat >> "$SB_DIR/sb.json" << SBEOF2
  ],
  "dns": {
    "servers": [
      { "tag": "doh", "address": "https://1.1.1.1/dns-query" }
    ]
  },
  "route": {
    "rules": [
      { "domain": ["geosite:google"], "outbound": "direct" }
    ],
    "final": "direct"
  },
  "outbounds": [
    { "tag": "direct", "type": "direct" },
    { "tag": "block", "type": "block" }
  ]
}
SBEOF2

info "sing-box 配置已写入 $SB_DIR/sb.json"

# 写入 cloudflared 配置
cat > /root/cf-tunnel.conf << CFEOF
CF_TOKEN="$CF_TOKEN"
TUNNEL_NAME="$TUNNEL_NAME"
TUNNEL_PORT=$SB_PORT
CF_HOST="$CF_HOST"
WS_PATH="$WS_PATH"
SB_DIR="$SB_DIR"
CFEOF
chmod 600 /root/cf-tunnel.conf
info "cloudflared 配置已写入 /root/cf-tunnel.conf（权限 600）"

# ================================================================
# Step 6 — 写入 systemd 服务
# ================================================================
step "Step 6/10 — 写入 systemd 服务"

# sing-box 服务
cat > /etc/systemd/system/sing-box-vless.service << SVC_EOF
[Unit]
Description=Sing-box VLESS for CF Tunnel
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c $SB_DIR/sb.json
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC_EOF

# cloudflared 服务
cat > /etc/systemd/system/cloudflared-tunnel.service << SVC_EOF
[Unit]
Description=Cloudflare Tunnel for VLESS
After=sing-box-vless.service
Wants=sing-box-vless.service

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel run --token \$(cat /root/cf-tunnel.conf | grep CF_TOKEN | cut -d'"' -f2) --protocol http2
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
info "systemd 服务已写入"

# ================================================================
# Step 7 — 启动服务
# ================================================================
step "Step 7/10 — 启动服务"

systemctl enable sing-box-vless.service
systemctl start sing-box-vless.service
sleep 2
info "sing-box 启动完成 (PID: $(pgrep -f 'sing-box' | head -1))"

systemctl enable cloudflared-tunnel.service
systemctl start cloudflared-tunnel.service
sleep 3
info "cloudflared 启动完成 (PID: $(pgrep -f cloudflared | head -1))"

# 检查 CF 连接
CF_CONN=$(journalctl -u cloudflared-tunnel --no-pager -n 20 2>/dev/null | grep -c "connected\|quic\|http2\|Connected" || echo 0)
info "cloudflared 连接状态: $CF_CONN 条活动连接"

# ================================================================
# Step 8 — 连通性测试
# ================================================================
step "Step 8/10 — 连通性测试"

# 本地测试
info "测试本地 sing-box 端口 $SB_PORT ..."
LOCAL_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$SB_PORT/" 2>/dev/null || echo "FAIL")
info "  HTTP 请求: $LOCAL_HTTP (正常返回404)"

# CF 隧道测试
info "测试 CF 隧道: https://$CF_HOST$WS_PATH ..."
CF_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --http1.1 "https://$CF_HOST/" 2>/dev/null || echo "FAIL")
CF_WS=$(curl -s --http1.1 --max-time 10 -H "Upgrade: websocket" -H "Connection: Upgrade" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" "https://$CF_HOST$WS_PATH" -o /dev/null -w '%{http_code}' 2>/dev/null || echo "FAIL")
info "  HTTP 请求: $CF_HTTP"
info "  WebSocket: $CF_WS (101=成功)"

if [ "$CF_WS" = "101" ]; then
  echo -e "  ${GREEN}[OK] CF 隧道连通性测试通过 ✓${NC}"
else
  echo -e "  ${YELLOW}[WARN] CF 隧道可能需要几分钟初始化，请稍后重试${NC}"
fi

# ================================================================
# Step 9 — 生成 sub.txt
# ================================================================
step "Step 9/10 — 生成 sub.txt"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")

# 生成两条 vless 链接（URL 相同，标签不同区分用途）
VLESS_URL="vless://${UUID}@${PREF_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${PREF_DOMAIN}&path=${WS_PATH}&sni=${PREF_DOMAIN}&fp=chrome"
VLESS_LINK1="${VLESS_URL}#配置一-无分片"
VLESS_LINK2="${VLESS_URL}#配置二-分片"

# 生成 sub.txt
cat > "$SUB_FILE" << SUBEOF
========================================
  网络学习节点 - 自动生成 $(date '+%Y-%m-%d %H:%M:%S')
  隧道: $TUNNEL_NAME | CF域名: $CF_HOST
  VPS:  $PUBLIC_IP | 时间: $NOW
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
  重启后自动恢复（systemd 开机自启）

========================================
SUBEOF

chmod 600 "$SUB_FILE"
info "已写入 $SUB_FILE"

# 打印 sub.txt
echo ""
cat "$SUB_FILE"

# ================================================================
# Step 10 — 完成
# ================================================================
step "Step 10/10 — 部署完成"

cat << DONE
╔═══════════════════════════════════════════════════════════╗
║                     部署成功！                             ║
╠═══════════════════════════════════════════════════════════╣
║                                                           ║
║   sing-box:  监听 $SB_PORT 端口                           ║
║   cloudflared: CF隧道 $TUNNEL_NAME 已建立                  ║
║   sub.txt:  /root/sub.txt                                 ║
║                                                           ║
║   客户端配置:                                             ║
║   • V2RayN / Karing: 粘贴上方分享链接                     ║
║   • CF优选域名:  在地址栏填入优选域名                      ║
║   • Host/SNI:    保持 $CF_HOST 不变  ║
║   • 分片:        如需请在V2RayN节点高级设置中开启            ║
║                                                           ║
║   查询命令:  cat /root/sub.txt                            ║
║   重启机器后: systemd 自动拉起，无需操作                   ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
DONE

echo ""
info "全部完成！"
echo ""
info "后续管理命令："
echo "  查询节点:    cat /root/sub.txt"
echo "  查看日志:    journalctl -u sing-box-vless -f"
echo "  重启服务:    systemctl restart sing-box-vless cloudflared-tunnel"
echo "  停止服务:    systemctl stop sing-box-vless cloudflared-tunnel"
echo "  卸载清理:    bash $0 uninstall"