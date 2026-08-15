#!/usr/bin/env python3

from __future__ import annotations

from pathlib import Path
import hashlib
import re
import sys

STATE_KEYS = [
    "PROJECT_ROOT",
    "REPOS_DIR",
    "RUNTIME_DIR",
    "STATE_DIR",
    "RELEASES_DIR",
    "BOT_REPO_URL",
    "CABINET_REPO_URL",
    "BOT_REPO_DIR",
    "CABINET_REPO_DIR",
    "BOT_RUNTIME_DIR",
    "BOT_DATA_DIR",
    "BOT_LOGS_DIR",
    "BOT_UPLOADS_DIR",
    "CABINET_DIST_DIR",
    "BOT_ENV_FILE",
    "BOT_OVERRIDE_ENV_FILE",
    "CABINET_ENV_FILE",
    "COMPOSE_FILE",
    "COMPOSE_PROJECT_NAME",
    "CADDY_CANDIDATE_FILE",
    "CADDY_SNIPPET_DIR",
    "CADDY_SNIPPET_FILE",
    "HOOK_DOMAIN",
    "APP_DOMAIN",
    "WEBHOOK_URL",
    "CABINET_URL",
    "BOT_TOKEN",
    "BOT_USERNAME",
    "ADMIN_IDS",
    "REMNAWAVE_API_URL",
    "REMNAWAVE_API_KEY",
    "REMNAWAVE_SECRET_KEY",
    "REMNAWAVE_WEBHOOK_SECRET",
    "REMNAWAVE_AUTH_TYPE",
    "TIMEZONE",
    "DEFAULT_LANGUAGE",
    "APP_NAME",
    "APP_LOGO",
    "WEBHOOK_SECRET_TOKEN",
    "WEB_API_DEFAULT_TOKEN",
    "CABINET_JWT_SECRET",
    "POSTGRES_DB",
    "POSTGRES_USER",
    "POSTGRES_PASSWORD",
    "POSTGRES_IMAGE",
    "REDIS_URL",
    "REDIS_IMAGE",
    "BOT_HTTP_PORT",
    "BOT_RUN_MODE",
    "WEB_API_ENABLED",
    "CABINET_ENABLED",
    "CABINET_EMAIL_AUTH_ENABLED",
    "CABINET_EMAIL_VERIFICATION_ENABLED",
    "BOT_VERSION_REF",
    "CABINET_VERSION_REF",
    "LAST_BOT_VERSION_REF",
    "LAST_CABINET_VERSION_REF",
    "RELEASE_MANIFEST_SOURCE",
    "CURRENT_RELEASE",
    "CURRENT_RELEASE_BUNDLE_IDENTITY",
    "CURRENT_CABINET_ARTIFACT_SHA256",
    "LAST_RELEASE_BUNDLE_IDENTITY",
    "LAST_CABINET_ARTIFACT_SHA256",
]


def compose_project_name(project_root: Path) -> str:
    slug = re.sub(r"[^a-z0-9_-]+", "-", project_root.name.lower()).strip("-_")
    slug = (slug or "stack")[:32]
    digest = hashlib.sha256(str(project_root).encode("utf-8")).hexdigest()[:8]
    return f"bedolaga-{slug}-{digest}"


def parse_env(path: Path | None) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path or not path.exists():
        return data

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        value = value.strip().rstrip("\r")
        if len(value) >= 2 and ((value[0] == value[-1] == "'") or (value[0] == value[-1] == '"')):
            value = value[1:-1]
        data[key.strip()] = value

    return data


def q(value: str) -> str:
    value = value or ""
    return "'" + value.replace("'", "'\\''") + "'"


def derive_domain(url: str) -> str:
    value = (url or "").strip()
    if value.startswith("http://"):
        value = value[7:]
    elif value.startswith("https://"):
        value = value[8:]
    return value.split("/", 1)[0].lower()


def cmd_get(argv: list[str]) -> int:
    env_path = Path(argv[0])
    key = argv[1]
    print(parse_env(env_path).get(key, ""))
    return 0


def cmd_sync_bot_username(argv: list[str]) -> int:
    cabinet_env = Path(argv[0])
    bot_env = Path(argv[1])

    cab = parse_env(cabinet_env)
    username = cab.get("VITE_TELEGRAM_BOT_USERNAME", "").strip().lstrip("@")
    if not username or not bot_env.exists():
        return 0

    lines = bot_env.read_text(encoding="utf-8").splitlines()
    key_re = re.compile(r"^BOT_USERNAME=")
    updated = False
    out: list[str] = []
    for line in lines:
        if key_re.match(line):
            out.append(f"BOT_USERNAME={username}")
            updated = True
        else:
            out.append(line)

    if not updated:
        out.append(f"BOT_USERNAME={username}")

    bot_env.write_text("\n".join(out) + "\n", encoding="utf-8")
    return 0


def cmd_state_updates(argv: list[str]) -> int:
    bot_env_path = Path(argv[0])
    cab_env_path = Path(argv[1]) if len(argv) > 1 and argv[1] else None

    bot = parse_env(bot_env_path)
    cab = parse_env(cab_env_path)

    webhook_url = bot.get("WEBHOOK_URL", "")
    cabinet_url = bot.get("CABINET_URL", "")

    state_updates = {
        "BOT_TOKEN": bot.get("BOT_TOKEN", ""),
        "ADMIN_IDS": bot.get("ADMIN_IDS", ""),
        "REMNAWAVE_API_URL": bot.get("REMNAWAVE_API_URL", ""),
        "REMNAWAVE_API_KEY": bot.get("REMNAWAVE_API_KEY", ""),
        "REMNAWAVE_SECRET_KEY": bot.get("REMNAWAVE_SECRET_KEY", ""),
        "REMNAWAVE_WEBHOOK_SECRET": bot.get("REMNAWAVE_WEBHOOK_SECRET", ""),
        "REMNAWAVE_AUTH_TYPE": bot.get("REMNAWAVE_AUTH_TYPE", "api_key"),
        "WEBHOOK_URL": webhook_url,
        "CABINET_URL": cabinet_url,
        "HOOK_DOMAIN": derive_domain(webhook_url),
        "APP_DOMAIN": derive_domain(cabinet_url),
        "DEFAULT_LANGUAGE": bot.get("DEFAULT_LANGUAGE", "ru"),
        "TIMEZONE": bot.get("TZ", bot.get("TIMEZONE", "Europe/Moscow")),
        "POSTGRES_DB": bot.get("POSTGRES_DB", ""),
        "POSTGRES_USER": bot.get("POSTGRES_USER", ""),
        "POSTGRES_PASSWORD": bot.get("POSTGRES_PASSWORD", ""),
        "REDIS_URL": bot.get("REDIS_URL", ""),
        "BOT_HTTP_PORT": bot.get("WEB_API_PORT", "8080"),
        "BOT_RUN_MODE": bot.get("BOT_RUN_MODE", "webhook"),
        "WEB_API_ENABLED": bot.get("WEB_API_ENABLED", "true"),
        "CABINET_ENABLED": bot.get("CABINET_ENABLED", "true"),
        "CABINET_EMAIL_AUTH_ENABLED": bot.get("CABINET_EMAIL_AUTH_ENABLED", "false"),
        "CABINET_EMAIL_VERIFICATION_ENABLED": bot.get("CABINET_EMAIL_VERIFICATION_ENABLED", "false"),
        "WEBHOOK_SECRET_TOKEN": bot.get("WEBHOOK_SECRET_TOKEN", ""),
        "WEB_API_DEFAULT_TOKEN": bot.get("WEB_API_DEFAULT_TOKEN", ""),
        "CABINET_JWT_SECRET": bot.get("CABINET_JWT_SECRET", ""),
        "BOT_USERNAME": cab.get("VITE_TELEGRAM_BOT_USERNAME", ""),
        "APP_NAME": cab.get("VITE_APP_NAME", "Bot Service"),
        "APP_LOGO": cab.get("VITE_APP_LOGO", "B"),
    }

    for key, value in state_updates.items():
        print(f"{key}={q(value)}")

    return 0


def cmd_restore_state(argv: list[str]) -> int:
    project_root = Path(argv[0])
    installer_state = Path(argv[1])
    bot_env = Path(argv[2])
    cabinet_env = Path(argv[3])
    bot_repo_url = argv[4]
    cabinet_repo_url = argv[5]
    bot_repo_dir = Path(argv[6])
    cabinet_repo_dir = Path(argv[7])

    bot = parse_env(bot_env)
    cab = parse_env(cabinet_env)

    webhook_url = bot.get("WEBHOOK_URL", "")
    cabinet_url = bot.get("CABINET_URL", "")

    compose_project = compose_project_name(project_root)
    state = {
        "PROJECT_ROOT": str(project_root),
        "REPOS_DIR": str(project_root / "repos"),
        "RUNTIME_DIR": str(project_root / "runtime"),
        "STATE_DIR": str(project_root / "state"),
        "RELEASES_DIR": str(project_root / "releases"),
        "BOT_REPO_URL": bot_repo_url,
        "CABINET_REPO_URL": cabinet_repo_url,
        "BOT_REPO_DIR": str(bot_repo_dir),
        "CABINET_REPO_DIR": str(cabinet_repo_dir),
        "BOT_RUNTIME_DIR": str(project_root / "runtime" / "bot"),
        "BOT_DATA_DIR": str(project_root / "runtime" / "bot" / "data"),
        "BOT_LOGS_DIR": str(project_root / "runtime" / "bot" / "logs"),
        "BOT_UPLOADS_DIR": str(project_root / "runtime" / "bot" / "uploads"),
        "CABINET_DIST_DIR": str(project_root / "runtime" / "cabinet-dist"),
        "BOT_ENV_FILE": str(project_root / "state" / "bot.env"),
        "BOT_OVERRIDE_ENV_FILE": str(project_root / "state" / "bot.override.env"),
        "CABINET_ENV_FILE": str(project_root / "state" / "cabinet.env"),
        "COMPOSE_FILE": str(project_root / "state" / "docker-compose.yml"),
        "COMPOSE_PROJECT_NAME": compose_project,
        "CADDY_CANDIDATE_FILE": str(project_root / "state" / "bot-stack.caddy"),
        "CADDY_SNIPPET_DIR": "/etc/caddy/conf.d",
        "CADDY_SNIPPET_FILE": f"/etc/caddy/conf.d/{compose_project}.caddy",
        "HOOK_DOMAIN": derive_domain(webhook_url),
        "APP_DOMAIN": derive_domain(cabinet_url),
        "WEBHOOK_URL": webhook_url,
        "CABINET_URL": cabinet_url,
        "BOT_TOKEN": bot.get("BOT_TOKEN", ""),
        "BOT_USERNAME": cab.get("VITE_TELEGRAM_BOT_USERNAME", ""),
        "ADMIN_IDS": bot.get("ADMIN_IDS", ""),
        "REMNAWAVE_API_URL": bot.get("REMNAWAVE_API_URL", ""),
        "REMNAWAVE_API_KEY": bot.get("REMNAWAVE_API_KEY", ""),
        "REMNAWAVE_SECRET_KEY": bot.get("REMNAWAVE_SECRET_KEY", ""),
        "REMNAWAVE_WEBHOOK_SECRET": bot.get("REMNAWAVE_WEBHOOK_SECRET", ""),
        "REMNAWAVE_AUTH_TYPE": bot.get("REMNAWAVE_AUTH_TYPE", "api_key"),
        "TIMEZONE": bot.get("TZ", "Europe/Moscow"),
        "DEFAULT_LANGUAGE": bot.get("DEFAULT_LANGUAGE", "ru"),
        "APP_NAME": cab.get("VITE_APP_NAME", "Bot Service"),
        "APP_LOGO": cab.get("VITE_APP_LOGO", "B"),
        "WEBHOOK_SECRET_TOKEN": bot.get("WEBHOOK_SECRET_TOKEN", ""),
        "WEB_API_DEFAULT_TOKEN": bot.get("WEB_API_DEFAULT_TOKEN", ""),
        "CABINET_JWT_SECRET": bot.get("CABINET_JWT_SECRET", ""),
        "POSTGRES_DB": bot.get("POSTGRES_DB", "remnawave_bot"),
        "POSTGRES_USER": bot.get("POSTGRES_USER", "remnawave_user"),
        "POSTGRES_PASSWORD": bot.get("POSTGRES_PASSWORD", ""),
        "POSTGRES_IMAGE": "postgres:15-alpine",
        "REDIS_URL": bot.get("REDIS_URL", "redis://redis:6379/0"),
        "REDIS_IMAGE": "redis:7-alpine",
        "BOT_HTTP_PORT": bot.get("WEB_API_PORT", "8080"),
        "BOT_RUN_MODE": bot.get("BOT_RUN_MODE", "webhook"),
        "WEB_API_ENABLED": bot.get("WEB_API_ENABLED", "true"),
        "CABINET_ENABLED": bot.get("CABINET_ENABLED", "true"),
        "CABINET_EMAIL_AUTH_ENABLED": bot.get("CABINET_EMAIL_AUTH_ENABLED", "false"),
        "CABINET_EMAIL_VERIFICATION_ENABLED": bot.get("CABINET_EMAIL_VERIFICATION_ENABLED", "false"),
        "BOT_VERSION_REF": "main",
        "CABINET_VERSION_REF": "main",
        "LAST_BOT_VERSION_REF": "",
        "LAST_CABINET_VERSION_REF": "",
        "RELEASE_MANIFEST_SOURCE": "",
        "CURRENT_RELEASE": "",
        "CURRENT_RELEASE_BUNDLE_IDENTITY": "",
        "CURRENT_CABINET_ARTIFACT_SHA256": "",
        "LAST_RELEASE_BUNDLE_IDENTITY": "",
        "LAST_CABINET_ARTIFACT_SHA256": "",
    }

    installer_state.write_text(
        "\n".join(f"{key}={q(value)}" for key, value in state.items()) + "\n",
        encoding="utf-8",
    )
    return 0


def cmd_read_state(argv: list[str]) -> int:
    state_path = Path(argv[0])
    state = parse_env(state_path)

    for key in STATE_KEYS:
        if key in state:
            print(f"{key}={q(state[key])}")

    return 0


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: env_helper.py <command> [...]", file=sys.stderr)
        return 1

    command, *rest = argv
    commands = {
        "get": (cmd_get, 2),
        "sync-bot-username": (cmd_sync_bot_username, 2),
        "state-updates": (cmd_state_updates, 1),
        "restore-state": (cmd_restore_state, 8),
        "read-state": (cmd_read_state, 1),
    }

    if command not in commands:
        print(f"unknown command: {command}", file=sys.stderr)
        return 1

    handler, min_args = commands[command]
    if len(rest) < min_args:
        print(f"not enough arguments for {command}", file=sys.stderr)
        return 1

    return handler(rest)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
