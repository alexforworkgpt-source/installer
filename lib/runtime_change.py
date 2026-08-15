from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time
from typing import Any, Protocol


_ACTIVE_COMMAND_PROCESS: subprocess.Popen[str] | None = None


def interrupt_active_command() -> None:
    process = _ACTIVE_COMMAND_PROCESS
    if process is None:
        return
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    elif process.poll() is None:
        process.kill()


class RuntimeChangeOutcome(str, Enum):
    COMMITTED = "committed"
    ROLLED_BACK = "rolled_back"
    SAFELY_STOPPED = "safely_stopped"


@dataclass(frozen=True)
class RuntimeChangeResult:
    name: str
    outcome: RuntimeChangeOutcome
    failed_stage: str | None
    error: str | None
    rollback_verified: bool
    safe_next_action: str
    log_reference: str | None = None


class RuntimeChangeAdapter(Protocol):
    def plan(self) -> None: ...

    def protect(self) -> Any: ...

    def apply(self) -> None: ...

    def verify(self) -> None: ...

    def commit(self) -> None: ...

    def rollback(self, recovery_point: Any) -> None: ...

    def verify_rollback(self, recovery_point: Any) -> None: ...

    def safe_stop(self) -> None: ...


class CommandStageRunner:
    def __init__(self, command: list[str]) -> None:
        if not command:
            raise ValueError("adapter command must not be empty")
        self.command = command
        self.timeout_seconds = int(os.environ.get("RUNTIME_CHANGE_STAGE_TIMEOUT", "1800"))

    def run(self, stage: str, *args: str) -> str:
        global _ACTIVE_COMMAND_PROCESS
        process: subprocess.Popen[str] | None = None
        inherited_lock_fds: tuple[int, ...] = ()
        if os.name == "posix":
            try:
                os.fstat(9)
            except OSError:
                pass
            else:
                inherited_lock_fds = (9,)

        def terminate_process_tree() -> None:
            if process is None:
                return
            if os.name == "posix":
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                time.sleep(0.2)
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                return
            if process.poll() is None:
                process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                if process.stdout is not None:
                    process.stdout.close()
                if process.stderr is not None:
                    process.stderr.close()
                process.wait()

        try:
            process = subprocess.Popen(
                [*self.command, stage, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                start_new_session=os.name == "posix",
                pass_fds=inherited_lock_fds,
            )
            _ACTIVE_COMMAND_PROCESS = process
            stdout, stderr = process.communicate(timeout=self.timeout_seconds)
        except subprocess.TimeoutExpired as error:
            terminate_process_tree()
            raise RuntimeError(
                f"{stage} exceeded {self.timeout_seconds} second timeout"
            ) from error
        except BaseException:
            terminate_process_tree()
            raise
        finally:
            if _ACTIVE_COMMAND_PROCESS is process:
                _ACTIVE_COMMAND_PROCESS = None
        assert process is not None
        if process.returncode != 0:
            error = stderr.strip() or stdout.strip() or f"{stage} failed"
            raise RuntimeError(error)
        return stdout.strip()


class CommandRuntimeChangeAdapter:
    def __init__(self, command: list[str]) -> None:
        self.runner = CommandStageRunner(command)

    def protect(self) -> str:
        return self.runner.run("protect")

    def plan(self) -> None:
        self.runner.run("plan")

    def apply(self) -> None:
        self.runner.run("apply")

    def verify(self) -> None:
        self.runner.run("verify")

    def commit(self) -> None:
        self.runner.run("commit")

    def rollback(self, recovery_point: str) -> None:
        self.runner.run("rollback", recovery_point)

    def verify_rollback(self, recovery_point: str) -> None:
        self.runner.run("verify-rollback", recovery_point)

    def safe_stop(self) -> None:
        self.runner.run("safe-stop")


@dataclass(frozen=True)
class PostgresCredentialState:
    database_password: str
    bot_password: str
    applied_password: str


class PostgresCredentialGateway(Protocol):
    def current_state(self) -> PostgresCredentialState: ...

    def set_database_password(self, password: str) -> None: ...

    def set_bot_password(self, password: str) -> None: ...

    def restart_bot(self) -> None: ...

    def verify_connection(self, password: str) -> None: ...

    def commit_applied_password(self, password: str) -> None: ...

    def safe_stop_bot(self) -> None: ...


class _PostgresCredentialRotation:
    def __init__(self, gateway: PostgresCredentialGateway, new_password: str) -> None:
        self.gateway = gateway
        self.new_password = new_password

    def protect(self) -> PostgresCredentialState:
        recovery_point = self.gateway.current_state()
        self.gateway.verify_connection(recovery_point.database_password)
        return recovery_point

    def plan(self) -> None:
        if not self.new_password:
            raise ValueError("new PostgreSQL password must not be empty")

    def apply(self) -> None:
        self.gateway.set_database_password(self.new_password)
        self.gateway.set_bot_password(self.new_password)
        self.gateway.restart_bot()

    def verify(self) -> None:
        self.gateway.verify_connection(self.new_password)

    def commit(self) -> None:
        self.gateway.commit_applied_password(self.new_password)

    def rollback(self, recovery_point: PostgresCredentialState) -> None:
        self.gateway.set_database_password(recovery_point.database_password)
        self.gateway.set_bot_password(recovery_point.bot_password)
        self.gateway.commit_applied_password(recovery_point.applied_password)
        self.gateway.restart_bot()

    def verify_rollback(self, recovery_point: PostgresCredentialState) -> None:
        self.gateway.verify_connection(recovery_point.database_password)

    def safe_stop(self) -> None:
        self.gateway.safe_stop_bot()


def run_runtime_change(
    name: str,
    adapter: RuntimeChangeAdapter,
    *,
    log_reference: str | None = None,
) -> RuntimeChangeResult:
    def rejected_before_mutation(
        failed_stage: str,
        error: str,
        safe_next_action: str,
    ) -> RuntimeChangeResult:
        return RuntimeChangeResult(
            name=name,
            outcome=RuntimeChangeOutcome.SAFELY_STOPPED,
            failed_stage=failed_stage,
            error=error,
            rollback_verified=False,
            safe_next_action=safe_next_action,
            log_reference=log_reference,
        )

    def safely_stopped(
        failed_stage: str,
        error: str,
        safe_next_action: str,
    ) -> RuntimeChangeResult:
        try:
            adapter.safe_stop()
        except Exception as safe_stop_error:
            return RuntimeChangeResult(
                name=name,
                outcome=RuntimeChangeOutcome.SAFELY_STOPPED,
                failed_stage="safe_stop",
                error=f"{error}; safe_stop failed: {safe_stop_error}",
                rollback_verified=False,
                safe_next_action=(
                    "Stop the affected runtime manually before retrying the change."
                ),
                log_reference=log_reference,
            )
        return RuntimeChangeResult(
            name=name,
            outcome=RuntimeChangeOutcome.SAFELY_STOPPED,
            failed_stage=failed_stage,
            error=error,
            rollback_verified=False,
            safe_next_action=safe_next_action,
            log_reference=log_reference,
        )

    try:
        adapter.plan()
    except Exception as error:
        return rejected_before_mutation(
            "plan",
            str(error),
            "Fix the change plan before retrying the operation.",
        )
    try:
        recovery_point = adapter.protect()
    except Exception as error:
        return rejected_before_mutation(
            "protect",
            str(error),
            "Inspect the failure before retrying the change.",
        )
    stage = "apply"
    try:
        adapter.apply()
        stage = "verify"
        adapter.verify()
        stage = "commit"
        adapter.commit()
    except Exception as error:
        try:
            adapter.rollback(recovery_point)
        except Exception as rollback_error:
            return safely_stopped(
                "rollback",
                f"{stage} failed: {error}; rollback failed: {rollback_error}",
                "Restore the affected runtime before retrying the change.",
            )
        try:
            adapter.verify_rollback(recovery_point)
        except Exception as rollback_error:
            return safely_stopped(
                "verify_rollback",
                (
                    f"{stage} failed: {error}; "
                    f"verify_rollback failed: {rollback_error}"
                ),
                "Restore the affected runtime before retrying the change.",
            )
        return RuntimeChangeResult(
            name=name,
            outcome=RuntimeChangeOutcome.ROLLED_BACK,
            failed_stage=stage,
            error=str(error),
            rollback_verified=True,
            safe_next_action="Fix the reported error, then retry the change.",
            log_reference=log_reference,
        )
    return RuntimeChangeResult(
        name=name,
        outcome=RuntimeChangeOutcome.COMMITTED,
        failed_stage=None,
        error=None,
        rollback_verified=False,
        safe_next_action="No further action is required.",
        log_reference=log_reference,
    )


def rotate_postgres_credentials(
    gateway: PostgresCredentialGateway,
    new_password: str,
    *,
    log_reference: str | None = None,
) -> RuntimeChangeResult:
    if len(new_password) < 32:
        raise ValueError("new PostgreSQL password must contain at least 32 characters")
    return run_runtime_change(
        "rotate PostgreSQL credentials",
        _PostgresCredentialRotation(gateway, new_password),
        log_reference=log_reference,
    )


def run_command_runtime_change(
    name: str,
    command: list[str],
    *,
    log_reference: str | None = None,
) -> RuntimeChangeResult:
    return run_runtime_change(
        name,
        CommandRuntimeChangeAdapter(command),
        log_reference=log_reference,
    )


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "show":
        result = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
        print(f"Outcome: {result['outcome']}")
        print(f"Failed stage: {result['failed_stage'] or '-'}")
        print(f"Rollback verified: {str(result['rollback_verified']).lower()}")
        print(f"Safe next action: {result['safe_next_action']}")
        print(f"Log reference: {result['log_reference'] or '-'}")
        return 0
    if len(argv) == 1 and argv[0] == "shell-assignments":
        result = json.load(sys.stdin)
        outcome = RuntimeChangeOutcome(result["outcome"])
        assignments = {
            "LAST_RUNTIME_CHANGE_RESULT": json.dumps(result, separators=(",", ":")),
            "LAST_RUNTIME_CHANGE_NAME": result["name"],
            "LAST_RUNTIME_CHANGE_OUTCOME": outcome.value,
            "LAST_RUNTIME_CHANGE_FAILED_STAGE": result["failed_stage"] or "-",
            "LAST_RUNTIME_CHANGE_ERROR": result["error"] or "-",
            "LAST_RUNTIME_CHANGE_ROLLBACK_VERIFIED": str(
                result["rollback_verified"]
            ).lower(),
            "LAST_RUNTIME_CHANGE_SAFE_NEXT_ACTION": result["safe_next_action"],
            "LAST_RUNTIME_CHANGE_LOG_REFERENCE": result["log_reference"] or "-",
        }
        for key, value in assignments.items():
            print(f"{key}={shlex.quote(str(value))}")
        return 0
    if len(argv) >= 5 and argv[0] == "run-command" and argv[3] == "--":
        interrupted_signal: int | None = None

        def interrupt_runtime_change(signum: int, _frame: object) -> None:
            nonlocal interrupted_signal
            interrupted_signal = signum
            interrupt_active_command()
            raise InterruptedError(f"runtime change interrupted by signal {signum}")

        signal.signal(signal.SIGINT, interrupt_runtime_change)
        signal.signal(signal.SIGTERM, interrupt_runtime_change)
        result = run_command_runtime_change(
            argv[1],
            argv[4:],
            log_reference=None if argv[2] == "-" else argv[2],
        )
        print(json.dumps(asdict(result), separators=(",", ":")))
        if interrupted_signal is not None:
            return 128 + interrupted_signal
        return 0
    if len(argv) != 8 or argv[0] != "result":
        print(
            "usage: runtime_change.py <result|show|shell-assignments|run-command> ...",
            file=sys.stderr,
        )
        return 2

    result = RuntimeChangeResult(
        name=argv[1],
        outcome=RuntimeChangeOutcome(argv[2]),
        failed_stage=None if argv[3] == "-" else argv[3],
        error=None if argv[4] == "-" else argv[4],
        rollback_verified=argv[5] == "true",
        safe_next_action=argv[6],
        log_reference=None if argv[7] == "-" else argv[7],
    )
    print(json.dumps(asdict(result), separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (KeyError, OSError, json.JSONDecodeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
