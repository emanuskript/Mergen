#!/usr/bin/env bash
set -u

PUBLIC_URL="${1:-http://134.76.19.184}"
LOCAL_FRONTEND="http://127.0.0.1:3000"
LOCAL_BACKEND="http://127.0.0.1:8000"
OPENAPI_URL="$LOCAL_BACKEND/openapi.json"

blue='\033[1;34m'
green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
nc='\033[0m'

say()  { echo -e "${blue}==>${nc} $*"; }
ok()   { echo -e "${green}OK${nc}  $*"; }
warn() { echo -e "${yellow}!!${nc}  $*"; }
fail() { echo -e "${red}XX${nc}  $*"; }

code_of() {
  curl -sS -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "000"
}

head_code_of() {
  curl -sS -o /dev/null -I -w "%{http_code}" "$1" 2>/dev/null || echo "000"
}

show_redirect() {
  curl -sS -o /dev/null -w "%{redirect_url}" "$1" 2>/dev/null
}

TMP_OPENAPI="$(mktemp)"
TMP_IMG="$(mktemp --suffix=.png)"

cleanup() {
  rm -f "$TMP_OPENAPI" "$TMP_IMG"
}
trap cleanup EXIT

say "Checking local endpoints"
for u in \
  "$LOCAL_FRONTEND" \
  "$LOCAL_BACKEND/api/health" \
  "$LOCAL_BACKEND/openapi.json"
do
  c="$(code_of "$u")"
  if [ "$c" = "200" ]; then
    ok "$u -> $c"
  else
    fail "$u -> $c"
  fi
done

say "Fetching OpenAPI"
if ! curl -fsS "$OPENAPI_URL" -o "$TMP_OPENAPI"; then
  fail "Could not fetch $OPENAPI_URL"
  exit 1
fi
ok "OpenAPI downloaded"

say "Extracting important backend paths"
python3 - <<'PY' "$TMP_OPENAPI"
import json, sys
p = json.load(open(sys.argv[1]))
paths = p.get("paths", {})
print("Declared paths:")
for path in sorted(paths):
    if path.startswith("/api/"):
        print(" ", path)
print()
print("Likely health paths:")
for path in sorted(paths):
    if "health" in path.lower() or "ping" in path.lower():
        print(" ", path)
print()
print("Likely prediction/model paths:")
for path in sorted(paths):
    low = path.lower()
    if any(x in low for x in ["predict", "class", "model", "analy", "download"]):
        print(" ", path)
print()
if "/api/predict/single" in paths:
    print("Methods for /api/predict/single:", ",".join(paths["/api/predict/single"].keys()))
PY

say "Testing local backend routes"
for p in \
  "/api/health" \
  "/api/classes" \
  "/api/predict/single" \
  "/api/predict/batch"
do
  c="$(code_of "$LOCAL_BACKEND$p")"
  echo "local  $p -> $c"
done

say "Testing public proxy routes"
for p in \
  "/" \
  "/api/health" \
  "/api/classes" \
  "/api/predict/single" \
  "/api/predict/batch"
do
  c="$(code_of "$PUBLIC_URL$p")"
  echo "public $p -> $c"
done

say "Checking redirects"
r="$(show_redirect "$PUBLIC_URL")"
if [ -n "$r" ]; then
  warn "Public root redirects to: $r"
else
  ok "Public root does not redirect"
fi

say "Checking frontend for hardcoded localhost / wrong API base"
grep -RInE "127\.0\.0\.1|localhost|/analyze|http://134\.76\.19\.184|duckdns" . \
  --exclude-dir=.git \
  --exclude=testing.sh \
  --exclude=fix.sh \
  --exclude=package-lock.json 2>/dev/null || true

say "Checking likely model weight files"
find . \
  \( -iname "*.pt" -o -iname "*.pth" -o -iname "*.onnx" -o -iname "*.engine" \) \
  -type f -printf "%s %p\n" 2>/dev/null \
| sort -nr | head -20 \
| awk '{
    size=$1;
    $1="";
    if (size>1073741824) hum=sprintf("%.2f GB", size/1073741824);
    else if (size>1048576) hum=sprintf("%.2f MB", size/1048576);
    else hum=sprintf("%.2f KB", size/1024);
    print hum " " substr($0,2);
  }'

say "Counting likely weight files"
COUNT="$(find . \( -iname "*.pt" -o -iname "*.pth" -o -iname "*.onnx" -o -iname "*.engine" \) -type f 2>/dev/null | wc -l | tr -d ' ')"
echo "Weight file count: $COUNT"

say "Making a tiny test image"
python3 - <<'PY' "$TMP_IMG"
import base64, sys
png_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9p2ZY3sAAAAASUVORK5CYII="
open(sys.argv[1], "wb").write(base64.b64decode(png_b64))
PY
ok "Tiny PNG created at $TMP_IMG"

say "Inspecting request schema for /api/predict/single"
python3 - <<'PY' "$TMP_OPENAPI"
import json, sys
doc = json.load(open(sys.argv[1]))
path = doc.get("paths", {}).get("/api/predict/single", {})
post = path.get("post", {})
rb = post.get("requestBody", {})
content = rb.get("content", {})
mp = content.get("multipart/form-data", {})
schema = mp.get("schema", {})
print(json.dumps(schema, indent=2))
PY

say "Probing predict endpoint with OPTIONS"
for base in "$LOCAL_BACKEND" "$PUBLIC_URL"; do
  c="$(curl -sS -o /dev/null -X OPTIONS -w "%{http_code}" "$base/api/predict/single" 2>/dev/null || echo 000)"
  echo "$base/api/predict/single OPTIONS -> $c"
done

say "Testing /api/classes response"
for base in "$LOCAL_BACKEND" "$PUBLIC_URL"; do
  echo "----- $base/api/classes"
  curl -sS "$base/api/classes" 2>/dev/null | head -c 500
  echo
done

echo
ok "testing completed"
echo "Public URL:      $PUBLIC_URL"
echo "Frontend local:  $LOCAL_FRONTEND"
echo "Backend local:   $LOCAL_BACKEND"
