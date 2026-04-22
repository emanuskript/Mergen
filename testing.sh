#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Layout app reachability + nginx proxy setup + endpoint checks
# Overwrites nginx site config so the app is reachable on:
#   http://<vm-hostname-or-ip>/
#
# Run with:
#   sudo bash ./testing.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}OK${NC}  $*"; }
warn() { echo -e "${YELLOW}!!${NC}  $*"; }
err()  { echo -e "${RED}XX${NC}  $*"; }
info() { echo -e "${BLUE}==>${NC} $*"; }

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "$SCRIPT_DIR/backend" && -d "$SCRIPT_DIR/frontend" ]]; then
  ROOT_DIR="$SCRIPT_DIR"
else
  ROOT_DIR="${ROOT_DIR:-$REAL_HOME/layout}"
fi

BACKEND_DIR="$ROOT_DIR/backend"
FRONTEND_DIR="$ROOT_DIR/frontend"
MODELS_DIR="$BACKEND_DIR/models"

FRONTEND_LOCAL="http://127.0.0.1:3000"
BACKEND_LOCAL="http://127.0.0.1:8000"
NGINX_LOCAL="http://127.0.0.1"

NGINX_SITE_AVAIL="/etc/nginx/sites-available/layout-host"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/layout-host"
OPENAPI_TMP="/tmp/layout_openapi_$$.json"

cleanup() {
  rm -f "$OPENAPI_TMP"
}
trap cleanup EXIT

http_code() {
  local url="$1"
  curl -L -sS -o /dev/null -w "%{http_code}" --max-time 15 "$url" 2>/dev/null || echo "000"
}

is_good_code() {
  local code="$1"
  [[ "$code" != "000" && "$code" != "404" && "$code" != "502" && "$code" != "503" && "$code" != "504" ]]
}

wait_for_url() {
  local name="$1"
  local url="$2"
  local tries="${3:-20}"
  local sleep_sec="${4:-2}"
  local code="000"

  for ((i=1; i<=tries; i++)); do
    code="$(http_code "$url")"
    if is_good_code "$code"; then
      ok "$name is reachable: $url (HTTP $code)"
      return 0
    fi
    sleep "$sleep_sec"
  done

  err "$name did not become reachable: $url (last HTTP $code)"
  return 1
}

reload_nginx() {
  info "Reloading nginx"

  if systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    return 0
  fi

  if service nginx status >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1; then
    service nginx restart >/dev/null 2>&1 || true
    return 0
  fi

  if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload
    return 0
  fi

  nginx
}

first_public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{
    for (i=1; i<=NF; i++) if ($i=="src") { print $(i+1); exit }
  }'
}

best_public_host() {
  local fqdn=""
  local pubip=""

  fqdn="$(hostname -f 2>/dev/null || true)"
  pubip="$(first_public_ip || true)"

  if [[ -n "$fqdn" && "$fqdn" == *.* && "$fqdn" != "localhost" ]]; then
    echo "$fqdn"
    return 0
  fi

  if [[ -n "$pubip" ]]; then
    echo "$pubip"
    return 0
  fi

  return 1
}

print_model_status() {
  info "Checking model weights"

  local missing=0
  local models=(
    "$MODELS_DIR/best_catmus.pt"
    "$MODELS_DIR/best_emanuskript_segmentation.pt"
    "$MODELS_DIR/best_zone_detection.pt"
  )

  for m in "${models[@]}"; do
    if [[ -s "$m" ]]; then
      ok "Found model: $m ($(du -h "$m" | awk '{print $1}'))"
    else
      err "Missing or empty model: $m"
      missing=1
    fi
  done

  return "$missing"
}

write_nginx_config() {
  info "Writing clean nginx config"

  mkdir -p /etc/nginx/sites-available /etc/nginx/sites-enabled

  if [[ -f "$NGINX_SITE_AVAIL" ]]; then
    cp "$NGINX_SITE_AVAIL" "${NGINX_SITE_AVAIL}.bak.$(date +%Y%m%d_%H%M%S)"
    ok "Backed up existing nginx config"
  fi

  cat > "$NGINX_SITE_AVAIL" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 1024M;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;

    # Frontend
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Backend API routes (preserve /api prefix)
    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # FastAPI docs / schema
    location = /openapi.json {
        proxy_pass http://127.0.0.1:8000/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /docs {
        proxy_pass http://127.0.0.1:8000/docs;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /redoc {
        proxy_pass http://127.0.0.1:8000/redoc;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

  rm -f "$NGINX_SITE_ENABLED"
  ln -sf "$NGINX_SITE_AVAIL" "$NGINX_SITE_ENABLED"
  rm -f /etc/nginx/sites-enabled/default || true

  nginx -t
  ok "nginx syntax is valid"

  reload_nginx
  ok "nginx reloaded"
}

fetch_openapi() {
  info "Fetching backend OpenAPI spec"
  curl -fsS "$BACKEND_LOCAL/openapi.json" -o "$OPENAPI_TMP"
  ok "Downloaded OpenAPI spec from $BACKEND_LOCAL/openapi.json"
}

print_openapi_paths() {
  info "Discovered backend endpoints from OpenAPI"
  python3 - "$OPENAPI_TMP" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    spec = json.load(f)

paths = spec.get("paths", {})
for path in sorted(paths):
    print(path)
PY
}

probe_openapi_routes() {
  info "Probing backend routes locally and through nginx"

  python3 - "$OPENAPI_TMP" <<'PY' | while IFS=$'\t' read -r path methods route_kind; do
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    spec = json.load(f)

valid_methods = {"get", "post", "put", "delete", "patch", "options", "head"}
for path, meta in sorted(spec.get("paths", {}).items()):
    methods = [m.upper() for m in meta.keys() if m.lower() in valid_methods]
    kind = "dynamic" if "{" in path or "}" in path else "static"
    print(f"{path}\t{','.join(sorted(methods))}\t{kind}")
PY
    if [[ "$route_kind" == "dynamic" ]]; then
      echo "SKIP dynamic route: $path [$methods]"
      continue
    fi

    local_code="$(http_code "$BACKEND_LOCAL$path")"
    nginx_code="$(http_code "$NGINX_LOCAL$path")"

    if is_good_code "$local_code"; then
      echo "LOCAL  $path [$methods] -> $local_code"
    else
      echo "LOCAL  $path [$methods] -> $local_code  (problem)"
    fi

    if is_good_code "$nginx_code"; then
      echo "NGINX  $path [$methods] -> $nginx_code"
    else
      echo "NGINX  $path [$methods] -> $nginx_code  (problem)"
    fi
  done
}

probe_manual_urls() {
  info "Checking core URLs"

  local manual_urls=(
    "$FRONTEND_LOCAL/"
    "$BACKEND_LOCAL/openapi.json"
    "$BACKEND_LOCAL/api/health"
    "$NGINX_LOCAL/"
    "$NGINX_LOCAL/openapi.json"
    "$NGINX_LOCAL/docs"
    "$NGINX_LOCAL/api/health"
  )

  for u in "${manual_urls[@]}"; do
    c="$(http_code "$u")"
    if is_good_code "$c"; then
      ok "$u -> HTTP $c"
    else
      err "$u -> HTTP $c"
    fi
  done
}

main() {
  info "Root dir: $ROOT_DIR"

  [[ -d "$ROOT_DIR" ]]     || { err "Root dir not found: $ROOT_DIR"; exit 1; }
  [[ -d "$BACKEND_DIR" ]]  || { err "Backend dir not found: $BACKEND_DIR"; exit 1; }
  [[ -d "$FRONTEND_DIR" ]] || { err "Frontend dir not found: $FRONTEND_DIR"; exit 1; }

  command -v curl   >/dev/null 2>&1 || { err "curl is required"; exit 1; }
  command -v nginx  >/dev/null 2>&1 || { err "nginx is required"; exit 1; }
  command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 1; }

  print_model_status || true

  info "Waiting for local services"
  wait_for_url "frontend local" "$FRONTEND_LOCAL/" 20 2
  wait_for_url "backend openapi local" "$BACKEND_LOCAL/openapi.json" 20 2
  wait_for_url "backend health local" "$BACKEND_LOCAL/api/health" 20 2

  write_nginx_config

  wait_for_url "frontend through nginx" "$NGINX_LOCAL/" 20 2
  wait_for_url "backend openapi through nginx" "$NGINX_LOCAL/openapi.json" 20 2
  wait_for_url "backend health through nginx" "$NGINX_LOCAL/api/health" 20 2

  fetch_openapi
  print_openapi_paths
  probe_openapi_routes
  probe_manual_urls

  PUBLIC_HOST="$(best_public_host || true)"
  PUBLIC_URL=""
  if [[ -n "$PUBLIC_HOST" ]]; then
    PUBLIC_URL="http://$PUBLIC_HOST/"
  fi

  echo
  ok "testing completed"
  echo "Frontend local:      $FRONTEND_LOCAL/"
  echo "Backend local:       $BACKEND_LOCAL/"
  echo "Nginx local:         $NGINX_LOCAL/"
  if [[ -n "$PUBLIC_URL" ]]; then
    echo "Best final link:     $PUBLIC_URL"
    c="$(http_code "$PUBLIC_URL")"
    if is_good_code "$c"; then
      ok "Public URL responds locally: $PUBLIC_URL (HTTP $c)"
    else
      warn "Public URL candidate does not respond from this VM: $PUBLIC_URL (HTTP $c)"
      warn "If localhost works but this does not open from your laptop, the remaining issue is external networking/firewall/DNS, not the app itself."
    fi
  else
    warn "Could not determine a public hostname or IP automatically"
  fi
}

main "$@"
