#!/usr/bin/env python3

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os
import re
import shutil
import tempfile

try:
    from .env_helper import parse_env, q
except ImportError:  # pragma: no cover - direct CLI execution
    from env_helper import parse_env, q


COMPOSE_PROJECT_PATTERN = re.compile(r"^[a-z0-9][a-z0-9_-]*$")
IMAGE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/@:-]*$")
ADOPTED_STATE_KEYS = ("COMPOSE_PROJECT_NAME", "POSTGRES_IMAGE", "REDIS_IMAGE")


@dataclass(frozen=True)
class CompletedMigrationRuntimeIdentity:
    adopted: bool
    override_present: bool
    compose_project: str
    postgres_image: str
    redis_image: str
    bot_image: str
    backup_dir: Path | None


def _unquote_yaml_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        value = value[1:-1]
    return value


def _parse_migration_override(path: Path) -> tuple[str, dict[str, str]]:
    compose_project = ""
    current_service = ""
    images: dict[str, str] = {}

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if raw_line.startswith("name:"):
            compose_project = _unquote_yaml_scalar(raw_line.split(":", 1)[1])
            continue
        service_match = re.fullmatch(r"  ([A-Za-z0-9_-]+):\s*", raw_line)
        if service_match:
            current_service = service_match.group(1)
            continue
        image_match = re.fullmatch(r"    image:\s*(.+?)\s*", raw_line)
        if image_match and current_service:
            images[current_service] = _unquote_yaml_scalar(image_match.group(1))

    if compose_project and not COMPOSE_PROJECT_PATTERN.fullmatch(compose_project):
        raise ValueError("migration override contains unsafe Compose project identity")
    for service in ("postgres", "redis", "bot"):
        image = images.get(service, "")
        if not IMAGE_PATTERN.fullmatch(image):
            raise ValueError(f"migration override contains unsafe {service} image identity")
    return compose_project, images


def _write_adopted_state(path: Path, updates: dict[str, str]) -> None:
    original_lines = path.read_text(encoding="utf-8").splitlines()
    remaining = dict(updates)
    output: list[str] = []

    for line in original_lines:
        key = line.split("=", 1)[0].strip() if "=" in line else ""
        if key in remaining:
            output.append(f"{key}={q(remaining.pop(key))}")
        else:
            output.append(line)
    for key in ADOPTED_STATE_KEYS:
        if key in remaining:
            output.append(f"{key}={q(remaining.pop(key))}")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".install.state.runtime-identity.",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write("\n".join(output) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.chmod(0o600)
        os.replace(temporary, path)
        try:
            directory_descriptor = os.open(path.parent, os.O_RDONLY)
        except OSError:
            if os.name != "nt":
                raise
        else:
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
    finally:
        temporary.unlink(missing_ok=True)


def inspect_completed_migration_runtime_identity(
    project_root: Path,
) -> CompletedMigrationRuntimeIdentity:
    project_root = project_root.resolve()
    state_dir = project_root / "state"
    state_file = state_dir / "install.state"
    completed_marker = state_dir / "migration.completed"
    resource_marker = project_root / ".migration-resources-created"
    override_file = state_dir / "migration-image.override.yml"

    for required in (state_file, completed_marker, resource_marker):
        if not required.is_file() or required.is_symlink():
            raise ValueError(f"completed migration runtime file is missing: {required}")
    if override_file.is_symlink():
        raise ValueError("completed migration image override is unsafe")

    resources = parse_env(resource_marker)
    recorded_project = resources.get("compose_project", "")
    if not COMPOSE_PROJECT_PATTERN.fullmatch(recorded_project):
        raise ValueError("migration resource marker contains unsafe Compose project")

    state = parse_env(state_file)
    existing_project = state.get("COMPOSE_PROJECT_NAME", "")
    if override_file.is_file():
        override_project, images = _parse_migration_override(override_file)
        if override_project and recorded_project != override_project:
            raise ValueError("migration Compose project identities do not match")
        if existing_project and existing_project != recorded_project:
            raise ValueError(
                "install.state conflicts with completed migration Compose project"
            )
        override_present = True
        bot_image = images["bot"]
    else:
        if existing_project != recorded_project:
            raise ValueError(
                "transitioned install.state conflicts with migration Compose project"
            )
        images = {
            "postgres": state.get("POSTGRES_IMAGE", ""),
            "redis": state.get("REDIS_IMAGE", ""),
        }
        for service, image in images.items():
            if not IMAGE_PATTERN.fullmatch(image):
                raise ValueError(
                    f"transitioned install.state has unsafe {service} image identity"
                )
        override_present = False
        bot_image = ""

    updates = {
        "COMPOSE_PROJECT_NAME": recorded_project,
        "POSTGRES_IMAGE": images["postgres"],
        "REDIS_IMAGE": images["redis"],
    }
    already_adopted = all(state.get(key) == value for key, value in updates.items())
    return CompletedMigrationRuntimeIdentity(
        adopted=already_adopted,
        override_present=override_present,
        compose_project=recorded_project,
        postgres_image=images["postgres"],
        redis_image=images["redis"],
        bot_image=bot_image,
        backup_dir=None,
    )


def adopt_completed_migration_runtime_identity(
    project_root: Path,
) -> CompletedMigrationRuntimeIdentity:
    project_root = project_root.resolve()
    state_dir = project_root / "state"
    state_file = state_dir / "install.state"
    completed_marker = state_dir / "migration.completed"
    resource_marker = project_root / ".migration-resources-created"
    override_file = state_dir / "migration-image.override.yml"
    inspected = inspect_completed_migration_runtime_identity(project_root)
    if not inspected.override_present:
        return CompletedMigrationRuntimeIdentity(
            adopted=False,
            override_present=False,
            compose_project=inspected.compose_project,
            postgres_image=inspected.postgres_image,
            redis_image=inspected.redis_image,
            bot_image=inspected.bot_image,
            backup_dir=None,
        )
    state = parse_env(state_file)
    updates = {
        "COMPOSE_PROJECT_NAME": inspected.compose_project,
        "POSTGRES_IMAGE": inspected.postgres_image,
        "REDIS_IMAGE": inspected.redis_image,
    }
    already_adopted = all(state.get(key) == value for key, value in updates.items())
    if already_adopted:
        return CompletedMigrationRuntimeIdentity(
            adopted=False,
            override_present=True,
            compose_project=inspected.compose_project,
            postgres_image=inspected.postgres_image,
            redis_image=inspected.redis_image,
            bot_image=inspected.bot_image,
            backup_dir=None,
        )

    backup_root = state_dir / "migration-backups"
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_dir = Path(tempfile.mkdtemp(prefix="runtime-identity-", dir=backup_root))
    backup_dir.chmod(0o700)
    for source in (state_file, completed_marker, resource_marker, override_file):
        target = backup_dir / source.name
        shutil.copy2(source, target)
        target.chmod(0o600)

    _write_adopted_state(state_file, updates)
    return CompletedMigrationRuntimeIdentity(
        adopted=True,
        override_present=True,
        compose_project=inspected.compose_project,
        postgres_image=inspected.postgres_image,
        redis_image=inspected.redis_image,
        bot_image=inspected.bot_image,
        backup_dir=backup_dir,
    )


def _print_shell_assignments(result: CompletedMigrationRuntimeIdentity) -> None:
    values = {
        "COMPOSE_PROJECT_NAME": result.compose_project,
        "POSTGRES_IMAGE": result.postgres_image,
        "REDIS_IMAGE": result.redis_image,
        "MIGRATION_BOT_IMAGE": result.bot_image,
        "MIGRATION_IMAGE_OVERRIDE_PRESENT": "true" if result.override_present else "false",
        "MIGRATION_RUNTIME_IDENTITY_ADOPTED": "true" if result.adopted else "false",
        "MIGRATION_RUNTIME_IDENTITY_BACKUP": str(result.backup_dir or ""),
    }
    for key, value in values.items():
        print(f"{key}={q(value)}")


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[0] not in {"inspect", "adopt"}:
        print(
            "usage: migration_runtime.py <inspect|adopt> <project-root>",
            file=os.sys.stderr,
        )
        return 2

    try:
        if argv[0] == "inspect":
            result = inspect_completed_migration_runtime_identity(Path(argv[1]))
        else:
            result = adopt_completed_migration_runtime_identity(Path(argv[1]))
    except (OSError, ValueError) as error:
        print(f"cannot adopt completed migration runtime identity: {error}", file=os.sys.stderr)
        return 1
    _print_shell_assignments(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(os.sys.argv[1:]))
