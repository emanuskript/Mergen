#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME:-layout}"
BACKEND_SERVICE="${BACKEND_SERVICE:-layout-backend}"
FRONTEND_SERVICE="${FRONTEND_SERVICE:-layout-frontend}"
NGINX_SERVICE="${NGINX_SERVICE:-nginx}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:8000}"
NGINX_LOCAL_URL="${NGINX_LOCAL_URL:-http://127.0.0.1}"
UPLOAD_ENDPOINT="${UPLOAD_ENDPOINT:-/api/predict/single}"
HEALTH_ENDPOINT="${HEALTH_ENDPOINT:-/api/health}"
CLASSES_ENDPOINT="${CLASSES_ENDPOINT:-/api/classes}"

log()  { echo -e "\033[1;34m==>\033[0m $*"; }
ok()   { echo -e "\033[1;32mOK \033[0m $*"; }
warn() { echo -e "\033[1;33m!! \033[0m $*"; }
err()  { echo -e "\033[1;31mXX \033[0m $*" >&2; }

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

need_cmd curl
need_cmd python3
need_cmd nginx
need_cmd systemctl
need_cmd journalctl
need_cmd grep
need_cmd sed
need_cmd awk
need_cmd mktemp

find_nginx_file() {
  local candidate=""
  for f in \
    /etc/nginx/sites-available/layout-host \
    /etc/nginx/sites-enabled/layout-host \
    /etc/nginx/conf.d/layout-host.conf \
    /etc/nginx/conf.d/default.conf \
    /etc/nginx/sites-available/default
  do
    if [[ -f "$f" ]]; then
      candidate="$f"
      break
    fi
  done

  if [[ -z "$candidate" ]]; then
    candidate="$($SUDO grep -RIl '127\.0\.0\.1:8000\|layout-backend\|/api/' /etc/nginx/sites-available /etc/nginx/sites-enabled /etc/nginx/conf.d 2>/dev/null | head -n1 || true)"
  fi

  echo "$candidate"
}

patch_nginx_file() {
  local file="$1"

  [[ -f "$file" ]] || {
    err "Nginx config file not found: $file"
    return 1
  }

  local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
  $SUDO cp "$file" "$backup"
  ok "Backed up nginx config to $backup"

  local tmp
  tmp="$(mktemp)"

  $SUDO python3 - "$file" "$tmp" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
tmp = Path(sys.argv[2])

text = src.read_text()

directives = {
    "client_max_body_size": "50M",
    "proxy_connect_timeout": "60s",
    "proxy_read_timeout": "600s",
    "proxy_send_timeout": "600s",
    "proxy_request_buffering": "off",
    "proxy_buffering": "off",
}

for key, value in directives.items():
    text = re.sub(
        rf"(^\s*{re.escape(key)}\s+)[^;]+;",
        rf"\1{value};",
        text,
        flags=re.MULTILINE,
    )

missing = [k for k in directives if not re.search(rf"^\s*{re.escape(k)}\s+[^;]+;", text, flags=re.MULTILINE)]

block = "\n".join([
    f"    {k} {v};" for k, v in directives.items() if k in missing
])

if block:
    m = re.search(r"server\s*\{", text)
    if not m:
        raise SystemExit("No nginx server block found to patch.")
    insert_at = m.end()
    text = text[:insert_at] + "\n" + block + text[insert_at:]

tmp.write_text(text)
PY

  $SUDO cp "$tmp" "$file"
  rm -f "$tmp"

  $SUDO nginx -t >/dev/null
  ok "Nginx config syntax is valid"
}

restart_services() {
  log "Restarting services"
  $SUDO systemctl daemon-reload || true
  $SUDO systemctl restart "$BACKEND_SERVICE" || true
  $SUDO systemctl restart "$FRONTEND_SERVICE" || true
  $SUDO systemctl restart "$NGINX_SERVICE"
}

wait_for_health() {
  local url="$1"
  local tries="${2:-30}"
  local i

  for ((i=1; i<=tries; i++)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      ok "Health check passed: $url"
      return 0
    fi
    sleep 2
  done

  err "Health check failed: $url"
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

curl_status() {
  local url="$1"
  local outfile="$2"
  shift 2
  curl -sS -o "$outfile" -w "%{http_code}" "$url" "$@" || true
}

show_recent_logs() {
  warn "Recent backend logs:"
  $SUDO journalctl -u "$BACKEND_SERVICE" -n 80 --no-pager || true
  warn "Recent nginx error log:"
  $SUDO tail -n 80 /var/log/nginx/error.log 2>/dev/null || true
}

main() {
  log "Finding active nginx config"
  local nginx_file
  nginx_file="$(find_nginx_file)"

  if [[ -z "$nginx_file" ]]; then
    err "Could not detect the active nginx site config automatically."
    exit 1
  fi

  ok "Using nginx config: $nginx_file"

  log "Patching nginx for uploads and longer proxy timeouts"
  patch_nginx_file "$nginx_file"

  restart_services

  wait_for_health "${BACKEND_URL}${HEALTH_ENDPOINT}" 30
  wait_for_health "${NGINX_LOCAL_URL}${HEALTH_ENDPOINT}" 30

  log "Checking classes endpoint through nginx"
  local classes_body
  classes_body="$(mktemp)"
  local classes_code
  classes_code="$(curl_status "${NGINX_LOCAL_URL}${CLASSES_ENDPOINT}" "$classes_body")"
  echo "classes HTTP $classes_code"
  head -c 300 "$classes_body" || true
  echo
  rm -f "$classes_body"

  local test_img
  test_img="$(mktemp --suffix=.png)"
  make_test_png "$test_img"
  ok "Created test image: $test_img"

  log "Testing upload directly against backend"
  local backend_body backend_code
  backend_body="$(mktemp)"
  backend_code="$(
    curl_status "${BACKEND_URL}${UPLOAD_ENDPOINT}" "$backend_body" \
      -X POST \
      -F "image=@${test_img};type=image/png"
  )"
  echo "backend upload HTTP $backend_code"
  head -c 500 "$backend_body" || true
  echo

  log "Testing upload through nginx"
  local nginx_body nginx_code
  nginx_body="$(mktemp)"
  nginx_code="$(
    curl_status "${NGINX_LOCAL_URL}${UPLOAD_ENDPOINT}" "$nginx_body" \
      -X POST \
      -F "image=@${test_img};type=image/png"
  )"
  echo "nginx upload HTTP $nginx_code"
  head -c 500 "$nginx_body" || true
  echo

  rm -f "$test_img"

  if [[ "$backend_code" == "200" && "$nginx_code" == "200" ]]; then
    ok "Upload works directly and through nginx."
    rm -f "$backend_body" "$nginx_body"
    exit 0
  fi

  if [[ "$backend_code" == "200" && "$nginx_code" != "200" ]]; then
    err "Backend upload works, but nginx upload still fails."
    show_recent_logs
    rm -f "$backend_body" "$nginx_body"
    exit 2
  fi

  if [[ "$backend_code" != "200" ]]; then
    err "Direct backend upload failed. This is not only an nginx issue."
    show_recent_logs
    rm -f "$backend_body" "$nginx_body"
    exit 3
  fi

  err "Unexpected state."
  show_recent_logs
  rm -f "$backend_body" "$nginx_body"
  exit 4
}

main "$@"
