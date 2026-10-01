import json
import hashlib
from pathlib import Path
import tempfile
import unittest

from test_publication_identity import git, repository


SOURCE = {"installer_sha": "a" * 40, "installer_tree_sha": "b" * 40,
          "archive_sha256": "c" * 64}
PROTECTED = {
    "bot_repository": "https://github.com/OWNER/bot.git", "bot_sha": "d" * 40,
    "postgres_image": f"postgres@sha256:{'e' * 64}",
    "redis_image": f"redis@sha256:{'f' * 64}",
    "backend_contract": "1", "bot_backend_contract": "1", "cabinet_backend_contract": "1",
    "configuration_schema": 1, "manifest_schema": 2, "migration_policy": "rollback-compatible",
    "target_os": "ubuntu-24.04", "target_platform": "linux/amd64",
}


def record() -> dict:
    return {"schema_version": 1, "kind": "installer-lifecycle", "result": "PASS",
            "installer": dict(SOURCE), "protected": dict(PROTECTED),
            "evidence_url": "https://github.com/OWNER/installer/actions/runs/123",
            "log_path": "releases/evidence/lifecycle.log",
            "log_sha256": hashlib.sha256(b"fictional lifecycle log").hexdigest()}


class LifecycleEvidenceTests(unittest.TestCase):
    def test_missing_committed_log_cannot_be_replaced_by_a_pass_json(self) -> None:
        from lib.lifecycle_evidence import read_reviewed_evidence

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository(root)
            path = root / "releases/evidence/lifecycle.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(record()), encoding="utf-8")
            git(root, "add", "releases/evidence/lifecycle.json")
            git(root, "commit", "--quiet", "-m", "Incomplete evidence fixture")
            sha = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/main", sha)
            with self.assertRaises(ValueError):
                read_reviewed_evidence(root, sha, "releases/evidence/lifecycle.json", "main")

    def test_incomplete_failed_or_unsupported_proof_is_rejected(self) -> None:
        from lib.lifecycle_evidence import verify_lifecycle_evidence

        for field, value in (("result", "BLOCKED"), ("schema_version", True),
                             ("evidence_url", ""), ("installer", {}), ("protected", {})):
            changed = record()
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify_lifecycle_evidence(changed, SOURCE, PROTECTED)
        unsupported = dict(PROTECTED, target_platform="linux/arm64")
        changed = record()
        changed["protected"] = unsupported
        with self.assertRaises(ValueError):
            verify_lifecycle_evidence(changed, SOURCE, unsupported)

    def test_record_must_exist_at_exact_commit_on_trusted_default_branch(self) -> None:
        from lib.lifecycle_evidence import read_reviewed_evidence

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository(root)
            path = root / "releases/evidence/lifecycle.json"
            path.parent.mkdir(parents=True)
            path.write_text(json.dumps(record()), encoding="utf-8")
            (path.parent / "lifecycle.log").write_bytes(b"fictional lifecycle log")
            git(root, "add", "releases/evidence/lifecycle.json", "releases/evidence/lifecycle.log")
            git(root, "commit", "--quiet", "-m", "Reviewed proof fixture")
            reviewed_sha = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/main", reviewed_sha)
            self.assertEqual(read_reviewed_evidence(
                root, reviewed_sha, "releases/evidence/lifecycle.json", "main"
            ), record())
            git(root, "commit", "--quiet", "--allow-empty", "-m", "Unreviewed fixture")
            with self.assertRaises(ValueError):
                read_reviewed_evidence(root, git(root, "rev-parse", "HEAD"),
                                       "releases/evidence/lifecycle.json", "main")
            for invalid_path in ("server.prod.env", "releases/evidence/../../server.prod.env"):
                with self.assertRaises(ValueError):
                    read_reviewed_evidence(root, reviewed_sha, invalid_path, "main")
            (path.parent / "lifecycle.log").write_bytes(b"altered fictional log")
            git(root, "add", "releases/evidence/lifecycle.log")
            git(root, "commit", "--quiet", "-m", "Changed log fixture")
            changed_sha = git(root, "rev-parse", "HEAD")
            git(root, "update-ref", "refs/remotes/origin/main", changed_sha)
            with self.assertRaisesRegex(ValueError, "log checksum"):
                read_reviewed_evidence(root, changed_sha, "releases/evidence/lifecycle.json", "main")

    def test_proof_is_bound_to_source_and_protected_stack(self) -> None:
        from lib.lifecycle_evidence import verify_lifecycle_evidence

        verify_lifecycle_evidence(record(), SOURCE, PROTECTED)
        for section, key, value in (
            ("installer", "installer_sha", "f" * 40),
            ("installer", "installer_tree_sha", "f" * 40),
            ("installer", "archive_sha256", "f" * 64),
            ("protected", "bot_sha", "f" * 40),
            ("protected", "redis_image", f"redis@sha256:{'a' * 64}"),
            ("protected", "postgres_image", f"postgres@sha256:{'a' * 64}"),
            ("protected", "target_os", "ubuntu-22.04"),
            ("protected", "backend_contract", "2"),
            ("protected", "configuration_schema", 2),
        ):
            with self.subTest(key=key):
                changed = record()
                changed[section][key] = value
                with self.assertRaises(ValueError):
                    verify_lifecycle_evidence(changed, SOURCE, PROTECTED)
