#!/usr/bin/env python3
"""
NAS Gateway v2.0 — 合并版 HTTP 服务
端口 8900 同时提供：
  1. 静态文件服务（原功能）
  2. Beacon API（/beacon, /dashboard, /api/records）
启动: python3 /root/nas-gateway.py --port 8900 --dir /path/to/downloads
"""
import json, os, time, sys
from http.server import HTTPServer, BaseHTTPRequestHandler, SimpleHTTPRequestHandler
from urllib.request import urlopen, Request
from datetime import datetime
from pathlib import Path

DATA_FILE = "/root/beacon-data.json"
PORT = 8900
SERVE_DIR = "/run/csi/mount-root/nas/4079184d856ecc166ed19d4887083405/workspaces/default/downloads"


# ── 地理位置查询 ──
def geolocate(ip):
    apis = [
        f"http://ip-api.com/json/{ip}?fields=country,city,regionName,isp,org,as",
        f"https://ipapi.co/{ip}/json/",
    ]
    for api_url in apis:
        try:
            req = Request(api_url, headers={"User-Agent": "nas-gateway/2.0"})
            resp = urlopen(req, timeout=6)
            data = json.loads(resp.read())
            if isinstance(data, dict) and data.get("status") == "fail":
                continue
            if "error" in data and data["error"]:
                continue
            return {
                "country":  data.get("country"),
                "city":     data.get("city"),
                "region":   data.get("regionName") or data.get("region"),
                "isp":      data.get("isp") or data.get("org"),
                "org":      data.get("org"),
                "as":       data.get("as"),
            }
        except Exception:
            continue
    return {}


# ── 数据存取 ──
def load_records():
    records = []
    if os.path.exists(DATA_FILE):
        try:
            with open(DATA_FILE, "r") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        records.append(json.loads(line))
        except Exception:
            pass
    return records


def append_record(record):
    with open(DATA_FILE, "a") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


# ── HTML 看板 ──
def render_dashboard():
    records = load_records()
    total = len(records)

    from collections import Counter

    versions  = Counter(r.get("version", "?") for r in records)
    countries = Counter(r.get("country", "?") or "?" for r in records)
    isps      = Counter(r.get("isp", "?") or "?" for r in records)

    top_v = versions.most_common(10)
    top_c = countries.most_common(10)
    top_i = isps.most_common(10)
    recent = records[-30:]

    rows_html = ""
    for r in reversed(recent):
        ts = datetime.fromtimestamp(r.get("timestamp", 0)).strftime("%Y-%m-%d %H:%M")
        loc = f"{r.get('country','?')} {r.get('city','?')}".strip() or "?"
        rows_html += f"""<tr>
  <td>{ts}</td><td>{r.get('version','?')}</td>
  <td>{r.get('arch','?')}</td><td>{loc}</td>
  <td>{r.get('isp','?')}</td><td>{r.get('ip','?')}</td>
</tr>"""

    v_list = "".join(f"<li><strong>{v}</strong>: {c} 次</li>" for v, c in top_v)
    c_list = "".join(f"<li><strong>{c}</strong>: {n} 次</li>" for c, n in top_c)
    i_list = "".join(f"<li><strong>{i}</strong>: {n} 次</li>" for i, n in top_i)

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>NAS Gateway — Beacon Dashboard</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
     background:#0f1419;color:#c9d1d9;padding:20px;line-height:1.5}}
.container{{max-width:1100px;margin:0 auto}}
h1{{font-size:1.5rem;color:#58a6ff;margin-bottom:4px}}
.sub{{color:#8b949e;font-size:0.85rem;margin-bottom:20px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px;margin-bottom:24px}}
.card{{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px}}
.num{{font-size:2rem;font-weight:700;color:#58a6ff}}
.label{{color:#8b949e;font-size:0.8rem;margin-top:4px}}
h2{{font-size:1rem;color:#58a6ff;margin:20px 0 8px;
    border-bottom:1px solid #30363d;padding-bottom:6px}}
table{{width:100%;border-collapse:collapse;font-size:0.85rem}}
th,td{{padding:7px 10px;text-align:left;border-bottom:1px solid #21262d}}
th{{background:#161b22;color:#8b949e;font-weight:600}}
tr:hover{{background:#161b22}}
ul{{list-style:none;padding-left:0}}
li{{padding:3px 0;font-size:0.85rem}}
.grid2{{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:24px}}
@media(max-width:600px){{.grid2{{grid-template-columns:1fr}}}}
.foot{{text-align:center;color:#484f58;font-size:0.75rem;
       margin-top:30px;padding-top:16px;border-top:1px solid #21262d}}
</style>
</head>
<body>
<div class="container">
<h1>📡 NAS Gateway Beacon</h1>
<p class="sub">匿名部署追踪 · 数据完全存储在本机</p>
<div class="cards">
  <div class="card"><div class="num">{total}</div><div class="label">总部署次数</div></div>
  <div class="card"><div class="num">{len(countries)}</div><div class="label">覆盖国家/地区</div></div>
  <div class="card"><div class="num">{len(isps)}</div><div class="label">不同 ISP</div></div>
</div>
<div class="grid2">
  <div><h2>📦 版本分布</h2><ul>{v_list}</ul></div>
  <div><h2>🌍 地区分布</h2><ul>{c_list}</ul></div>
</div>
<h2>🏢 ISP 分布 (Top 10)</h2><ul>{i_list}</ul>
<h2>📋 最近 30 条</h2>
<table>
<tr><th>时间</th><th>版本</th><th>架构</th><th>位置</th><th>ISP</th><th>IP</th></tr>
{rows_html}</table>
<div class="foot">NAS Gateway v2.0 · 静态文件 + Beacon · 仅 8900 端口</div>
</div>
</body>
</html>""".encode()


# ── HTTP Handler ──
class GatewayHandler(BaseHTTPRequestHandler):
    serve_dir = SERVE_DIR

    def _send_file(self, local_path):
        """发送静态文件"""
        try:
            full = os.path.join(self.serve_dir, local_path.lstrip("/"))
            full = os.path.normpath(full)
            if not full.startswith(self.serve_dir):
                self.send_response(403)
                self.end_headers()
                return
            with open(full, "rb") as f:
                content = f.read()
            # 目录请求，找 index.html
            if content == b"" and os.path.isdir(full):
                idx = os.path.join(full, "index.html")
                if os.path.isfile(idx):
                    with open(idx, "rb") as f:
                        content = f.read()
            self.send_response(200)
            ext = os.path.splitext(local_path)[1].lower()
            mime = {
                ".html": "text/html; charset=utf-8",
                ".css": "text/css; charset=utf-8",
                ".js": "application/javascript; charset=utf-8",
                ".json": "application/json; charset=utf-8",
                ".png": "image/png",
                ".jpg": "image/jpeg",
                ".gif": "image/gif",
                ".svg": "image/svg+xml",
                ".ico": "image/x-icon",
                ".txt": "text/plain; charset=utf-8",
                ".sh": "text/plain; charset=utf-8",
                ".py": "text/plain; charset=utf-8",
                ".md": "text/markdown; charset=utf-8",
            }.get(ext, "application/octet-stream")
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found")

    def do_GET(self):
        # ── Beacon 路由 ──
        if self.path == "/beacon" or self.path.startswith("/beacon?"):
            ip = self.client_address[0]
            loc = geolocate(ip)
            qs = self.path.split("?")[-1] if "?" in self.path else ""
            params = {}
            for pair in qs.split("&"):
                if "=" in pair:
                    k, v = pair.split("=", 1)
                    params[k] = v
            record = {
                "timestamp": time.time(),
                "version":   params.get("v", "unknown"),
                "arch":      params.get("a", "unknown"),
                "os":        params.get("o", "unknown"),
                "ip":        ip,
                "country":   loc.get("country"),
                "city":      loc.get("city"),
                "region":    loc.get("region"),
                "isp":       loc.get("isp"),
                "org":       loc.get("org"),
                "as":        loc.get("as"),
                "ua":        self.headers.get("User-Agent"),
            }
            append_record(record)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return

        if self.path in ("/dashboard", "/"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(render_dashboard())
            return

        if self.path == "/api/records":
            recs = load_records()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(recs, ensure_ascii=False).encode())
            return

        # ── 静态文件路由（原 8900 功能） ──
        self._send_file(self.path)

    def do_POST(self):
        if self.path == "/beacon":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length).decode()
            try:
                data = json.loads(body)
            except Exception:
                data = {}
            ip = self.client_address[0]
            loc = geolocate(ip)
            record = {
                "timestamp": time.time(),
                "version":   data.get("version", "unknown"),
                "arch":      data.get("arch", "unknown"),
                "os":        data.get("os", "unknown"),
                "ip":        ip,
                "country":   loc.get("country"),
                "city":      loc.get("city"),
                "region":    loc.get("region"),
                "isp":       loc.get("isp"),
                "org":       loc.get("org"),
                "as":        loc.get("as"),
                "ua":        self.headers.get("User-Agent"),
            }
            append_record(record)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, fmt, *args):
        pass  # 静默


if __name__ == "__main__":
    port = PORT
    serve_dir = SERVE_DIR
    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "--port" and i + 1 < len(sys.argv):
            port = int(sys.argv[i + 1])
            i += 1
        if sys.argv[i] == "--dir" and i + 1 < len(sys.argv):
            serve_dir = sys.argv[i + 1]
            i += 1
        i += 1

    GatewayHandler.serve_dir = serve_dir
    server = HTTPServer(("0.0.0.0", port), GatewayHandler)
    print(f"🌐 NAS Gateway running on :{port}")
    print(f"   Dashboard: http://localhost:{port}/dashboard")
    print(f"   Static:    http://localhost:{port}/  (→ {serve_dir})")
    print(f"   Beacon:    http://localhost:{port}/beacon")
    server.serve_forever()