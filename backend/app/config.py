import os
from pathlib import Path
from urllib.parse import urlsplit

from pydantic_settings import BaseSettings


def _resolve_backend_root() -> Path:
    """Resolve the backend root even if modules are loaded from __pycache__."""
    module_dir = Path(__file__).resolve().parent

    # When running from sourceless bytecode, __file__ can be:
    # backend/app/__pycache__/config.cpython-311.pyc
    if module_dir.name == "__pycache__":
        module_dir = module_dir.parent

    if module_dir.name == "app":
        return module_dir.parent
    if module_dir.name == "backend":
        return module_dir

    return module_dir.parent


BACKEND_ROOT = _resolve_backend_root()


class Settings(BaseSettings):
    # Runtime mode
    app_env: str = "development"

    # CORS
    cors_origins: str = "http://localhost:3000,http://127.0.0.1:3000"

    # Paths
    backend_root: str = str(BACKEND_ROOT)
    model_dir: str = str(BACKEND_ROOT / "models")
    task_base_dir: str = str(BACKEND_ROOT / ".tasks")

    # Analytics
    analytics_db_path: str = str(BACKEND_ROOT / "analytics.db")
    analytics_username: str = "admin"
    analytics_password: str = "layout2024"

    # JWT
    jwt_secret: str = "development-only-change-this-secret"
    jwt_expiry_minutes: int = 60

    # Processing
    max_pool_workers: int = 3
    task_ttl_minutes: int = 60
    task_cleanup_interval_seconds: int = 300
    max_upload_bytes: int = 200 * 1024 * 1024
    max_batch_entries: int = 1000
    max_batch_uncompressed_bytes: int = 1024 * 1024 * 1024

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def emanuskript_model_path(self) -> str:
        return os.path.join(self.model_dir, "best_emanuskript_segmentation.pt")

    @property
    def catmus_model_path(self) -> str:
        return os.path.join(self.model_dir, "best_catmus.pt")

    @property
    def zone_model_path(self) -> str:
        return os.path.join(self.model_dir, "best_zone_detection.pt")

    @property
    def required_model_paths(self) -> dict[str, str]:
        return {
            "emanuskript": self.emanuskript_model_path,
            "catmus": self.catmus_model_path,
            "zone": self.zone_model_path,
        }

    def validate_production_security(self) -> None:
        """Reject repository defaults when running a public deployment."""
        if self.app_env.lower() != "production":
            return

        weak_values = {
            "jwt_secret": {
                "development-only-change-this-secret",
                "change-this-to-a-random-string",
                "change-me-in-production",
                "",
            },
            "analytics_password": {"layout2024", "admin", ""},
        }
        failures = [
            name
            for name, forbidden in weak_values.items()
            if str(getattr(self, name, "")) in forbidden
        ]
        if len(self.jwt_secret) < 32:
            failures.append("jwt_secret (must be at least 32 characters)")
        if len(self.analytics_password) < 16:
            failures.append("analytics_password (must be at least 16 characters)")
        if not self.analytics_username.strip():
            failures.append("analytics_username")

        origins = self.cors_origins_list
        if not origins or "*" in origins:
            failures.append("cors_origins (explicit origins required)")
        else:
            for origin in origins:
                parsed = urlsplit(origin)
                if (
                    parsed.scheme not in {"http", "https"}
                    or not parsed.netloc
                    or parsed.username
                    or parsed.password
                    or parsed.path not in {"", "/"}
                    or parsed.query
                    or parsed.fragment
                ):
                    failures.append(f"cors_origins (invalid origin: {origin})")
                    break
        if failures:
            raise RuntimeError(
                "Refusing to start production with insecure defaults: "
                + ", ".join(failures)
            )

    model_config = {"env_file": ".env", "extra": "ignore"}


settings = Settings()
