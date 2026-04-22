import logging
import multiprocessing as mp
import os

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.config import settings
from app.routers import analytics, classes, download, health, predict
from app.services.inference import init_model_pool, shutdown_model_pool

logger = logging.getLogger(__name__)


def _is_dir_writable(path: str) -> bool:
    try:
        os.makedirs(path, exist_ok=True)
        probe = os.path.join(path, ".write_probe")
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
        return True
    except OSError:
        logger.exception("Directory is not writable: %s", path)
        return False


def _log_startup_checks() -> None:
    logger.info("Startup diagnostics: cwd=%s", os.getcwd())
    logger.info("Resolved backend root: %s", settings.backend_root)
    logger.info("Resolved model directory: %s", settings.model_dir)

    model_dir_exists = os.path.isdir(settings.model_dir)
    logger.info("Model directory exists: %s", model_dir_exists)

    for name, model_path in settings.required_model_paths.items():
        logger.info(
            "Model file [%s]: path=%s exists=%s",
            name,
            model_path,
            os.path.isfile(model_path),
        )

    task_dir_exists = os.path.isdir(settings.task_base_dir)
    task_dir_writable = _is_dir_writable(settings.task_base_dir)
    logger.info(
        "Task directory: path=%s exists=%s writable=%s",
        settings.task_base_dir,
        task_dir_exists,
        task_dir_writable,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize model pool on startup, clean up on shutdown."""
    try:
        mp.set_start_method("spawn", force=True)
    except RuntimeError:
        pass

    _log_startup_checks()
    init_model_pool()
    yield
    shutdown_model_pool()


app = FastAPI(
    title="Manuscript Layout Analysis API",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["Content-Disposition"],
)

app.include_router(health.router, prefix="/api")
app.include_router(classes.router, prefix="/api")
app.include_router(predict.router, prefix="/api")
app.include_router(download.router, prefix="/api")
app.include_router(analytics.router, prefix="/api")