from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys
import tarfile

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from lib.release_bundle import load_release_bundle


def create_pinned_cabinet_dockerfile(
    source_path: Path,
    output_path: Path,
    node_builder_image: str,
    nginx_runtime_image: str,
) -> None:
    image_pattern = r"[^@\s]+@sha256:[0-9a-f]{64}"
    if not re.fullmatch(image_pattern, node_builder_image):
        raise ValueError("node builder image must be pinned by sha256 digest")
    if not re.fullmatch(image_pattern, nginx_runtime_image):
        raise ValueError("nginx runtime image must be pinned by sha256 digest")

    dockerfile = source_path.read_text(encoding="utf-8")
    node_from = "FROM node:20-alpine AS builder"
    nginx_from = "FROM nginx:alpine"
    if dockerfile.count(node_from) != 1 or dockerfile.count(nginx_from) != 1:
        raise ValueError("Cabinet Dockerfile base image contract changed")
    dockerfile = dockerfile.replace(
        node_from,
        f"FROM {node_builder_image} AS builder",
    ).replace(nginx_from, f"FROM {nginx_runtime_image}")
    output_path.write_text(dockerfile, encoding="utf-8")


def create_deterministic_cabinet_archive(
    source_dir: Path,
    output_path: Path,
) -> str:
    if not (source_dir / "index.html").is_file():
        raise ValueError("cabinet dist must contain root index.html")

    entries = sorted(source_dir.rglob("*"), key=lambda path: path.relative_to(source_dir).as_posix())
    for entry in entries:
        if entry.is_symlink() or not (entry.is_file() or entry.is_dir()):
            raise ValueError(f"unsupported cabinet dist entry: {entry}")
        if (
            entry.is_file()
            and entry.suffix in {".css", ".html", ".js", ".json"}
            and b"Program Files/Git" in entry.read_bytes()
        ):
            raise ValueError(
                f"cabinet dist contains a Git Bash path-conversion artifact: {entry}"
            )

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("wb") as raw_output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_output, mtime=0) as gzip_output:
            with tarfile.open(fileobj=gzip_output, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for entry in entries:
                    relative_path = entry.relative_to(source_dir).as_posix()
                    info = archive.gettarinfo(str(entry), arcname=relative_path)
                    info.uid = 0
                    info.gid = 0
                    info.uname = "root"
                    info.gname = "root"
                    info.mtime = 0
                    info.mode = 0o755 if entry.is_dir() else 0o644
                    if entry.is_file():
                        with entry.open("rb") as source_file:
                            archive.addfile(info, source_file)
                    else:
                        archive.addfile(info)

    return hashlib.sha256(output_path.read_bytes()).hexdigest()


def create_release_manifest(
    *,
    output_path: Path,
    release: str,
    installer_repository: str,
    installer_tag: str,
    bot_repository: str,
    bot_sha: str,
    cabinet_repository: str,
    cabinet_sha: str,
    artifact_sha256: str,
    postgres_image: str,
    redis_image: str,
    migration_policy: str,
) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", installer_repository):
        raise ValueError("installer repository must use OWNER/REPOSITORY format")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", installer_tag):
        raise ValueError("installer tag contains unsupported characters")
    if not release:
        raise ValueError("release must not be empty")

    artifact_url = (
        f"https://github.com/{installer_repository}/releases/download/"
        f"{installer_tag}/cabinet-dist.tar.gz"
    )
    manifest = {
        "schema_version": 2,
        "release": release,
        "bot": {
            "repository": bot_repository,
            "sha": bot_sha,
            "backend_contract": "1",
        },
        "cabinet": {
            "repository": cabinet_repository,
            "source_sha": cabinet_sha,
            "artifact_url": artifact_url,
            "artifact_sha256": artifact_sha256,
            "backend_contract": "1",
        },
        "images": {
            "postgres": postgres_image,
            "redis": redis_image,
        },
        "backend_contract": "1",
        "configuration_schema": 1,
        "migration_policy": migration_policy,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    load_release_bundle(output_path, supported_configuration_schema=1)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build installer Release Bundle assets")
    subparsers = parser.add_subparsers(dest="command", required=True)

    archive_parser = subparsers.add_parser("package-cabinet")
    archive_parser.add_argument("source_dir", type=Path)
    archive_parser.add_argument("output_path", type=Path)

    manifest_parser = subparsers.add_parser("create-manifest")
    manifest_parser.add_argument("--output", required=True, type=Path)
    manifest_parser.add_argument("--release", required=True)
    manifest_parser.add_argument("--installer-repository", required=True)
    manifest_parser.add_argument("--installer-tag", required=True)
    manifest_parser.add_argument("--bot-repository", required=True)
    manifest_parser.add_argument("--bot-sha", required=True)
    manifest_parser.add_argument("--cabinet-repository", required=True)
    manifest_parser.add_argument("--cabinet-sha", required=True)
    manifest_parser.add_argument("--artifact-sha256", required=True)
    manifest_parser.add_argument("--postgres-image", required=True)
    manifest_parser.add_argument("--redis-image", required=True)
    manifest_parser.add_argument(
        "--migration-policy",
        choices=("rollback-compatible", "forward-only"),
        required=True,
    )

    dockerfile_parser = subparsers.add_parser("pin-cabinet-dockerfile")
    dockerfile_parser.add_argument("source_path", type=Path)
    dockerfile_parser.add_argument("output_path", type=Path)
    dockerfile_parser.add_argument("node_builder_image")
    dockerfile_parser.add_argument("nginx_runtime_image")

    args = parser.parse_args()
    if args.command == "package-cabinet":
        print(create_deterministic_cabinet_archive(args.source_dir, args.output_path))
        return 0
    if args.command == "pin-cabinet-dockerfile":
        create_pinned_cabinet_dockerfile(
            args.source_path,
            args.output_path,
            args.node_builder_image,
            args.nginx_runtime_image,
        )
        return 0

    create_release_manifest(
        output_path=args.output,
        release=args.release,
        installer_repository=args.installer_repository,
        installer_tag=args.installer_tag,
        bot_repository=args.bot_repository,
        bot_sha=args.bot_sha,
        cabinet_repository=args.cabinet_repository,
        cabinet_sha=args.cabinet_sha,
        artifact_sha256=args.artifact_sha256,
        postgres_image=args.postgres_image,
        redis_image=args.redis_image,
        migration_policy=args.migration_policy,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
