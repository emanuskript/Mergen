import os
from pathlib import Path

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
    jwt_secret: str = "change-this-to-a-random-string"
    jwt_expiry_minutes: int = 60

    # Processing
    max_pool_workers: int = 3
    task_ttl_minutes: int = 60

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

    model_config = {"env_file": ".env", "extra": "ignore"}


settings = Settings()
