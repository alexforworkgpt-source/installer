from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from lib.installation_config import (
    load_installation_config,
    migrate_legacy_installation,
    render_installation,
)
from tests.test_installation_config import MINIMAL_BOT_ENV_KEYS, read_env


class LegacyInstallationMigrationTests(unittest.TestCase):
    def test_legacy_environment_becomes_minimal_with_advanced_override(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            legacy_bot = (
                "BOT_TOKEN=1234567890:valid-token\n"
                "BOT_USERNAME=bedolaga_bot\n"
                "ADMIN_IDS=123456789\n"
                "DEFAULT_LANGUAGE=ru\n"
                "TZ=Europe/Moscow # legacy inline comment\n"
                "POSTGRES_DB=remnawave_bot\n"
                "POSTGRES_USER=remnawave_user\n"
                f"POSTGRES_PASSWORD={'p' * 64}\n"
                "REMNAWAVE_API_URL=https://panel.example.com\n"
                "REMNAWAVE_API_KEY=api-key\n"
                "REMNAWAVE_SECRET_KEY=header:secret\n"
                f"REMNAWAVE_WEBHOOK_SECRET={'r' * 64}\n"
                "WEBHOOK_URL=https://hooks.example.com\n"
                f"WEBHOOK_SECRET_TOKEN={'w' * 64}\n"
                f"WEB_API_DEFAULT_TOKEN={'a' * 64}\n"
                "CABINET_URL=https://app.example.com\n"
                f"CABINET_JWT_SECRET={'j' * 64}\n"
                "SUPPORT_USERNAME=@custom_support\n"
                "LOG_LEVEL=DEBUG\n"
                "TELEGRAM_STARS_ENABLED=true\n"
                "HELEKET_ENABLED=true\n"
                "HELEKET_API_KEY=obsolete-secret\n"
            )
            legacy_cabinet = (
                "VITE_API_URL=/api\n"
                "VITE_TELEGRAM_BOT_USERNAME=bedolaga_bot\n"
                "VITE_APP_NAME=My VPN\n"
                "VITE_APP_LOGO=V\n"
            )
            bot_env.write_text(legacy_bot, encoding="utf-8")
            cabinet_env.write_text(legacy_cabinet, encoding="utf-8")

            result = migrate_legacy_installation(
                state_dir,
                application_defaults={
                    "SUPPORT_USERNAME": "@support",
                    "LOG_LEVEL": "INFO",
                    "TELEGRAM_STARS_ENABLED": "false",
                },
            )

            migrated_bot = read_env(bot_env)
            override = read_env(state_dir / "bot.override.env")
            self.assertEqual(set(migrated_bot), MINIMAL_BOT_ENV_KEYS)
            self.assertEqual(migrated_bot["TZ"], "Europe/Moscow")
            self.assertEqual(
                override,
                {
                    "SUPPORT_USERNAME": "@custom_support",
                    "LOG_LEVEL": "DEBUG",
                    "TELEGRAM_STARS_ENABLED": "true",
                },
            )
            self.assertEqual(
                (result.backup_dir / "bot.env").read_text(encoding="utf-8"),
                legacy_bot,
            )
            self.assertEqual(
                (result.backup_dir / "cabinet.env").read_text(encoding="utf-8"),
                legacy_cabinet,
            )

            override_before_regeneration = (state_dir / "bot.override.env").read_bytes()
            render_installation(
                load_installation_config(bot_env, cabinet_env),
                bot_env,
                cabinet_env,
            )
            self.assertEqual(
                (state_dir / "bot.override.env").read_bytes(),
                override_before_regeneration,
            )

    def test_missing_required_legacy_value_fails_after_backup_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            legacy_bot = (
                "BOT_USERNAME=bedolaga_bot\n"
                "ADMIN_IDS=123456789\n"
                "WEBHOOK_URL=https://hooks.example.com\n"
                "CABINET_URL=https://app.example.com\n"
            )
            legacy_cabinet = "VITE_TELEGRAM_BOT_USERNAME=bedolaga_bot\n"
            bot_env.write_text(legacy_bot, encoding="utf-8")
            cabinet_env.write_text(legacy_cabinet, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "BOT_TOKEN"):
                migrate_legacy_installation(state_dir, application_defaults={})

            backups = list((state_dir / "migration-backups").glob("legacy-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(bot_env.read_text(encoding="utf-8"), legacy_bot)
            self.assertEqual(cabinet_env.read_text(encoding="utf-8"), legacy_cabinet)

    def test_failed_migration_keeps_applied_environment_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            legacy_bot = (
                "BOT_TOKEN=1234567890:valid-token\n"
                "ADMIN_IDS=123456789\n"
                "TZ=Europe/Moscow\n"
                "POSTGRES_DB=remnawave_bot\n"
                "POSTGRES_USER=remnawave_user\n"
                f"POSTGRES_PASSWORD={'p' * 64}\n"
                "REMNAWAVE_API_URL=https://panel.example.com\n"
                "REMNAWAVE_API_KEY=api-key\n"
                "REMNAWAVE_SECRET_KEY=header:secret\n"
                f"REMNAWAVE_WEBHOOK_SECRET={'r' * 64}\n"
                "WEBHOOK_URL=https://hooks.example.com\n"
                f"WEBHOOK_SECRET_TOKEN={'w' * 64}\n"
                f"WEB_API_DEFAULT_TOKEN={'a' * 64}\n"
                "CABINET_URL=https://app.example.com\n"
                f"CABINET_JWT_SECRET={'j' * 64}\n"
                "LOG_LEVEL=DEBUG\n"
            )
            legacy_cabinet = (
                "VITE_TELEGRAM_BOT_USERNAME=bedolaga_bot\n"
                "VITE_APP_NAME=My VPN\n"
                "VITE_APP_LOGO=V\n"
            )
            bot_env.write_text(legacy_bot, encoding="utf-8")
            cabinet_env.write_text(legacy_cabinet, encoding="utf-8")
            (state_dir / "bot.override.env").mkdir()

            with self.assertRaises(OSError):
                migrate_legacy_installation(
                    state_dir,
                    application_defaults={"LOG_LEVEL": "INFO"},
                )

            self.assertEqual(bot_env.read_text(encoding="utf-8"), legacy_bot)
            self.assertEqual(cabinet_env.read_text(encoding="utf-8"), legacy_cabinet)


if __name__ == "__main__":
    unittest.main()
