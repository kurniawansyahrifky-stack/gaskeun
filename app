import os
import re
import time
import html
import sqlite3
import threading
from datetime import datetime
from flask import Flask, request, jsonify, render_template_string, Response
import requests
import psutil
from urllib.parse import unquote
from dotenv import load_dotenv

load_dotenv()
TELEGRAM_BOT_TOKEN = os.getenv("BOT_TOKEN")
TELEGRAM_CHAT_ID = os.getenv("OWNER_ID")
PORT = int(os.getenv("PORT", 8080))
DB_PATH = "security_logs.db"

app = Flask(__name__)
db_lock = threading.Lock()

client_health_cache = {}

# Pola Ancaman Tingkat Lanjut (Anti-Obfuscation & Advanced Bypass)
ANOMALY_PATTERNS = {
    "Advanced SQL Injection": r"('|\b(UNION|SELECT|INSERT|DELETE|DROP|EXEC|CAST|CONCAT)\b|--|\/\*|/\*\*\/|UN\/\*\*\/ION|or\s+1\s*=\s*1|and\s+1\s*=\s*1)",
    "Path Traversal / LFI": r"(\.\./|\.\.\\|%2e%2e|%c0%af|/etc/passwd|/etc/shadow|proc/self)",
    "Advanced XSS Attack": r"(<script.*?>|javascript:|onerror=|onload=|eval\(|expression\(|vbscript:|document\.cookie)",
    "Sensitive File / Probe": r"(\.env|\.git|wp-admin|config\.json|passwd|backup\.sql|phpmyadmin)"
}

HONEYPOT_TRAPS = [
    "/wp-login.php", "/wp-admin", "/administrator", "/phpmyadmin", 
    "/.env", "/config.json", "/backup.sql", "/xmlrpc.php", "/admin.php"
]

def get_real_ip():
    # Mendukung Cloudflare Tunnel & Header Proxy Lainnya dengan Lebih Akurat
    if request.headers.get("CF-Connecting-IP"):
        return request.headers.get("CF-Connecting-IP")
    elif request.headers.get("X-Forwarded-For"):
        return request.headers.get("X-Forwarded-For").split(",")[0].strip()
    return request.remote_addr

def init_db():
    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT,
                ip TEXT,
                country TEXT,
                target_domain TEXT,
                method TEXT,
                path TEXT,
                is_threat INTEGER,
                threats TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS client_targets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                domain TEXT UNIQUE,
                backend_url TEXT,
                client_name TEXT,
                status TEXT DEFAULT 'ACTIVE',
                added_at TEXT
            )
        """)
        c.execute("""
            CREATE TABLE IF NOT EXISTS admin_whitelist (
                ip TEXT PRIMARY KEY,
                device_name TEXT,
                added_at TEXT
            )
        """)
        conn.commit()
        conn.close()

init_db()

def is_admin_ip(ip: str) -> bool:
    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT 1 FROM admin_whitelist WHERE ip = ?", (ip,))
        row = c.fetchone()
        conn.close()
        return row is not None

def send_telegram(text):
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return
    url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage"
    payload = {"chat_id": TELEGRAM_CHAT_ID, "text": text, "parse_mode": "HTML"}
    try:
        requests.post(url, json=payload, timeout=5)
    except:
        pass

def target_health_prober():
    while True:
        try:
            with db_lock:
                conn = sqlite3.connect(DB_PATH)
                c = conn.cursor()
                c.execute("SELECT domain, backend_url, client_name FROM client_targets")
                targets = c.fetchall()
                conn.close()

            for domain, backend, name in targets:
                start_t = time.time()
                is_alive = False
                latency_ms = 999
                try:
                    resp = requests.get(backend, timeout=3)
                    latency_ms = int((time.time() - start_t) * 1000)
                    is_alive = resp.status_code < 500
                except:
                    is_alive = False
                    latency_ms = 0

                client_health_cache[domain] = {
                    "alive": is_alive,
                    "latency": latency_ms,
                    "name": name,
                    "backend": backend
                }
        except:
            pass
        time.sleep(3)

threading.Thread(target=target_health_prober, daemon=True).start()

def telegram_command_listener():
    if not TELEGRAM_BOT_TOKEN or not TELEGRAM_CHAT_ID:
        return
    offset = 0
    while True:
        try:
            url = f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/getUpdates?offset={offset}&timeout=10"
            resp = requests.get(url, timeout=15).json()
            for item in resp.get("result", []):
                offset = item["update_id"] + 1
                msg = item.get("message", {})
                chat_id = str(msg.get("chat", {}).get("id"))
                text = msg.get("text", "").strip()

                if chat_id == str(TELEGRAM_CHAT_ID):
                    if text.startswith("/addadmin "):
                        parts = text.split(" ")
                        if len(parts) >= 3:
                            admin_ip, device_name = parts[1], parts[2]
                            with db_lock:
                                conn = sqlite3.connect(DB_PATH)
                                c = conn.cursor()
                                c.execute("INSERT OR REPLACE INTO admin_whitelist (ip, device_name, added_at) VALUES (?, ?, ?)",
                                          (admin_ip, device_name, datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
                                conn.commit()
                                conn.close()
                            send_telegram(f"🛡 <b>Admin IP Terdaftar!</b>\n• Device: {device_name}\n• IP: <code>{admin_ip}</code>")
                    elif text.startswith("/deladmin "):
                        parts = text.split(" ")
                        if len(parts) >= 2:
                            target_ip = parts[1]
                            with db_lock:
                                conn = sqlite3.connect(DB_PATH)
                                c = conn.cursor()
                                c.execute("DELETE FROM admin_whitelist WHERE ip = ?", (target_ip,))
                                conn.commit()
                                conn.close()
                            send_telegram(f"🚫 <b>Akses Dicabut!</b>\n• IP: <code>{target_ip}</code>")
                    elif text.startswith("/addclient "):
                        parts = text.split(" ")
                        if len(parts) >= 4:
                            client_name, domain, backend = parts[1], parts[2].lower(), parts[3]
                            with db_lock:
                                conn = sqlite3.connect(DB_PATH)
                                c = conn.cursor()
                                c.execute("INSERT OR REPLACE INTO client_targets (domain, backend_url, client_name, status, added_at) VALUES (?, ?, ?, 'ACTIVE', ?)",
                                          (domain, backend, client_name, datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
                                conn.commit()
                                conn.close()
                            send_telegram(f"🎉 <b>Klien Terdaftar!</b>\n• {client_name} ({domain})")
        except:
            pass
        time.sleep(1)

threading.Thread(target=telegram_command_listener, daemon=True).start()

# Fungsi Anti-Bypass: Melakukan Recursive Decoding (menangkal double encoding)
def recursive_unquote(data: str) -> str:
    for _ in range(3): # Coba decode berlapis hingga 3 kali
        decoded = unquote(data)
        if decoded == data:
            break
        data = decoded
    return data

@app.before_request
def global_waf_interceptor():
    if request.path in ['/api/stats', '/api/store']:
        return

    host = request.host.lower().split(':')[0]
    client_ip = get_real_ip()
    path = request.path
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    # Kumpulkan seluruh komponen request (path, query string, body, headers penting)
    body_data = request.get_data(as_text=True)
    raw_full_req = f"{path} {request.query_string.decode('utf-8', errors='ignore')} {body_data} {request.headers.get('User-Agent', '')}"
    
    # Terapkan Recursive Decoding & Normalisasi (Ubah ke huruf kecil agar tidak bisa dikelabui case-switching)
    fully_decoded_req = recursive_unquote(raw_full_req).lower()

    threats = [name for name, pat in ANOMALY_PATTERNS.items() if re.search(pat, fully_decoded_req, re.IGNORECASE)]
    if path in HONEYPOT_TRAPS:
        threats.append("Honeypot Trap")

    if threats:
        with db_lock:
            conn = sqlite3.connect(DB_PATH)
            c = conn.cursor()
            c.execute("INSERT INTO logs (timestamp, ip, country, target_domain, method, path, is_threat, threats) VALUES (?, ?, 'ID 🇮🇩', ?, ?, ?, 1, ?)",
                      (timestamp, client_ip, host, request.method, path, ", ".join(threats)))
            conn.commit()
            conn.close()

        safe_path = html.escape(path)
        safe_threats = html.escape(", ".join(threats))
        alert_msg = (
            f"🚨 <b>ADVANCED WAF BLOCKED ATTACK!</b> 🚨\n"
            f"━━━━━━━━━━━━━━━━━━━\n"
            f"🌐 <b>IP Penyerang:</b> <code>{client_ip}</code>\n"
            f"🎯 <b>Target:</b> {host}\n"
            f"📌 <b>Path:</b> <code>{safe_path}</code>\n"
            f"⚠️ <b>Ancaman:</b> <code>{safe_threats}</code>\n"
            f"🛡 <b>Aksi:</b> Request DIBUNUH (HTTP 403 Forbidden)!\n"
            f"━━━━━━━━━━━━━━━━━━━"
        )
        send_telegram(alert_msg)
        return jsonify({"error": "Request Blocked by Advanced Security WAF Policy"}), 403

HTML_DASHBOARD = """
<!DOCTYPE html>
<html>
<head>
    <title>Garfield Elite SOC</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #080c14; color: #f8fafc; padding: 20px; margin: 0; }
        .header { background: linear-gradient(135deg, #1e293b, #0f172a); border: 1px solid #334155; border-radius: 12px; padding: 20px; margin-bottom: 20px; display: flex; justify-content: space-between; align-items: center; }
        h1 { color: #38bdf8; margin: 0; font-size: 22px; }
        .sys-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 25px; }
        .sys-card { background: #131b2e; border: 1px solid #1e293b; border-radius: 10px; padding: 15px; display: flex; align-items: center; justify-content: space-between; }
        .sys-val { font-size: 20px; font-weight: bold; color: #38bdf8; }
        .sys-label { font-size: 11px; color: #94a3b8; text-transform: uppercase; }
        .section-title { font-size: 14px; font-weight: bold; color: #94a3b8; margin: 20px 0 10px 0; text-transform: uppercase; letter-spacing: 1px; }
        .grid-clients { display: grid; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); gap: 20px; }
        .client-card { background: #131b2e; border: 1px solid #1e293b; border-radius: 12px; padding: 20px; }
        .client-header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #1e293b; padding-bottom: 12px; margin-bottom: 15px; }
        .client-title { font-size: 18px; font-weight: bold; color: #f8fafc; }
        .client-domain { font-size: 12px; color: #64748b; font-family: monospace; }
        .speedometer-box { width: 100%; height: 140px; display: flex; justify-content: center; align-items: center; }
        .speed-text { font-size: 22px; font-weight: bold; color: #38bdf8; text-align: center; margin-top: 5px; font-family: monospace; }
        .metrics-grid { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; margin-top: 15px; }
        .metric-box { background: #0a0f1d; padding: 10px; border-radius: 8px; text-align: center; border: 1px solid #1e293b; }
        .metric-label { font-size: 10px; color: #64748b; text-transform: uppercase; }
        .metric-val { font-size: 14px; font-weight: bold; margin-top: 3px; }
        .badge { font-size: 11px; padding: 4px 10px; border-radius: 6px; font-weight: bold; }
        .badge-online { background: rgba(34, 197, 94, 0.15); color: #22c55e; border: 1px solid rgba(34, 197, 94, 0.3); }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; font-size: 12px; }
        th, td { padding: 10px; text-align: left; border-bottom: 1px solid #1e293b; }
        th { background: #0a0f1d; color: #94a3b8; }
    </style>
</head>
<body>
    <div class="header">
        <div>
            <h1>🛡️ Garfield Multi-Tenant SOC Command Center</h1>
            <span style="color: #22c55e; font-size: 12px;">● Advanced WAF & Telemetry Sentinel Active</span>
        </div>
        <div style="font-size: 12px; color: #64748b;" id="clock">--:--:--</div>
    </div>

    <div class="sys-bar">
        <div class="sys-card"><div><div class="sys-label">Beban CPU</div><div class="sys-val" id="cpuVal">0%</div></div><span>⚙️</span></div>
        <div class="sys-card"><div><div class="sys-label">RAM Terpakai</div><div class="sys-val" id="ramVal">0%</div></div><span>🧠</span></div>
        <div class="sys-card"><div><div class="sys-label">Storage Disk</div><div class="sys-val" id="diskVal">0%</div></div><span>💾</span></div>
        <div class="sys-card"><div><div class="sys-label">Web Terlindungi</div><div class="sys-val" id="activeWebCount">0</div></div><span>🌐</span></div>
    </div>

    <div class="section-title">⚡ Website Telemetry (Ping & Health)</div>
    <div class="grid-clients" id="clientsGrid"></div>

    <div class="section-title" style="margin-top: 30px;">🛰️ Global Threat & Access Stream</div>
    <div style="background: #131b2e; border: 1px solid #1e293b; border-radius: 12px; padding: 15px;">
        <table>
            <thead>
                <tr><th>Waktu</th><th>Target Web</th><th>IP Client</th><th>Negara</th><th>Method & Path</th><th>Status</th></tr>
            </thead>
            <tbody id="logTable">
                <tr><td colspan="6" style="text-align: center; color: #64748b;">Memuat data...</td></tr>
            </tbody>
        </table>
    </div>

    <script>
        const clientCharts = {};
        async function updateDashboard() {
            try {
                let res = await fetch('/api/stats');
                let data = await res.json();
                
                document.getElementById('cpuVal').innerText = data.system.cpu + '%';
                document.getElementById('ramVal').innerText = data.system.ram + '%';
                document.getElementById('diskVal').innerText = data.system.disk + '%';
                document.getElementById('activeWebCount').innerText = data.clients.length;
                document.getElementById('clock').innerText = new Date().toLocaleTimeString();

                const grid = document.getElementById('clientsGrid');

                data.clients.forEach(c => {
                    const id = 'chart_' + c.domain.replace(/[^a-zA-Z0-9]/g, '_');
                    if (!document.getElementById(id)) {
                        const cardHtml = `
                            <div class="client-card">
                                <div class="client-header">
                                    <div><div class="client-title">${c.client_name}</div><div class="client-domain">${c.domain}</div></div>
                                    <span class="badge badge-online">● ONLINE</span>
                                </div>
                                <div class="speedometer-box"><canvas id="${id}"></canvas></div>
                                <div class="speed-text" id="ping_${id}">0 ms</div>
                                <div class="metrics-grid">
                                    <div class="metric-box"><div class="metric-label">Status</div><div class="metric-val" style="color:#22c55e;">HEALTHY</div></div>
                                    <div class="metric-box"><div class="metric-label">Total Traffic</div><div class="metric-val" id="tot_${id}" style="color:#38bdf8;">${c.total_logs}</div></div>
                                    <div class="metric-box"><div class="metric-label">Serangan Stop</div><div class="metric-val" id="thr_${id}" style="color:#ef4444;">${c.threats_count}</div></div>
                                </div>
                            </div>
                        `;
                        grid.insertAdjacentHTML('beforeend', cardHtml);
                        const ctx = document.getElementById(id).getContext('2d');
                        clientCharts[id] = new Chart(ctx, {
                            type: 'doughnut',
                            data: { datasets: [{ data: [0, 100], backgroundColor: ['#22c55e', '#1e293b'], borderWidth: 0 }] },
                            options: { circumference: 180, rotation: 270, cutout: '75%', plugins: { legend: { display: false } } }
                        });
                    }

                    document.getElementById('tot_' + id).innerText = c.total_logs;
                    document.getElementById('thr_' + id).innerText = c.threats_count;
                    document.getElementById('ping_' + id).innerText = c.latency + ' ms';
                    
                    let gaugeVal = Math.min(Math.max(c.latency / 5, 5), 100);
                    clientCharts[id].data.datasets[0].data = [gaugeVal, 100 - gaugeVal];
                    clientCharts[id].update();
                });

                let rows = '';
                data.logs.forEach(l => {
                    let badge = l.is_threat ? `<span style="color:#ef4444;font-weight:bold;">🚨 ${l.threats}</span>` : `<span style="color:#22c55e;">OK</span>`;
                    rows += `<tr><td>${l.timestamp}</td><td><b>${l.target_domain}</b></td><td><code>${l.ip}</code></td><td>${l.country}</td><td><b>${l.method}</b> ${l.path}</td><td>${badge}</td></tr>`;
                });
                if(rows) document.getElementById('logTable').innerHTML = rows;
            } catch(e) {}
        }
        setInterval(updateDashboard, 1500);
        updateDashboard();
    </script>
</body>
</html>
"""

PAGE_404 = """<!doctype html><html lang=en><title>404 Not Found</title><h1>Not Found</h1><p>The requested URL was not found on the server.</p>"""

@app.route('/', methods=['GET'])
@app.route('/dashboard', methods=['GET'])
def render_dashboard():
    host = request.host.lower().split(':')[0]
    client_ip = get_real_ip()

    # Perbaikan agar Tunnel Cloudflare (yang membawa host monitor.devgarf.my.id atau lokal) diizinkan masuk
    allowed_hosts = ["monitor.devgarf.my.id", "monitor.defgarf.my.id", "127.0.0.1", "localhost", "192.168.15.50"]
    if host not in allowed_hosts and not host.endswith("devgarf.my.id"):
        return proxy_handler('')

    # Auto-whitelist IP yang sedang mengakses agar tidak 404
    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute('INSERT OR IGNORE INTO admin_whitelist (ip, device_name, added_at) VALUES (?, ?, datetime("now"))', (client_ip, 'AutoAllow'))
        conn.commit()
        conn.close()

    if not is_admin_ip(client_ip):
        return render_template_string(PAGE_404), 404
    return render_template_string(HTML_DASHBOARD)

@app.route('/api/stats', methods=['GET'])
def get_stats():
    client_ip = get_real_ip()
    if not is_admin_ip(client_ip):
        return jsonify({"error": "Unauthorized"}), 403

    cpu_usage = psutil.cpu_percent(interval=None)
    ram_usage = psutil.virtual_memory().percent
    disk_usage = psutil.disk_usage('/').percent

    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        c = conn.cursor()
        c.execute("SELECT domain, backend_url, client_name, status FROM client_targets")
        clients_raw = [dict(row) for row in c.fetchall()]

        clients_data = []
        for cl in clients_raw:
            d = cl['domain']
            c.execute("SELECT COUNT(*) FROM logs WHERE target_domain = ?", (d,))
            tot = c.fetchone()[0]
            c.execute("SELECT COUNT(*) FROM logs WHERE target_domain = ? AND is_threat = 1", (d,))
            thr = c.fetchone()[0]
            cl['total_logs'] = tot
            cl['threats_count'] = thr
            probe = client_health_cache.get(d, {"alive": True, "latency": 15})
            cl['alive'] = probe.get("alive", True)
            cl['latency'] = probe.get("latency", 0)
            clients_data.append(cl)

        c.execute("SELECT timestamp, ip, country, target_domain, method, path, is_threat, threats FROM logs ORDER BY id DESC LIMIT 50")
        logs = [dict(row) for row in c.fetchall()]
        conn.close()

    return jsonify({
        "system": {"cpu": cpu_usage, "ram": ram_usage, "disk": disk_usage},
        "clients": clients_data, 
        "logs": logs
    })

@app.route('/api/store', methods=['GET'])
def get_store_api():
    sample_products = [
        {
            "id": 1,
            "name": "Garfield Auto Bot Script",
            "category": "Bot & Script",
            "description": "Script bot otomatis tingkat lanjut untuk pengelolaan telegram dan layanan digital secara instan.",
            "price": 150000,
            "image": "feature1.png",
            "badge": "HOT",
            "plans": [
                {"name": "Starter", "price": 100000, "hasDiscount": False},
                {"name": "Pro", "price": 150000, "hasDiscount": True, "discountPrice": 120000, "discountUntil": None}
            ]
        },
        {
            "id": 2,
            "name": "Custom Professional Website",
            "category": "Web Architecture",
            "description": "Pembuatan website modern, responsif, elegan, dan aman dari berbagai ancaman siber.",
            "price": 500000,
            "image": "feature3.png",
            "badge": "BEST SELLER",
            "plans": [
                {"name": "Landing Page", "price": 300000, "hasDiscount": False},
                {"name": "Full Company Profile", "price": 500000, "hasDiscount": True, "discountPrice": 450000, "discountUntil": None}
            ]
        }
    ]
    return jsonify({
        "success": True,
        "settings": {"telegram": "maongqw"},
        "products": sample_products
    })

@app.route('/<path:subpath>', methods=['GET', 'POST', 'PUT', 'DELETE'])
def proxy_handler(subpath):
    host = request.host.lower().split(':')[0]
    client_ip = get_real_ip()

    dashboard_hosts = ["monitor.devgarf.my.id", "monitor.defgarf.my.id", "127.0.0.1", "localhost"]
    if (host in dashboard_hosts or host.endswith("devgarf.my.id")) and subpath in ['dashboard', 'api/stats', 'api/store']:
        if subpath == 'api/store':
            return get_store_api()
        return render_dashboard()

    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("SELECT backend_url, client_name FROM client_targets WHERE domain = ? AND status = 'ACTIVE'", (host,))
        row = c.fetchone()
        conn.close()

    if not row:
        return render_template_string(PAGE_404), 404

    backend_url = row[0]
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("INSERT INTO logs (timestamp, ip, country, target_domain, method, path, is_threat, threats) VALUES (?, ?, 'ID 🇮🇩', ?, ?, ?, 0, '')",
                  (timestamp, client_ip, host, request.method, f"/{subpath}"))
        conn.commit()
        conn.close()

    target_url = f"{backend_url.rstrip('/')}/{subpath}"
    try:
        resp = requests.request(
            method=request.method,
            url=target_url,
            headers={k: v for k, v in request.headers if k != 'Host'},
            params=request.args,
            data=request.get_data(),
            cookies=request.cookies,
            allow_redirects=False,
            timeout=10
        )
        return Response(resp.content, resp.status_code)
    except Exception as e:
        return f"Proxy Error: {e}", 502

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=PORT, threaded=True)
