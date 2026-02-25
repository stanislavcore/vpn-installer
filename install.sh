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
EOF

venv/bin/pip install -r requirements.txt

# === СОЗДАЁМ agent.py ===
cat > agent.py << 'EOP'
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel
import psutil
import subprocess
import json
import os
import asyncio
import httpx
from datetime import datetime

app = FastAPI(title="VPN Agent")

AGENT_SECRET = os.getenv("AGENT_SECRET")
CENTRAL_API = os.getenv("CENTRAL_API")
SERVER_ID = os.getenv("SERVER_ID")

class AddUser(BaseModel):
    uuid: str

# ====================== ЭНДПОИНТЫ ======================
@app.get("/metrics")
async def get_metrics(secret: str = Header(..., alias="X-Agent-Secret")):
    if secret != AGENT_SECRET:
        raise HTTPException(403)
    cpu = psutil.cpu_percent(interval=1)
    ram = psutil.virtual_memory().percent
    net = psutil.net_io_counters()
    active = 0
    try:
        out = subprocess.check_output(
            ["xray", "api", "statsquery", "--name", "inbound>>vless-reality>>users"],
            text=True, timeout=5
        )
        active = len(json.loads(out).get("stat", []))
    except:
        pass
    return {
        "cpu": round(cpu, 1),
        "ram": round(ram, 1),
        "network_in_mb": net.bytes_recv // 1024 // 1024,
        "network_out_mb": net.bytes_sent // 1024 // 1024,
        "active_users": active
    }

@app.post("/add_user")
async def add_user(data: AddUser, secret: str = Header(..., alias="X-Agent-Secret")):
    if secret != AGENT_SECRET:
        raise HTTPException(403)
    cmd = f'xray api adduser --inboundTag="vless-reality" --userId="{data.uuid}"'
    subprocess.check_output(cmd, shell=True, timeout=10)
    return {"status": "ok"}

@app.post("/remove_user")
async def remove_user(data: AddUser, secret: str = Header(..., alias="X-Agent-Secret")):
    if secret != AGENT_SECRET:
        raise HTTPException(403)
    try:
        cmd = f'xray api removeuser --inboundTag="vless-reality" --userId="{data.uuid}"'
        subprocess.check_output(cmd, shell=True, timeout=10)
        return {"status": "ok"}
    except Exception as e:
        raise HTTPException(500, str(e))

@app.post("/update_reality")
async def update_reality(secret: str = Header(..., alias="X-Agent-Secret")):
    if secret != AGENT_SECRET:
        raise HTTPException(403)
    subprocess.run(["systemctl", "restart", "xray"], check=True)
    return {"status": "reloaded"}

# ====================== ФОНОВАЯ ЗАДАЧА ======================
async def send_metrics_loop():
    while True:
        try:
            data = await get_metrics(AGENT_SECRET)
            async with httpx.AsyncClient() as client:
                await client.post(
                    f"{CENTRAL_API}/api/servers/metrics/ingest?server_id={SERVER_ID}",
                    json=data,
                    headers={"X-Agent-Secret": AGENT_SECRET}
                )
        except:
            pass
        await asyncio.sleep(15)

@app.on_event("startup")
async def startup_event():
    asyncio.create_task(send_metrics_loop())

# ====================== ЗАПУСК ======================
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8001)
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
