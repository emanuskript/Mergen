#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-layout}"
BACKEND_SERVICE="${BACKEND_SERVICE:-layout-backend}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:-layout-frontend}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"

BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8000}"
NGINX_LOCAL_URL="${NGINX_LOCAL_URL:-http://127.0.0.1}"

HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/api/health}"
CLASSES_ENDPOINT="${CLASSES_ENDPOINT:-/api/classes}"
UPLOAD_ENDPOINT="${UPLOAD_ENDPOINT:-/api/predict/single}"

UPLOAD_LIMIT="${UPLOAD_LIMIT:-50M}"
PROXY_CONNECT_TIMEOUT="${PROXY_CONNECT_TIMEOUT:-60s}"
PROXY_READ_TIMEOUT="${PROXY_READ_TIMEOUT:-600s}"
PROXY_SEND_TIMEOUT="${PROXY_SEND_TIMEOUT:-600s}"

WORKDIR="${WORKDIR:-$PWD}"

BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

log()  { echo -e "${BLUE}==>${RESET} $*"; }
ok()   { echo -e "${GREEN}OK${RESET}  $*"; }
warn() { echo -e "${YELLOW}!!${RESET}  $*"; }
err()  { echo -e "${RED}XX${RESET}  $*" >&2; }

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Missing required command: $1"
    exit 1
  }
}

cleanup() {
  [[ -n "${TMP_SRC:-}" && -f "${TMP_SRC:-}" ]] && rm -f "$TMP_SRC" || true
  [[ -n "${TMP_OUT:-}" && -f "${TMP_OUT:-}" ]] && rm -f "$TMP_OUT" || true
  [[ -n "${TEST_IMG:-}" && -f "${TEST_IMG:-}" ]] && rm -f "$TEST_IMG" || true
  [[ -n "${BODY1:-}" && -f "${BODY1:-}" ]] && rm -f "$BODY1" || true
  [[ -n "${BODY2:-}" && -f "${BODY2:-}" ]] && rm -f "$BODY2" || true
  [[ -n "${BODY3:-}" && -f "${BODY3:-}" ]] && rm -f "$BODY3" || true
}
trap cleanup EXIT

need_cmd curl
need_cmd python3
need_cmd nginx
need_cmd systemctl
need_cmd journalctl
need_cmd mktemp
need_cmd grep
need_cmd sed
need_cmd awk

find_nginx_file() {
  local f

  for f in \
    /etc/nginx/sites-available/layout-host \
    /etc/nginx/sites-enabled/layout-host \
    /etc/nginx/conf.d/layout-host.conf \
    /etc/nginx/conf.d/default.conf \
    /etc/nginx/sites-available/default
  do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done

  f="$($SUDO grep -RIl '127\.0\.0\.1:8000\|layout-backend\|/api/' \
      /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n1 || true)"

  if [[ -n "$f" ]]; then
    echo "$f"
    return 0
  fi

  return 1
}

backup_nginx_file() {
  local file="$1"
  BACKUP_FILE="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  $SUDO cp "$file" "$BACKUP_FILE"
  ok "Backed up nginx config to $BACKUP_FILE"
}

restore_nginx_backup() {
  local file="$1"
  if [[ -n "${BACKUP_FILE:-}" && -f "${BACKUP_FILE:-}" ]]; then
    warn "Restoring nginx config from backup"
    $SUDO cp "$BACKUP_FILE" "$file"
    $SUDO nginx -t >/dev/null 2>&1 || true
    $SUDO systemctl reload "$NGINX_SERVICE" >/dev/null 2>&1 || true
  fi
}

patch_nginx_file() {
  local file="$1"

  TMP_SRC="$(mktemp "$WORKDIR/.fix_src.XXXXXX")"
  TMP_OUT="$(mktemp "$WORKDIR/.fix_out.XXXXXX")"

  $SUDO cat "$file" > "$TMP_SRC"

  python3 - "$TMP_SRC" "$TMP_OUT" \
    "$UPLOAD_LIMIT" \
    "$PROXY_CONNECT_TIMEOUT" \
    "$PROXY_READ_TIMEOUT" \
    "$PROXY_SEND_TIMEOUT" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
out = Path(sys.argv[2])

upload_limit = sys.argv[3]
proxy_connect_timeout = sys.argv[4]
proxy_read_timeout = sys.argv[5]
proxy_send_timeout = sys.argv[6]

text = src.read_text()

server_match = re.search(r'\bserver\s*\{', text)
if not server_match:
    raise SystemExit("No nginx server block found.")

start = server_match.start()
open_brace = server_match.end() - 1

depth = 0
end = None
for i in range(open_brace, len(text)):
    ch = text[i]
    if ch == '{':
        depth += 1
    elif ch == '}':
        depth -= 1
        if depth == 0:
            end = i
            break

if end is None:
    raise SystemExit("Could not find end of nginx server block.")

server_block = text[start:end+1]

replacements = {
    "client_max_body_size": upload_limit,
    "proxy_connect_timeout": proxy_connect_timeout,
    "proxy_read_timeout": proxy_read_timeout,
    "proxy_send_timeout": proxy_send_timeout,
    "proxy_request_buffering": "off",
    "proxy_buffering": "off",
}

for key, value in replacements.items():
    pattern = re.compile(rf'(^[ \t]*{re.escape(key)}[ \t]+)[^;]+;', re.MULTILINE)
    if pattern.search(server_block):
        server_block = pattern.sub(lambda m, v=value: f"{m.group(1)}{v};", server_block)
    else:
        insertion = f"    {key} {value};\n"
        brace_pos = server_block.find("{")
        server_block = server_block[:brace_pos+1] + "\n" + insertion + server_block[brace_pos+1:]

new_text = text[:start] + server_block + text[end+1:]
out.write_text(new_text)
PY

  backup_nginx_file "$file"
  $SUDO cp "$TMP_OUT" "$file"

  if ! $SUDO nginx -t >/dev/null 2>&1; then
    err "nginx syntax test failed after patch"
    restore_nginx_backup "$file"
    err "Broken patch reverted"
    exit 1
  fi

  ok "nginx config patched successfully"
}

restart_services() {
  log "Restarting services"
  $SUDO systemctl daemon-reload || true
  $SUDO systemctl restart "$BACKEND_SERVICE" || true
  $SUDO systemctl restart "$FRONTEND_SERVICE" || true
  $SUDO systemctl restart "$NGINX_SERVICE"
}

wait_for_url() {
  local url="$1"
  local tries="${2:-30}"
  local i

  for ((i=1; i<=tries; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      ok "Reachable: $url"
      return 0
    fi
    sleep 2
  done

  err "Not reachable after waiting: $url"
  return 1
}

make_test_png() {
  local out="$1"
  python3 - "$out" <<'PY'
import struct
import zlib
import sys

path = sys.argv[1]
w, h = 128, 128

row = b'\x00' + (b'\xff\xff\xff' * w)
raw = row * h

def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xffffffff
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(raw, 9))
png += chunk(b'IEND', b'')

with open(path, "wb") as f:
    f.write(png)
PY
}

post_file() {
  local url="$1"
  local body="$2"
  local img="$3"

  curl -sS \
    -o "$body" \
    -w "%{http_code}" \
    -X POST \
    -F "image=@${img};type=image/png" \
    "$url" || true
}

print_body_preview() {
  local label="$1"
  local code="$2"
  local body="$3"

  echo "$label HTTP $code"
  head -c 600 "$body" || true
  echo
  echo
}

show_logs() {
  warn "Recent backend logs:"
  $SUDO journalctl -u "$BACKEND_SERVICE" -n 120 --no-pager || true
  echo
  warn "Recent nginx error log:"
  $SUDO tail -n 120 /var/log/nginx/error.log 2>/dev/null || true
  echo
}

show_service_status() {
  warn "Service status:"
  $SUDO systemctl --no-pager --full status "$BACKEND_SERVICE" "$FRONTEND_SERVICE" "$NGINX_SERVICE" || true
  echo
}

main() {
  log "Finding active nginx config"
  NGINX_FILE="$(find_nginx_file || true)"

  if [[ -z "${NGINX_FILE:-}" ]]; then
    err "Could not detect the active nginx config."
    exit 1
  fi

  ok "Using nginx config: $NGINX_FILE"

  log "Patching nginx for uploads and proxy timeouts"
  patch_nginx_file "$NGINX_FILE"

  restart_services

  wait_for_url "${BACKEND_URL}${HEALTH_ENDPOINT}" 30
  wait_for_url "${NGINX_LOCAL_URL}${HEALTH_ENDPOINT}" 30

  TEST_IMG="$(mktemp "$WORKDIR/.upload_test.XXXXXX.png")"
  make_test_png "$TEST_IMG"
  ok "Created test image: $TEST_IMG"

  BODY1="$(mktemp "$WORKDIR/.body1.XXXXXX")"
  BODY2="$(mktemp "$WORKDIR/.body2.XXXXXX")"
  BODY3="$(mktemp "$WORKDIR/.body3.XXXXXX")"

  log "Checking classes endpoint through nginx"
  CLASSES_CODE="$(curl -sS -o "$BODY1" -w "%{http_code}" "${NGINX_LOCAL_URL}${CLASSES_ENDPOINT}" || true)"
  print_body_preview "classes" "$CLASSES_CODE" "$BODY1"

  log "Testing direct backend upload"
  DIRECT_CODE="$(post_file "${BACKEND_URL}${UPLOAD_ENDPOINT}" "$BODY2" "$TEST_IMG")"
  print_body_preview "direct backend upload" "$DIRECT_CODE" "$BODY2"

  log "Testing nginx upload"
  NGINX_CODE="$(post_file "${NGINX_LOCAL_URL}${UPLOAD_ENDPOINT}" "$BODY3" "$TEST_IMG")"
  print_body_preview "nginx upload" "$NGINX_CODE" "$BODY3"

  if [[ "$DIRECT_CODE" == "200" && "$NGINX_CODE" == "200" ]]; then
    ok "Upload works directly and through nginx."
    exit 0
  fi

  if [[ "$DIRECT_CODE" == "200" && "$NGINX_CODE" != "200" ]]; then
    err "Backend upload works, but nginx upload still fails."
    show_logs
    exit 2
  fi

  if [[ "$DIRECT_CODE" != "200" ]]; then
    err "Direct backend upload failed too. This is not only nginx."
    show_logs
    show_service_status
    exit 3
  fi

  err "Unexpected upload state."
  show_logs
  show_service_status
  exit 4
}

main "$@"
