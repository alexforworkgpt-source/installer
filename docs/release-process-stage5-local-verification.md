# Этап 5: локальная проверка release process

Date: 2026-10-01<br>
Status: local contract gate PASS; полный этап 5 не завершён<br>
Plan: [release-process-implementation-plan.md](release-process-implementation-plan.md)<br>
Decision: [ADR 0001](adr/0001-independent-project-releases-and-bundles.md)

## Что проверено

1. **В Installer:** полный `scripts/run-release-contract-tests.sh` выполнен на
   Ubuntu 24.04.4 / `linux/amd64`, Python 3.12.3, Git 2.43.0. Результат:
   138 Python tests PASS без skips и 21 shell harness PASS, exit code 0.
   Список из 22 команд сверён с publication workflow Installer HEAD
   `b54219d34a582e393f397a4441c6aacc52f274a8`: прежние проверки сохранены.
2. **В Docker Desktop на локальном компьютере:** использован уже имевшийся
   образ `ubuntu@sha256:561618e2c15bf2397621dd04f96926663a3b5616c189cf7e38db7e82f5c538ea`.
   Python/Git/sudo/curl/jq установлены только внутри временного контейнера.
   Во время tests у него нет сети, host mounts или Docker socket.
   Тестовые изменения `/opt` и `/etc/caddy` остаются внутри контейнера.
   Подменённые сервисы не подключаются к настоящему Bot, Docker runtime,
   Telegram, панели, платежам или production.
3. **В обоих проектах:** `actionlint` 1.7.12 PASS с отключёнными недоступными
   интеграциями shellcheck/pyflakes; отдельно `bash -n` PASS для 24 Installer
   и 24 Custom Cabinet workflow run blocks. Diff whitespace check PASS.
   Secret-shape scan публичных release документов/workflows/Python/scripts PASS;
   он проверяет характерные формы credentials, не доказывает отсутствие любых
   возможных секретов. Public branding и Markdown links проверены тестами Installer.
4. **В Custom Cabinet:** 38 hashes прежних dirty/untracked файлов владельца
   совпали с сохранённым baseline; README отличается от baseline только
   абзацем Release Boundary. Source, dependencies, LICENSE и UPSTREAM.md
   не изменены в этом продолжении. Прежние этапа 3 результаты 991 frontend
   tests на Node 24/26, type-check/build и 12 publication fixtures остаются
   ранее выполненными проверками; они не выдаются за новый Linux CI.
   Frontend/browser suite не повторялся, потому что новых source изменений нет.
5. **В Custom Cabinet release scripts:** все 12 publication tests прошли
   дополнительно на Linux: Node 24.18.1, Git 2.39.5, Debian 12 из локального
   образа `node@sha256:235600a8101ab264e117b1768e925532262668dc9b581ef1dd7d96ced463b8e7`.
   Tests выполнялись в отдельном контейнере без сети, host mounts и Docker
   socket; Git/API fixtures вымышленные. Контейнер удалён. Это проверка
   платформы release scripts, не настоящий GitHub CI/CodeQL или publication.
6. **В Installer runtime image guard:** `verify_runtime_images` проверен
   реальными `docker pull --platform linux/amd64` и `docker image inspect`
   для PostgreSQL/Redis из публичного manifest `v2026.10.01`. Оба exact digest
   и платформа PASS; сервисы и базы не запускались. Manifest/provenance скачаны
   штатным public downloader без Authorization; runtime Bundle identity
   совпала с reference из workspace CONTEXT.md.

## Source и локальные результаты

Тестировался public snapshot dirty Installer working tree, включая локальные
изменения этапов 1–4. Он собран по явному списку public project paths; `.git`,
private environment, `state`, `.scratch`, caches и generated private files
не копировались. Коммиты исходных репозиториев не создавались; существующие
tests создают только вымышленные Git fixtures во временных каталогах.

Это **не** exact committed source и **не** reviewed lifecycle/promotion record.
Результаты нельзя помещать в `releases/evidence/` как подтверждение настоящего
lifecycle, publication или smoke. Изменённому Installer нужен новый чистый
source commit и собственный trusted full lifecycle.

Локальные артефакты находятся в OS temporary directory Windows:

- `installer-stage5-linux-contract-20261001.log` — полный contract log;
- `installer-stage5-container-setup-20261001.log` — подготовка контейнера;
- `installer-stage5-final-docs-20261001.log` — 7 public branding/Markdown-link
  tests PASS на Linux после уточнений документации;
- `installer-stage5-static-20261001.log` — Bash syntax, сохранность contract
  commands и secret-shape scan;
- `installer-stage5-contract-20261001/snapshot.json` и `public-source.tar` —
  финальный public snapshot рабочей копии после уточнений документации.
- `cabinet-stage5-linux-publication-20261001.log` — 12 Linux publication tests;
- `installer-stage5-runtime-20261001.log` и
  `installer-stage5-runtime-20261001-2gfu9pv8/` — read-only GitHub settings,
  public manifest/provenance и результат настоящих digest pulls.

Первоначальный snapshot для полного contract gate содержал 107 файлов;
SHA-256 переданного tar:
`c78d26287d3dcfcd78329b4941f1c1d2a6445646adba8facff9c724d7fb92968`.
После tests все 107 файлов контейнера побайтно совпали с этим snapshot.
Финальный snapshot содержит также этот отчёт и обновлённые инструкции;
он не выдаётся за архив, на котором выполнен первоначальный полный gate.

Последние документационные уточнения после полного contract gate проверяются
отдельно public branding/Markdown-link tests и static checks. Они не меняют
runtime или publication code. Временный тестовый контейнер после проверки
удалён; чужие локальные containers/images не изменялись.

## Согласованность инструкций

В Installer обновлены README, INSTALL, RUNBOOK, `release-bundle.md` и
`release-and-update-flow.md`: раздельные Installer/Bundle tags и archive names,
reviewed lifecycle inputs вместо строковой attestation, public prerelease с
`latest=false`, stable promotion без замены assets, exact protected tuple reuse.
В Custom Cabinet `RELEASE_PROCESS.md` теперь ссылается на подготовленный
Bundle promotion и явно сохраняет отсутствие автоматического Cabinet promotion.
Исторические tags/URL, runtime schema v1/v2 и source attribution сохранены.

## Read-only проверка GitHub settings

На 2026-10-01 успешные API GET `rulesets?includes_parents=true` и `environments`
для `alexforworkgpt-source/installer` и `alexforworkgpt-source/custom-cabinet`
вернули:

- Rulesets обоих репозиториев: пустой список. Новые tag-prefix rulesets
  отсутствуют; это не проверка отдельной classic branch protection.
- Installer: environment `production-release` существует, но
  `protection_rules=[]`, `deployment_branch_policy=null`. Он не обеспечивает
  запланированное подтверждение reviewer перед publication/promotion.
- Custom Cabinet: список environments пуст; `production-release` отсутствует.
  Упоминание environment в локальном workflow не доказывает наличие approval rules.
- Historical Release `v2026.10.01`, ID `400899095`: `immutable=false`.
  Это свойство старого Release, не доказательство состояния настройки для
  будущих Releases; исторические assets/settings не менялись.

Эти пробелы блокируют первый внешний запуск по согласованному ADR до отдельной
настройки и проверки защит. Все вызовы только читали API; GitHub settings,
environments, rulesets, Releases и refs не изменялись.

## Пакет diff для review

В OS temporary directory подготовлены отдельные patches Installer и Custom
Cabinet с inventory file hashes и исходными HEAD. Installer: 41 файл процесса;
Custom Cabinet: 22 файла workflows/release scripts/docs. Cabinet README patch
построен относительно сохранённого owner baseline, поэтому включает только
Release Boundary. Application source, dependencies, browser tests и остальные
изменения владельца не включены. Для обоих patches `git apply --reverse --check`
прошёл без изменения index/worktree: patch соответствует текущим локальным bytes.
Это материал для review, а не source commit, человеческое approval или Release Bundle.

## Что остаётся непроверенным

| Gate | Состояние и причина |
| --- | --- |
| Новый exact clean Installer source | Не создан: в этой работе запрещены коммиты; dirty snapshot не заменяет commit |
| GitHub test repository | Не создавался; upload/download, actual permissions, native immutability, environment approval и metadata PATCH требуют отдельного разрешения на внешний тест |
| Tag/branch/environment protections | Read-only rulesets/environment проверены: tag-prefix rulesets отсутствуют, Installer approval rules пусты, Cabinet environment отсутствует; classic branch protection и будущая native immutability не проверены, настройки не менялись |
| Новый full lifecycle Ubuntu 24.04 | Не запускался на disposable VPS; прежний proof `b54219d…` не покрывает изменённый Installer |
| Registry pulls protected runtime digests | PASS для exact PostgreSQL/Redis из reference Bundle `v2026.10.01`; выбранный будущий состав должен пройти этот guard заново |
| Previous → candidate transition | Не выполнялся; обязателен при изменении Bot/images/contracts относительно явно выбранного previous Bundle |
| Final public Bundle smoke | Не выполнялся: candidate нового процесса ещё не опубликован |
| Telegram/payment/panel/renewal/concurrency | Живые сценарии не выполнялись; coverage остаётся BLOCKED/OPEN или отдельно принятым владельцем риском |

Коммитов, push, tags, Releases, GitHub settings, SSH/VPS действий и production
изменений в этом продолжении нет. Исторический backfill этапа 6 не начинался.
Следующий шаг после отдельного разрешения — reviewed clean source, изолированный
GitHub test и trusted lifecycle; порядок внешних действий определён планом и
[RUNBOOK](../RUNBOOK.md#публикация-нового-release-bundle).
