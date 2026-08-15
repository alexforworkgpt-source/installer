from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import tarfile
import tempfile
from collections.abc import Iterator
from typing import Protocol
import sys
import threading

if __package__:
    from lib import file_backup, managed_filesystem
else:
    import file_backup
    import managed_filesystem

ARTIFACT_TYPE = file_backup.ARTIFACT_TYPE
FileBackupArtifact = file_backup.FileBackupArtifact
RecoveryError = file_backup.RecoveryError
_assert_no_managed_symlinks = file_backup._assert_no_managed_symlinks
_create_named_file_backup = file_backup._create_named_file_backup
_create_safety_backup = file_backup._create_safety_backup
validate_file_backup = file_backup.validate_file_backup
_capture_rollback_transients = managed_filesystem._capture_rollback_transients
_invalidate_transient_state = managed_filesystem._invalidate_transient_state
_mark_applied_state = managed_filesystem._mark_applied_state
_restore_project_tree = managed_filesystem._restore_project_tree
_restore_rollback_transients = managed_filesystem._restore_rollback_transients


class RecoveryInterrupted(RuntimeError):
    pass


class RecoveryOutcome(str, Enum):
    COMMITTED = "committed"
    ROLLED_BACK = "rolled_back"
    SAFELY_STOPPED = "safely_stopped"


@dataclass(frozen=True)
class RecoveryResult:
    outcome: RecoveryOutcome
    failed_stage: str | None
    error: str | None
    rollback_verified: bool
    recovery_plan: str | None = None
    safety_backup: Path | None = None


class RecoveryAdapter(Protocol):
    def quiesce(self) -> None: ...

    def activate(self) -> None: ...

    def verify(self) -> None: ...

    def safe_stop(self) -> None: ...


class ShellRecoveryAdapter:
    def __init__(self, script: Path, project_root: Path) -> None:
        self.script = script.resolve()
        self.project_root = project_root.resolve()

    def _run(self, action: str) -> None:
        subprocess.run(
            ["bash", str(self.script), action, str(self.project_root)],
            check=True,
        )

    def quiesce(self) -> None:
        self._run("quiesce")

    def activate(self) -> None:
        self._run("activate")

    def verify(self) -> None:
        self._run("verify")

    def safe_stop(self) -> None:
        self._run("safe-stop")


def _recovery_marker_path(project_root: Path) -> Path:
    return project_root / ".file-recovery-in-progress.json"


def _write_recovery_marker(
    project_root: Path,
    source_archive: Path,
    safety_backup: Path,
    stage: str,
) -> Path:
    marker = _recovery_marker_path(project_root)
    marker.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = marker.with_name(f".{marker.name}.{secrets.token_hex(6)}")
    temporary.write_text(
        json.dumps(
            {
                "source_archive": str(source_archive),
                "safety_backup": str(safety_backup),
                "stage": stage,
            },
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    os.chmod(temporary, 0o600)
    os.replace(temporary, marker)
    return marker


def _safe_stop_after_failure(
    adapter: RecoveryAdapter,
    safety_backup: Path,
) -> None:
    try:
        adapter.safe_stop()
    except Exception as stop_error:
        raise RecoveryError(
            "rollback failed and safe stop was not verified; "
            f"use safety backup {safety_backup}"
        ) from stop_error


@contextmanager
def _translate_interrupts() -> Iterator[None]:
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    handled_signals = (signal.SIGINT, signal.SIGTERM)
    previous_handlers = {
        handled_signal: signal.getsignal(handled_signal)
        for handled_signal in handled_signals
    }

    def interrupt_handler(signum: int, _frame: object) -> None:
        raise RecoveryInterrupted(f"recovery interrupted by signal {signum}")

    try:
        for handled_signal in handled_signals:
            signal.signal(handled_signal, interrupt_handler)
        yield
    finally:
        for handled_signal, previous_handler in previous_handlers.items():
            signal.signal(handled_signal, previous_handler)


def _recover_file_backup(
    archive: Path,
    expected_project_root: Path,
    adapter: RecoveryAdapter,
) -> RecoveryResult:
    source_archive = archive.resolve()
    expected_project_root = expected_project_root.resolve()
    _assert_no_managed_symlinks(expected_project_root)
    with tempfile.TemporaryDirectory(prefix="bedolaga-recovery-") as temp_dir:
        work_dir = Path(temp_dir)
        frozen_archive = work_dir / "input-file-backup.tar.gz"
        shutil.copyfile(source_archive, frozen_archive)
        os.chmod(frozen_archive, 0o600)
        artifact = validate_file_backup(frozen_archive, expected_project_root)
        required_free_space = artifact.uncompressed_size * 2 + frozen_archive.stat().st_size
        if shutil.disk_usage(work_dir).free < required_free_space:
            raise RecoveryError("not enough free disk space for verified recovery")
        if shutil.disk_usage(expected_project_root).free < artifact.uncompressed_size:
            raise RecoveryError("not enough project disk space for verified recovery")
        extracted = work_dir / "extracted"
        safety = work_dir / "safety"
        rollback_transients = work_dir / "rollback-transients"
        restored_transients = work_dir / "restored-transients"
        with tarfile.open(artifact.archive, "r:gz") as bundle:
            bundle.extractall(extracted, filter="data")
        if artifact.artifact_role == "safety":
            _capture_rollback_transients(
                extracted / "project",
                restored_transients,
            )
        safety_archive = _create_safety_backup(artifact.project_root, work_dir)
        _capture_rollback_transients(artifact.project_root, rollback_transients)
        marker = _write_recovery_marker(
            artifact.project_root,
            source_archive,
            safety_archive,
            "quiesce",
        )

        try:
            adapter.quiesce()
        except Exception as error:
            try:
                adapter.verify()
            except Exception:
                _safe_stop_after_failure(adapter, safety_archive)
                marker.unlink(missing_ok=True)
                return RecoveryResult(
                    outcome=RecoveryOutcome.SAFELY_STOPPED,
                    failed_stage="quiesce",
                    error=str(error),
                    rollback_verified=False,
                    recovery_plan="Keep the stack stopped and fix service shutdown before retrying recovery.",
                    safety_backup=safety_archive,
                )
            marker.unlink(missing_ok=True)
            return RecoveryResult(
                outcome=RecoveryOutcome.ROLLED_BACK,
                failed_stage="quiesce",
                error=str(error),
                rollback_verified=True,
                safety_backup=safety_archive,
            )

        stage = "restore"
        try:
            _write_recovery_marker(
                artifact.project_root,
                source_archive,
                safety_archive,
                stage,
            )
            _restore_project_tree(extracted / "project", artifact.project_root)
            _invalidate_transient_state(artifact.project_root)
            _restore_rollback_transients(
                restored_transients,
                artifact.project_root,
                runtime_override_only=True,
            )
            stage = "activate"
            _write_recovery_marker(
                artifact.project_root,
                source_archive,
                safety_archive,
                stage,
            )
            adapter.activate()
            stage = "verify"
            _write_recovery_marker(
                artifact.project_root,
                source_archive,
                safety_archive,
                stage,
            )
            adapter.verify()
            stage = "commit"
            _write_recovery_marker(
                artifact.project_root,
                source_archive,
                safety_archive,
                stage,
            )
            _mark_applied_state(artifact.project_root)
            _restore_rollback_transients(
                restored_transients,
                artifact.project_root,
                runtime_override_only=False,
            )
        except Exception as error:
            try:
                _write_recovery_marker(
                    artifact.project_root,
                    source_archive,
                    safety_archive,
                    "rollback-quiesce",
                )
                adapter.quiesce()
                safety_artifact = validate_file_backup(
                    safety_archive,
                    artifact.project_root,
                )
                with tarfile.open(safety_artifact.archive, "r:gz") as bundle:
                    bundle.extractall(safety, filter="data")
                _write_recovery_marker(
                    artifact.project_root,
                    source_archive,
                    safety_archive,
                    "rollback-restore",
                )
                _restore_project_tree(safety / "project", artifact.project_root)
                _invalidate_transient_state(artifact.project_root)
                _restore_rollback_transients(
                    rollback_transients,
                    artifact.project_root,
                    runtime_override_only=True,
                )
                _write_recovery_marker(
                    artifact.project_root,
                    source_archive,
                    safety_archive,
                    "rollback-activate",
                )
                adapter.activate()
                _write_recovery_marker(
                    artifact.project_root,
                    source_archive,
                    safety_archive,
                    "rollback-verify",
                )
                adapter.verify()
                _mark_applied_state(artifact.project_root)
                _restore_rollback_transients(
                    rollback_transients,
                    artifact.project_root,
                    runtime_override_only=False,
                )
            except Exception as rollback_error:
                _safe_stop_after_failure(adapter, safety_archive)
                marker.unlink(missing_ok=True)
                return RecoveryResult(
                    outcome=RecoveryOutcome.SAFELY_STOPPED,
                    failed_stage=stage,
                    error=str(error),
                    rollback_verified=False,
                    recovery_plan="Keep the stack stopped and restore a verified backup manually.",
                    safety_backup=safety_archive,
                )
            marker.unlink(missing_ok=True)
            return RecoveryResult(
                outcome=RecoveryOutcome.ROLLED_BACK,
                failed_stage=stage,
                error=str(error),
                rollback_verified=True,
                safety_backup=safety_archive,
            )

    marker.unlink(missing_ok=True)
    return RecoveryResult(
        outcome=RecoveryOutcome.COMMITTED,
        failed_stage=None,
        error=None,
        rollback_verified=False,
        safety_backup=safety_archive,
    )


def recover_file_backup(
    archive: Path,
    expected_project_root: Path,
    adapter: RecoveryAdapter,
) -> RecoveryResult:
    with _translate_interrupts():
        return _recover_file_backup(archive, expected_project_root, adapter)


def _result_json(result: RecoveryResult) -> str:
    return json.dumps(
        {
            "outcome": result.outcome.value,
            "failed_stage": result.failed_stage,
            "error": result.error,
            "rollback_verified": result.rollback_verified,
            "recovery_plan": result.recovery_plan,
            "safety_backup": str(result.safety_backup) if result.safety_backup else None,
        },
        separators=(",", ":"),
    )


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[0] == "validate":
            artifact = validate_file_backup(Path(argv[1]), Path(argv[2]))
            print(
                json.dumps(
                    {
                        "artifact_type": ARTIFACT_TYPE,
                        "artifact_role": artifact.artifact_role,
                        "project_root": str(artifact.project_root),
                        "contains_postgresql": False,
                        "contains_redis": False,
                        "members": list(artifact.members),
                    },
                    separators=(",", ":"),
                )
            )
            return 0
        if len(argv) in {2, 3} and argv[0] == "create":
            project_root = Path(argv[1]).resolve()
            label = argv[2] if len(argv) == 3 else "manual"
            print(_create_named_file_backup(project_root, label))
            return 0
        if len(argv) in {4, 5} and argv[0] == "recover":
            project_root = Path(argv[2]).resolve()
            result = recover_file_backup(
                Path(argv[1]),
                project_root,
                ShellRecoveryAdapter(Path(argv[3]), project_root),
            )
            result_json = _result_json(result)
            if len(argv) == 5:
                result_file = Path(argv[4])
                result_file.write_text(result_json + "\n", encoding="utf-8")
                os.chmod(result_file, 0o600)
            else:
                print(result_json)
            return 0
        if len(argv) == 3 and argv[0] == "result-field":
            result = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
            value = result.get(argv[2])
            if value is not None:
                print(str(value))
            return 0
    except (
        RecoveryError,
        OSError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
    ) as error:
        print(f"recovery failed: {error}", file=sys.stderr)
        return 1
    print(
        "usage: recovery.py <validate ARCHIVE PROJECT_ROOT|create PROJECT_ROOT [LABEL]|recover ARCHIVE PROJECT_ROOT ADAPTER [RESULT_FILE]|result-field RESULT_FILE FIELD>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
