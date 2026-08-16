#!/bin/bash
# ============================================================
# CF Tunnel + VLESS 自动部署脚本 v2.5
# VLESS Tunnel Deploy Toolkit部署工具
# 守护架构：PM2（主） + systemd（容器兜底） + cron（可选）
# ============================================================
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "  ${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "  ${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "  ${CYAN}$1${NC}"; echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行"

# ================================================================
# 目录自愈：修正 git clone 嵌套问题
# 如果检测到 /root/softvlssauto/softvlssauto/ 这种多层嵌套，
# 把内层文件合并到外层，然后删除多余层。
# ================================================================
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SCRIPT_BASENAME="$(basename "$SELF_DIR")"
SELF_PARENT="$(dirname "$SELF_DIR")"

if [ -n "$SELF_PARENT" ] && [ "$SELF_PARENT" != "/" ]; then
  # 检测外层是否也有同名目录（说明我们被嵌在里面了）
  OUTER_SCRIPT="${SELF_PARENT}/${SCRIPT_BASENAME}"
  if [ -d "$SELF_DIR" ] && [ -f "${SELF_DIR}/${SCRIPT_BASENAME}.sh" ] && [ -d "${SELF_DIR}/${SCRIPT_BASENAME}" ]; then
    warn "检测到嵌套目录结构，正在修复..."
    for f in install.sh gen_links.sh query.sh sb-template.json uninstall.sh README.md; do
      [ -f "${SELF_DIR}/${SCRIPT_BASENAME}/${f}" ] && cp "${SELF_DIR}/${SCRIPT_BASENAME}/${f}" "${SELF_DIR}/${f}" 2>/dev/null
    done
    rm -rf "${SELF_DIR}/${SCRIPT_BASENAME}"
    info "嵌套目录已修正（展开至 ${SELF_DIR}/）"
  fi

  # 检测同一目录下是否还有同名的旧克隆副本
  OLD_CLONE="${SELF_DIR}/softvlssauto"
  if [ -d "$OLD_CLONE" ] && [ -f "${OLD_CLONE}/install.sh" ]; then
    warn "检测到旧克隆副本，正在清理..."
    for f in install.sh gen_links.sh query.sh sb-template.json uninstall.sh README.md; do
      [ -f "${OLD_CLONE}/${f}" ] && cp "${OLD_CLONE}/${f}" "${SELF_DIR}/${f}" 2>/dev/null
    done
    rm -rf "$OLD_CLONE"
    info "旧克隆副本已清理"
  fi
fi

TUNNEL_NAME=""; CF_TOKEN=""; CF_HOST=""; SB_PORT=""; WS_PATH=""; UUID=""
PREF_DOMAIN=""; USE_GRPC="n"; NON_INTERACTIVE=0
BEACON_URL="${BEACON_URL:-http://47.84.122.196:8900/beacon}"
NO_BEACON="${NO_BEACON:-0}"
if [ -n "${CF_TOKEN:-}" ] && [ -n "${CF_HOST:-}" ]; then NON_INTERACTIVE=1; fi
# 解析 --no-beacon 参数
for _arg in "$@"; do
  [ "$_arg" = "--no-beacon" ] && NO_BEACON=1
done
ARCH=$(uname -m); NOW=$(date +%Y-%m-%d_%H%M%S)
SB_DIR="/etc/sing-box"; SUB_FILE="/root/sub.txt"
USE_SYSTEMD=0
[ "$(cat /proc/1/comm 2>/dev/null)" = "systemd" ] && USE_SYSTEMD=1

# ── 修复 /etc/hosts ──
fix_hosts() {
  if grep -q '^[[:space:]]*::1.*localhost' /etc/hosts 2>/dev/null; then
    info "修复 /etc/hosts（移除 ::1 localhost）..."
    grep -v '^[[:space:]]*::1.*localhost' /etc/hosts > /tmp/hosts.tmp
    cp /tmp/hosts.tmp /etc/hosts 2>/dev/null || warn "/etc/hosts 只读，无法修改"
    rm -f /tmp/hosts.tmp
  fi
}

# ================================================================
# Step 1 — 系统检测
# ================================================================
step "Step 1/10 — 系统检测"

if [ -f /etc/os-release ]; then . /etc/os-release; SYS="$PRETTY_NAME"; else SYS=$(uname -s); fi
DISK_FREE=$(df -h / | awk 'NR==2{print $4}'); DISK_TOTAL=$(df -h / | awk 'NR==2{print $2}')
echo -e "  ${GREEN}[INFO]${NC} 系统: $SYS | 架构: $ARCH | 内核: $(uname -r)"
echo -e "  ${GREEN}[INFO]${NC} 磁盘: 可用 $DISK_FREE / 总计 $DISK_TOTAL"
echo -e "  ${GREEN}[INFO]${NC} systemd: $([ "$USE_SYSTEMD" -eq 1 ] && echo "可用" || echo "不可用（容器）")"

for cmd in curl wget jq python3 file openssl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "缺少 $cmd，正在安装..."
    (apt-get install -y -qq "$cmd" 2>/dev/null || yum install -y "$cmd" 2>/dev/null) || true
  fi
done

# ================================================================
# Step 2 — 端口扫描
# ================================================================
step "Step 2/10 — 端口扫描"

scan_port() { ss -tlnp "sport = :$1" >/dev/null 2>&1; }
SUGGEST_PORT=""
for PORT in 8001 8002 8080 8443 3000; do
  if ! scan_port "$PORT"; then SUGGEST_PORT="$PORT"; break; fi
done
[ -z "$SUGGEST_PORT" ] && SUGGEST_PORT="8001"

printf "  ${BOLD}┌──────────┬────────┬──────────────────────┐${NC}\n"
printf "  ${BOLD}│  端口    │ 状态   │ 占用进程            │${NC}\n"
printf "  ${BOLD}├──────────┼────────┼──────────────────────┤${NC}\n"
for PORT in 80 443 8001 8002 8080 8443 3000; do
  if scan_port "$PORT"; then
    PID=$(ss -tlnp "sport = :$PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1 || true)
    CMD=$(cat /proc/"${PID:-0}"/cmdline 2>/dev/null | tr '\0' ' ' | sed 's/ /_/g' | cut -c1-20 || echo "")
    STATUS="${RED}已占用${NC}"; EXTRA="${PID:-?} ${CMD}"
  else
    STATUS="${GREEN}空闲${NC}"; EXTRA=""
  fi
  printf "  ${BOLD}│ %6d │ %-6s │ %-20s │${NC}\n" "$PORT" "$STATUS" "$EXTRA"
done
printf "  ${BOLD}└──────────┴────────┴──────────────────────┘${NC}\n"

kill_port() {
  local pid=$(ss -tlnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1 || true)
  [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null && sleep 1 && return 0
  return 1
}

[ "$NON_INTERACTIVE" -eq 1 ] && SB_PORT="$SUGGEST_PORT" && \
  (scan_port "$SB_PORT" && kill_port "$SB_PORT") || true
[ "$NON_INTERACTIVE" -eq 0 ] && {
  read -rp "  sing-box 监听端口（推荐 ${CYAN}${SUGGEST_PORT}${NC}）: ["$SUGGEST_PORT"]" SB_PORT
  SB_PORT="${SB_PORT:-$SUGGEST_PORT}"
  scan_port "$SB_PORT" && kill_port "$SB_PORT" && info "端口已释放"
}
info "sing-box 监听端口: $SB_PORT"

# ================================================================
# Step 2.5 — 网络检测
# ================================================================
step "Step 2.5/10 — 网络检测"

GITHUB_OK=0; NAS_OK=0
curl -sI --max-time 5 https://github.com >/dev/null 2>&1 && GITHUB_OK=1
NAS_BASE="${NAS_BASE:-http://47.84.122.196:8900}"
curl -sI --max-time 5 "${NAS_BASE}/sing-box" >/dev/null 2>&1 && NAS_OK=1

[ "$NAS_OK" -eq 1 ] && echo "  ${GREEN}✓ NAS 本地源可达${NC}" || echo "  ${YELLOW}✗ NAS 本地源不可达${NC}"
[ "$GITHUB_OK" -eq 1 ] && echo "  ${GREEN}✓ GitHub 可达${NC}" || echo "  ${YELLOW}✗ GitHub 不可达${NC}"
[ "$GITHUB_OK" -eq 0 ] && [ "$NAS_OK" -eq 0 ] && error "所有下载源均不可达"

# ================================================================
# Step 3 — 下载二进制
# ================================================================
step "Step 3/10 — 下载二进制"

if [ "$ARCH" = "x86_64" ]; then R_ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then R_ARCH="arm64"; else R_ARCH="$ARCH"; fi

# ── sing-box ──
SB_VER="${SB_VERSION:-1.13.18}"; SB_TAR="sing-box-${SB_VER}-linux-${R_ARCH}.tar.gz"
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${SB_TAR}"
SB_MIRROR="https://gitlab.com/rwkgyg/sing-box-yg/-/raw/main/${SB_TAR}"
SB_DL=0

if [ "$NAS_OK" -eq 1 ]; then
  curl -sL -o /usr/local/bin/sing-box "${NAS_BASE}/sing-box" --retry 2 2>/dev/null
  [ -f /usr/local/bin/sing-box ] && [ "$(xxd -l 4 /usr/local/bin/sing-box | awk '{print $2}')" = "7f45" ] && SB_DL=1
fi

if [ "$SB_DL" -eq 0 ]; then
  for try_url in "$SB_URL" "$SB_MIRROR"; do
    mkdir -p /tmp/sb-dl
    curl -sL -o /tmp/sb-dl/sb.tar.gz "$try_url" --retry 2 2>/dev/null
    if [ -f /tmp/sb-dl/sb.tar.gz ] && [ "$(xxd -l 2 /tmp/sb-dl/sb.tar.gz | awk '{print $2}')" = "1f8b" ]; then
      tar xzf /tmp/sb-dl/sb.tar.gz -C /tmp/sb-dl/ 2>/dev/null
      EXTRACTED=$(find /tmp/sb-dl -name "sing-box" -type f -size +1M 2>/dev/null | head -1)
      [ -n "$EXTRACTED" ] && cp "$EXTRACTED" /usr/local/bin/sing-box && SB_DL=1 && break
    fi
  done
  rm -rf /tmp/sb-dl
fi
[ "$SB_DL" -eq 0 ] && error "sing-box 下载失败"
chmod +x /usr/local/bin/sing-box; info "sing-box 下载完成"

# ── cloudflared ──
CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${R_ARCH}"
CF_MIRROR="https://gitlab.com/rwkgyg/sing-box-yg/-/raw/main/${R_ARCH}"
CF_DL=0

if [ "$NAS_OK" -eq 1 ]; then
  curl -sL -o /usr/local/bin/cloudflared "${NAS_BASE}/cloudflared" --retry 2 2>/dev/null
  [ -f /usr/local/bin/cloudflared ] && [ "$(xxd -l 4 /usr/local/bin/cloudflared | awk '{print $2}')" = "7f45" ] && CF_DL=1
fi

if [ "$CF_DL" -eq 0 ]; then
  for try_url in "$CF_URL" "$CF_MIRROR"; do
    curl -sL -o /tmp/cf-bin "$try_url" --retry 2 2>/dev/null
    if [ -f /tmp/cf-bin ] && [ "$(xxd -l 4 /tmp/cf-bin | awk '{print $2}')" = "7f45" ]; then
      cp /tmp/cf-bin /usr/local/bin/cloudflared && CF_DL=1 && break
    fi
  done
  rm -f /tmp/cf-bin
fi
[ "$CF_DL" -eq 0 ] && error "cloudflared 下载失败"
chmod +x /usr/local/bin/cloudflared; info "cloudflared 下载完成"

# ── Node.js + PM2（主进程管理器） ──
info "检测 Node.js ..."
if ! command -v node >/dev/null 2>&1; then
  warn "Node.js 未安装，正在安装 ..."
  if command -v apt-get >/dev/null 2>&1; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - 2>/dev/null
    apt-get install -y -qq nodejs 2>/dev/null
  elif command -v yum >/dev/null 2>&1; then
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - 2>/dev/null
    yum install -y nodejs 2>/dev/null
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  warn "Node.js 安装失败，将回退到 systemd/nohup 模式"
else
  info "Node.js: $(node -v)"
fi

# ================================================================
# Step 4 — 参数配置
# ================================================================
step "Step 4/10 — 参数配置"

[ -z "${TUNNEL_NAME:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && {
  read -rp "  1. 隧道名称: [network-learning-node]" TUNNEL_NAME; TUNNEL_NAME="${TUNNEL_NAME:-network-learning-node}"
} || TUNNEL_NAME="${TUNNEL_NAME:-network-learning-node}"

[ -z "${CF_TOKEN:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && {
  echo "  ${YELLOW}提示：Token 较长（约200字符），整段复制后粘贴${NC}"
  echo -n "  2. 隧道 Token (eyJh...): "; read -r CF_TOKEN
}
[ -z "$CF_TOKEN" ] && error "Token 不能为空"

[ -z "${CF_HOST:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && read -rp "  3. CF 隧道域名: " CF_HOST
[ -z "$CF_HOST" ] && error "CF 域名不能为空"

SB_PORT="${SB_PORT:-$SUGGEST_PORT}"

[ -z "${WS_PATH:-}" ] && {
  RANDOM_PATH="/proxy-$(openssl rand -hex 3 2>/dev/null || echo $((RANDOM*RANDOM % 99999)))"
  [ "$NON_INTERACTIVE" -eq 0 ] && {
    read -rp "  4. WS 路径（自动生成 $CYAN$RANDOM_PATH${NC}）: ["$RANDOM_PATH"]" WS_PATH
  }
  WS_PATH="${WS_PATH:-$RANDOM_PATH}"
}

[ -z "${UUID:-}" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)

[ -z "${PREF_DOMAIN:-}" ] && PREF_DOMAIN="${PREF_DOMAIN:-cf.godns.cc}"

[ -z "${USE_GRPC:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && {
  read -rp "  5. 启用 gRPC？${YELLOW}(推荐 N)${NC} [N]: " USE_GRPC
}
USE_GRPC="${USE_GRPC:-n}"

if [ "$NON_INTERACTIVE" -eq 0 ]; then
  echo ""
  echo "  ${BOLD}配置确认:${NC}"
  echo "  隧道: $TUNNEL_NAME | 端口: $SB_PORT | 路径: $WS_PATH"
  echo "  CF域名: $CF_HOST | 优选域名: $PREF_DOMAIN | gRPC: $USE_GRPC"
  read -rp "  确认开始部署？[Y/n]: " CONFIRM
  [ "${CONFIRM:-Y}" = "n" ] && error "部署已取消"
fi

# ================================================================
# Step 5 — 生成配置
# ================================================================
step "Step 5/10 — 生成配置"

mkdir -p "$SB_DIR"

cat > "$SB_DIR/sb.json" << SBEOF
{
  "log": { "level": "error" },
  "inbounds": [
    {
      "tag": "vless-ws-in",
      "listen": "127.0.0.1",
      "listen_port": $SB_PORT,
      "type": "vless",
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "$WS_PATH",
        "headers": { "Host": "$CF_HOST" }
      }
    }
SBEOF

if [ "$USE_GRPC" = "y" ] || [ "$USE_GRPC" = "Y" ]; then
  cat >> "$SB_DIR/sb.json" << GRPEOF
    ,
    {
      "tag": "vless-grpc-in",
      "listen": "127.0.0.1",
      "listen_port": 8002,
      "type": "vless",
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "grpc",
        "service_name": "network-learning"
      }
    }
GRPEOF
  info "已添加 gRPC 入口 (8002)"
fi

cat >> "$SB_DIR/sb.json" << SBEOF2
  ],
  "dns": {
    "servers": [{ "tag": "doh", "address": "https://1.1.1.1/dns-query" }],
    "strategy": "prefer_ipv4"
  },
  "route": {
    "rules": [{ "domain": ["geosite:google"], "outbound": "direct" }],
    "final": "direct"
  },
  "outbounds": [
    { "tag": "direct", "type": "direct" },
    { "tag": "block", "type": "block" }
  ]
}
SBEOF2

# ── 写入 Cloudflare Token 到安全文件（chmod 600，仅 root 可读） ──
cat > /root/cf-tunnel.conf << CFEOF
token=$CF_TOKEN
CFEOF
chmod 600 /root/cf-tunnel.conf
info "Token 已安全写入 /root/cf-tunnel.conf (chmod 600)"

# ── 创建 PM2 启动脚本（避免 token 泄露到进程命令行） ──
cat > /root/start-sing-box.sh << 'SBWEOF'
#!/bin/bash
exec /usr/local/bin/sing-box run -c /etc/sing-box/sb.json
SBWEOF
chmod +x /root/start-sing-box.sh

cat > /root/start-cloudflared.sh << 'CFWEOF'
#!/bin/bash
CF_TOKEN="$(cat /root/cf-tunnel.conf | cut -d= -f2)"
exec /usr/local/bin/cloudflared tunnel run --token "$CF_TOKEN" --protocol http2
CFWEOF
chmod +x /root/start-cloudflared.sh

# ── PM2 ecosystem 配置 ──
cat > /root/cf-tunnel-ecosystem.json << ECOSYS
{
  "apps": [
    {
      "name": "sing-box-vless",
      "script": "/root/start-sing-box.sh",
      "cwd": "/",
      "log_file": "/tmp/sing-box-vless.log",
      "error_file": "/tmp/sing-box-vless.err.log",
      "out_file": "/tmp/sing-box-vless.out.log",
      "merge_logs": true,
      "max_restarts": 999,
      "min_uptime": 10000,
      "restart_delay": 3
    },
    {
      "name": "cloudflared-tunnel",
      "script": "/root/start-cloudflared.sh",
      "cwd": "/",
      "log_file": "/tmp/cloudflared-tunnel.log",
      "error_file": "/tmp/cloudflared-tunnel.err.log",
      "out_file": "/tmp/cloudflared-tunnel.out.log",
      "merge_logs": true,
      "max_restarts": 999,
      "min_uptime": 15000,
      "restart_delay": 5
    }
  ]
}
ECOSYS
chmod 600 /root/cf-tunnel-ecosystem.json
info "sing-box 配置 + 启动脚本 + PM2 ecosystem 已写入"

# ================================================================
# Step 6 — 启动（PM2 优先 / systemd 兜底）
# ================================================================
step "Step 6/10 — 启动（PM2 优先）"

HAS_PM2=0
if command -v pm2 >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
  HAS_PM2=1
fi

if [ "$HAS_PM2" -eq 1 ] || (command -v node >/dev/null 2>&1 && npm install -g pm2 2>/dev/null); then
  info "PM2 可用，使用 PM2 作为进程管理器"

  # 确保 pm2 在 PATH
  if ! command -v pm2 >/dev/null 2>&1; then
    export PATH="/usr/local/bin:$PATH"
  fi

  PM2_BIN=$(command -v pm2 || echo "/usr/local/bin/pm2")

  # 启动
  "$PM2_BIN" start /root/cf-tunnel-ecosystem.json 2>/dev/null || \
    npx pm2 start /root/cf-tunnel-ecosystem.json 2>/dev/null
  sleep 3

  # 开机自启
  if [ "$USE_SYSTEMD" -eq 1 ]; then
    info "设置 PM2 开机自启 (systemd) ..."
    "$PM2_BIN" startup systemd -u root --hp /root 2>/dev/null || true
  else
    info "容器环境，跳过开机自启（systemd 不可用）"
    info "容器重建后需重新运行 install.sh"
  fi

  # 保存进程列表
  "$PM2_BIN" save 2>/dev/null || true
  info "PM2 进程已启动并保存"

  USE_SYSTEMD=1  # 统一后续逻辑
elif [ "$USE_SYSTEMD" -eq 1 ]; then
  info "PM2 不可用但 systemd 可用，使用 systemd 服务"

  cat > /etc/systemd/system/sing-box-vless.service << SVC_EOF
[Unit]
Description=Sing-box VLESS for CF Tunnel
After=network.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
ExecStart=/usr/local/bin/sing-box run -c $SB_DIR/sb.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_EOF

  cat > /etc/systemd/system/cloudflared-tunnel.service << SVC_EOF
[Unit]
Description=Cloudflare Tunnel for VLESS
After=sing-box-vless.service
Wants=sing-box-vless.service

[Service]
Type=simple
ExecStart=/root/start-cloudflared.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

  systemctl daemon-reload
  systemctl enable sing-box-vless cloudflared-tunnel 2>/dev/null || true
  systemctl start sing-box-vless 2>/dev/null || true
  sleep 2
  systemctl start cloudflared-tunnel 2>/dev/null || true
  sleep 3
else
  info "PM2 和 systemd 均不可用，使用 nohup 后台运行"
  nohup /root/start-sing-box.sh > /tmp/sing-box-vless.log 2>&1 &
  sleep 2
  nohup /root/start-cloudflared.sh > /tmp/cloudflared-tunnel.log 2>&1 &
  sleep 3
fi

# 修复 /etc/hosts
fix_hosts

# 检查状态
if command -v pm2 >/dev/null 2>&1 || command -v /usr/local/bin/pm2 >/dev/null 2>&1; then
  PM2_BIN=$(command -v pm2 || echo "/usr/local/bin/pm2")
  echo ""
  "$PM2_BIN" list
else
  for PROC in "sing-box" "cloudflared"; do
    if pgrep -f "$PROC" >/dev/null 2>&1; then
      echo -e "  ${GREEN}[OK]${NC} $PROC 运行中 (PID: $(pgrep -f "$PROC" | head -1))"
    else
      echo -e "  ${RED}[FAIL]${NC} $PROC 未运行"
    fi
  done
fi

# ================================================================
# Step 7 — 连通性测试
# ================================================================
step "Step 7/10 — 连通性测试"

LOCAL_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SB_PORT/" 2>/dev/null || echo "FAIL")
echo "  本地 sing-box: HTTP $LOCAL_HTTP (404=正常)"

CF_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$CF_HOST/" 2>/dev/null || echo "FAIL")
CF_WS=$(curl -s --http1.1 --max-time 10 -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  "https://$CF_HOST$WS_PATH" -o /dev/null -w '%{http_code}' 2>/dev/null || echo "FAIL")
echo "  CF HTTP: $CF_HTTP | CF WebSocket: $CF_WS (101=成功)"

[ "$CF_WS" = "101" ] && echo -e "  ${GREEN}[OK] CF 隧道连通性测试通过 ✓${NC}" || \
  echo -e "  ${YELLOW}[WARN] CF 隧道可能需要几分钟初始化${NC}"

# ================================================================
# Step 8 — 生成 sub.txt
# ================================================================
step "Step 8/10 — 生成 sub.txt"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")
VLESS_URL="vless://${UUID}@${PREF_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"

cat > "$SUB_FILE" << SUBEOF
========================================
  VLESS Tunnel Deploy Toolkit v2.3
  生成: $(date '+%Y-%m-%d %H:%M:%S')
  VPS:  $PUBLIC_IP | 隧道: $TUNNEL_NAME
========================================

【配置一】VLESS + WS（无分片，直接粘贴）
  地址:  $PREF_DOMAIN
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

【配置二】VLESS + WS（需开启 Fragment 分片）
  与配置一相同，在客户端节点设置中开启:
  分片: tlshello 100-200 / 10-20ms

  分享链接:
  $VLESS_URL#配置二-分片

--- 管理命令 ---
  查询节点:  cat /root/sub.txt
  换优选域名: bash gen_links.sh <新域名>
  查看日志:  pm2 logs            (或 tail -f /tmp/sing-box-vless.log)
  重启节点:  pm2 restart all
  停止节点:  pm2 stop all
  卸载清理:  bash $0 uninstall

========================================
SUBEOF

chmod 600 "$SUB_FILE"
info "已写入 $SUB_FILE"
echo ""
cat "$SUB_FILE"

# ================================================================
# Step 9 — 完成
# ================================================================
step "Step 9/10 — 部署完成"

cat << DONE
╔═══════════════════════════════════════════════════════════╗
║                  部署成功！v2.5                           ║
╠═══════════════════════════════════════════════════════════╣
║                                                           ║
║   sing-box:  监听 $SB_PORT 端口 (127.0.0.1)            ║
║   cloudflared: CF隧道 $TUNNEL_NAME 已建立               ║
║   守护进程: PM2（主） / systemd（兜底）                  ║
║   sub.txt:  /root/sub.txt                                ║
║                                                           ║
║   客户端配置:                                             ║
║   • V2RayN / Karing: 粘贴上方分享链接                    ║
║   • CF优选域名:  填入地址栏                               ║
║   • Host/SNI:    保持 $CF_HOST 不变          ║
║   • 分片:        如需请开启 Fragment                       ║
║                                                           ║
║   查询:  cat /root/sub.txt                               ║
║   日志:  pm2 logs                                        ║
║   重启:  pm2 restart all                                 ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
DONE

echo ""
info "后续可选配置："
echo "  查看 PM2 状态:  pm2 list"
echo "  实时日志:       pm2 logs"
echo "  重启服务:       pm2 restart all"
echo "  换优选域名:     bash gen_links.sh <新域名>"
echo "  卸载:           bash $0 uninstall"
echo ""
echo "  ${YELLOW}注意：重启 VPS/容器后，系统会自动拉起（PM2 startup / systemd）。${NC}"
echo "  ${YELLOW}如果 VPS 有 cron，可选用 30 分钟 cron 做额外兜底。${NC}"

# ── 匿名部署追踪（Beacon） ──
SCRIPT_VERSION="v2.5"
if [ "$NO_BEACON" != "1" ]; then
  (
    curl -s --max-time 4 \
      "${BEACON_URL}?v=${SCRIPT_VERSION}&a=$(uname -m 2>/dev/null || echo x)&o=$(uname -s 2>/dev/null || echo x)" \
      -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
      -H "Referer: https://github.com/" \
      -o /dev/null 2>&1 &
  ) &
  info "匿名部署追踪已上报（如需关闭：--no-beacon）"
else
  info "已跳过匿名部署追踪（--no-beacon）"
fi
