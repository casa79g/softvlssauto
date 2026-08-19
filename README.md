# CF Tunnel + VMess/VLESS 自动部署 v4.1

基于 Cloudflare Tunnel + sing-box 的网络学习方案，**无需开放公网端口**，零端口暴露。

## 🔥 v4.1 核心变化（v4.0 → v4.1）

| 特性 | v4.0 | v4.1 |
|------|------|------|
| 连接协议 | 默认 auto（QUIC 优先） | **强制 `--protocol http2`**，跳过 QUIC 退避黑洞 |
| 容器/无 systemd 自启 | 跳过（需重跑 install.sh） | **自动注册**：cron @reboot → rc.local → profile.d 登录钩子 |
| 隧道探活自愈 | ❌ | ✅ 每 5 分钟 curl 穿透域名，连接断自动重启 cloudflared |
| 平台级沙箱提示 | ❌ | ✅ 提示在平台面板配置开机命令 |

> **为什么强制 http2？** 很多 VPS/容器/家宽环境会丢出站 UDP 7844（QUIC）。cloudflared 默认先试 QUIC，失败后指数退避（4s→8s→16s→32s），**每次断连后要 2-3 分钟才 fallback 到 http2**，形成"黑洞期"。显式 `--protocol http2` 后 1 秒内注册成功。
>
> **为什么做探活自愈？** 进程活着 ≠ 隧道通。CF 边缘断连时 cloudflared 进程可能还在但连接已死，PM2 只按进程存亡重启，不会管连接死活。定时探活兜底解决这个盲区。

## 🏗️ 守护架构（v4.1）

```
主守护：PM2（Node.js 进程管理器）
├── 进程挂掉 → 秒级自动重启
├── 开机自启 → systemd（有 systemd 时）自动拉起
├── 日志管理 → pm2 logs（滚动日志，自带时间戳）
└── 优雅重启 → pm2 restart all（不用先 kill）

兜底1：systemd 服务（PM2 不可用时自动降级）
兜底2：非 systemd 自启（无 systemd 容器自动注册，逐级降级）
        ├── cron @reboot → /root/auto-start-tunnel.sh（等外网通 → pm2 resurrect）
        ├── rc.local（若存在）
        └── profile.d 登录钩子（任何登录 shell 都会检查拉起）
兜底3：隧道探活自愈（全环境，cron daemon 可用时）
        └── 每 5 分钟 curl 穿透域名 → 000/502/504 → pm2 restart cloudflared-tunnel
```

> **平台级沙箱/按需容器**（如云开发环境、AI 编程平台容器，无 cron、无 systemd、无登录 shell）：请在**平台自身的开机命令/启动脚本**配置里填 `bash /root/auto-start-tunnel.sh`，这是唯一可靠的入口。安装时脚本会提示你这么做。

## 📋 系统要求

- **必需**：root 权限、curl、openssl、bash、base64
- **推荐**：Node.js（PM2 需要，脚本会自动安装）
- **CF API Token**（可选）：提供后脚本自动配置隧道路由规则；不提供则需手动在 CF 面板配置

## 🚀 快速部署

### 方式一：交互式部署
```bash
curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
```

### 方式二：无交互部署
```bash
export TUNNEL_NAME="your-tunnel-name"                   # 隧道名称，自定义
export CF_TOKEN="eyJh..."                              # Cloudflare Tunnel Token
export CF_HOST="xxxxxx.cloudflarecf.app"                # CF 隧道域名
export PREF_DOMAIN="cf.godns.cc"                        # 可选，默认 cf.godns.cc
curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
```

> **可选**：提供 `CF_API_TOKEN`（`cfat_`）后脚本会自动配置隧道路由规则，否则需手动在 CF 面板配置（见 [CF 隧道路由配置](#-cf-隧道路由配置)）。

### 方式三：自定义参数
```bash
export TUNNEL_NAME="arnegowl"                           # 隧道名称
export CF_TOKEN="eyJh..."
export CF_HOST="xxxxxx.cloudflarecf.app"
export PREF_DOMAIN="cf.godns.cc"                        # 可选
export SB_PORT=8001                                     # VLESS 端口
export VMESS_PORT=8003                                  # VMess 端口（固定）
export WS_PATH="/proxy-abcdef"                          # VLESS WS 路径
export VMESS_PATH="/vmess-f229df"                       # VMess WS 路径
export UUID="your-uuid-here"
export USE_GRPC="n"
export TUNNEL_PROBE="y"                                  # 隧道探活自愈（默认 y；设 n 关闭）
bash install.sh
```

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本（v4.1，PM2 守护 + 自愈） |
| `gen_links.sh` | 切换 CF 优选域名（支持 VMess/VLESS） |
| `query.sh` | 节点信息查询与诊断 |
| `/etc/sing-box/sb.json` | sing-box 配置（VLESS:$SB_PORT + VMess:8003） |
| `/root/cf-tunnel-ecosystem.json` | PM2 进程配置（权限 600） |
| `/root/auto-start-tunnel.sh` | 非 systemd 自启脚本（等外网 → pm2 resurrect） |
| `/root/tunnel-probe.sh` | 隧道探活自愈（cron 每 5 分钟，失败自动重启） |
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
bash /root/gen_links.sh <新域名>  # 切换优选域名
bash /root/uninstall.sh        # 卸载（或 bash install.sh uninstall）
```

> **注**：`gen_links.sh`、`query.sh`、`uninstall.sh` 安装时自动拷贝至 `/root/`，可从任意目录调用。

## 🔍 连通性检查

```bash
bash query.sh          # 检查节点状态、PM2 进程、端口监听、回环测试
cat /root/sub.txt      # 查看分享链接和节点配置
```

`query.sh` 会检查：
- PM2 进程状态（sing-box + cloudflared）
- 端口监听（8001 VLESS / 8003 VMess / 8002 gRPC）
- 本地回环 HTTP 响应（400/404=正常）
- /etc/hosts IPv6 问题
- 配置文件权限

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
4. **重启后**：systemd 环境 PM2 通过 `pm2 startup` 自动拉起；无 systemd 容器自动注册 cron @reboot / rc.local / profile.d 钩子三层兜底
5. **gRPC**：默认不启用；如需 `export USE_GRPC=y`
6. **/etc/hosts**：脚本会自动修复 IPv6 localhost 问题
7. **分片参数**：VMess 无标准分片 URL 参数，导入 V2RayN 后需在节点设置里手动开启（包长 100-200，间隔 10-20ms）
