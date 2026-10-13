# Mergen

Mergen is a full-stack manuscript layout analysis app that runs three YOLO models in parallel, combines results into a unified annotation set, and provides interactive review and export tools.

## What the app does

- Detects manuscript layout/content elements with 3 models: emanuskript, catmus, zone.
- Supports single-image and batch ZIP workflows.
- Returns unified COCO annotations with class filtering.
- Produces annotated image previews and aggregate statistics.
- Exports COCO JSON, annotated images, ZIP bundles, and PAGE XML.
- Includes authenticated analytics endpoints for usage reporting.

## Tech stack

- Frontend: Next.js 16 (App Router), React 19, TypeScript.
- Backend: FastAPI + Uvicorn.
- Inference: Ultralytics YOLO models executed in multiprocessing pool.
- Reverse proxy (container deployment): Caddy.
- Alternative host deployment: systemd + nginx via deploy.sh.

## Model weights

The project publishes the required model weights from this OwnCloud folder:

https://owncloud.gwdg.de/index.php/apps/files/?dir=/Mergen%20Weights&fileid=4279218283

Place these files in backend/models:

- best_emanuskript_segmentation.pt
- best_catmus.pt
- best_zone_detection.pt

The folder page is not a stable direct-download endpoint, so deployments do not
scrape it or embed credentials. Download the three files manually and copy them
to `backend/models/`. An operator may instead supply an authenticated direct
download base through `MODEL_WEIGHTS_BASE_URL`; the URL must expose each exact
filename at its root. The deployment validates the checkpoints before starting
the service and never silently overwrites an invalid operator-supplied file.

## Supported classes

The backend exposes 22 final COCO classes, including:

- Layout: Border, Table, Diagram, Column
- Script: Main script black/coloured, Variant script black/coloured
- Initials: Historiated, Inhabited, Zoo - Anthropomorphic, Embellished, Plain initial variants
- Navigation/content: Page Number, Quire Mark, Running header, Catchword, Gloss, Illustrations
- Music: Music

## API overview

Base prefix: /api

- GET /health
- GET /classes
- POST /predict/single
- POST /predict/batch
- GET /predict/batch/{task_id}/progress (SSE)
- GET /predict/batch/{task_id}/results
- GET /download/{task_id}/coco_json
- GET /download/{task_id}/annotated_image
- GET /download/{task_id}/annotated/{index}
- GET /download/{task_id}/results_zip
- GET /download/{task_id}/page_xml
- POST /analytics/login
- GET /analytics/data (JWT required)

## Local development

Prerequisites:

- Python 3.11+
- Node.js 20+
- npm

### 1) Clone

```bash
git clone https://github.com/emanuskript/Mergen.git
cd Mergen
```

### 2) Prepare model files

Create backend/models and copy the three .pt files listed above.

### 3) Run backend

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip setuptools wheel
pip install --index-url https://download.pytorch.org/whl/cpu torch torchvision
pip install -e backend

cd backend
MODEL_DIR="$(pwd)/models" CORS_ORIGINS="http://localhost:3000" uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1
```

Backend URL: http://localhost:8000
Docs: http://localhost:8000/docs

### 4) Run frontend

In a new terminal:

```bash
cd frontend
npm install
BACKEND_URL=http://localhost:8000 npm run dev -- --hostname 0.0.0.0 --port 3000
```

Frontend URL: http://localhost:3000/analyze

## Deployment

See [DEPLOYMENT.md](DEPLOYMENT.md) for server sizing, exact commands, secret and
model provisioning, persistence, TLS, backup, rollback, and verification.

### Option A: Docker Compose + Caddy

1. Put all three validated model files in `backend/models/`.
2. Copy `.env.example` to `.env`, set the public origin/domain, and replace all
   secret placeholders.

Run:

```bash
docker compose --env-file .env config
docker compose --env-file .env up -d --build
```

This starts:

- backend service (FastAPI)
- frontend service (Next.js standalone)
- caddy (reverse proxy on ports 80/443)

### Option B: Direct host deployment (systemd + nginx)

The repository includes deploy.sh, which installs dependencies, builds frontend, provisions systemd services, and configures nginx.

Run from a clean project checkout on Ubuntu 22.04/24.04:

```bash
APP_HOST=mergen.example.org \
PUBLIC_URL=https://mergen.example.org \
./deploy.sh
```

The script defaults the backend inference pool to a single worker on direct host deployments to keep low-memory CPU VMs stable. You can override that when needed, for example:

```bash
BACKEND_MAX_POOL_WORKERS=2 ./deploy.sh
```

## Important configuration

Backend environment variables:

- `APP_ENV` (`production` enables rejection of repository credentials)
- `MODEL_DIR` (defaults to `backend/models`)
- `TASK_BASE_DIR` and `ANALYTICS_DB_PATH` (must be persistent and writable)
- `CORS_ORIGINS` (comma-separated exact origins)
- MAX_POOL_WORKERS (default 3)
- `MAX_UPLOAD_BYTES`, `MAX_BATCH_ENTRIES`, and `MAX_BATCH_UNCOMPRESSED_BYTES`
- `TASK_TTL_MINUTES` and `TASK_CLEANUP_INTERVAL_SECONDS`
- JWT_SECRET
- ANALYTICS_USERNAME
- ANALYTICS_PASSWORD

Frontend build/runtime:

- INTERNAL_BACKEND_URL (used by the standalone frontend runtime when /api/* is not already proxied at the public edge)
- BACKEND_URL (legacy fallback supported by next.config.ts)

## Analytics authentication

Development defaults exist for local use only. With `APP_ENV=production`, the
backend refuses to start with the repository JWT secret or analytics password.
Generate unique production values; do not reuse these local defaults:

- username: admin
- password: layout2024

## Repository structure

```text
.
├── backend/
│   ├── app/
│   ├── models/
│   └── pyproject.toml
├── frontend/
├── docker-compose.yml
├── Caddyfile
└── deploy.sh
```

## License

Licensed under Apache 2.0. See LICENSE.
