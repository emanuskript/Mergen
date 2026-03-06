#!/usr/bin/env bash
# deploy.sh — direct host deployment for backend + frontend (no Docker)
# Usage: bash deploy.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=""
BACKEND_SERVICE="layout-backend"
FRONTEND_SERVICE="layout-frontend"
NGINX_CONF="/etc/nginx/sites-available/layout-host"
TMP_ROOT=""
PUBLIC_IP=""
BACKEND_PORT="8000"
FRONTEND_PORT="3000"

cleanup() {
  if [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT:-}" ]; then
    rm -rf "$TMP_ROOT" || true
  fi
}
trap cleanup EXIT

log() {
  echo "==> $*"
}

fail() {
  echo ""
  echo "!! $*"
  exit 1
}

detect_repo_dir() {
  if [ -d "$SCRIPT_DIR/.git" ] && [ -d "$SCRIPT_DIR/backend" ] && [ -d "$SCRIPT_DIR/frontend" ]; then
    echo "$SCRIPT_DIR"
    return
  fi

  if [ -d "$PWD/.git" ] && [ -d "$PWD/backend" ] && [ -d "$PWD/frontend" ]; then
    echo "$PWD"
    return
  fi

  if [ -d "$PWD/layout/.git" ] && [ -d "$PWD/layout/backend" ] && [ -d "$PWD/layout/frontend" ]; then
    echo "$PWD/layout"
    return
  fi

  echo ""
}

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4fsS https://ifconfig.me 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -4fsS https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  echo "$ip"
}

ensure_node_20() {
  local major="0"

  if command -v node >/dev/null 2>&1; then
    major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  fi

  if [ "$major" -ge 20 ]; then
    return
  fi

  log "Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y --no-install-recommends nodejs
}

check_weights() {
  [ -f "$REPO_DIR/backend/models/best_catmus.pt" ] || return 1
  [ -f "$REPO_DIR/backend/models/best_emanuskript_segmentation.pt" ] || return 1
  [ -f "$REPO_DIR/backend/models/best_zone_detection.pt" ] || return 1
}

write_backend_service() {
  sudo tee "/etc/systemd/system/${BACKEND_SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=Layout Backend API (FastAPI)
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
Description=Layout Frontend (Next.js)
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
  sudo tee "$NGINX_CONF" >/dev/null <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 200M;

    location /api/ {
        proxy_pass http://127.0.0.1:8000/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF
}

log "Installing base system packages..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  git \
  nginx \
  python3 \
  python3-pip \
  python3-venv \
  build-essential \
  libgl1 \
  libglib2.0-0 \
  libsm6 \
  libxext6 \
  libxrender1

log "Resolving repository path..."
REPO_DIR="$(detect_repo_dir)"
if [ -z "$REPO_DIR" ]; then
  log "Repo not found here. Cloning fresh copy into \$PWD/layout ..."
  git clone https://github.com/emanuskript/layout.git "$PWD/layout"
  REPO_DIR="$PWD/layout"
fi

cd "$REPO_DIR"

log "Ensuring Node.js >= 20 is available..."
ensure_node_20

log "Checking for model weights..."
if ! check_weights; then
  echo ""
  echo "!! Model weights not found in backend/models/"
  echo "!! Required files:"
  echo "!!   backend/models/best_catmus.pt"
  echo "!!   backend/models/best_emanuskript_segmentation.pt"
  echo "!!   backend/models/best_zone_detection.pt"
  echo ""
  fail "Copy the weights into ${REPO_DIR}/backend/models and run again."
fi

log "Detecting machine public IP..."
PUBLIC_IP="$(detect_public_ip)"
[ -n "$PUBLIC_IP" ] || fail "Unable to detect public IP automatically."

TMP_ROOT="${REPO_DIR}/.deploy-tmp"
mkdir -p "$TMP_ROOT"
export TMPDIR="$TMP_ROOT"
export TEMP="$TMP_ROOT"
export TMP="$TMP_ROOT"

log "Cleaning package caches to save space..."
rm -rf "$HOME/.cache/pip" "$HOME/.npm/_cacache" || true
sudo apt-get clean || true

log "Preparing backend virtual environment..."
python3 -m venv "$REPO_DIR/backend/.venv"
"$REPO_DIR/backend/.venv/bin/pip" install --upgrade pip setuptools wheel

log "Installing backend dependencies (CPU-only torch)..."
TMPDIR="$TMP_ROOT" "$REPO_DIR/backend/.venv/bin/pip" install \
  --no-cache-dir \
  --index-url https://download.pytorch.org/whl/cpu \
  torch torchvision

TMPDIR="$TMP_ROOT" "$REPO_DIR/backend/.venv/bin/pip" install \
  --no-cache-dir \
  -e "$REPO_DIR/backend"

log "Installing frontend dependencies..."
cd "$REPO_DIR/frontend"
if [ -f package-lock.json ]; then
  TMPDIR="$TMP_ROOT" npm ci --cache "$TMP_ROOT/.npm-cache"
else
  TMPDIR="$TMP_ROOT" npm install --cache "$TMP_ROOT/.npm-cache"
fi

log "Building frontend production bundle..."
BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}" \
NEXT_PUBLIC_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}" \
TMPDIR="$TMP_ROOT" \
npm run build

cd "$REPO_DIR"

log "Writing systemd service units..."
write_backend_service
write_frontend_service

log "Writing nginx reverse proxy config..."
write_nginx_config
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/layout-host
sudo rm -f /etc/nginx/sites-enabled/default

log "Reloading systemd and starting services..."
sudo systemctl daemon-reload
sudo systemctl enable "$BACKEND_SERVICE" "$FRONTEND_SERVICE" nginx
sudo systemctl restart "$BACKEND_SERVICE"
sudo systemctl restart "$FRONTEND_SERVICE"

log "Validating nginx config..."
sudo nginx -t
sudo systemctl restart nginx

log "Waiting briefly for services to come up..."
sleep 3

sudo systemctl is-active --quiet "$BACKEND_SERVICE" || fail "${BACKEND_SERVICE} is not active. Check: sudo journalctl -u ${BACKEND_SERVICE} -n 100 --no-pager"
sudo systemctl is-active --quiet "$FRONTEND_SERVICE" || fail "${FRONTEND_SERVICE} is not active. Check: sudo journalctl -u ${FRONTEND_SERVICE} -n 100 --no-pager"
sudo systemctl is-active --quiet nginx || fail "nginx is not active. Check: sudo journalctl -u nginx -n 100 --no-pager"

echo ""
echo "==> Deployment complete"
echo "Frontend URL: http://${PUBLIC_IP}"
echo "Backend local: http://127.0.0.1:${BACKEND_PORT}"
echo "Services: ${BACKEND_SERVICE}, ${FRONTEND_SERVICE}, nginx"