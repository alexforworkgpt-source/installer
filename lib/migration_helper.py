#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path, PurePosixPath
import posixpath
import sys
import tarfile


ALLOWED_TOP_LEVEL = {
    "checksums.sha256",
    "database",
    "images",
    "manifest.env",
    "project",
}


def validate_member(member: tarfile.TarInfo) -> None:
    path = PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"unsafe archive path: {member.name}")

    parts = tuple(part for part in path.parts if part not in ("", "."))
    if not parts or parts[0] not in ALLOWED_TOP_LEVEL:
        raise ValueError(f"unexpected archive path: {member.name}")

    if member.isdev() or member.isfifo():
        raise ValueError(f"unsupported archive entry: {member.name}")

    if member.issym() or member.islnk():
        link_base = path.parent if member.issym() else PurePosixPath()
        resolved_link = PurePosixPath(posixpath.normpath(str(link_base / member.linkname)))
        if resolved_link.is_absolute() or ".." in resolved_link.parts:
            raise ValueError(f"unsafe archive link: {member.name}")
        if not resolved_link.parts or resolved_link.parts[0] != "project":
            raise ValueError(f"archive link leaves project: {member.name}")
        if len(parts) > 1 and parts[1] in {"state", "runtime", "caddy"}:
            raise ValueError(f"links are not allowed in {parts[1]}: {member.name}")


def extract_archive(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as package:
        for member in package.getmembers():
            validate_member(member)
        package.extractall(destination, filter="data")


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[0] != "extract":
        print("usage: migration_helper.py extract <archive.tar.gz> <destination>", file=sys.stderr)
        return 2

    archive = Path(argv[1]).resolve()
    destination = Path(argv[2]).resolve()
    if not archive.is_file():
        print(f"archive not found: {archive}", file=sys.stderr)
        return 1

    try:
        extract_archive(archive, destination)
    except (OSError, tarfile.TarError, ValueError) as error:
        print(f"cannot extract migration archive: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
