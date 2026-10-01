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

Ниже сохранён пример исторического Bundle `v2026.08.5`, а не выбор текущего
production Bundle. Имена архивов новых отдельных Releases описаны в
[INSTALL.md](INSTALL.md#обновление-существующего-installer).

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

Разделение Releases Installer, Custom Cabinet и Release Bundle:
[ADR 0001](docs/adr/0001-independent-project-releases-and-bundles.md) и
[план реализации](docs/release-process-implementation-plan.md). Документы
фиксируют направление работы. Локально подготовлены безопасный lifecycle source,
раздельные tags и workflows Installer/Bundle и связанное lifecycle evidence.
Локально подготовлены собственный workflow Custom Cabinet и отдельный
metadata-only `Promote Release Bundle` с проверкой public candidate и stable
project Releases. Изменения ещё не опубликованы и не проверены в GitHub.
Новый порядок и его
границы описаны в `RUNBOOK.md`, формат proof — в
[docs/lifecycle-evidence.md](docs/lifecycle-evidence.md).
Candidate → stable evidence:
[docs/bundle-promotion-evidence.md](docs/bundle-promotion-evidence.md).

## Откуда устанавливаются компоненты

| Компонент | Источник при установке или обновлении |
|---|---|
| Installer | Архив exact source из собственного Installer Release или выбранного Release Bundle |
| Upstream Bot | Upstream-репозиторий, точный Git SHA; сборка выполняется на VPS |
| Custom Cabinet по умолчанию; Upstream Cabinet в legacy Bundle | Готовый `cabinet-dist.tar.gz` из выбранного Release Bundle в репозитории Installer |
| PostgreSQL и Redis | Docker-образы по неизменяемым `@sha256` digest |

GitHub Actions собирает Cabinet frontend из точного SHA выбранного публичного
GitHub-репозитория. Исходники Upstream Bot и Cabinet frontend в assets Release Bundle не
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

Полный набор contract tests в disposable Linux окружении:

```bash
PYTHONDONTWRITEBYTECODE=1 bash scripts/run-release-contract-tests.sh
```

Recovery harness использует тестовые пути в `/opt` и `/etc/caddy`; запускайте
набор в отдельном контейнере или disposable VM, где эти пути не заняты.
Contract tests подменяют внешние сервисы и не заменяют полный lifecycle,
проверку публикации на GitHub или живые интеграции.

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

Для удалённого тестового VPS используйте clean Git candidate Installer:

```bash
INSTALLER_SOURCE_SHA="$(git rev-parse HEAD)"
python3 tests/integration/run-remote.py run \
  --source-sha "${INSTALLER_SOURCE_SHA}" --confirm-disposable-server
```

Runner проверяет exact HEAD и отсутствие uncommitted source до подключения,
архивирует только committed public files и выводит Installer SHA, tree SHA и
checksum отправляемого архива. Private environment, state и generated files
не отправляются. Изменения нужно подготовить отдельным проверенным commit;
runner не коммитит и не очищает рабочую копию. Распакованный Release archive
без Git metadata не является source для этого lifecycle gate.

Флаг `--confirm-disposable-server` — обязательное явное подтверждение destructive
gate и действует только в памяти; private `server.env` не меняется. Проверки
`preflight`/`final-postflight` не требуют `--source-sha` и не загружают source.
