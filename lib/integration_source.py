"""Package the committed Installer source for disposable lifecycle tests."""

from __future__ import annotations

import gzip
import hashlib
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile


class IntegrationSourceError(RuntimeError):
    pass


def _git(workspace: Path, *arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(workspace), *arguments],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise IntegrationSourceError("unable to verify committed Installer source") from error


def _excluded(path: PurePosixPath) -> bool:
    parts = tuple(part.lower() for part in path.parts)
    return (
        parts[0] in {".git", ".scratch", "state", ".playwright-mcp"}
        or "__pycache__" in parts
        or parts[-1] == "env.txt"
        or parts[-1].startswith(".env.")
        or parts[-1].endswith((".env", ".pyc"))
    )


def create_source_archive(
    workspace: Path, destination: Path, *, expected_sha: str | None = None
) -> dict[str, str]:
    workspace = workspace.resolve()
    repository_root = Path(_git(workspace, "rev-parse", "--show-toplevel").decode().strip())
    if repository_root.resolve() != workspace:
        raise IntegrationSourceError("Installer source must be a Git repository root")
    installer_sha = _git(workspace, "rev-parse", "HEAD^{commit}").decode().strip()
    if expected_sha is not None:
        if not re.fullmatch(r"[0-9a-f]{40}", expected_sha):
            raise IntegrationSourceError("expected Installer SHA must be 40 lowercase hex characters")
        if expected_sha != installer_sha:
            raise IntegrationSourceError("Installer HEAD does not match expected source SHA")

    changes = _git(workspace, "status", "--porcelain=v1", "-z", "--untracked-files=normal")
    for change in changes.split(b"\0"):
        if not change:
            continue
        if change[:2] != b"??":
            raise IntegrationSourceError("Installer source has uncommitted changes")
        if not _excluded(PurePosixPath(change[3:].decode("utf-8"))):
            raise IntegrationSourceError("Installer source has uncommitted untracked files")

    files = []
    for entry in _git(workspace, "ls-tree", "-r", "-z", installer_sha).split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        path = PurePosixPath(raw_path.decode("utf-8"))
        if _excluded(path):
            continue
        if metadata.split(b" ", 1)[0] not in {b"100644", b"100755"}:
            raise IntegrationSourceError("Installer source contains an unsupported Git entry")
        files.append(path.as_posix())
    if not files:
        raise IntegrationSourceError("Installer commit contains no public source files")

    installer_tree_sha = _git(workspace, "rev-parse", f"{installer_sha}^{{tree}}").decode().strip()
    with tempfile.TemporaryDirectory(prefix="installer-source-") as temp_dir:
        archive = Path(temp_dir) / "source.tar"
        _git(
            workspace, "archive", "--format=tar", f"--output={archive}", installer_sha,
            "--", *(f":(literal){path}" for path in files),
        )
        with archive.open("rb") as source, destination.open("wb") as output:
            with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=0) as compressed:
                shutil.copyfileobj(source, compressed)

    checksum = hashlib.sha256()
    with destination.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return {
        "installer_sha": installer_sha,
        "installer_tree_sha": installer_tree_sha,
        "archive_sha256": checksum.hexdigest(),
    }
