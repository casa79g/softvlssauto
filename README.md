# CF Tunnel + VMess/VLESS 自动部署 v4.0

基于 Cloudflare Tunnel + sing-box 的网络学习方案，**无需开放公网端口**，零端口暴露。

## 🔥 v4.0 核心变化

| 特性 | v3.x | v4.0 |
|------|------|------|
| 协议 | VLESS only | **VMess（主推）+ VLESS（备选）** |
| VMess 入口 | ❌ | ✅ 8003 端口，路径 `/vmess-f229df` |
| CF 路由配置 | 手动 | **脚本自动**（提供 CF API Token 时） |
| 分片支持 | 无 | VMess/VLESS 均提示分片参数 |
| sub.txt 顺序 | VLESS 真实→优选 | **VMess优选→VLESS优选→VLESS真实** |

> **为什么 VMess 更稳？** VMess 自带加密使 CF 边缘无法做 HTTP/2 帧级"优化"而原样转发，buffer 更持久，断流更少。VLESS 透传被 CF 做 HTTP/2 帧重组，负载均衡切换时易断流。

## 🏗️ 守护架构（v3.0 起，v4.0 沿用）

```
主守护：PM2（Node.js 进程管理器）
├── 进程挂掉 → 秒级自动重启
├── 开机自启 → pm2 startup systemd（系统重启自动拉起）
├── 日志管理 → pm2 logs（滚动日志，自带时间戳）
└── 优雅重启 → pm2 restart all（不用先 kill）

兜底1：systemd（容器环境 PM2 不可用时自动降级）
兜底2：cron（可选，仅限 VPS 有 cron 服务时）
```

## 📋 系统要求

- **必需**：root 权限、curl、openssl、bash、base64
- **推荐**：Node.js（PM2 需要，脚本会自动安装）
- **CF API Token**：可选，提供后脚本自动配置隧道路由规则（`cfat_`，权限 `Tunnel:Configuration:Edit`）

## 🚀 快速部署

### 方式一：交互式部署
```bash
curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
```

### 方式二：无交互部署（含 CF API Token）
```bash
export CF_TOKEN="eyJh..."                              # Cloudflare Tunnel Token
export CF_HOST="xxxxxx.cloudflarecf.app"                # CF 隧道域名
export CF_API_TOKEN="cfat_xxx..."                       # CF API Token（自动配置路由）
export CF_ACCOUNT_ID="your-account-id"                  # 可选，自动解码
export TUNNEL_NAME="network-learning-node"
export PREF_DOMAIN="cf.godns.cc"
curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
```

### 方式三：自定义参数
```bash
export CF_TOKEN="eyJh..."
export CF_HOST="xxxxxx.cloudflarecf.app"
export CF_API_TOKEN="cfat_xxx..."                       # 可选
export SB_PORT=8001                                     # VLESS 端口
export VMESS_PORT=8003                                  # VMess 端口（固定）
export WS_PATH="/proxy-abcdef"                          # VLESS WS 路径
export VMESS_PATH="/vmess-f229df"                       # VMess WS 路径
export UUID="your-uuid-here"
export PREF_DOMAIN="cf.godns.cc"
export USE_GRPC="n"
bash install.sh
```

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本（v4.0，PM2 守护） |
| `gen_links.sh` | 切换 CF 优选域名（支持 VMess/VLESS） |
| `query.sh` | 节点信息查询与诊断 |
| `/etc/sing-box/sb.json` | sing-box 配置（VLESS:$SB_PORT + VMess:8003） |
| `/root/cf-tunnel-ecosystem.json` | PM2 进程配置（权限 600） |
| `/root/sub.txt` | 客户端分享链接（权限 600） |

## 📡 客户端配置（按推荐顺序）

### 1️⃣ VMess + 优选域名（主推）
```
地址:  cf.godns.cc
端口:  443
协议:  VMess
UUID:  <从 sub.txt 获取>
AlterID: 0
传输:  WebSocket
Host/SNI: <CF 隧道域名，从 sub.txt 获取>
路径:  /vmess-f229df
TLS:   true
指纹:  chrome
分片:  包长 100-200，间隔 10-20ms（客户端手动开启）
```

### 2️⃣ VLESS + 优选域名（备选，分片优化）
```
地址:  cf.godns.cc
端口:  443
协议:  VLESS
UUID:  <从 sub.txt 获取>
传输:  WebSocket
Host/SNI: <CF 隧道域名>
路径:  <从 sub.txt 获取>
TLS:   true
指纹:  chrome
分片:  包长 100-200，间隔 10-20ms
```

### 3️⃣ VLESS + 真实隧道域名（连通测试用）
```
地址:  <CF 隧道域名>
用途:  TLS 握手必通，用于验证隧道连通性
```

> **Host/SNI 必须保持为真实隧道域名**，不可改为优选域名。

## 🔧 管理命令

```bash
pm2 list                  # 查看所有进程状态
pm2 logs                  # 实时查看日志
pm2 restart all           # 重启所有服务
pm2 stop all              # 停止所有服务
pm2 save                  # 保存进程列表
cat /root/sub.txt         # 查看分享链接
bash gen_links.sh <新域名> # 切换优选域名
```

## 🔍 诊断

```bash
bash query.sh          # 检查节点状态、PM2 进程、日志、连通性
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8001/    # VLESS 本地 (400=正常)
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8003/    # VMess 本地 (400=正常)
```

## ⚡ 快速测速（检测 VPS 真实带宽）

### 方式一：Ookla Speedtest CLI（推荐）
```bash
cd /tmp && curl -sL https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz -o st.tgz && tar xzf st.tgz && chmod +x speedtest && ./speedtest --accept-license --accept-gdpr
```

### 方式二：Cloudflare 下载测速
```bash
curl -o /dev/null -s -w "down=%{speed_download} B/s time=%{time_total}s\n" "https://speed.cloudflare.com/__down?bytes=20000000"
```

## 🌐 CF 隧道路由配置

v4.0 脚本会自动调用 CF API 配置以下路由规则：

| 路径规则 | 目标端口 | 协议 |
|---------|---------|------|
| `^/vmess-f229df` | 8003 | VMess |
| 留空（catch-all） | 8001 | VLESS |

如未提供 `CF_API_TOKEN`，需在 CF 面板手动配置：
- CF Dashboard → Zero Trust → Networks → Tunnels → 你的隧道 → Routes
- 添加两条规则：`^/vmess-f229df` → `http://localhost:8003`，留空 → `http://localhost:8001`

## ❌ 卸载

```bash
bash install.sh uninstall
```

## ⚠️ 注意事项

1. **CF Tunnel Token**（`eyJh...`）在 Cloudflare 面板 → Network → Tunnels 获取
2. **CF API Token**（`cfat_`）需 `Tunnel:Configuration:Edit` 权限，创建方式：https://dash.cloudflare.com/profile/api-tokens
3. **优选域名** 选择离客户端本地近的服务商
4. **重启后**：PM2 通过 `pm2 startup` 自动拉起
5. **gRPC**：默认不启用；如需 `export USE_GRPC=y`
6. **/etc/hosts**：脚本会自动修复 IPv6 localhost 问题
7. **分片参数**：VMess 无标准分片 URL 参数，导入 V2RayN 后需在节点设置里手动开启（包长 100-200，间隔 10-20ms）
