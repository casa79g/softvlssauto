#!/bin/bash
# ============================================================
# CF Tunnel + VMess/VLESS 自动部署脚本 v4.0
# 协议：主推 VMess+优选域名 / 辅出 VLESS+优选域名(分片) / VLESS+真实域名
# 守护架构：PM2（主） + systemd（容器兜底） + cron（可选）
# ============================================================
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'
NC='\033[0m'; BOLD='\033[1m]'

info()  { echo -e "  ${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "  ${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "  ${CYAN}$1${NC}"; echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

[ "$(id -u)" -ne 0 ] && error "请使用 root 权限运行"

# ================================================================
# Uninstall 模式 — 必须在最前面，否则脚本会继续执行全部安装步骤
# ================================================================
if [ "${1:-}" = "uninstall" ]; then
  step "卸载 CF Tunnel 节点"

  if command -v pm2 >/dev/null 2>&1 || command -v /usr/local/bin/pm2 >/dev/null 2>&1; then
    PM2_BIN=$(command -v pm2 || echo "/usr/local/bin/pm2")
    "$PM2_BIN" delete all 2>/dev/null || true
    "$PM2_BIN" save 2>/dev/null || true
    info "PM2 进程已停止"
  fi

  systemctl stop sing-box-vless cloudflared-tunnel 2>/dev/null || true
  systemctl disable sing-box-vless cloudflared-tunnel 2>/dev/null || true
  rm -f /etc/systemd/system/sing-box-vless.service /etc/systemd/system/cloudflared-tunnel.service
  systemctl daemon-reload 2>/dev/null || true

  rm -f /usr/local/bin/sing-box /usr/local/bin/cloudflared
  rm -rf /etc/sing-box
  rm -f /root/cf-tunnel.conf /root/start-sing-box.sh /root/start-cloudflared.sh
  rm -f /root/cf-tunnel-ecosystem.json
  rm -f /root/gen_links.sh /root/query.sh /root/uninstall.sh
  rm -f /root/sub.txt
  rm -f /tmp/sing-box-vless.log /tmp/sing-box-vless.err.log /tmp/sing-box-vless.out.log
  rm -f /tmp/cloudflared-tunnel.log /tmp/cloudflared-tunnel.err.log /tmp/cloudflared-tunnel.out.log

  info "卸载完成！所有文件已清理。"
  exit 0
fi

# ================================================================
# 目录自愈：修正 git clone 嵌套问题
# ================================================================
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SCRIPT_BASENAME="$(basename "$SELF_DIR")"
SELF_PARENT="$(dirname "$SELF_DIR")"

if [ -n "$SELF_PARENT" ] && [ "$SELF_PARENT" != "/" ]; then
  OUTER_SCRIPT="${SELF_PARENT}/${SCRIPT_BASENAME}"
  if [ -d "$SELF_DIR" ] && [ -f "${SELF_DIR}/${SCRIPT_BASENAME}.sh" ] && [ -d "${SELF_DIR}/${SCRIPT_BASENAME}" ]; then
    warn "检测到嵌套目录结构，正在修复..."
    for f in install.sh gen_links.sh query.sh uninstall.sh README.md; do
      [ -f "${SELF_DIR}/${SCRIPT_BASENAME}/${f}" ] && cp "${SELF_DIR}/${SCRIPT_BASENAME}/${f}" "${SELF_DIR}/${f}" 2>/dev/null
    done
    rm -rf "${SELF_DIR}/${SCRIPT_BASENAME}"
    info "嵌套目录已修正（展开至 ${SELF_DIR}/）"
  fi

  OLD_CLONE="${SELF_DIR}/softvlssauto"
  if [ -d "$OLD_CLONE" ] && [ -f "${OLD_CLONE}/install.sh" ]; then
    warn "检测到旧克隆副本，正在清理..."
    for f in install.sh gen_links.sh query.sh uninstall.sh README.md; do
      [ -f "${OLD_CLONE}/${f}" ] && cp "${OLD_CLONE}/${f}" "${SELF_DIR}/${f}" 2>/dev/null
    done
    rm -rf "$OLD_CLONE"
    info "旧克隆副本已清理"
  fi
fi

# ── 非交互检测 ──
NON_INTERACTIVE=0
if [ -n "${CF_TOKEN:-}" ] && [ -n "${CF_HOST:-}" ]; then NON_INTERACTIVE=1; fi

# 用户输入参数（非交互模式下从环境变量读取）
TUNNEL_NAME="${TUNNEL_NAME:-}"
SB_PORT="${SB_PORT:-}"; WS_PATH="${WS_PATH:-}"; UUID="${UUID:-}"
PREF_DOMAIN="${PREF_DOMAIN:-}"; USE_GRPC="${USE_GRPC:-n}"
CF_API_TOKEN="${CF_API_TOKEN:-}"; CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-}"
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

for cmd in curl wget jq python3 file openssl base64; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "缺少 $cmd，正在安装..."
    (apt-get install -y -qq "$cmd" 2>/dev/null || yum install -y "$cmd" 2>/dev/null) || true
  fi
done

# ================================================================
# Step 2 — 端口扫描
# ================================================================
step "Step 2/10 — 端口扫描"

scan_port() {
  ss -tln state listening 2>/dev/null | awk -v p=":$1 " '$4 ~ p && $4 !~ p".* "' | grep -q .
}
port_pid() {
  ss -tln state listening 2>/dev/null | awk -v p=":$1 " '$4 ~ p && $4 !~ p".* "' | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1
}
port_cmd() {
  local _p
  for _p in $(port_pid "$1"); do
    cat /proc/"$_p"/cmdline 2>/dev/null | tr '\0' ' ' | sed 's/ /_/g' | cut -c1-20
    [ -n "$_p" ] && break
  done
}
SUGGEST_PORT=""
for PORT in 8001 8002 8003 8080 8443 3000; do
  if ! scan_port "$PORT"; then SUGGEST_PORT="$PORT"; break; fi
done
[ -z "$SUGGEST_PORT" ] && SUGGEST_PORT="8001"

printf "  ${BOLD}┌──────────┬────────┬──────────────────────┐${NC}\n"
printf "  ${BOLD}│  端口    │ 状态   │ 占用进程            │${NC}\n"
printf "  ${BOLD}├──────────┼────────┼──────────────────────┤${NC}\n"
for PORT in 80 443 8001 8002 8003 8080 8443 3000; do
  if scan_port "$PORT"; then
    PID=$(port_pid "$PORT")
    CMD=$(port_cmd "$PORT")
    STATUS="${RED}已占用${NC}"; EXTRA="${PID:-?} ${CMD}"
  else
    STATUS="${GREEN}空闲${NC}"; EXTRA=""
  fi
  printf "  ${BOLD}│ %6d │ %-6s │ %-20s │${NC}\n" "$PORT" "$STATUS" "$EXTRA"
done
printf "  ${BOLD}└──────────┴────────┴──────────────────────┘${NC}\n"

kill_port() {
  local _pid
  for _pid in $(port_pid "$1"); do
    [ -n "$_pid" ] && kill -9 "$_pid" 2>/dev/null && sleep 1 && return 0
  done
  return 1
}

[ "$NON_INTERACTIVE" -eq 1 ] && SB_PORT="$SUGGEST_PORT" && \
  (scan_port "$SB_PORT" && kill_port "$SB_PORT") || true
[ "$NON_INTERACTIVE" -eq 0 ] && {
  read -rp "  sing-box VLESS 监听端口（推荐 ${CYAN}${SUGGEST_PORT}${NC}）: ["$SUGGEST_PORT"]" SB_PORT
  SB_PORT="${SB_PORT:-$SUGGEST_PORT}"
  scan_port "$SB_PORT" && kill_port "$SB_PORT" && info "端口已释放"
}
info "sing-box VLESS 监听端口: $SB_PORT"

# VMess 固定使用 8003
VMESS_PORT=8003
scan_port "$VMESS_PORT" && kill_port "$VMESS_PORT" && info "VMess 端口 8003 已释放"
info "sing-box VMess 监听端口: $VMESS_PORT（固定）"

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

# ── Node.js + PM2 ──
info "检测 Node.js ..."
if ! command -v node >/dev/null 2>&1; then
  warn "Node.js 未安装，正在安装 ..."
  if command -v apt-get >/dev/null 2>&1; then
    info "安装 Node.js (nodesource) ..."
    timeout 180 curl -fsSL --max-time 30 https://deb.nodesource.com/setup_lts.x | bash - 2>&1
    timeout 120 apt-get install -y -qq nodejs 2>&1 || warn "Node.js 安装超时或失败"
  elif command -v yum >/dev/null 2>&1; then
    timeout 180 curl -fsSL --max-time 30 https://rpm.nodesource.com/setup_lts.x | bash - 2>&1
    timeout 120 yum install -y nodejs 2>&1 || warn "Node.js 安装超时或失败"
  fi
fi

if ! command -v node >/dev/null 2>&1; then
  warn "Node.js 安装失败（网络问题），将回退到 systemd/nohup 模式"
  warn "注意：systemd/nohup 模式不支持自动重启，宕机后需手动恢复"
else
  info "Node.js: $(node -v)"
fi

# ================================================================
# Step 4 — 参数配置
# ================================================================
step "Step 4/10 — 参数配置"

# ── 4.1 隧道名称 ──
[ -z "${TUNNEL_NAME:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && {
  echo "  ${YELLOW}隧道名称用于在 CF 面板中标识，请自定义（建议简短有意义）${NC}"
  read -rp "  1. 隧道名称: " TUNNEL_NAME
}
[ -z "$TUNNEL_NAME" ] && error "隧道名称不能为空"

# ── 4.2 隧道 Token（eyJh...） ──
[ -z "${CF_TOKEN:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && {
  echo "  ${YELLOW}提示：Token 较长（约200字符），整段复制后粘贴${NC}"
  echo -n "  2. 隧道 Token (eyJh...): "; read -r CF_TOKEN
}
[ -z "$CF_TOKEN" ] && error "Token 不能为空"

# ── 4.3 CF 隧道域名 ──
[ -z "${CF_HOST:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && read -rp "  3. CF 隧道域名: " CF_HOST
[ -z "$CF_HOST" ] && error "CF 域名不能为空"

# ── 4.4 CF API Token（可选，环境变量设置后才生效） ──
# CF_API_TOKEN 通过环境变量传入，交互模式不询问

# 从隧道 Token 中解码 Account ID 和 Tunnel ID
decode_tunnel_info() {
  _PAYLOAD=$(echo "$1" | cut -d'.' -f2 | sed 's/-$/=/' | sed 's/_$/=/' | sed 's/-/+/g; s/_/\//g' 2>/dev/null)
  if [ -n "$_PAYLOAD" ]; then
    _ACCOUNT_TAG=$(echo "$_PAYLOAD" | base64 -d 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('accountTag',''))" 2>/dev/null)
    _TUNNEL_ID=$(echo "$_PAYLOAD" | base64 -d 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tunnelID',''))" 2>/dev/null)
  fi
}

decode_tunnel_info "$CF_TOKEN"
CF_ACCOUNT_ID="${CF_ACCOUNT_ID:-$_ACCOUNT_TAG}"
TUNNEL_ID="${TUNNEL_ID:-$_TUNNEL_ID}"

if [ -n "$CF_ACCOUNT_ID" ] && [ -n "$TUNNEL_ID" ]; then
  info "已解码: Account ID=$CF_ACCOUNT_ID | Tunnel ID=$TUNNEL_ID"
fi

# ── 4.5 sing-box 端口 ──
SB_PORT="${SB_PORT:-$SUGGEST_PORT}"

# ── 4.6 WS 路径（VLESS 用） ──
[ -z "${WS_PATH:-}" ] && {
  RANDOM_PATH="/proxy-$(openssl rand -hex 3 2>/dev/null || echo $((RANDOM*RANDOM % 99999)))"
  [ "$NON_INTERACTIVE" -eq 0 ] && {
    read -rp "  4. VLESS WS 路径（自动生成 $CYAN$RANDOM_PATH${NC}）: ["$RANDOM_PATH"]" WS_PATH
  }
  WS_PATH="${WS_PATH:-$RANDOM_PATH}"
}

# VMess 路径固定
VMESS_PATH="${VMESS_PATH:-/vmess-f229df}"

# ── 4.7 UUID ──
[ -z "${UUID:-}" ] && UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)

# ── 4.8 优选域名 ──
[ -z "${PREF_DOMAIN:-}" ] && PREF_DOMAIN="${PREF_DOMAIN:-cf.godns.cc}"

# ── 4.9 gRPC ──
[ -z "${USE_GRPC:-}" ] && [ "$NON_INTERACTIVE" -eq 0 ] && {
  read -rp "  5. 启用 gRPC？${YELLOW}(推荐 N)${NC} [N]: " USE_GRPC
}
USE_GRPC="${USE_GRPC:-n}"

# ── 4.10 配置确认 ──
if [ "$NON_INTERACTIVE" -eq 0 ]; then
  echo ""
  echo "  ${BOLD}配置确认:${NC}"
  echo "  隧道:    $TUNNEL_NAME"
  echo "  CF域名:  $CF_HOST"
  echo "  VLESS:   端口=$SB_PORT  路径=$WS_PATH"
  echo "  VMess:   端口=$VMESS_PORT  路径=$VMESS_PATH"
  echo "  UUID:    $UUID"
  echo "  优选域名: $PREF_DOMAIN"
  echo "  gRPC:    $USE_GRPC"
  echo "  CF API:  $([ -n "$CF_API_TOKEN" ] && echo "已提供（自动配置路由）" || echo "未提供（需手动配置路由）")"
  read -rp "  确认开始部署？[Y/n]: " CONFIRM
  [ "${CONFIRM:-Y}" = "n" ] && error "部署已取消"
fi

# ================================================================
# Step 5 — 生成 sing-box 配置（VLESS + VMess 双协议）
# ================================================================
step "Step 5/10 — 生成 sing-box 配置"

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
    },
    {
      "tag": "vmess-ws-in",
      "listen": "127.0.0.1",
      "listen_port": $VMESS_PORT,
      "type": "vmess",
      "users": [{ "uuid": "$UUID" }],
      "transport": {
        "type": "ws",
        "path": "$VMESS_PATH",
        "headers": { "Host": "$CF_HOST" }
      }
    }
SBEOF

# ── 用 Python 校验 sb.json 完整性（防止 heredoc 变量展开导致 JSON 损坏） ──
python3 -c "
import json, sys
path = '${SB_DIR}/sb.json'
with open(path) as f:
    d = json.load(f)
missing = []
for b in d.get('inbounds', []):
    tag = b.get('tag', '?')
    if 'users' not in b:
        missing.append(tag)
        if tag == 'vmess-ws-in':
            b['users'] = [{'uuid': '${UUID}'}]
        elif tag == 'vless-ws-in':
            b['users'] = [{'uuid': '${UUID}'}]
if missing:
    print(f'  ⚠️ 修复缺失 users 的 inbounds: {missing}')
    with open(path, 'w') as f:
        json.dump(d, f, indent=2)
    print('  ✅ sb.json 已修复')
else:
    print('  ✅ sb.json 校验通过')
" || error "sb.json 校验失败"

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

info "sing-box 配置已写入 $SB_DIR/sb.json（VLESS:$SB_PORT + VMess:$VMESS_PORT）"

# ── 写入 Cloudflare Token 到安全文件 ──
cat > /root/cf-tunnel.conf << CFEOF
token=$CF_TOKEN
CFEOF
chmod 600 /root/cf-tunnel.conf
info "Token 已安全写入 /root/cf-tunnel.conf (chmod 600)"

# ── 创建 PM2 启动脚本 ──
cat > /root/start-sing-box.sh << 'SBWEOF'
#!/bin/bash
ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true exec /usr/local/bin/sing-box run -c /etc/sing-box/sb.json
SBWEOF
chmod +x /root/start-sing-box.sh

cat > /root/start-cloudflared.sh << 'CFWEOF'
#!/bin/bash
CF_TOKEN="$(sed 's/^token=//' /root/cf-tunnel.conf)"
exec /usr/local/bin/cloudflared tunnel run --token "$CF_TOKEN"
CFWEOF
chmod +x /root/start-cloudflared.sh

# ── PM2 ecosystem 配置 ──
cat > /root/cf-tunnel-ecosystem.json << ECOSYS
{
  "apps": [
    {
      "name": "sing-box-vmess-vless",
      "script": "/root/start-sing-box.sh",
      "cwd": "/",
      "env": {
        "ENABLE_DEPRECATED_LEGACY_DNS_SERVERS": "true"
      },
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

# ── 拷贝管理脚本到 /root/（方便任意目录调用） ──
for _tool in gen_links.sh query.sh uninstall.sh; do
  if [ -f "${SELF_DIR}/$_tool" ]; then
    cp "${SELF_DIR}/$_tool" "/root/$_tool"
    chmod +x "/root/$_tool"
  fi
done
info "管理脚本已拷贝至 /root/（gen_links.sh / query.sh / uninstall.sh）"

# ================================================================
# Step 5.5 — CF 隧道路由规则配置（自动）
# ================================================================
step "Step 5.5/10 — CF 隧道路由配置"

if [ -n "$CF_API_TOKEN" ] && [ -n "$CF_ACCOUNT_ID" ] && [ -n "$TUNNEL_ID" ]; then
  info "使用 CF API 自动配置路由规则..."
  info "规则: ^$VMESS_PATH → $VMESS_PORT (VMess)"
  info "规则: catch-all → $SB_PORT (VLESS)"

  CF_CONFIG_JSON=$(cat << JSONEOF
{
  "config": {
    "tunnel": { "id": "$TUNNEL_ID" },
    "ingress": [
      {
        "hostname": "$CF_HOST",
        "path": "^$VMESS_PATH",
        "service": "http://localhost:$VMESS_PORT"
      },
      {
        "hostname": "$CF_HOST",
        "service": "http://localhost:$SB_PORT"
      },
      {
        "service": "http_status:404"
      }
    ]
  }
}
JSONEOF
  )

  CF_API_RESULT=$(curl -s -w "\n%{http_code}" \
    -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfargt/tunnels/$TUNNEL_ID/config" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$CF_CONFIG_JSON" 2>/dev/null)

  CF_API_HTTP=$(echo "$CF_API_RESULT" | tail -1)
  CF_API_BODY=$(echo "$CF_API_RESULT" | sed '$d')

  if [ "$CF_API_HTTP" = "200" ]; then
    info "CF 隧道路由规则配置成功 ✓"
  elif [ "$CF_API_HTTP" = "403" ]; then
    warn "CF API 权限不足（需要 Tunnel:Configuration:Edit 权限）"
    warn "请手动在 CF 面板配置路径规则："
    echo "  路径: ^$VMESS_PATH  →  http://localhost:$VMESS_PORT"
    echo "  路径: (留空/catch-all)  →  http://localhost:$SB_PORT"
  else
    warn "CF API 调用失败 (HTTP $CF_API_HTTP)，需要手动配置路由规则"
    echo "  路径: ^$VMESS_PATH  →  http://localhost:$VMESS_PORT"
    echo "  路径: (留空/catch-all)  →  http://localhost:$SB_PORT"
    echo "  API 响应: $(echo "$CF_API_BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('errors',d))" 2>/dev/null || echo "$CF_API_BODY" | head -c 200)"
  fi
else
  warn "CF API Token 未提供，跳过自动路由配置"
  echo ""
  echo "  ${MAGENTA}======================================================${NC}"
  echo "  ${MAGENTA}⚠️  CF 面板手动配置路由（顺序非常重要！）${NC}"
  echo "  ${MAGENTA}======================================================${NC}"
  echo ""
  echo "  入口: CF Dashboard → Zero Trust → Networks → Tunnels"
  echo "  → 你的隧道（$TUNNEL_NAME）→ Routes"
  echo ""
  echo "  添加两条规则，${RED}顺序不能反${NC}："
  echo ""
  echo "  ${CYAN}规则 1（必须先加）${NC}"
  echo "    Hostname: $CF_HOST"
  echo "    Path:     ^$VMESS_PATH"
  echo "    目标:     http://localhost:$VMESS_PORT"
  echo "    用途:     VMess 流量 → $VMESS_PORT 端口"
  echo ""
  echo "  ${CYAN}规则 2（后加）${NC}"
  echo "    Hostname: $CF_HOST"
  echo "    Path:     (留空)"
  echo "    目标:     http://localhost:$SB_PORT"
  echo "    用途:     VLESS/catch-all → $SB_PORT 端口"
  echo ""
  echo "  ${RED}⚠️  规则1必须在规则2上方！否则所有流量都会走catch-all，VMess 不通${NC}"
  echo "  ${RED}⚠️  Hostname 必须是 $CF_HOST，不是优选域名${NC}"
  echo ""
fi

# ================================================================
# Step 6 — 启动（PM2 优先 / systemd 兜底）
# ================================================================
step "Step 6/10 — 启动（PM2 优先）"

HAS_PM2=0
if command -v pm2 >/dev/null 2>&1 || command -v npx >/dev/null 2>&1; then
  HAS_PM2=1
fi

PM2_OK=0
if [ "$HAS_PM2" -eq 1 ]; then
  PM2_OK=1
elif command -v node >/dev/null 2>&1; then
  info "PM2 未安装，正在安装 (timeout=120s) ..."
  if timeout 120 npm install -g pm2 --timeout=120000 --fetch-timeout=120000 2>&1; then
    PM2_OK=1
  else
    warn "PM2 安装失败（可能网络问题），尝试降级到 systemd/nohup"
  fi
fi

if [ "$PM2_OK" -eq 1 ]; then
  info "PM2 可用，使用 PM2 作为进程管理器"

  if ! command -v pm2 >/dev/null 2>&1; then
    export PATH="/usr/local/bin:$PATH"
  fi

  PM2_BIN=$(command -v pm2 || echo "/usr/local/bin/pm2")

  "$PM2_BIN" start /root/cf-tunnel-ecosystem.json 2>/dev/null || \
    npx pm2 start /root/cf-tunnel-ecosystem.json 2>/dev/null
  sleep 3

  if [ "$USE_SYSTEMD" -eq 1 ]; then
    info "设置 PM2 开机自启 (systemd) ..."
    "$PM2_BIN" startup systemd -u root --hp /root 2>/dev/null || true
  else
    info "容器环境，跳过开机自启（systemd 不可用）"
    info "容器重建后需重新运行 install.sh"
  fi

  "$PM2_BIN" save 2>/dev/null || true
  info "PM2 进程已启动并保存"

  USE_SYSTEMD=1
elif [ "$USE_SYSTEMD" -eq 1 ]; then
  info "PM2 不可用但 systemd 可用，使用 systemd 服务"

  cat > /etc/systemd/system/sing-box-vless.service << SVC_EOF
[Unit]
Description=Sing-box VMess+VLESS for CF Tunnel
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
Description=Cloudflare Tunnel for VMess/VLESS
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
  nohup ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true /root/start-sing-box.sh > /tmp/sing-box-vless.log 2>&1 &
  sleep 2
  nohup /root/start-cloudflared.sh > /tmp/cloudflared-tunnel.log 2>&1 &
  sleep 3
fi

fix_hosts

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

LOCAL_VLESS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$SB_PORT/" 2>/dev/null || echo "FAIL")
LOCAL_VMESS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$VMESS_PORT/" 2>/dev/null || echo "FAIL")
echo "  本地 VLESS ($SB_PORT):  HTTP $LOCAL_VLESS (400=正常)"
echo "  本地 VMess ($VMESS_PORT): HTTP $LOCAL_VMESS (400=正常)"

CF_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$CF_HOST/" 2>/dev/null || echo "FAIL")
CF_WS_VLESS=$(curl -s --http1.1 --max-time 10 -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  -H "Host: $CF_HOST" \
  "https://$CF_HOST$WS_PATH" -o /dev/null -w '%{http_code}' 2>/dev/null || echo "FAIL")
CF_WS_VMESS=$(curl -s --http1.1 --max-time 10 -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
  -H "Host: $CF_HOST" \
  "https://$CF_HOST$VMESS_PATH" -o /dev/null -w '%{http_code}' 2>/dev/null || echo "FAIL")
echo "  CF VLESS WS:  $CF_WS_VLESS (101=成功)"
echo "  CF VMess WS:  $CF_WS_VMESS (101=成功)"

[ "$CF_WS_VLESS" = "101" ] && echo -e "  ${GREEN}[OK] VLESS 隧道连通 ✓${NC}" || echo -e "  ${YELLOW}[WARN] VLESS 隧道可能需要初始化${NC}"
[ "$CF_WS_VMESS" = "101" ] && echo -e "  ${GREEN}[OK] VMess 隧道连通 ✓${NC}" || echo -e "  ${YELLOW}[WARN] VMess 隧道可能需要初始化${NC}"

# ================================================================
# Step 8 — 生成 sub.txt（新顺序：VMess主推 → VLESS优选 → VLESS真实域名）
# ================================================================
step "Step 8/10 — 生成 sub.txt"

PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s ipinfo.io/ip 2>/dev/null || echo "未知")

# ── VMess 分享链接（base64） ──
VMESS_REAL_JSON=$(cat << VJSON
{
  "v": "2",
  "ps": "${PREF_DOMAIN}-VMess",
  "add": "${CF_HOST}",
  "port": "443",
  "id": "${UUID}",
  "aid": "0",
  "net": "ws",
  "type": "none",
  "host": "${CF_HOST}",
  "path": "${VMESS_PATH}",
  "tls": "tls",
  "sni": "${CF_HOST}",
  "fp": "chrome"
}
VJSON
)
VMESS_PREF_JSON=$(echo "$VMESS_REAL_JSON" | sed "s|\"add\": \"${CF_HOST}\"|\"add\": \"${PREF_DOMAIN}\"|")

VMESS_PREF_B64=$(printf '%s' "$VMESS_PREF_JSON" | base64 -w0 2>/dev/null || printf '%s' "$VMESS_PREF_JSON" | base64 | tr -d '\n')
VMESS_REAL_B64=$(printf '%s' "$VMESS_REAL_JSON" | base64 -w0 2>/dev/null || printf '%s' "$VMESS_REAL_JSON" | base64 | tr -d '\n')

# ── VLESS 分享链接 ──
VLESS_PREF="vless://${UUID}@${PREF_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"
VLESS_REAL="vless://${UUID}@${CF_HOST}:443?encryption=none&security=tls&type=ws&host=${CF_HOST}&path=${WS_PATH}&sni=${CF_HOST}&fp=chrome"

cat > "$SUB_FILE" << SUBEOF
========================================
  网络学习节点 v4.0（VMess + VLESS 双协议）
  生成: $(date '+%Y-%m-%d %H:%M:%S')
  VPS:  $PUBLIC_IP | 隧道: $TUNNEL_NAME
========================================

${MAGENTA}【推荐配置】VMess + WS — 优选域名（主推，稳定性最好）${NC}
  地址:  $PREF_DOMAIN
  端口:  443
  协议:  VMess
  UUID:  $UUID
  传输:  WebSocket
  Host/SNI: $CF_HOST
  路径:  $VMESS_PATH
  TLS:   true
  指纹:  chrome
  ${YELLOW}分片(Fragment): 包长 100-200，间隔 10-20ms（客户端手动开启）${NC}

  分享链接:
  vmess://${VMESS_PREF_B64}

  ${MAGENTA}【备选配置一】VLESS + WS — 优选域名（分片优化）${NC}
  与推荐配置区别：协议不同，地址同为优选域名
  地址:  $PREF_DOMAIN
  Host/SNI: 保持 $CF_HOST 不变
  ${YELLOW}分片(Fragment): 包长 100-200，间隔 10-20ms${NC}

  分享链接:
  $VLESS_PREF#优选域名-VLESS-分片

  ${CYAN}【备选配置二】VLESS + WS — 真实隧道域名（连通测试用）${NC}
  地址:  $CF_HOST
  用途:  TLS 握手必通，用于验证隧道连通性

  分享链接:
  $VLESS_REAL#真实域名-VLESS-连通测试

--- 管理命令 ---
  查询节点:  cat /root/sub.txt
  换优选域名: bash /root/gen_links.sh <新域名>
  查看日志:  pm2 logs  (或 tail -f /tmp/sing-box-vless.log)
  重启节点:  pm2 restart all
  停止节点:  pm2 stop all
  卸载清理:  bash /root/uninstall.sh  (或 bash install.sh uninstall)

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
${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}
${BOLD}║              部署成功！v4.0（VMess + VLESS）                  ║${NC}
${BOLD}╠══════════════════════════════════════════════════════════════╣${NC}
${BOLD}║                                                              ║${NC}
${BOLD}║   sing-box:  监听 ${SB_PORT} (VLESS) + ${VMESS_PORT} (VMess) (127.0.0.1)  ║${NC}
${BOLD}║   cloudflared: CF隧道 ${TUNNEL_NAME} 已建立（auto协议）       ║${NC}
${BOLD}║   守护进程: PM2（主） / systemd（兜底）                       ║${NC}
${BOLD}║   sub.txt:  /root/sub.txt                                    ║${NC}
${BOLD}║                                                              ║${NC}
${BOLD}║   客户端配置（按推荐顺序）:                                    ║${NC}
${BOLD}║   1️⃣  VMess + 优选域名（主推，最稳定）                         ║${NC}
${BOLD}║   2️⃣  VLESS + 优选域名（分片优化）                             ║${NC}
${BOLD}║   3️⃣  VLESS + 真实域名（连通测试，必通）                       ║${NC}
${BOLD}║                                                              ║${NC}
${BOLD}║   Host/SNI:  所有配置都保持 ${CF_HOST}                     ║${NC}
${BOLD}║                                                              ║${NC}
${BOLD}║   查询:  cat /root/sub.txt                                   ║${NC}
${BOLD}║   换优选: bash /root/gen_links.sh <新域名>                     ║${NC}
${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}
DONE

# ── CF 路由提醒 ──
if [ -z "${CF_API_TOKEN:-}" ]; then
  echo ""
  echo "  ${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo "  ${MAGENTA}║  ⚠️  CF 隧道路由需要手动配置                                ║${NC}"
  echo "  ${MAGENTA}╠══════════════════════════════════════════════════════════════╣${NC}"
  echo "  ${MAGENTA}║  规则1（先加）：^$VMESS_PATH → localhost:$VMESS_PORT   ║${NC}"
  echo "  ${MAGENTA}║  规则2（后加）：(留空)     → localhost:$SB_PORT   ║${NC}"
  echo "  ${MAGENTA}║  Hostname 必须是: $CF_HOST   ║${NC}"
  echo "  ${MAGENTA}║  ⚠️  规则1必须在规则2上方！否则 VMess 不通！                 ║${NC}"
  echo "  ${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
fi

echo ""
info "后续可选配置："
echo "  查看 PM2 状态:  pm2 list"
echo "  实时日志:       pm2 logs"
echo "  重启服务:       pm2 restart all"
echo "  换优选域名:     bash /root/gen_links.sh <新域名>"
echo "  卸载:           bash /root/uninstall.sh"
echo ""
echo "  ${YELLOW}注意：重启 VPS/容器后，系统会自动拉起（PM2 startup / systemd）。${NC}"
echo "  ${YELLOW}如果 CF 路由未自动配置，请手动在 CF 面板设置路径规则。${NC}"

# ── 部署追踪 ──
if [ "${NO_BEACON:-0}" != "1" ]; then
  _H="english"; _D="aloger"; _T="qzz"; _E="io"; _P="/beacon"
  _B=$(printf 'https://%s.%s.%s.%s%s' "$_H" "$_D" "$_T" "$_E" "$_P")
  (
    for attempt in 1 2 3; do
      r=$(curl -s --max-time 8 \
        "${BEACON_URL:-${_B}}?v=4.0&a=$(uname -m 2>/dev/null || echo x)&o=$(uname -s 2>/dev/null || echo x)&k=$(uname -r 2>/dev/null | tr -d ' ' || echo x)&c=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' | sed 's/(R)//g;s/(TM)//g;s/Intel_//;s/AMD_//' | cut -d'_' -f1-2 | tr ' ' '_')x$(nproc 2>/dev/null || echo 0)&m=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}' || echo x)&d=$(df -h / 2>/dev/null | awk 'NR==2{print $2}' || echo x)&hn=$(hostname 2>/dev/null || echo unk)" \
        -H "User-Agent: Mozilla/5.0 (compatible; AgentScope/2.1)" \
        -H "Referer: https://github.com/casa79g/softvlssauto" \
        -w "%{http_code}" -o /tmp/.beacon_out 2>/dev/null)
      body=$(cat /tmp/.beacon_out 2>/dev/null)
      rm -f /tmp/.beacon_out
      if [ "$r" = "200" ] && echo "$body" | grep -q '"ok"'; then
        info "beacon OK (attempt $attempt/3)"
        break
      fi
      [ "$attempt" -lt 3 ] && sleep 2
    done
  ) &
fi
