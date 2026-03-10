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

# 4. Xray (VLESS + Reality)
bash <(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
mkdir -p /usr/local/etc/xray

# Базовый config с Reality
cat > /usr/local/etc/xray/config.json << EOF
{
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "StatsService",
      "LoggerService",
      "RoutingService",
      "ReflectionService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "statsUserOnline": true
      }
    }
  },
  "log": {
    "loglevel": "info",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "tag": "vless-reality",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "askubuntu.com:443",
          "serverNames": [
            "$DOMAIN"
          ],
          "privateKey": "aFZR-H4qsoToNF-9hjNfdf6jtoaHHuAtbQpw8wsgdl4",
          "shortIds": [
            "0a381e1fa219",
            "be0ce04754dc",
            "41beec74f4bc"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    },
    {
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      },
      "tag": "api"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      }
    ]
  },
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "freedom",
      "tag": "api"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
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
import subprocess
import psutil
import tempfile
from filelock import FileLock
from typing import Dict, List
from datetime import datetime
from pydantic import BaseModel

app = FastAPI(title="VPN Agent")

AGENT_SECRET = os.getenv("AGENT_SECRET")
CENTRAL_API = os.getenv("CENTRAL_API")
SERVER_ID = os.getenv("SERVER_ID")

CONFIG_PATH = "/usr/local/etc/xray/config.json"
LOCK_PATH = "/tmp/xray_config.lock"
SYNC_INTERVAL = 30
METRICS_INTERVAL = 15

lock = FileLock(LOCK_PATH)
API_SERVER = "127.0.0.1:10085"  # твой API порт
INBOUND_TAG = "vless-reality"
PORT = 443
PROTOCOL = "vless"
DECRYPTION = "none"
FLOW = "xtls-rprx-vision"

api_lock = asyncio.Lock()

# ================= CONFIG =================
def load_config():
    with open(CONFIG_PATH, "r") as f:
        return json.load(f)

def save_config(config):
    with open(CONFIG_PATH, "w") as f:
        json.dump(config, f, indent=2)

def reload_xray():
    try:
        subprocess.run(["systemctl", "reload", "xray"], check=True, timeout=10)
    except Exception as e:
        print(f"Reload failed: {e}")

# ================= XRAY API HELPERS =================
def run_xray_api(cmd: List[str], timeout=10) -> Dict:
    """Универсальный вызов xray api с обработкой ошибок"""
    try:
        full_cmd = ["xray", "api"] + cmd + ["--server", API_SERVER]
        result = subprocess.check_output(full_cmd, text=True, timeout=timeout, stderr=subprocess.STDOUT)
        return json.loads(result)
    except subprocess.TimeoutExpired:
        print(f"Timeout on {' '.join(full_cmd)}")
        return {}
    except subprocess.CalledProcessError as e:
        print(f"Error on {' '.join(full_cmd)}: {e.output}")
        return {}
    except json.JSONDecodeError:
        print(f"Invalid JSON from {' '.join(full_cmd)}")
        return {}
    except Exception as e:
        print(f"Unexpected error: {e}")
        return {}
    
    
def run_xray_api_cmd_end(cmd: List[str], timeout=10) -> Dict:
    """Универсальный вызов xray api с обработкой ошибок"""
    try:
        full_cmd = ["xray", "api"] + cmd
        result = subprocess.check_output(full_cmd, text=True, timeout=timeout, stderr=subprocess.STDOUT)
        return json.loads(result)
    except subprocess.TimeoutExpired:
        print(f"Timeout on {' '.join(full_cmd)}")
        return {}
    except subprocess.CalledProcessError as e:
        print(f"Error on {' '.join(full_cmd)}: {e.output}")
        return {}
    except json.JSONDecodeError:
        print(f"Invalid JSON from {' '.join(full_cmd)}")
        return {}
    except Exception as e:
        print(f"Unexpected error: {e}")
        return {}

# ================= ONLINE & STATS =================
def get_all_stats() -> Dict:
    """Получает все статистики одним запросом (самый эффективный способ)"""
    return run_xray_api(["statsquery"])

def get_all_emails_from_inbound(tag: str = "vless-reality") -> List[str]:
    """Получает список всех email'ов из указанного inbound"""
    resp = run_xray_api(["inbounduser", "--tag", tag])
    if not resp or "users" not in resp:
        print("inbounduser returned empty or invalid response")
        return []

    emails = []
    for user in resp["users"]:
        email = user.get("email")
        if email:
            emails.append(email)
    return emails


def get_online_users_detailed() -> List[Dict]:
    online = []
    emails = get_all_emails_from_inbound("vless-reality")  # или передавай тег как параметр

    for email in emails:
        # Кол-во активных сессий
        online_resp = run_xray_api(["statsonline", "--email", email])
        sessions_str = online_resp.get("stat", {}).get("value", "0")
        try:
            sessions = int(sessions_str)
        except (ValueError, TypeError):
            sessions = 0

        if sessions == 0:
            continue

        # IP-адреса + время последней активности
        iplist_resp = run_xray_api(["statsonlineiplist", "--email", email])
        ips_data = iplist_resp.get("ips", {})

        ips_formatted = {}
        last_activity = 0
        for ip, ts in ips_data.items():
            try:
                ts_int = int(ts)
                ips_formatted[ip] = ts_int
                last_activity = max(last_activity, ts_int)
            except:
                pass  # пропускаем некорректные значения

        if last_activity == 0 and ips_formatted:
            # fallback — берём максимум из доступных
            last_activity = max(ips_formatted.values(), default=0)

        online.append({
            "email": email,
            "active_sessions": sessions,
            "ips": ips_formatted,
            "last_activity_unix": last_activity,
            "last_activity": (
                datetime.utcfromtimestamp(last_activity).strftime("%Y-%m-%d %H:%M:%S UTC")
                if last_activity > 0 else None
            )
        })

    return online

def parse_traffic_stats(stats: Dict) -> Dict:
    """Парсит трафик из statsquery"""
    traffic = {
        "users": {},
        "inbounds": {},
        "outbounds": {}
    }

    for stat in stats.get("stat", []):
        name = stat.get("name", "")
        value = int(stat.get("value", 0))

        parts = name.split(">>>")
        if len(parts) < 3:
            continue

        category, key, metric_type, direction = parts if len(parts) == 4 else (parts[0], parts[1], parts[2], None)

        if category == "user":
            email = key
            if metric_type == "traffic":
                if email not in traffic["users"]:
                    traffic["users"][email] = {"uplink": 0, "downlink": 0}
                if direction == "uplink":
                    traffic["users"][email]["uplink"] += value
                elif direction == "downlink":
                    traffic["users"][email]["downlink"] += value

        elif category == "inbound":
            tag = key
            if metric_type == "traffic":
                if tag not in traffic["inbounds"]:
                    traffic["inbounds"][tag] = {"uplink": 0, "downlink": 0}
                if direction == "uplink":
                    traffic["inbounds"][tag]["uplink"] += value
                elif direction == "downlink":
                    traffic["inbounds"][tag]["downlink"] += value

        elif category == "outbound":
            tag = key
            if metric_type == "traffic":
                if tag not in traffic["outbounds"]:
                    traffic["outbounds"][tag] = {"uplink": 0, "downlink": 0}
                if direction == "uplink":
                    traffic["outbounds"][tag]["uplink"] += value
                elif direction == "downlink":
                    traffic["outbounds"][tag]["downlink"] += value

    return traffic

# ================= METRICS =================
def collect_metrics():
    cpu = psutil.cpu_percent(interval=0.5)
    ram = psutil.virtual_memory().percent
    disk = psutil.disk_usage("/").percent
    net = psutil.net_io_counters(pernic=False)

    stats = get_all_stats()
    traffic = parse_traffic_stats(stats)
    online_detailed = get_online_users_detailed()

    return {
        "timestamp": datetime.utcnow().isoformat(),
        "server_id": SERVER_ID,
        "cpu_percent": round(cpu, 1),
        "ram_percent": round(ram, 1),
        "disk_percent": round(disk, 1),
        "network": {
            "bytes_recv": net.bytes_recv,
            "bytes_sent": net.bytes_sent,
            "packets_recv": net.packets_recv,
            "packets_sent": net.packets_sent,
            "errin": net.errin,
            "errout": net.errout,
            "dropin": net.dropin,
            "dropout": net.dropout
        },
        "xray_traffic": traffic,
        "online_users": online_detailed,
        "active_users_count": len(online_detailed),
        "total_user_traffic_bytes": {
            "uplink_sum": sum(u["uplink"] for u in traffic["users"].values()),
            "downlink_sum": sum(u["downlink"] for u in traffic["users"].values())
        }
    }

async def metrics_loop():
    while True:
        try:
            metrics = collect_metrics()
            async with httpx.AsyncClient(timeout=20) as client:
                resp = await client.post(
                    f"{CENTRAL_API}/servers/metrics/ingest?server_id={SERVER_ID}",
                    json=metrics,
                    headers={"X-Agent-Secret": AGENT_SECRET}
                )
                if resp.status_code >= 400:
                    print(f"Central API error: {resp.status_code} {resp.text}")
        except Exception as e:
            print(f"Metrics push error: {e}")
        await asyncio.sleep(METRICS_INTERVAL)

# ================= USER MANAGEMENT =================
class AddUserRequest(BaseModel):
    email: str
    uuid: str

class BootstrapResponse(BaseModel):
    users: List[AddUserRequest]

class RemoveUserRequest(BaseModel):
    email: str

@app.post("/add_user")
async def add_user(
    req: AddUserRequest,
    secret: str = Header(..., alias="X-Agent-Secret")
):
    if secret != AGENT_SECRET:
        raise HTTPException(status_code=403, detail="Invalid secret")
    
    async with api_lock:
        # Генерируем JSON для добавления
        data = {
            "inbounds": [
                {
                    "tag": INBOUND_TAG,
                    "protocol": PROTOCOL,
                    "port": PORT,
                    "settings": {
                        "decryption": DECRYPTION,
                        "clients": [
                            {
                                "email": req.email,
                                "id": req.uuid,
                                "flow": FLOW
                            }
                        ]
                    }
                }
            ]
        }
        
        temp_path = None
        try:
            with tempfile.NamedTemporaryFile(mode="w+", delete=False, suffix=".json") as temp:
                json.dump(data, temp)
                temp_path = temp.name
            
            # Вызываем API
            resp = run_xray_api_cmd_end(["adu", f"--server={API_SERVER}", temp_path])
            return {"status": "ok", "added": req.email, "response": resp}
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))
        finally:
            if temp_path and os.path.exists(temp_path):
                os.unlink(temp_path)

@app.post("/remove_user")
async def remove_user(
    req: RemoveUserRequest,
    secret: str = Header(..., alias="X-Agent-Secret")
):
    if secret != AGENT_SECRET:
        raise HTTPException(status_code=403, detail="Invalid secret")
    
    async with api_lock:
        email = req.email.strip()
        
        # Прямая команда без файла
        cmd = ["xray", "api", "rmu", f"--server={API_SERVER}", f"-tag={INBOUND_TAG}", email]
        
        try:
            # Используем subprocess для выполнения и захвата вывода
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=15,
                check=False
            )
            
            if result.returncode != 0:
                error_msg = result.stderr.strip() or result.stdout.strip() or "Unknown error"
                raise HTTPException(status_code=500, detail=f"rmu failed: {error_msg}")
            
            output = result.stdout.strip()
            # Обычно при успехе вывод пустой или "Removed 1 user(s)"
            return {
                "status": "success",
                "removed_email": email,
                "xray_output": output or "ok (no output)"
            }
        
        except subprocess.TimeoutExpired:
            raise HTTPException(status_code=504, detail="rmu command timed out")
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Execution error: {str(e)}")

async def bootstrap_users():

    async with httpx.AsyncClient(timeout=60) as client:

        resp = await client.post(
            f"{CENTRAL_API}/servers/bootstrap?server_id={SERVER_ID}",
            headers={"X-Agent-Secret": AGENT_SECRET}
        )

        if resp.status_code != 200:
            print("Bootstrap failed:", resp.text)
            return

        data = BootstrapResponse(**resp.json())

        if not data.users:
            print("No users to bootstrap")
            return

        print(f"Bootstrapping {len(data.users)} users")

        await add_users_batch(data.users)


async def add_users_batch(users: List[User]):
    async with api_lock:
        clients = []
        for u in users:
            clients.append({
                "email": u.email,
                "id": u.uuid,
                "flow": FLOW
            })

        data = {
            "inbounds": [
                {
                    "tag": INBOUND_TAG,
                    "protocol": PROTOCOL,
                    "port": PORT,
                    "settings": {
                        "decryption": DECRYPTION,
                        "clients": clients
                    }
                }
            ]
        }

        temp_path = None
        try:
            with tempfile.NamedTemporaryFile(mode="w+", delete=False, suffix=".json") as temp:
                json.dump(data, temp)
                temp_path = temp.name
            resp = run_xray_api_cmd_end(
                ["adu", f"--server={API_SERVER}", temp_path]
            )
            print(f"Added {len(users)} users")
        except Exception as e:
            print("Batch add error:", e)
        finally:
            if temp_path and os.path.exists(temp_path):
                os.unlink(temp_path)


@app.on_event("startup")
async def startup_event():
    print("VPN Agent starting...")
    
    try:
        await bootstrap_users()
    except Exception as e:
        print("Bootstrap error:", e)
        
    asyncio.create_task(metrics_loop())

# Опционально: эндпоинт для ручной проверки метрик
@app.get("/metrics")
def get_current_metrics():
    return collect_metrics()
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
ExecStart=/opt/vpn-agent/venv/bin/uvicorn agent:app --host 0.0.0.0 --port 8001
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vpn-agent

systemctl restart xray
sleep 3
systemctl restart vpn-agent

# 7. Финальная регистрация
curl -X POST "$CENTRAL_API/servers/metrics/ingest?server_id=$SERVER_ID" \
  -H "X-Agent-Secret: $AGENT_SECRET" \
  -d '{"cpu":0,"ram":0,"network_in_mb":0,"network_out_mb":0,"active_users":0}' || true

echo "=== УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА ==="
echo "Домен: $DOMAIN"
echo "Агент работает на порту 8001"
echo "Можно добавлять пользователей!"
