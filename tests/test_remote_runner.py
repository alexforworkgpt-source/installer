from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


RUNNER_PATH = Path(__file__).parent / "integration/run-remote.py"
SPEC = importlib.util.spec_from_file_location("remote_runner", RUNNER_PATH)
REMOTE_RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REMOTE_RUNNER)


class RemoteRunnerTests(unittest.TestCase):
    def test_compose_project_name_uses_exact_posix_project_root(self) -> None:
        self.assertEqual(
            REMOTE_RUNNER.compose_project_name("/opt/bot-stack-integration"),
            "bedolaga-bot-stack-integration-20eb7c07",
        )


if __name__ == "__main__":
    unittest.main()
