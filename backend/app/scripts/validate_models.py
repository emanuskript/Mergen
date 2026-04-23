"""CLI for validating backend model checkpoint files before deployment."""

import gc
import os
import sys
from pathlib import Path

from ultralytics import YOLO

from app.config import settings


def _format_size(num_bytes: int) -> str:
    return f"{num_bytes / (1024 * 1024):.1f} MB"


def _validate_checkpoint(model_path: str) -> None:
    model = YOLO(model_path)
    # Touch the wrapped model so corrupt checkpoints fail during validation,
    # not on the first production request.
    _ = model.model
    del model
    gc.collect()


def main() -> int:
    print(f"Validating model checkpoints in {settings.model_dir}")
    failures: list[str] = []

    for model_name, model_path in settings.required_model_paths.items():
        path = Path(model_path)
        if not path.is_file():
            failures.append(f"{model_name}: missing file at {model_path}")
            print(f"✗ {model_name}: missing file at {model_path}", file=sys.stderr)
            continue

        size_label = _format_size(path.stat().st_size)
        try:
            _validate_checkpoint(model_path)
            print(f"✓ {model_name}: {model_path} ({size_label})")
        except Exception as exc:
            failures.append(f"{model_name}: {exc}")
            print(
                f"✗ {model_name}: {model_path} ({size_label})",
                file=sys.stderr,
            )
            print(f"  {exc}", file=sys.stderr)

    if failures:
        print(
            "\nOne or more model checkpoints are invalid. "
            "Re-copy the affected .pt file(s) to backend/models and rerun deployment.",
            file=sys.stderr,
        )
        return 1

    print("All model checkpoints loaded successfully.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
