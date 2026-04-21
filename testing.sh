#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# CONFIG
###############################################################################

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BACKEND_PORT="${BACKEND_PORT:-8000}"

FRONTEND_URL="http://127.0.0.1:${FRONTEND_PORT}"
BACKEND_URL="http://127.0.0.1:${BACKEND_PORT}"
OPENAPI_URL="${BACKEND_URL}/openapi.json"
HEALTH_URL="${BACKEND_URL}/api/health"

NGINX_SITE="${NGINX_SITE:-/etc/nginx/sites-available/layout-host}"
NGINX_ENABLED="${NGINX_ENABLED:-/etc/nginx/sites-enabled/layout-host}"

REQUIRED_MODEL_COUNT="${REQUIRED_MODEL_COUNT:-3}"
MIN_MODEL_SIZE_MB="${MIN_MODEL_SIZE_MB:-10}"

# If you know the exact filenames, put them here.
# Leave blank to auto-detect.
EXPECTED_MODELS=(
  "${EXPECTED_MODEL_1:-}"
  "${EXPECTED_MODEL_2:-}"
  "${EXPECTED_MODEL_3:-}"
)

###############################################################################
# UI
###############################################################################

blue='\033[1;34m'
green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

step() { echo -e "${blue}==>${reset} $*"; }
ok()   { echo -e "${green}OK${reset}  $*"; }
warn() { echo -e "${yellow}!!${reset}  $*"; }
err()  { echo -e "${red}XX${reset}  $*"; }
die()  { err "$*"; exit 1; }

###############################################################################
# HELPERS
###############################################################################

have() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  have "$1" || die "Missing required command: $1"
}

http_code() {
  local url="$1"
  curl -k -sS -o /dev/null -w "%{http_code}" "$url" || true
}

wait_http_ok() {
  local url="$1"
  local label="$2"
  local tries="${3:-40}"
  local delay="${4:-2}"

  local code
  for ((i=1; i<=tries; i++)); do
    code="$(http_code "$url")"
    if [[ "$code" == "200" ]]; then
      ok "$label is reachable: $url"
      return 0
    fi
    sleep "$delay"
  done

  err "$label did not become reachable: $url"
  return 1
}

wait_http_any() {
  local url="$1"
  local label="$2"
  local tries="${3:-40}"
  local delay="${4:-2}"

  local code
  for ((i=1; i<=tries; i++)); do
    code="$(http_code "$url")"
    if [[ "$code" =~ ^(200|301|302|307|308|401|403|404|405)$ ]]; then
      ok "$label responded with HTTP $code: $url"
      return 0
    fi
    sleep "$delay"
  done

  err "$label did not respond: $url"
  return 1
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local backup="${f}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -a "$f" "$backup"
    ok "Backed up $f to $backup"
  fi
}

port_owner() {
  local port="$1"
  ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print}'
}

systemd_units_matching() {
  local pattern="$1"
  systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' \
    | grep -Ei "$pattern" || true
}

restart_units_matching() {
  local pattern="$1"
  local found=0
  while IFS= read -r unit; do
    [[ -z "$unit" ]] && continue
    found=1
    step "Restarting service: $unit"
    systemctl restart "$unit"
  done < <(systemd_units_matching "$pattern")

  return $found
}

pm2_restart_matching() {
  have pm2 || return 1
  local pattern="$1"
  local names
  names="$(pm2 jlist 2>/dev/null | python3 - "$pattern" <<'PY'
import json, re, sys
pat = re.compile(sys.argv[1], re.I)
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for item in data:
    name = item.get("name", "")
    if pat.search(name):
        print(name)
PY
)"
  [[ -z "$names" ]] && return 1
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    step "Restarting PM2 process: $name"
    pm2 restart "$name" >/dev/null
  done <<< "$names"
}

activate_venv_if_present() {
  if [[ -f "${APP_DIR}/.venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${APP_DIR}/.venv/bin/activate"
    ok "Using virtualenv: ${APP_DIR}/.venv"
  elif [[ -f "${APP_DIR}/venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "${APP_DIR}/venv/bin/activate"
    ok "Using virtualenv: ${APP_DIR}/venv"
  else
    warn "No virtualenv found in ${APP_DIR}/.venv or ${APP_DIR}/venv"
  fi
}

guess_backend_app_module() {
  if [[ -f "${APP_DIR}/backend/app/main.py" ]]; then
    echo "backend.app.main:app"; return 0
  fi
  if [[ -f "${APP_DIR}/backend/main.py" ]]; then
    echo "backend.main:app"; return 0
  fi
  if [[ -f "${APP_DIR}/app/main.py" ]]; then
    echo "app.main:app"; return 0
  fi
  if [[ -f "${APP_DIR}/main.py" ]]; then
    echo "main:app"; return 0
  fi
  return 1
}

frontend_dir() {
  if [[ -f "${APP_DIR}/package.json" ]]; then
    echo "${APP_DIR}"; return 0
  fi
  if [[ -f "${APP_DIR}/frontend/package.json" ]]; then
    echo "${APP_DIR}/frontend"; return 0
  fi
  return 1
}

find_weight_files() {
  find "${APP_DIR}" \
    -type f \
    \( -iname '*.pt' -o -iname '*.pth' -o -iname '*.onnx' -o -iname '*.engine' -o -iname '*.bin' \) \
    ! -path '*/node_modules/*' \
    ! -path '*/.git/*' \
    ! -path '*/dist/*' \
    ! -path '*/build/*' 2>/dev/null
}

is_lfs_pointer() {
  local f="$1"
  head -n 1 "$f" 2>/dev/null | grep -q 'version https://git-lfs.github.com/spec/v1'
}

bytes_to_mb() {
  python3 - "$1" <<'PY'
import sys
print(round(int(sys.argv[1]) / (1024*1024), 2))
PY
}

list_model_report() {
  local found_any=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    found_any=1
    local size
    size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    local mb
    mb="$(bytes_to_mb "$size")"
    if is_lfs_pointer "$f"; then
      echo "POINTER | ${mb} MB | $f"
    else
      echo "FILE    | ${mb} MB | $f"
    fi
  done < <(find_weight_files)

  [[ $found_any -eq 1 ]]
}

ensure_git_lfs_materialized() {
  if ! git -C "${APP_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "Not a git checkout, skipping Git LFS checks"
    return 0
  fi

  if ! grep -Rqs "git-lfs" "${APP_DIR}/.gitattributes" "${APP_DIR}/.git" 2>/dev/null; then
    warn "No obvious Git LFS configuration found"
  fi

  if have git && git lfs version >/dev/null 2>&1; then
    step "Running git lfs pull"
    git -C "${APP_DIR}" lfs install --local >/dev/null 2>&1 || true
    git -C "${APP_DIR}" lfs pull || true
  else
    warn "git-lfs is not installed; if model files are pointers, install git-lfs and rerun"
  fi
}

verify_models() {
  step "Checking model weights"

  ensure_git_lfs_materialized

  local files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(find_weight_files)

  [[ ${#files[@]} -gt 0 ]] || die "No candidate model files found"

  echo
  echo "Model file report:"
  list_model_report || true
  echo

  local good=0
  local pointers=0

  for f in "${files[@]}"; do
    local size
    size="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
    if is_lfs_pointer "$f"; then
      ((pointers+=1))
      continue
    fi
    if (( size >= MIN_MODEL_SIZE_MB * 1024 * 1024 )); then
      ((good+=1))
    fi
  done

  if (( pointers > 0 )); then
    die "Found ${pointers} Git LFS pointer file(s) instead of full model weights"
  fi

  if (( good < REQUIRED_MODEL_COUNT )); then
    die "Found only ${good} full model file(s) >= ${MIN_MODEL_SIZE_MB} MB; expected at least ${REQUIRED_MODEL_COUNT}"
  fi

  ok "Found at least ${REQUIRED_MODEL_COUNT} full model weights"
}

verify_expected_model_names_if_set() {
  local set_count=0
  for m in "${EXPECTED_MODELS[@]}"; do
    [[ -n "$m" ]] && ((set_count+=1))
  done

  (( set_count == 0 )) && return 0

  step "Checking exact expected model filenames"
  for m in "${EXPECTED_MODELS[@]}"; do
    [[ -z "$m" ]] && continue
    local hit
    hit="$(find "${APP_DIR}" -type f -name "$m" 2>/dev/null | head -n 1 || true)"
    [[ -n "$hit" ]] || die "Expected model file not found: $m"
    if is_lfs_pointer "$hit"; then
      die "Expected model file is still a Git LFS pointer: $hit"
    fi
    ok "Found expected model: $hit"
  done
}

start_backend_if_needed() {
  step "Ensuring backend is up"

  if wait_http_any "${OPENAPI_URL}" "backend openapi local" 3 1; then
    return 0
  fi

  if have systemctl; then
    restart_units_matching '(layout|emanuskript).*(back|api)|uvicorn|fastapi' || true
  fi

  if wait_http_any "${OPENAPI_URL}" "backend openapi local" 8 2; then
    return 0
  fi

  pm2_restart_matching '(layout|emanuskript).*(back|api)|backend|api' || true

  if wait_http_any "${OPENAPI_URL}" "backend openapi local" 8 2; then
    return 0
  fi

  local app_module
  app_module="$(guess_backend_app_module)" || die "Could not detect backend app module"

  activate_venv_if_present

  step "Starting backend manually with uvicorn: ${app_module}"
  nohup python3 -m uvicorn "${app_module}" \
    --host 0.0.0.0 \
    --port "${BACKEND_PORT}" \
    --proxy-headers \
    > "${APP_DIR}/.testing_backend.log" 2>&1 &

  wait_http_any "${OPENAPI_URL}" "backend openapi local" 20 2 \
    || die "Backend failed to start. Check ${APP_DIR}/.testing_backend.log"
}

start_frontend_if_needed() {
  step "Ensuring frontend is up"

  if wait_http_any "${FRONTEND_URL}" "frontend local" 3 1; then
    return 0
  fi

  if have systemctl; then
    restart_units_matching '(layout|emanuskript).*(front|web|ui)|node|next|vite' || true
  fi

  if wait_http_any "${FRONTEND_URL}" "frontend local" 8 2; then
    return 0
  fi

  pm2_restart_matching '(layout|emanuskript).*(front|web|ui)|frontend|web|ui' || true

  if wait_http_any "${FRONTEND_URL}" "frontend local" 8 2; then
    return 0
  fi

  local fdir
  fdir="$(frontend_dir)" || die "Could not detect frontend directory"

  step "Starting frontend manually from ${fdir}"
  cd "${fdir}"

  if [[ -f package-lock.json ]]; then
    nohup npm run dev -- --host 0.0.0.0 --port "${FRONTEND_PORT}" \
      > "${APP_DIR}/.testing_frontend.log" 2>&1 &
  elif [[ -f pnpm-lock.yaml ]]; then
    nohup pnpm dev --host 0.0.0.0 --port "${FRONTEND_PORT}" \
      > "${APP_DIR}/.testing_frontend.log" 2>&1 &
  elif [[ -f yarn.lock ]]; then
    nohup yarn dev --host 0.0.0.0 --port "${FRONTEND_PORT}" \
      > "${APP_DIR}/.testing_frontend.log" 2>&1 &
  else
    nohup npm run dev -- --host 0.0.0.0 --port "${FRONTEND_PORT}" \
      > "${APP_DIR}/.testing_frontend.log" 2>&1 &
  fi

  wait_http_any "${FRONTEND_URL}" "frontend local" 20 2 \
    || die "Frontend failed to start. Check ${APP_DIR}/.testing_frontend.log"
}

write_clean_nginx_config() {
  have nginx || { warn "nginx is not installed; skipping nginx config"; return 0; }
  [[ "$(id -u)" -eq 0 ]] || { warn "Not running as root; skipping nginx config"; return 0; }

  step "Writing clean nginx config"
  backup_file "${NGINX_SITE}"

  cat > "${NGINX_SITE}" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    client_max_body_size 200M;
    proxy_connect_timeout 600s;
    proxy_send_timeout 600s;
    proxy_read_timeout 600s;
    send_timeout 600s;

    location /api/ {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location = /openapi.json {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/openapi.json;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /docs {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/docs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /redoc {
        proxy_pass http://127.0.0.1:${BACKEND_PORT}/redoc;
        proxy_http_version 1.1;
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
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  step "Relinking nginx site"
  mkdir -p "$(dirname "${NGINX_ENABLED}")"
  ln -sfn "${NGINX_SITE}" "${NGINX_ENABLED}"

  step "Testing nginx syntax"
  nginx -t

  step "Reloading nginx"
  if have systemctl; then
    systemctl restart nginx.service 2>/dev/null || systemctl restart nginx 2>/dev/null || nginx -s reload
  else
    nginx -s reload
  fi

  ok "nginx config is valid and loaded"
}

print_openapi_paths() {
  step "Reading OpenAPI paths"
  curl -fsS "${OPENAPI_URL}" | python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
paths = sorted(data.get("paths", {}).keys())
print()
print("Discovered backend paths:")
for p in paths:
    print("  " + p)
print()
print("Likely health endpoints:")
for p in paths:
    if "health" in p.lower() or "ping" in p.lower():
        print("  " + p)
print()
print("Likely model/analyze endpoints:")
for p in paths:
    lp = p.lower()
    if any(k in lp for k in ("predict", "analy", "model", "infer")):
        print("  " + p)
print()
PY
}

assert_required_api_paths() {
  step "Checking required backend paths from OpenAPI"
  curl -fsS "${OPENAPI_URL}" | python3 - <<'PY'
import json, sys
data = json.load(sys.stdin)
paths = set(data.get("paths", {}).keys())
required = ["/api/health", "/api/predict/single", "/api/predict/batch"]
missing = [p for p in required if p not in paths]
if missing:
    print("MISSING")
    for m in missing:
        print(m)
    sys.exit(1)
print("OK")
PY
  ok "Required API paths are present"
}

print_summary() {
  local public_ip
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

  echo
  echo "============================================================"
  echo "DEPLOYMENT SUMMARY"
  echo "============================================================"
  echo "App dir:           ${APP_DIR}"
  echo "Frontend local:    ${FRONTEND_URL}"
  echo "Backend local:     ${BACKEND_URL}"
  echo "OpenAPI local:     ${OPENAPI_URL}"
  echo "Health local:      ${HEALTH_URL}"
  [[ -n "${public_ip}" ]] && echo "Public URL guess:   http://${public_ip}"
  echo
  echo "Port owners:"
  echo "  3000 -> $(port_owner 3000 | tr -s ' ' || true)"
  echo "  8000 -> $(port_owner 8000 | tr -s ' ' || true)"
  echo "  80   -> $(port_owner 80   | tr -s ' ' || true)"
  echo "============================================================"
  echo
}

###############################################################################
# MAIN
###############################################################################

main() {
  require_cmd curl
  require_cmd python3
  require_cmd ss
  require_cmd find
  require_cmd stat

  cd "${APP_DIR}"

  verify_models
  verify_expected_model_names_if_set

  start_backend_if_needed
  start_frontend_if_needed
  write_clean_nginx_config

  wait_http_any "${FRONTEND_URL}" "frontend local" 10 1 || die "Frontend not reachable"
  wait_http_ok  "${HEALTH_URL}"   "backend health local" 10 1 || die "Backend health not reachable"
  wait_http_any "http://127.0.0.1/" "nginx local" 10 1 || die "nginx not reachable on port 80"

  print_openapi_paths
  assert_required_api_paths

  ok "testing.sh completed successfully"
  print_summary
}

main "$@"
