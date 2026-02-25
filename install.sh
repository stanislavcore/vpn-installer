#!/bin/bash
set -e

# ====================== ПАРАМЕТРЫ ======================
DOMAIN=""
CENTRAL_API=""
AGENT_SECRET=""
SERVER_ID=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain) DOMAIN="$2"; shift; shift ;;
    --central-api) CENTRAL_API="$2"; shift; shift ;;
    --agent-secret) AGENT_SECRET="$2"; shift; shift ;;
    --server-id) SERVER_ID="$2"; shift; shift ;;
    *) echo "Неизвестный параметр $1"; exit 1 ;;
  esac
done

if [ -z "$DOMAIN" ] || [ -z "$AGENT_SECRET" ] || [ -z "$SERVER_ID" ]; then
  echo "Ошибка: не все параметры переданы!"
  exit 1
fi

echo "=== Автоматическая установка VPN-сервера (Ubuntu 24.04) ==="
echo "Домен: $DOMAIN"
echo "Central API: $CENTRAL_API"
echo "Server ID: $SERVER_ID"

# 1. Обновление системы
apt update && apt upgrade -y
apt install -y curl wget unzip jq ufw python3 python3-venv python3-pip git

# 2. Firewall
ufw allow 22/tcp
ufw allow 443/tcp
ufw allow 8001
ufw --force enable

# 3. Caddy (самый простой reverse-proxy)
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

# 4. Xray (VLESS + Reality)
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh) --version 1.8.23
mkdir -p /usr/local/etc/xray

# Базовый config с Reality
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "tag": "vless-reality",
    "settings": {
      "clients": [],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.microsoft.com:443",
        "xver": 0,
        "serverNames": ["www.microsoft.com", "microsoft.com"],
        "privateKey": "YOUR_PRIVATE_KEY_HERE",   # будет заменён при первой ротации
        "shortIds": ["0123456789abcdef"]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom"}],
  "api": {"services": ["HandlerService", "StatsService"], "tag": "api"},
  "stats": {}
}
EOF

systemctl enable --now xray

# 5. Python Agent
mkdir -p /opt/vpn-agent
cd /opt/vpn-agent

python3 -m venv venv

cat > requirements.txt << EOF
fastapi
uvicorn[standard]
psutil
httpx
python-dotenv
filelock
EOF

venv/bin/pip install -r requirements.txt

# === СОЗДАЁМ agent.py ===
cat > agent.py << 'EOP'
from fastapi import FastAPI, Header, HTTPException
import asyncio
import httpx
import os
import json
import hashlib
import subprocess
import psutil
from filelock import FileLock
from typing import List

app = FastAPI(title="VPN Agent")

AGENT_SECRET = os.getenv("AGENT_SECRET")
CENTRAL_API = os.getenv("CENTRAL_API")
SERVER_ID = os.getenv("SERVER_ID")

CONFIG_PATH = "/usr/local/etc/xray/config.json"
LOCK_PATH = "/tmp/xray_config.lock"

SYNC_INTERVAL = 30
METRICS_INTERVAL = 15

lock = FileLock(LOCK_PATH)
current_hash = None


# ================= CONFIG =================

def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)

def save_config(config):
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)

def reload_xray():
    subprocess.run(["systemctl", "reload", "xray"], check=True)


# ================= USERS SYNC =================

async def fetch_desired_users():
    async with httpx.AsyncClient(timeout=20) as client:
        resp = await client.get(
            f"{CENTRAL_API}/api/servers/{SERVER_ID}/desired-users",
            headers={"X-Agent-Secret": AGENT_SECRET}
        )
        resp.raise_for_status()
        return resp.json()


def apply_sync(target_users: List[str]):
    with lock:
        config = load_config()
        clients = config["inbounds"][0]["settings"]["clients"]

        current = {c["id"] for c in clients}
        target = set(target_users)

        to_add = target - current
        to_remove = current - target

        if not to_add and not to_remove:
            return False

        clients = [c for c in clients if c["id"] not in to_remove]

        for uuid in to_add:
            clients.append({
                "id": uuid,
                "flow": "",
            })

        config["inbounds"][0]["settings"]["clients"] = clients
        save_config(config)

        reload_xray()

        return True


async def sync_loop():
    global current_hash

    while True:
        try:
            data = await fetch_desired_users()

            if data["config_hash"] != current_hash:
                changed = apply_sync(data["users"])

                if changed:
                    print("Users synced and Xray reloaded")

                current_hash = data["config_hash"]

        except Exception as e:
            print("Sync error:", e)

        await asyncio.sleep(SYNC_INTERVAL)


# ================= METRICS =================

def collect_metrics():
    cpu = psutil.cpu_percent(interval=1)
    ram = psutil.virtual_memory().percent
    net = psutil.net_io_counters()

    active_users = len(get_online_users_internal())

    return {
        "cpu": round(cpu, 1),
        "ram": round(ram, 1),
        "network_in_mb": net.bytes_recv // 1024 // 1024,
        "network_out_mb": net.bytes_sent // 1024 // 1024,
        "active_users": active_users
    }


async def metrics_loop():
    while True:
        try:
            metrics = collect_metrics()

            async with httpx.AsyncClient(timeout=15) as client:
                await client.post(
                    f"{CENTRAL_API}/api/servers/metrics/ingest?server_id={SERVER_ID}",
                    json=metrics,
                    headers={"X-Agent-Secret": AGENT_SECRET}
                )

        except Exception as e:
            print("Metrics push error:", e)

        await asyncio.sleep(METRICS_INTERVAL)


# ================= ONLINE USERS =================

def get_online_users_internal():
    try:
        result = subprocess.check_output(
            ["xray", "api", "statsquery"],
            text=True,
            timeout=5
        )
        data = json.loads(result)
        stats = data.get("stat", [])

        online = []
        for item in stats:
            name = item.get("name", "")
            if "user>>>" in name and "online" in name:
                uuid = name.split(">>>")[1]
                online.append(uuid)

        return online

    except:
        return []


@app.get("/online")
async def get_online(secret: str = Header(..., alias="X-Agent-Secret")):
    if secret != AGENT_SECRET:
        raise HTTPException(403)

    return {"online_users": get_online_users_internal()}


# ================= HEALTH =================

@app.get("/health")
async def health():
    return {"status": "ok"}


# ================= STARTUP =================

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(sync_loop())
    asyncio.create_task(metrics_loop())
EOP

# Systemd сервис агента
cat > /etc/systemd/system/vpn-agent.service << EOF
[Unit]
Description=VPN Agent
After=network.target

[Service]
WorkingDirectory=/opt/vpn-agent
Environment=AGENT_SECRET=$AGENT_SECRET
Environment=CENTRAL_API=$CENTRAL_API
Environment=SERVER_ID=$SERVER_ID
ExecStart=/opt/vpn-agent/venv/bin/python agent.py
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-agent

# 6. Caddyfile (Reality + fallback)
cat > /etc/caddy/Caddyfile << EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:443 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
systemctl restart caddy

# 7. Финальная регистрация
curl -X POST "$CENTRAL_API/servers/metrics/ingest?server_id=$SERVER_ID" \
  -H "X-Agent-Secret: $AGENT_SECRET" \
  -d '{"cpu":0,"ram":0,"network_in_mb":0,"network_out_mb":0,"active_users":0}' || true

echo "=== УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА ==="
echo "Домен: $DOMAIN"
echo "Агент работает на порту 8001"
echo "Можно добавлять пользователей!"
