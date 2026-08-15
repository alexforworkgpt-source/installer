from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from lib.installation_config import (
    build_redacted_change_plan,
    create_settings_draft,
    promote_settings_draft,
    render_installation,
)


class SettingsDraftTests(unittest.TestCase):
    def test_draft_is_isolated_and_plan_redacts_secrets(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            render_installation(
                {
                    "HOOK_DOMAIN": "hooks.example.com",
                    "APP_DOMAIN": "app.example.com",
                    "BOT_TOKEN": "1234567890:valid-token",
                    "BOT_USERNAME": "bedolaga_bot",
                    "ADMIN_IDS": "123456789",
                    "REMNAWAVE_API_URL": "https://panel.example.com",
                    "REMNAWAVE_API_KEY": "api-key",
                    "REMNAWAVE_SECRET_KEY": "header:secret",
                    "REMNAWAVE_WEBHOOK_SECRET": "r" * 64,
                },
                bot_env,
                cabinet_env,
            )
            applied_bot = bot_env.read_text(encoding="utf-8")
            applied_cabinet = cabinet_env.read_text(encoding="utf-8")
            old_secret = "j" * 64
            new_secret = "n" * 64
            applied_bot = applied_bot.replace(
                next(
                    line
                    for line in applied_bot.splitlines()
                    if line.startswith("CABINET_JWT_SECRET=")
                ).split("=", 1)[1],
                old_secret,
            )
            bot_env.write_text(applied_bot, encoding="utf-8")

            draft = create_settings_draft(state_dir)
            draft_bot = draft.bot_env.read_text(encoding="utf-8")
            draft_bot = draft_bot.replace("BOT_USERNAME=bedolaga_bot", "BOT_USERNAME=new_bot")
            draft_bot = draft_bot.replace(
                f"CABINET_JWT_SECRET={old_secret}",
                f"CABINET_JWT_SECRET={new_secret}",
            )
            draft.bot_env.write_text(draft_bot, encoding="utf-8")

            plan = build_redacted_change_plan(state_dir)

            self.assertEqual(bot_env.read_text(encoding="utf-8"), applied_bot)
            self.assertEqual(cabinet_env.read_text(encoding="utf-8"), applied_cabinet)
            self.assertIn("bot.env: BOT_USERNAME: bedolaga_bot -> new_bot", plan)
            self.assertIn("bot.env: CABINET_JWT_SECRET: <redacted> -> <redacted>", plan)
            self.assertNotIn(old_secret, plan)
            self.assertNotIn(new_secret, plan)

    def test_only_explicit_promotion_replaces_applied_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            render_installation(
                {
                    "HOOK_DOMAIN": "hooks.example.com",
                    "APP_DOMAIN": "app.example.com",
                    "BOT_TOKEN": "1234567890:valid-token",
                    "BOT_USERNAME": "bedolaga_bot",
                    "ADMIN_IDS": "123456789",
                    "REMNAWAVE_API_URL": "https://panel.example.com",
                    "REMNAWAVE_API_KEY": "api-key",
                    "REMNAWAVE_SECRET_KEY": "header:secret",
                    "REMNAWAVE_WEBHOOK_SECRET": "r" * 64,
                },
                bot_env,
                cabinet_env,
            )
            draft = create_settings_draft(state_dir)
            draft.bot_env.write_text(
                draft.bot_env.read_text(encoding="utf-8").replace(
                    "BOT_USERNAME=bedolaga_bot",
                    "BOT_USERNAME=new_bot",
                ),
                encoding="utf-8",
            )

            self.assertIn("BOT_USERNAME=bedolaga_bot", bot_env.read_text(encoding="utf-8"))

            promote_settings_draft(state_dir)

            self.assertIn("BOT_USERNAME=new_bot", bot_env.read_text(encoding="utf-8"))
            self.assertFalse((state_dir / "draft").exists())

    def test_invalid_draft_cannot_replace_applied_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            bot_env = state_dir / "bot.env"
            cabinet_env = state_dir / "cabinet.env"
            render_installation(
                {
                    "HOOK_DOMAIN": "hooks.example.com",
                    "APP_DOMAIN": "app.example.com",
                    "BOT_TOKEN": "1234567890:valid-token",
                    "BOT_USERNAME": "bedolaga_bot",
                    "ADMIN_IDS": "123456789",
                    "REMNAWAVE_API_URL": "https://panel.example.com",
                    "REMNAWAVE_API_KEY": "api-key",
                    "REMNAWAVE_SECRET_KEY": "header:secret",
                    "REMNAWAVE_WEBHOOK_SECRET": "r" * 64,
                },
                bot_env,
                cabinet_env,
            )
            applied_bot = bot_env.read_text(encoding="utf-8")
            draft = create_settings_draft(state_dir)
            draft.bot_env.write_text(
                draft.bot_env.read_text(encoding="utf-8").replace(
                    "BOT_TOKEN=1234567890:valid-token",
                    "BOT_TOKEN=invalid-token",
                ),
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "BOT_TOKEN"):
                promote_settings_draft(state_dir)

            self.assertEqual(bot_env.read_text(encoding="utf-8"), applied_bot)
            self.assertTrue((state_dir / "draft").exists())

    def test_advanced_override_secrets_are_redacted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            state_dir = Path(temp_dir)
            render_installation(
                {
                    "HOOK_DOMAIN": "hooks.example.com",
                    "APP_DOMAIN": "app.example.com",
                    "BOT_TOKEN": "1234567890:valid-token",
                    "BOT_USERNAME": "bedolaga_bot",
                    "ADMIN_IDS": "123456789",
                    "REMNAWAVE_API_URL": "https://panel.example.com",
                    "REMNAWAVE_API_KEY": "api-key",
                    "REMNAWAVE_SECRET_KEY": "header:secret",
                    "REMNAWAVE_WEBHOOK_SECRET": "r" * 64,
                },
                state_dir / "bot.env",
                state_dir / "cabinet.env",
            )
            old_password = "old-smtp-password"
            new_password = "new-smtp-password"
            (state_dir / "bot.override.env").write_text(
                f"SMTP_PASSWORD={old_password}\n",
                encoding="utf-8",
            )
            draft = create_settings_draft(state_dir)
            draft.override_env.write_text(
                f"SMTP_PASSWORD={new_password}\n",
                encoding="utf-8",
            )

            plan = build_redacted_change_plan(state_dir)

            self.assertIn(
                "bot.override.env: SMTP_PASSWORD: <redacted> -> <redacted>",
                plan,
            )
            self.assertNotIn(old_password, plan)
            self.assertNotIn(new_password, plan)


if __name__ == "__main__":
    unittest.main()
