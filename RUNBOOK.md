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

### Первый Bundle update после legacy migration import

Установка, перенесённая прежним Installer, может хранить Compose project и
точные импортированные PostgreSQL/Redis images только в
`.migration-resources-created` и `state/migration-image.override.yml`, без этих
полей в `install.state`. Перед первым Release Bundle update новый Installer:

1. сверяет marker, override, фактические Docker containers, их images и оба
   volumes;
2. создаёт private safety backup в `state/migration-backups/`;
3. атомарно сохраняет точные `COMPOSE_PROJECT_NAME`, `POSTGRES_IMAGE` и
   `REDIS_IMAGE` в `install.state`, не перезапуская runtime;
4. копирует migration override в protected update context;
5. применяет immutable images из Bundle без override;
6. при rollback восстанавливает прежний override byte-for-byte до запуска
   предыдущего runtime.

После успешного перехода migration markers остаются как provenance, а override
больше не нужен. При следующих Bundle update Installer сверяет marker с
`install.state`, фактическими containers, images и volumes и продолжает update
без повторного импорта legacy images.

Несовпадение хотя бы одной identity останавливает update до изменения runtime.
Не удаляйте migration markers или override вручную: они являются доказательством
происхождения существующих volumes и источником автоматического rollback.

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

Ниже описаны локально подготовленные workflows `Publish Installer` и
`Publish Release Bundle`. Они ещё не опубликованы в GitHub. В опубликованном
Installer `b54219d` исходники и Bundle выбирались одним `installer_tag`;
исторические Releases и их URL остаются неизменными.

Новый Bundle workflow публикует только prerelease с `latest=false`. Собственный
`Publish Custom Cabinet` и отдельный `Promote Release Bundle` подготовлены
локально; их работа на GitHub ещё не проверена. Новый процесс пока не завершён
для production-рекомендации. Cabinet собирается на runner GitHub.
Production deployment остаётся отдельным разрешённым действием.

Перед первым публичным запуском новые source и workflow должны пройти полный
disposable Ubuntu 24.04 lifecycle, а будущие tags/Releases — получить защиту
и native release immutability по ADR. Настройки GitHub локальная реализация
не меняет. Формат и границы доверия proof описаны в
[docs/lifecycle-evidence.md](docs/lifecycle-evidence.md).

### 1. Выбрать неизменяемые версии

- выбрать существующий Installer source tag `installer-vYYYY.MM.DD[.N]` и
  exact SHA; новый source tag нужен только при изменении кода Installer;
- подготовить новый `bundle-v<release>` на том же Installer commit; оба tags
  должны уже существовать на GitHub до запуска workflow;
- выбрать точный 40-символьный Git SHA Bot;
- выбрать публичный GitHub-репозиторий Cabinet и точный 40-символьный Git SHA;
- разрешить PostgreSQL, Redis, Node builder и Nginx runtime только в identities
  вида `image@sha256:<64 hex>`;
- выбрать Bundle release name `YYYY.MM.DD[.N]`, например `2026.10.01.1`;
- получить reviewed lifecycle JSON и redacted log в `releases/evidence/`
  на доверенной default branch Installer, записать exact evidence commit/path.

Эти действия выполняются только в рамках разрешённой публикации. Подготовка
локальных workflows не создаёт tags, Releases или подтверждение реального PASS.

Не используйте изменяемые `main`, `latest` или обычные Docker tags как
зафиксированные production identities.

### 2. Запустить workflow

В GitHub откройте:

```text
Actions -> Publish Release Bundle -> Run workflow -> выбрать Installer source tag
```

Заполните inputs:

| Input | Что указать |
|---|---|
| `release` | Bundle version `YYYY.MM.DD[.N]` |
| `installer_tag` | Существующий source tag `installer-vYYYY.MM.DD[.N]` |
| `installer_sha` | Exact 40-символьный Installer commit |
| `bundle_tag` | Существующий `bundle-v<release>` на том же commit |
| `bot_ref` | Точный SHA Bot |
| `cabinet_repository` | Default публичный Custom Cabinet; менять только осознанно |
| `cabinet_ref` | Точный SHA Cabinet |
| `postgres_image` | PostgreSQL image с `@sha256` |
| `redis_image` | Redis image с `@sha256` |
| `node_builder_image` | Node builder image с `@sha256` |
| `nginx_runtime_image` | Nginx runtime image с `@sha256` |
| `lifecycle_evidence_sha` | Exact reviewed commit с proof на default branch |
| `lifecycle_evidence_path` | JSON в `releases/evidence/` на этом commit |

`Use workflow from` должен указывать на exact выбранный Installer commit:
runner проверяет `github.workflow_sha`, checkout, dereferenced source/Bundle tags
и ожидаемый SHA. Изменённый publication workflow требует нового Installer
commit и нового lifecycle proof. Строковые inputs `lifecycle_proof` и
`lifecycle_sha` старого workflow больше не служат proof нового процесса.

`Publish Installer` принимает четыре inputs: `installer_tag`, `installer_sha`
и два `lifecycle_evidence_*`. Он публикует только Installer archive/checksum,
не содержит Cabinet или `release.json` и всегда сохраняет текущий `latest` Bundle.

### 3. Дождаться полной проверки

Workflow должен успешно выполнить все этапы:

1. сверить source/workflow/tag identities и создать безопасный committed archive;
2. подтвердить отсутствие любого existing Release именно для `bundle_tag`;
3. запустить прежний полный набор release-contract tests;
4. загрузить PostgreSQL/Redis по exact digest под `linux/amd64` и проверить identity;
5. разрешить Bot/Cabinet refs, дважды собрать Cabinet и сравнить bytes;
6. создать schema v2 manifest с Cabinet URL под `bundle_tag`;
7. сверить reviewed lifecycle source/tree/archive hash и protected stack;
8. создать свой draft Bundle, загрузить шесть assets без замены existing assets;
9. скачать assets обратно, сверить exact набор/bytes всех шести файлов с runner
   и проверить manifest/provenance/checksums;
10. опубликовать только prerelease candidate, без изменения `latest`.

Draft и prerelease не являются стабильным production Bundle. Existing draft
не удаляется для повторной попытки: используйте новый tag либо отдельно разбирайте
свой незавершённый запуск. Cleanup проверяет receipt текущего run, Release ID,
tag, owner marker и draft status; public Release сохраняется. API error, включая
403/404, останавливает lookup, а не означает отсутствие Release.

### 4. Независимо проверить публичный Release

После публикации скачайте assets по публичным URL без GitHub-токена и проверьте:

- candidate является prerelease и не сменил `latest`;
- опубликованы `cabinet-dist.tar.gz`, два `.sha256`, архив installer,
  `release.json` и `release-provenance.json`;
- все шесть файлов совпадают с подготовленными bytes, обе команды
  `sha256sum --check` завершаются успешно;
- `release.json` содержит ожидаемые Bot/Cabinet repository, SHA и PostgreSQL/Redis digests;
- checksum Cabinet в manifest совпадает с реально скачанным файлом;
- provenance содержит ожидаемые Cabinet repository/SHA, Node builder и Nginx identities;
- Installer archive соответствует выбранному source SHA/tag, а Bundle tag
  указывает на тот же Installer commit;
- в installer archive отсутствуют private и generated artifacts, включая
  `server.env`, `server.prod.env`, `env.txt`, `.playwright-mcp`, `__pycache__` и `*.pyc`.

Публичный candidate можно использовать для разрешённых тестов по его точному
URL. Для production-рекомендации ещё требуются собственные stable Releases
Installer/Custom Cabinet и separate promotion gate, привязанный к этим же
asset bytes и долговременному evidence. Подготовлен workflow `Promote Release Bundle`
и формат [bundle-promotion-evidence.md](docs/bundle-promotion-evidence.md). Этапы описаны в плане;
ручно менять candidate assets или обходить promotion proof нельзя.

### 5. Проверка project Releases перед stable promotion

В Custom Cabinet подготовлен отдельный `Publish Custom Cabinet`; порядок
описан в его `RELEASE_PROCESS.md`. Он фиксирует source version и limits,
а compiled Cabinet остаётся в Release Bundle Installer.

В Installer подготовлена read-only команда; тот же guard использует promotion workflow:

```bash
python3 scripts/publication_control.py project-releases \
  --manifest /path/to/verified-public-candidate/release.json \
  --cabinet-tag cabinet-vYYYY.MM.DD
```

Она принимает `GITHUB_REPOSITORY`, `INSTALLER_TAG`, `INSTALLER_SHA`, `GH_TOKEN`
из окружения; значения токена не выводить. Проверяет stable Installer Release
и Cabinet Release в source repository из manifest. Каждый tag должен
dereference в exact selected source SHA, а draft/prerelease/missing/API error
останавливают gate. Cabinet сравнивается с `cabinet.source_sha` данного
public candidate; Installer — с проверенным source/evidence выбранного выпуска.

Исторический stable Cabinet Release без нового metadata JSON пригоден для
reuse. Изменение Bot требует нового compatibility evidence Bundle, без правки
старого Cabinet Release. Команда проверяет project identities, не smoke или
совместимость. Отдельный `Promote Release Bundle` использует тот же guard
после проверки public candidate bytes и долговременного reviewed evidence.

### 6. Перевести exact public candidate в stable

Следуйте [bundle-promotion-evidence.md](docs/bundle-promotion-evidence.md).
Сначала подтвердите применимые lifecycle/transition/smoke gates, затем примите
публичный record и очищенный журнал на default branch по reviewed процессу.
GitHub должен возвращать `immutable=true` у candidate. Этот процесс требует
нового trusted proof для первого изменённого Installer commit; прежний proof
`b54219d…` не подтверждает код нового publication/promotion процесса.

В `Promote Release Bundle` передайте source Installer tag/SHA, конечный Bundle
tag, exact promotion evidence commit/path и явно выбранный `make_latest`.
Workflow выполняется из выбранного Installer commit. Preflight использует
read-only GitHub permissions; после environment gate отдельный job повторно
скачивает public assets без токена и сверяет всё перед metadata PATCH по ID.
Запись должна согласовать тот же latest выбор; default false не вытесняет
действующий latest. Настоящие environment approval rules ещё надо проверить.

Для отдельной read-only проверки entry point:

```bash
python3 scripts/promote_release_bundle.py verify \
  --output "$RUNNER_TEMP/new-bundle-verification"
```

Нужны `INSTALLER_TAG`, `INSTALLER_SHA`, `BUNDLE_TAG`, `WORKFLOW_SHA`,
`PROMOTION_EVIDENCE_SHA`, `PROMOTION_EVIDENCE_PATH`, `DEFAULT_BRANCH`,
`GITHUB_REPOSITORY`, `MAKE_LATEST`, `GH_TOKEN`. Токен нужен только для API
metadata/run lookup; public downloads не получают Authorization. Output —
новая папка внутри RUNNER_TEMP и вне source, без перезаписи existing files.
Команда `promote` после тех же checks меняет только prerelease/latest;
ручной запуск разрешён лишь в рамках отдельно разрешённой публикации.

Результат уже stable Release — no-op с повторной проверкой, без повторной смены
latest. При API failure или несовпадении proof/bytes/run/source ничего
не исправляется внутри Release. Failed candidate сохраняется, изменённые
assets требуют нового tag. Promotion не выполняет production update.

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

Локальные contract tests запускаются отдельно от полного lifecycle:

```bash
PYTHONDONTWRITEBYTECODE=1 bash scripts/run-release-contract-tests.sh
```

Этот набор выполняется только в disposable Linux окружении: recovery harness
создаёт и удаляет тестовые пути в `/opt` и `/etc/caddy`. Он использует подменённые
сервисы и не доказывает настоящий Docker runtime, GitHub publication или
Telegram/payment integrations. Локальный dirty source допустим для этих tests,
но их PASS не является proof для source commit.

Перед первой публикацией нового Installer Release на отдельно разрешённом
disposable Ubuntu 24.04 запускается полный lifecycle:

```bash
INSTALLER_SOURCE_SHA="$(git rev-parse HEAD)"
python3 tests/integration/run-remote.py run \
  --source-sha "${INSTALLER_SOURCE_SHA}" --confirm-disposable-server
python3 tests/integration/run-remote.py final-postflight --confirm-disposable-server
```

Команды выполняются из clean Git candidate Installer, а не из распакованного
Release archive или установленной management-копии. Runner до чтения
connection environment и SSH сверяет expected SHA с HEAD и отклоняет
uncommitted tracked/untracked source. Ignored private и временные файлы не
входят в source snapshot; даже tracked environment/state/generated paths
исключаются. Источник — Git commit, не содержимое локальной папки.

Сохраните строку `Installer source` с `installer_sha`, `installer_tree_sha`
и `archive_sha256` вместе с результатом gate. Tree SHA относится к Git tree,
archive checksum — к фактически отправляемому public snapshot с исключениями.
Этот вывод подтверждает identity source, но сам по себе не означает lifecycle
PASS. `installer_sha` в lifecycle record берётся из реально проверенного commit,
а не из другого HEAD.

Gate проверяет clean preflight, minimal fresh/repeat install, legacy fixture,
settings draft/apply, protected update, injected verified rollback, file recovery,
non-root writes, второй Compose project и uninstall. Publication workflow требует
reviewed lifecycle record с exact source/stack identities; без реально
завершённого gate для этого commit такой record принимать нельзя. Диагностические файлы
остаются private и не должны содержать credentials.
