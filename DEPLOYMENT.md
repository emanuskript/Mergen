# Mergen production deployment

Mergen is a stateful inference service, not a static site. Production consists
of a Next.js frontend, one FastAPI/Uvicorn API process, three PyTorch/YOLO model
checkpoints, persistent task/analytics storage, and a TLS reverse proxy.

## Supported target and capacity

- Ubuntu 22.04 or 24.04, x86-64.
- Docker Engine with Compose v2 for the recommended path, or Python 3.10+,
  Node.js 20/22, systemd, and Nginx for direct-host deployment.
- Start with 4 CPU cores, 8 GiB RAM, and 20 GiB free disk for CPU inference.
  The Compose limit is 4 GiB for the backend; increase it for large pages or
  more workers. GPU acceleration is not configured by the supplied files.
- Public DNS and inbound TCP 80/443. Do not expose ports 3000 or 8000.

## Required model files

Download the weights from the folder linked in `README.md`, then place exactly
these files in `backend/models/`:

```text
best_emanuskript_segmentation.pt
best_catmus.pt
best_zone_detection.pt
```

Record checksums in the operator's release notes after download:

```bash
sha256sum backend/models/*.pt
```

The repository intentionally does not contain credentials or scrape the
interactive OwnCloud page. For automated provisioning only, set
`MODEL_WEIGHTS_BASE_URL` to a protected direct-download base that serves the
three exact filenames. Never commit that URL if it contains a token.

## Recommended: Docker Compose and Caddy

From a clean checkout of the intended commit:

```bash
cp .env.example .env
openssl rand -hex 32
openssl rand -base64 24
chmod 600 .env
```

Put those generated values in `JWT_SECRET` and `ANALYTICS_PASSWORD`; set
`CORS_ORIGINS=https://mergen.example.org` and
`SITE_ADDRESS=mergen.example.org`. Do not quote values in `.env`.

Preflight and start:

```bash
test -s backend/models/best_emanuskript_segmentation.pt
test -s backend/models/best_catmus.pt
test -s backend/models/best_zone_detection.pt
docker compose --env-file .env config
docker compose --env-file .env build --pull
docker compose --env-file .env up -d
docker compose ps
docker compose logs --tail=100 backend frontend caddy
```

Caddy obtains and renews certificates when `SITE_ADDRESS` is a resolvable DNS
name and 80/443 reach the host. With `:80` or an IP it serves HTTP only.

Verify through the public edge:

```bash
curl -fsS https://mergen.example.org/api/health
curl -fsS https://mergen.example.org/api/classes >/dev/null
curl -fsSI https://mergen.example.org/analyze
```

Also submit one representative manuscript page in the UI. Health only proves
that the process started; an actual prediction proves that all three
checkpoints can be loaded and used.

### Persistence and backup

`backend-data` contains temporary task files and `analytics.db`; `caddy-data`
contains certificate state. Back up at least the SQLite database and `.env`:

```bash
docker compose exec -T backend python -c \
  'import sqlite3; src=sqlite3.connect("/app/data/analytics.db"); dst=sqlite3.connect("/tmp/analytics-backup.db"); src.backup(dst); dst.close()'
docker compose cp backend:/tmp/analytics-backup.db ./analytics-backup.db
```

Tasks expire and are cleaned automatically, so they are not durable user
storage. Test database restore separately before relying on a backup process.

### Update and rollback

Never deploy from a moving working tree. Record `git rev-parse HEAD`, pull the
reviewed commit, rebuild, and re-run the prediction smoke test. To roll back,
checkout the previously recorded commit and rebuild with the same model files
and `.env`. Named volumes remain intact.

## Alternative: direct host deployment

Copy the model files before running the script. The script installs OS/Python
dependencies, builds the standalone frontend, creates unprivileged systemd
services, stores secrets in `/etc/layout/backend.env` with mode `0600`, writes
runtime data under `/var/lib/layout`, configures only its Nginx site, and runs a
real prediction smoke test.

```bash
APP_HOST=mergen.example.org \
PUBLIC_URL=https://mergen.example.org \
BACKEND_MAX_POOL_WORKERS=1 \
./deploy.sh
```

The script does not obtain a certificate or change firewall rules. Configure
TLS in Nginx or an upstream proxy before treating the deployment as public.
If another service already owns the web ports, the script stops rather than
disabling it.

Useful operations:

```bash
sudo systemctl status layout-backend layout-frontend nginx
sudo journalctl -u layout-backend -n 200 --no-pager
sudo journalctl -u layout-frontend -n 200 --no-pager
sudo nginx -t
```

## Enforced safeguards

- Production refuses repository JWT/password defaults and wildcard CORS.
- Uploads stream to disk and have a byte limit.
- ZIP batches have entry and expanded-size limits and reject traversal and
  symbolic links.
- Expired and orphaned task directories are removed.
- Containers and services are unprivileged, with reduced capabilities and
  read-only application filesystems where supported.
- No model file, secret, unrelated web configuration, firewall rule, Docker
  cache, or unrelated service is silently removed.

Review the defaults in `.env.example` against real traffic. In particular,
large batches can consume substantial CPU, RAM, and temporary disk even within
the configured archive limits.
