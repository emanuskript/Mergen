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
BACKEND_MAX_POOL_WORKERS="${BACKEND_MAX_POOL_WORKERS:-1}"
MODEL_WEIGHTS_BASE_URL="${MODEL_WEIGHTS_BASE_URL:-}"
SERVICE_USER="${LAYOUT_SERVICE_USER:-$USER}"
SERVICE_GROUP="${LAYOUT_SERVICE_GROUP:-$(id -gn "$SERVICE_USER")}"
DATA_DIR="${LAYOUT_DATA_DIR:-/var/lib/layout}"
ENV_DIR="/etc/layout"
ENV_FILE="${ENV_DIR}/backend.env"
TMP_ROOT=""
PUBLIC_IP=""
APP_HOST="${APP_HOST:-}"
PUBLIC_URL="${PUBLIC_URL:-}"
APP_TITLE="Manuscript Layout Analysis"

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run this deployment as a normal user with sudo access, not as root." >&2
  exit 1
fi
if [ "$(id -u "$SERVICE_USER")" -eq 0 ]; then
  echo "ERROR: LAYOUT_SERVICE_USER must be an unprivileged account." >&2
  exit 1
fi

cleanup() {
  [ -n "${TMP_ROOT:-}" ] && [ -d "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT" || true
}
trap cleanup EXIT

log() { echo "==> $*"; }
fail() { echo; echo "!! $*"; exit 1; }

dump_backend_logs() {
  echo
  echo "-- ${BACKEND_SERVICE} journal (last 80 lines) --"
  sudo journalctl -u "${BACKEND_SERVICE}" -n 80 --no-pager || true
}

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
  if [ -d "$PWD/Mergen/.git" ] && [ -d "$PWD/Mergen/backend" ] && [ -d "$PWD/Mergen/frontend" ]; then
    echo "$PWD/Mergen"; return
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
  major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  [ "$major" -le 22 ] || fail "Unsupported Node.js $(node -v). Use Node.js 20 or 22 for this release."
}

check_weights() {
  [ -f "$REPO_DIR/backend/models/best_catmus.pt" ] &&
  [ -f "$REPO_DIR/backend/models/best_emanuskript_segmentation.pt" ] &&
  [ -f "$REPO_DIR/backend/models/best_zone_detection.pt" ]
}

download_model_weight() {
  local filename="$1"
  local target_dir="$2"
  local tmp_file="${target_dir}/${filename}.tmp"
  local final_file="${target_dir}/${filename}"

  curl -fL --retry 3 --retry-delay 2 \
    "${MODEL_WEIGHTS_BASE_URL%/}/${filename}" \
    -o "${tmp_file}"
  mv "${tmp_file}" "${final_file}"
}

download_all_model_weights() {
  local target_dir="$1"
  mkdir -p "${target_dir}"

  [ -n "$MODEL_WEIGHTS_BASE_URL" ] || fail "Model weights are missing. Copy the three .pt files listed in README.md to ${target_dir}, or set MODEL_WEIGHTS_BASE_URL to an authenticated direct-download base URL."
  log "Downloading model weights from the configured direct-download URL..."
  download_model_weight "best_catmus.pt" "${target_dir}"
  download_model_weight "best_emanuskript_segmentation.pt" "${target_dir}"
  download_model_weight "best_zone_detection.pt" "${target_dir}"
}

ensure_model_weights() {
  local target_dir="${REPO_DIR}/backend/models"
  mkdir -p "${target_dir}"

  if ! check_weights; then
    download_all_model_weights "${target_dir}"
  fi
}

clean_build_artifacts() {
  log "Removing only this checkout's generated build artifacts..."
  rm -rf "$REPO_DIR/frontend/.next" "$REPO_DIR/frontend/node_modules" || true
  rm -rf "$REPO_DIR/backend/.venv" "$REPO_DIR/.deploy-tmp" || true
}

require_space() {
  local avail_kb
  avail_kb="$(df --output=avail / | tail -1 | tr -d ' ')"
  [ -n "$avail_kb" ] || fail "Could not determine free disk space."
  [ "$avail_kb" -ge 1500000 ] || fail "Need at least ~1.5 GB free on / before deployment."
}

check_conflicting_services() {
  for svc in caddy apache2; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      fail "${svc}.service is using the web ports. Stop or reconfigure it explicitly before deploying Mergen; this script will not disable unrelated services."
    fi
  done
}

prepare_runtime_config() {
  local jwt_secret analytics_password analytics_username
  jwt_secret="${JWT_SECRET:-}"
  analytics_password="${ANALYTICS_PASSWORD:-}"
  analytics_username="${ANALYTICS_USERNAME:-}"

  # Preserve generated credentials across safe re-runs unless the operator
  # explicitly supplies replacements.
  if sudo test -f "$ENV_FILE"; then
    [ -n "$jwt_secret" ] || jwt_secret="$(sudo awk -F= '$1 == "JWT_SECRET" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
    [ -n "$analytics_password" ] || analytics_password="$(sudo awk -F= '$1 == "ANALYTICS_PASSWORD" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
    [ -n "$analytics_username" ] || analytics_username="$(sudo awk -F= '$1 == "ANALYTICS_USERNAME" {sub(/^[^=]*=/, ""); print; exit}' "$ENV_FILE")"
  fi
  jwt_secret="${jwt_secret:-$(openssl rand -hex 32)}"
  analytics_password="${analytics_password:-$(openssl rand -base64 24 | tr -d '\n')}"
  analytics_username="${analytics_username:-admin}"

  sudo install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$DATA_DIR" "${DATA_DIR}/tasks"
  sudo install -d -m 0750 "$ENV_DIR"
  sudo tee "$ENV_FILE" >/dev/null <<EOF
APP_ENV=production
MODEL_DIR=${REPO_DIR}/backend/models
TASK_BASE_DIR=${DATA_DIR}/tasks
ANALYTICS_DB_PATH=${DATA_DIR}/analytics.db
CORS_ORIGINS=${PUBLIC_URL}
MAX_POOL_WORKERS=${BACKEND_MAX_POOL_WORKERS}
TASK_TTL_MINUTES=${TASK_TTL_MINUTES:-60}
TASK_CLEANUP_INTERVAL_SECONDS=${TASK_CLEANUP_INTERVAL_SECONDS:-300}
MAX_UPLOAD_BYTES=${MAX_UPLOAD_BYTES:-209715200}
MAX_BATCH_ENTRIES=${MAX_BATCH_ENTRIES:-1000}
MAX_BATCH_UNCOMPRESSED_BYTES=${MAX_BATCH_UNCOMPRESSED_BYTES:-1073741824}
JWT_SECRET=${jwt_secret}
ANALYTICS_USERNAME=${analytics_username}
ANALYTICS_PASSWORD=${analytics_password}
OMP_NUM_THREADS=1
OPENBLAS_NUM_THREADS=1
MKL_NUM_THREADS=1
NUMEXPR_NUM_THREADS=1
PYTHONDONTWRITEBYTECODE=1
PYTHONUNBUFFERED=1
XDG_CONFIG_HOME=${DATA_DIR}/.config
MPLCONFIGDIR=${DATA_DIR}/.cache/matplotlib
EOF
  sudo chmod 0600 "$ENV_FILE"
  sudo install -d -m 0750 -o "$SERVICE_USER" -g "$SERVICE_GROUP" \
    "${DATA_DIR}/.config" "${DATA_DIR}/.cache/matplotlib"
}

write_backend_service() {
  sudo tee "/etc/systemd/system/${BACKEND_SERVICE}.service" >/dev/null <<EOF
[Unit]
Description=Layout Backend API
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${REPO_DIR}/backend
EnvironmentFile=${ENV_FILE}
ExecStart=${REPO_DIR}/backend/.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port ${BACKEND_PORT} --workers 1
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${DATA_DIR}
UMask=0077

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
User=${SERVICE_USER}
WorkingDirectory=${REPO_DIR}/frontend/.next/standalone
Environment=NODE_ENV=production
Environment=NEXT_TELEMETRY_DISABLED=1
Environment=PORT=${FRONTEND_PORT}
Environment=HOSTNAME=127.0.0.1
Environment=INTERNAL_BACKEND_URL=http://127.0.0.1:${BACKEND_PORT}
ExecStart=/usr/bin/env node server.js
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=${REPO_DIR}/frontend/.next/standalone/.next/cache
UMask=0027

[Install]
WantedBy=multi-user.target
EOF
}

write_nginx_config() {
  sudo tee "$NGINX_CONF" >/dev/null <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${APP_HOST};

    client_max_body_size 200M;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;

    location = /api {
        return 301 /api/;
    }

    location ^~ /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/api/;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;
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
  curl -fsS -H "Host: ${APP_HOST}" "http://127.0.0.1" | grep -q "${APP_TITLE}" \
    || fail "Local nginx is not serving the expected frontend."
}

verify_api() {
  curl -fsS -H "Host: ${APP_HOST}" "http://127.0.0.1/api/health" >/dev/null \
    || fail "nginx -> backend health route is broken."
  curl -fsS -H "Host: ${APP_HOST}" "http://127.0.0.1/api/classes" >/dev/null \
    || fail "nginx -> backend classes route is broken."
}

run_prediction_request() {
  local url="$1"
  local response_file="$2"

  curl -sS -o "${response_file}" -w "%{http_code}" -X POST \
    -H "Host: ${APP_HOST}" \
    -F "image=@${smoke_image}" \
    -F "confidence=0.25" \
    -F "iou=0.3" \
    "${url}"
}

verify_prediction_flow() {
  local smoke_image response response_file backend_response_file http_code backend_http_code task_id annotated_path
  smoke_image="${TMP_ROOT}/smoke-test.jpg"
  response_file="${TMP_ROOT}/predict-response.json"
  backend_response_file="${TMP_ROOT}/predict-response-backend.json"

  "$REPO_DIR/backend/.venv/bin/python" - "$smoke_image" <<'PY'
from PIL import Image
import sys

Image.new("RGB", (512, 512), "white").save(sys.argv[1])
PY

  http_code="$(run_prediction_request "http://127.0.0.1/api/predict/single" "${response_file}")" || {
    dump_backend_logs
    fail "nginx -> backend single prediction route is broken."
  }

  if [ "${http_code}" != "200" ]; then
    echo
    echo "-- nginx predict response body --"
    cat "${response_file}" || true

    backend_http_code="$(run_prediction_request "http://127.0.0.1:${BACKEND_PORT}/api/predict/single" "${backend_response_file}")" || true
    if [ -n "${backend_http_code:-}" ]; then
      echo
      echo "-- backend direct predict response (${backend_http_code}) --"
      cat "${backend_response_file}" || true
    fi

    dump_backend_logs
    fail "nginx -> backend single prediction route returned HTTP ${http_code}."
  fi

  response="$(cat "${response_file}")"

  task_id="$(
    printf '%s' "$response" | "$REPO_DIR/backend/.venv/bin/python" -c \
      'import json,sys; print(json.load(sys.stdin)["task_id"])'
  )"

  annotated_path="$(
    printf '%s' "$response" | "$REPO_DIR/backend/.venv/bin/python" -c \
      'import json,sys; print(json.load(sys.stdin)["annotated_image_url"])'
  )"

  [ -n "$task_id" ] || fail "Prediction response did not include a task_id."
  [ -n "$annotated_path" ] || fail "Prediction response did not include annotated_image_url."

  curl -fsS -H "Host: ${APP_HOST}" "http://127.0.0.1${annotated_path}" -o /dev/null -D - | grep -qi '^content-type: image/jpeg' \
    || fail "Predicted annotated image is not reachable through nginx."
}

verify_public_route() {
  if curl -fsS "${PUBLIC_URL}" | grep -q "${APP_TITLE}"; then
    log "Public URL is serving the expected frontend."
  else
    echo
    echo "!! Local deployment is correct, but ${PUBLIC_URL} is not serving the same frontend."
  fi
}

log "Installing base packages..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git nginx openssl python3 python3-pip python3-venv \
  build-essential libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
  libspatialindex-dev

log "Resolving repository path..."
REPO_DIR="$(detect_repo_dir)"
if [ -z "$REPO_DIR" ]; then
  git clone https://github.com/emanuskript/Mergen.git "$PWD/Mergen"
  REPO_DIR="$PWD/Mergen"
fi
cd "$REPO_DIR"

if [ -n "$(git status --porcelain)" ]; then
  fail "Deploy only from a clean, committed Mergen checkout. Preserve or commit local changes first."
fi

ensure_node_20

log "Ensuring model weights are present..."
ensure_model_weights

if [ -z "$APP_HOST" ]; then
  PUBLIC_IP="$(detect_public_ip)"
  [ -n "$PUBLIC_IP" ] || fail "Unable to detect public IP; set APP_HOST explicitly."
  APP_HOST="$PUBLIC_IP"
fi
PUBLIC_URL="${PUBLIC_URL:-http://${APP_HOST}}"
[[ "${APP_HOST}" =~ ^[A-Za-z0-9.-]+$ ]] \
  || fail "APP_HOST must be a DNS hostname or IPv4 address."
[[ "${PUBLIC_URL}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
  || fail "PUBLIC_URL must be one http(s) origin without a path."

clean_build_artifacts
require_space
check_conflicting_services
prepare_runtime_config

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

log "Validating backend model checkpoints..."
MODEL_DIR="${REPO_DIR}/backend/models" \
  "$REPO_DIR/backend/.venv/bin/python" -m app.scripts.validate_models \
  || {
    fail "One or more model checkpoints are invalid. Replace them from the README source; the script will not silently overwrite supplied weights."
  }

log "Building frontend..."
cd "$REPO_DIR/frontend"
rm -rf .next node_modules
if [ -f package-lock.json ]; then
  TMPDIR="$TMP_ROOT" npm ci --cache "$TMP_ROOT/.npm-cache"
else
  TMPDIR="$TMP_ROOT" npm install --cache "$TMP_ROOT/.npm-cache"
fi
npm audit --omit=dev --audit-level=high
INTERNAL_BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}" TMPDIR="$TMP_ROOT" npm run build
mkdir -p .next/standalone/.next
rm -rf .next/standalone/.next/static .next/standalone/public
cp -R .next/static .next/standalone/.next/static
cp -R public .next/standalone/public
mkdir -p .next/standalone/.next/cache
sudo chown -R "$SERVICE_USER:$SERVICE_GROUP" .next/standalone/.next/cache
rm -rf "$REPO_DIR/frontend/node_modules"
cd "$REPO_DIR"

log "Writing services and nginx config..."
write_backend_service
write_frontend_service

NGINX_BACKUP="${TMP_ROOT}/nginx.previous"
NGINX_CONFIG_EXISTED=false
NGINX_SITE_WAS_ENABLED=false
if sudo test -f "$NGINX_CONF"; then
  sudo cat "$NGINX_CONF" > "$NGINX_BACKUP"
  NGINX_CONFIG_EXISTED=true
fi
if sudo test -e /etc/nginx/sites-enabled/layout-host \
  || sudo test -L /etc/nginx/sites-enabled/layout-host; then
  NGINX_SITE_WAS_ENABLED=true
fi
write_nginx_config
sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/layout-host
if ! sudo nginx -t; then
  if [ "$NGINX_CONFIG_EXISTED" = true ]; then
    sudo install -m 0644 "$NGINX_BACKUP" "$NGINX_CONF"
  else
    sudo rm -f "$NGINX_CONF"
  fi
  if [ "$NGINX_SITE_WAS_ENABLED" != true ]; then
    sudo rm -f /etc/nginx/sites-enabled/layout-host
  fi
  sudo nginx -t || true
  fail "New nginx configuration is invalid; the previous configuration was restored."
fi

log "Restarting services..."
sudo systemctl daemon-reload
sudo systemctl enable "$BACKEND_SERVICE" "$FRONTEND_SERVICE" nginx
sudo systemctl stop "$FRONTEND_SERVICE" || true
sudo systemctl restart "$BACKEND_SERVICE"
sudo systemctl start "$FRONTEND_SERVICE"
sudo systemctl restart nginx

sleep 3

sudo systemctl is-active --quiet "$BACKEND_SERVICE" || fail "Backend service not active."
sudo systemctl is-active --quiet "$FRONTEND_SERVICE" || fail "Frontend service not active."
sudo systemctl is-active --quiet nginx || fail "nginx not active."

verify_local_frontend
verify_local_nginx
verify_api
verify_prediction_flow
verify_public_route

echo
echo "==> Deployment complete"
echo "Frontend URL: ${PUBLIC_URL}"
echo "Backend local: http://127.0.0.1:${BACKEND_PORT}"
echo "Services: ${BACKEND_SERVICE}, ${FRONTEND_SERVICE}, nginx"
echo "Secrets file: ${ENV_FILE} (root-readable only)"
echo "For public production, terminate TLS at nginx or an upstream proxy and set PUBLIC_URL=https://your-domain before rerunning."
