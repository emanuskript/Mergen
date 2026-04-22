#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# EDIT THESE
###############################################################################
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8000}"
NGINX_SITE_NAME="${NGINX_SITE_NAME:-layout-host}"
SERVER_NAME="${SERVER_NAME:-_}"

# Put your 3 FULL weight files here, absolute paths.
EXPECTED_WEIGHT_FILES=(
  "/ABSOLUTE/PATH/TO/weight_1.pt"
  "/ABSOLUTE/PATH/TO/weight_2.pt"
  "/ABSOLUTE/PATH/TO/weight_3.pt"
)

###############################################################################
# Helpers
###############################################################################
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

info() { echo -e "${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}OK  $*${NC}"; }
warn() { echo -e "${YELLOW}!!  $*${NC}"; }
err()  { echo -e "${RED}XX  $*${NC}" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

http_code() {
  local url="$1"
  curl -k -L -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true
}

wait_http() {
  local url="$1"
  local tries="${2:-20}"
  local sleep_s="${3:-2}"
  local i code
  for ((i=1; i<=tries; i++)); do
    code="$(http_code "$url")"
    if [[ "$code" =~ ^2|3 ]]; then
      return 0
    fi
    sleep "$sleep_s"
  done
  return 1
}

first_ok_url() {
  local code url
  for url in "$@"; do
    code="$(http_code "$url")"
    if [[ "$code" =~ ^2|3 ]]; then
      printf '%s\n' "$url"
      return 0
    fi
  done
  return 1
}

show_listener() {
  local port="$1"
  if have ss; then
    ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}'
  elif have netstat; then
    netstat -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}'
  fi
}

reload_nginx() {
  info "Reloading nginx"

  if have nginx; then
    nginx -t
  fi

  if have systemctl && systemctl list-unit-files --type=service 2>/dev/null | grep -q '^nginx\.service'; then
    systemctl reload nginx || systemctl restart nginx
    return 0
  fi

  if have service; then
    service nginx reload || service nginx restart || true
  fi

  if have nginx; then
    nginx -s reload || true
  fi
}

maybe_restart_service() {
  local svc="$1"

  if have systemctl && systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}\.service"; then
    info "Restarting service: $svc"
    systemctl restart "$svc"
    return 0
  fi

  if have service && service "$svc" status >/dev/null 2>&1; then
    info "Restarting service: $svc"
    service "$svc" restart
    return 0
  fi

  warn "Service not managed here or not installed: $svc"
  return 1
}

pretty_json() {
  local url="$1"
  local label="$2"
  echo "$label"
  curl -k -L -sS --max-time 15 "$url" 2>/dev/null | python3 - <<'PY' || true
import json, sys
data = sys.stdin.read().strip()
if not data:
    print("(empty)")
    raise SystemExit(0)
try:
    obj = json.loads(data)
    print(json.dumps(obj, indent=2, ensure_ascii=False)[:4000])
except Exception:
    print(data[:4000])
PY
}

###############################################################################
# Model weight checks
###############################################################################
check_weights() {
  info "Checking model weights"
  local missing=0
  local f

  if [[ "${#EXPECTED_WEIGHT_FILES[@]}" -ne 3 ]]; then
    err "EXPECTED_WEIGHT_FILES must contain exactly 3 entries"
    exit 1
  fi

  for f in "${EXPECTED_WEIGHT_FILES[@]}"; do
    if [[ "$f" == "/ABSOLUTE/PATH/TO/"* ]]; then
      warn "Weight path still placeholder: $f"
      missing=1
      continue
    fi

    if [[ -s "$f" ]]; then
      ok "Found weight: $f ($(du -h "$f" | awk '{print $1}'))"
    else
      err "Missing or empty weight: $f"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    err "Fix the weight paths above before trusting this deployment"
    exit 1
  fi
}

###############################################################################
# Nginx config
###############################################################################
write_nginx_config() {
  local site_file="/etc/nginx/sites-available/${NGINX_SITE_NAME}"
  local backup_file="${site_file}.bak.$(date +%Y%m%d_%H%M%S)"

  info "Writing clean nginx config"

  if [[ -f "$site_file" ]]; then
    cp "$site_file" "$backup_file"
    ok "Backed up nginx config to $backup_file"
  fi

  cat > "$site_file" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_NAME};

    client_max_body_size 512M;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;

    # Frontend
    location / {
        proxy_pass http://127.0.0.1:${FRONTEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Make FastAPI schema/docs available under /api/* even if backend serves them at root.
    location = /api/openapi.json {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /api/docs {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /api/redoc {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/redoc;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Backend API routes already live under /api/*
    location /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  info "Relinking sites-enabled"
  ln -sfn "$site_file" "/etc/nginx/sites-enabled/${NGINX_SITE_NAME}"

  info "Testing nginx syntax"
  nginx -t
  ok "nginx syntax is valid"
}

###############################################################################
# Endpoint discovery
###############################################################################
discover_backend() {
  info "Discovering backend routes"

  BACKEND_LOCAL="http://127.0.0.1:${BACKEND_PORT}"
  FRONTEND_LOCAL="http://127.0.0.1:${FRONTEND_PORT}"
  NGINX_LOCAL="http://127.0.0.1"

  BACKEND_HEALTH_URL="$(first_ok_url \
    "${BACKEND_LOCAL}/api/health" \
    "${BACKEND_LOCAL}/health" \
    "${BACKEND_LOCAL}/ping" || true)"

  BACKEND_OPENAPI_URL="$(first_ok_url \
    "${BACKEND_LOCAL}/openapi.json" \
    "${BACKEND_LOCAL}/api/openapi.json" || true)"

  BACKEND_CLASSES_URL="$(first_ok_url \
    "${BACKEND_LOCAL}/api/classes" \
    "${BACKEND_LOCAL}/classes" || true)"

  [[ -n "${BACKEND_HEALTH_URL}" ]]  && ok "backend health local is reachable: ${BACKEND_HEALTH_URL}" \
                                    || warn "No backend health endpoint found locally"
  [[ -n "${BACKEND_OPENAPI_URL}" ]] && ok "backend openapi local is reachable: ${BACKEND_OPENAPI_URL}" \
                                    || warn "No backend openapi endpoint found locally"
  [[ -n "${BACKEND_CLASSES_URL}" ]] && ok "backend classes local is reachable: ${BACKEND_CLASSES_URL}" \
                                    || warn "No backend classes endpoint found locally"
}

###############################################################################
# Main checks
###############################################################################
main() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run this script with sudo: sudo bash ./testing.sh"
    exit 1
  fi

  check_weights

  discover_backend
  write_nginx_config
  reload_nginx

  # Optional service restarts if they actually exist as units on this host.
  info "Trying known app service names (best effort)"
  maybe_restart_service "layout-backend" || true
  maybe_restart_service "layout-frontend" || true
  maybe_restart_service "backend" || true
  maybe_restart_service "frontend" || true

  info "Service / listener status"
  echo "Frontend listeners:"
  show_listener "$FRONTEND_PORT" || true
  echo
  echo "Backend listeners:"
  show_listener "$BACKEND_PORT" || true
  echo
  echo "Nginx listeners:"
  show_listener "80" || true
  echo

  info "Waiting for endpoints"
  wait_http "${FRONTEND_LOCAL}" 20 2 \
    && ok "frontend local is reachable: ${FRONTEND_LOCAL}" \
    || err "frontend local did not become reachable: ${FRONTEND_LOCAL}"

  if [[ -n "${BACKEND_OPENAPI_URL}" ]]; then
    wait_http "${BACKEND_OPENAPI_URL}" 20 2 \
      && ok "backend openapi local is reachable: ${BACKEND_OPENAPI_URL}" \
      || err "backend openapi local did not become reachable: ${BACKEND_OPENAPI_URL}"
  fi

  NGINX_HEALTH_URL="$(first_ok_url \
    "${NGINX_LOCAL}/api/health" \
    "${NGINX_LOCAL}/health" || true)"

  NGINX_OPENAPI_URL="$(first_ok_url \
    "${NGINX_LOCAL}/api/openapi.json" \
    "${NGINX_LOCAL}/openapi.json" || true)"

  NGINX_CLASSES_URL="$(first_ok_url \
    "${NGINX_LOCAL}/api/classes" \
    "${NGINX_LOCAL}/classes" || true)"

  [[ -n "${NGINX_HEALTH_URL}" ]]  && ok "backend health through nginx is reachable: ${NGINX_HEALTH_URL}" \
                                  || err "backend health through nginx did not become reachable"

  [[ -n "${NGINX_OPENAPI_URL}" ]] && ok "backend openapi through nginx is reachable: ${NGINX_OPENAPI_URL}" \
                                  || err "backend openapi through nginx did not become reachable"

  [[ -n "${NGINX_CLASSES_URL}" ]] && ok "backend classes through nginx is reachable: ${NGINX_CLASSES_URL}" \
                                  || warn "backend classes through nginx not found"

  if [[ -n "${BACKEND_CLASSES_URL}" ]]; then
    pretty_json "${BACKEND_CLASSES_URL}" "Local classes payload:"
  fi

  if [[ -n "${NGINX_CLASSES_URL}" ]]; then
    pretty_json "${NGINX_CLASSES_URL}" "Nginx classes payload:"
  fi

  PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  PUBLIC_URL=""
  [[ -n "${PUBLIC_IP}" ]] && PUBLIC_URL="http://${PUBLIC_IP}"

  echo
  ok "testing completed"
  echo "Frontend local: ${FRONTEND_LOCAL}"
  echo "Backend local:  ${BACKEND_LOCAL}"
  echo "Nginx local:    ${NGINX_LOCAL}"
  [[ -n "${PUBLIC_URL}" ]] && echo "Public URL:      ${PUBLIC_URL}"
}

main "$@"
