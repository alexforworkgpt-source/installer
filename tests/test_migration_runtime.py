from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from lib.env_helper import parse_env
from lib.migration_runtime import (
    adopt_completed_migration_runtime_identity,
    inspect_completed_migration_runtime_identity,
)


class CompletedMigrationRuntimeIdentityTests(unittest.TestCase):
    def test_adopts_exact_legacy_runtime_identity_without_removing_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            project_root = Path(temp) / "bot-stack"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            state_file = state_dir / "install.state"
            original_state = (
                f"PROJECT_ROOT='{project_root}'\n"
                "BOT_VERSION_REF='v4.1.0'\n"
                "CABINET_VERSION_REF='v1.66.0'\n"
            )
            state_file.write_text(original_state, encoding="utf-8")
            (state_dir / "migration.completed").write_text(
                "imported_at=2026-08-05T20:16:06Z\n",
                encoding="utf-8",
            )
            (project_root / ".migration-resources-created").write_text(
                "compose_project=bedolaga-232719bb124c\n"
                "volume=bedolaga-232719bb124c_postgres_data\n"
                "volume=bedolaga-232719bb124c_redis_data\n",
                encoding="utf-8",
            )
            override_file = state_dir / "migration-image.override.yml"
            override_contents = (
                "services:\n"
                "  postgres:\n"
                '    image: "bedolaga-migration/postgres:20260805-220129"\n'
                "  redis:\n"
                '    image: "bedolaga-migration/redis:20260805-220129"\n'
                "  bot:\n"
                '    image: "bedolaga-local/bot:v4.1.0"\n'
                "    restart: unless-stopped\n"
            )
            override_file.write_text(override_contents, encoding="utf-8")

            result = adopt_completed_migration_runtime_identity(project_root)

            self.assertTrue(result.adopted)
            self.assertEqual(result.compose_project, "bedolaga-232719bb124c")
            self.assertEqual(
                result.postgres_image,
                "bedolaga-migration/postgres:20260805-220129",
            )
            self.assertEqual(
                result.redis_image,
                "bedolaga-migration/redis:20260805-220129",
            )
            self.assertEqual(override_file.read_text(encoding="utf-8"), override_contents)

            adopted_state = parse_env(state_file)
            self.assertEqual(
                adopted_state["COMPOSE_PROJECT_NAME"], "bedolaga-232719bb124c"
            )
            self.assertEqual(
                adopted_state["POSTGRES_IMAGE"],
                "bedolaga-migration/postgres:20260805-220129",
            )
            self.assertEqual(
                adopted_state["REDIS_IMAGE"],
                "bedolaga-migration/redis:20260805-220129",
            )

            backups = list((state_dir / "migration-backups").glob("runtime-identity-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(
                (backups[0] / "install.state").read_text(encoding="utf-8"),
                original_state,
            )
            self.assertEqual(
                (backups[0] / "migration-image.override.yml").read_text(
                    encoding="utf-8"
                ),
                override_contents,
            )

            override_file.unlink()
            transitioned = inspect_completed_migration_runtime_identity(project_root)

            self.assertFalse(transitioned.override_present)
            self.assertEqual(transitioned.compose_project, "bedolaga-232719bb124c")

    def test_rejects_missing_override_before_runtime_identity_is_adopted(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            project_root = Path(temp) / "bot-stack"
            state_dir = project_root / "state"
            state_dir.mkdir(parents=True)
            (state_dir / "install.state").write_text(
                f"PROJECT_ROOT='{project_root}'\n",
                encoding="utf-8",
            )
            (state_dir / "migration.completed").write_text(
                "imported_at=2026-08-05T20:16:06Z\n",
                encoding="utf-8",
            )
            (project_root / ".migration-resources-created").write_text(
                "compose_project=bedolaga-232719bb124c\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "transitioned install.state"):
                inspect_completed_migration_runtime_identity(project_root)


if __name__ == "__main__":
    unittest.main()
