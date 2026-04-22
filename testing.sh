#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
BACKEND_DIR="$REPO_DIR/backend"
MODELS_DIR="$BACKEND_DIR/models"

FRONTEND_LOCAL_URL="http://127.0.0.1:3000"
BACKEND_LOCAL_URL="http://127.0.0.1:8000"
NGINX_LOCAL_URL="http://127.0.0.1"

# ---------- pretty output ----------
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

step() { echo -e "\n${BLUE}==>${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC}  $*"; }
warn() { echo -e "${YELLOW}!!${NC}  $*"; }
fail() { echo -e "${RED}XX${NC}  $*"; }

# ---------- helpers ----------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

http_code() {
  local url="$1"
  curl -L -sS -o /dev/null -w '%{http_code}' --max-time 12 "$url" 2>/dev/null || echo "000"
}

http_code_host() {
  local host="$1"
  local url="$2"
  curl -L -sS -o /dev/null -w '%{http_code}' --max-time 12 -H "Host: $host" "$url" 2>/dev/null || echo "000"
}

is_good_http() {
  local code="$1"
  [[ "$code" =~ ^2[0-9][0-9]$ || "$code" =~ ^3[0-9][0-9]$ ]]
}

first_line() {
  awk 'NF {print; exit}'
}

resolve_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | first_line || true
}

detect_public_ip() {
  local ip=""
  if have_cmd hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}')"
  fi
  echo "$ip"
}

detect_public_fqdn() {
  local fqdn=""
  fqdn="$(hostname -f 2>/dev/null || true)"
  if [[ -n "$fqdn" && "$fqdn" != "localhost" && "$fqdn" != "localhost.localdomain" ]]; then
    echo "$fqdn"
    return
  fi
  echo ""
}

check_url() {
  local label="$1"
  local url="$2"
  local code
  code="$(http_code "$url")"
  if is_good_http "$code"; then
    ok "$label is reachable: $url [$code]"
    return 0
  else
    fail "$label is NOT reachable: $url [$code]"
    return 1
  fi
}

check_url_with_host() {
  local label="$1"
  local host="$2"
  local url="$3"
  local code
  code="$(http_code_host "$host" "$url")"
  if is_good_http "$code"; then
    ok "$label is reachable with Host=$host via $url [$code]"
    return 0
  else
    fail "$label is NOT reachable with Host=$host via $url [$code]"
    return 1
  fi
}

# ---------- detect public identity ----------
PUBLIC_IP="$(detect_public_ip)"
PUBLIC_FQDN="$(detect_public_fqdn)"
RESOLVED_FQDN_IP=""

if [[ -n "$PUBLIC_FQDN" ]]; then
  RESOLVED_FQDN_IP="$(resolve_ipv4 "$PUBLIC_FQDN")"
fi

# ---------- basic file checks ----------
step "Checking repository layout"
[[ -d "$BACKEND_DIR" ]] && ok "Backend directory found: $BACKEND_DIR" || { fail "Missing backend directory: $BACKEND_DIR"; exit 1; }
[[ -d "$MODELS_DIR" ]] && ok "Models directory found: $MODELS_DIR" || { fail "Missing models directory: $MODELS_DIR"; exit 1; }

step "Checking required model weights"
REQUIRED_MODELS=(
  "$MODELS_DIR/best_catmus.pt"
  "$MODELS_DIR/best_emanuskript_segmentation.pt"
  "$MODELS_DIR/best_zone_detection.pt"
)

for model in "${REQUIRED_MODELS[@]}"; do
  if [[ -f "$model" ]]; then
    ok "Found model: $model"
  else
    fail "Missing model: $model"
    exit 1
  fi
done

# ---------- process / port checks ----------
step "Checking listening ports"
if have_cmd ss; then
  ss -ltnp 2>/dev/null | grep -E ':(80|3000|8000)\s' || warn "Did not see one or more expected listening ports in ss output"
else
  warn "ss not available; skipping port inspection"
fi

# ---------- service checks ----------
step "Checking nginx process"
if pgrep -x nginx >/dev/null 2>&1; then
  ok "nginx process is running"
else
  fail "nginx process is not running"
fi

if have_cmd systemctl; then
  if systemctl is-active --quiet nginx; then
    ok "nginx service is active"
  else
    warn "nginx service is not active according to systemctl"
  fi
fi

# ---------- local URL checks ----------
step "Checking local endpoints"
check_url "frontend local root" "$FRONTEND_LOCAL_URL/"
check_url "backend local openapi" "$BACKEND_LOCAL_URL/openapi.json"
check_url "backend local health" "$BACKEND_LOCAL_URL/api/health"
check_url "nginx local root" "$NGINX_LOCAL_URL/"
check_url "backend through nginx local" "$NGINX_LOCAL_URL/api/health"

# ---------- API route discovery ----------
step "Inspecting backend OpenAPI for expected routes"
OPENAPI_TMP="$(mktemp)"
if curl -fsS --max-time 12 "$BACKEND_LOCAL_URL/openapi.json" -o "$OPENAPI_TMP"; then
  ok "Downloaded OpenAPI spec"
  grep -oE '"/api/[^"]+' "$OPENAPI_TMP" | tr -d '"' | sort -u || true

  echo
  echo "Likely health endpoints:"
  grep -oE '/api/health[^", ]*' "$OPENAPI_TMP" | sort -u || true

  echo
  echo "Likely model/analyze endpoints:"
  grep -oE '/api/[^", ]*(predict|analy|class|download)[^", ]*' "$OPENAPI_TMP" | sort -u || true
else
  warn "Could not fetch OpenAPI spec from backend"
fi
rm -f "$OPENAPI_TMP"

# ---------- hostname / DNS checks ----------
step "Checking public hostname and DNS"

if [[ -n "$PUBLIC_FQDN" ]]; then
  ok "Detected VM hostname: $PUBLIC_FQDN"
else
  warn "No FQDN detected from hostname -f"
fi

if [[ -n "$PUBLIC_IP" ]]; then
  ok "Detected VM IP: $PUBLIC_IP"
else
  warn "Could not detect a non-loopback IP from hostname -I"
fi

if [[ -n "$PUBLIC_FQDN" && -n "$RESOLVED_FQDN_IP" ]]; then
  ok "Hostname resolves in DNS: $PUBLIC_FQDN -> $RESOLVED_FQDN_IP"
  if [[ -n "$PUBLIC_IP" && "$PUBLIC_IP" != "$RESOLVED_FQDN_IP" ]]; then
    warn "DNS IP does not match detected host IP"
    warn "Detected host IP: $PUBLIC_IP"
    warn "Resolved DNS IP:  $RESOLVED_FQDN_IP"
  fi
elif [[ -n "$PUBLIC_FQDN" ]]; then
  warn "Hostname exists locally but does not resolve via getent: $PUBLIC_FQDN"
fi

# ---------- Host-header nginx checks ----------
step "Checking nginx routing with Host header"

if [[ -n "$PUBLIC_FQDN" ]]; then
  check_url_with_host "nginx root using public hostname locally" "$PUBLIC_FQDN" "$NGINX_LOCAL_URL/"
  check_url_with_host "nginx /api/health using public hostname locally" "$PUBLIC_FQDN" "$NGINX_LOCAL_URL/api/health"
else
  warn "Skipping Host-header test because no public hostname was detected"
fi

# ---------- public reachability checks ----------
step "Checking likely public URLs"

FINAL_URL=""
FINAL_OK=0

if [[ -n "$PUBLIC_FQDN" ]]; then
  FQDN_URL="http://$PUBLIC_FQDN/"
  FQDN_API_URL="http://$PUBLIC_FQDN/api/health"

  FQDN_ROOT_CODE="$(http_code "$FQDN_URL")"
  FQDN_API_CODE="$(http_code "$FQDN_API_URL")"

  if is_good_http "$FQDN_ROOT_CODE"; then
    ok "Public hostname root reachable: $FQDN_URL [$FQDN_ROOT_CODE]"
    FINAL_URL="$FQDN_URL"
    FINAL_OK=1
  else
    warn "Public hostname root not reachable yet: $FQDN_URL [$FQDN_ROOT_CODE]"
  fi

  if is_good_http "$FQDN_API_CODE"; then
    ok "Public hostname API reachable: $FQDN_API_URL [$FQDN_API_CODE]"
  else
    warn "Public hostname API not reachable yet: $FQDN_API_URL [$FQDN_API_CODE]"
  fi
fi

if [[ $FINAL_OK -eq 0 && -n "$PUBLIC_IP" ]]; then
  IP_URL="http://$PUBLIC_IP/"
  IP_API_URL="http://$PUBLIC_IP/api/health"

  IP_ROOT_CODE="$(http_code "$IP_URL")"
  IP_API_CODE="$(http_code "$IP_API_URL")"

  if is_good_http "$IP_ROOT_CODE"; then
    ok "Public IP root reachable: $IP_URL [$IP_ROOT_CODE]"
    FINAL_URL="$IP_URL"
    FINAL_OK=1
  else
    warn "Public IP root not reachable yet: $IP_URL [$IP_ROOT_CODE]"
  fi

  if is_good_http "$IP_API_CODE"; then
    ok "Public IP API reachable: $IP_API_URL [$IP_API_CODE]"
  else
    warn "Public IP API not reachable yet: $IP_API_URL [$IP_API_CODE]"
  fi
fi

# ---------- firewall hints ----------
step "Checking local firewall hints"

if have_cmd ufw; then
  ufw status || true
else
  warn "ufw not installed"
fi

# ---------- summary ----------
step "Summary"

echo "Frontend local:   $FRONTEND_LOCAL_URL"
echo "Backend local:    $BACKEND_LOCAL_URL"
echo "Nginx local:      $NGINX_LOCAL_URL"
echo "Detected FQDN:    ${PUBLIC_FQDN:-<none>}"
echo "Detected IP:      ${PUBLIC_IP:-<none>}"

if [[ $FINAL_OK -eq 1 ]]; then
  ok "Final public URL candidate: $FINAL_URL"
else
  fail "No globally reachable URL was confirmed from this VM"
  echo
  echo "Most likely causes:"
  echo "  1) DNS/hostname is missing or wrong"
  echo "  2) Port 80 is blocked by VM/provider firewall"
  echo "  3) nginx is serving locally but not reachable externally"
  exit 2
fi

ok "testing completed"
