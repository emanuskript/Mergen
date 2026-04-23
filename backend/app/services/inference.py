"""Model pool management and parallel YOLO inference."""

import logging
import os
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path
from typing import Dict

from app.config import settings
from app.core.constants import MODEL_CLASSES

logger = logging.getLogger(__name__)

# Per-process model cache
_worker_models: dict = {}
_model_pool: ProcessPoolExecutor | None = None


def _worker_init():
    """Initialize worker process; models are loaded lazily on first use."""
    global _worker_models
    _worker_models = {}


def _run_single_model(args: tuple) -> tuple[str, str]:
    """Run a single YOLO model prediction in a worker process."""
    global _worker_models
    model_name, model_path, image_path, output_dir, classes, confidence, iou = args

    if not os.path.isfile(model_path):
        raise FileNotFoundError(f"Model file not found for {model_name}: {model_path}")

    if model_name not in _worker_models:
        from ultralytics import YOLO

        try:
            _worker_models[model_name] = YOLO(model_path)
        except Exception as exc:
            raise RuntimeError(
                f"Failed to load model checkpoint at {model_path}. "
                "The file may be corrupted or incomplete; re-copy the .pt file to the VM."
            ) from exc

    model = _worker_models[model_name]

    model_dir = os.path.join(output_dir, model_name)
    os.makedirs(model_dir, exist_ok=True)

    predict_kwargs = {
        "device": "cpu",
        "conf": confidence,
        "iou": iou,
        "augment": False,
        "stream": False,
    }
    if classes is not None:
        predict_kwargs["classes"] = classes

    results = model.predict(image_path, **predict_kwargs)
    if not results:
        raise RuntimeError(f"{model_name} returned no prediction results")

    image_id = Path(image_path).stem
    json_path = os.path.join(model_dir, f"{image_id}.json")
    with open(json_path, "w") as f:
        f.write(results[0].to_json())

    return model_name, model_dir


def init_model_pool():
    """Create the shared ProcessPoolExecutor. Called once at app startup."""
    global _model_pool
    if _model_pool is None:
        _model_pool = ProcessPoolExecutor(
            max_workers=settings.max_pool_workers,
            initializer=_worker_init,
        )
        logger.info("Model worker pool initialized.")


def shutdown_model_pool():
    """Shut down the pool. Called at app shutdown."""
    global _model_pool
    if _model_pool is not None:
        _model_pool.shutdown(wait=False)
        _model_pool = None


def _validate_model_files() -> None:
    missing = [
        f"{name}: {path}"
        for name, path in settings.required_model_paths.items()
        if not os.path.isfile(path)
    ]
    if missing:
        raise FileNotFoundError(
            "Missing model weight file(s). "
            + "Expected files at: "
            + "; ".join(missing)
        )


def run_models_parallel(
    image_path: str,
    output_dir: str,
    confidence: float = 0.25,
    iou: float = 0.3,
) -> Dict[str, str]:
    """Run all 3 YOLO models in parallel using the pre-initialized pool."""
    global _model_pool
    if _model_pool is None:
        init_model_pool()

    if not os.path.isfile(image_path):
        raise FileNotFoundError(f"Input image not found: {image_path}")

    _validate_model_files()
    os.makedirs(output_dir, exist_ok=True)

    model_args = [
        (
            "emanuskript",
            settings.emanuskript_model_path,
            image_path,
            output_dir,
            MODEL_CLASSES["emanuskript"],
            confidence,
            iou,
        ),
        (
            "catmus",
            settings.catmus_model_path,
            image_path,
            output_dir,
            MODEL_CLASSES["catmus"],
            confidence,
            iou,
        ),
        (
            "zone",
            settings.zone_model_path,
            image_path,
            output_dir,
            MODEL_CLASSES["zone"],
            confidence,
            iou,
        ),
    ]

    futures = {_model_pool.submit(_run_single_model, args): args[0] for args in model_args}

    results: Dict[str, str] = {}
    for future in as_completed(futures):
        model_name = futures[future]
        try:
            name, dir_path = future.result(timeout=300)
            results[name] = dir_path
        except Exception as exc:
            logger.exception(
                "Model inference failed: model=%s image=%s",
                model_name,
                image_path,
            )
            raise RuntimeError(f"{model_name} inference failed: {exc}") from exc

    return results
