#!/usr/bin/env bash
# deploy.sh — Run on the VM to get the app up and running.
# Usage: bash deploy.sh [domain_or_ip]
set -euo pipefail

SITE="${1:-:80}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR=""

echo "==> Installing Docker (if missing)..."
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER"
  echo "Docker installed. You may need to log out and back in, then re-run this script."
  exit 0
fi

echo "==> Resolving repository path..."
if [ -f "$SCRIPT_DIR/docker-compose.yml" ] && [ -d "$SCRIPT_DIR/backend" ]; then
  REPO_DIR="$SCRIPT_DIR"
elif [ -f "$PWD/docker-compose.yml" ] && [ -d "$PWD/backend" ]; then
  REPO_DIR="$PWD"
elif [ -d "$PWD/layout" ] && [ -f "$PWD/layout/docker-compose.yml" ] && [ -d "$PWD/layout/backend" ]; then
  REPO_DIR="$PWD/layout"
else
  echo "==> Cloning repo..."
  git clone https://github.com/emanuskript/layout.git "$PWD/layout"
  REPO_DIR="$PWD/layout"
fi

cd "$REPO_DIR"

echo "==> Checking for model weights..."
if [ ! -f backend/models/best_catmus.pt ]; then
  echo ""
  echo "!! Model weights not found in backend/models/"
  echo "!! Copy them from your local machine first:"
  echo "!!   scp backend/models/*.pt user@this-vm:~/layout/backend/models/"
  echo ""
  exit 1
fi

echo "==> Setting site address to: $SITE"
export SITE_ADDRESS="$SITE"

echo "==> Building and starting containers..."
docker compose up -d --build

echo ""
echo "==> Done! The app is available at:"
if [[ "$SITE" == ":80" ]]; then
  echo "    http://$(curl -s ifconfig.me)"
else
  echo "    https://$SITE"
fi
