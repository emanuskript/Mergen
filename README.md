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

Download all required model weights from OwnCloud:

https://owncloud.gwdg.de/index.php/s/PyQ2nN6aKpypKfG?path=%2FApps%2FLayout%20App%2Fmodel%20weights

Place these files in backend/models:

- best_emanuskript_segmentation.pt
- best_catmus.pt
- best_zone_detection.pt

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

You can deploy with either Docker Compose (recommended) or direct host deployment script.

### Option A: Docker Compose + Caddy

1. Ensure backend/model files are present.
2. Optionally set environment values:
   - SITE_ADDRESS (for Caddy, default :80)
   - JWT_SECRET
   - ANALYTICS_USERNAME
   - ANALYTICS_PASSWORD

Run:

```bash
docker compose up -d --build
```

This starts:

- backend service (FastAPI)
- frontend service (Next.js standalone)
- caddy (reverse proxy on ports 80/443)

### Option B: Direct host deployment (systemd + nginx)

The repository includes deploy.sh, which installs dependencies, builds frontend, provisions systemd services, and configures nginx.

Run from project root:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script expects model weights in backend/models before deployment.

## Important configuration

Backend environment variables:

- MODEL_DIR (defaults to backend/models)
- CORS_ORIGINS (comma-separated, default http://localhost:3000)
- MAX_POOL_WORKERS (default 3)
- JWT_SECRET
- ANALYTICS_USERNAME
- ANALYTICS_PASSWORD

Frontend build/runtime:

- BACKEND_URL (used by Next.js rewrite from /api/* to backend)

## Analytics authentication

Default credentials are configured in backend/app/config.py and should be changed in production:

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
