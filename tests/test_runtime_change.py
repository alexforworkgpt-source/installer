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

from lib.runtime_change import (
    PostgresCredentialState,
    RuntimeChangeOutcome,
    rotate_postgres_credentials,
    run_command_runtime_change,
    run_runtime_change,
)


class SuccessfulRuntimeAdapter:
    def __init__(self) -> None:
        self.runtime = "old"
        self.applied = "old"

    def plan(self) -> None:
        pass

    def protect(self) -> str:
        return self.runtime

    def apply(self) -> None:
        self.runtime = "new"

    def verify(self) -> None:
        if self.runtime != "new":
            raise RuntimeError("new runtime is not ready")

    def commit(self) -> None:
        self.applied = self.runtime

    def rollback(self, recovery_point: str) -> None:
        self.runtime = recovery_point

    def verify_rollback(self, recovery_point: str) -> None:
        if self.runtime != recovery_point:
            raise RuntimeError("rollback is not ready")

    def safe_stop(self) -> None:
        self.runtime = "stopped"


class FailingApplyAdapter(SuccessfulRuntimeAdapter):
    def apply(self) -> None:
        self.runtime = "partial-new"
        raise RuntimeError("compose failed")


class FailingProtectionAdapter(SuccessfulRuntimeAdapter):
    def protect(self) -> str:
        raise RuntimeError("snapshot failed")


class FailingPlanAdapter(SuccessfulRuntimeAdapter):
    def plan(self) -> None:
        raise RuntimeError("invalid plan")


class FailingVerificationAdapter(SuccessfulRuntimeAdapter):
    def verify(self) -> None:
        raise RuntimeError("health check failed")


class FailingCommitAdapter(SuccessfulRuntimeAdapter):
    def commit(self) -> None:
        raise RuntimeError("state commit failed")


class FailingRollbackVerificationAdapter(FailingApplyAdapter):
    def verify_rollback(self, recovery_point: str) -> None:
        raise RuntimeError("rollback health check failed")


class FailingRollbackAndSafeStopAdapter(FailingApplyAdapter):
    def rollback(self, recovery_point: str) -> None:
        raise RuntimeError("rollback failed")

    def safe_stop(self) -> None:
        raise RuntimeError("stop command failed")


class PostgresGateway:
    def __init__(self) -> None:
        self.database_password = "old-password"
        self.bot_password = "old-password"
        self.applied_password = "old-password"
        self.bot_running = True
        self.old_connection_verified = False
        self.verified_passwords: list[str] = []

    def current_state(self) -> PostgresCredentialState:
        return PostgresCredentialState(
            database_password=self.database_password,
            bot_password=self.bot_password,
            applied_password=self.applied_password,
        )

    def set_database_password(self, password: str) -> None:
        if not self.old_connection_verified:
            raise RuntimeError("old connection was not verified")
        self.database_password = password

    def set_bot_password(self, password: str) -> None:
        self.bot_password = password

    def restart_bot(self) -> None:
        self.bot_running = True

    def verify_connection(self, password: str) -> None:
        self.verified_passwords.append(password)
        if not self.bot_running:
            raise RuntimeError("bot is stopped")
        if self.database_password != password or self.bot_password != password:
            raise RuntimeError("credential mismatch")
        if password == "old-password":
            self.old_connection_verified = True

    def commit_applied_password(self, password: str) -> None:
        self.applied_password = password

    def safe_stop_bot(self) -> None:
        self.bot_running = False


class FailingCredentialApplyGateway(PostgresGateway):
    def set_bot_password(self, password: str) -> None:
        if password != "old-password":
            raise RuntimeError("bot secret write failed")
        super().set_bot_password(password)


class FailingCredentialRollbackGateway(FailingCredentialApplyGateway):
    def set_database_password(self, password: str) -> None:
        if password == "old-password" and self.database_password != "old-password":
            raise RuntimeError("database rollback failed")
        super().set_database_password(password)


class RuntimeChangeTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "POSIX inherited lock behavior")
    def test_sigkill_coordinator_keeps_installer_lock_held_by_adapter(self) -> None:
        import fcntl

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            lock_file = root / "installer.lock"
            applying = root / "applying"
            adapter = root / "adapter.py"
            adapter.write_text(
                """
from pathlib import Path
import sys
import time

applying = Path(sys.argv[1])
stage = sys.argv[2]
if stage == "protect":
    print("recovery-point")
elif stage == "apply":
    applying.write_text("yes", encoding="utf-8")
    time.sleep(2)
""".strip()
                + "\n",
                encoding="utf-8",
            )
            runtime_script = Path(__file__).parents[1] / "lib" / "runtime_change.py"
            shell_command = (
                f'exec 9>"{lock_file}"; flock -n 9; '
                f'exec "{sys.executable}" "{runtime_script}" '
                f'run-command "sigkill test" - -- "{sys.executable}" '
                f'"{adapter}" "{applying}"'
            )
            process = subprocess.Popen(["bash", "-c", shell_command])
            deadline = time.time() + 5
            while not applying.exists() and time.time() < deadline:
                time.sleep(0.05)
            self.assertTrue(applying.exists())
            process.kill()
            process.wait(timeout=5)

            with lock_file.open("a+") as lock_handle:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                time.sleep(2.5)
                fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)

    @unittest.skipUnless(os.name == "posix", "POSIX signal behavior")
    def test_cli_signal_rolls_back_and_returns_a_signal_exit_code(self) -> None:
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
if stage == "protect":
    print("recovery-point")
elif stage == "apply":
    applying.write_text("yes", encoding="utf-8")
    time.sleep(30)
elif stage in {"rollback", "verify-rollback", "safe-stop"}:
    with order.open("a", encoding="utf-8") as output:
        output.write(stage + "\\n")
""".strip()
                + "\n",
                encoding="utf-8",
            )
            command = [
                sys.executable,
                str(Path(__file__).parents[1] / "lib" / "runtime_change.py"),
                "run-command",
                "signal test",
                "-",
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
                time.sleep(0.05)
            self.assertTrue(applying.exists())
            process.send_signal(signal.SIGTERM)
            try:
                stdout, stderr = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
                self.fail(
                    f"runtime change CLI did not exit after SIGTERM; "
                    f"stdout={stdout!r}, stderr={stderr!r}"
                )

            result = json.loads(stdout)
            self.assertEqual(process.returncode, 128 + signal.SIGTERM)
            self.assertEqual(result["outcome"], "rolled_back")
            self.assertEqual(result["failed_stage"], "apply")
            self.assertEqual(
                order.read_text(encoding="utf-8").splitlines(),
                ["rollback", "verify-rollback"],
            )

    @unittest.skipUnless(os.name == "posix", "POSIX process-group behavior")
    def test_stage_timeout_terminates_the_entire_adapter_process_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            descendant_marker = root / "descendant-finished"
            adapter = root / "adapter.py"
            adapter.write_text(
                """
import subprocess
import sys
import time

marker = sys.argv[1]
stage = sys.argv[2]
if stage == "plan":
    subprocess.Popen([
        sys.executable,
        "-c",
        "import pathlib,signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "time.sleep(1.5); pathlib.Path(r'%s').write_text('alive')" % marker,
    ])
elif stage == "safe-stop":
    pass
""".strip()
                + "\n",
                encoding="utf-8",
            )
            previous_timeout = os.environ.get("RUNTIME_CHANGE_STAGE_TIMEOUT")
            os.environ["RUNTIME_CHANGE_STAGE_TIMEOUT"] = "1"
            try:
                result = run_command_runtime_change(
                    "timeout test",
                    [sys.executable, str(adapter), str(descendant_marker)],
                )
            finally:
                if previous_timeout is None:
                    os.environ.pop("RUNTIME_CHANGE_STAGE_TIMEOUT", None)
                else:
                    os.environ["RUNTIME_CHANGE_STAGE_TIMEOUT"] = previous_timeout

            time.sleep(1)
            self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
            self.assertEqual(result.failed_stage, "plan")
            self.assertIn("exceeded 1 second timeout", result.error or "")
            self.assertFalse(descendant_marker.exists())

    def test_command_adapter_commits_through_the_runtime_change_seam(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            state_file = root / "state.txt"
            state_file.write_text("old", encoding="utf-8")
            adapter = root / "adapter.py"
            adapter.write_text(
                """
from pathlib import Path
import sys

state = Path(sys.argv[1])
stage = sys.argv[2]
if stage == "protect":
    print(state.read_text(encoding="utf-8"))
elif stage == "apply":
    state.write_text("new", encoding="utf-8")
elif stage == "verify":
    assert state.read_text(encoding="utf-8") == "new"
elif stage == "commit":
    state.with_suffix(".committed").write_text("yes", encoding="utf-8")
elif stage == "rollback":
    state.write_text(sys.argv[3], encoding="utf-8")
elif stage == "verify-rollback":
    assert state.read_text(encoding="utf-8") == sys.argv[3]
elif stage == "safe-stop":
    state.write_text("stopped", encoding="utf-8")
""".strip()
                + "\n",
                encoding="utf-8",
            )

            result = run_command_runtime_change(
                "settings draft",
                [sys.executable, str(adapter), str(state_file)],
                log_reference="runtime.log",
            )

            self.assertEqual(result.outcome, RuntimeChangeOutcome.COMMITTED)
            self.assertEqual(state_file.read_text(encoding="utf-8"), "new")
            self.assertTrue(state_file.with_suffix(".committed").is_file())

    def test_command_adapter_failure_restores_and_verifies_recovery_point(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            state_file = root / "state.txt"
            state_file.write_text("old", encoding="utf-8")
            adapter = root / "adapter.py"
            adapter.write_text(
                """
from pathlib import Path
import sys

state = Path(sys.argv[1])
stage = sys.argv[2]
if stage == "protect":
    print(state.read_text(encoding="utf-8"))
elif stage == "apply":
    state.write_text("partial", encoding="utf-8")
    raise RuntimeError("injected apply failure")
elif stage == "rollback":
    state.write_text(sys.argv[3], encoding="utf-8")
elif stage == "verify-rollback":
    assert state.read_text(encoding="utf-8") == sys.argv[3]
elif stage == "safe-stop":
    state.write_text("stopped", encoding="utf-8")
""".strip()
                + "\n",
                encoding="utf-8",
            )

            result = run_command_runtime_change(
                "settings draft",
                [sys.executable, str(adapter), str(state_file)],
            )

            self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
            self.assertEqual(result.failed_stage, "apply")
            self.assertTrue(result.rollback_verified)
            self.assertEqual(state_file.read_text(encoding="utf-8"), "old")

    def test_verified_runtime_change_commits(self) -> None:
        adapter = SuccessfulRuntimeAdapter()

        result = run_runtime_change("apply settings", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.COMMITTED)
        self.assertIsNone(result.failed_stage)
        self.assertEqual(result.safe_next_action, "No further action is required.")
        self.assertIsNone(result.log_reference)
        self.assertEqual(adapter.runtime, "new")
        self.assertEqual(adapter.applied, "new")

    def test_failed_change_returns_verified_rollback(self) -> None:
        adapter = FailingApplyAdapter()

        result = run_runtime_change(
            "deploy", adapter, log_reference="/var/log/installer/runtime.log"
        )

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "apply")
        self.assertTrue(result.rollback_verified)
        self.assertIn("compose failed", result.error or "")
        self.assertEqual(
            result.safe_next_action,
            "Fix the reported error, then retry the change.",
        )
        self.assertEqual(result.log_reference, "/var/log/installer/runtime.log")
        self.assertEqual(adapter.runtime, "old")
        self.assertEqual(adapter.applied, "old")

    def test_invalid_plan_leaves_the_existing_runtime_untouched(self) -> None:
        adapter = FailingPlanAdapter()

        result = run_runtime_change("repeat install", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "plan")
        self.assertFalse(result.rollback_verified)
        self.assertIn("invalid plan", result.error or "")
        self.assertEqual(adapter.runtime, "old")

    def test_missing_protection_leaves_the_existing_runtime_untouched(self) -> None:
        adapter = FailingProtectionAdapter()

        result = run_runtime_change("repeat install", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "protect")
        self.assertFalse(result.rollback_verified)
        self.assertIn("snapshot failed", result.error or "")
        self.assertEqual(adapter.runtime, "old")

    def test_failed_verification_restores_the_previous_runtime(self) -> None:
        adapter = FailingVerificationAdapter()

        result = run_runtime_change("apply settings", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "verify")
        self.assertTrue(result.rollback_verified)
        self.assertIn("health check failed", result.error or "")
        self.assertEqual(adapter.runtime, "old")
        self.assertEqual(adapter.applied, "old")

    def test_failed_commit_restores_the_previous_runtime(self) -> None:
        adapter = FailingCommitAdapter()

        result = run_runtime_change("repeat install", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "commit")
        self.assertTrue(result.rollback_verified)
        self.assertIn("state commit failed", result.error or "")
        self.assertEqual(adapter.runtime, "old")
        self.assertEqual(adapter.applied, "old")

    def test_failed_rollback_verification_safely_stops_the_runtime(self) -> None:
        adapter = FailingRollbackVerificationAdapter()

        result = run_runtime_change("deploy", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "verify_rollback")
        self.assertFalse(result.rollback_verified)
        self.assertIn("compose failed", result.error or "")
        self.assertIn("rollback health check failed", result.error or "")
        self.assertEqual(
            result.safe_next_action,
            "Restore the affected runtime before retrying the change.",
        )
        self.assertEqual(adapter.runtime, "stopped")

    def test_failed_safe_stop_is_returned_as_a_structured_result(self) -> None:
        adapter = FailingRollbackAndSafeStopAdapter()

        result = run_runtime_change("repeat install", adapter)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "safe_stop")
        self.assertFalse(result.rollback_verified)
        self.assertIn("compose failed", result.error or "")
        self.assertIn("rollback failed", result.error or "")
        self.assertIn("stop command failed", result.error or "")
        self.assertEqual(
            result.safe_next_action,
            "Stop the affected runtime manually before retrying the change.",
        )

    def test_postgres_credential_rotation_commits_database_and_bot_password(self) -> None:
        gateway = PostgresGateway()
        new_password = "n" * 64

        result = rotate_postgres_credentials(
            gateway,
            new_password,
            log_reference="/var/log/installer/postgres-rotation.log",
        )

        self.assertEqual(result.outcome, RuntimeChangeOutcome.COMMITTED)
        self.assertEqual(gateway.database_password, new_password)
        self.assertEqual(gateway.bot_password, new_password)
        self.assertEqual(gateway.applied_password, new_password)
        self.assertTrue(gateway.bot_running)
        self.assertTrue(gateway.old_connection_verified)
        self.assertEqual(gateway.verified_passwords, ["old-password", new_password])
        self.assertEqual(
            result.log_reference, "/var/log/installer/postgres-rotation.log"
        )

    def test_postgres_credential_apply_failure_restores_old_credentials(self) -> None:
        gateway = FailingCredentialApplyGateway()

        result = rotate_postgres_credentials(gateway, "n" * 64)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.ROLLED_BACK)
        self.assertEqual(result.failed_stage, "apply")
        self.assertTrue(result.rollback_verified)
        self.assertIn("bot secret write failed", result.error or "")
        self.assertEqual(gateway.database_password, "old-password")
        self.assertEqual(gateway.bot_password, "old-password")
        self.assertEqual(gateway.applied_password, "old-password")
        self.assertTrue(gateway.bot_running)

    def test_postgres_credential_rollback_failure_safely_stops_bot(self) -> None:
        gateway = FailingCredentialRollbackGateway()

        result = rotate_postgres_credentials(gateway, "n" * 64)

        self.assertEqual(result.outcome, RuntimeChangeOutcome.SAFELY_STOPPED)
        self.assertEqual(result.failed_stage, "rollback")
        self.assertFalse(result.rollback_verified)
        self.assertIn("bot secret write failed", result.error or "")
        self.assertIn("database rollback failed", result.error or "")
        self.assertEqual(
            result.safe_next_action,
            "Restore the affected runtime before retrying the change.",
        )
        self.assertFalse(gateway.bot_running)


if __name__ == "__main__":
    unittest.main()
