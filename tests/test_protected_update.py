from __future__ import annotations

import unittest
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from lib.protected_update import (
    MigrationPolicy,
    run_command_protected_update,
    run_protected_update,
)
from lib.runtime_change import RuntimeChangeOutcome


class UpdateGateway:
    def __init__(self) -> None:
        self.release = "old"
        self.revision = "rev-old"
        self.stopped = False
        self.restored_dumps: list[str] = []
        self.verified_rollbacks: list[tuple[str, str, str]] = []

    def create_verified_dump(self) -> str:
        return "backup-before-update.dump"

    def current_revision(self) -> str:
        return self.revision

    def apply_release(self) -> None:
        self.release = "new"
        self.revision = "rev-new"

    def verify_release(self) -> None:
        if self.release != "new":
            raise RuntimeError("new release unhealthy")

    def commit_release(self) -> None:
        pass

    def rollback_release(self, previous_release: str, dump_reference: str) -> None:
        self.release = previous_release

    def restore_dump(self, dump_reference: str) -> None:
        self.restored_dumps.append(dump_reference)
        self.revision = "rev-old"

    def verify_rollback(
        self,
        previous_release: str,
        before_revision: str,
        dump_reference: str,
    ) -> None:
        self.verified_rollbacks.append(
            (previous_release, before_revision, dump_reference)
        )
        if self.release != previous_release or self.revision != before_revision:
            raise RuntimeError("restored update state is unhealthy")

    def current_release(self) -> str:
        return self.release

    def safe_stop(self) -> None:
        self.stopped = True


class FailingForwardOnlyGateway(UpdateGateway):
    def verify_release(self) -> None:
        raise RuntimeError("new release unhealthy")


class FailingDumpVerificationGateway(UpdateGateway):
    def create_verified_dump(self) -> str:
        raise RuntimeError("dump is unreadable")


class FailingMigrationGateway(UpdateGateway):
    def apply_release(self) -> None:
        self.release = "new"
        self.revision = "rev-partial"
        raise RuntimeError("migration failed")


class FailingCommitGateway(UpdateGateway):
    def commit_release(self) -> None:
        raise RuntimeError("release record write failed")


class FailingRollbackGateway(FailingForwardOnlyGateway):
    def rollback_release(self, previous_release: str, dump_reference: str) -> None:
        raise RuntimeError("previous bundle unavailable")


class FailingRollbackVerificationGateway(FailingForwardOnlyGateway):
    def verify_rollback(
        self,
        previous_release: str,
        before_revision: str,
        dump_reference: str,
    ) -> None:
        super().verify_rollback(previous_release, before_revision, dump_reference)
        raise RuntimeError("restored stack is unhealthy")


class FailingRollbackAndSafeStopGateway(FailingRollbackGateway):
    def safe_stop(self) -> None:
        raise RuntimeError("stop command failed")


class FailingReleaseProtectionGateway(UpdateGateway):
    def current_release(self) -> str:
        raise RuntimeError("release identity unavailable")


class ProtectedUpdateTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "POSIX signal behavior")
    def test_cli_signal_rolls_back_update_and_returns_signal_exit_code(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            order = root / "order"
            applying = root / "applying"
            adapter = root / "adapter.py"
            adapter.write_text(
                """
from pathlib import Path
import sys
import time

order = Path(sys.argv[1])
applying = Path(sys.argv[2])
stage = sys.argv[3]
if stage == "create-dump":
    print("verified.dump")
elif stage == "current-revision":
    print("rev-old")
elif stage == "current-release":
    print("release-old")
elif stage == "apply-release":
    applying.write_text("yes", encoding="utf-8")
    time.sleep(30)
elif stage in {"rollback-release", "restore-dump", "verify-rollback", "safe-stop"}:
    with order.open("a", encoding="utf-8") as output:
        output.write(stage + "\\n")
""".strip()
                + "\n",
                encoding="utf-8",
            )
            command = [
                sys.executable,
                str(Path(__file__).parents[1] / "lib" / "protected_update.py"),
                "run-command",
                "rollback-compatible",
                "--",
                sys.executable,
                str(adapter),
                str(order),
                str(applying),
            ]
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
            )
            deadline = time.time() + 5
            while not applying.exists() and time.time() < deadline:
                if process.poll() is not None:
                    stdout, stderr = process.communicate()
                    self.fail(
                        f"protected update CLI exited before apply; "
                        f"stdout={stdout!r}, stderr={stderr!r}"
                    )
                time.sleep(0.05)
            self.assertTrue(applying.exists())
            process.send_signal(signal.SIGTERM)
            stdout, _stderr = process.communicate(timeout=10)

            result = json.loads(stdout)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM)
            self.assertEqual(result["outcome"], "rolled_back")
            self.assertEqual(result["failed_stage"], "apply")
            self.assertEqual(
                order.read_text(encoding="utf-8").splitlines(),
                ["rollback-release", "restore-dump", "verify-rollback"],
            )

    def test_command_gateway_commits_a_verified_release(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            state = root / "state"
            state.write_text("old,rev-old", encoding="utf-8")
            adapter = self.write_command_adapter(root)

            result = run_command_protected_update(
                [sys.executable, str(adapter), str(state)],
                MigrationPolicy.ROLLBACK_COMPATIBLE,
            )

            self.assertEqual(result.outcome, RuntimeChangeOutcome.COMMITTED)
            self.assertEqual(result.dump_reference, "verified.dump")
            self.assertEqual(result.before_revision, "rev-old")
            self.assertEqual(result.after_revision, "rev-new")
            self.assertEqual(state.read_text(encoding="utf-8"), "new,rev-new")
            self.assertTrue(state.with_suffix(".committed").is_file())

    def test_command_gateway_restores_release_and_dump_after_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            state = root / "state"
            state.write_text("old,rev-old", encoding="utf-8")
            adapter = self.write_command_adapter(root)
            previous_failure = os.environ.get("PROTECTED_UPDATE_FAIL_VERIFY")
            os.environ["PROTECTED_UPDATE_FAIL_VERIFY"] = "true"
            try:
                result = run_command_protected_update(
                    [sys.executable, str(adapter), str(state)],
                    MigrationPolicy.ROLLBACK_COMPATIBLE,
                )
            finally:
                if previous_failure is None:
                    os.environ.pop("PROTECTED_UPDATE_FAIL_VERIFY", None)
                else:
                    os.environ["PROTECTED_UPDATE_FAIL_VERIFY"] = previous_failure

            self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
            self.assertEqual(result.failed_stage, "verify")
            self.assertTrue(result.rollback_verified)
            self.assertEqual(state.read_text(encoding="utf-8"), "old,rev-old")

    @staticmethod
    def write_command_adapter(root: Path) -> Path:
        adapter = root / "protected_update_adapter.py"
        adapter.write_text(
            """
import os
from pathlib import Path
import sys

state = Path(sys.argv[1])
stage = sys.argv[2]
release, revision = state.read_text(encoding="utf-8").split(",")
if stage == "create-dump":
    print("verified.dump")
elif stage == "current-revision":
    print(revision)
elif stage == "current-release":
    print(release)
elif stage == "apply-release":
    state.write_text("new,rev-new", encoding="utf-8")
elif stage == "verify-release":
    if os.environ.get("PROTECTED_UPDATE_FAIL_VERIFY") == "true":
        raise RuntimeError("release unhealthy")
elif stage == "commit-release":
    state.with_suffix(".committed").write_text("yes", encoding="utf-8")
elif stage == "rollback-release":
    state.write_text(f"{sys.argv[3]},rev-new", encoding="utf-8")
elif stage == "restore-dump":
    state.write_text(f"{state.read_text().split(',')[0]},rev-old", encoding="utf-8")
elif stage == "verify-rollback":
    assert state.read_text(encoding="utf-8") == f"{sys.argv[3]},{sys.argv[4]}"
elif stage == "safe-stop":
    state.with_suffix(".stopped").write_text("yes", encoding="utf-8")
""".strip()
            + "\n",
            encoding="utf-8",
        )
        return adapter

    def test_verified_dump_and_schema_revisions_are_returned_on_commit(self) -> None:
        gateway = UpdateGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.COMMITTED)
        self.assertEqual(result.dump_reference, "backup-before-update.dump")
        self.assertEqual(result.before_revision, "rev-old")
        self.assertEqual(result.after_revision, "rev-new")
        self.assertEqual(gateway.release, "new")
        self.assertFalse(gateway.stopped)

    def test_forward_only_failure_stops_without_starting_old_release(self) -> None:
        gateway = FailingForwardOnlyGateway()

        result = run_protected_update(gateway, MigrationPolicy.FORWARD_ONLY)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "verify")
        self.assertEqual(result.dump_reference, "backup-before-update.dump")
        self.assertEqual(result.before_revision, "rev-old")
        self.assertEqual(result.after_revision, "rev-new")
        self.assertIn("backup-before-update.dump", result.recovery_plan or "")
        self.assertIn(
            "Do not start release old against schema revision rev-new",
            result.recovery_plan or "",
        )
        self.assertIn(
            "complete a compatible forward migration",
            result.recovery_plan or "",
        )
        self.assertIn(
            "verify schema revision rev-old and full health before restart",
            result.recovery_plan or "",
        )
        self.assertNotIn("rollback", (result.recovery_plan or "").lower())
        self.assertFalse(result.rollback_verified)
        self.assertEqual(gateway.restored_dumps, [])
        self.assertEqual(gateway.verified_rollbacks, [])
        self.assertEqual(gateway.release, "new")
        self.assertTrue(gateway.stopped)

    def test_dump_verification_failure_leaves_existing_runtime_running(self) -> None:
        gateway = FailingDumpVerificationGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "protect")
        self.assertIn("dump is unreadable", result.recovery_plan or "")
        self.assertIn(
            "verify a database dump, then retry the update",
            result.recovery_plan or "",
        )
        self.assertEqual(gateway.release, "old")
        self.assertEqual(gateway.revision, "rev-old")
        self.assertFalse(gateway.stopped)

    def test_release_protection_failure_happens_before_revision_and_dump(self) -> None:
        gateway = FailingReleaseProtectionGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertIsNone(result.dump_reference)
        self.assertIsNone(result.before_revision)
        self.assertIn("release identity unavailable", result.recovery_plan or "")
        self.assertFalse(gateway.stopped)

    def test_migration_failure_restores_release_and_verified_dump(self) -> None:
        gateway = FailingMigrationGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "apply")
        self.assertEqual(gateway.release, "old")
        self.assertEqual(gateway.revision, "rev-old")
        self.assertEqual(gateway.restored_dumps, ["backup-before-update.dump"])
        self.assertFalse(gateway.stopped)

    def test_final_verification_failure_returns_verified_rollback(self) -> None:
        gateway = FailingForwardOnlyGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "verify")
        self.assertEqual(result.error, "new release unhealthy")
        self.assertTrue(result.rollback_verified)
        self.assertEqual(gateway.release, "old")
        self.assertEqual(gateway.revision, "rev-old")
        self.assertFalse(gateway.stopped)

    def test_commit_failure_restores_and_verifies_previous_update_state(self) -> None:
        gateway = FailingCommitGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "commit")
        self.assertEqual(result.error, "release record write failed")
        self.assertTrue(result.rollback_verified)
        self.assertEqual(
            gateway.verified_rollbacks,
            [("old", "rev-old", "backup-before-update.dump")],
        )

    def test_rollback_failure_stops_with_exact_manual_recovery_plan(self) -> None:
        gateway = FailingRollbackGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "verify")
        self.assertEqual(result.error, "new release unhealthy")
        self.assertFalse(result.rollback_verified)
        self.assertIn("previous bundle unavailable", result.recovery_plan or "")
        self.assertIn("restore backup-before-update.dump", result.recovery_plan or "")
        self.assertIn("deploy release old", result.recovery_plan or "")
        self.assertIn(
            "verify schema revision rev-old before restart",
            result.recovery_plan or "",
        )
        self.assertTrue(gateway.stopped)

    def test_safe_stop_failure_is_returned_in_manual_recovery_plan(self) -> None:
        gateway = FailingRollbackAndSafeStopGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertFalse(result.rollback_verified)
        self.assertIn("previous bundle unavailable", result.recovery_plan or "")
        self.assertIn("Automatic safe stop failed", result.recovery_plan or "")
        self.assertIn("stop command failed", result.recovery_plan or "")

    def test_rollback_verification_failure_never_claims_rollback(self) -> None:
        gateway = FailingRollbackVerificationGateway()

        result = run_protected_update(gateway, MigrationPolicy.ROLLBACK_COMPATIBLE)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertFalse(result.rollback_verified)
        self.assertIn("Rollback verification failed", result.recovery_plan or "")
        self.assertIn("restored stack is unhealthy", result.recovery_plan or "")
        self.assertEqual(gateway.release, "old")
        self.assertEqual(gateway.revision, "rev-old")
        self.assertEqual(gateway.restored_dumps, ["backup-before-update.dump"])
        self.assertTrue(gateway.stopped)


if __name__ == "__main__":
    unittest.main()
