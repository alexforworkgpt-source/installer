from __future__ import annotations

import importlib.util
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
