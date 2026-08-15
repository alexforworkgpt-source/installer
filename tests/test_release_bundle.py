from __future__ import annotations

from dataclasses import FrozenInstanceError
import json
import hashlib
import os
import stat
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from lib.release_bundle import (
    BackendContractPair,
    ReleaseBundleError,
    ResolvedGitRef,
    activate_cabinet_artifact,
    load_release_bundle,
    release_bundle_identity,
    resolve_git_ref,
    verify_cabinet_artifact,
    verify_repository_head,
)


VALID_BOT_SHA = "b" * 40
VALID_CABINET_SHA = "c" * 40
VALID_ARTIFACT_SHA256 = "a" * 64
VALID_POSTGRES_DIGEST = "d" * 64
VALID_REDIS_DIGEST = "e" * 64


def valid_manifest() -> dict[str, object]:
    return {
        "schema_version": 1,
        "release": "2026.08.0",
        "bot": {
            "repository": "https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git",
            "sha": VALID_BOT_SHA,
        },
        "cabinet": {
            "source_sha": VALID_CABINET_SHA,
            "artifact_url": "https://github.com/BEDOLAGA-DEV/bedolaga-installer/releases/download/2026.08.0/cabinet-dist.tar.gz",
            "artifact_sha256": VALID_ARTIFACT_SHA256,
        },
        "images": {
            "postgres": f"postgres@sha256:{VALID_POSTGRES_DIGEST}",
            "redis": f"redis@sha256:{VALID_REDIS_DIGEST}",
        },
        "backend_contract": "1",
        "configuration_schema": 1,
        "migration_policy": "rollback-compatible",
    }


def create_git_repository(root: Path) -> tuple[Path, str]:
    repository = root / "repository"
    repository.mkdir()
    subprocess.run(
        ["git", "init", "--quiet", "--initial-branch=main", str(repository)],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repository), "config", "user.email", "tests@example.com"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repository), "config", "user.name", "Release Tests"],
        check=True,
    )
    (repository / "release.txt").write_text("first release", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(repository), "add", "release.txt"],
        check=True,
    )
    subprocess.run(
        ["git", "-C", str(repository), "commit", "--quiet", "-m", "first release"],
        check=True,
    )
    sha = subprocess.run(
        ["git", "-C", str(repository), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    subprocess.run(
        ["git", "-C", str(repository), "tag", "-a", "v1.0.0", "-m", "release v1"],
        check=True,
    )
    return repository, sha


class ReleaseBundleTests(unittest.TestCase):
    def test_git_refs_resolve_to_an_immutable_commit_before_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            repository, sha = create_git_repository(Path(temp_dir))

            for requested_ref in ("main", "v1.0.0", sha):
                with self.subTest(requested_ref=requested_ref):
                    resolved = resolve_git_ref(repository, requested_ref)

                    self.assertEqual(
                        resolved,
                        ResolvedGitRef(
                            repository=str(repository),
                            requested_ref=requested_ref,
                            sha=sha,
                        ),
                    )
                    with self.assertRaises(FrozenInstanceError):
                        resolved.sha = "a" * 40

            self.assertEqual(
                subprocess.run(
                    ["git", "-C", str(repository), "rev-parse", "HEAD"],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip(),
                sha,
            )

    def test_missing_git_ref_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            repository, _ = create_git_repository(Path(temp_dir))

            with self.assertRaisesRegex(ReleaseBundleError, "unable to resolve Git ref"):
                resolve_git_ref(repository, "missing-release")

    def test_repository_head_must_equal_resolved_sha(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            repository, previous_sha = create_git_repository(Path(temp_dir))
            (repository / "release.txt").write_text("second release", encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(repository), "commit", "--quiet", "-am", "second release"],
                check=True,
            )

            with self.assertRaisesRegex(ReleaseBundleError, "HEAD does not match expected SHA"):
                verify_repository_head(repository, previous_sha)

            current_sha = subprocess.run(
                ["git", "-C", str(repository), "rev-parse", "HEAD"],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            verify_repository_head(repository, current_sha)

    def test_valid_manifest_resolves_to_immutable_release_bundle(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest_path = Path(temp_dir) / "release.json"
            manifest_path.write_text(json.dumps(valid_manifest()), encoding="utf-8")

            bundle = load_release_bundle(manifest_path, supported_configuration_schema=1)

            self.assertEqual(bundle.release, "2026.08.0")
            self.assertEqual(bundle.bot.sha, VALID_BOT_SHA)
            self.assertEqual(bundle.cabinet.source_sha, VALID_CABINET_SHA)
            self.assertEqual(bundle.cabinet.artifact_sha256, VALID_ARTIFACT_SHA256)
            self.assertEqual(
                bundle.images.postgres,
                f"postgres@sha256:{VALID_POSTGRES_DIGEST}",
            )
            self.assertEqual(bundle.images.redis, f"redis@sha256:{VALID_REDIS_DIGEST}")
            self.assertEqual(bundle.backend_contract, "1")
            self.assertEqual(
                bundle.backend_contracts,
                BackendContractPair(bot="1", cabinet="1"),
            )
            self.assertEqual(bundle.configuration_schema, 1)
            self.assertEqual(bundle.migration_policy, "rollback-compatible")

    def test_manifest_rejects_incompatible_bot_and_cabinet_contract_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest = valid_manifest()
            manifest["bot"]["backend_contract"] = "1"
            manifest["cabinet"]["backend_contract"] = "2"
            manifest_path = Path(temp_dir) / "release.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            with self.assertRaisesRegex(
                ReleaseBundleError,
                "incompatible Bot/Cabinet backend contract pair",
            ):
                load_release_bundle(manifest_path, supported_configuration_schema=1)

    def test_manifest_accepts_explicit_compatible_backend_contract_pair(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            manifest = valid_manifest()
            manifest["bot"]["backend_contract"] = "1"
            manifest["cabinet"]["backend_contract"] = "1"
            manifest_path = Path(temp_dir) / "release.json"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

            bundle = load_release_bundle(manifest_path, supported_configuration_schema=1)

            self.assertEqual(
                bundle.backend_contracts,
                BackendContractPair(bot="1", cabinet="1"),
            )

    def test_previous_bundle_identity_is_deterministic_and_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            previous_manifest_path = root / "previous.json"
            previous_manifest_path.write_text(
                json.dumps(valid_manifest(), indent=2),
                encoding="utf-8",
            )
            equivalent_manifest_path = root / "equivalent.json"
            equivalent_manifest_path.write_text(
                json.dumps(valid_manifest(), sort_keys=True),
                encoding="utf-8",
            )
            next_manifest = valid_manifest()
            next_manifest["cabinet"]["artifact_sha256"] = "f" * 64
            next_manifest_path = root / "next.json"
            next_manifest_path.write_text(json.dumps(next_manifest), encoding="utf-8")

            previous_bundle = load_release_bundle(previous_manifest_path, 1)
            previous_identity = release_bundle_identity(previous_bundle)
            equivalent_bundle = load_release_bundle(equivalent_manifest_path, 1)
            next_bundle = load_release_bundle(next_manifest_path, 1)

            self.assertEqual(
                release_bundle_identity(equivalent_bundle),
                previous_identity,
            )
            self.assertNotEqual(
                release_bundle_identity(next_bundle),
                previous_identity,
            )
            self.assertEqual(release_bundle_identity(previous_bundle), previous_identity)

    def test_manifest_rejects_mutable_or_unsupported_release_identity(self) -> None:
        invalid_manifests = {
            "bot.sha": lambda manifest: manifest["bot"].update(sha="main"),
            "cabinet.source_sha": lambda manifest: manifest["cabinet"].update(
                source_sha="v1.0.0"
            ),
            "cabinet.artifact_sha256": lambda manifest: manifest["cabinet"].update(
                artifact_sha256="short"
            ),
            "cabinet.artifact_url": lambda manifest: manifest["cabinet"].update(
                artifact_url="http://downloads.example.com/cabinet-dist.tar.gz"
            ),
            "images.postgres": lambda manifest: manifest["images"].update(
                postgres="postgres:15-alpine"
            ),
            "configuration_schema": lambda manifest: manifest.update(
                configuration_schema=2
            ),
            "backend_contract": lambda manifest: manifest.update(backend_contract="2"),
            "migration_policy": lambda manifest: manifest.update(
                migration_policy="automatic"
            ),
        }

        for expected_field, mutate in invalid_manifests.items():
            with self.subTest(field=expected_field), tempfile.TemporaryDirectory() as temp_dir:
                manifest = valid_manifest()
                mutate(manifest)
                manifest_path = Path(temp_dir) / "release.json"
                manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

                with self.assertRaisesRegex(ValueError, expected_field.replace(".", r"\.")):
                    load_release_bundle(
                        manifest_path,
                        supported_configuration_schema=1,
                    )

    def test_verified_cabinet_artifact_atomically_replaces_frontend(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "artifact-source"
            source.mkdir()
            (source / "index.html").write_text("new cabinet", encoding="utf-8")
            (source / "assets").mkdir()
            (source / "assets" / "app.js").write_text("new bundle", encoding="utf-8")
            archive = root / "cabinet-dist.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(source / "index.html", arcname="index.html")
                bundle.add(source / "assets", arcname="assets")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            destination = root / "cabinet-dist"
            destination.mkdir()
            (destination / "index.html").write_text("old cabinet", encoding="utf-8")

            verify_cabinet_artifact(archive, checksum)
            activate_cabinet_artifact(archive, checksum, destination)

            self.assertEqual(
                (destination / "index.html").read_text(encoding="utf-8"),
                "new cabinet",
            )
            self.assertEqual(
                (destination / "assets" / "app.js").read_text(encoding="utf-8"),
                "new bundle",
            )
            if os.name == "posix":
                self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o755)
                self.assertEqual(
                    stat.S_IMODE((destination / "assets").stat().st_mode), 0o755
                )
                self.assertEqual(
                    stat.S_IMODE((destination / "index.html").stat().st_mode), 0o644
                )
            self.assertFalse(any(root.glob(".cabinet-dist.*")))

    def test_cabinet_activation_failure_preserves_old_frontend(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "artifact-source"
            source.mkdir()
            (source / "index.html").write_text("new cabinet", encoding="utf-8")
            archive = root / "cabinet-dist.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(source / "index.html", arcname="index.html")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            destination = root / "cabinet-dist"
            destination.mkdir()
            (destination / "index.html").write_text("old cabinet", encoding="utf-8")
            real_replace = os.replace

            def fail_candidate_switch(source_path: object, target_path: object) -> None:
                if Path(source_path).name.startswith(".cabinet-dist.candidate-"):
                    raise OSError("injected cabinet activation failure")
                real_replace(source_path, target_path)

            with mock.patch(
                "lib.release_bundle.os.replace",
                side_effect=fail_candidate_switch,
            ), self.assertRaisesRegex(OSError, "injected cabinet activation failure"):
                activate_cabinet_artifact(archive, checksum, destination)

            self.assertEqual(
                (destination / "index.html").read_text(encoding="utf-8"),
                "old cabinet",
            )
            self.assertFalse(any(root.glob(".cabinet-dist.*")))

    def test_failed_cabinet_restore_keeps_the_last_backup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "artifact-source"
            source.mkdir()
            (source / "index.html").write_text("new cabinet", encoding="utf-8")
            archive = root / "cabinet-dist.tar.gz"
            with tarfile.open(archive, "w:gz") as bundle:
                bundle.add(source / "index.html", arcname="index.html")
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
            destination = root / "cabinet-dist"
            destination.mkdir()
            (destination / "index.html").write_text("old cabinet", encoding="utf-8")
            real_replace = os.replace

            def fail_switch_and_restore(source_path: object, target_path: object) -> None:
                source_name = Path(source_path).name
                if source_name.startswith((".cabinet-dist.candidate-", ".cabinet-dist.backup-")):
                    raise OSError("injected candidate and restore failure")
                real_replace(source_path, target_path)

            with mock.patch(
                "lib.release_bundle.os.replace",
                side_effect=fail_switch_and_restore,
            ), self.assertRaisesRegex(OSError, "injected candidate and restore failure"):
                activate_cabinet_artifact(archive, checksum, destination)

            backups = list(root.glob(".cabinet-dist.backup-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(
                (backups[0] / "index.html").read_text(encoding="utf-8"),
                "old cabinet",
            )


if __name__ == "__main__":
    unittest.main()
