#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_LOCAL="http://127.0.0.1:3000"
BACKEND_LOCAL="http://127.0.0.1:8000"
MODELS_DIR="${ROOT_DIR}/backend/models"

NGINX_AVAIL="/etc/nginx/sites-available/layout-host"
NGINX_ENABLED="/etc/nginx/sites-enabled/layout-host"
NGINX_DEFAULT="/etc/nginx/sites-enabled/default"

TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_PATH="${NGINX_AVAIL}.bak.${TS}"

say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf 'OK  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'XX  %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

http_code() {
  local url="$1"
  local timeout="${2:-20}"
  curl -L -sS -o /dev/null -w '%{http_code}' --max-time "$timeout" "$url" 2>/dev/null || echo "000"
}

wait_http_ok() {
  local name="$1"
  local url="$2"
  local tries="${3:-40}"
  local delay="${4:-2}"

  local i code
  for (( i=1; i<=tries; i++ )); do
    code="$(http_code "$url")"
    if [[ "$code" =~ ^(200|201|202|204|301|302|307|308)$ ]]; then
      ok "${name} is reachable: ${url} (${code})"
      return 0
    fi
    sleep "$delay"
  done

  die "${name} did not become reachable: ${url}"
}

best_host_candidate() {
  local fqdn short ip
  fqdn="$(hostname -f 2>/dev/null || true)"
  short="$(hostname 2>/dev/null || true)"
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

  if [[ -n "${fqdn}" && "${fqdn}" != "localhost" && "${fqdn}" == *.* ]]; then
    printf '%s' "$fqdn"
    return 0
  fi

  if [[ -n "${ip}" ]]; then
    printf '%s' "$ip"
    return 0
  fi

  if [[ -n "${short}" ]]; then
    printf '%s' "$short"
    return 0
  fi

  printf '127.0.0.1'
}

reload_or_start_nginx() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true
  fi

  if command -v service >/dev/null 2>&1; then
    service nginx reload >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1 || true
  fi

  if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload >/dev/null 2>&1 || pkill -HUP nginx >/dev/null 2>&1 || true
  else
    nginx >/dev/null 2>&1 || true
  fi

  pgrep -x nginx >/dev/null 2>&1 || die "nginx is not running after reload/start attempts"
}

open_firewall_if_needed() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi "Status: active"; then
      ufw allow 80/tcp >/dev/null 2>&1 || true
      ufw allow 443/tcp >/dev/null 2>&1 || true
      ok "ufw updated to allow 80/tcp and 443/tcp"
    fi
  fi
}

test_documented_routes() {
  say "Testing documented API routes through nginx"

  python3 - <<'PY' "$BACKEND_LOCAL/openapi.json" "http://127.0.0.1"
import json
import sys
import urllib.request
import urllib.error

openapi_url = sys.argv[1]
base = sys.argv[2]

try:
    with urllib.request.urlopen(openapi_url, timeout=20) as r:
        spec = json.loads(r.read().decode("utf-8"))
except Exception as e:
    print(f"XX  failed to read OpenAPI schema from {openapi_url}: {e}")
    sys.exit(1)

paths = spec.get("paths", {})
if not paths:
    print("XX  no paths found in OpenAPI schema")
    sys.exit(1)

for path in sorted(paths):
    methods = paths[path]
    for method in sorted(methods):
        method_upper = method.upper()
        if method_upper == "GET":
            if "{" in path or "}" in path:
                print(f"--  SKIP {method_upper} {path} (path params required)")
                continue
            url = base + path
            try:
                with urllib.request.urlopen(url, timeout=20) as r:
                    print(f"OK  {method_upper} {path} -> {r.status}")
            except urllib.error.HTTPError as e:
                print(f"!!  {method_upper} {path} -> HTTP {e.code}")
            except Exception as e:
                print(f"XX  {method_upper} {path} -> {e}")
        else:
            print(f"--  FOUND {method_upper} {path}")
PY
}

need_cmd curl
need_cmd nginx
need_cmd python3
need_cmd ip

[[ "${EUID}" -eq 0 ]] || die "Run this script with sudo: sudo bash ./testing.sh"

say "Checking real project paths"
[[ -d "${ROOT_DIR}/backend" ]] || die "Missing backend directory at ${ROOT_DIR}/backend"
[[ -d "${ROOT_DIR}/frontend" ]] || die "Missing frontend directory at ${ROOT_DIR}/frontend"
[[ -d "${MODELS_DIR}" ]] || die "Missing models directory at ${MODELS_DIR}"

for f in \
  "${MODELS_DIR}/best_catmus.pt" \
  "${MODELS_DIR}/best_emanuskript_segmentation.pt" \
  "${MODELS_DIR}/best_zone_detection.pt"
do
  [[ -f "$f" ]] || die "Missing model file: $f"
  ok "Found model file: $f"
done

PUBLIC_HOST="$(best_host_candidate)"
FINAL_FRONTEND_URL="http://${PUBLIC_HOST}/"
FINAL_API_HEALTH_URL="http://${PUBLIC_HOST}/api/health"
FINAL_DOCS_URL="http://${PUBLIC_HOST}/docs"
FINAL_OPENAPI_URL="http://${PUBLIC_HOST}/openapi.json"

HOST_FQDN="$(hostname -f 2>/dev/null || true)"
PRIMARY_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"

SERVER_NAMES="_"
if [[ -n "${HOST_FQDN}" && "${HOST_FQDN}" != "localhost" ]]; then
  SERVER_NAMES="${SERVER_NAMES} ${HOST_FQDN}"
fi
if [[ -n "${PRIMARY_IP}" ]]; then
  SERVER_NAMES="${SERVER_NAMES} ${PRIMARY_IP}"
fi

say "Preflight: verifying local services"
wait_http_ok "frontend local" "${FRONTEND_LOCAL}/"
wait_http_ok "backend local health" "${BACKEND_LOCAL}/api/health"
wait_http_ok "backend local openapi" "${BACKEND_LOCAL}/openapi.json"

say "Backing up existing nginx config"
mkdir -p "$(dirname "$NGINX_AVAIL")" "$(dirname "$NGINX_ENABLED")"
if [[ -f "$NGINX_AVAIL" ]]; then
  cp -f "$NGINX_AVAIL" "$BACKUP_PATH"
  ok "Backed up nginx config to $BACKUP_PATH"
else
  ok "No previous nginx config found at $NGINX_AVAIL"
fi

say "Writing clean nginx config"
cat > "$NGINX_AVAIL" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${SERVER_NAMES};

    client_max_body_size 500M;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;

    location = /api {
        return 301 /api/;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /docs {
        proxy_pass http://127.0.0.1:8000/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /docs/ {
        proxy_pass http://127.0.0.1:8000/docs/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /openapi.json {
        proxy_pass http://127.0.0.1:8000/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /redoc {
        proxy_pass http://127.0.0.1:8000/redoc;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

say "Relinking nginx sites-enabled"
ln -sfn "$NGINX_AVAIL" "$NGINX_ENABLED"
rm -f "$NGINX_DEFAULT" || true

say "Testing nginx syntax"
nginx -t

say "Reloading or starting nginx"
reload_or_start_nginx

say "Opening firewall if needed"
open_firewall_if_needed

say "Waiting for nginx-routed endpoints"
wait_http_ok "nginx local frontend" "http://127.0.0.1/"
wait_http_ok "nginx local API health" "http://127.0.0.1/api/health"
wait_http_ok "nginx local docs" "http://127.0.0.1/docs"
wait_http_ok "nginx local openapi" "http://127.0.0.1/openapi.json"

say "Testing final externally usable host from the VM"
wait_http_ok "final frontend URL" "${FINAL_FRONTEND_URL}"
wait_http_ok "final API health URL" "${FINAL_API_HEALTH_URL}"
wait_http_ok "final docs URL" "${FINAL_DOCS_URL}"
wait_http_ok "final openapi URL" "${FINAL_OPENAPI_URL}"

test_documented_routes

say "Final result"
printf 'Frontend URL : %s\n' "$FINAL_FRONTEND_URL"
printf 'API health   : %s\n' "$FINAL_API_HEALTH_URL"
printf 'API docs     : %s\n' "$FINAL_DOCS_URL"
printf 'OpenAPI JSON : %s\n' "$FINAL_OPENAPI_URL"

if [[ -n "${HOST_FQDN}" && "${HOST_FQDN}" == *.* ]]; then
  ok "Preferred public hostname: http://${HOST_FQDN}/"
else
  warn "No public FQDN detected; using IP-based URL instead"
fi

ok "testing.sh completed successfully"
