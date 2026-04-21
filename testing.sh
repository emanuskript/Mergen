#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="layout"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8000}"

NGINX_AVAIL="/etc/nginx/sites-available/layout-host"
NGINX_ENABLED="/etc/nginx/sites-enabled/layout-host"

FRONTEND_SERVICE="${FRONTEND_SERVICE:-layout-frontend}"
BACKEND_SERVICE="${BACKEND_SERVICE:-layout-backend}"
NGINX_SERVICE="nginx"

PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
TMP_OPENAPI="/tmp/${APP_NAME}_openapi.json"

blue()   { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
green()  { printf '\033[1;32mOK  %s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m!!  %s\033[0m\n' "$*"; }
red()    { printf '\033[1;31mXX  %s\033[0m\n' "$*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { red "Missing command: $1"; exit 1; }
}

run() {
  "$@"
}

wait_http() {
  local url="$1"
  local label="$2"
  local tries="${3:-20}"
  local delay="${4:-2}"

  for ((i=1; i<=tries; i++)); do
    if curl -fsS --max-time 10 "$url" >/dev/null 2>&1; then
      green "$label is reachable: $url"
      return 0
    fi
    sleep "$delay"
  done

  red "$label did not become reachable: $url"
  return 1
}

show_http_summary() {
  local url="$1"
  local label="$2"
  local code redirect final_url
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$url" || true)"
  redirect="$(curl -sS -o /dev/null -w '%{redirect_url}' "$url" || true)"
  final_url="$(curl -sSL -o /dev/null -w '%{url_effective}' "$url" || true)"
  printf '%-18s code=%-4s final=%s' "$label" "$code" "${final_url:-$url}"
  if [[ -n "${redirect}" ]]; then
    printf ' redirect=%s' "$redirect"
  fi
  printf '\n'
}

restore_backup_and_exit() {
  local backup="$1"
  if [[ -f "$backup" ]]; then
    yellow "Restoring nginx config from backup"
    cp -f "$backup" "$NGINX_AVAIL"
    rm -f "$NGINX_ENABLED"
    ln -s "$NGINX_AVAIL" "$NGINX_ENABLED"
    nginx -t || true
    systemctl restart "$NGINX_SERVICE" || true
  fi
  exit 1
}

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

need_cmd nginx
need_cmd systemctl
need_cmd curl
need_cmd python3
need_cmd awk
need_cmd sed
need_cmd grep

blue "Writing clean nginx config"
BACKUP="${NGINX_AVAIL}.bak.$(date +%Y%m%d_%H%M%S)"
if [[ -f "$NGINX_AVAIL" ]]; then
  cp -f "$NGINX_AVAIL" "$BACKUP"
  green "Backed up nginx config to $BACKUP"
else
  yellow "No previous nginx config found at $NGINX_AVAIL"
fi

cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 200M;
    proxy_connect_timeout 60s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;

    location /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/;
        proxy_http_version 1.1;
        proxy_request_buffering off;
        proxy_buffering off;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${FRONTEND_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

blue "Relinking sites-enabled"
rm -f "$NGINX_ENABLED"
ln -s "$NGINX_AVAIL" "$NGINX_ENABLED"

blue "Testing nginx syntax"
if ! nginx -t; then
  red "nginx syntax test failed"
  restore_backup_and_exit "$BACKUP"
fi
green "nginx syntax is valid"

blue "Restarting services"
for svc in "$BACKEND_SERVICE" "$FRONTEND_SERVICE" "$NGINX_SERVICE"; do
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"; then
    systemctl restart "$svc"
    green "Restarted $svc"
  else
    yellow "Service not found: $svc"
  fi
done

echo
blue "Service status"
for svc in "$BACKEND_SERVICE" "$FRONTEND_SERVICE" "$NGINX_SERVICE"; do
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"; then
    if systemctl is-active --quiet "$svc"; then
      green "$svc is active"
    else
      red "$svc is not active"
      systemctl --no-pager -l status "$svc" || true
    fi
  fi
done

echo
blue "Waiting for endpoints"
wait_http "http://127.0.0.1:${FRONTEND_PORT}" "frontend local" 20 2 || true
wait_http "http://127.0.0.1:${BACKEND_PORT}/openapi.json" "backend openapi local" 20 2 || true
wait_http "http://127.0.0.1/api/openapi.json" "backend openapi through nginx" 20 2 || true
wait_http "http://127.0.0.1" "frontend through nginx" 20 2 || true

echo
blue "HTTP summary"
show_http_summary "http://127.0.0.1:${FRONTEND_PORT}" "frontend:3000"
show_http_summary "http://127.0.0.1:${BACKEND_PORT}/openapi.json" "backend:8000"
show_http_summary "http://127.0.0.1/api/openapi.json" "nginx /api"
show_http_summary "http://127.0.0.1" "nginx /"

if [[ -n "${PUBLIC_IP}" ]]; then
  show_http_summary "http://${PUBLIC_IP}" "public ip"
  show_http_summary "http://${PUBLIC_IP}/api/openapi.json" "public ip /api"
fi

echo
blue "Inspecting backend OpenAPI"
if curl -fsS "http://127.0.0.1:${BACKEND_PORT}/openapi.json" -o "$TMP_OPENAPI"; then
  python3 - <<PY
import json, pathlib
p = pathlib.Path("$TMP_OPENAPI")
data = json.loads(p.read_text())
paths = sorted((data.get("paths") or {}).keys())

print("All backend paths:")
for x in paths:
    print("  " + x)

health = [x for x in paths if "health" in x.lower() or "ping" in x.lower()]
modelish = [x for x in paths if "model" in x.lower() or "predict" in x.lower() or "analy" in x.lower()]

print("")
print("Likely health endpoints:")
for x in health:
    print("  " + x)

print("")
print("Likely model/analyze endpoints:")
for x in modelish:
    print("  " + x)
PY
else
  yellow "Could not fetch backend OpenAPI from local backend"
fi

echo
blue "Probing common health/model endpoints"
COMMON_ENDPOINTS=(
  "/health"
  "/ping"
  "/api/health"
  "/api/ping"
  "/analyze"
  "/api/analyze"
)

for ep in "${COMMON_ENDPOINTS[@]}"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${BACKEND_PORT}${ep}" || true)"
  printf '%-20s -> %s\n' "backend ${ep}" "${code:-ERR}"
done

echo
green "testing completed"
echo "Frontend local:  http://127.0.0.1:${FRONTEND_PORT}"
echo "Backend local:   http://127.0.0.1:${BACKEND_PORT}"
echo "Nginx local:     http://127.0.0.1"
if [[ -n "${PUBLIC_IP}" ]]; then
  echo "Public URL:      http://${PUBLIC_IP}"
fi
