#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

log()  { printf '\n==> %s\n' "$*"; }
ok()   { printf 'OK  %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }
die()  { printf 'XX  %s\n' "$*" >&2; exit 1; }

trap 'die "Stopped at line $LINENO. Check the message above."' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Run this as root: sudo bash ./fix.sh"
  fi
}

ORIG_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER:-hasan}")}"
ORIG_HOME="$(getent passwd "$ORIG_USER" | cut -d: -f6)"
[[ -n "${ORIG_HOME:-}" ]] || ORIG_HOME="/home/$ORIG_USER"

APP_ROOT="${APP_ROOT:-$ORIG_HOME/layout}"
BACKEND_SERVICE="${BACKEND_SERVICE:-layout-backend}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:-layout-frontend}"
NGINX_SERVICE="nginx"
BACKEND_LOCAL="${BACKEND_LOCAL:-http://127.0.0.1:8000}"
UPLOAD_LIMIT="${UPLOAD_LIMIT:-200M}"
READ_TIMEOUT="${READ_TIMEOUT:-600s}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-60s}"

NGINX_CONF=""
NGINX_CONF_REAL=""
BACKUP_PATH=""

find_nginx_conf() {
  log "Finding active nginx config"
  local candidates=(
    /etc/nginx/sites-enabled/layout-host
    /etc/nginx/sites-available/layout-host
    /etc/nginx/sites-enabled/default
    /etc/nginx/sites-available/default
  )
  local f
  for f in "${candidates[@]}"; do
    if [[ -e "$f" ]]; then
      NGINX_CONF="$f"
      NGINX_CONF_REAL="$(readlink -f "$f")"
      ok "Using nginx config: $NGINX_CONF_REAL"
      return 0
    fi
  done
  die "Could not find an nginx site config to patch"
}

backup_nginx_conf() {
  local ts
  ts="$(date +%Y%m%d_%H%M%S)"
  BACKUP_PATH="${NGINX_CONF_REAL}.bak.${ts}"
  cp -a "$NGINX_CONF_REAL" "$BACKUP_PATH"
  ok "Backed up nginx config to $BACKUP_PATH"
}

restore_nginx_conf() {
  if [[ -n "${BACKUP_PATH:-}" && -f "${BACKUP_PATH:-}" ]]; then
    warn "Restoring nginx config from backup"
    cp -af "$BACKUP_PATH" "$NGINX_CONF_REAL"
    nginx -t >/dev/null 2>&1 || true
    systemctl restart "$NGINX_SERVICE" || true
  fi
}

sanitize_and_patch_nginx() {
  log "Sanitizing and patching nginx for uploads and long proxy timeouts"
  python3 - "$NGINX_CONF_REAL" "$UPLOAD_LIMIT" "$READ_TIMEOUT" "$CONNECT_TIMEOUT" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
upload_limit = sys.argv[2]
read_timeout = sys.argv[3]
connect_timeout = sys.argv[4]

raw = path.read_bytes()
raw = raw.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
if raw.startswith(b"\xef\xbb\xbf"):
    raw = raw[3:]

# Remove weird control bytes that can create broken directives like "hM"
clean = bytearray()
for b in raw:
    if b in (9, 10) or 32 <= b <= 126:
        clean.append(b)
text = clean.decode("ascii", "ignore")

# Strip junk before the first directive token on each non-comment line
fixed_lines = []
for line in text.split("\n"):
    if not line.strip() or line.lstrip().startswith("#"):
        fixed_lines.append(line.rstrip())
        continue
    m = re.search(r"[A-Za-z_][A-Za-z0-9_]*", line)
    if m:
        prefix = line[:m.start()]
        if prefix.strip():
            line = line[m.start():]
    fixed_lines.append(line.rstrip())

text = "\n".join(fixed_lines).strip() + "\n"

settings = {
    "client_max_body_size": upload_limit,
    "proxy_read_timeout": read_timeout,
    "proxy_send_timeout": read_timeout,
    "proxy_connect_timeout": connect_timeout,
    "send_timeout": read_timeout,
}

for name, value in settings.items():
    pattern = re.compile(rf"(?m)^\s*{re.escape(name)}\s+[^;]+;")
    replacement = f"{name} {value};"
    if pattern.search(text):
        text = pattern.sub(replacement, text, count=1)
    else:
        text = replacement + "\n" + text

path.write_text(text, encoding="utf-8", newline="\n")
PY

  if ! nginx -t >/tmp/fix_nginx_test.out 2>&1; then
    cat /tmp/fix_nginx_test.out >&2 || true
    restore_nginx_conf
    die "nginx syntax test failed after patch; original config restored"
  fi
  ok "nginx syntax is valid after patch"
}

patch_frontend_api_envs() {
  log "Normalizing common frontend API env vars to relative /api"
  local public_ip
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

  while IFS= read -r -d '' envfile; do
    python3 - "$envfile" "${public_ip:-}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
public_ip = sys.argv[2].strip()

text = path.read_text(encoding="utf-8", errors="ignore")
orig = text

vars_ = [
    "VITE_API_URL",
    "VITE_API_BASE_URL",
    "NEXT_PUBLIC_API_URL",
    "NEXT_PUBLIC_API_BASE_URL",
    "REACT_APP_API_URL",
    "REACT_APP_API_BASE_URL",
    "PUBLIC_API_URL",
    "PUBLIC_API_BASE_URL",
    "API_URL",
    "API_BASE_URL",
]

absolute_patterns = [
    r"https?://thelayout\.duckdns\.org/?",
    r"https?://127\.0\.0\.1:8000/?",
    r"https?://localhost:8000/?",
]
if public_ip:
    absolute_patterns.append(rf"https?://{re.escape(public_ip)}(?::8000)?/?")

for var in vars_:
    rx = re.compile(rf"(?m)^({re.escape(var)}=)(.*)$")
    m = rx.search(text)
    if not m:
        continue
    value = m.group(2).strip().strip('"').strip("'")
    if any(re.fullmatch(p, value) for p in absolute_patterns):
        text = rx.sub(rf"\1/api", text)

if text != orig:
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"patched {path}")
PY
  done < <(find "$APP_ROOT" -maxdepth 4 -type f \( -name ".env" -o -name ".env.*" -o -name "*.env" \) -print0 2>/dev/null || true)

  ok "Frontend API env normalization done"
}

restart_services() {
  log "Reloading systemd and restarting services"
  systemctl daemon-reload
  systemctl restart "$BACKEND_SERVICE"
  systemctl restart "$FRONTEND_SERVICE"
  systemctl restart "$NGINX_SERVICE"

  systemctl is-active --quiet "$BACKEND_SERVICE" || die "$BACKEND_SERVICE is not active"
  systemctl is-active --quiet "$FRONTEND_SERVICE" || die "$FRONTEND_SERVICE is not active"
  systemctl is-active --quiet "$NGINX_SERVICE" || die "$NGINX_SERVICE is not active"

  ok "$BACKEND_SERVICE is active"
  ok "$FRONTEND_SERVICE is active"
  ok "$NGINX_SERVICE is active"
}

curl_ok() {
  local url="$1"
  curl -fsS -m 20 "$url" >/dev/null 2>&1
}

probe_backend() {
  log "Probing backend locally"
  local urls=(
    "$BACKEND_LOCAL/health"
    "$BACKEND_LOCAL/api/health"
    "$BACKEND_LOCAL/openapi.json"
    "$BACKEND_LOCAL/docs"
    "$BACKEND_LOCAL/"
  )
  local url
  for url in "${urls[@]}"; do
    if curl_ok "$url"; then
      ok "Backend reachable: $url"
      return 0
    fi
  done

  journalctl -u "$BACKEND_SERVICE" -n 80 --no-pager || true
  die "Backend is not responding on common local endpoints"
}

probe_frontend() {
  log "Probing frontend through nginx"
  local public_ip
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local urls=(
    "http://127.0.0.1"
    "http://localhost"
  )
  if [[ -n "${public_ip:-}" ]]; then
    urls+=("http://$public_ip")
  fi

  local url
  for url in "${urls[@]}"; do
    if curl -fsS -m 20 -L "$url" >/dev/null 2>&1; then
      ok "Frontend reachable: $url"
      return 0
    fi
  done
  die "Frontend is not reachable through nginx"
}

probe_proxy_to_backend() {
  log "Checking that nginx can still reach the backend"
  local public_ip
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local urls=(
    "http://127.0.0.1/openapi.json"
    "http://127.0.0.1/api/openapi.json"
    "http://localhost/openapi.json"
    "http://localhost/api/openapi.json"
  )
  if [[ -n "${public_ip:-}" ]]; then
    urls+=(
      "http://$public_ip/openapi.json"
      "http://$public_ip/api/openapi.json"
    )
  fi

  local url
  for url in "${urls[@]}"; do
    if curl_ok "$url"; then
      ok "Proxied backend reachable: $url"
      return 0
    fi
  done

  warn "Could not confirm a proxied OpenAPI route. Local backend is up, but your frontend may call a different API path."
}

check_upload_endpoint_presence() {
  log "Checking for upload-capable endpoints in OpenAPI"
  local spec
  if ! spec="$(curl -fsS -m 20 "$BACKEND_LOCAL/openapi.json" 2>/dev/null)"; then
    warn "Could not fetch openapi.json from backend; skipping endpoint discovery"
    return 0
  fi

  local out
  out="$(python3 - <<'PY' <<<"$spec"
import json, sys
try:
    spec = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

hits = []
for path, ops in spec.get("paths", {}).items():
    if not isinstance(ops, dict):
        continue
    for method, meta in ops.items():
        if not isinstance(meta, dict):
            continue
        rb = meta.get("requestBody", {})
        content = rb.get("content", {})
        if "multipart/form-data" in content:
            hits.append(f"{method.upper()} {path}")
if hits:
    print("\n".join(hits[:20]))
PY
)"
  if [[ -n "${out:-}" ]]; then
    ok "Found upload-capable endpoints:"
    printf '%s\n' "$out"
  else
    warn "No multipart upload endpoints were found in OpenAPI"
  fi
}

check_models() {
  log "Checking model reachability"

  local -a env_targets=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && env_targets+=("$line")
  done < <(
    grep -RhoE '([A-Z0-9_]*MODEL[A-Z0-9_]*(PATH|FILE|URL))=["'"'"']?[^"'"'"'[:space:]]+' \
      "$APP_ROOT" /etc/systemd/system /lib/systemd/system 2>/dev/null \
      | sed -E 's/^[^=]+=//g' \
      | sort -u
  )

  local found=0
  local target
  for target in "${env_targets[@]}"; do
    if [[ "$target" =~ ^https?:// ]]; then
      if curl -fsS -m 20 "$target" >/dev/null 2>&1; then
        ok "Remote model target reachable: $target"
        ((found+=1))
      else
        warn "Remote model target not reachable: $target"
      fi
    else
      if [[ -r "$target" ]]; then
        ok "Local model target readable: $target"
        ((found+=1))
      else
        warn "Local model target missing/unreadable: $target"
      fi
    fi
  done

  if (( found < 3 )); then
    local -a local_models=()
    while IFS= read -r -d '' f; do
      local_models+=("$f")
    done < <(find "$APP_ROOT" -type f \( -iname "*.pt" -o -iname "*.onnx" -o -iname "*.pth" -o -iname "*.engine" -o -iname "*.trt" -o -iname "*.safetensors" \) -print0 2>/dev/null || true)

    if (( ${#local_models[@]} >= 3 )); then
      local unique=""
      local count=0
      local f
      for f in "${local_models[@]}"; do
        if [[ ":$unique:" != *":$f:"* ]]; then
          unique="${unique}:$f"
          if [[ -r "$f" ]]; then
            ok "Model artifact readable: $f"
            ((count+=1))
          fi
        fi
        (( count >= 3 )) && break
      done
      (( count >= 3 )) || die "Could not verify 3 readable model artifacts"
    else
      die "Could not find 3 model targets or artifacts under $APP_ROOT"
    fi
  fi

  journalctl -u "$BACKEND_SERVICE" -n 120 --no-pager | grep -Ei 'model|worker pool|loaded|ready|error|traceback' || true
}

check_for_hardcoded_hosts() {
  log "Scanning for stale hardcoded hosts in frontend files"
  local public_ip
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  grep -RInE "thelayout\.duckdns\.org|127\.0\.0\.1:8000|localhost:8000|${public_ip:-DO_NOT_MATCH}" \
    "$APP_ROOT" \
    --exclude-dir=.git \
    --exclude-dir=.venv \
    --exclude-dir=node_modules \
    --exclude='*.pyc' \
    2>/dev/null | head -n 40 || true
}

show_summary() {
  log "Summary"
  local public_ip
  public_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "App root:        $APP_ROOT"
  echo "nginx conf:      $NGINX_CONF_REAL"
  echo "backup:          $BACKUP_PATH"
  echo "backend local:   $BACKEND_LOCAL"
  [[ -n "${public_ip:-}" ]] && echo "frontend public: http://$public_ip"
  echo "services:        $BACKEND_SERVICE, $FRONTEND_SERVICE, $NGINX_SERVICE"
  echo
  echo "Done."
}

main() {
  require_root
  [[ -d "$APP_ROOT" ]] || die "App root not found: $APP_ROOT"

  find_nginx_conf
  backup_nginx_conf
  sanitize_and_patch_nginx
  patch_frontend_api_envs
  restart_services
  probe_backend
  probe_frontend
  probe_proxy_to_backend
  check_upload_endpoint_presence
  check_models
  check_for_hardcoded_hosts
  show_summary
}

main "$@"
