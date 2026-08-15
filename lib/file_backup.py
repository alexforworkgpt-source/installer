from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import tarfile
import tempfile


MANIFEST_PATH = "manifest.json"
CHECKSUMS_PATH = "checksums.sha256"
ARTIFACT_TYPE = "bedolaga-file-backup"
MAX_ARCHIVE_MEMBERS = 250_000
MAX_UNCOMPRESSED_BYTES = 100 * 1024 * 1024 * 1024
MAX_CONTROL_FILE_BYTES = 32 * 1024 * 1024


class RecoveryError(ValueError):
    pass


def _compose_project_name(project_root: Path) -> str:
    slug = re.sub(r"[^a-z0-9_-]+", "-", project_root.name.lower()).strip("-_")
    slug = (slug or "stack")[:32]
    digest = hashlib.sha256(str(project_root).encode("utf-8")).hexdigest()[:8]
    return f"bedolaga-{slug}-{digest}"


@dataclass(frozen=True)
class FileBackupArtifact:
    archive: Path
    project_root: Path
    members: tuple[str, ...]
    uncompressed_size: int
    artifact_role: str


def _validate_member(member: tarfile.TarInfo) -> None:
    if "\\" in member.name:
        raise RecoveryError(f"unsafe file backup path: {member.name}")
    path = PurePosixPath(member.name)
    parts = tuple(part for part in path.parts if part not in ("", "."))
    if path.is_absolute() or ".." in path.parts or not parts:
        raise RecoveryError(f"unsafe file backup path: {member.name}")
    if member.name != PurePosixPath(*parts).as_posix():
        raise RecoveryError(f"non-canonical file backup path: {member.name}")
    if member.issym() or member.islnk() or not (member.isfile() or member.isdir()):
        raise RecoveryError(f"unsupported file backup entry: {member.name}")

    if parts[0] in {MANIFEST_PATH, CHECKSUMS_PATH} and len(parts) == 1:
        return
    if parts == ("project",) and member.isdir():
        return
    if parts[0] != "project" or len(parts) < 2:
        raise RecoveryError(f"unexpected file backup path: {member.name}")
    if parts[1] == "state":
        if len(parts) >= 3 and parts[2] == "backups":
            raise RecoveryError("file backup cannot contain nested backups")
        return
    if parts[1] != "runtime":
        raise RecoveryError(f"unexpected file backup path: {member.name}")
    if len(parts) == 2:
        return
    if parts[2] == "cabinet-dist":
        return
    if parts[2] == "bot" and len(parts) == 3 and member.isdir():
        return
    if parts[2] != "bot" or len(parts) == 3:
        raise RecoveryError(f"unexpected file backup path: {member.name}")
    if parts[3] not in {"data", "logs", "uploads"}:
        raise RecoveryError(f"unexpected file backup path: {member.name}")


def _read_member(bundle: tarfile.TarFile, name: str) -> bytes:
    member = bundle.getmember(name)
    if not member.isfile():
        raise RecoveryError(f"file backup entry is not a file: {name}")
    if member.size > MAX_CONTROL_FILE_BYTES:
        raise RecoveryError(f"file backup control entry is too large: {name}")
    extracted = bundle.extractfile(member)
    if extracted is None:
        raise RecoveryError(f"cannot read file backup entry: {name}")
    return extracted.read()


def _hash_member(bundle: tarfile.TarFile, name: str) -> str:
    member = bundle.getmember(name)
    extracted = bundle.extractfile(member)
    if extracted is None:
        raise RecoveryError(f"cannot read file backup entry: {name}")
    digest = hashlib.sha256()
    while chunk := extracted.read(1024 * 1024):
        digest.update(chunk)
    return digest.hexdigest()


def _hash_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_checksums(content: bytes) -> dict[str, str]:
    checksums: dict[str, str] = {}
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise RecoveryError("file backup checksums are not UTF-8") from error
    for line in lines:
        digest, separator, name = line.partition("  ")
        if (
            not separator
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
            or not name
            or name in checksums
        ):
            raise RecoveryError("invalid file backup checksum list")
        checksums[name] = digest
    return checksums


def _parse_state(content: bytes) -> dict[str, str]:
    try:
        lines = content.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise RecoveryError("file backup install.state is not UTF-8") from error
    state: dict[str, str] = {}
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1].replace("'\\''", "'")
        elif len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        state[key] = value
    return state


def _validate_state_paths(content: bytes, project_root: Path) -> None:
    state = _parse_state(content)
    if state.get("PROJECT_ROOT") != str(project_root):
        raise RecoveryError("file backup state belongs to another project root")

    expected_compose_project = _compose_project_name(project_root)
    expected_paths = {
        "REPOS_DIR": project_root / "repos",
        "RUNTIME_DIR": project_root / "runtime",
        "STATE_DIR": project_root / "state",
        "RELEASES_DIR": project_root / "releases",
        "BOT_REPO_DIR": project_root / "repos/bot-backend",
        "CABINET_REPO_DIR": project_root / "repos/bot-cabinet",
        "BOT_RUNTIME_DIR": project_root / "runtime/bot",
        "BOT_DATA_DIR": project_root / "runtime/bot/data",
        "BOT_LOGS_DIR": project_root / "runtime/bot/logs",
        "BOT_UPLOADS_DIR": project_root / "runtime/bot/uploads",
        "CABINET_DIST_DIR": project_root / "runtime/cabinet-dist",
        "BOT_ENV_FILE": project_root / "state/bot.env",
        "BOT_OVERRIDE_ENV_FILE": project_root / "state/bot.override.env",
        "CABINET_ENV_FILE": project_root / "state/cabinet.env",
        "COMPOSE_FILE": project_root / "state/docker-compose.yml",
        "CADDY_CANDIDATE_FILE": project_root / "state/bot-stack.caddy",
        "CADDY_SNIPPET_DIR": "/etc/caddy/conf.d",
        "CADDY_SNIPPET_FILE": f"/etc/caddy/conf.d/{expected_compose_project}.caddy",
    }
    for key, expected_path in expected_paths.items():
        if key in state and state[key] != str(expected_path):
            raise RecoveryError(f"file backup install.state has unsafe {key}")
    if state.get("COMPOSE_PROJECT_NAME", expected_compose_project) != expected_compose_project:
        raise RecoveryError("file backup install.state has unsafe COMPOSE_PROJECT_NAME")


def validate_file_backup(
    archive: Path,
    expected_project_root: Path,
) -> FileBackupArtifact:
    archive = archive.resolve()
    expected_project_root = expected_project_root.resolve()
    try:
        with tarfile.open(archive, "r|gz") as stream:
            member_count = 0
            uncompressed_size = 0
            for member in stream:
                member_count += 1
                uncompressed_size += member.size
                if member_count > MAX_ARCHIVE_MEMBERS:
                    raise RecoveryError("file backup contains too many entries")
                if uncompressed_size > MAX_UNCOMPRESSED_BYTES:
                    raise RecoveryError(
                        "file backup uncompressed size exceeds the limit"
                    )
        with tarfile.open(archive, "r:gz") as bundle:
            members = bundle.getmembers()
            names = [member.name for member in members]
            if len(names) != len(set(names)):
                raise RecoveryError("file backup contains duplicate paths")
            for member in members:
                _validate_member(member)
            if MANIFEST_PATH not in names or CHECKSUMS_PATH not in names:
                raise RecoveryError("file backup manifest or checksums are missing")

            manifest = json.loads(_read_member(bundle, MANIFEST_PATH))
            if not isinstance(manifest, dict):
                raise RecoveryError("file backup manifest must be an object")
            if manifest.get("schema_version") != 1:
                raise RecoveryError("unsupported file backup schema_version")
            if manifest.get("artifact_type") != ARTIFACT_TYPE:
                raise RecoveryError("artifact is not a supported file backup")
            artifact_role = manifest.get("artifact_role", "manual")
            if artifact_role not in {"manual", "safety"}:
                raise RecoveryError("unsupported file backup artifact_role")
            if manifest.get("contains_postgresql") is not False:
                raise RecoveryError("file backup cannot claim PostgreSQL data")
            if manifest.get("contains_redis") is not False:
                raise RecoveryError("file backup cannot claim Redis data")
            if manifest.get("project_root") != str(expected_project_root):
                raise RecoveryError("file backup belongs to another project root")

            state_path = "project/state/install.state"
            if state_path not in names:
                raise RecoveryError("file backup install.state is missing")
            _validate_state_paths(
                _read_member(bundle, state_path),
                expected_project_root,
            )

            checksums = _parse_checksums(_read_member(bundle, CHECKSUMS_PATH))
            file_names = {member.name for member in members if member.isfile()}
            expected_names = file_names - {CHECKSUMS_PATH}
            if set(checksums) != expected_names:
                raise RecoveryError("file backup checksum coverage is incomplete")
            for name, expected_digest in checksums.items():
                actual_digest = _hash_member(bundle, name)
                if not secrets.compare_digest(actual_digest, expected_digest):
                    raise RecoveryError(f"file backup checksum mismatch: {name}")
    except (OSError, tarfile.TarError, json.JSONDecodeError, KeyError) as error:
        if isinstance(error, RecoveryError):
            raise
        raise RecoveryError(f"cannot validate file backup: {error}") from error

    return FileBackupArtifact(
        archive=archive,
        project_root=expected_project_root,
        members=tuple(names),
        uncompressed_size=uncompressed_size,
        artifact_role=artifact_role,
    )


def _copy_managed_project(
    source_root: Path,
    destination_root: Path,
    *,
    include_transient_state: bool,
) -> None:
    destination_project = destination_root / "project"
    destination_project.mkdir(parents=True)
    source_state = source_root / "state"
    if not (source_state / "install.state").is_file():
        raise RecoveryError("current install.state is unavailable for safety backup")

    def ignore_state_entries(directory: str, names: list[str]) -> set[str]:
        if Path(directory) != source_state:
            return set()
        ignored = {"backups"}
        if not include_transient_state:
            ignored.update(
                {
                    "draft",
                    "migration.pending",
                    "migration.completed",
                    "migration-image.override.yml",
                    "migration-export.in-progress",
                }
            )
        ignored.update(
            name
            for name in names
            if name.startswith("applied-") and name.endswith(".sha256")
        )
        return ignored.intersection(names)

    shutil.copytree(
        source_state,
        destination_project / "state",
        ignore=ignore_state_entries,
        symlinks=True,
    )
    runtime_paths = ("bot/data", "bot/logs", "bot/uploads", "cabinet-dist")
    for relative_path in runtime_paths:
        source = source_root / "runtime" / relative_path
        if source.is_dir():
            shutil.copytree(
                source,
                destination_project / "runtime" / relative_path,
                symlinks=True,
            )


def _assert_no_managed_symlinks(project_root: Path) -> None:
    for relative_root in (
        "state",
        "runtime/bot/data",
        "runtime/bot/logs",
        "runtime/bot/uploads",
        "runtime/cabinet-dist",
    ):
        managed_root = project_root / relative_root
        current = project_root
        for part in Path(relative_root).parts:
            current /= part
            if current.is_symlink():
                raise RecoveryError(f"managed project path is a symlink: {current}")
        if not managed_root.is_dir():
            continue
        for path in managed_root.rglob("*"):
            if path.is_symlink():
                raise RecoveryError(f"managed project entry is a symlink: {path}")


def _write_file_backup_archive(
    project_root: Path,
    archive: Path,
    staging_root: Path,
    *,
    artifact_role: str,
) -> None:
    _assert_no_managed_symlinks(project_root)
    _copy_managed_project(
        project_root,
        staging_root,
        include_transient_state=artifact_role == "safety",
    )
    manifest = {
        "schema_version": 1,
        "artifact_type": ARTIFACT_TYPE,
        "artifact_role": artifact_role,
        "project_root": str(project_root),
        "created_at": datetime.now(timezone.utc).isoformat(),
        "contains_postgresql": False,
        "contains_redis": False,
    }
    (staging_root / MANIFEST_PATH).write_text(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")),
        encoding="utf-8",
    )
    staged_paths = sorted(staging_root.rglob("*"))
    if any(path.is_symlink() for path in staged_paths):
        raise RecoveryError("file backup staging contains a symlink")
    files = [path for path in staged_paths if path.is_file()]
    checksums = "".join(
        f"{_hash_path(path)}  {path.relative_to(staging_root).as_posix()}\n"
        for path in files
    )
    (staging_root / CHECKSUMS_PATH).write_text(checksums, encoding="utf-8")
    archive.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(archive, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    with tarfile.open(archive, "w:gz") as bundle:
        for path in sorted(staging_root.rglob("*")):
            bundle.add(
                path,
                arcname=path.relative_to(staging_root).as_posix(),
                recursive=False,
            )


def _create_safety_backup(project_root: Path, work_dir: Path) -> Path:
    backup_dir = project_root / "state/backups"
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    token = secrets.token_hex(6)
    final_archive = backup_dir / f"before-recovery-{token}-file-backup.tar.gz"
    temporary_archive = backup_dir / f".{final_archive.name}.tmp"
    staging_root = work_dir / "safety-staging"
    try:
        _write_file_backup_archive(
            project_root,
            temporary_archive,
            staging_root,
            artifact_role="safety",
        )
        validate_file_backup(temporary_archive, project_root)
        os.replace(temporary_archive, final_archive)
        os.chmod(final_archive, 0o600)
    finally:
        temporary_archive.unlink(missing_ok=True)
    return final_archive


def _create_named_file_backup(project_root: Path, label: str) -> Path:
    safe_label = "".join(
        character
        if character.isascii() and (character.isalnum() or character in "._-")
        else "-"
        for character in label.lower()
    ).strip("-") or "manual"
    backup_dir = project_root / "state/backups"
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_dir, 0o700)
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    final_archive = backup_dir / (
        f"{timestamp}-{safe_label}-{secrets.token_hex(4)}-file-backup.tar.gz"
    )
    with tempfile.TemporaryDirectory(prefix="bedolaga-backup-") as temp_dir:
        work_dir = Path(temp_dir)
        temporary_archive = (
            backup_dir / f".{final_archive.name}.{secrets.token_hex(6)}.tmp"
        )
        try:
            _write_file_backup_archive(
                project_root,
                temporary_archive,
                work_dir / "staging",
                artifact_role="manual",
            )
            validate_file_backup(temporary_archive, project_root)
            os.replace(temporary_archive, final_archive)
            os.chmod(final_archive, 0o600)
        finally:
            temporary_archive.unlink(missing_ok=True)
    return final_archive
