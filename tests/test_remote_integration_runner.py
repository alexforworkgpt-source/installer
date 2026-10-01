from __future__ import annotations

import importlib.util
import hashlib
import contextlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).parent / "integration" / "run-remote.py"
SPEC = importlib.util.spec_from_file_location("remote_integration_runner", SCRIPT)
assert SPEC and SPEC.loader
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RemoteIntegrationRunnerTests(unittest.TestCase):
    def git(self, workspace: Path, *arguments: str) -> str:
        return subprocess.run(
            ["git", "-C", str(workspace), *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def committed_workspace(self, root: Path) -> Path:
        workspace = root / "installer"
        workspace.mkdir()
        self.git(workspace, "init", "--quiet")
        self.git(workspace, "config", "user.name", "Integration fixture")
        self.git(workspace, "config", "user.email", "fixture@example.test")
        self.git(workspace, "config", "commit.gpgsign", "false")
        self.git(workspace, "config", "core.hooksPath", str(root / "no-hooks"))
        self.git(workspace, "config", "core.autocrlf", "false")
        (workspace / "README.md").write_text("public", encoding="utf-8")
        (workspace / ".gitignore").write_text(
            "server*.env\nenv.txt\n.scratch/\nstate/\n__pycache__/\n",
            encoding="utf-8",
        )
        self.git(workspace, "add", "README.md", ".gitignore")
        self.git(workspace, "commit", "--quiet", "-m", "Public fixture")
        return workspace

    def test_disposable_confirmation_is_explicit_and_in_memory_only(self) -> None:
        config = {"SERVER_IS_DISPOSABLE": "no"}

        unchanged = RUNNER.apply_disposable_confirmation(config, confirmed=False)
        confirmed = RUNNER.apply_disposable_confirmation(config, confirmed=True)

        self.assertEqual(unchanged["SERVER_IS_DISPOSABLE"], "no")
        self.assertEqual(confirmed["SERVER_IS_DISPOSABLE"], "yes")
        self.assertEqual(config["SERVER_IS_DISPOSABLE"], "no")

    def test_source_archive_excludes_private_environment_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = self.committed_workspace(root)
            (workspace / "server.env").write_text("private", encoding="utf-8")
            (workspace / "server.prod.env").write_text("production-private", encoding="utf-8")
            (workspace / "env.txt").write_text("private", encoding="utf-8")
            archive = root / "installer.tar.gz"

            RUNNER.create_source_archive(workspace, archive)

            with tarfile.open(archive, "r:gz") as bundle:
                names = set(bundle.getnames())
            self.assertIn("README.md", names)
            self.assertNotIn("server.env", names)
            self.assertNotIn("server.prod.env", names)
            self.assertNotIn("env.txt", names)

    def test_source_archive_rejects_uncommitted_tracked_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = self.committed_workspace(root)
            (workspace / "README.md").write_text("untested change", encoding="utf-8")
            archive = root / "installer.tar.gz"

            with self.assertRaisesRegex(RUNNER.RemoteIntegrationError, "uncommitted"):
                RUNNER.create_source_archive(workspace, archive)

            self.assertFalse(archive.exists())

    def test_source_archive_reports_and_packages_exact_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = self.committed_workspace(root)
            expected_sha = self.git(workspace, "rev-parse", "HEAD")
            archive = root / "installer.tar.gz"

            identity = RUNNER.create_source_archive(
                workspace, archive, expected_sha=expected_sha
            )

            self.assertEqual(identity["installer_sha"], expected_sha)
            self.assertEqual(
                identity["installer_tree_sha"],
                self.git(workspace, "rev-parse", "HEAD^{tree}"),
            )
            self.assertEqual(
                identity["archive_sha256"], hashlib.sha256(archive.read_bytes()).hexdigest()
            )
            with tarfile.open(archive, "r:gz") as bundle:
                self.assertEqual(bundle.pax_headers["comment"], expected_sha)
                self.assertEqual(bundle.extractfile("README.md").read(), b"public")

    def test_run_requires_source_sha_before_environment_or_ssh(self) -> None:
        with (
            mock.patch.object(RUNNER, "parse_env") as parse_environment,
            mock.patch.object(RUNNER, "RemoteSession") as session,
            contextlib.redirect_stderr(io.StringIO()),
        ):
            with self.assertRaises(SystemExit) as error:
                RUNNER.main(["run", "--confirm-disposable-server"])

        self.assertEqual(error.exception.code, 2)
        parse_environment.assert_not_called()
        session.assert_not_called()

    def test_run_rejects_wrong_source_sha_before_environment_or_ssh(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = self.committed_workspace(Path(temp_dir))
            with (
                mock.patch.object(RUNNER, "WORKSPACE", workspace),
                mock.patch.object(RUNNER, "parse_env") as parse_environment,
                mock.patch.object(RUNNER, "RemoteSession") as session,
            ):
                with self.assertRaisesRegex(RUNNER.RemoteIntegrationError, "does not match"):
                    RUNNER.main(["run", "--source-sha", "0" * 40])

            parse_environment.assert_not_called()
            session.assert_not_called()

    def test_source_archive_rejects_untracked_public_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = self.committed_workspace(root)
            (workspace / "new-helper.py").write_text("untested source", encoding="utf-8")
            archive = root / "installer.tar.gz"

            with self.assertRaisesRegex(RUNNER.RemoteIntegrationError, "untracked"):
                RUNNER.create_source_archive(workspace, archive)

            self.assertFalse(archive.exists())

    def test_source_archive_excludes_tracked_private_and_generated_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = self.committed_workspace(root)
            private_paths = (
                "server.prod.env", ".env.local", "env.txt", "nested/tenant.env",
                ".scratch/notes.md", "state/install.state", "__pycache__/module.pyc",
                ".playwright-mcp/screenshot.txt",
            )
            for relative in private_paths:
                path = workspace / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fictional-private-sentinel", encoding="utf-8")
            self.git(workspace, "add", "--force", "--", *private_paths)
            self.git(workspace, "commit", "--quiet", "-m", "Private fixture")
            archive = root / "installer.tar.gz"

            RUNNER.create_source_archive(workspace, archive)

            with tarfile.open(archive, "r:gz") as bundle:
                self.assertEqual(set(bundle.getnames()), {"README.md", ".gitignore"})
                for member in bundle.getmembers():
                    self.assertNotIn(b"fictional-private-sentinel", bundle.extractfile(member).read())

    def test_source_archive_is_reproducible_for_one_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            workspace = self.committed_workspace(root)
            first = root / "first.tar.gz"
            second = root / "second.tar.gz"

            first_identity = RUNNER.create_source_archive(workspace, first)
            second_identity = RUNNER.create_source_archive(workspace, second)

            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first_identity, second_identity)

    def test_remote_environment_forwards_release_manifest_source(self) -> None:
        manifest_source = (
            "https://github.com/example/installer/releases/download/"
            "test-candidate/release.json"
        )
        config = {
            "RUN_INSTALLER_INTEGRATION": "1",
            "TEST_PROJECT_ROOT": "/opt/bot-stack-integration",
            "TEST_HOOK_DOMAIN": "hooks.example.test",
            "TEST_APP_DOMAIN": "app.example.test",
            "TEST_BOT_TOKEN": "test-token",
            "TEST_BOT_USERNAME": "test_bot",
            "TEST_ADMIN_IDS": "123456789",
            "TEST_REMNAWAVE_API_URL": "https://panel.example.test",
            "TEST_REMNAWAVE_API_KEY": "test-api-key",
            "TEST_REMNAWAVE_SECRET_KEY": "test-secret-key",
            "TEST_REMNAWAVE_WEBHOOK_SECRET": "test-webhook-secret",
            "TEST_RELEASE_MANIFEST_SOURCE": manifest_source,
        }

        environment = RUNNER.remote_environment(config).decode("utf-8").splitlines()

        self.assertIn(
            f"TEST_RELEASE_MANIFEST_SOURCE={manifest_source}",
            environment,
        )


if __name__ == "__main__":
    unittest.main()
