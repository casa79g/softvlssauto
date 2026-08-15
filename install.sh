#!/bin/bash
# ============================================================
# CF Tunnel + VLESS 自动部署脚本 v1.6
# 网络学习节点部署工具
# 用法: bash install.sh
# 无交互: export CF_TOKEN=... CF_HOST=... && bash install.sh
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
NON_INTERACTIVE=0
if [ -n "${CF_TOKEN:-}" ] && [ -n "${CF_HOST:-}" ]; then
  NON_INTERACTIVE=1
fi
ARCH=$(uname -m)
NOW=$(date +%Y-%m-%d_%H%M%S)
SB_DIR="/etc/sing-box"
SUB_FILE="/root/sub.txt"

# ── 检测 systemd 是否可用 ──
USE_SYSTEMD=0
if [ -d /run/systemd/system ] || systemctl is-system-running >/dev/null 2>&1; then
  USE_SYSTEMD=1
fi

# ── 启动后台进程（systemd 不可用时回退用）──
start_bg() {
  local name="$1"
  local cmd="$2"
  local log="$3"

  if [ "$USE_SYSTEMD" -eq 1 ]; then
    systemctl enable "$name.service" 2>/dev/null || true
    systemctl start "$name.service" 2>/dev/null || true
  else
    info "systemd 不可用，使用 nohup 后台运行"
    nohup $cmd >> "$log" 2>&1 &
    sleep 2
  fi
}

stop_bg() {
  local name="$1"
  if [ "$USE_SYSTEMD" -eq 1 ]; then
    systemctl stop "$name.service" 2>/dev/null || true
  else
    pkill -f "$name" 2>/dev/null || true
  fi
}

# ── 检查进程是否运行 ──
check_bg() {
  local pattern="$1"
  if [ "$USE_SYSTEMD" -eq 1 ]; then
    systemctl is-active --quiet "$(echo "$pattern" | cut -d'-' -f1)-vless" 2>/dev/null
  else
    pgrep -f "$pattern" >/dev/null 2>&1
  fi
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
# Step 2 — 端口扫描 + 自动释放
# ================================================================
step "Step 2/10 — 端口扫描"

scan_port() {
  if ss -tlnp "sport = :$1" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# 获取占用端口的进程信息
get_port_info() {
  local port="$1"
  ss -tlnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -1 || true
}

get_port_cmd() {
  local pid="$1"
  cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' | sed 's/ $//' || echo "unknown"
}

# 自动释放端口上的进程
kill_port_process() {
  local port="$1"
  local pid
  pid=$(get_port_info "$port")

  if [ -z "$pid" ]; then
    return 0  # 已经空闲
  fi

  local cmd
  cmd=$(get_port_cmd "$pid")

  # 如果是我们的服务，先用 systemd 停
  if echo "$cmd" | grep -q "sing-box"; then
    if systemctl is-active --quiet sing-box-vless 2>/dev/null; then
      info "检测到 sing-box-vless 服务占用 $port 端口，正在停止..."
      systemctl stop sing-box-vless.service 2>/dev/null || true
      sleep 1
    fi
  elif echo "$cmd" | grep -q "cloudflared"; then
    if systemctl is-active --quiet cloudflared-tunnel 2>/dev/null; then
      info "检测到 cloudflared-tunnel 服务占用 $port 端口，正在停止..."
      systemctl stop cloudflared-tunnel.service 2>/dev/null || true
      sleep 1
    fi
  fi

  # 再次检查
  if ! scan_port "$port"; then
    info "端口 $port 已释放"
    return 0
  fi

  # systemd 没停掉，直接 kill
  pid=$(get_port_info "$port")
  if [ -n "$pid" ]; then
    local cmd2
    cmd2=$(get_port_cmd "$pid")
    info "正在 kill 端口 $port 上的进程 (PID: $pid, 命令: ${cmd2:0:60})..."
    kill -9 "$pid" 2>/dev/null || true
    sleep 1
  fi

  # 最终验证
  if scan_port "$port"; then
    return 1  # 仍然占用
  else
    info "端口 $port 已释放"
    return 0
  fi
}

scan_all_ports() {
  local STATUS EXTRA pid cmd_info
  STATUS=""
  EXTRA=""

  printf "  ${GREEN}[INFO]${NC} 正在扫描常用端口...\n\n"
  printf "  %s┌──────────┬────────┬──────────────────────┐%s\n" "${BOLD}" "${NC}"
  printf "  %s│  端口    │ 状态   │ 占用进程            │%s\n" "${BOLD}" "${NC}"
  printf "  %s├──────────┼────────┼──────────────────────┤%s\n" "${BOLD}" "${NC}"

  for PORT in 80 443 8001 8002 8080 8443 3000; do
    if scan_port "$PORT"; then
      pid=$(get_port_info "$PORT") || true
      if [ -n "$pid" ]; then
        cmd_info=$(get_port_cmd "$pid" 2>/dev/null | sed 's/ /_/g' | cut -c1-20) || true
        STATUS="${RED}已占用${NC}"
        EXTRA="PID:$pid ${cmd_info:0:18}"
      else
        STATUS="${RED}已占用${NC}"
        EXTRA=""
      fi
    else
      STATUS="${GREEN}空闲${NC}"
      EXTRA=""
    fi
    printf "  %s│ %6d │ %-6s │ %-20s │%s\n" "${BOLD}" "$PORT" "$STATUS" "${EXTRA}" "${NC}"
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

# 自动释放被占用的端口
echo ""
if [ "$NON_INTERACTIVE" -eq 1 ]; then
  # 无交互模式：自动释放推荐端口
  info "无交互模式：自动释放推荐端口 $SUGGEST_PORT ..."
  if scan_port "$SUGGEST_PORT"; then
    kill_port_process "$SUGGEST_PORT" || \
      warn "端口 $SUGGEST_PORT 释放失败，尝试备选端口..."
    if scan_port "$SUGGEST_PORT"; then
      # 尝试备选端口
      for alt_port in 8080 8443 3000; do
        if ! scan_port "$alt_port"; then
          SUGGEST_PORT="$alt_port"
          break
        fi
        kill_port_process "$alt_port" 2>/dev/null
        if ! scan_port "$alt_port"; then
          SUGGEST_PORT="$alt_port"
          break
        fi
      done
      info "切换到端口 $SUGGEST_PORT"
    fi
  fi
  SB_PORT="$SUGGEST_PORT"
else
  # 交互模式
  read -rp "  sing-box 监听端口（推荐 ${CYAN}${SUGGEST_PORT}${NC}，回车使用默认）: ["$SUGGEST_PORT"]" SB_PORT
  SB_PORT="${SB_PORT:-$SUGGEST_PORT}"

  if scan_port "$SB_PORT"; then
    echo -e "  ${YELLOW}[INFO]端口 $SB_PORT 被占用，尝试自动释放${NC}"
    if kill_port_process "$SB_PORT"; then
      info "端口 $SB_PORT 已释放"
    else
      warn "端口 $SB_PORT 释放失败"
      # 推荐备选
      for alt_port in 8080 8443 3000 9001 9002; do
        if ! scan_port "$alt_port"; then
          read -rp "  备选端口 $alt_port 空闲，是否使用？[Y/n]: " USE_ALT
          if [ "${USE_ALT:-Y}" = "n" ]; then
            continue
          else
            SB_PORT="$alt_port"
            break
          fi
        else
          info "备选端口 $alt_port 也被占用，尝试释放..."
          kill_port_process "$alt_port" 2>/dev/null
          if ! scan_port "$alt_port"; then
            read -rp "  备选端口 $alt_port 已释放，是否使用？[Y/n]: " USE_ALT
            if [ "${USE_ALT:-Y}" = "n" ]; then
              continue
            else
              SB_PORT="$alt_port"
              break
            fi
          fi
        fi
      done
      # 如果所有备选都失败
      if scan_port "$SB_PORT"; then
        error "所有推荐端口均无法使用，请手动释放端口后重试"
      fi
    fi
  fi
fi

info "sing-box 将监听端口: $SB_PORT"

# ================================================================
# Step 2.5 — 网络检测
# ================================================================
step "Step 2.5/10 — 网络检测"

GITHUB_REACHABLE=0
NAS_REACHABLE=0

# 检测 GitHub 可达性
curl -sI --max-time 5 https://github.com >/dev/null 2>&1 && GITHUB_REACHABLE=1

# 检测 NAS 本地源可达性
NAS_BASE="${NAS_BASE:-http://47.84.122.196:8900}"
curl -sI --max-time 5 "${NAS_BASE}/sing-box" >/dev/null 2>&1 && NAS_REACHABLE=1

echo "  ${GREEN}[INFO]${NC} 下载源检测:"
if [ "$NAS_REACHABLE" -eq 1 ]; then
  echo "  ${GREEN}  ✓ NAS 本地源: $NAS_BASE 可达（优先使用）${NC}"
else
  echo "  ${YELLOW}  ✗ NAS 本地源: 不可达${NC}"
fi
if [ "$GITHUB_REACHABLE" -eq 1 ]; then
  echo "  ${GREEN}  ✓ GitHub: 可达${NC}"
else
  echo "  ${YELLOW}  ✗ GitHub: 不可达（将通过 NAS 本地源下载）${NC}"
fi
if [ "$GITHUB_REACHABLE" -eq 0 ] && [ "$NAS_REACHABLE" -eq 0 ]; then
  error "所有下载源均不可达，请检查网络或 NAS HTTP 服务器是否运行"
fi

# ================================================================
# Step 3 — 下载二进制
# ================================================================
step "Step 3/10 — 下载二进制"

get_latest_release() {
  curl -sL "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name' 2>/dev/null || echo "$2"
}

# 映射 uname -m 到 release 文件名
if [ "$ARCH" = "x86_64" ]; then
  RELEASE_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
  RELEASE_ARCH="arm64"
else
  RELEASE_ARCH="$ARCH"
fi

# NAS 本地 HTTP 服务器地址（ECI 容器专用，普通 VPS 自动跳过）
NAS_BASE="${NAS_BASE:-http://47.84.122.196:8900}"

# 检测 NAS 是否可达
NAS_REACHABLE=0
curl -sI --max-time 5 "${NAS_BASE}/sing-box" >/dev/null 2>&1 && NAS_REACHABLE=1

# 下载 sing-box（tar.gz 格式，与 sing-box-yg 一致）
SB_VERSION="${SB_VERSION:-1.13.18}"
SB_TARBALL="sing-box-${SB_VERSION}-linux-${RELEASE_ARCH}.tar.gz"
SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${SB_TARBALL}"
SB_MIRROR="https://gitlab.com/rwkgyg/sing-box-yg/-/raw/main/${SB_TARBALL}"

info "下载 sing-box ..."
SB_DOWNLOAD_OK=0

# 优先从 NAS 下载（本地裸二进制）
if [ "$NAS_REACHABLE" -eq 1 ]; then
  curl -sL -o /usr/local/bin/sing-box "${NAS_BASE}/sing-box" --retry 2 2>/dev/null
  if [ -f /usr/local/bin/sing-box ] && [ "$(xxd -l 4 /usr/local/bin/sing-box 2>/dev/null | awk '{print $2}')" = "7f45" ]; then
    SB_DOWNLOAD_OK=1
    info "从 NAS 本地下载完成"
  fi
fi

# NAS 不可达则从 GitHub/GitLab 下载 tar.gz
if [ "$SB_DOWNLOAD_OK" -eq 0 ]; then
  mkdir -p /tmp/sb-dl
  SB_URLS=("$SB_URL" "$SB_MIRROR" "https://github.com/SagerNet/sing-box/releases/latest/download/${SB_TARBALL}")
  for try_url in "${SB_URLS[@]}"; do
    curl -sL -o /tmp/sb-dl/sing-box.tar.gz "$try_url" --retry 2 2>/dev/null
    if [ -f /tmp/sb-dl/sing-box.tar.gz ] && [ "$(xxd -l 2 /tmp/sb-dl/sing-box.tar.gz 2>/dev/null | awk '{print $2}')" = "1f8b" ]; then
      tar xzf /tmp/sb-dl/sing-box.tar.gz -C /tmp/sb-dl/ 2>/dev/null
      EXTRACTED=$(find /tmp/sb-dl -name "sing-box" -type f -size +1M 2>/dev/null | head -1)
      if [ -n "$EXTRACTED" ]; then
        cp "$EXTRACTED" /usr/local/bin/sing-box
        SB_DOWNLOAD_OK=1
        break
      fi
    fi
  done
  rm -rf /tmp/sb-dl
fi

[ "$SB_DOWNLOAD_OK" -eq 0 ] && error "sing-box 下载失败。请检查网络是否可以访问 GitHub；ECI 容器请确认 NAS 47.84.122.196:8900 可达"
chmod +x /usr/local/bin/sing-box
info "sing-box 下载完成"

# 下载 cloudflared
info "下载 cloudflared ..."
CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${RELEASE_ARCH}"
CF_MIRROR="https://gitlab.com/rwkgyg/sing-box-yg/-/raw/main/${RELEASE_ARCH}"
CF_DEB_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${RELEASE_ARCH}.deb"

CF_DOWNLOAD_OK=0

# 优先从 NAS 下载
if [ "$NAS_REACHABLE" -eq 1 ]; then
  curl -sL -o /usr/local/bin/cloudflared "${NAS_BASE}/cloudflared" --retry 2 2>/dev/null
  if [ -f /usr/local/bin/cloudflared ] && [ "$(xxd -l 4 /usr/local/bin/cloudflared 2>/dev/null | awk '{print $2}')" = "7f45" ]; then
    CF_DOWNLOAD_OK=1
    info "从 NAS 本地下载完成"
  fi
fi

# NAS 不可达则尝试裸二进制
if [ "$CF_DOWNLOAD_OK" -eq 0 ]; then
  CF_URLS=("$CF_URL" "$CF_MIRROR" "$CF_DEB_URL")
  for try_url in "${CF_URLS[@]}"; do
    curl -sL -o /tmp/cf-binary "$try_url" --retry 2 2>/dev/null
    if [ -f /tmp/cf-binary ] && [ "$(xxd -l 4 /tmp/cf-binary 2>/dev/null | awk '{print $2}')" = "7f45" ]; then
      cp /tmp/cf-binary /usr/local/bin/cloudflared
      CF_DOWNLOAD_OK=1
      break
    fi
  done
  rm -f /tmp/cf-binary
fi

[ "$CF_DOWNLOAD_OK" -eq 0 ] && error "cloudflared 下载失败。请检查网络是否可以访问 GitHub；ECI 容器请确认 NAS 47.84.122.196:8900 可达"
chmod +x /usr/local/bin/cloudflared
info "cloudflared 下载完成"

# ================================================================
# Step 4 — 参数配置
# ================================================================
step "Step 4/10 — 参数配置"

# --- TUNNEL_NAME ---
if [ -n "${TUNNEL_NAME:-}" ]; then
  info "已检测到环境变量 TUNNEL_NAME: $TUNNEL_NAME"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  TUNNEL_NAME="network-learning-node"
else
  read -rp "  1. 隧道名称（CF面板中的名字）: [arnegowl]" TUNNEL_NAME
  TUNNEL_NAME="${TUNNEL_NAME:-arnegowl}"
fi
TUNNEL_NAME="${TUNNEL_NAME:-arnegowl}"

# --- CF_TOKEN ---
if [ -n "${CF_TOKEN:-}" ]; then
  info "已检测到环境变量 CF_TOKEN"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  error "无交互模式需要设置 CF_TOKEN 环境变量"
else
  echo ""
  warn "提示：Token 较长（约200字符），请整段复制后粘贴，不要手动输入"
  echo -n "  2. 隧道 Token（eyJh... 开头，不回显，粘贴后回车）: "
  read -r CF_TOKEN
fi
[ -z "$CF_TOKEN" ] && error "Token 不能为空"

# --- CF_HOST ---
if [ -n "${CF_HOST:-}" ]; then
  info "已检测到环境变量 CF_HOST: $CF_HOST"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  error "无交互模式需要设置 CF_HOST 环境变量"
else
  read -rp "  3. CF 隧道域名（CF面板 ingress 的 hostname）: " CF_HOST
fi
[ -z "$CF_HOST" ] && error "CF 域名不能为空"

# --- SB_PORT ---
SB_PORT="${SB_PORT:-$SUGGEST_PORT}"

# --- WS_PATH ---
if [ -n "${WS_PATH:-}" ]; then
  info "已检测到环境变量 WS_PATH: $WS_PATH"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  WS_PATH="/proxy-$(openssl rand -hex 3 2>/dev/null || echo $((RANDOM*RANDOM % 99999)))"
  info "自动生成 WS_PATH: $WS_PATH"
else
  RANDOM_PATH="/proxy-$(openssl rand -hex 3 2>/dev/null || echo $((RANDOM*RANDOM % 99999)))"
  read -rp "  4. WebSocket 路径（回车自动生成 $CYAN$RANDOM_PATH${NC}）: ["$RANDOM_PATH"]" WS_PATH
  WS_PATH="${WS_PATH:-$RANDOM_PATH}"
fi

# --- UUID ---
if [ -n "${UUID:-}" ]; then
  info "已检测到环境变量 UUID"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)")
  info "自动生成 UUID"
else
  AUTO_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$(head -c 8 /dev/urandom | md5sum | cut -d' ' -f1)")
  read -rp "  5. UUID（回车自动生成）: ["$AUTO_UUID"]" UUID
  UUID="${UUID:-$AUTO_UUID}"
fi

# --- PREF_DOMAIN ---
if [ -n "${PREF_DOMAIN:-}" ]; then
  info "已检测到环境变量 PREF_DOMAIN: $PREF_DOMAIN"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  PREF_DOMAIN="cf.godns.cc"
else
  read -rp "  6. CF优选域名（地址/Host/SNI均使用，默认 ${CYAN}cf.godns.cc${NC}）: ["cf.godns.cc"]" PREF_DOMAIN
  PREF_DOMAIN="${PREF_DOMAIN:-cf.godns.cc}"
fi

# --- USE_GRPC ---
if [ -n "${USE_GRPC:-}" ]; then
  info "已检测到环境变量 USE_GRPC: $USE_GRPC"
elif [ "$NON_INTERACTIVE" -eq 1 ]; then
  USE_GRPC="n"
else
  read -rp "  7. 是否启用 gRPC 入口？${YELLOW}(推荐 N，VLESS 已够用)${NC} [N]: " USE_GRPC
  USE_GRPC="${USE_GRPC:-n}"
fi

# --- 打印配置确认 ---
if [ "$NON_INTERACTIVE" -eq 0 ]; then
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
fi

# ================================================================
# Step 5 — 生成配置
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

if [ "$USE_GRPC" = "y" ] || [ "$USE_GRPC" = "Y" ]; then
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
    warn "sing-box 不支持 gRPC，跳过"
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

start_bg "sing-box-vless" "/usr/local/bin/sing-box run -c $SB_DIR/sb.json" "/tmp/sing-box-vless.log"
sleep 2

if pgrep -f 'sing-box' >/dev/null 2>&1; then
  info "sing-box 启动完成 (PID: $(pgrep -f 'sing-box' | head -1))"
else
  warn "sing-box 启动异常，请查看 /tmp/sing-box-vless.log"
fi

start_bg "cloudflared-tunnel" '/usr/local/bin/cloudflared tunnel run --token "$(cat /root/cf-tunnel.conf | grep CF_TOKEN | cut -d'"'"'"'"'"' -f2)" --protocol http2' "/tmp/cloudflared-tunnel.log"
sleep 3

if pgrep -f 'cloudflared' >/dev/null 2>&1; then
  info "cloudflared 启动完成 (PID: $(pgrep -f cloudflared | head -1))"
else
  warn "cloudflared 启动异常，请查看 /tmp/cloudflared-tunnel.log"
fi

CF_CONN=$(journalctl -u cloudflared-tunnel --no-pager -n 20 2>/dev/null | grep -ci "connected\|quic\|http2" || echo 0)
if [ "$USE_SYSTEMD" -eq 1 ]; then
  info "cloudflared 连接状态: $CF_CONN 条活动连接"
else
  info "cloudflared 连接状态: 请查看 /tmp/cloudflared-tunnel.log"
fi

# ================================================================
# Step 8 — 连通性测试
# ================================================================
step "Step 8/10 — 连通性测试"

info "测试本地 sing-box 端口 $SB_PORT ..."
LOCAL_HTTP=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$SB_PORT/" 2>/dev/null || echo "FAIL")
info "  HTTP 请求: $LOCAL_HTTP (正常返回404)"

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

VLESS_URL="vless://${UUID}@${PREF_DOMAIN}:443?encryption=none&security=tls&type=ws&host=${PREF_DOMAIN}&path=${WS_PATH}&sni=${PREF_DOMAIN}&fp=chrome"
VLESS_LINK1="${VLESS_URL}#配置一-无分片"
VLESS_LINK2="${VLESS_URL}#配置二-分片"

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
if [ "$USE_SYSTEMD" -eq 1 ]; then
  echo "  查看日志:    journalctl -u sing-box-vless -f"
  echo "  重启服务:    systemctl restart sing-box-vless cloudflared-tunnel"
  echo "  停止服务:    systemctl stop sing-box-vless cloudflared-tunnel"
else
  echo "  [nohup 模式] systemd 不可用，以下命令替代："
  echo "  查看日志:    tail -f /tmp/sing-box-vless.log"
  echo "  重启服务:    bash /root/softvlssauto/install.sh restart"
  echo "  停止服务:    pkill -f 'sing-box run'"
  echo "  重启后:     重新运行 install.sh（无 systemd 无法自动启动）"
fi
echo "  卸载清理:    bash $0 uninstall"