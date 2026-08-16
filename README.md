# CF Tunnel + VLESS 自动部署 v2.1

基于 Cloudflare Tunnel + sing-box 的网络学习方案，**无需开放公网端口**，零端口暴露。

## 🏗️ 守护架构（v2.1 核心变化）

```
主守护：PM2（Node.js 进程管理器）
├── 进程挂掉 → 秒级自动重启
├── 开机自启 → pm2 startup systemd（系统重启自动拉起）
├── 日志管理 → pm2 logs（滚动日志，自带时间戳）
└── 优雅重启 → pm2 restart all（不用先 kill）

兜底1：systemd（容器环境 PM2 不可用时自动降级）
└── systemd service 文件，自带 Restart=always

兜底2：cron（可选，仅限 VPS 有 cron 服务时）
└── 每 30 分钟检查一次，仅做额外保护
└── 无 cron 的 VPS 直接用 PM2/systemd 完全 OK
```

> **为什么用 PM2？** 对比原方案：原方案靠 cron 每 10 分钟检查，宕机恢复最长 10 分钟。PM2 是专业的进程管理器，进程一挂立刻重启，开机自动拉起，自带日志滚动。cron 只是可选兜底，不是强制依赖。

## 📋 系统要求

- **必需**：root 权限、curl、openssl、bash
- **推荐**：Node.js（PM2 需要，脚本会自动安装）
- **可选**：systemd（无则用 nohup）、cron（可选兜底）

## 🚀 快速部署

### 方式一：交互式部署
```bash
curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
```

### 方式二：无交互部署（适合脚本化/批量）
```bash
export CF_TOKEN="eyJh..."          # Cloudflare Tunnel Token
export CF_HOST="xxxxxx.cloudflarecf.app"  # CF 隧道域名
export TUNNEL_NAME="network-learning-node"
export PREF_DOMAIN="cf.godns.cc"     # 可选，默认 cf.godns.cc
curl -fsSL https://raw.githubusercontent.com/casa79g/softvlssauto/main/install.sh | bash
```

### 方式三：自定义参数
```bash
export CF_TOKEN="eyJh..."
export CF_HOST="xxxxxx.cloudflarecf.app"
export SB_PORT=8001                    # sing-box 监听端口
export WS_PATH="/proxy-abcdef"         # WS 路径
export UUID="your-uuid-here"           # 客户端 UUID
export PREF_DOMAIN="cf.godns.cc"
export USE_GRPC="n"                    # 是否启用 gRPC 入口
bash install.sh
```

## 📁 文件说明

| 文件 | 说明 |
|------|------|
| `install.sh` | 主安装脚本，PM2 守护 |
| `sb-template.json` | sing-box 配置模板 |
| `gen_links.sh` | 切换 CF 优选域名 |
| `query.sh` | 节点信息查询与诊断 |
| `/etc/sing-box/sb.json` | sing-box 配置文件 |
| `/root/cf-tunnel-ecosystem.json` | PM2 进程配置（权限 600） |
| `/root/sub.txt` | 客户端分享链接（权限 600） |

## 🔧 管理命令

### PM2 方式（v2.1 默认）
```bash
pm2 list                  # 查看所有进程状态
pm2 logs                  # 实时查看日志
pm2 logs --lines 50       # 查看最近 50 行
pm2 restart all           # 重启所有服务
pm2 restart sing-box-vless  # 只重启 sing-box
pm2 stop all              # 停止所有服务
pm2 save                  # 保存进程列表（修改配置后）
```

### 传统 systemd（v1.x 方式，仍然兼容）
```bash
systemctl status sing-box-vless
systemctl restart sing-box-vless cloudflared-tunnel
journalctl -u sing-box-vless -f
```

## 🔍 诊断

```bash
bash query.sh          # 检查节点状态、PM2 进程、日志、连通性
cat /root/sub.txt      # 查看分享链接和节点配置
```

## ❌ 卸载

```bash
bash install.sh uninstall
```

自动执行：
1. `pm2 delete all`（停止并删除 PM2 进程）
2. `pm2 save`（清空进程列表）
3. 删除配置文件（`/etc/sing-box/sb.json`、`/root/cf-tunnel-ecosystem.json`）
4. 删除订阅文件（`/root/sub.txt`）
5. 清理日志文件

## 📋 架构说明

```
客户端 (V2RayN/Karing)
    │
    ▼  VLESS over WebSocket + TLS
优选域名 (cf.godns.cc) → Cloudflare Edge
    │
    ▼  CF Tunnel (免费，零端口暴露)
cloudflared (PM2 守护)
    │
    ▼  HTTP/2 → 127.0.0.1:8001
sing-box (PM2 守护)
    │
    ▼  转发到目标网站
```

## ⚠️ 注意事项

1. **CF Tunnel Token 和域名** 在 Cloudflare 面板 → Network → Tunnels 获取
2. **CF 域名格式** 类似 `xxxxxxxx-xxxxxxxx-xxxxxxxx-xxxxxxxx.cloudflarecf.app`
3. **优选域名** 选择离**客户端本地**近的服务商，不是离 VPS 近的
4. **重启后**：PM2 通过 `pm2 startup` 自动拉起，无需任何操作
5. **gRPC 入口**：默认不启用（VLESS 已够用）；如需启用 `export USE_GRPC=y`
6. **/etc/hosts**：安装脚本会自动修复 IPv6 localhost 问题
