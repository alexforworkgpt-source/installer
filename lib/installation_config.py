from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
import tempfile
from urllib.parse import urlsplit


@dataclass(frozen=True)
class FieldSpec:
    required: bool
    default: str | None
    secret: bool
    mutable: bool
    destinations: tuple[str, ...]
    validator: Callable[[str], bool]
    value_type: type[str] = str


def _nonempty(value: str) -> bool:
    return bool(value)


def _domain(value: str) -> bool:
    return bool(
        re.fullmatch(
            r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}",
            value.lower(),
        )
    )


def _absolute_url(value: str) -> bool:
    parsed = urlsplit(value)
    return parsed.scheme in ("http", "https") and bool(parsed.hostname)


def _bot_token(value: str) -> bool:
    return bool(re.fullmatch(r"[0-9]+:[^\s]+", value))


def _bot_username(value: str) -> bool:
    return bool(re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{4,31}", value))


def _admin_ids(value: str) -> bool:
    return bool(re.fullmatch(r"[0-9]+(?:,[0-9]+)*", value))


def _webhook_secret(value: str) -> bool:
    return len(value) >= 32


def _port(value: str) -> bool:
    return value.isdigit() and 1 <= int(value) <= 65535


CONFIG_SCHEMA = {
    "HOOK_DOMAIN": FieldSpec(True, None, False, True, ("bot.env", "caddy"), _domain),
    "APP_DOMAIN": FieldSpec(True, None, False, True, ("bot.env", "cabinet.env", "caddy"), _domain),
    "BOT_TOKEN": FieldSpec(True, None, True, True, ("bot.env",), _bot_token),
    "BOT_USERNAME": FieldSpec(True, None, False, True, ("bot.env", "cabinet.env"), _bot_username),
    "ADMIN_IDS": FieldSpec(True, None, False, True, ("bot.env",), _admin_ids),
    "REMNAWAVE_API_URL": FieldSpec(True, None, False, True, ("bot.env",), _absolute_url),
    "REMNAWAVE_API_KEY": FieldSpec(True, None, True, True, ("bot.env",), _nonempty),
    "REMNAWAVE_SECRET_KEY": FieldSpec(True, None, True, True, ("bot.env",), _nonempty),
    "REMNAWAVE_WEBHOOK_SECRET": FieldSpec(True, None, True, True, ("bot.env",), _webhook_secret),
    "DEFAULT_LANGUAGE": FieldSpec(False, "ru", False, True, ("bot.env",), _nonempty),
    "TIMEZONE": FieldSpec(False, "Europe/Moscow", False, True, ("bot.env",), _nonempty),
    "POSTGRES_DB": FieldSpec(False, "remnawave_bot", False, False, ("bot.env",), _nonempty),
    "POSTGRES_USER": FieldSpec(False, "remnawave_user", False, False, ("bot.env",), _nonempty),
    "POSTGRES_PASSWORD": FieldSpec(False, None, True, False, ("bot.env",), _nonempty),
    "WEBHOOK_SECRET_TOKEN": FieldSpec(False, None, True, True, ("bot.env",), _nonempty),
    "WEB_API_DEFAULT_TOKEN": FieldSpec(False, None, True, True, ("bot.env",), _nonempty),
    "CABINET_JWT_SECRET": FieldSpec(False, None, True, True, ("bot.env",), _nonempty),
    "BOT_HTTP_PORT": FieldSpec(False, "8080", False, True, ("bot.env", "compose", "caddy"), _port),
    "APP_NAME": FieldSpec(False, "Bot Service", False, True, ("cabinet.env",), _nonempty),
    "APP_LOGO": FieldSpec(False, "B", False, True, ("cabinet.env",), _nonempty),
}


def _secret() -> str:
    return secrets.token_hex(32)


def _validate_values(config: Mapping[str, str]) -> None:
    for key, value in config.items():
        if any(character in value for character in ("\n", "\r", "\0")):
            raise ValueError(f"{key} contains a forbidden control character")


def _validate_schema(config: Mapping[str, str]) -> None:
    for key, spec in CONFIG_SCHEMA.items():
        value = config.get(key)
        if value is None:
            value = spec.default
        if spec.required and not value:
            raise ValueError(f"{key} is required")
        if value and not spec.validator(value):
            raise ValueError(f"{key} is invalid")


def _read_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists() or not path.is_file():
        return values
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = _clean_env_value(value)
    return values


def _clean_env_value(value: str) -> str:
    value = value.strip()
    quote: str | None = None
    for index, character in enumerate(value):
        if character in ("'", '"'):
            if quote == character:
                quote = None
            elif quote is None:
                quote = character
        elif character == "#" and quote is None:
            if index == 0 or value[index - 1].isspace():
                value = value[:index].rstrip()
                break
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def _postgres_identity(config: Mapping[str, str], bot_env_path: Path) -> tuple[str, str, str]:
    applied = _read_env(bot_env_path)
    applied_database = applied.get("POSTGRES_DB")
    applied_user = applied.get("POSTGRES_USER")
    applied_password = applied.get("POSTGRES_PASSWORD")

    database = config.get("POSTGRES_DB") or applied_database or "remnawave_bot"
    user = config.get("POSTGRES_USER") or applied_user or "remnawave_user"
    password = config.get("POSTGRES_PASSWORD") or applied_password or _secret()

    if applied_database and applied_user and applied_password:
        if (database, user, password) != (
            applied_database,
            applied_user,
            applied_password,
        ):
            raise ValueError(
                "PostgreSQL identity is immutable after initialization; use credential rotation"
            )

    return database, user, password


def _write_env(path: Path, values: Mapping[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.",
        text=True,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.writelines(f"{key}={value}\n" for key, value in values.items())
        os.replace(temporary_path, path)
        path.chmod(0o600)
    finally:
        temporary_path.unlink(missing_ok=True)


def _atomic_copy(source: Path, destination: Path) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        dir=destination.parent,
        prefix=f".{destination.name}.",
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    try:
        shutil.copyfile(source, temporary_path)
        temporary_path.chmod(0o600)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)


def render_installation(
    config: Mapping[str, str],
    bot_env_path: Path,
    cabinet_env_path: Path,
) -> None:
    _validate_values(config)
    _validate_schema(config)
    hook_domain = config["HOOK_DOMAIN"]
    app_domain = config["APP_DOMAIN"]
    cabinet_url = f"https://{app_domain}"
    postgres_database, postgres_user, postgres_password = _postgres_identity(
        config,
        bot_env_path,
    )

    bot_env = {
        "BOT_TOKEN": config["BOT_TOKEN"],
        "BOT_USERNAME": config["BOT_USERNAME"].lstrip("@"),
        "ADMIN_IDS": config["ADMIN_IDS"],
        "DEFAULT_LANGUAGE": config.get("DEFAULT_LANGUAGE", "ru"),
        "TZ": config.get("TIMEZONE", "Europe/Moscow"),
        "DATABASE_MODE": "auto",
        "POSTGRES_HOST": "postgres",
        "POSTGRES_PORT": "5432",
        "POSTGRES_DB": postgres_database,
        "POSTGRES_USER": postgres_user,
        "POSTGRES_PASSWORD": postgres_password,
        "REDIS_URL": "redis://redis:6379/0",
        "REMNAWAVE_API_URL": config["REMNAWAVE_API_URL"],
        "REMNAWAVE_API_KEY": config["REMNAWAVE_API_KEY"],
        "REMNAWAVE_AUTH_TYPE": "api_key",
        "REMNAWAVE_SECRET_KEY": config["REMNAWAVE_SECRET_KEY"],
        "REMNAWAVE_WEBHOOK_ENABLED": "true",
        "REMNAWAVE_WEBHOOK_PATH": "/remnawave-webhook",
        "REMNAWAVE_WEBHOOK_SECRET": config["REMNAWAVE_WEBHOOK_SECRET"],
        "BOT_RUN_MODE": "webhook",
        "WEBHOOK_URL": f"https://{hook_domain}",
        "WEBHOOK_PATH": "/webhook",
        "WEBHOOK_SECRET_TOKEN": config.get("WEBHOOK_SECRET_TOKEN") or _secret(),
        "WEBHOOK_DROP_PENDING_UPDATES": "false",
        "WEB_API_ENABLED": "true",
        "WEB_API_HOST": "0.0.0.0",
        "WEB_API_PORT": config.get("BOT_HTTP_PORT", "8080"),
        "WEB_API_ALLOWED_ORIGINS": cabinet_url,
        "WEB_API_DOCS_ENABLED": "false",
        "WEB_API_DEFAULT_TOKEN": config.get("WEB_API_DEFAULT_TOKEN") or _secret(),
        "CABINET_ENABLED": "true",
        "CABINET_URL": cabinet_url,
        "CABINET_JWT_SECRET": config.get("CABINET_JWT_SECRET") or _secret(),
        "CABINET_ALLOWED_ORIGINS": cabinet_url,
        "CABINET_EMAIL_AUTH_ENABLED": "false",
        "CABINET_EMAIL_VERIFICATION_ENABLED": "false",
        "MAIN_MENU_MODE": "cabinet",
        "MINIAPP_CUSTOM_URL": cabinet_url,
    }
    cabinet_env = {
        "VITE_API_URL": "/api",
        "VITE_TELEGRAM_BOT_USERNAME": config["BOT_USERNAME"].lstrip("@"),
        "VITE_APP_NAME": config.get("APP_NAME", "Bot Service"),
        "VITE_APP_LOGO": config.get("APP_LOGO", "B"),
    }

    _write_env(bot_env_path, bot_env)
    _write_env(cabinet_env_path, cabinet_env)


def load_installation_config(
    bot_env_path: Path,
    cabinet_env_path: Path,
) -> dict[str, str]:
    bot = _read_env(bot_env_path)
    cabinet = _read_env(cabinet_env_path)
    config = {
        "HOOK_DOMAIN": _domain_from_url(bot.get("WEBHOOK_URL", ""), "WEBHOOK_URL"),
        "APP_DOMAIN": _domain_from_url(bot.get("CABINET_URL", ""), "CABINET_URL"),
        "BOT_TOKEN": bot.get("BOT_TOKEN", ""),
        "BOT_USERNAME": bot.get("BOT_USERNAME", ""),
        "ADMIN_IDS": bot.get("ADMIN_IDS", ""),
        "REMNAWAVE_API_URL": bot.get("REMNAWAVE_API_URL", ""),
        "REMNAWAVE_API_KEY": bot.get("REMNAWAVE_API_KEY", ""),
        "REMNAWAVE_SECRET_KEY": bot.get("REMNAWAVE_SECRET_KEY", ""),
        "REMNAWAVE_WEBHOOK_SECRET": bot.get("REMNAWAVE_WEBHOOK_SECRET", ""),
        "DEFAULT_LANGUAGE": bot.get("DEFAULT_LANGUAGE", "ru"),
        "TIMEZONE": bot.get("TZ", "Europe/Moscow"),
        "POSTGRES_DB": bot.get("POSTGRES_DB", ""),
        "POSTGRES_USER": bot.get("POSTGRES_USER", ""),
        "POSTGRES_PASSWORD": bot.get("POSTGRES_PASSWORD", ""),
        "WEBHOOK_SECRET_TOKEN": bot.get("WEBHOOK_SECRET_TOKEN", ""),
        "WEB_API_DEFAULT_TOKEN": bot.get("WEB_API_DEFAULT_TOKEN", ""),
        "CABINET_JWT_SECRET": bot.get("CABINET_JWT_SECRET", ""),
        "BOT_HTTP_PORT": bot.get("WEB_API_PORT", "8080"),
        "APP_NAME": cabinet.get("VITE_APP_NAME", "Bot Service"),
        "APP_LOGO": cabinet.get("VITE_APP_LOGO", "B"),
    }
    _validate_values(config)
    _validate_schema(config)
    return config


@dataclass(frozen=True)
class MigrationResult:
    backup_dir: Path
    override_path: Path


@dataclass(frozen=True)
class DraftPaths:
    bot_env: Path
    cabinet_env: Path
    override_env: Path


SECRET_KEYS = {
    "BOT_TOKEN",
    "CABINET_JWT_SECRET",
    "POSTGRES_PASSWORD",
    "REMNAWAVE_API_KEY",
    "REMNAWAVE_SECRET_KEY",
    "REMNAWAVE_WEBHOOK_SECRET",
    "WEBHOOK_SECRET_TOKEN",
    "WEB_API_DEFAULT_TOKEN",
}


def _is_secret_key(key: str) -> bool:
    upper_key = key.upper()
    return key in SECRET_KEYS or any(
        marker in upper_key
        for marker in (
            "PASSWORD",
            "TOKEN",
            "SECRET",
            "API_KEY",
            "PRIVATE_KEY",
            "PASSPHRASE",
        )
    )


def create_settings_draft(state_dir: Path) -> DraftPaths:
    applied_bot = state_dir / "bot.env"
    applied_cabinet = state_dir / "cabinet.env"
    applied_override = state_dir / "bot.override.env"
    if not applied_bot.is_file() or not applied_cabinet.is_file():
        raise ValueError("applied bot.env and cabinet.env are required")

    draft_dir = state_dir / "draft"
    draft_dir.mkdir(parents=True, exist_ok=True)
    draft = DraftPaths(
        bot_env=draft_dir / "bot.env",
        cabinet_env=draft_dir / "cabinet.env",
        override_env=draft_dir / "bot.override.env",
    )
    if not draft.bot_env.exists():
        _atomic_copy(applied_bot, draft.bot_env)
    if not draft.cabinet_env.exists():
        _atomic_copy(applied_cabinet, draft.cabinet_env)
    if not draft.override_env.exists():
        if applied_override.is_file():
            _atomic_copy(applied_override, draft.override_env)
        else:
            _write_env(draft.override_env, {})
    return draft


def build_redacted_change_plan(state_dir: Path) -> str:
    draft_dir = state_dir / "draft"
    artifacts = (
        ("bot.env", state_dir / "bot.env", draft_dir / "bot.env"),
        ("cabinet.env", state_dir / "cabinet.env", draft_dir / "cabinet.env"),
        (
            "bot.override.env",
            state_dir / "bot.override.env",
            draft_dir / "bot.override.env",
        ),
    )
    if not (draft_dir / "bot.env").is_file() or not (draft_dir / "cabinet.env").is_file():
        raise ValueError("settings draft does not exist")

    changes: list[str] = []
    for artifact_name, applied_path, draft_path in artifacts:
        applied = _read_env(applied_path)
        draft = _read_env(draft_path)
        for key in sorted(set(applied) | set(draft)):
            before = applied.get(key, "<unset>")
            after = draft.get(key, "<unset>")
            if before == after:
                continue
            if _is_secret_key(key):
                before = "<redacted>"
                after = "<redacted>"
            changes.append(f"{artifact_name}: {key}: {before} -> {after}")
    return "\n".join(changes)


def promote_settings_draft(state_dir: Path) -> None:
    draft = DraftPaths(
        bot_env=state_dir / "draft" / "bot.env",
        cabinet_env=state_dir / "draft" / "cabinet.env",
        override_env=state_dir / "draft" / "bot.override.env",
    )
    for path in (draft.bot_env, draft.cabinet_env, draft.override_env):
        if not path.is_file():
            raise ValueError(f"draft artifact is missing: {path.name}")

    applied_bot = state_dir / "bot.env"
    applied_cabinet = state_dir / "cabinet.env"
    applied_override = state_dir / "bot.override.env"
    applied_identity = _read_env(applied_bot)
    draft_identity = _read_env(draft.bot_env)
    draft_cabinet = _read_env(draft.cabinet_env)
    draft_config = {
        "HOOK_DOMAIN": _domain_from_url(
            draft_identity.get("WEBHOOK_URL", ""),
            "WEBHOOK_URL",
        ),
        "APP_DOMAIN": _domain_from_url(
            draft_identity.get("CABINET_URL", ""),
            "CABINET_URL",
        ),
        "BOT_TOKEN": draft_identity.get("BOT_TOKEN", ""),
        "BOT_USERNAME": draft_identity.get("BOT_USERNAME")
        or draft_cabinet.get("VITE_TELEGRAM_BOT_USERNAME", ""),
        "ADMIN_IDS": draft_identity.get("ADMIN_IDS", ""),
        "REMNAWAVE_API_URL": draft_identity.get("REMNAWAVE_API_URL", ""),
        "REMNAWAVE_API_KEY": draft_identity.get("REMNAWAVE_API_KEY", ""),
        "REMNAWAVE_SECRET_KEY": draft_identity.get("REMNAWAVE_SECRET_KEY", ""),
        "REMNAWAVE_WEBHOOK_SECRET": draft_identity.get(
            "REMNAWAVE_WEBHOOK_SECRET",
            "",
        ),
        "BOT_HTTP_PORT": draft_identity.get("WEB_API_PORT", "8080"),
    }
    _validate_values(draft_config)
    _validate_schema(draft_config)
    for key in ("POSTGRES_DB", "POSTGRES_USER", "POSTGRES_PASSWORD"):
        if applied_identity.get(key) != draft_identity.get(key):
            raise ValueError(
                "PostgreSQL identity is immutable in a settings draft; use credential rotation"
            )

    with tempfile.TemporaryDirectory(prefix=".draft-backup-", dir=state_dir) as backup:
        backup_dir = Path(backup)
        _atomic_copy(applied_bot, backup_dir / "bot.env")
        _atomic_copy(applied_cabinet, backup_dir / "cabinet.env")
        if applied_override.is_file():
            _atomic_copy(applied_override, backup_dir / "bot.override.env")

        try:
            _atomic_copy(draft.bot_env, applied_bot)
            _atomic_copy(draft.cabinet_env, applied_cabinet)
            _atomic_copy(draft.override_env, applied_override)
        except OSError:
            _atomic_copy(backup_dir / "bot.env", applied_bot)
            _atomic_copy(backup_dir / "cabinet.env", applied_cabinet)
            backup_override = backup_dir / "bot.override.env"
            if backup_override.exists():
                _atomic_copy(backup_override, applied_override)
            elif applied_override.is_file():
                applied_override.unlink()
            raise

    shutil.rmtree(state_dir / "draft")


def replace_postgres_password(bot_env_path: Path, new_password: str) -> None:
    if len(new_password) < 32:
        raise ValueError("POSTGRES_PASSWORD must contain at least 32 characters")
    values = _read_env(bot_env_path)
    if "POSTGRES_PASSWORD" not in values:
        raise ValueError("POSTGRES_PASSWORD is missing from bot.env")
    values["POSTGRES_PASSWORD"] = new_password
    _write_env(bot_env_path, values)


def _domain_from_url(value: str, key: str) -> str:
    domain = urlsplit(value).hostname
    if not domain:
        raise ValueError(f"{key} must contain an absolute URL")
    return domain


def migrate_legacy_installation(
    state_dir: Path,
    application_defaults: Mapping[str, str],
) -> MigrationResult:
    bot_env_path = state_dir / "bot.env"
    cabinet_env_path = state_dir / "cabinet.env"
    override_path = state_dir / "bot.override.env"
    if not bot_env_path.is_file() or not cabinet_env_path.is_file():
        raise ValueError("legacy bot.env and cabinet.env are required")

    backup_root = state_dir / "migration-backups"
    backup_root.mkdir(parents=True, exist_ok=True)
    backup_dir = Path(tempfile.mkdtemp(prefix="legacy-", dir=backup_root))
    shutil.copy2(bot_env_path, backup_dir / "bot.env")
    shutil.copy2(cabinet_env_path, backup_dir / "cabinet.env")
    if override_path.is_file():
        shutil.copy2(override_path, backup_dir / "bot.override.env")
    (backup_dir / "bot.env").chmod(0o600)
    (backup_dir / "cabinet.env").chmod(0o600)
    if (backup_dir / "bot.override.env").exists():
        (backup_dir / "bot.override.env").chmod(0o600)

    legacy_bot = _read_env(bot_env_path)
    legacy_cabinet = _read_env(cabinet_env_path)
    config = {
        "HOOK_DOMAIN": _domain_from_url(legacy_bot.get("WEBHOOK_URL", ""), "WEBHOOK_URL"),
        "APP_DOMAIN": _domain_from_url(legacy_bot.get("CABINET_URL", ""), "CABINET_URL"),
        "BOT_TOKEN": legacy_bot.get("BOT_TOKEN", ""),
        "BOT_USERNAME": legacy_bot.get("BOT_USERNAME")
        or legacy_cabinet.get("VITE_TELEGRAM_BOT_USERNAME", ""),
        "ADMIN_IDS": legacy_bot.get("ADMIN_IDS", ""),
        "DEFAULT_LANGUAGE": legacy_bot.get("DEFAULT_LANGUAGE", "ru"),
        "TIMEZONE": legacy_bot.get("TZ", "Europe/Moscow"),
        "POSTGRES_DB": legacy_bot.get("POSTGRES_DB", ""),
        "POSTGRES_USER": legacy_bot.get("POSTGRES_USER", ""),
        "POSTGRES_PASSWORD": legacy_bot.get("POSTGRES_PASSWORD", ""),
        "REMNAWAVE_API_URL": legacy_bot.get("REMNAWAVE_API_URL", ""),
        "REMNAWAVE_API_KEY": legacy_bot.get("REMNAWAVE_API_KEY", ""),
        "REMNAWAVE_SECRET_KEY": legacy_bot.get("REMNAWAVE_SECRET_KEY", ""),
        "REMNAWAVE_WEBHOOK_SECRET": legacy_bot.get("REMNAWAVE_WEBHOOK_SECRET", ""),
        "WEBHOOK_SECRET_TOKEN": legacy_bot.get("WEBHOOK_SECRET_TOKEN", ""),
        "WEB_API_DEFAULT_TOKEN": legacy_bot.get("WEB_API_DEFAULT_TOKEN", ""),
        "BOT_HTTP_PORT": legacy_bot.get("WEB_API_PORT", "8080"),
        "CABINET_JWT_SECRET": legacy_bot.get("CABINET_JWT_SECRET", ""),
        "APP_NAME": legacy_cabinet.get("VITE_APP_NAME", "Bot Service"),
        "APP_LOGO": legacy_cabinet.get("VITE_APP_LOGO", "B"),
    }

    with tempfile.TemporaryDirectory(prefix=".migration-candidate-", dir=state_dir) as candidate:
        candidate_dir = Path(candidate)
        candidate_bot = candidate_dir / "bot.env"
        candidate_cabinet = candidate_dir / "cabinet.env"
        render_installation(config, candidate_bot, candidate_cabinet)
        minimal_keys = set(_read_env(candidate_bot))

        advanced = {
            key: value
            for key, value in legacy_bot.items()
            if key not in minimal_keys
            and not key.startswith("HELEKET_")
            and value != application_defaults.get(key, "")
        }
        candidate_override = candidate_dir / "bot.override.env"
        _write_env(candidate_override, advanced)

        for destination in (bot_env_path, cabinet_env_path, override_path):
            if destination.exists() and not destination.is_file():
                raise OSError(f"migration destination is not a file: {destination}")

        try:
            os.replace(candidate_bot, bot_env_path)
            os.replace(candidate_cabinet, cabinet_env_path)
            os.replace(candidate_override, override_path)
        except OSError:
            _atomic_copy(backup_dir / "bot.env", bot_env_path)
            _atomic_copy(backup_dir / "cabinet.env", cabinet_env_path)
            backup_override = backup_dir / "bot.override.env"
            if backup_override.exists():
                _atomic_copy(backup_override, override_path)
            elif override_path.is_file():
                override_path.unlink()
            raise

    return MigrationResult(backup_dir=backup_dir, override_path=override_path)


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: installation_config.py <command> ...", file=sys.stderr)
        return 2

    command = argv[0]
    if command == "render":
        if len(argv) < 3:
            print(
                "usage: installation_config.py render <bot-env> <cabinet-env> KEY=VALUE ...",
                file=sys.stderr,
            )
            return 2
        config: dict[str, str] = {}
        for item in argv[3:]:
            if "=" not in item:
                print(f"invalid configuration value: {item}", file=sys.stderr)
                return 2
            key, value = item.split("=", 1)
            config[key] = value
        render_installation(config, Path(argv[1]), Path(argv[2]))
        return 0

    if command == "migrate":
        if len(argv) not in (2, 3):
            print(
                "usage: installation_config.py migrate <state-dir> [application-defaults-env]",
                file=sys.stderr,
            )
            return 2
        defaults = _read_env(Path(argv[2])) if len(argv) == 3 else {}
        result = migrate_legacy_installation(Path(argv[1]), defaults)
        print(result.backup_dir)
        return 0

    if command == "create-draft" and len(argv) == 2:
        draft = create_settings_draft(Path(argv[1]))
        print(draft.bot_env)
        print(draft.cabinet_env)
        print(draft.override_env)
        return 0

    if command == "plan-draft" and len(argv) == 2:
        print(build_redacted_change_plan(Path(argv[1])))
        return 0

    if command == "promote-draft" and len(argv) == 2:
        promote_settings_draft(Path(argv[1]))
        return 0

    if command == "replace-postgres-password" and len(argv) == 3:
        replace_postgres_password(Path(argv[1]), argv[2])
        return 0

    print(f"invalid arguments for command: {command}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
