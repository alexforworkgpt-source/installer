# Runbook

Расположение state:

- основной файл: `<PROJECT_ROOT>/state/install.state`
- pending первой установки: `<PROJECT_ROOT>/state/install.state.pending-first-install`
- минимальный runtime env: `<PROJECT_ROOT>/state/bot.env`
- дополнительные настройки: `<PROJECT_ROOT>/state/bot.override.env`
- черновик настроек: `<PROJECT_ROOT>/state/draft/`
- последний использованный путь: `state/last_project_root`
- лог установщика: `<PROJECT_ROOT>/state/installer.log`
- file backups: `<PROJECT_ROOT>/state/backups/`
- быстрые точки: `<PROJECT_ROOT>/state/snapshots/`
- резервные копии UFW: `<PROJECT_ROOT>/state/firewall-backups/`
- стабильная management-копия: `/opt/bedolaga-installer/current/`
- launcher: `/usr/local/bin/vpn` (`sudo vpn`)

Compose project name имеет вид `bedolaga-<basename>-<hash PROJECT_ROOT>`.
Контейнеры и volumes выбираются по Compose labels, поэтому разные `PROJECT_ROOT`
не используют глобальные имена и могут сосуществовать. Bot работает как
`1000:1000`; writable каталоги `data`, `logs`, `uploads` принадлежат этому UID.

File backup не содержит PostgreSQL, Redis, Git-репозитории или Docker-образы.
Для переноса установки и disaster recovery используйте migration package из
[MIGRATION.md](MIGRATION.md), а не раздел резервирования.

## Первая и повторная установка

- первая установка пишет конфигурацию в `install.state.pending-first-install`
- рабочий `install.state` появляется атомарно только после обязательных health checks
- до рендера generated files создаётся `runtime-change.in-progress`
- после hard crash следующий запуск удаляет только каталог с точным ownership marker
- если crash произошёл после commit, installer повторно проверяет runtime и сохраняет terminal receipt
- запуск установки при существующем `install.state` считается repeat install и выполняется через Protected Update с PostgreSQL dump

## Резервирование

- `Обслуживание -> Резервирование`
- `Создать быструю точку` сохраняет настройки и служебные файлы перед изменениями
- `Создать file backup` сохраняет `state`, `runtime/bot/data`, `runtime/bot/logs`, `runtime/bot/uploads`, `runtime/cabinet-dist`
- file backup не включает старые архивы из `state/backups`, applied hashes, draft и migration markers
- manifest, project root и SHA-256 каждого файла находятся внутри artifact и проверяются до остановки сервисов
- очистка старых быстрых точек и file backups доступна из того же меню
- `Восстановить быструю точку` возвращает `install.state`, `bot.env`, `cabinet.env`, `docker-compose.yml` и Caddy candidate из выбранного snapshot
- `Восстановить file backup` выполняет полный Recovery lifecycle для `state` и перечисленных runtime-каталогов

## File backup и migration package

| Artifact | File backup | Migration package |
|---|---|---|
| Назначение | Восстановление файлов на той же VPS | Перенос и disaster recovery на другой VPS |
| `state`, uploads, Bot data/logs, Cabinet dist | Да | Да |
| PostgreSQL | Нет | Да, согласованный dump |
| Redis | Нет | Да |
| Git repositories и точные SHA | Нет | Да |
| Точные Docker images | Нет | Да |
| Checksums | Внутри artifact | Внутри и во внешнем `.sha256` |

Оба artifact содержат секреты. Храните их с правами `600`, передавайте только
по SSH/SCP и держите проверенную копию вне production VPS. Локальный
`state/backups` не защищает от потери диска или всей VPS. После копирования
file backup на отдельное хранилище проверьте его до инцидента:

```bash
sudo python3 /path/to/installer/lib/recovery.py validate \
  /off-host/path/FILE-file-backup.tar.gz /opt/bot-stack
```

Периодически выполняйте тестовое восстановление на disposable Ubuntu 24.04.
Не считайте file backup заменой migration package: в нём нет PostgreSQL и Redis.

## Новости и uploads

- загруженные медиафайлы кабинета хранятся в `runtime/bot/uploads`
- bot-контейнер получает эту папку как `/app/uploads`
- Caddy отдаёт `/uploads/*` с app-домена из `runtime/bot/uploads`
- для app-домена установлен лимит тела запроса `50MB`

## Первая установка

- `Установка -> Полная установка`
- `Установка -> Проверка сервера` рекомендуется перед первой установкой
- полная установка автоматически разрешает текущий SSH-порт, `80/tcp`, `443/tcp` и `443/udp`, затем включает UFW
- остальные входящие соединения запрещаются, исходящие остаются разрешёнными
- существующие UFW-правила не удаляются и `ufw reset` не используется

## Firewall

- `Обслуживание -> Firewall -> Показать статус` выводит полную политику UFW
- `Применить базовые правила` безопасно добавляет недостающие правила и подходит для уже установленного стека
- `Проверить защиту` проверяет профиль UFW и отсутствие публичных портов Bot API, PostgreSQL и Redis
- повторное применение ничего не меняет, если профиль уже корректен
- конфликтующий `DENY/REJECT` для обязательного порта останавливает операцию до включения UFW, чтобы не потерять SSH-доступ
- внешний firewall панели VPS installer не изменяет; там должны быть разрешены SSH, `80/tcp`, `443/tcp` и при необходимости `443/udp`

## Восстановление служебных файлов

- `Установка -> Восстановить служебные файлы`

Использовать, если меню не видит state, но в рабочей установке уже есть:
- `<PROJECT_ROOT>/state/bot.env`
- `<PROJECT_ROOT>/state/cabinet.env`

## Изменение настроек

1. `Обслуживание -> Настройки`
2. открыть черновик `bot.env`, `cabinet.env` или advanced override
3. проверить `Показать план изменений`
4. выбрать `Применить черновик` и подтвердить redacted plan
5. перед promotion установщик создаёт быструю точку в `state/snapshots/`
6. после этого проверить `Статус` и `Диагностика`

Редактор не изменяет applied-файлы напрямую. До явного применения repair,
webhook и остальные операции продолжают использовать действующую
конфигурацию. Пункт `Удалить черновик` отменяет редактирование без изменений
runtime.

## Runtime Change outcomes

Операции deploy, protected update, применения settings draft и ротации
PostgreSQL credentials защищают предыдущее состояние до первой runtime mutation.

- `committed`: новое состояние применено и прошло обязательные health checks
- `rolled back`: операция упала, прежнее состояние восстановлено и проверено
- `safely stopped`: применить изменение и доказать rollback не удалось; Bot остановлен, чтобы не работать в неизвестном состоянии

При `safely stopped` не запускайте Bot вручную. Сначала откройте installer log,
найдите указанный recovery snapshot и используйте раздел восстановления.
Последний structured result всегда сохраняется в private-файле
`<PROJECT_ROOT>/state/last-runtime-change.json`; меню показывает failed stage,
rollback verification, безопасное следующее действие и путь к логу.

Во время settings apply, PostgreSQL rotation и protected update создаётся private marker
`runtime-change.in-progress`. После прерывания installer при следующем запуске
автоматически пытается восстановить snapshot и проверить rollback. Если это не
удаётся, Bot остаётся остановленным, marker и recovery plan сохраняются для
ручного восстановления.

## Ротация PostgreSQL credentials

Используйте:

```text
Обслуживание -> Настройки -> Сменить пароль PostgreSQL
```

Installer автоматически генерирует новый пароль, меняет database role и
private Bot environment, перезапускает Bot и проверяет password-authenticated
подключение. Обычный env editor по-прежнему запрещает изменение PostgreSQL
database, user и password.
Пароль передаётся stage adapter через временный private-файл и stdin, а не через
process arguments; context удаляется после committed/rolled-back результата.

## Миграция старого env

При первом запуске генерации после обновления installer обнаруживает старый
широкий `bot.env`, если рядом ещё нет `bot.override.env`. Installer:

1. создаёт safety backup в `<PROJECT_ROOT>/state/migration-backups/`
2. формирует минимальный `bot.env`
3. переносит дополнительные non-default значения в `bot.override.env`
4. исключает устаревшие installer-specific настройки
5. заменяет applied-файлы только после успешной проверки candidates

При ошибке applied `bot.env` и `cabinet.env` остаются прежними.

## Обновление

- основной production-сценарий: `Обновления -> Обновить всё из Release Bundle`
- manifest можно получить по HTTPS или указать локальным абсолютным путём
- Release Bundle фиксирует совместимые Bot SHA, Cabinet repository и SHA, Cabinet artifact и Docker image digests
- Cabinet artifact проверяется по SHA-256 до изменения runtime
- перед dump Bot останавливается, чтобы после snapshot в PostgreSQL не появились
  новые записи, которые rollback не сможет сохранить
- до checkout создаётся и проверяется PostgreSQL custom-format dump
- installer записывает Alembic revision до и после успешного update
- dump и metadata сохраняются в `state/backups/database/`
- compatible rollback текущего bundle-managed update останавливает Bot,
  возвращает защищённые перед update repository/commits/images/Cabinet dist, восстанавливает
  dump и исходную Alembic revision, и только затем запускает Bot
- при ошибке `forward-only` release старый Bot автоматически не запускается
  против новой schema; стек получает `safely stopped` и точный recovery plan
- прерванный `rollback-compatible` update при следующем запуске автоматически
  возвращает предыдущий release, восстанавливает dump и проверяет health
- ручной выбор `latest release`, `main` или конкретного тега остаётся в расширенном меню для разработки
- перед каждым обновлением создаётся быстрая точка в `state/snapshots/`
- обновление считается успешным только после итоговой проверки
- при обновлении обоих компонентов bot и cabinet применяются как одна группа
- если групповое обновление падает, установщик откатывает оба компонента на предыдущие версии

### Обновление Installer перед schema v2

Schema v2 добавляет `cabinet.repository` в проверяемую identity Release Bundle.
Installer из `v2026.08.3` и старше не знает это поле и намеренно отклоняет schema
v2 до runtime mutation. Поэтому существующую установку обновляйте в таком порядке:

1. скачайте `installer-<RELEASE>.tar.gz` и соответствующий `.sha256` из нового
   публичного Release;
2. выполните `sha256sum --check installer-<RELEASE>.tar.gz.sha256`;
3. распакуйте архив в отдельный каталог вне `PROJECT_ROOT`;
4. запустите из этого каталога `sudo bash bot-menu.sh` — startup автоматически
   установит версионированную копию в `<INSTALLER_HOME>/current` и обновит
   launcher `sudo vpn`;
5. только после этого примените `release.json` через
   `Обновления -> Обновить всё из Release Bundle`;
6. проверьте статус, диагностику, Cabinet repository и фактический Git HEAD.

Не копируйте файлы вручную поверх `<INSTALLER_HOME>/current` и не
применяйте schema v2 старой management-копией.

Формат и процесс публикации описаны в [docs/release-bundle.md](docs/release-bundle.md).
Понятная схема источников Bot, Cabinet и Installer находится в
[docs/release-and-update-flow.md](docs/release-and-update-flow.md).

## Публикация нового Release Bundle

Публикация выполняется workflow `Publish Release Bundle` на GitHub Actions.
Cabinet собирается на runner GitHub, а не на локальном компьютере и не на VPS.
До начала убедитесь, что полный disposable Ubuntu 24.04 lifecycle gate прошёл
для публикуемого installer commit.

### 1. Выбрать неизменяемые версии

- создать и отправить новый installer tag, указывающий на проверенный commit;
- выбрать точный 40-символьный Git SHA Bot;
- выбрать публичный GitHub-репозиторий Cabinet и точный 40-символьный Git SHA;
- разрешить PostgreSQL, Redis, Node builder и Nginx runtime только в identities
  вида `image@sha256:<64 hex>`;
- выбрать release name, например `2026.08.N`, и соответствующий installer tag,
  например `v2026.08.N`.

Не используйте изменяемые `main`, `latest` или обычные Docker tags как
зафиксированные production identities.

### 2. Запустить workflow

В GitHub откройте:

```text
Actions -> Publish Release Bundle -> Run workflow
```

Заполните inputs:

| Input | Что указать |
|---|---|
| `release` | Публичное имя версии без `v` |
| `installer_tag` | Уже существующий неизменяемый tag installer |
| `bot_ref` | Точный SHA Bot |
| `cabinet_repository` | Default публичный Custom Cabinet; менять только осознанно |
| `cabinet_ref` | Точный SHA Cabinet |
| `postgres_image` | PostgreSQL image с `@sha256` |
| `redis_image` | Redis image с `@sha256` |
| `node_builder_image` | Node builder image с `@sha256` |
| `nginx_runtime_image` | Nginx runtime image с `@sha256` |
| `lifecycle_proof` | Только точное значение `ubuntu-24.04-passed` после реального gate |
| `lifecycle_sha` | Точный 40-символьный Installer SHA, на котором прошёл gate |

### 3. Дождаться полной проверки

Workflow должен успешно выполнить все этапы:

1. проверить installer tag и lifecycle attestation;
2. запустить release-contract tests;
3. разрешить Bot и Cabinet refs в точные SHA;
4. дважды собрать Cabinet и сравнить результаты byte-for-byte;
5. создать и проверить manifest;
6. создать draft Release и загрузить assets;
7. скачать draft-assets обратно, сравнить manifest/provenance и проверить checksums;
8. только после этого сделать Release публичным.

Draft не считается готовым результатом. При падении workflow найдите первый
failed step и устраните причину; не ослабляйте SHA, digest или checksum проверки.

### 4. Независимо проверить публичный Release

После публикации скачайте assets по публичным URL без GitHub-токена и проверьте:

- Release не является draft или prerelease;
- опубликованы `cabinet-dist.tar.gz`, два `.sha256`, архив installer,
  `release.json` и `release-provenance.json`;
- обе команды `sha256sum --check` завершаются успешно;
- `release.json` содержит ожидаемые Bot/Cabinet repository, SHA и PostgreSQL/Redis digests;
- checksum Cabinet в manifest совпадает с реально скачанным файлом;
- provenance содержит ожидаемые Cabinet repository/SHA, Node builder и Nginx identities;
- архив installer соответствует точному опубликованному tag;
- в installer archive отсутствуют private и generated artifacts, включая
  `server.env`, `env.txt`, `.playwright-mcp`, `__pycache__` и `*.pyc`.

Только после этой независимой проверки Release можно предлагать VPS как новый
production Bundle.

## Сервисы

- `Обслуживание -> Сервисы -> Развернуть текущую конфигурацию` — полное применение текущей конфигурации
- `Обслуживание -> Сервисы -> Пересобрать сервисы` — полная пересборка
- `Обслуживание -> Сервисы -> Перезапустить сервисы` — быстрый перезапуск

## Восстановление

- `Обслуживание -> Восстановление`

Использовать, когда нужно точечно починить конфиги, Caddy, webhook, кабинет или только бота.
`Восстановление -> Пересобрать кабинет` подходит, если проблема только в статических файлах кабинета.

## Восстановление из snapshot

- `Обслуживание -> Резервирование -> Восстановить быструю точку`
- перед восстановлением текущие служебные файлы сохраняются в новый snapshot
- после восстановления выполнить `Обслуживание -> Применить новые настройки`

## Восстановление из file backup

- `Обслуживание -> Резервирование -> Восстановить file backup`
- archive structure, project root и checksums проверяются до остановки runtime
- перед заменой файлов создаётся и проверяется safety file backup текущего состояния
- safety artifact имеет отдельную роль и сохраняет текущий draft/migration control state для точного rollback; обычный file backup их не переносит
- Bot и Caddy останавливаются до замены используемых ими файлов
- applied hashes, draft и migration markers инвалидируются до activation
- успех требует активации и проверки Docker, Caddy и Telegram
- при ошибке Recovery повторно останавливает процессы, возвращает safety backup и проверяет rollback
- если rollback доказать нельзя, Bot и Caddy остаются остановленными с recovery plan
- при SIGINT/SIGTERM Recovery запускает тот же verified rollback; marker жёстко прерванной операции при следующем запуске удерживает Bot/Caddy остановленными и показывает safety backup
- старые архивы без встроенных manifest/checksums автоматически не восстанавливаются

## Диагностика

Рекомендуемый порядок:

1. `Статус`
2. `Диагностика`
3. `Проверить домены и SSL`
4. `Логи`

`Логи -> Последние действия установщика` показывает последние действия без перехода в режим постоянного просмотра.

## Caddy и домены

- `Обслуживание -> Домены и Caddy -> Пересоздать конфиг Caddy`
- основной snippet называется по Compose project и не конфликтует с другим stack
- webhook host разрешает только `/webhook` и `/remnawave-webhook`; fallback — `404`
- candidate активируется через validation, reload и строгий public TLS post-check;
  при ошибке предыдущий snippet возвращается и reload повторяется
- лендинги хранятся в отдельных `conf.d/landing-*.caddy` и не затираются при регенерации основного конфига

## Telegram webhook

- `Обслуживание -> Восстановление -> Починить Telegram webhook`

Использовать после смены домена, токена или если Telegram смотрит на старый URL.
Ожидающие Telegram-события при обновлении webhook по умолчанию не сбрасываются.

## Удаление

- обычные варианты удаления работают только с выбранным Compose project
- `Полное удаление установки` удаляет stack/project, но сохраняет `sudo vpn` и
  установленную management/recovery-копию
- отдельное удаление installer требует точного подтверждения `REMOVE_INSTALLER`
- удаление первоначального source clone не ломает launcher

## Release lifecycle gate

Перед публикацией installer Release на disposable Ubuntu 24.04 запускается:

```bash
python3 tests/integration/run-remote.py run --confirm-disposable-server
python3 tests/integration/run-remote.py final-postflight --confirm-disposable-server
```

Gate проверяет clean preflight, minimal fresh/repeat install, legacy fixture,
settings draft/apply, protected update, injected verified rollback, file recovery,
non-root writes, второй Compose project и uninstall. Publication workflow требует
inputs `lifecycle_proof=ubuntu-24.04-passed` и точный `lifecycle_sha`; без реально
завершённого gate для этого commit их указывать нельзя. Диагностические файлы
остаются private и не должны содержать credentials.
