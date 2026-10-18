from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from lib.env_helper import parse_env


class PostgresStateRestoreTests(unittest.TestCase):
    def test_restored_state_keeps_verified_pg18_runtime_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = root / "state"
            state.mkdir()
            for name in ("bot.env", "cabinet.env", "docker-compose.yml"):
                (state / name).write_text("", encoding="utf-8")
            result = subprocess.run([
                sys.executable, "lib/env_helper.py", "restore-state", str(root),
                str(state / "install.state"), str(state / "bot.env"), str(state / "cabinet.env"),
                "https://example.test/bot.git", "https://example.test/cabinet.git",
                str(root / "repos/bot-backend"), str(root / "repos/bot-cabinet"),
                "legacy-project", "postgres@sha256:fixture18", "18",
                "legacy-project_postgres18_data-upgrade1", "redis@sha256:fixture",
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            restored = parse_env(state / "install.state")
            self.assertEqual(restored["COMPOSE_PROJECT_NAME"], "legacy-project")
            self.assertEqual(restored["POSTGRES_MAJOR"], "18")
            self.assertEqual(restored["POSTGRES_VOLUME_NAME"], "legacy-project_postgres18_data-upgrade1")
            self.assertEqual(restored["POSTGRES_IMAGE"], "postgres@sha256:fixture18")
