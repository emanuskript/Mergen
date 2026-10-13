import os
import stat
import time
import zipfile

import pytest

from app.config import Settings, settings
from app.routers.predict import _safe_extract_zip
from app.services import file_manager


def _write_zip(path, entries):
    with zipfile.ZipFile(path, "w") as archive:
        for name, content in entries:
            archive.writestr(name, content)


def test_safe_extract_zip_accepts_regular_files(tmp_path, monkeypatch):
    archive_path = tmp_path / "batch.zip"
    output = tmp_path / "out"
    output.mkdir()
    _write_zip(archive_path, [("folder/page.jpg", b"image")])
    monkeypatch.setattr(settings, "max_batch_entries", 10)
    monkeypatch.setattr(settings, "max_batch_uncompressed_bytes", 1024)

    _safe_extract_zip(str(archive_path), str(output))

    assert (output / "folder" / "page.jpg").read_bytes() == b"image"


def test_safe_extract_zip_rejects_path_traversal(tmp_path):
    archive_path = tmp_path / "batch.zip"
    output = tmp_path / "out"
    output.mkdir()
    _write_zip(archive_path, [("../escape.jpg", b"image")])

    with pytest.raises(ValueError, match="Unsafe ZIP entry"):
        _safe_extract_zip(str(archive_path), str(output))

    assert not (tmp_path / "escape.jpg").exists()


def test_safe_extract_zip_rejects_symlinks(tmp_path):
    archive_path = tmp_path / "batch.zip"
    output = tmp_path / "out"
    output.mkdir()
    with zipfile.ZipFile(archive_path, "w") as archive:
        entry = zipfile.ZipInfo("link")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(entry, "target")

    with pytest.raises(ValueError, match="ZIP links are not supported"):
        _safe_extract_zip(str(archive_path), str(output))


def test_cleanup_removes_orphaned_task_directories(tmp_path, monkeypatch):
    orphan = tmp_path / "orphan"
    orphan.mkdir()
    old = time.time() - 7200
    os.utime(orphan, (old, old))

    monkeypatch.setattr(file_manager, "TASK_BASE_DIR", str(tmp_path))
    monkeypatch.setattr(settings, "task_ttl_minutes", 60)
    file_manager.cleanup_expired_tasks()

    assert not orphan.exists()


def test_production_rejects_weak_or_wildcard_configuration():
    production = Settings(
        app_env="production",
        cors_origins="*",
        jwt_secret="short",
        analytics_password="short",
    )

    with pytest.raises(RuntimeError, match="cors_origins"):
        production.validate_production_security()


def test_production_accepts_explicit_origin_and_strong_secrets():
    production = Settings(
        app_env="production",
        cors_origins="https://mergen.example.org",
        jwt_secret="a" * 64,
        analytics_username="operator",
        analytics_password="a-unique-password-with-entropy",
    )

    production.validate_production_security()
