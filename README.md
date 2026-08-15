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

### 方式一：交互式安装（适合第一次使用）

在 VPS 上获取 root 权限后执行：

```bash
git clone https://github.com/casa79g/softvlssauto.git
cd softvlssauto
bash install.sh
```

然后按提示输入参数：
- 隧道名称 → 例如 `arnegowl`（回车用默认）
- 隧道 Token → 从 CF 面板获取，整段粘贴后回车
- CF 隧道域名 → CF 面板 ingress 的 hostname（必填）
- 监听端口 → 默认 `8001`（被占用自动释放）
- WebSocket 路径 → 回车自动生成
- UUID → 回车自动生成
- CF 优选域名 → 默认 `cf.godns.cc`
- 是否启用 gRPC → 推荐 N

### 方式二：无交互安装（适合批量/自动化）

所有参数通过环境变量传入，全程零交互：

```bash
export CF_TOKEN=eyJh你的完整Token
export CF_HOST=你的隧道域名
# 可选：覆盖默认值
# export TUNNEL_NAME=arnegowl
# export PREF_DOMAIN=cf.godns.cc
# export WS_PATH=/proxy-自定义
# export UUID=自定义uuid
# export USE_GRPC=n

git clone https://github.com/casa79g/softvlssauto.git
cd softvlssauto
bash install.sh
```

> **注意**：`CF_TOKEN` 和 `CF_HOST` 是必填的环境变量，缺任意一个会报错。
> 其他参数不设置会自动生成默认值。

### 方式三：从 NAS 复制后运行

```bash
scp /NAS/cf-tunnel-vless/install.sh root@你的VPS_IP:/root/
ssh root@你的VPS_IP
bash /root/install.sh
```

## 端口占用自动释放

脚本在 Step 2 会扫描常用端口，发现占用时：

1. 如果占用进程是 **sing-box** 或 **cloudflared** 服务 → 先通过 `systemctl stop` 优雅停止
2. 如果停止后仍未释放 → `kill -9` 强制终止
3. 所有推荐端口都失败时 → 报错退出，提示手动干预

### 手动释放端口命令

```bash
# 查看占用端口 8001 的进程
ss -tlnp "sport = :8001"

# 查看具体命令
cat /proc/<PID>/cmdline | tr '\0' ' '

# 强制终止
kill -9 <PID>

# 或如果通过 systemd 管理
systemctl stop sing-box-vless cloudflared-tunnel
```

## 安装流程

1. SSH 登录新 VPS，获取 root 权限
2. 运行 `bash install.sh`（交互）或设置环境变量后运行（无交互）
3. 自动完成：下载 → 配置 → 启动 → 测试 → 生成 sub.txt
4. 终端打印 sub.txt，**两条链接**，复制到 V2RayN

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

## 环境变量参数一览

| 变量 | 必填 | 默认值 | 说明 |
|------|:----:|--------|------|
| `CF_TOKEN` | ✅ | — | CF 隧道 Token |
| `CF_HOST` | ✅ | — | CF 隧道域名（ingress hostname） |
| `TUNNEL_NAME` | ❌ | `arnegowl` | CF 面板隧道名称 |
| `SB_PORT` | ❌ | 自动检测 | sing-box 监听端口 |
| `WS_PATH` | ❌ | 自动生成 | WebSocket 路径 |
| `UUID` | ❌ | 自动生成 | VLESS UUID |
| `PREF_DOMAIN` | ❌ | `cf.godns.cc` | CF 优选域名 |
| `USE_GRPC` | ❌ | `n` | 是否启用 gRPC |

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

Token 写入 `/root/cf-tunnel.conf`（权限 600），不在日志中打印。

### 文件位置

| 文件/目录 | 用途 |
|-----------|------|
| `/etc/sing-box/sb.json` | sing-box 配置 |
| `/root/cf-tunnel.conf` | cloudflared 配置（Token 在此） |
| `/root/sub.txt` | 节点分享链接 |
| `/root/softvlssauto/` | 脚本文件目录 |