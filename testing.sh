#!/usr/bin/env bash
set -uo pipefail

# -----------------------------
# Fixed paths for this VM
# -----------------------------
REPO_DIR="/home/hasan/layout"
BACKEND_DIR="/home/hasan/layout/backend"
FRONTEND_DIR="/home/hasan/layout/frontend"
MODELS_DIR="/home/hasan/layout/backend/models"

EXPECTED_WEIGHT_FILES=(
  "/home/hasan/layout/backend/models/best_catmus.pt"
  "/home/hasan/layout/backend/models/best_emanuskript_segmentation.pt"
  "/home/hasan/layout/backend/models/best_zone_detection.pt"
)

FRONTEND_LOCAL="http://127.0.0.1:3000"
BACKEND_LOCAL="http://127.0.0.1:8000"
NGINX_LOCAL="http://127.0.0.1"

PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
PUBLIC_URL=""
if [[ -n "${PUBLIC_IP:-}" ]]; then
  PUBLIC_URL="http://${PUBLIC_IP}"
fi

FAILURES=0
WARNINGS=0

blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }

ok()   { green "OK  $*"; }
warn() { yellow "!!  $*"; WARNINGS=$((WARNINGS + 1)); }
err()  { red "XX  $*"; FAILURES=$((FAILURES + 1)); }
step() { echo; blue "==> $*"; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "Required command not found: $cmd"
    return 1
  }
}

http_code() {
  local url="$1"
  curl -sS -L -o /dev/null -w "%{http_code}" --max-time 20 "$url" 2>/dev/null || echo "000"
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local tries="${3:-20}"
  local sleep_s="${4:-2}"
  local code="000"

  for ((i=1; i<=tries; i++)); do
    code="$(http_code "$url")"
    if [[ "$code" =~ ^2|3 ]]; then
      ok "$label is reachable: $url ($code)"
      return 0
    fi
    sleep "$sleep_s"
  done

  err "$label did not become reachable: $url (last code: $code)"
  return 1
}

check_file() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    err "Missing file: $path"
    return 1
  fi
  if [[ ! -f "$path" ]]; then
    err "Not a regular file: $path"
    return 1
  fi
  if [[ ! -s "$path" ]]; then
    err "File exists but is empty: $path"
    return 1
  fi
  ok "Found model weight: $path"
  return 0
}

probe_url() {
  local base="$1"
  local path="$2"
  local label="$3"
  local code
  code="$(http_code "${base}${path}")"
  echo "$label ${path} -> ${code}"
}

show_listener_info() {
  step "Listening ports"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp 2>/dev/null | grep -E '(:80 |:80$|:3000 |:3000$|:8000 |:8000$)' || true
  else
    warn "ss not available; skipping listener check"
  fi
}

show_nginx_info() {
  step "Nginx config"
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      ok "nginx syntax is valid"
    else
      err "nginx syntax test failed"
      nginx -t || true
    fi

    if [[ -L /etc/nginx/sites-enabled/layout-host ]]; then
      ok "sites-enabled/layout-host symlink exists"
      ls -l /etc/nginx/sites-enabled/layout-host || true
    else
      warn "Expected symlink missing: /etc/nginx/sites-enabled/layout-host"
    fi

    if [[ -f /etc/nginx/sites-available/layout-host ]]; then
      ok "Found /etc/nginx/sites-available/layout-host"
    else
      warn "Missing /etc/nginx/sites-available/layout-host"
    fi
  else
    warn "nginx command not found"
  fi
}

show_repo_info() {
  step "Repo sanity checks"

  [[ -d "$REPO_DIR" ]]     && ok "Repo dir exists: $REPO_DIR"     || err "Repo dir missing: $REPO_DIR"
  [[ -d "$BACKEND_DIR" ]]  && ok "Backend dir exists: $BACKEND_DIR" || err "Backend dir missing: $BACKEND_DIR"
  [[ -d "$FRONTEND_DIR" ]] && ok "Frontend dir exists: $FRONTEND_DIR" || err "Frontend dir missing: $FRONTEND_DIR"
  [[ -d "$MODELS_DIR" ]]   && ok "Models dir exists: $MODELS_DIR" || err "Models dir missing: $MODELS_DIR"
}

check_model_weights() {
  step "Checking the 3 required model weights"
  local f
  for f in "${EXPECTED_WEIGHT_FILES[@]}"; do
    check_file "$f"
  done
}

fetch_openapi_and_print() {
  step "Reading backend OpenAPI"
  local tmp_json
  tmp_json="$(mktemp)"

  if curl -fsS --max-time 20 "${BACKEND_LOCAL}/openapi.json" > "$tmp_json"; then
    ok "Fetched backend OpenAPI: ${BACKEND_LOCAL}/openapi.json"

    python3 - "$tmp_json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    data = json.load(f)

paths = sorted(data.get("paths", {}).keys())
print()
print("Available API paths:")
for path in paths:
    print(f"  {path}")

health = [x for x in paths if "health" in x.lower() or "ping" in x.lower()]
predict = [x for x in paths if any(k in x.lower() for k in ["predict", "analyze", "analytics", "class"])]

print()
print("Likely health endpoints:")
for path in health or ["<none found>"]:
    print(f"  {path}")

print()
print("Likely model/analyze endpoints:")
for path in predict or ["<none found>"]:
    print(f"  {path}")
PY
  else
    err "Could not fetch backend OpenAPI from ${BACKEND_LOCAL}/openapi.json"
  fi

  rm -f "$tmp_json"
}

probe_common_endpoints() {
  step "Probing common endpoints"

  probe_url "$BACKEND_LOCAL" "/health"      "backend"
  probe_url "$BACKEND_LOCAL" "/ping"        "backend"
  probe_url "$BACKEND_LOCAL" "/api/health"  "backend"
  probe_url "$BACKEND_LOCAL" "/api/ping"    "backend"
  probe_url "$BACKEND_LOCAL" "/analyze"     "backend"
  probe_url "$BACKEND_LOCAL" "/api/analyze" "backend"

  echo
  probe_url "$NGINX_LOCAL" "/"              "nginx"
  probe_url "$NGINX_LOCAL" "/api/health"    "nginx"
  probe_url "$NGINX_LOCAL" "/openapi.json"  "nginx"
  probe_url "$NGINX_LOCAL" "/api/openapi.json" "nginx"

  if [[ -n "$PUBLIC_URL" ]]; then
    echo
    probe_url "$PUBLIC_URL" "/"             "public"
    probe_url "$PUBLIC_URL" "/api/health"   "public"
  fi
}

main() {
  require_cmd curl || true
  require_cmd python3 || true

  step "Starting deployment test"
  show_repo_info
  check_model_weights
  show_nginx_info
  show_listener_info

  step "Waiting for local endpoints"
  wait_for_http "${FRONTEND_LOCAL}/" "frontend local"
  wait_for_http "${BACKEND_LOCAL}/openapi.json" "backend openapi local"
  wait_for_http "${BACKEND_LOCAL}/api/health" "backend /api/health local"

  step "Checking nginx reverse proxy"
  wait_for_http "${NGINX_LOCAL}/" "nginx root"
  wait_for_http "${NGINX_LOCAL}/api/health" "nginx /api/health"

  if [[ -n "$PUBLIC_URL" ]]; then
    step "Checking public URL"
    wait_for_http "${PUBLIC_URL}/" "public root"
    wait_for_http "${PUBLIC_URL}/api/health" "public /api/health"
  else
    warn "Could not determine public IP; skipping public URL checks"
  fi

  fetch_openapi_and_print
  probe_common_endpoints

  echo
  if [[ "$FAILURES" -eq 0 ]]; then
    green "OK  testing completed successfully"
    echo "Frontend local:  ${FRONTEND_LOCAL}"
    echo "Backend local:   ${BACKEND_LOCAL}"
    echo "Nginx local:     ${NGINX_LOCAL}"
    [[ -n "$PUBLIC_URL" ]] && echo "Public URL:      ${PUBLIC_URL}"
    exit 0
  else
    red "XX  testing completed with ${FAILURES} failure(s) and ${WARNINGS} warning(s)"
    echo "Frontend local:  ${FRONTEND_LOCAL}"
    echo "Backend local:   ${BACKEND_LOCAL}"
    echo "Nginx local:     ${NGINX_LOCAL}"
    [[ -n "$PUBLIC_URL" ]] && echo "Public URL:      ${PUBLIC_URL}"
    exit 1
  fi
}

main "$@"
