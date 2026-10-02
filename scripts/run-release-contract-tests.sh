#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -m unittest discover -s tests
bash tests/integration/package-manager-lock.sh
sudo -E bash tests/integration/recovery-runtime-adapter.sh
bash tests/integration/firewall.sh
bash tests/integration/caddy-regeneration-failure.sh
bash tests/integration/deploy-safe-stop.sh
bash tests/integration/full-install-transaction.sh
bash tests/integration/fresh-install-release-bundle.sh
bash tests/integration/fresh-install-project-root.sh
bash tests/integration/first-install-pending-state.sh
bash tests/integration/first-install-runtime-change.sh
bash tests/integration/migration-discard-identity.sh
bash tests/integration/migration-export-cleanup.sh
bash tests/integration/completed-migration-runtime-identity.sh
bash tests/integration/settings-runtime-change.sh
bash tests/integration/release-bundle-shell.sh
bash tests/integration/postgres-dump-verification.sh
bash tests/integration/protected-update-adapter.sh
bash tests/integration/protected-update-recovery.sh
bash tests/integration/runtime-isolation.sh
bash tests/integration/management-launcher.sh
bash tests/integration/production-readiness.sh
