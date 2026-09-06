from __future__ import annotations

import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest


SCRIPT = Path(__file__).parent / "integration" / "run-remote.py"
SPEC = importlib.util.spec_from_file_location("remote_integration_runner", SCRIPT)
assert SPEC and SPEC.loader
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RemoteIntegrationRunnerTests(unittest.TestCase):
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
            workspace = root / "installer"
            workspace.mkdir()
            (workspace / "README.md").write_text("public", encoding="utf-8")
            (workspace / "server.env").write_text("private", encoding="utf-8")
            (workspace / "env.txt").write_text("private", encoding="utf-8")
            archive = root / "installer.tar.gz"

            RUNNER.create_source_archive(workspace, archive)

            with tarfile.open(archive, "r:gz") as bundle:
                names = set(bundle.getnames())
            self.assertIn("README.md", names)
            self.assertNotIn("server.env", names)
            self.assertNotIn("env.txt", names)

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
