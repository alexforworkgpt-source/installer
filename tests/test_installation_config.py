from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
import stat

from lib.installation_config import (
    CONFIG_SCHEMA,
    load_installation_config,
    render_installation,
)


MINIMAL_BOT_ENV_KEYS = {
    "ADMIN_IDS",
    "BOT_RUN_MODE",
    "BOT_TOKEN",
    "BOT_USERNAME",
    "CABINET_ALLOWED_ORIGINS",
    "CABINET_EMAIL_AUTH_ENABLED",
    "CABINET_EMAIL_VERIFICATION_ENABLED",
    "CABINET_ENABLED",
    "CABINET_JWT_SECRET",
    "CABINET_URL",
    "DATABASE_MODE",
    "DEFAULT_LANGUAGE",
    "MAIN_MENU_MODE",
    "MINIAPP_CUSTOM_URL",
    "POSTGRES_DB",
    "POSTGRES_HOST",
    "POSTGRES_PASSWORD",
    "POSTGRES_PORT",
    "POSTGRES_USER",
    "REDIS_URL",
    "REMNAWAVE_API_KEY",
    "REMNAWAVE_API_URL",
    "REMNAWAVE_AUTH_TYPE",
    "REMNAWAVE_SECRET_KEY",
    "REMNAWAVE_WEBHOOK_ENABLED",
    "REMNAWAVE_WEBHOOK_PATH",
    "REMNAWAVE_WEBHOOK_SECRET",
    "TZ",
    "WEBHOOK_DROP_PENDING_UPDATES",
    "WEBHOOK_PATH",
    "WEBHOOK_SECRET_TOKEN",
    "WEBHOOK_URL",
    "WEB_API_ALLOWED_ORIGINS",
    "WEB_API_DEFAULT_TOKEN",
    "WEB_API_DOCS_ENABLED",
    "WEB_API_ENABLED",
    "WEB_API_HOST",
    "WEB_API_PORT",
}

MINIMAL_CABINET_ENV_KEYS = {
    "VITE_API_URL",
    "VITE_APP_LOGO",
    "VITE_APP_NAME",
    "VITE_TELEGRAM_BOT_USERNAME",
}


def read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


class InstallationConfigurationTests(unittest.TestCase):
    def valid_config(self) -> dict[str, str]:
        return {
            "HOOK_DOMAIN": "hooks.example.com",
            "APP_DOMAIN": "app.example.com",
            "BOT_TOKEN": "1234567890:valid-token",
            "BOT_USERNAME": "bedolaga_bot",
            "ADMIN_IDS": "123456789,987654321",
            "REMNAWAVE_API_URL": "https://panel.example.com",
            "REMNAWAVE_API_KEY": "remnawave-api-key",
            "REMNAWAVE_SECRET_KEY": "header:secret-value",
            "REMNAWAVE_WEBHOOK_SECRET": "r" * 64,
        }

    def test_fresh_install_generates_minimal_core_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"

            render_installation(
                self.valid_config(),
                bot_env,
                cabinet_env,
            )

            bot = read_env(bot_env)
            cabinet = read_env(cabinet_env)

            self.assertEqual(set(bot), MINIMAL_BOT_ENV_KEYS)
            self.assertEqual(set(cabinet), MINIMAL_CABINET_ENV_KEYS)
            self.assertEqual(bot["WEBHOOK_URL"], "https://hooks.example.com")
            self.assertEqual(bot["CABINET_URL"], "https://app.example.com")
            self.assertEqual(bot["CABINET_ALLOWED_ORIGINS"], "https://app.example.com")
            self.assertEqual(bot["WEB_API_ALLOWED_ORIGINS"], "https://app.example.com")
            self.assertEqual(bot["MINIAPP_CUSTOM_URL"], "https://app.example.com")
            self.assertEqual(bot["MAIN_MENU_MODE"], "cabinet")
            self.assertEqual(bot["REMNAWAVE_WEBHOOK_ENABLED"], "true")
            self.assertEqual(bot["REMNAWAVE_WEBHOOK_PATH"], "/remnawave-webhook")
            self.assertEqual(bot["WEBHOOK_DROP_PENDING_UPDATES"], "false")
            self.assertEqual(cabinet["VITE_API_URL"], "/api")
            self.assertEqual(cabinet["VITE_TELEGRAM_BOT_USERNAME"], "bedolaga_bot")

            generated_secrets = {
                bot["POSTGRES_PASSWORD"],
                bot["WEBHOOK_SECRET_TOKEN"],
                bot["WEB_API_DEFAULT_TOKEN"],
                bot["CABINET_JWT_SECRET"],
            }
            self.assertEqual(len(generated_secrets), 4)
            self.assertNotIn("change_me_please", generated_secrets)
            self.assertTrue(all(len(secret) == 64 for secret in generated_secrets))

    @unittest.skipIf(os.name == "nt", "POSIX permissions require the Ubuntu seam")
    def test_generated_environment_files_are_private_from_creation(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"

            render_installation(self.valid_config(), bot_env, cabinet_env)

            self.assertEqual(stat.S_IMODE(bot_env.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(cabinet_env.stat().st_mode), 0o600)

    def test_interrupted_secret_write_leaves_no_destination_or_temporary_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"

            with patch(
                "lib.installation_config.os.replace",
                side_effect=OSError("injected atomic replace failure"),
            ), self.assertRaisesRegex(OSError, "injected atomic replace failure"):
                render_installation(self.valid_config(), bot_env, cabinet_env)

            self.assertFalse(bot_env.exists())
            self.assertFalse(cabinet_env.exists())
            self.assertEqual(list(state_dir.iterdir()), [])

    def test_generated_environment_contains_no_unresolved_placeholders(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"

            render_installation(self.valid_config(), bot_env, cabinet_env)

            generated = bot_env.read_text(encoding="utf-8") + cabinet_env.read_text(
                encoding="utf-8"
            )
            self.assertNotRegex(generated, r"__[A-Z][A-Z0-9_]*__")
            self.assertNotIn("change_me_please", generated)

    def test_typed_schema_round_trips_every_supported_value(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            first_bot = state_dir / "first.bot.env"
            first_cabinet = state_dir / "first.cabinet.env"
            second_bot = state_dir / "second.bot.env"
            second_cabinet = state_dir / "second.cabinet.env"
            config = self.valid_config() | {
                "DEFAULT_LANGUAGE": "en",
                "TIMEZONE": "UTC",
                "POSTGRES_DB": "custom_db",
                "POSTGRES_USER": "custom_user",
                "POSTGRES_PASSWORD": "p" * 64,
                "WEBHOOK_SECRET_TOKEN": "w" * 64,
                "WEB_API_DEFAULT_TOKEN": "a" * 64,
                "CABINET_JWT_SECRET": "j" * 64,
                "BOT_HTTP_PORT": "9090",
                "APP_NAME": "Custom App",
                "APP_LOGO": "C",
            }

            render_installation(config, first_bot, first_cabinet)
            restored = load_installation_config(first_bot, first_cabinet)
            render_installation(restored, second_bot, second_cabinet)

            self.assertEqual(set(restored), set(CONFIG_SCHEMA))
            self.assertTrue(all(spec.value_type is str for spec in CONFIG_SCHEMA.values()))
            self.assertEqual(restored, config)
            self.assertEqual(first_bot.read_bytes(), second_bot.read_bytes())
            self.assertEqual(first_cabinet.read_bytes(), second_cabinet.read_bytes())

    def test_invalid_draft_does_not_replace_applied_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            bot_env.write_text("APPLIED_BOT=true\n", encoding="utf-8")
            cabinet_env.write_text("APPLIED_CABINET=true\n", encoding="utf-8")
            invalid_config = self.valid_config()
            invalid_config["BOT_TOKEN"] = "1234567890:token\nHELEKET_ENABLED=true"

            with self.assertRaisesRegex(ValueError, "BOT_TOKEN"):
                render_installation(invalid_config, bot_env, cabinet_env)

            self.assertEqual(bot_env.read_text(encoding="utf-8"), "APPLIED_BOT=true\n")
            self.assertEqual(
                cabinet_env.read_text(encoding="utf-8"),
                "APPLIED_CABINET=true\n",
            )

    def test_legacy_restore_does_not_adopt_heleket_settings(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            project_root = Path(temp_dir)
            state_dir = project_root / "state"
            state_dir.mkdir()
            state_file = state_dir / "install.state"
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            bot_env.write_text(
                "WEBHOOK_URL=https://hooks.example.com\n"
                "CABINET_URL=https://app.example.com\n"
                "HELEKET_ENABLED=true\n"
                "HELEKET_API_KEY=legacy-secret\n",
                encoding="utf-8",
            )
            cabinet_env.write_text(
                "VITE_TELEGRAM_BOT_USERNAME=bedolaga_bot\n",
                encoding="utf-8",
            )

            subprocess.run(
                [
                    sys.executable,
                    "lib/env_helper.py",
                    "restore-state",
                    str(project_root),
                    str(state_file),
                    str(bot_env),
                    str(cabinet_env),
                    "https://example.com/bot.git",
                    "https://example.com/cabinet.git",
                    str(project_root / "repos" / "bot"),
                    str(project_root / "repos" / "cabinet"),
                ],
                check=True,
            )

            restored = read_env(state_file)
            self.assertFalse(any(key.startswith("HELEKET_") for key in restored))

    def test_generic_render_rejects_initialized_postgres_identity_change(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            render_installation(self.valid_config(), bot_env, cabinet_env)
            applied_bot = bot_env.read_text(encoding="utf-8")
            applied_cabinet = cabinet_env.read_text(encoding="utf-8")
            changed_config = self.valid_config()
            changed_config["POSTGRES_USER"] = "different_user"

            with self.assertRaisesRegex(ValueError, "PostgreSQL identity"):
                render_installation(changed_config, bot_env, cabinet_env)

            self.assertEqual(bot_env.read_text(encoding="utf-8"), applied_bot)
            self.assertEqual(cabinet_env.read_text(encoding="utf-8"), applied_cabinet)

    def test_invalid_installation_draft_is_rejected_before_render(self) -> None:
        invalid_values = {
            "HOOK_DOMAIN": "not-a-domain",
            "APP_DOMAIN": "https://app.example.com/path",
            "BOT_TOKEN": "invalid-token",
            "BOT_USERNAME": "@bad-name",
            "ADMIN_IDS": "123, admin",
            "REMNAWAVE_API_URL": "panel.example.com",
            "REMNAWAVE_WEBHOOK_SECRET": "too-short",
            "BOT_HTTP_PORT": "70000",
        }

        for key, invalid_value in invalid_values.items():
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temp_dir:
                state_dir = Path(temp_dir)
                config = self.valid_config()
                config[key] = invalid_value

                with self.assertRaisesRegex(ValueError, key):
                    render_installation(
                        config,
                        state_dir / "bot.env",
                        state_dir / "cabinet.env",
                    )

                self.assertFalse((state_dir / "bot.env").exists())
                self.assertFalse((state_dir / "cabinet.env").exists())


if __name__ == "__main__":
    unittest.main()
