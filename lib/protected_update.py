from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum
import json
import signal
import sys
from typing import Protocol

if __package__:
    from lib.runtime_change import (
        CommandStageRunner,
        RuntimeChangeOutcome,
        interrupt_active_command,
    )
else:
    from runtime_change import (  # type: ignore[no-redef]
        CommandStageRunner,
        RuntimeChangeOutcome,
        interrupt_active_command,
    )


class MigrationPolicy(str, Enum):
    ROLLBACK_COMPATIBLE = "rollback-compatible"
    FORWARD_ONLY = "forward-only"


@dataclass(frozen=True)
class ProtectedUpdateResult:
    outcome: RuntimeChangeOutcome
    dump_reference: str | None
    before_revision: str | None
    after_revision: str | None
    failed_stage: str | None
    error: str | None
    rollback_verified: bool
    recovery_plan: str | None


class ProtectedUpdateGateway(Protocol):
    def create_verified_dump(self) -> str: ...

    def current_revision(self) -> str: ...

    def current_release(self) -> str: ...

    def apply_release(self) -> None: ...

    def verify_release(self) -> None: ...

    def commit_release(self) -> None: ...

    def rollback_release(self, previous_release: str, dump_reference: str) -> None: ...

    def restore_dump(self, dump_reference: str) -> None: ...

    def verify_rollback(
        self,
        previous_release: str,
        before_revision: str,
        dump_reference: str,
    ) -> None: ...

    def safe_stop(self) -> None: ...


class CommandProtectedUpdateGateway:
    def __init__(self, command: list[str]) -> None:
        self.runner = CommandStageRunner(command)
        self.dump_reference: str | None = None
        self.before_revision: str | None = None
        self.after_revision: str | None = None

    def create_verified_dump(self) -> str:
        dump_reference = self.runner.run("create-dump")
        if not dump_reference:
            raise RuntimeError("create-dump returned an empty dump reference")
        self.dump_reference = dump_reference
        return dump_reference

    def current_revision(self) -> str:
        revision = self.runner.run("current-revision")
        if not revision:
            raise RuntimeError("current-revision returned an empty revision")
        if self.before_revision is None:
            self.before_revision = revision
        else:
            self.after_revision = revision
        return revision

    def current_release(self) -> str:
        release = self.runner.run("current-release")
        if not release:
            raise RuntimeError("current-release returned an empty release")
        return release

    def apply_release(self) -> None:
        self.runner.run("apply-release")

    def verify_release(self) -> None:
        self.runner.run("verify-release")

    def commit_release(self) -> None:
        if not self.dump_reference or not self.before_revision or not self.after_revision:
            raise RuntimeError("protected update commit metadata is incomplete")
        self.runner.run(
            "commit-release",
            self.dump_reference,
            self.before_revision,
            self.after_revision,
        )

    def rollback_release(self, previous_release: str, dump_reference: str) -> None:
        self.runner.run("rollback-release", previous_release, dump_reference)

    def restore_dump(self, dump_reference: str) -> None:
        if not self.before_revision:
            raise RuntimeError("protected update rollback revision is missing")
        self.runner.run("restore-dump", dump_reference, self.before_revision)

    def verify_rollback(
        self,
        previous_release: str,
        before_revision: str,
        dump_reference: str,
    ) -> None:
        self.runner.run(
            "verify-rollback",
            previous_release,
            before_revision,
            dump_reference,
        )

    def safe_stop(self) -> None:
        self.runner.run("safe-stop")


def run_protected_update(
    gateway: ProtectedUpdateGateway,
    policy: MigrationPolicy,
) -> ProtectedUpdateResult:
    dump_reference: str | None = None
    before_revision: str | None = None
    previous_release: str | None = None

    def attempt_safe_stop() -> str | None:
        try:
            gateway.safe_stop()
        except Exception as error:
            return str(error)
        return None

    try:
        previous_release = gateway.current_release()
        before_revision = gateway.current_revision()
        dump_reference = gateway.create_verified_dump()
    except Exception as error:
        if previous_release is None:
            recovery_plan = (
                f"Protection failed before update: {error}. Determine the current release, "
                "then retry the update."
            )
        elif before_revision is None:
            recovery_plan = (
                f"Protection failed for release {previous_release}: {error}. Determine the "
                "current schema revision, then retry the update."
            )
        else:
            recovery_plan = (
                f"Protection failed before update of {previous_release}: {error}. Fix backup "
                "access, verify a database dump, then retry the update."
            )
        return ProtectedUpdateResult(
            outcome=RuntimeChangeOutcome.SAFELY_STOPPED,
            dump_reference=dump_reference,
            before_revision=before_revision,
            after_revision=None,
            failed_stage="protect",
            error=str(error),
            rollback_verified=False,
            recovery_plan=recovery_plan,
        )

    assert dump_reference is not None
    assert before_revision is not None
    assert previous_release is not None
    stage = "apply"
    try:
        gateway.apply_release()
        stage = "verify"
        gateway.verify_release()
        after_revision = gateway.current_revision()
        stage = "commit"
        gateway.commit_release()
    except Exception as error:
        try:
            after_revision = gateway.current_revision()
        except Exception:
            after_revision = None
        if policy is MigrationPolicy.FORWARD_ONLY:
            safe_stop_error = attempt_safe_stop()
            safe_stop_suffix = (
                f" Automatic safe stop failed: {safe_stop_error}. Stop runtime manually."
                if safe_stop_error
                else ""
            )
            return ProtectedUpdateResult(
                outcome=RuntimeChangeOutcome.SAFELY_STOPPED,
                dump_reference=dump_reference,
                before_revision=before_revision,
                after_revision=after_revision,
                failed_stage=stage,
                error=str(error),
                rollback_verified=False,
                recovery_plan=(
                    f"Forward-only update failed during {stage}: {error}. Runtime is "
                    f"stopped. Do not start release {previous_release} against schema "
                    f"revision {after_revision or 'unknown'}. Either complete a compatible "
                    f"forward migration, or restore {dump_reference} and deploy release "
                    f"{previous_release}; verify schema revision {before_revision} and full "
                    f"health before restart.{safe_stop_suffix}"
                ),
            )
        rollback_stage = "Rollback"
        try:
            gateway.rollback_release(previous_release, dump_reference)
            gateway.restore_dump(dump_reference)
            rollback_stage = "Rollback verification"
            gateway.verify_rollback(
                previous_release,
                before_revision,
                dump_reference,
            )
        except Exception as rollback_error:
            safe_stop_error = attempt_safe_stop()
            safe_stop_suffix = (
                f" Automatic safe stop failed: {safe_stop_error}. Stop runtime manually."
                if safe_stop_error
                else ""
            )
            return ProtectedUpdateResult(
                outcome=RuntimeChangeOutcome.SAFELY_STOPPED,
                dump_reference=dump_reference,
                before_revision=before_revision,
                after_revision=after_revision,
                failed_stage=stage,
                error=str(error),
                rollback_verified=False,
                recovery_plan=(
                    f"{rollback_stage} failed: {rollback_error}. Keep runtime stopped; restore "
                    f"{dump_reference}, deploy release {previous_release}, and verify "
                    f"schema revision {before_revision} before restart.{safe_stop_suffix}"
                ),
            )
        return ProtectedUpdateResult(
            outcome=RuntimeChangeOutcome.ROLLED_BACK,
            dump_reference=dump_reference,
            before_revision=before_revision,
            after_revision=after_revision,
            failed_stage=stage,
            error=str(error),
            rollback_verified=True,
            recovery_plan=None,
        )
    return ProtectedUpdateResult(
        outcome=RuntimeChangeOutcome.COMMITTED,
        dump_reference=dump_reference,
        before_revision=before_revision,
        after_revision=after_revision,
        failed_stage=None,
        error=None,
        rollback_verified=False,
        recovery_plan=None,
    )


def run_command_protected_update(
    command: list[str],
    policy: MigrationPolicy,
) -> ProtectedUpdateResult:
    return run_protected_update(CommandProtectedUpdateGateway(command), policy)


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[0] == "run-command" and argv[2] == "--":
        interrupted_signal: int | None = None

        def interrupt_protected_update(signum: int, _frame: object) -> None:
            nonlocal interrupted_signal
            interrupted_signal = signum
            interrupt_active_command()
            raise InterruptedError(f"protected update interrupted by signal {signum}")

        signal.signal(signal.SIGINT, interrupt_protected_update)
        signal.signal(signal.SIGTERM, interrupt_protected_update)
        result = run_command_protected_update(
            argv[3:],
            MigrationPolicy(argv[1]),
        )
        print(json.dumps(asdict(result), separators=(",", ":")))
        if interrupted_signal is not None:
            return 128 + interrupted_signal
        return 0
    print(
        "usage: protected_update.py run-command <migration-policy> -- <adapter-command...>",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
