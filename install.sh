#!/bin/bash
# ============================================================
# softvlssauto v5.0 — 智能导航版 (IPv4/IPv6 双栈自适应)
# 协议: VLESS+Reality(xray) / Hysteria2(sing-box) / VLESS+VMess+WS(CF Tunnel)
# 用法: curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
#       (curl|bash 会自动保存为 /root/softvlssauto.sh 再以交互模式重启)
# ============================================================
set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; MAGENTA='\033[0;35m'
NC='\033[0m'; BOLD='\033[1m'
info()  { echo -e "  ${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "  ${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "  ${CYAN}$1${NC}"; echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SELF="/root/softvlssauto.sh"

# ── curl|bash 模式自动转交互 (交互菜单需要真实 tty stdin) ──
if [ ! -t 0 ]; then
  cat > "$SELF"
  chmod +x "$SELF"
  echo -e "${CYAN}[INFO] 脚本已保存到 $SELF , 以交互模式重新启动...${NC}"
  exec bash "$SELF" "$@"
fi

[ "$(id -u)" -ne 0 ] && err "请使用 root 权限运行"

SB_VER="1.13.18"
ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && RARCH=amd64 || RARCH=arm64
UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)

# ================================================================
# Phase 1 — 环境扫描 (全部非交互)
# ================================================================
scan_env() {
  step "Phase 1/4 — 环境扫描"

  SYS=$(grep -oP '(?<=^NAME=")[^"]*' /etc/os-release 2>/dev/null || echo "Linux")
  info "系统: $SYS | 架构: $ARCH | 内核: $(uname -r)"
  info "磁盘: $(df -h / | awk 'NR==2{print "可用 "$4" / 总计 "$2}')"

  # 依赖自动安装
  for cmd in curl openssl python3; do
    command -v "$cmd" >/dev/null 2>&1 || { warn "缺少 $cmd, 安装..."; apt-get install -y -qq "$cmd" 2>/dev/null || yum install -y "$cmd" 2>/dev/null || true; }
  done

  # ---- 网络: 出站 ----
  V4_OUT=1; V6_OUT=1
  curl -4 -s --max-time 6 -o /dev/null https://www.cloudflare.com || V4_OUT=0
  curl -6 -s --max-time 6 -o /dev/null https://www.cloudflare.com || V6_OUT=0
  [ "$V4_OUT" -eq 1 ] && echo -e "  出站 IPv4: ${GREEN}✓ 可用${NC}" || echo -e "  出站 IPv4: ${RED}✗ 不可达${NC}"
  [ "$V6_OUT" -eq 1 ] && echo -e "  出站 IPv6: ${GREEN}✓ 可用${NC}" || echo -e "  出站 IPv6: ${RED}✗ 不可达${NC}"

  # ---- 网络: 入站公网地址 (能不能被客户端直连) ----
  HAS_PUB4=0; HAS_PUB6=0
  PUB4=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+' | head -1)
  PUB6=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6 )\S+' | grep -v '^fe80' | head -1)
  [ -n "$PUB4" ] && HAS_PUB4=1
  [ -n "$PUB6" ] && HAS_PUB6=1
  [ "$HAS_PUB4" -eq 1 ] && echo -e "  入站 IPv4: ${GREEN}✓ $PUB4${NC}" || echo -e "  入站 IPv4: ${RED}✗ 无公网地址${NC}"
  [ "$HAS_PUB6" -eq 1 ] && echo -e "  入站 IPv6: ${GREEN}✓ $PUB6${NC}" || echo -e "  入站 IPv6: ${RED}✗ 无公网地址${NC}"

  # ---- v4 出站不可用时: DNS64 自动适配 (今晚实测的坑) ----
  if [ "$V4_OUT" -eq 0 ] && [ "$V6_OUT" -eq 1 ]; then
    warn "IPv6-only 环境: 自动启用 DNS64+NAT64 (v4-only 网站可达)"
    cp /etc/resolv.conf /etc/resolv.conf.bak-softvlss 2>/dev/null || true
    printf 'nameserver 2a00:1098:2b::1\nnameserver 2a01:4f9:c010:3f66::1\n' > /etc/resolv.conf
    info "DNS64 已配置"
  fi

  # ---- 端口占用扫描 ----
  echo -e "  ${BOLD}端口扫描:${NC}"
  PORT_FREE=""
  for PORT in 443 80 8443 8001 8003; do
    if ss -tlnu 2>/dev/null | grep -q ":$PORT "; then
      echo -e "    $PORT: ${RED}占用${NC}"
    else
      echo -e "    $PORT: ${GREEN}空闲${NC}"
      [ -z "$PORT_FREE" ] && PORT_FREE=$PORT
    fi
  done
  [ -z "$PORT_FREE" ] && PORT_FREE=8443
}

# ================================================================
# Phase 2 — 扫描结论 (能跑什么)
# ================================================================
show_verdict() {
  step "Phase 2/4 — 扫描结论 (本机可跑的协议)"
  echo ""
  if [ "$HAS_PUB4" -eq 1 ] || [ "$HAS_PUB6" -eq 1 ]; then
    echo -e "  ${GREEN}✔ 直连类协议可用${NC} (客户端需能直连本机公网地址):"
    echo -e "     • VLESS + Reality (TCP)   — 抗封锁首选, 无需证书"
    echo -e "     • Hysteria2 (UDP/QUIC)    — 高丢包链路最快 (Brutal)"
    [ "$HAS_PUB4" -eq 0 ] && echo -e "     ${YELLOW}⚠ 本机无 IPv4 入站: 仅 IPv6 客户端可直连${NC}"
  else
    echo -e "  ${RED}✗ 无公网入站 (NAT 后面)${NC} — 直连类协议不可用"
  fi
  echo -e "  ${GREEN}✔ CF Tunnel 架构可用${NC} (客户端经 Cloudflare, 无需直连本机):"
  echo -e "     • VLESS + VMess + WS      — 任意网络可达, 需你提供 Tunnel Token"
  echo ""
  echo -e "  出站提醒: IPv4 出站不可用时自动走 DNS64 (已配置)"
  echo ""
}

# ================================================================
# 下载工具 (sing-box / xray / cloudflared)
# ================================================================
fetch_url() {
  local url="$1" out="$2"
  curl -fsSL --connect-timeout 10 --max-time 300 -o "$out" "$url" 2>/dev/null && return 0
  curl -fsSL --connect-timeout 10 --max-time 300 -o "$out" "https://ghproxy.net/$url" 2>/dev/null && return 0
  return 1
}

install_singbox() {
  command -v /usr/local/bin/sing-box >/dev/null 2>&1 && { info "sing-box 已安装"; return 0; }
  local tar="sing-box-${SB_VER}-linux-${RARCH}.tar.gz"
  mkdir -p /tmp/sbdl
  fetch_url "https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${tar}" "/tmp/sbdl/sb.tar.gz" || { err "sing-box 下载失败"; return 1; }
  tar xzf /tmp/sbdl/sb.tar.gz -C /tmp/sbdl
  find /tmp/sbdl -name sing-box -type f | head -1 | xargs -I{} cp {} /usr/local/bin/sing-box
  chmod +x /usr/local/bin/sing-box; rm -rf /tmp/sbdl
  info "sing-box: $(/usr/local/bin/sing-box version | head -1)"
}

install_xray() {
  command -v /usr/local/bin/xray >/dev/null 2>&1 && { info "xray 已安装"; return 0; }
  local zf="Xray-linux-64.zip"; [ "$RARCH" != "amd64" ] && zf="Xray-linux-arm64-v8a.zip"
  fetch_url "https://github.com/XTLS/Xray-core/releases/latest/download/$zf" "/tmp/xray.zip" || { err "xray 下载失败"; return 1; }
  python3 -c "import zipfile,sys; zipfile.ZipFile('/tmp/xray.zip').extract('xray','/usr/local/bin/')"
  chmod +x /usr/local/bin/xray; rm -f /tmp/xray.zip
  info "xray: $(/usr/local/bin/xray version | head -1)"
}

# ================================================================
# 部署 1 — VLESS + Reality (xray)
# ================================================================
deploy_reality() {
  step "部署 VLESS + Reality (xray)"
  install_xray || return 1

  local port=${R_PORT:-80}
  # 443 被占或运营商 QoS 443 时用 80 (今晚实测: 443 被 QoS, 80 通)
  ss -tln 2>/dev/null | grep -q ":443 " && port=80
  local sni="www.cloudflare.com"

  local keys=$(/usr/local/bin/xray x25519)
  local priv=$(echo "$keys" | grep -oP '(?<=Private key: )\S+' || echo "$keys" | tail -2 | head -1 | awk '{print $NF}')
  local pub=$(echo "$keys" | grep -oP '(?<=Public key: )\S+' || echo "$keys" | tail -1 | awk '{print $NF}')
  local sid=$(openssl rand -hex 8)

  mkdir -p /etc/xray
  cat > /etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $port,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }], "decryption": "none" },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false, "dest": "$sni:443", "xver": 0,
        "serverNames": ["$sni"], "privateKey": "$priv", "shortIds": ["$sid"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom", "tag": "direct" }]
}
EOF
  /usr/local/bin/xray run -test -c /etc/xray/config.json >/dev/null 2>&1 || { err "xray 配置非法: $(/usr/local/bin/xray run -test -c /etc/xray/config.json 2>&1 | head -c 150)"; return 1; }

  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Reality
After=network.target
[Service]
ExecStart=/usr/local/bin/xray run -c /etc/xray/config.json
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now xray
  sleep 2
  systemctl is-active xray >/dev/null && info "Reality 已启动 (端口 $port)" || { err "Reality 启动失败"; return 1; }

  local addr="127.0.0.1"
  [ "$HAS_PUB6" -eq 1 ] && addr="$PUB6"
  [ "$HAS_PUB4" -eq 1 ] && addr="$PUB4"
  REALITY_LINK="vless://${UUID}@${addr}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#Reality-v5"
  echo -e "  ${MAGENTA}Reality 链接:${NC} $REALITY_LINK"
}

# ================================================================
# 部署 2 — Hysteria2 (sing-box)
# ================================================================
deploy_hy2() {
  step "部署 Hysteria2 (sing-box)"
  install_singbox || return 1

  local port=${H_PORT:-8443}
  local pw=$(openssl rand -hex 12)
  mkdir -p /etc/sing-box
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -days 3650 \
    -subj "/CN=www.cloudflare.com" 2>/dev/null

  cat > /etc/sing-box/hy2.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "hysteria2", "tag": "hy2-in",
    "listen": "::", "listen_port": $port,
    "ignore_client_bandwidth": true,
    "users": [{ "password": "$pw" }],
    "tls": { "enabled": true, "server_name": "www.cloudflare.com",
             "certificate_path": "/etc/sing-box/hy2.crt", "key_path": "/etc/sing-box/hy2.key" }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
  /usr/local/bin/sing-box check -c /etc/sing-box/hy2.json >/dev/null 2>&1 || { err "HY2 配置非法: $(/usr/local/bin/sing-box check -c /etc/sing-box/hy2.json 2>&1 | head -c 150)"; return 1; }

  cat > /etc/systemd/system/sing-box-hy2.service <<EOF
[Unit]
Description=sing-box Hysteria2
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/hy2.json
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now sing-box-hy2
  sleep 2
  systemctl is-active sing-box-hy2 >/dev/null && info "HY2 已启动 (UDP $port)" || { err "HY2 启动失败"; return 1; }

  local addr="127.0.0.1"
  [ "$HAS_PUB6" -eq 1 ] && addr="$PUB6"
  [ "$HAS_PUB4" -eq 1 ] && addr="$PUB4"
  local fprint=$(openssl x509 -in /etc/sing-box/hy2.crt -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
  HY2_LINK="hysteria2://${pw}@${addr}:${port}?sni=www.cloudflare.com&pinSHA256=${fprint}#HY2-v5"
  echo -e "  ${MAGENTA}HY2 链接 (pinSHA256 版, 兼容 26.2.6+ 内核):${NC} $HY2_LINK"
}

# ================================================================
# 部署 3 — CF Tunnel 架构 (交互: 需要用户填 token)
# ================================================================
deploy_tunnel() {
  step "部署 CF Tunnel 架构 (VLESS+VMess+WS)"
  install_singbox || return 1

  echo -e "  ${YELLOW}此步骤需要交互: 请先在 CF 面板 (Zero Trust → Networks → Tunnels) 创建隧道并复制 Token${NC}"
  read -rp "  输入 Tunnel Token: " TUN_TOKEN
  [ -z "$TUN_TOKEN" ] && { warn "未输入, 取消"; return 1; }
  read -rp "  输入隧道域名 (CF 面板绑定的 Public Hostname, 如 nl.example.com): " TUN_HOST
  [ -z "$TUN_HOST" ] && { warn "未输入, 取消"; return 1; }
  local wsport=${WS_PORT:-8001}
  local wspath="/$(openssl rand -hex 4)"

  # sing-box WS 入站 (vless + vmess 双协议)
  mkdir -p /etc/sing-box
  cat > /etc/sing-box/tunnel.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    { "tag": "vless-ws", "listen": "127.0.0.1", "listen_port": $wsport, "type": "vless",
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "ws", "path": "$wspath" } },
    { "tag": "vmess-ws", "listen": "127.0.0.1", "listen_port": 8003, "type": "vmess",
      "users": [{ "uuid": "$UUID" }],
      "transport": { "type": "ws", "path": "/vm-$wspath" } }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" }
}
EOF
  /usr/local/bin/sing-box check -c /etc/sing-box/tunnel.json >/dev/null 2>&1 || { err "配置非法"; return 1; }

  # cloudflared (token 模式)
  command -v /usr/local/bin/cloudflared >/dev/null 2>&1 || {
    fetch_url "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${RARCH}" "/usr/local/bin/cloudflared" || { err "cloudflared 下载失败"; return 1; }
    chmod +x /usr/local/bin/cloudflared
  }

  cat > /etc/systemd/system/sing-box-ws.service <<EOF
[Unit]
Description=sing-box WS (CF Tunnel)
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/tunnel.json
Restart=always
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/cf-tunnel.service <<EOF
[Unit]
Description=cloudflared tunnel
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel run --protocol http2 --token ${TUN_TOKEN}
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sing-box-ws cf-tunnel
  sleep 3
  systemctl is-active sing-box-ws >/dev/null && systemctl is-active cf-tunnel >/dev/null && info "隧道与 WS 入站已启动 ✓" || warn "部分服务未就绪, 稍等后 bash /root/status.sh 查看"

  echo -e "  ${YELLOW}别忘了在 CF 面板该隧道的 Public Hostname 里配置:${NC}"
  echo -e "    hostname=$TUN_HOST → service http://localhost:$wsport"
  echo -e "    (VMess 路径 /vm$wspath 与 VLESS 共用此 hostname)"
  TUN_VLESS="vless://${UUID}@${TUN_HOST}:443?encryption=none&security=tls&sni=${TUN_HOST}&fp=chrome&type=ws&host=${TUN_HOST}&path=${wspath}%3Fed%3D2560#Tunnel-VLESS"
  TUN_VMESS="vmess://$(printf '%s' "{\"v\":\"2\",\"ps\":\"Tunnel-VMess\",\"add\":\"${TUN_HOST}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"host\":\"${TUN_HOST}\",\"path\":\"/vm${wspath}\",\"tls\":\"tls\",\"sni\":\"${TUN_HOST}\",\"fp\":\"chrome\"}" | base64 -w0)"
  echo -e "  ${MAGENTA}VLESS 链接:${NC} $TUN_VLESS"
  echo -e "  ${MAGENTA}VMess 链接:${NC} $TUN_VMESS"
}

# ================================================================
# status.sh 体检工具
# ================================================================
install_status() {
  cat > /root/status.sh <<'STATUSEOF'
#!/bin/bash
echo "══════════ 服务状态 ══════════"
for s in $(systemctl list-unit-files | grep -oP '^(sing-box[\w-]*|xray|cf-tunnel)\.service' | sort -u); do
  st=$(systemctl is-active "$s"); [ "$st" = "active" ] && m="OK" || m="DOWN"
  printf "  %-24s %s %s\n" "$s" "$m" "$st"
done
echo "══════════ 监听端口 ══════════"
ss -tlnp 2>/dev/null | grep -E 'sing-box|xray' | awk '{print "  " $4}'
echo "══════════ 出站健康 ══════════"
curl -6 -s -o /dev/null --max-time 8 -w "  v6出站: %{http_code}\n" https://www.cloudflare.com/ 2>/dev/null
curl -s -o /dev/null --max-time 12 -w "  v4出站(NAT64): %{http_code}\n" http://example.com/ 2>/dev/null
echo "  出口IP: $(curl -s --max-time 8 ifconfig.me 2>/dev/null)"
echo "══════════ 节点链接 ══════════"
[ -f /root/node-links.txt ] && cat /root/node-links.txt || echo "  (未见 node-links.txt)"
echo "══════════ 最近错误 ══════════"
journalctl -n 300 --no-pager 2>/dev/null | grep -iE 'error.*reality|error.*hysteria|error.*sing-box|error.*xray' | tail -3 || echo "  (无)"
STATUSEOF
  chmod +x /root/status.sh
  info "体检工具: bash /root/status.sh"
}

# ================================================================
# 主菜单
# ================================================================
main_menu() {
  clear 2>/dev/null || true
  echo -e "${BOLD}━━━━━━━━ softvlssauto v5.0 智能部署 ━━━━━━━━${NC}"
  scan_env
  show_verdict
  install_status
  echo -e "${BOLD}请选择部署项:${NC}"
  echo -e "  ${GREEN}[1]${NC} VLESS + Reality (xray, TCP 直连)"
  echo -e "  ${GREEN}[2]${NC} Hysteria2 (sing-box, UDP 直连)"
  echo -e "  ${GREEN}[3]${NC} CF Tunnel 架构 (VLESS+VMess+WS, ${YELLOW}需交互输入${NC})"
  echo -e "  ${GREEN}[4]${NC} 1+2 一起 (直连双协议)"
  echo -e "  ${GREEN}[5]${NC} 1+2+3 全家桶"
  echo -e "  ${GREEN}[0]${NC} 退出"
  read -rp "选择: " choice
  case "$choice" in
    1) deploy_reality ;;
    2) deploy_hy2 ;;
    3) deploy_tunnel ;;
    4) deploy_reality; deploy_hy2 ;;
    5) deploy_reality; deploy_hy2; deploy_tunnel ;;
    0) exit 0 ;;
    *) warn "无效选择" ;;
  esac

  # 汇总
  {
    [ -n "${REALITY_LINK:-}" ] && echo "$REALITY_LINK"
    [ -n "${HY2_LINK:-}" ] && echo "$HY2_LINK"
    [ -n "${TUN_VLESS:-}" ] && echo "$TUN_VLESS"
    [ -n "${TUN_VMESS:-}" ] && echo "$TUN_VMESS"
  } > /root/node-links.txt 2>/dev/null
  echo ""
  info "全部节点已存 /root/node-links.txt | 体检: bash /root/status.sh"
  echo -e "  ${YELLOW}再次运行本脚本可追加部署其他协议 (已装的自动跳过)${NC}"
}

# ── 卸载模式 ──
if [ "${1:-}" = "uninstall" ]; then
  step "卸载全部"
  systemctl stop xray sing-box-hy2 sing-box-ws cf-tunnel 2>/dev/null
  systemctl disable xray sing-box-hy2 sing-box-ws cf-tunnel 2>/dev/null
  rm -f /etc/systemd/system/{xray,sing-box-hy2,sing-box-ws,cf-tunnel}.service
  systemctl daemon-reload
  rm -rf /etc/xray /etc/sing-box /root/node-links.txt
  info "已卸载 (证书备份在 /etc/sing-box.bak 如有)"
  exit 0
fi

main_menu
