#!/usr/bin/env bash
# deploy.sh — Run on the VM to deploy backend+frontend directly on host.
# Usage: bash deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=""
BACKEND_SERVICE="layout-backend"
FRONTEND_SERVICE="layout-frontend"
NGINX_CONF="/etc/nginx/sites-available/layout-host"

detect_public_ip() {
  local ip=""
  ip="$(curl -4fsS https://api.ipify.org || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4fsS https://ifconfig.me || true)"
  fi
  if [ -z "$ip" ]; then
    ip="$(curl -4fsS https://icanhazip.com | tr -d '[:space:]' || true)"
  fi
  echo "$ip"
}

echo "==> Installing base system packages..."
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg nginx python3 python3-venv python3-pip

echo "==> Resolving repository path..."
if [ -d "$SCRIPT_DIR/.git" ] && [ -d "$SCRIPT_DIR/backend" ] && [ -d "$SCRIPT_DIR/frontend" ]; then
  REPO_DIR="$SCRIPT_DIR"
elif [ -d "$PWD/.git" ] && [ -d "$PWD/backend" ] && [ -d "$PWD/frontend" ]; then
  REPO_DIR="$PWD"
elif [ -d "$PWD/layout/.git" ] && [ -d "$PWD/layout/backend" ] && [ -d "$PWD/layout/frontend" ]; then
  REPO_DIR="$PWD/layout"
else
  echo "==> Cloning repo..."
  git clone https://github.com/emanuskript/layout.git "$PWD/layout"
  REPO_DIR="$PWD/layout"
fi

cd "$REPO_DIR"

echo "==> Ensuring Node.js >= 20 is available..."
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
else
  NODE_MAJOR="0"
fi

if [ "$NODE_MAJOR" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y --no-install-recommends nodejs
fi

echo "==> Checking for model weights..."
if [ ! -f backend/models/best_catmus.pt ] \
  || [ ! -f backend/models/best_emanuskript_segmentation.pt ] \
  || [ ! -f backend/models/best_zone_detection.pt ]; then
  echo ""
  echo "!! Model weights not found in backend/models/"
  echo "!! Copy them from your local machine first:"
  echo "!!   scp backend/models/*.pt user@this-vm:~/layout/backend/models/"
  echo ""
  exit 1
fi

echo "==> Detecting machine public IP..."
PUBLIC_IP="$(detect_public_ip)"
if [ -z "$PUBLIC_IP" ]; then
  echo "!! Unable to detect public IP automatically."
  echo "!! Ensure outbound internet access, then re-run."
  exit 1
fi

echo "==> Preparing backend virtual environment..."
python3 -m venv backend/.venv
backend/.venv/bin/pip install --upgrade pip setuptools wheel

echo "==> Installing backend dependencies (CPU-only torch)..."
backend/.venv/bin/pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch torchvision
backend/.venv/bin/pip install --no-cache-dir -e backend

echo "==> Installing frontend dependencies and building production bundle..."
cd "$REPO_DIR/frontend"
npm ci
BACKEND_URL="http://127.0.0.1:8000" npm run build

NPM_BIN="$(command -v npm)"
cd "$REPO_DIR"

echo "==> Writing systemd service units..."
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
ExecStart=${REPO_DIR}/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee "/etc/systemd/system/${FRONTEND_SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=Layout Frontend (Next.js)
After=network.target ${BACKEND_SERVICE}.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}/frontend
Environment=NODE_ENV=production
ExecStart=${NPM_BIN} run start -- --hostname 127.0.0.1 --port 3000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo "==> Writing nginx reverse proxy config..."
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
    }
}
EOF

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/layout-host
sudo rm -f /etc/nginx/sites-enabled/default

echo "==> Enabling and restarting services..."
sudo systemctl daemon-reload
sudo systemctl enable --now "$BACKEND_SERVICE"
sudo systemctl restart "$BACKEND_SERVICE"
sudo systemctl enable --now "$FRONTEND_SERVICE"
sudo systemctl restart "$FRONTEND_SERVICE"

sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx

echo "==> Verifying service health..."
sudo systemctl is-active --quiet "$BACKEND_SERVICE" || (echo "!! $BACKEND_SERVICE is not active" && exit 1)
sudo systemctl is-active --quiet "$FRONTEND_SERVICE" || (echo "!! $FRONTEND_SERVICE is not active" && exit 1)
sudo systemctl is-active --quiet nginx || (echo "!! nginx is not active" && exit 1)

echo ""
echo "==> Deployment complete"
echo "Frontend URL: http://${PUBLIC_IP}"
echo "Backend local: http://127.0.0.1:8000"
echo "Services: ${BACKEND_SERVICE}, ${FRONTEND_SERVICE}, nginx"
