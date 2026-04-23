#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# Config
############################################
FRONTEND_HOST="${FRONTEND_HOST:-127.0.0.1}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_PORT="${BACKEND_PORT:-8000}"

SITE_NAME="${SITE_NAME:-layout-host}"
NGINX_CONF="/etc/nginx/sites-available/${SITE_NAME}"
NGINX_LINK="/etc/nginx/sites-enabled/${SITE_NAME}"

# Optional:
# If you have a real DNS hostname pointing to this VM, set:
#   DOMAIN=your-hostname.example.org
#   CERTBOT_EMAIL=you@example.org
DOMAIN="${DOMAIN:-}"
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"

# Optional explicit public host override:
#   PUBLIC_HOST=203.0.113.10
#   PUBLIC_HOST=apps.example.org
PUBLIC_HOST="${PUBLIC_HOST:-}"

# Optional smoke test image:
#   TEST_IMAGE=/absolute/path/to/test.jpg
TEST_IMAGE="${TEST_IMAGE:-}"

############################################
# Helpers
############################################
log()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32mOK\033[0m  $*"; }
warn() { echo -e "\033[1;33m!!\033[0m  $*"; }
err()  { echo -e "\033[1;31mXX\033[0m  $*" >&2; }

if [[ "${EUID}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    err "Run as root or install sudo."
    exit 1
  fi
else
  SUDO=""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

curl_code() {
  local url="$1"
  curl -sS -o /dev/null -w "%{http_code}" --max-time 20 "$url" || true
}

check_url() {
  local url="$1"
  local code
  code="$(curl_code "$url")"
  if [[ "$code" =~ ^2|3 ]]; then
    ok "$url -> HTTP $code"
    return 0
  else
    err "$url -> HTTP $code"
    return 1
  fi
}

is_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_private_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] \
    || [[ "$ip" =~ ^127\. ]] \
    || [[ "$ip" =~ ^192\.168\. ]] \
    || [[ "$ip" =~ ^169\.254\. ]] \
    || [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]
}

get_public_ip() {
  local candidate=""
  local services=(
    "https://api.ipify.org"
    "https://checkip.amazonaws.com"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
  )

  for url in "${services[@]}"; do
    candidate="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ -n "$candidate" ]] && is_ipv4 "$candidate" && ! is_private_ipv4 "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

LOCAL_INTERFACE_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
PUBLIC_IP="$(get_public_ip || true)"

BEST_HTTP_LINK=""
PUBLIC_CANDIDATE_LINK=""

if [[ -n "${DOMAIN}" ]]; then
  BEST_HTTP_LINK="http://${DOMAIN}/"
  PUBLIC_CANDIDATE_LINK="${BEST_HTTP_LINK}"
elif [[ -n "${PUBLIC_HOST}" ]]; then
  BEST_HTTP_LINK="http://${PUBLIC_HOST}/"
  PUBLIC_CANDIDATE_LINK="${BEST_HTTP_LINK}"
elif [[ -n "${PUBLIC_IP}" ]]; then
  BEST_HTTP_LINK="http://${PUBLIC_IP}/"
  PUBLIC_CANDIDATE_LINK="${BEST_HTTP_LINK}"
else
  BEST_HTTP_LINK="http://127.0.0.1/"
fi

############################################
# Preflight
############################################
require_cmd curl
require_cmd python3
require_cmd nginx

log "Detected addressing"
echo "Local interface IP: ${LOCAL_INTERFACE_IP:-<unknown>}"
echo "Public IP:          ${PUBLIC_IP:-<unknown>}"
echo "Public host:        ${PUBLIC_HOST:-<unset>}"
echo "Domain:             ${DOMAIN:-<unset>}"

log "Checking local upstreams first"

check_url "http://${FRONTEND_HOST}:${FRONTEND_PORT}/" || {
  err "Frontend is not reachable on ${FRONTEND_HOST}:${FRONTEND_PORT}"
  exit 1
}

check_url "http://${BACKEND_HOST}:${BACKEND_PORT}/openapi.json" || {
  err "Backend openapi is not reachable on ${BACKEND_HOST}:${BACKEND_PORT}"
  exit 1
}

check_url "http://${BACKEND_HOST}:${BACKEND_PORT}/api/health" || {
  err "Backend /api/health is not reachable on ${BACKEND_HOST}:${BACKEND_PORT}"
  exit 1
}

############################################
# Write nginx config
############################################
log "Writing clean nginx config"

SERVER_NAME="_"
if [[ -n "${DOMAIN}" ]]; then
  SERVER_NAME="${DOMAIN}"
elif [[ -n "${PUBLIC_HOST}" ]]; then
  SERVER_NAME="${PUBLIC_HOST}"
elif [[ -n "${PUBLIC_IP}" ]]; then
  SERVER_NAME="${PUBLIC_IP}"
fi

BACKUP_SUFFIX="$(date +%Y%m%d_%H%M%S)"
if [[ -f "${NGINX_CONF}" ]]; then
  ${SUDO} cp "${NGINX_CONF}" "${NGINX_CONF}.bak.${BACKUP_SUFFIX}"
  ok "Backed up nginx config to ${NGINX_CONF}.bak.${BACKUP_SUFFIX}"
fi

${SUDO} tee "${NGINX_CONF}" >/dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_NAME};

    client_max_body_size 512M;
    client_body_timeout 3600s;
    proxy_connect_timeout 60s;
    proxy_send_timeout 3600s;
    proxy_read_timeout 3600s;
    send_timeout 3600s;

    location = /openapi.json {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT}/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /docs {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT}/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /redoc {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT}/redoc;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /api/ {
        proxy_pass http://${BACKEND_HOST}:${BACKEND_PORT};
        proxy_http_version 1.1;

        proxy_request_buffering off;
        proxy_buffering off;
        proxy_max_temp_file_size 0;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    location / {
        proxy_pass http://${FRONTEND_HOST}:${FRONTEND_PORT};
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

log "Relinking sites-enabled"
${SUDO} mkdir -p /etc/nginx/sites-enabled /etc/nginx/sites-available
${SUDO} rm -f /etc/nginx/sites-enabled/default || true
${SUDO} ln -sf "${NGINX_CONF}" "${NGINX_LINK}"

log "Testing nginx syntax"
${SUDO} nginx -t
ok "nginx syntax is valid"

log "Reloading nginx"
if pgrep -x nginx >/dev/null 2>&1; then
  ${SUDO} nginx -s reload
else
  ${SUDO} nginx
fi
ok "nginx is running"

############################################
# Optional firewall opening
############################################
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -qi "Status: active"; then
    log "UFW is active, allowing 80/tcp and 443/tcp"
    ${SUDO} ufw allow 80/tcp >/dev/null || true
    ${SUDO} ufw allow 443/tcp >/dev/null || true
    ok "Firewall rules checked"
  fi
fi

############################################
# Probe routes through nginx
############################################
log "Checking core URLs"

check_url "http://127.0.0.1/"
check_url "http://127.0.0.1/openapi.json"
check_url "http://127.0.0.1/docs"
check_url "http://127.0.0.1/api/health"

############################################
# Check route presence in OpenAPI
############################################
log "Checking route presence in OpenAPI"

python3 - <<'PY'
import json, sys, urllib.request

url = "http://127.0.0.1/openapi.json"
with urllib.request.urlopen(url, timeout=20) as r:
    spec = json.load(r)

paths = spec.get("paths", {})
needed = [
    "/api/health",
    "/api/classes",
    "/api/predict/single",
    "/api/predict/batch",
]

missing = [p for p in needed if p not in paths]
if missing:
    print("XX Missing routes in OpenAPI:")
    for m in missing:
        print("   ", m)
    sys.exit(1)

print("OK OpenAPI contains required routes:")
for p in needed:
    methods = ", ".join(sorted(paths[p].keys()))
    print(f"   {p} [{methods}]")
PY

############################################
# Route status checks via local backend and nginx
############################################
log "Probing backend routes locally and through nginx"

python3 - <<'PY'
import json
import urllib.request
import urllib.error

spec_url = "http://127.0.0.1/openapi.json"
with urllib.request.urlopen(spec_url, timeout=20) as r:
    spec = json.load(r)

paths = spec.get("paths", {})
targets = [
    "/api/analytics/data",
    "/api/analytics/login",
    "/api/classes",
    "/api/health",
    "/api/predict/batch",
    "/api/predict/single",
]

def probe(base, path, method):
    url = base + path
    req = urllib.request.Request(url, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.getcode()
    except urllib.error.HTTPError as e:
        return e.code
    except Exception:
        return "ERR"

for path in targets:
    entry = paths.get(path)
    if not entry:
        print(f"SKIP missing path: {path}")
        continue
    methods = sorted(entry.keys())
    method = "GET" if "get" in methods else ("POST" if "post" in methods else methods[0].upper())
    local = probe("http://127.0.0.1:8000", path, method)
    nginx = probe("http://127.0.0.1", path, method)
    print(f"LOCAL  {path:26s} [{method}] -> {local}")
    print(f"NGINX  {path:26s} [{method}] -> {nginx}")
PY

############################################
# Optional real smoke test for single endpoint
############################################
if [[ -n "${TEST_IMAGE}" ]]; then
  if [[ ! -f "${TEST_IMAGE}" ]]; then
    warn "TEST_IMAGE is set but file does not exist: ${TEST_IMAGE}"
  else
    log "Running optional single-endpoint smoke test with TEST_IMAGE"

    SINGLE_OUT="$(mktemp)"
    SINGLE_CODE="$(
      curl -sS -o "${SINGLE_OUT}" -w "%{http_code}" \
        -X POST "http://127.0.0.1/api/predict/single" \
        -H "accept: application/json" \
        -F "image=@${TEST_IMAGE}" \
        -F "confidence=0.25" \
        -F "iou=0.3" || true
    )"

    if [[ "${SINGLE_CODE}" =~ ^2 ]]; then
      ok "Single inference smoke test passed -> HTTP ${SINGLE_CODE}"
    else
      err "Single inference smoke test failed -> HTTP ${SINGLE_CODE}"
      echo "----- response body begin -----"
      cat "${SINGLE_OUT}" || true
      echo
      echo "----- response body end -----"
      warn "This means nginx/proxy is fine, but backend inference code is still failing internally."
    fi

    rm -f "${SINGLE_OUT}"
  fi
else
  warn "Skipping real inference smoke test. Set TEST_IMAGE=/absolute/path/to/test.jpg to test /api/predict/single."
fi

############################################
# Optional HTTPS setup
############################################
if [[ -n "${DOMAIN}" && -n "${CERTBOT_EMAIL}" ]]; then
  if command -v certbot >/dev/null 2>&1; then
    log "Attempting HTTPS with Let's Encrypt for ${DOMAIN}"
    ${SUDO} certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "${CERTBOT_EMAIL}" --redirect || {
      warn "HTTPS setup failed. Check that:"
      warn "1) ${DOMAIN} points to this VM"
      warn "2) ports 80 and 443 are open"
      warn "3) nginx is publicly reachable"
    }
  else
    warn "certbot is not installed. HTTPS was not configured."
  fi
else
  warn "HTTPS not configured."
  warn "Browser 'Not secure' warning cannot be removed on raw http://IP."
  warn "To remove it, use a real DNS hostname + valid TLS certificate."
fi

############################################
# Final summary
############################################
BEST_FINAL_LINK="${BEST_HTTP_LINK}"
if [[ -n "${DOMAIN}" ]]; then
  HTTPS_CODE="$(curl -k -sS -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" || true)"
  if [[ "${HTTPS_CODE}" =~ ^2|3 ]]; then
    BEST_FINAL_LINK="https://${DOMAIN}/"
  fi
fi

echo
ok "testing completed"
echo "Frontend local:      http://${FRONTEND_HOST}:${FRONTEND_PORT}/"
echo "Backend local:       http://${BACKEND_HOST}:${BACKEND_PORT}/"
echo "Nginx local:         http://127.0.0.1/"
echo "Local interface IP:  ${LOCAL_INTERFACE_IP:-<unknown>}"
echo "Public IP:           ${PUBLIC_IP:-<unknown>}"
echo "Public candidate:    ${PUBLIC_CANDIDATE_LINK:-<none>}"
echo "Best final link:     ${BEST_FINAL_LINK}"

FINAL_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "${BEST_FINAL_LINK}" || true)"
if [[ "${FINAL_CODE}" =~ ^2|3 ]]; then
  ok "Final link responds from this VM: ${BEST_FINAL_LINK} (HTTP ${FINAL_CODE})"
else
  warn "Final link did not respond from this VM: ${BEST_FINAL_LINK} (HTTP ${FINAL_CODE})"
fi

if [[ -n "${PUBLIC_CANDIDATE_LINK}" ]]; then
  echo
  echo "Public URL to test from another machine:"
  echo "  ${PUBLIC_CANDIDATE_LINK}"
else
  echo
  warn "No public URL could be determined automatically."
  warn "Set PUBLIC_HOST=your.public.ip.or.hostname or DOMAIN=your.domain"
fi
