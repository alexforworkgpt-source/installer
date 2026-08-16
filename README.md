# Installer

Интерактивная установка и обслуживание Upstream Bot и выбранного Cabinet
frontend. По умолчанию Release Bundle собирается из публичного Custom Cabinet;
legacy Bundle сохраняют точный исторический Upstream Cabinet.

Целевая схема:

- Ubuntu 24.04
- Caddy на хосте
- Docker Compose для бота, PostgreSQL и Redis
- отдельный домен для webhook
- отдельный домен для кабинета и mini app

## Запуск на новой VPS

Если Installer ещё не скачан, загрузите архив точного immutable Release tag,
проверьте checksum и только после этого запускайте скрипт:

```bash
RELEASE_TAG=v2026.08.5
RELEASE_NAME=2026.08.5
INSTALLER_DIR="$HOME/installer-${RELEASE_TAG}"

mkdir -p "${INSTALLER_DIR}"
cd "${INSTALLER_DIR}"

curl -fLO "https://github.com/alexforworkgpt-source/installer/releases/download/${RELEASE_TAG}/installer-${RELEASE_NAME}.tar.gz"
curl -fLO "https://github.com/alexforworkgpt-source/installer/releases/download/${RELEASE_TAG}/installer-${RELEASE_NAME}.tar.gz.sha256"

sha256sum --check "installer-${RELEASE_NAME}.tar.gz.sha256"
tar -xzf "installer-${RELEASE_NAME}.tar.gz"

sudo bash bot-menu.sh
```

Проверка checksum должна вывести:

```text
installer-2026.08.5.tar.gz: OK
```

Если файлы Installer уже находятся в текущем каталоге, достаточно выполнить
`sudo bash bot-menu.sh`. После первой установки меню обслуживания запускается
командой `sudo vpn`.

Основное:

- Корень рабочей установки по умолчанию: `/opt/bot-stack`
- Стабильная установленная копия installer: `/opt/bedolaga-installer/current`
- Команда обслуживания после первой установки: `sudo vpn`
- Основной state-файл: `<PROJECT_ROOT>/state/install.state`
- Лог установщика: `<PROJECT_ROOT>/state/installer.log`
- File backups без PostgreSQL и Redis: `<PROJECT_ROOT>/state/backups/`
- Быстрые точки: `<PROJECT_ROOT>/state/snapshots/`
- Установщик запоминает последний `PROJECT_ROOT` и использует его при следующем запуске
- Генерируемые файлы: минимальный `bot.env`, пользовательский `bot.override.env`, `cabinet.env`, `docker-compose.yml`, `bot-stack.caddy`
- Точные Bot/Cabinet repository URL и Git SHA хранятся в state
- Меню включает установку, обслуживание, обновления, восстановление, домены и Caddy, firewall, резервирование и удаление
- Отдельный перенос между VPS сохраняет актуальную PostgreSQL, Redis, точные Git SHA и Docker-образы
- `Резервирование` объединяет быстрые точки и проверяемые file backups
- File backup содержит встроенные manifest и checksums, но не PostgreSQL и Redis
- Для другой VPS и disaster recovery используется отдельный migration package
- При обновлении Telegram webhook ожидающие события по умолчанию не сбрасываются
- Production-обновление использует проверенный [Release Bundle](docs/release-bundle.md) с точными repository URL, Git SHA, image digests и Cabinet checksum
- Первая production-установка также требует Release Bundle и не собирает Cabinet frontend на VPS
- Базовый `bot.env` содержит только настройки Telegram Bot, PostgreSQL, Redis, Cabinet Mini App, Web API и Remnawave webhooks
- Пароль PostgreSQL и runtime-секреты генерируются автоматически; известные пароли по умолчанию не используются
- Опциональные платежи и другие функции Bot не включаются базовым installer profile и используют defaults приложения до отдельной настройки
- Дополнительные настройки хранятся в `bot.override.env`; installer не перезаписывает их при регенерации минимального профиля
- Редактор работает с private draft-копиями и показывает redacted plan до явного применения
- Старый широкий `bot.env` автоматически переносится один раз с safety backup в `state/migration-backups/`
- Deploy, settings apply и PostgreSQL credential rotation используют outcomes `committed`, `rolled back` или `safely stopped`
- Полная установка автоматически включает UFW для текущего SSH-порта, HTTP, HTTPS и HTTP/3 без сброса существующих правил
- Bot работает с UID/GID `1000:1000`; writable data, logs и uploads принадлежат этому пользователю
- Compose project identity вычисляется из полного `PROJECT_ROOT`; глобальные container names не используются
- Webhook-домен пропускает только `/webhook` и `/remnawave-webhook`, остальные routes отвечают `404`
- Обычный uninstall сохраняет management/recovery tooling; его удаление требует отдельного `REMOVE_INSTALLER`

Краткий порядок первой установки: [INSTALL.md](INSTALL.md).
Рабочие сценарии обслуживания: [RUNBOOK.md](RUNBOOK.md).
Перенос на другую VPS: [MIGRATION.md](MIGRATION.md).
Контракт production-релиза: [docs/release-bundle.md](docs/release-bundle.md).
Техническая атрибуция и совместимые legacy-identifiers:
[docs/technical-attribution.md](docs/technical-attribution.md).

## Откуда устанавливаются компоненты

| Компонент | Источник при установке или обновлении |
|---|---|
| Installer | Архив точного tag из публичного Release `installer` |
| Upstream Bot | Upstream-репозиторий, точный Git SHA; сборка выполняется на VPS |
| Custom Cabinet по умолчанию; Upstream Cabinet в legacy Bundle | Готовый `cabinet-dist.tar.gz` из Release `installer` |
| PostgreSQL и Redis | Docker-образы по неизменяемым `@sha256` digest |

GitHub Actions собирает Cabinet frontend из точного SHA выбранного публичного
GitHub-репозитория. Исходники Upstream Bot и Cabinet frontend в Release `installer` не
копируются. Новая версия в `main` upstream-репозитория не устанавливается
автоматически: сначала должен быть опубликован новый проверенный Bundle.

Release Bundle schema v2 фиксирует `cabinet.repository`. Перед применением
schema v2 Bundle на существующей VPS сначала запустите Installer из архива того
же или более нового tag. Installer из `v2026.08.3` и старше намеренно отклоняет
schema v2 до изменения runtime. Порядок обновления описан в
[RUNBOOK.md](RUNBOOK.md#обновление-installer-перед-schema-v2).

Понятная схема первой установки, обновления и кастомизации Cabinet:
[docs/release-and-update-flow.md](docs/release-and-update-flow.md).

## Проверки

Быстрые configuration tests:

```bash
python3 -m unittest tests.test_installation_config
```

Изолированная проверка firewall без изменения правил хоста:

```bash
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
bash tests/integration/settings-runtime-change.sh
bash tests/integration/release-bundle-shell.sh
bash tests/integration/postgres-dump-verification.sh
bash tests/integration/protected-update-adapter.sh
bash tests/integration/protected-update-recovery.sh
bash tests/integration/runtime-isolation.sh
bash tests/integration/management-launcher.sh
bash tests/integration/production-readiness.sh
```

Полный lifecycle gate требует disposable Ubuntu 24.04, не менее 1.5 GB RAM и
3 GB свободного диска, тестовые домены и отдельные credentials. Он выполняет
fresh/repeat install, settings apply, update, injected rollback, recovery,
изоляцию двух projects и uninstall:

```bash
sudo RUN_INSTALLER_INTEGRATION=1 \
  TEST_HOOK_DOMAIN=hooks-test.example.com \
  TEST_APP_DOMAIN=app-test.example.com \
  TEST_BOT_TOKEN=... \
  TEST_BOT_USERNAME=... \
  TEST_ADMIN_IDS=... \
  TEST_REMNAWAVE_API_URL=... \
  TEST_REMNAWAVE_API_KEY=... \
  TEST_REMNAWAVE_SECRET_KEY=... \
  TEST_REMNAWAVE_WEBHOOK_SECRET=... \
  bash tests/integration/minimal-stack.sh
```

Для удалённого тестового VPS используйте `tests/integration/run-remote.py run
--confirm-disposable-server`. Флаг — обязательное явное подтверждение
destructive gate и действует только в памяти; private `server.env` не меняется.
