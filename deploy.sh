#!/usr/bin/env bash
# deploy.sh — direct host deployment for backend + frontend (no Docker)
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=""
BACKEND_SERVICE="layout-backend"
FRONTEND_SERVICE="layout-frontend"
NGINX_CONF="/etc/nginx/sites-available/layout-host"
BACKEND_PORT="8000"
FRONTEND_PORT="3000"
TMP_ROOT=""
PUBLIC_IP=""
APP_TITLE="Manuscript Layout Analysis"

cleanup() {
  [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT" || true
}
trap cleanup EXIT

log() { echo "==> $*"; }
fail() { echo; echo "!! $*"; exit 1; }

detect_repo_dir() {
  if [ -d "$SCRIPT_DIR/.git" ] && [ -d "$SCRIPT_DIR/backend" ] && [ -d "$SCRIPT_DIR/frontend" ]; then
    echo "$SCRIPT_DIR"; return
  fi
  if [ -d "$PWD/.git" ] && [ -d "$PWD/backend" ] && [ -d "$PWD/frontend" ]; then
    echo "$PWD"; return
  fi
  if [ -d "$PWD/layout/.git" ] && [ -d "$PWD/layout/backend" ] && [ -d "$PWD/layout/frontend" ]; then
    echo "$PWD/layout"; return
  fi
  echo ""
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -4fsS https://ifconfig.me 2>/dev/null || true)"
  [ -n "$ip" ] || ip="$(curl -4fsS https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  echo "$ip"
}

ensure_node_20() {
  local major="0"
  if command -v node >/dev/null 2>&1; then
    major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  fi
  if [ "$major" -lt 20 ]; then
    log "Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt-get install -y --no-install-recommends nodejs
  fi
}

check_weights() {
  [ -f "$REPO_DIR/backend/models/best_catmus.pt" ] &&
  [ -f "$REPO_DIR/backend/models/best_emanuskript_segmentation.pt" ] &&
  [ -f "$REPO_DIR/backend/models/best_zone_detection.pt" ]
}

free_space() {
  log "Freeing disk space..."
  sudo apt-get clean || true
  sudo apt-get autoremove -y || true
  sudo rm -rf /tmp/* /var/tmp/* || true
  rm -rf "$HOME/.cache" "$HOME/.npm" || true
  rm -rf "$REPO_DIR/frontend/.next" "$REPO_DIR/frontend/node_modules" || true
  rm -rf "$REPO_DIR/backend/.venv" "$REPO_DIR/.deploy-tmp" || true
  sudo journalctl --vacuum-time=1d || true
  if command -v docker >/dev/null 2>&1; then
    sudo docker system prune -a -f --volumes || true
  fi
}

require_space() {
  local avail_kb
  avail_kb="$(df --output=avail / | tail -1 | tr -d ' ')"
  [ -n "$avail_kb" ] || fail "Could not determine free disk space."
  [ "$avail_kb" -ge 1500000 ] || fail "Need at least ~1.5 GB free on / before deployment."
}

disable_conflicting_services() {
  log "Disabling conflicting web services..."
  for svc in caddy apache2; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
      sudo systemctl stop "$svc" || true
      sudo systemctl disable "$svc" || true
    fi
  done
}

disable_old_public_configs() {
  log "Disabling old public nginx configs..."
  sudo mkdir -p /etc/nginx/disabled-by-layout

  sudo rm -f /etc/nginx/sites-enabled/* || true

  while IFS= read -r -d '' f; do
    if sudo grep -qiE 'duckdns\.org|thelayout|layout\.duckdns|thelayout\.duckdns' "$f"; then
      sudo mv "$f" "/etc/nginx/disabled-by-layout/$(basename "$f").bak.$(date +%s)" || true
    fi
  done < <(sudo find /etc/nginx \
    \( -path "/etc/nginx/sites-available/*" -o -path "/etc/nginx/conf.d/*" \) \
    \( -type f -o -type l \) -print0 2>/dev/null)
}

write_backend_service() {
  sudo tee "/etc/systemd/system/${BACKEND_SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=Layout Backend API
After=network.target

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}/backend
Environment=MODEL_DIR=${REPO_DIR}/backend/models
Environment=CORS_ORIGINS=http://${PUBLIC_IP}
Environment=PYTHONUNBUFFERED=1
ExecStart=${REPO_DIR}/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port ${BACKEND_PORT} --workers 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_frontend_service() {
  sudo tee "/etc/systemd/system/${FRONTEND_SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=Layout Frontend
After=network.target ${BACKEND_SERVICE}.service
Requires=${BACKEND_SERVICE}.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}/frontend
Environment=NODE_ENV=production
Environment=PORT=${FRONTEND_PORT}
ExecStart=/usr/bin/env npm run start -- --hostname 127.0.0.1 --port ${FRONTEND_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_config() {
  sudo tee "$NGINX_CONF" >/dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 200M;
    add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;

    location ^~ /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location = /docs {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location = /openapi.json {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location = /redoc {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/redoc;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location / {
        proxy_pass http://127.0.0.1:${FRONTEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
}

verify_local_frontend() {
  curl -fsS "http://127.0.0.1:${FRONTEND_PORT}" | grep -q "${APP_TITLE}" \
    || fail "Local frontend on port ${FRONTEND_PORT} is not serving the expected app."
}

verify_local_nginx() {
  curl -fsS "http://127.0.0.1" | grep -q "${APP_TITLE}" \
    || fail "Local nginx is not serving the expected frontend."
}

verify_public_route() {
  if curl -fsS "http://${PUBLIC_IP}" | grep -q "${APP_TITLE}"; then
    log "Public IP is serving the expected frontend."
  else
    echo
    echo "!! Local deployment is correct, but public IP is not serving the same frontend."
    echo "!! This usually means external routing / NAT / DNS is still pointing to an old public setup."
    echo "!! Local nginx is correct. Public URL may still be handled outside this VM."
  fi
}

log "Installing base packages..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git nginx python3 python3-pip python3-venv \
  build-essential libgl1 libglib2.0-0 libsm6 libxext6 libxrender1

log "Resolving repository path..."
REPO_DIR="$(detect_repo_dir)"
if [ -z "$REPO_DIR" ]; then
  git clone https://github.com/emanuskript/layout.git "$PWD/layout"
  REPO_DIR="$PWD/layout"
fi
cd "$REPO_DIR"

ensure_node_20

log "Checking model weights..."
check_weights || fail "Missing model weights in backend/models."

PUBLIC_IP="$(detect_public_ip)"
[ -n "$PUBLIC_IP" ] || fail "Unable to detect public IP."

free_space
require_space
disable_conflicting_services
disable_old_public_configs

TMP_ROOT="${REPO_DIR}/.deploy-tmp"
mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"
export TEMP="$TMP_ROOT"
export TMP="$TMP_ROOT"

log "Preparing backend venv..."
python3 -m venv "$REPO_DIR/backend/.venv"
"$REPO_DIR/backend/.venv/bin/pip" install --upgrade pip setuptools wheel

log "Installing backend dependencies..."
TMPDIR="$TMP_ROOT" "$REPO_DIR/backend/.venv/bin/pip" install --no-cache-dir \
  --index-url https://download.pytorch.org/whl/cpu torch torchvision
TMPDIR="$TMP_ROOT" "$REPO_DIR/backend/.venv/bin/pip" install --no-cache-dir \
  -e "$REPO_DIR/backend"

log "Building frontend..."
cd "$REPO_DIR/frontend"
rm -rf .next node_modules
if [ -f package-lock.json ]; then
  TMPDIR="$TMP_ROOT" npm ci --cache "$TMP_ROOT/.npm-cache"
else
  TMPDIR="$TMP_ROOT" npm install --cache "$TMP_ROOT/.npm-cache"
fi
BACKEND_URL="/api" NEXT_PUBLIC_BACKEND_URL="/api" TMPDIR="$TMP_ROOT" npm run build
cd "$REPO_DIR"

log "Writing services and nginx config..."
write_backend_service
write_frontend_service
write_nginx_config
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/layout-host

log "Restarting services..."
sudo systemctl daemon-reload
sudo systemctl enable "$BACKEND_SERVICE" "$FRONTEND_SERVICE" nginx
sudo systemctl stop "$FRONTEND_SERVICE" || true
sudo pkill -f "next.*3000" || true
sudo pkill -f "next-server" || true
sudo pkill -f "next start" || true
sudo systemctl restart "$BACKEND_SERVICE"
sudo systemctl start "$FRONTEND_SERVICE"
sudo nginx -t
sudo systemctl restart nginx

sleep 3

sudo systemctl is-active --quiet "$BACKEND_SERVICE" || fail "Backend service not active."
sudo systemctl is-active --quiet "$FRONTEND_SERVICE" || fail "Frontend service not active."
sudo systemctl is-active --quiet nginx || fail "nginx not active."

verify_local_frontend
verify_local_nginx
verify_public_route

echo
echo "==> Deployment complete"
echo "Frontend URL: http://${PUBLIC_IP}"
echo "Backend local: http://127.0.0.1:${BACKEND_PORT}"
echo "Services: ${BACKEND_SERVICE}, ${FRONTEND_SERVICE}, nginx"