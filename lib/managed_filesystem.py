from __future__ import annotations

import hashlib
import os
from pathlib import Path
import secrets
import shutil


def _secure_private_path(path: Path) -> None:
    if path.is_dir():
        os.chmod(path, 0o700)
        for child in path.rglob("*"):
            os.chmod(child, 0o700 if child.is_dir() else 0o600)
    elif path.is_file():
        os.chmod(path, 0o600)


def _secure_restored_state(project_root: Path) -> None:
    state_dir = project_root / "state"
    os.chmod(state_dir, 0o700)
    backups_dir = state_dir / "backups"
    if backups_dir.is_dir():
        os.chmod(backups_dir, 0o700)
    for name in (
        "install.state",
        "bot.env",
        "bot.override.env",
        "cabinet.env",
    ):
        path = state_dir / name
        if path.is_file():
            os.chmod(path, 0o600)


def _replace_tree(source: Path, destination: Path) -> None:
    candidate = destination.with_name(
        f".{destination.name}.recovery-{secrets.token_hex(8)}"
    )
    if candidate.exists():
        shutil.rmtree(candidate)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.is_dir():
        shutil.copytree(source, candidate)
    else:
        candidate.mkdir(parents=True)
    if destination.exists():
        shutil.rmtree(destination)
    os.replace(candidate, destination)


def _restore_project_tree(source_project: Path, project_root: Path) -> None:
    source_state = source_project / "state"
    destination_state = project_root / "state"
    preserved_backups = None
    if (destination_state / "backups").is_dir():
        preserved_backups = project_root / f".recovery-backups-{secrets.token_hex(8)}"
        os.replace(destination_state / "backups", preserved_backups)

    project_root.mkdir(parents=True, exist_ok=True)
    try:
        _replace_tree(source_state, destination_state)
    finally:
        if preserved_backups is not None and preserved_backups.exists():
            destination_state.mkdir(parents=True, exist_ok=True)
            os.replace(preserved_backups, destination_state / "backups")

    runtime_roots = (
        ("bot/data", project_root / "runtime/bot/data"),
        ("bot/logs", project_root / "runtime/bot/logs"),
        ("bot/uploads", project_root / "runtime/bot/uploads"),
        ("cabinet-dist", project_root / "runtime/cabinet-dist"),
    )
    for relative_source, destination in runtime_roots:
        _replace_tree(source_project / "runtime" / relative_source, destination)
    _secure_restored_state(project_root)


def _invalidate_transient_state(project_root: Path) -> None:
    state_dir = project_root / "state"
    for hash_file in state_dir.glob("applied-*.sha256"):
        hash_file.unlink()
    for relative_path in (
        "draft",
        "migration.pending",
        "migration.completed",
        "migration-image.override.yml",
        "migration-export.in-progress",
    ):
        path = state_dir / relative_path
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    for name in (".migration-import-in-progress", ".migration-resources-created"):
        marker = project_root / name
        if marker.exists():
            marker.unlink()


def _capture_rollback_transients(project_root: Path, destination: Path) -> None:
    state_dir = project_root / "state"
    for relative_path in (
        "draft",
        "migration.pending",
        "migration.completed",
        "migration-image.override.yml",
        "migration-export.in-progress",
    ):
        source = state_dir / relative_path
        target = destination / "state" / relative_path
        if source.is_dir():
            shutil.copytree(source, target)
        elif source.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    for name in (".migration-import-in-progress", ".migration-resources-created"):
        source = project_root / name
        if source.is_file():
            target = destination / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


def _restore_rollback_transients(
    source: Path,
    project_root: Path,
    *,
    runtime_override_only: bool,
) -> None:
    relative_paths = (
        ("migration-image.override.yml",)
        if runtime_override_only
        else (
            "draft",
            "migration.pending",
            "migration.completed",
            "migration-export.in-progress",
        )
    )
    for relative_path in relative_paths:
        saved = source / "state" / relative_path
        target = project_root / "state" / relative_path
        if saved.is_dir():
            shutil.copytree(saved, target)
        elif saved.is_file():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(saved, target)
        _secure_private_path(target)
    if runtime_override_only:
        return
    for name in (".migration-import-in-progress", ".migration-resources-created"):
        saved = source / name
        if saved.is_file():
            target = project_root / name
            shutil.copy2(saved, target)
            _secure_private_path(target)


def _mark_applied_state(project_root: Path) -> None:
    state_dir = project_root / "state"
    tracked_files = {
        "bot-env": state_dir / "bot.env",
        "bot-override-env": state_dir / "bot.override.env",
        "cabinet-env": state_dir / "cabinet.env",
        "compose": state_dir / "docker-compose.yml",
        "caddy-candidate": state_dir / "bot-stack.caddy",
    }
    for label, source in tracked_files.items():
        if not source.is_file():
            continue
        destination = state_dir / f"applied-{label}.sha256"
        temporary = state_dir / f".{destination.name}.{secrets.token_hex(6)}"
        temporary.write_text(
            hashlib.sha256(source.read_bytes()).hexdigest() + "\n",
            encoding="utf-8",
        )
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
