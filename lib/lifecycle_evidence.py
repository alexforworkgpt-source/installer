"""Validate reviewed lifecycle evidence separately from the runtime manifest."""

import json
import hashlib
from pathlib import Path, PurePosixPath
import re

from lib.publication_identity import git_bytes, git_value


PROTECTED_FIELDS = {
    "bot_repository", "bot_sha", "postgres_image", "redis_image", "backend_contract",
    "bot_backend_contract", "cabinet_backend_contract", "configuration_schema",
    "manifest_schema", "migration_policy", "target_os", "target_platform",
}


def validate_protected_stack(protected: dict) -> None:
    if not isinstance(protected, dict) or set(protected) != PROTECTED_FIELDS:
        raise ValueError("lifecycle protected stack fields are incomplete or unsupported")
    if (protected["target_os"] != "ubuntu-24.04" or protected["target_platform"] != "linux/amd64"
            or any(protected[key] != "1" for key in (
                "backend_contract", "bot_backend_contract", "cabinet_backend_contract"))
            or type(protected["configuration_schema"]) is not int or protected["configuration_schema"] != 1
            or type(protected["manifest_schema"]) is not int or protected["manifest_schema"] != 2
            or protected["migration_policy"] not in ("rollback-compatible", "forward-only")):
        raise ValueError("lifecycle protected stack contract or platform is unsupported")
    patterns = {
        "bot_sha": r"[0-9a-f]{40}",
        "bot_repository": r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?",
        "postgres_image": r"[^@\s]+@sha256:[0-9a-f]{64}",
        "redis_image": r"[^@\s]+@sha256:[0-9a-f]{64}",
    }
    for key, pattern in patterns.items():
        if not isinstance(protected[key], str) or not re.fullmatch(pattern, protected[key]):
            raise ValueError(f"lifecycle protected {key} is invalid")


def verify_lifecycle_evidence(record: dict, source: dict, protected: dict) -> None:
    if not isinstance(record, dict) or set(record) != {
        "schema_version", "kind", "result", "installer", "protected", "evidence_url", "log_path", "log_sha256"
    }:
        raise ValueError("lifecycle evidence fields are incomplete or unsupported")
    if (type(record["schema_version"]) is not int or record["schema_version"] != 1
            or record["kind"] != "installer-lifecycle" or record["result"] != "PASS"):
        raise ValueError("lifecycle evidence must record a successful supported gate")
    validate_protected_stack(protected)
    if set(source) != {"installer_sha", "installer_tree_sha", "archive_sha256"}:
        raise ValueError("lifecycle source identity fields are incomplete")
    for key, length in (("installer_sha", 40), ("installer_tree_sha", 40), ("archive_sha256", 64)):
        if not isinstance(source[key], str) or not re.fullmatch(rf"[0-9a-f]{{{length}}}", source[key]):
            raise ValueError(f"lifecycle source {key} is invalid")
    if record["installer"] != source:
        raise ValueError("lifecycle source identity does not match Installer snapshot")
    if record["protected"] != protected:
        raise ValueError("lifecycle protected stack does not match selected Bundle")
    if not isinstance(record["evidence_url"], str) or not re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/"
        r"(?:actions/runs/[0-9]+|blob/[0-9a-f]{40}/releases/evidence/[A-Za-z0-9_./-]+)",
        record["evidence_url"],
    ):
        raise ValueError("lifecycle evidence must reference a public run or exact committed log")
    validate_log_identity(record)


def validate_log_identity(record: dict) -> None:
    path = record.get("log_path")
    digest = record.get("log_sha256")
    if (not isinstance(path, str)
            or not re.fullmatch(r"releases/evidence/[A-Za-z0-9_./-]+\.(?:log|txt|md)", path)
            or ".." in PurePosixPath(path).parts
            or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
        raise ValueError("lifecycle evidence must bind a public redacted log and its checksum")


def read_reviewed_evidence(workspace: Path, commit: str, path: str, default_branch: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("lifecycle evidence commit must be an exact SHA")
    if (not re.fullmatch(r"releases/evidence/[A-Za-z0-9_./-]+\.json", path)
            or ".." in PurePosixPath(path).parts):
        raise ValueError("lifecycle evidence must be a public releases/evidence JSON record")
    git_value(workspace, "check-ref-format", f"refs/heads/{default_branch}")
    git_value(workspace, "merge-base", "--is-ancestor", commit,
              f"refs/remotes/origin/{default_branch}")
    try:
        record = json.loads(git_value(workspace, "show", f"{commit}:{path}"))
    except json.JSONDecodeError as error:
        raise ValueError("reviewed lifecycle evidence is invalid JSON") from error
    if not isinstance(record, dict):
        raise ValueError("reviewed lifecycle evidence must be an object")
    validate_log_identity(record)
    log = git_bytes(workspace, "show", f"{commit}:{record['log_path']}")
    if hashlib.sha256(log).hexdigest() != record["log_sha256"]:
        raise ValueError("reviewed lifecycle log checksum does not match")
    return record
