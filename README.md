# Установщик Bot Stack

Интерактивный установщик и меню обслуживания для Bedolaga бота и веб-кабинета.

Целевая схема:

- Ubuntu 24.04
- Caddy на хосте
- Docker Compose для бота, PostgreSQL и Redis
- отдельный домен для webhook
- отдельный домен для кабинета и mini app

Запуск:

```bash
sudo bash bot-menu.sh
```

Основное:

- Корень рабочей установки по умолчанию: `/opt/bot-stack`
- Основной state-файл: `<PROJECT_ROOT>/state/install.state`
- Лог установщика: `<PROJECT_ROOT>/state/installer.log`
- File backups без PostgreSQL и Redis: `<PROJECT_ROOT>/state/backups/`
- Быстрые точки: `<PROJECT_ROOT>/state/snapshots/`
- Установщик запоминает последний `PROJECT_ROOT` и использует его при следующем запуске
- Генерируемые файлы: минимальный `bot.env`, пользовательский `bot.override.env`, `cabinet.env`, `docker-compose.yml`, `bot-stack.caddy`
- Репозитории по умолчанию: официальные Bedolaga bot и cabinet, хранятся в state
- Меню включает установку, обслуживание, обновления, восстановление, домены и Caddy, firewall, резервирование и удаление
- Отдельный перенос между VPS сохраняет актуальную PostgreSQL, Redis, точные Git SHA и Docker-образы
- `Резервирование` объединяет быстрые точки и проверяемые file backups
- File backup содержит встроенные manifest и checksums, но не PostgreSQL и Redis
- Для другой VPS и disaster recovery используется отдельный migration package
- При обновлении Telegram webhook ожидающие события по умолчанию не сбрасываются
- Production-обновление использует проверенный [Release Bundle](docs/release-bundle.md) с точными Git SHA, image digests и Cabinet checksum
- Первая production-установка также требует Release Bundle и не собирает Cabinet frontend на VPS
- Базовый `bot.env` содержит только настройки Telegram Bot, PostgreSQL, Redis, Cabinet Mini App, Web API и Remnawave webhooks
- Пароль PostgreSQL и runtime-секреты генерируются автоматически; известные пароли по умолчанию не используются
- Опциональные платежи и другие функции Bot не включаются базовым installer profile и используют defaults приложения до отдельной настройки
- Дополнительные настройки хранятся в `bot.override.env`; installer не перезаписывает их при регенерации минимального профиля
- Редактор работает с private draft-копиями и показывает redacted plan до явного применения
- Старый широкий `bot.env` автоматически переносится один раз с safety backup в `state/migration-backups/`
- Deploy, settings apply и PostgreSQL credential rotation используют outcomes `committed`, `rolled back` или `safely stopped`
- Полная установка автоматически включает UFW для текущего SSH-порта, HTTP, HTTPS и HTTP/3 без сброса существующих правил

Краткий порядок первой установки: [INSTALL.md](INSTALL.md).
Рабочие сценарии обслуживания: [RUNBOOK.md](RUNBOOK.md).
Перенос на другую VPS: [MIGRATION.md](MIGRATION.md).
Контракт production-релиза: [docs/release-bundle.md](docs/release-bundle.md).

## Проверки

Быстрые configuration tests:

```bash
python3 -m unittest tests.test_installation_config
```

Изолированная проверка firewall без изменения правил хоста:

```bash
bash tests/integration/firewall.sh
bash tests/integration/deploy-safe-stop.sh
bash tests/integration/full-install-transaction.sh
bash tests/integration/fresh-install-release-bundle.sh
bash tests/integration/first-install-pending-state.sh
bash tests/integration/first-install-runtime-change.sh
bash tests/integration/settings-runtime-change.sh
bash tests/integration/release-bundle-shell.sh
```

Полный smoke требует disposable Ubuntu 24.04, тестовые домены и отдельные credentials:

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
