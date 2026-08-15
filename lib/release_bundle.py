from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import re
import secrets
import shutil
import subprocess
import tarfile
import tempfile
import sys
from urllib.parse import urlsplit


class ReleaseBundleError(ValueError):
    pass


@dataclass(frozen=True)
class ResolvedGitRef:
    repository: str
    requested_ref: str
    sha: str


@dataclass(frozen=True)
class BotRelease:
    repository: str
    sha: str


@dataclass(frozen=True)
class CabinetRelease:
    source_sha: str
    artifact_url: str
    artifact_sha256: str
    repository: str | None = None


@dataclass(frozen=True)
class ImageReleases:
    postgres: str
    redis: str


@dataclass(frozen=True)
class BackendContractPair:
    bot: str
    cabinet: str


@dataclass(frozen=True)
class ReleaseBundle:
    release: str
    bot: BotRelease
    cabinet: CabinetRelease
    images: ImageReleases
    backend_contract: str
    backend_contracts: BackendContractPair
    configuration_schema: int
    migration_policy: str


def resolve_git_ref(repository: str | Path, requested_ref: str) -> ResolvedGitRef:
    repository_value = os.fspath(repository)
    if not requested_ref:
        raise ReleaseBundleError("requested Git ref must not be empty")

    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            subprocess.run(
                ["git", "init", "--quiet", "--bare", temp_dir],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [
                    "git",
                    "-C",
                    temp_dir,
                    "fetch",
                    "--quiet",
                    "--no-tags",
                    "--",
                    repository_value,
                    requested_ref,
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            sha = subprocess.run(
                ["git", "-C", temp_dir, "rev-parse", "--verify", "FETCH_HEAD^{commit}"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ReleaseBundleError(
            f"unable to resolve Git ref {requested_ref!r} in repository {repository_value!r}"
        ) from error

    _validate_sha(sha, "resolved Git ref", 40)
    return ResolvedGitRef(
        repository=repository_value,
        requested_ref=requested_ref,
        sha=sha,
    )


def verify_repository_head(repository: str | Path, expected_sha: str) -> None:
    _validate_sha(expected_sha, "expected SHA", 40)
    repository_value = os.fspath(repository)
    try:
        actual_sha = subprocess.run(
            ["git", "-C", repository_value, "rev-parse", "--verify", "HEAD^{commit}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise ReleaseBundleError(
            f"unable to read repository HEAD in {repository_value!r}"
        ) from error

    _validate_sha(actual_sha, "repository HEAD", 40)
    if not secrets.compare_digest(actual_sha, expected_sha):
        raise ReleaseBundleError(
            f"repository HEAD does not match expected SHA: {actual_sha} != {expected_sha}"
        )


def release_bundle_identity(bundle: ReleaseBundle) -> str:
    identity_payload = asdict(bundle)
    if bundle.cabinet.repository is None:
        del identity_payload["cabinet"]["repository"]
    canonical_bundle = json.dumps(
        identity_payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(canonical_bundle).hexdigest()


def verify_cabinet_artifact(archive_path: Path, expected_sha256: str) -> None:
    actual_sha256 = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    if not secrets.compare_digest(actual_sha256, expected_sha256):
        raise ReleaseBundleError("cabinet artifact checksum mismatch")

    has_root_index = False
    with tarfile.open(archive_path, "r:gz") as bundle:
        for member in bundle.getmembers():
            member_path = PurePosixPath(member.name)
            if (
                member_path.is_absolute()
                or ".." in member_path.parts
                or member.issym()
                or member.islnk()
                or not (member.isfile() or member.isdir())
            ):
                raise ReleaseBundleError(
                    f"unsafe cabinet artifact member: {member.name}"
                )
            if member.isfile() and member_path.parts == ("index.html",):
                has_root_index = True

    if not has_root_index:
        raise ReleaseBundleError("cabinet artifact does not contain root index.html")


def activate_cabinet_artifact(
    archive_path: Path,
    expected_sha256: str,
    destination: Path,
) -> None:
    verify_cabinet_artifact(archive_path, expected_sha256)

    destination.parent.mkdir(parents=True, exist_ok=True)
    candidate = Path(
        tempfile.mkdtemp(
            dir=destination.parent,
            prefix=f".{destination.name}.candidate-",
        )
    )
    backup = destination.with_name(
        f".{destination.name}.backup-{secrets.token_hex(8)}"
    )
    try:
        with tarfile.open(archive_path, "r:gz") as bundle:
            bundle.extractall(candidate, filter="data")

        candidate.chmod(0o755)
        for extracted_path in candidate.rglob("*"):
            if extracted_path.is_dir():
                extracted_path.chmod(0o755)
            elif extracted_path.is_file():
                extracted_path.chmod(0o644)

        if destination.exists() and not destination.is_dir():
            raise ReleaseBundleError("cabinet destination is not a directory")

        if destination.exists():
            os.replace(destination, backup)
        try:
            os.replace(candidate, destination)
        except OSError:
            if backup.exists():
                os.replace(backup, destination)
            raise
        if backup.exists():
            try:
                shutil.rmtree(backup)
            except OSError:
                # Activation is already committed; a stale private backup is safer
                # than reporting a false activation failure.
                pass
    finally:
        if candidate.exists():
            shutil.rmtree(candidate)


def _validate_sha(value: object, field: str, length: int) -> None:
    if not isinstance(value, str) or not re.fullmatch(
        rf"[0-9a-f]{{{length}}}",
        value,
    ):
        raise ReleaseBundleError(f"{field} must be an immutable {length}-character hex digest")


def _validate_image(value: object, field: str) -> None:
    if not isinstance(value, str) or not re.fullmatch(
        r"[^@\s]+@sha256:[0-9a-f]{64}",
        value,
    ):
        raise ReleaseBundleError(f"{field} must be pinned by sha256 digest")


def _validate_public_https_repository(value: object, field: str) -> None:
    if not isinstance(value, str):
        raise ReleaseBundleError(f"{field} must be a public GitHub HTTPS URL")
    try:
        repository_url = urlsplit(value)
        port = repository_url.port
    except ValueError as error:
        raise ReleaseBundleError(f"{field} must be a public GitHub HTTPS URL") from error
    if (
        value != value.strip()
        or any(character.isspace() for character in value)
        or repository_url.scheme != "https"
        or repository_url.hostname != "github.com"
        or not repository_url.path.strip("/")
        or repository_url.username is not None
        or repository_url.password is not None
        or repository_url.query
        or repository_url.fragment
        or port not in (None, 443)
    ):
        raise ReleaseBundleError(f"{field} must be a public GitHub HTTPS URL")


def _backend_contract_pair(manifest: dict[str, object]) -> BackendContractPair:
    bot = manifest["bot"]
    cabinet = manifest["cabinet"]
    backend_contract = manifest["backend_contract"]
    if not isinstance(bot, dict) or not isinstance(cabinet, dict):
        raise ReleaseBundleError("bot and cabinet must be objects")
    return BackendContractPair(
        bot=bot.get("backend_contract", backend_contract),
        cabinet=cabinet.get("backend_contract", backend_contract),
    )


def _validate_manifest(manifest: dict[str, object], supported_configuration_schema: int) -> None:
    if manifest["schema_version"] not in (1, 2):
        raise ReleaseBundleError("unsupported manifest schema_version")
    if not isinstance(manifest["configuration_schema"], int):
        raise ReleaseBundleError("configuration_schema must be an integer")
    if manifest["configuration_schema"] > supported_configuration_schema:
        raise ReleaseBundleError("unsupported configuration_schema")

    bot = manifest["bot"]
    cabinet = manifest["cabinet"]
    images = manifest["images"]
    if not isinstance(bot, dict) or not isinstance(cabinet, dict) or not isinstance(images, dict):
        raise ReleaseBundleError("bot, cabinet and images must be objects")
    _validate_sha(bot.get("sha"), "bot.sha", 40)
    has_cabinet_repository = "repository" in cabinet
    cabinet_repository = cabinet.get("repository")
    if manifest["schema_version"] == 1 and has_cabinet_repository:
        raise ReleaseBundleError("schema_version 1 must not define cabinet.repository")
    if manifest["schema_version"] == 2 and not has_cabinet_repository:
        raise ReleaseBundleError("schema_version 2 requires cabinet.repository")
    if has_cabinet_repository:
        _validate_public_https_repository(cabinet_repository, "cabinet.repository")
    _validate_sha(cabinet.get("source_sha"), "cabinet.source_sha", 40)
    _validate_sha(cabinet.get("artifact_sha256"), "cabinet.artifact_sha256", 64)
    artifact_url = cabinet.get("artifact_url")
    parsed_artifact_url = urlsplit(artifact_url if isinstance(artifact_url, str) else "")
    if (
        parsed_artifact_url.scheme != "https"
        or not parsed_artifact_url.hostname
        or not parsed_artifact_url.path.endswith(".tar.gz")
    ):
        raise ReleaseBundleError("cabinet.artifact_url must be an HTTPS tar.gz URL")
    _validate_image(images.get("postgres"), "images.postgres")
    _validate_image(images.get("redis"), "images.redis")
    if manifest["backend_contract"] != "1":
        raise ReleaseBundleError("backend_contract is unsupported")
    backend_contracts = _backend_contract_pair(manifest)
    if (
        backend_contracts.bot != backend_contracts.cabinet
        or backend_contracts.bot != manifest["backend_contract"]
    ):
        raise ReleaseBundleError("incompatible Bot/Cabinet backend contract pair")
    if manifest["migration_policy"] not in ("rollback-compatible", "forward-only"):
        raise ReleaseBundleError("migration_policy is unsupported")


def load_release_bundle(
    manifest_path: Path,
    supported_configuration_schema: int,
) -> ReleaseBundle:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if not isinstance(manifest, dict):
            raise ReleaseBundleError("release manifest must be an object")
        _validate_manifest(manifest, supported_configuration_schema)
        return ReleaseBundle(
            release=manifest["release"],
            bot=BotRelease(
                repository=manifest["bot"]["repository"],
                sha=manifest["bot"]["sha"],
            ),
            cabinet=CabinetRelease(
                source_sha=manifest["cabinet"]["source_sha"],
                artifact_url=manifest["cabinet"]["artifact_url"],
                artifact_sha256=manifest["cabinet"]["artifact_sha256"],
                repository=manifest["cabinet"].get("repository"),
            ),
            images=ImageReleases(**manifest["images"]),
            backend_contract=manifest["backend_contract"],
            backend_contracts=_backend_contract_pair(manifest),
            configuration_schema=manifest["configuration_schema"],
            migration_policy=manifest["migration_policy"],
        )
    except (KeyError, TypeError, json.JSONDecodeError) as error:
        raise ReleaseBundleError(f"invalid release manifest: {error}") from error


def main(argv: list[str]) -> int:
    if not argv:
        print(
            "usage: release_bundle.py <validate|resolve-ref|verify-head|verify-cabinet|activate-cabinet> ...",
            file=sys.stderr,
        )
        return 2
    if argv[0] == "validate" and len(argv) == 3:
        bundle = load_release_bundle(Path(argv[1]), int(argv[2]))
        output = asdict(bundle)
        output["identity"] = release_bundle_identity(bundle)
        print(json.dumps(output, separators=(",", ":")))
        return 0
    if argv[0] == "activate-cabinet" and len(argv) == 4:
        activate_cabinet_artifact(Path(argv[1]), argv[2], Path(argv[3]))
        return 0
    if argv[0] == "resolve-ref" and len(argv) == 3:
        print(resolve_git_ref(argv[1], argv[2]).sha)
        return 0
    if argv[0] == "verify-head" and len(argv) == 3:
        verify_repository_head(argv[1], argv[2])
        return 0
    if argv[0] == "verify-cabinet" and len(argv) == 3:
        verify_cabinet_artifact(Path(argv[1]), argv[2])
        return 0
    print(f"invalid arguments for command: {argv[0]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ReleaseBundleError, OSError, tarfile.TarError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
