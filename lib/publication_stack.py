"""Protected lifecycle identities derived from the selected publication manifest."""

import json
from pathlib import Path

from lib.release_bundle import load_release_bundle


def protected_stack(manifest: Path) -> dict:
    value = json.loads(manifest.read_text(encoding="utf-8"))
    if type(value.get("schema_version")) is not int or value["schema_version"] != 2:
        raise ValueError("new publication evidence requires manifest schema v2")
    bundle = load_release_bundle(manifest, 1)
    return {
        "bot_repository": bundle.bot.repository, "bot_sha": bundle.bot.sha,
        "postgres_image": bundle.images.postgres, "redis_image": bundle.images.redis,
        "backend_contract": bundle.backend_contract,
        "bot_backend_contract": bundle.backend_contracts.bot,
        "cabinet_backend_contract": bundle.backend_contracts.cabinet,
        "configuration_schema": bundle.configuration_schema, "manifest_schema": 2,
        "migration_policy": bundle.migration_policy,
        "target_os": "ubuntu-24.04", "target_platform": "linux/amd64",
    }
