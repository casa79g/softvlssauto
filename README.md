# CF Tunnel + VLESS 自动部署工具

## 用途

在新 VPS 上一键部署网络学习节点（VLESS + WebSocket + Cloudflare Tunnel），
生成 V2RayN / Karing 可直接使用的分享链接。

## 架构

```
V2RayN/Karing
  → CF 边缘（你的 CF 域名）
    → cloudflared tunnel
      → localhost:8001
        → sing-box (VLESS + WebSocket)
```

## 安装

### 方式一：从 GitHub 私库（推荐）

在 VPS 上获取 root 权限后执行：

```bash
GIT_TOKEN=ghp_你的token
git clone https://${GIT_TOKEN}@github.com/casa79g/softvlssauto.git
cd softvlssauto
bash install.sh
```

### 方式二：从 NAS 复制后运行

```bash
scp /NAS/cf-tunnel-vless/install.sh root@你的VPS_IP:/root/
ssh root@你的VPS_IP
bash /root/install.sh
```

## 安装流程

1. SSH 登录新 VPS，获取 root 权限
2. 运行 `bash install.sh`
3. 按提示输入（带默认值，可回车跳过）：
   - 隧道名称 → 例如 `arnegowl`
   - 隧道 Token → 从 CF 面板获取，需双输确认
   - CF 隧道域名 → CF 面板 ingress 的 hostname
   - 监听端口 → 默认 `8001`（被占用则自动切换）
   - WebSocket 路径 → 回车自动生成随机路径
   - UUID → 回车自动生成
   - **CF 优选域名** → 例如 `cf.godns.cc`（地址/Host/SNI 统一用此域名）
   - 是否启用 gRPC → 推荐 N（VLESS 已够用）
4. 自动完成：下载 → 配置 → 启动 → 测试 → 生成 sub.txt
5. 终端打印 sub.txt，**两条链接**，复制到 V2RayN

---

## 日常操作（直接复制运行）

| 操作 | 命令 |
|------|------|
| **查询节点信息** | `cat /root/sub.txt` |
| **换优选域名** | `bash /root/softvlssauto/gen_links.sh 新域名` |
| **查看运行状态** | `bash /root/softvlssauto/query.sh` |
| **查看服务日志** | `journalctl -u sing-box-vless -f --no-pager` |
| **重启网络学习服务** | `systemctl restart sing-box-vless cloudflared-tunnel` |
| **停止网络学习服务** | `systemctl stop sing-box-vless cloudflared-tunnel` |
| **卸载全部** | `bash /root/softvlssauto/uninstall.sh` |

---

## 关键说明

### 地址/Host/SNI 统一域名

只输入一个优选域名（如 `cf.godns.cc`），地址、Host、SNI 全部用同一域名，
无需关心多个域名的对应关系。换域名只需运行 `gen_links.sh` 即可。

### 两条链接的区别

| 链接 | 内容 | 用途 |
|------|------|------|
| 配置一 | URL 完整，无分片 | 日常使用 |
| 配置二 | URL 相同，标签注明"分片" | 在 V2RayN 此节点**高级设置**中开启 Fragment |

开启 Fragment：此节点 → 右键编辑 → 高级设置 → Fragment → tlshello 100-200 / 10-20ms

### Token 安全

Token 交互式双输确认，写入 `/root/cf-tunnel.conf`（权限 600），不在日志中打印。

### 文件位置

| 文件/目录 | 用途 |
|-----------|------|
| `/etc/sing-box/sb.json` | sing-box 配置 |
| `/root/cf-tunnel.conf` | cloudflared 配置（Token 在此） |
| `/root/sub.txt` | 节点分享链接 |
| `/root/softvlssauto/` | 脚本文件目录 |