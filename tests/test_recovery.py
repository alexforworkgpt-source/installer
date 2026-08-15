from __future__ import annotations

import hashlib
import io
import json
import os
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from lib.recovery import (
    RecoveryError,
    RecoveryInterrupted,
    RecoveryOutcome,
    recover_file_backup,
    validate_file_backup,
)


def create_file_backup_fixture(
    archive: Path,
    project_root: Path,
    files: dict[str, bytes],
) -> None:
    source = archive.parent / "fixture"
    source.mkdir()
    manifest = {
        "schema_version": 1,
        "artifact_type": "bedolaga-file-backup",
        "project_root": str(project_root),
        "contains_postgresql": False,
        "contains_redis": False,
    }
    fixture_files = {
        "manifest.json": json.dumps(manifest, sort_keys=True).encode(),
        **files,
    }
    for relative_path, content in fixture_files.items():
        target = source / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)

    checksums = "".join(
        f"{hashlib.sha256(content).hexdigest()}  {relative_path}\n"
        for relative_path, content in sorted(fixture_files.items())
    )
    (source / "checksums.sha256").write_text(checksums, encoding="utf-8")
    with tarfile.open(archive, "w:gz") as backup:
        for path in sorted(source.rglob("*")):
            backup.add(path, arcname=path.relative_to(source), recursive=False)


def create_raw_file_backup_fixture(
    archive: Path,
    project_root: Path,
    files: dict[str, bytes],
    corrupt_checksum_for: str | None = None,
) -> None:
    manifest = json.dumps(
        {
            "schema_version": 1,
            "artifact_type": "bedolaga-file-backup",
            "project_root": str(project_root),
            "contains_postgresql": False,
            "contains_redis": False,
        },
        sort_keys=True,
    ).encode()
    fixture_files = {"manifest.json": manifest, **files}
    checksums = "".join(
        f"{('0' * 64) if relative_path == corrupt_checksum_for else hashlib.sha256(content).hexdigest()}  {relative_path}\n"
        for relative_path, content in sorted(fixture_files.items())
    ).encode()
    with tarfile.open(archive, "w:gz") as backup:
        for relative_path, content in {
            **fixture_files,
            "checksums.sha256": checksums,
        }.items():
            member = tarfile.TarInfo(relative_path)
            member.size = len(content)
            backup.addfile(member, io.BytesIO(content))


class RuntimeProbe:
    def __init__(self, project_root: Path) -> None:
        self.project_root = project_root
        self.quiesced = False
        self.activated = False
        self.stopped = False
        self.transient_state_was_clear_at_activation = False

    def quiesce(self) -> None:
        self.quiesced = True

    def activate(self) -> None:
        if list((self.project_root / "state").glob("applied-*.sha256")):
            raise RuntimeError("restored applied hash caused a false no-op")
        self.transient_state_was_clear_at_activation = True
        self.activated = True

    def verify(self) -> None:
        if not self.activated:
            raise RuntimeError("runtime was not activated")

    def safe_stop(self) -> None:
        self.stopped = True


class SafetyBackupProbe(RuntimeProbe):
    def __init__(self, project_root: Path) -> None:
        super().__init__(project_root)
        self.safety_existed_before_quiesce = False

    def quiesce(self) -> None:
        backups = list((self.project_root / "state/backups").glob("*.tar.gz"))
        self.safety_existed_before_quiesce = len(backups) == 1
        super().quiesce()


class QuiesceFailureProbe(RuntimeProbe):
    def quiesce(self) -> None:
        raise RuntimeError("bot did not stop")

    def activate(self) -> None:
        raise RuntimeError("activation must not run after failed quiesce")

    def verify(self) -> None:
        return


class PartialActivationFailureProbe(RuntimeProbe):
    def __init__(self, project_root: Path) -> None:
        super().__init__(project_root)
        self.quiesce_count = 0
        self.activation_count = 0

    def quiesce(self) -> None:
        self.quiesce_count += 1

    def activate(self) -> None:
        self.activation_count += 1
        if self.activation_count == 1:
            raise RuntimeError("Caddy activation failed after Docker started")
        if self.quiesce_count < 2:
            raise RuntimeError("rollback files were replaced while runtime was active")
        self.activated = True


class RollbackFailureProbe(PartialActivationFailureProbe):
    def activate(self) -> None:
        self.activation_count += 1
        if self.activation_count == 1:
            raise RuntimeError("restored runtime activation failed")
        raise RuntimeError("safety runtime activation failed")


class UnstoppableRollbackProbe(RollbackFailureProbe):
    def safe_stop(self) -> None:
        raise RuntimeError("Docker daemon is unavailable")


class InterruptedActivationProbe(PartialActivationFailureProbe):
    def activate(self) -> None:
        self.activation_count += 1
        if self.activation_count == 1:
            raise RecoveryInterrupted("received SIGTERM")
        if self.quiesce_count < 2:
            raise RuntimeError("rollback was not quiesced")
        self.activated = True


class TransientStateProbe(RuntimeProbe):
    def activate(self) -> None:
        state_dir = self.project_root / "state"
        transient_paths = (
            state_dir / "migration.pending",
            state_dir / "migration.completed",
            state_dir / "migration-image.override.yml",
            state_dir / "draft",
        )
        if any(path.exists() for path in transient_paths):
            raise RuntimeError("transient recovery state reached activation")
        if not (state_dir / "bot.override.env").is_file():
            raise RuntimeError("user-owned advanced override was removed")
        super().activate()


class RecoveryTests(unittest.TestCase):
    def test_interrupted_extraction_leaves_runtime_and_files_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            (state_dir / "draft").mkdir()
            (state_dir / "draft/bot.env").write_text(
                "PLANNED=true\n",
                encoding="utf-8",
            )
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = RuntimeProbe(project_root)

            with patch(
                "lib.recovery.tarfile.TarFile.extractall",
                side_effect=RecoveryInterrupted("interrupted extraction"),
            ), self.assertRaises(RecoveryInterrupted):
                recover_file_backup(archive, project_root, runtime)

            self.assertFalse(runtime.quiesced)
            self.assertFalse((state_dir / "backups").exists())
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=current\n",
            )

    def test_unverified_safe_stop_leaves_durable_recovery_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = UnstoppableRollbackProbe(project_root)

            with self.assertRaisesRegex(RecoveryError, "safe stop was not verified"):
                recover_file_backup(archive, project_root, runtime)

            marker = project_root / ".file-recovery-in-progress.json"
            self.assertTrue(marker.is_file())
            marker_data = json.loads(marker.read_text(encoding="utf-8"))
            self.assertTrue(Path(marker_data["safety_backup"]).is_file())

    def test_verified_rollback_restores_the_pre_recovery_settings_draft(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            draft_dir = state_dir / "draft"
            draft_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            (draft_dir / "bot.env").write_text("PLANNED=true\n", encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = PartialActivationFailureProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.ROLLED_BACK)
            self.assertEqual(
                (draft_dir / "bot.env").read_text(encoding="utf-8"),
                "PLANNED=true\n",
            )

    def test_interrupted_activation_returns_verified_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = InterruptedActivationProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.ROLLED_BACK)
            self.assertEqual(result.failed_stage, "activate")
            self.assertEqual(runtime.quiesce_count, 2)
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=current\n",
            )

    def test_recovery_rejects_symlink_in_managed_project_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            outside = root / "outside-secret"
            outside.write_text("must not enter backup\n", encoding="utf-8")
            try:
                os.symlink(outside, state_dir / "linked-secret")
            except OSError as error:
                self.skipTest(f"symlinks are unavailable: {error}")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {"project/state/install.state": current_state.encode()},
            )
            runtime = RuntimeProbe(project_root)

            with self.assertRaisesRegex(RecoveryError, "symlink"):
                recover_file_backup(archive, project_root, runtime)

            self.assertFalse(runtime.quiesced)

    def test_validation_rejects_host_paths_in_restored_state(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            archive = root / "host-path-file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": (
                        f"PROJECT_ROOT={project_root}\n"
                        "BOT_DATA_DIR=/etc\n"
                    ).encode(),
                },
            )

            with self.assertRaisesRegex(RecoveryError, "BOT_DATA_DIR"):
                validate_file_backup(archive, project_root)

    def test_recovery_invalidates_transient_state_but_keeps_user_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                    "project/state/bot.override.env": b"OPTIONAL_FEATURE=true\n",
                    "project/state/applied-bot-env.sha256": b"old-hash\n",
                    "project/state/migration.pending": b"pending\n",
                    "project/state/migration.completed": b"completed\n",
                    "project/state/migration-image.override.yml": b"services: {}\n",
                    "project/state/draft/bot.env": b"UNAPPLIED=true\n",
                },
            )
            runtime = TransientStateProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.COMMITTED)
            self.assertEqual(
                (state_dir / "bot.override.env").read_text(encoding="utf-8"),
                "OPTIONAL_FEATURE=true\n",
            )
            self.assertFalse((state_dir / "draft").exists())
            self.assertFalse((state_dir / "migration.pending").exists())

    def test_validation_rejects_checksum_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            archive = root / "tampered-file-backup.tar.gz"
            state_path = "project/state/install.state"
            create_raw_file_backup_fixture(
                archive,
                project_root,
                {state_path: f"PROJECT_ROOT={project_root}\n".encode()},
                corrupt_checksum_for=state_path,
            )

            with self.assertRaisesRegex(RecoveryError, "checksum mismatch"):
                validate_file_backup(archive, project_root)

    def test_failed_rollback_returns_safely_stopped_with_recovery_plan(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = RollbackFailureProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.SAFELY_STOPPED)
            self.assertEqual(result.failed_stage, "activate")
            self.assertFalse(result.rollback_verified)
            self.assertTrue(runtime.stopped)
            self.assertIsNotNone(result.recovery_plan)
            self.assertIsNotNone(result.safety_backup)
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=current\n",
            )

    def test_corrupt_artifact_is_rejected_without_runtime_or_file_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            archive = root / "corrupt-file-backup.tar.gz"
            archive.write_bytes(b"not a tar archive")
            runtime = RuntimeProbe(project_root)

            with self.assertRaises(RecoveryError):
                recover_file_backup(archive, project_root, runtime)

            self.assertFalse(runtime.quiesced)
            self.assertFalse(runtime.activated)
            self.assertFalse((state_dir / "backups").exists())
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=current\n",
            )

    def test_activation_failure_requiesces_before_verified_rollback(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = PartialActivationFailureProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.ROLLED_BACK)
            self.assertEqual(result.failed_stage, "activate")
            self.assertTrue(result.rollback_verified)
            self.assertEqual(runtime.quiesce_count, 2)
            self.assertFalse(runtime.stopped)
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=current\n",
            )

    def test_failed_quiesce_keeps_the_unchanged_verified_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = QuiesceFailureProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.ROLLED_BACK)
            self.assertEqual(result.failed_stage, "quiesce")
            self.assertTrue(result.rollback_verified)
            self.assertFalse(runtime.stopped)
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=current\n",
            )

    def test_validation_rejects_backslash_path_traversal(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            archive = root / "unsafe-file-backup.tar.gz"
            create_raw_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": (
                        f"PROJECT_ROOT={project_root}\n".encode()
                    ),
                    "project/state/..\\outside": b"must not escape\n",
                },
            )

            with self.assertRaisesRegex(RecoveryError, "unsafe file backup path"):
                validate_file_backup(archive, project_root)

    def test_recovery_creates_a_verified_safety_backup_before_quiescing(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            current_state = f"PROJECT_ROOT={project_root}\n"
            (state_dir / "install.state").write_text(current_state, encoding="utf-8")
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")
            (state_dir / "draft").mkdir()
            (state_dir / "draft/bot.env").write_text(
                "PLANNED=true\n",
                encoding="utf-8",
            )
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": current_state.encode(),
                    "project/state/bot.env": b"VERSION=restored\n",
                },
            )
            runtime = SafetyBackupProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertTrue(runtime.safety_existed_before_quiesce)
            self.assertIsNotNone(result.safety_backup)
            safety = validate_file_backup(result.safety_backup, project_root)
            self.assertIn("project/state/bot.env", safety.members)
            self.assertIn("project/state/draft/bot.env", safety.members)
            self.assertEqual(safety.artifact_role, "safety")
            if os.name != "nt":
                self.assertEqual(
                    stat.S_IMODE(result.safety_backup.stat().st_mode),
                    0o600,
                )
                self.assertEqual(
                    stat.S_IMODE(result.safety_backup.parent.stat().st_mode),
                    0o700,
                )

            rollback_runtime = RuntimeProbe(project_root)
            rollback_result = recover_file_backup(
                result.safety_backup,
                project_root,
                rollback_runtime,
            )
            self.assertEqual(rollback_result.outcome, RecoveryOutcome.COMMITTED)
            self.assertEqual(
                (state_dir / "draft/bot.env").read_text(encoding="utf-8"),
                "PLANNED=true\n",
            )

    def test_validation_rejects_foreign_project_state(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            archive = root / "foreign-file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": b"PROJECT_ROOT=/opt/another-stack\n",
                },
            )

            with self.assertRaisesRegex(RecoveryError, "another project root"):
                validate_file_backup(archive, project_root)

    def test_restored_applied_hash_cannot_turn_recovery_into_a_false_no_op(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            project_root = root / "project"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            (state_dir / "install.state").write_text(
                f"PROJECT_ROOT={project_root}\n",
                encoding="utf-8",
            )
            (state_dir / "bot.env").write_text("VERSION=current\n", encoding="utf-8")

            restored_env = b"VERSION=restored\n"
            archive = root / "file-backup.tar.gz"
            create_file_backup_fixture(
                archive,
                project_root,
                {
                    "project/state/install.state": (
                        f"PROJECT_ROOT={project_root}\n".encode()
                    ),
                    "project/state/bot.env": restored_env,
                    "project/state/applied-bot-env.sha256": (
                        hashlib.sha256(restored_env).hexdigest().encode() + b"\n"
                    ),
                },
            )
            runtime = RuntimeProbe(project_root)

            result = recover_file_backup(archive, project_root, runtime)

            self.assertEqual(result.outcome, RecoveryOutcome.COMMITTED)
            self.assertTrue(runtime.quiesced)
            self.assertTrue(runtime.activated)
            self.assertTrue(runtime.transient_state_was_clear_at_activation)
            self.assertFalse(runtime.stopped)
            self.assertEqual(
                (state_dir / "bot.env").read_text(encoding="utf-8"),
                "VERSION=restored\n",
            )
            self.assertEqual(
                (state_dir / "applied-bot-env.sha256").read_text(encoding="utf-8"),
                hashlib.sha256(restored_env).hexdigest() + "\n",
            )
            if os.name != "nt":
                self.assertEqual(stat.S_IMODE(state_dir.stat().st_mode), 0o700)
                self.assertEqual(
                    stat.S_IMODE((state_dir / "install.state").stat().st_mode),
                    0o600,
                )
                self.assertEqual(
                    stat.S_IMODE((state_dir / "bot.env").stat().st_mode),
                    0o600,
                )


if __name__ == "__main__":
    unittest.main()
