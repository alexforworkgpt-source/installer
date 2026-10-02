# План разделения Releases Installer, Custom Cabinet и Release Bundle

Status: In progress — этапы 1–4 подготовлены, локальная часть этапа 5 проверена<br>
Date: 2026-10-01<br>
Decision: [ADR 0001](adr/0001-independent-project-releases-and-bundles.md)

Локально реализованы безопасный source archive и разделение публикаций
Installer/Bundle, связанные lifecycle records и runtime image guards.
Отдельный workflow Custom Cabinet и project Release identity guard подготовлены
на этапе 3. Проверки выполнены на искусственных Git repositories и подменённых API/Docker
ответах без SSH/VPS и remote mutations. Реальный lifecycle нового Installer
commit и новые публикации ещё не выполнены. Metadata-only promotion и durable
candidate evidence подготовлены локально на этапе 4. Linux contract gate и
согласование инструкций выполнены в локальной части этапа 5; настоящий GitHub
процесс и новый lifecycle не проверены. Этап 5 целиком и этап 6 не завершены.
Workflows изменены только локально; GitHub settings, tags, Releases и production
не изменены. Обновлённые inputs и границы — в [RUNBOOK.md](../RUNBOOK.md).

## Reference point и границы

Опорная точка исследования — Bundle `v2026.10.01`:

- Installer `b54219d34a582e393f397a4441c6aacc52f274a8`;
- Custom Cabinet `cabinet-v2026.10.01.1` / `5ee46023afc373fbfcef69f6793d440aa1d2cdd0`;
- Upstream Bot `877690a7039d1326b2c00eda3e297879b80c0678`.

Это историческая проверенная identity, а не указание выбрать её `latest`
или утверждение о новом состоянии production. Перед реализацией повторно
проверяются remote refs, локальный status и актуальный workspace CONTEXT.md.
Dirty Custom Cabinet не очищается и не коммитится целиком.

Работа выполняется отдельно в Installer и Custom Cabinet. `site/`, справочная
документация Upstream Bot и Cabinet, Upstream Bot и private production material
не изменяются.
Push, публикации, GitHub settings, destructive VPS tests и production требуют
соответствующего разрешения владельца. Одобрение документа не разрешает их.

## Этапы по приоритету

### 1. P0 — безопасный и точный source для lifecycle

**Где:** Installer, `tests/integration/run-remote.py` и
`tests/test_remote_integration_runner.py`.

**Что:** исключить production environment и другие private/generated files из
отправки на test VPS; формировать проверяемый source snapshot, связанный с
точным Installer commit, вместо произвольного локального дерева.

**Почему:** в опорном Installer commit `b54219d` `.gitignore` не определял
содержимое remote archive; `server.prod.env` не исключался функцией и её тестом.
Проверка `lifecycle_sha` не доказывала равенство загруженного source tree
Git-коммиту.

**Готово, когда:** regression fixtures с вымышленными секретами подтверждают
исключения и identity source. Приватные реальные файлы не читаются и не
отправляются. Существующий disposable-server lock сохраняется.

**Локальный результат 2026-10-01:** source packaging находится в
`lib/integration_source.py`; action `run` требует `--source-sha`, сверяет HEAD
и clean source до env/SSH, создаёт archive из Git commit и выводит его identity.
Regression fixtures проверяют private paths, uncommitted source, mismatched SHA,
committed bytes и воспроизводимость. Полный локальный набор: 108 tests, PASS,
5 пропусков по условиям существующих tests. Real VPS proof остаётся отдельным gate.

### 2. P0 — раздельные identities и связанные доказательства

**Где:** Installer, `.github/workflows/publish-release-bundle.yml`,
`scripts/release_bundle_publication.py` и publication/Bundle tests.

**Что:** разделить Installer source tag и Bundle publication tag во всех
операциях checkout, archive, asset URL, release lookup/upload/download/cleanup
и concurrency. Проверять, что Bundle tag и Installer tag указывают на один
ожидаемый Installer SHA. Добавить отдельную публикацию standalone Installer.

Standalone Installer не становится `latest` в общем репозитории. Bundle cleanup
работает только с draft этого запуска; чужой draft, project Release и public
candidate сохраняются. Любой API error отличается от подтверждённого not-found.

Проверять доступность PostgreSQL/Redis по exact digest и выбранной платформе,
а не только форму строки. Для Node builder/Nginx сохранять pinned identities
и две byte-identical сборки. Связать lifecycle evidence с защищённым составом
ADR и source tree; отсутствие proof, несовпадение identities и API errors
останавливают проверку, а не считаются PASS.

**Почему:** это устраняет смешение двух выпусков и повторение ручных ошибок.

**Готово, когда:** один Installer используется минимум двумя разными Bundle
identities; URL Cabinet ведёт в нужный Bundle. Wrong SHA, missing image/proof,
неизвестная совместимость и опубликованный existing Release отклоняются.
Legacy schema v1/v2 fixtures и прежние URL проходят regression checks.
Проверяются также неизменность legacy identity hashes, неправильные роли tags,
две публикации Bundle на одном Installer SHA и отказ без удаления чужого draft.

**Локальный результат 2026-10-01:** `installer_tag`/`installer_sha` выбирают source,
`bundle_tag` — URL, lookup, upload/download и concurrency Bundle. Оба tags
dereference в exact tested commit; workflow тоже должен выполняться из этого
commit. Добавлен отдельный `Publish Installer` с archive/checksum и `latest=false`.
Полный прежний contract suite общий для двух workflows.

Строковый proof заменён exact reviewed evidence commit/path на default branch;
record связывает source SHA/tree/archive, protected stack и checksum committed
redacted log. Формат и границы доверия — в
[lifecycle-evidence.md](lifecycle-evidence.md). PostgreSQL/Redis должны загрузиться
по exact digest под `linux/amd64`; Cabinet build остаётся byte-identical.
Release API failures не считаются not-found, existing drafts сохраняются,
cleanup сверяет receipt/run/Release ID/tag/marker/draft. Upload не заменяет assets;
re-download сверяет весь набор из шести assets и каждый файл с prepared bytes,
а не только скачанный архив с его скачанным checksum.

Bundle workflow пока заканчивается только public prerelease с `latest=false`.
Stable promotion специально блокируется до этапа 4. На момент этапа 2 основы
candidate publication готовы, promotion evidence и Cabinet workflow оставались
следующими этапами.
Локальные 126 unit/behavioral tests PASS (5 пропусков Windows), `actionlint`
и Bash syntax для 20 workflow run blocks PASS; все 22 прежние contract commands
сохранены. GitHub API/Docker registry,
full Ubuntu contract suite, VPS lifecycle и real publication остаются
непроверенными в этом локальном этапе.

### 3. P1 — собственный Release Custom Cabinet

**Где:** Custom Cabinet, отдельный publication workflow и release documentation;
Installer, проверка перед stable Bundle promotion.

**Что:** source gates запускаются на exact выпускаемом commit, включая release
branches/tags. Создаётся отдельный Cabinet Release с tag/SHA, изменениями,
Upstream provenance, проверенным Bot и ограничениями. Перед stable Bundle
проверяется существующий Cabinet Release на exact artifact source SHA.

**Почему:** публикация Cabinet больше не зависит от отдельного ручного шага.

**Готово, когда:** Cabinet-only изменение не создаёт новую версию кода Installer;
missing/mismatched Cabinet tag/Release блокирует stable promotion. Existing
проверенный Cabinet Release разрешено использовать повторно. В планах Cabinet
сохраняются BSCHEKER/Simple Mode decisions и известные backend limitations.

**Локальный результат 2026-10-01:** Custom Cabinet получил отдельный manual
`publish-custom-cabinet.yml`. Preflight сверяет source tag/commit/workflow,
читает exact reviewed record commit/path с default branch и связывает его
с Cabinet tree, committed upstream provenance, LICENSE и проверенным Bot.
Reusable CI и CodeQL используют выбранный SHA; push gates охватывают
`release/**`, `sync/**` и `cabinet-v*`. Release содержит только metadata/checksum;
compiled frontend остаётся в Installer Bundle. Draft receipt, API failures,
existing Release preservation и byte-for-byte re-download проверяются локально.

Installer `lib/project_release_verification.py` и команда `project-releases`
проверяют stable Installer/Cabinet Releases и dereferenced tags относительно
selected Installer SHA и Cabinet source SHA в manifest. Existing stable Cabinet
Release без нового metadata asset допускается к reuse. Новый Bot не доказывает
совместимость автоматически: она остаётся gate нового Bundle evidence.
Guard подготовлен для подключения к stable promotion на этапе 4; текущий
Bundle publisher по-прежнему выпускает только prerelease.

Custom Cabinet: 991 tests PASS на Node 24/26 с двумя workers; type-check/build
на Node 24 PASS. Все 12 publication fixtures PASS на Node 24/26; Biome
check/format, `actionlint` и Bash syntax (20 Installer + 24 Cabinet run blocks)
PASS. Secret-shape scan новых public stage 3 files PASS; frontend runtime,
зависимости и dirty работа владельца не изменены. Полный Installer unit suite:
129 tests PASS, 5 Windows skips. Истинность compatibility evidence проверяет
reviewed процесс, а ancestry/JSON guard лишь связывает данные с исходниками.
GitHub dispatch, Linux CodeQL/CI, native immutability, реальные permissions,
живые интеграции и публикации не проверены. Документация Cabinet:
`custom-cabinet/RELEASE_PROCESS.md`; настоящая approved record не создана.

### 4. P1 — candidate → stable без замены assets

**Где:** Installer, Bundle preparation/promotion workflows и проверяющие tests.

**Что:** draft со всеми assets проверяется re-download; затем публикуется как
prerelease с `latest=false` под конечным Bundle tag. Public downloads,
применимые lifecycle/transition gates и smoke используют эти же URLs и bytes.
Stable promotion меняет только prerelease/latest metadata после проверки proof.

Proof записывается отдельно от locked Release assets, в versioned records
Installer `releases/evidence/`: manifest hash, Bundle identity, asset hashes,
Installer/Cabinet/Bot SHA, publication workflow SHA, protected lifecycle tuple,
результаты и ссылки на проверки. Promotion принимает record по точному Git SHA
из доверенного reviewed процесса; сам факт существования JSON с `PASS`
недостаточен. CI artifacts могут дополнять долговременную запись. Private
environment и production logs в public evidence не попадают.

**Почему:** VPS тестирует тот комплект, который затем станет стабильным.

**Готово, когда:** promotion без proof или с изменённым составом отклоняется;
повторная попытка не заменяет опубликованные assets. Failed public candidate
остаётся prerelease, исправление использует новый tag. Installer и Cabinet
Releases проверены на exact SHA и стали stable до stable promotion Bundle;
Bundle candidate можно проверить до этого, поэтому зависимости не замыкаются.
Tests покрывают чужой/неполный proof, несовпадение asset или workflow SHA,
потерянный CI artifact без долговременного evidence и повторную promotion.
Promotion проверен
в изолированном GitHub test repository с включённой immutability, если такой
тест отдельно разрешён; production repositories не служат тестовыми fixtures.

**Локальный результат 2026-10-01:** отдельный `Promote Release Bundle` сначала
выполняет read-only verification, затем после environment gate повторно сверяет
всё и меняет только prerelease/latest по exact Release ID. Требует native
`immutable=true`; отсутствие настройки блокирует promotion. Проверяет exact
successful publication run/attempt/workflow SHA, reviewed record и committed
redacted log, все шесть public asset hashes, manifest/runtime identity,
Installer archive относительно independently prepared committed source,
Cabinet/provenance, protected lifecycle proof и stable project Releases.

Previous stable Bundle выбирается явно, его public manifest hash/identity
сверяются независимо. Changed Bot/images/contracts требуют transition PASS;
Cabinet-only reuse требует обязательный smoke нового Bundle. Повторная promotion
уже stable candidate выполняет проверки без повторной записи и без смены latest.
Публичные downloads не получают GitHub token, existing assets/notes/tags
сохраняются. Record schema и границы доверия:
[bundle-promotion-evidence.md](bundle-promotion-evidence.md).

Local tests используют temporary Git repositories, actual source packaging,
fake HTTP responses и redacted fictional logs. Они подтверждают успешный путь,
read-only verification, no-op retry, отказ при подмене bytes/run/source/proof,
отсутствующем committed log и попытке читать private path. Real GitHub native
immutability/permissions/environment и actual metadata PATCH не проверены;
изолированный GitHub test и VPS gates остаются частью следующего этапа.
Полный локальный Installer suite: 138 tests PASS, 5 Windows skips; `actionlint`,
синтаксис 24 workflow Bash blocks, diff check и secret-shape scan stage 4 public
files PASS. Исходная dirty работа Custom Cabinet сохранена по baseline hashes.

### 5. P1 — первый полный gate и обновление инструкций

**Где:** оба проекта локально, затем разрешённый disposable Ubuntu 24.04;
Installer README/INSTALL/RUNBOOK и `docs/release-*.md`, Custom Cabinet release docs.

**Что:** синхронизировать инструкции с внедрёнными inputs, названиями выпусков,
evidence и reuse rules. Проверить первые standalone Installer/Cabinet Releases
и Bundle как один процесс. После отдельного разрешения включить future release
immutability и tag protection; latest в Installer задавать явно для stable
Bundle, чтобы standalone Installer и backfill его не вытесняли.
Выбранный для первого Bundle Cabinet Release подготавливается на этапе 3;
он не должен ждать массового исторического backfill этапа 6.

**Почему:** новый Installer commit и изменённый publication contract требуют
нового доверенного proof. Старого proof `b54219d…` для первого нового процесса
недостаточно; дальнейший Cabinet-only reuse выполняется по ADR.

**Готово, когда:** local contract/regression gates, Cabinet tests/type-check/build
и affected browser paths PASS; exact candidate проходит full lifecycle,
targeted previous→candidate Bot/schema transition при изменении Bot и final
Bundle smoke. Same-version update не выдаётся за version transition. Telegram,
payment и реальные интеграции с отсутствующим доступом остаются BLOCKED или
явно принятым риском. Production deployment в этот этап не входит.

**Локальный результат 2026-10-01:** Docker Desktop Linux engine запущен с уже
имевшимся образом Ubuntu 24.04; полный `scripts/run-release-contract-tests.sh`
прошёл в отдельном контейнере без host mounts, Docker socket и сети во время
tests. Все 138 Python tests PASS без Windows skips; все 21 shell harness PASS.
Все 22 contract commands совпали с workflow опорного Installer HEAD `b54219d…`.
`actionlint`, Bash syntax 24 Installer + 24 Cabinet workflow blocks, public
branding/Markdown links, diff check и secret-shape scan PASS.

README/INSTALL/RUNBOOK и документы Bundle/обновления согласованы с раздельными
tag/asset identities, lifecycle evidence, public candidate и stable promotion.
В Custom Cabinet изменён только `RELEASE_PROCESS.md`; продуктовый source,
dependencies и прежняя работа владельца сохранены. Frontend gates этапа 3
не повторялись: исходники не менялись, новых затронутых browser paths нет.
Границы проверки и оставшиеся gates:
[release-process-stage5-local-verification.md](release-process-stage5-local-verification.md).

Это проверка dirty working-tree snapshot, не proof для нового source commit.
Коммиты, push, публикации, GitHub settings, SSH/VPS и production в этом
продолжении не выполнялись. Для завершения этапа 5 ещё нужны отдельно
разрешённые exact clean source, GitHub test и trusted full lifecycle/smoke.

**Продолжение локального этапа 5, 2026-10-01:** 12 Cabinet publication fixtures
PASS на Linux Node 24.18.1; настоящие PostgreSQL/Redis digest pulls reference
Bundle `v2026.10.01` PASS для `linux/amd64`. Public manifest identity совпала
с CONTEXT.md. Read-only GitHub API выявил отсутствующие tag-prefix rulesets
обоих проектов, пустые approval rules Installer `production-release` и отсутствие
такого environment у Custom Cabinet. Настройки не менялись; до внешнего запуска
это обязательные отдельные gates. Подготовлены отдельные public diff patches
и inventory hashes для review без Cabinet application source владельца;
проверка patches не меняла Git index. Подробности — в отчёте этапа 5.

### 6. P2 — исторический реестр и недостающие Cabinet Releases

**Где:** новый реестр в Installer `docs/`; после отдельного разрешения —
GitHub Releases Custom Cabinet на существующих tags.

**Что:** связать Bundle tags с Installer SHA, Cabinet SHA/tag/Release, Bot,
images и доступным evidence. Отличать дату source commit от даты публикации.
Отметить `v2026.08.0` как failed publication, `v2026.09.07` и `v2026.09.21`
как заменённые исправленными выпусками. Errata хранить в реестре, старые Releases
и notes не переписывать.

Первые записи для backfill:

| Cabinet tag без GitHub Release | Существующие связанные Bundle |
| --- | --- |
| `cabinet-v2026.09.07.1` | `v2026.09.07`, `v2026.09.07.1` |
| `cabinet-v2026.09.14.1` | `v2026.09.14` |
| `cabinet-v2026.09.21.1` | `v2026.09.21`, `v2026.09.21.1` |
| `cabinet-v2026.09.25.1` | `v2026.09.25` |
| `cabinet-v2026.09.30.1` | `v2026.09.30` |
| `cabinet-v2026.10.01.1` | `v2026.10.01` |

**Почему:** история станет понятной без подмены прошлых исходников и проверок.

**Готово, когда:** соответствия заново подтверждены через dereferenced tag SHA
и public manifest; аннотированный tag object SHA не перепутан с commit SHA.
Backfill содержит реальную дату новой публикации, не меняет `latest`
автоматически и не утверждает отсутствующий исторический PASS. Cabinet source
Bundle `v2026.09.29` и ранние source SHA без собственных tags учитываются
в реестре; массовое создание таких tags не требуется.

## Порядок выполнения и завершение

Этапы 1–2 → 3 → 4 → 5 → 6. Локальные этапы 1–4 подготовлены, локальная часть
этапа 5 проверена; следующий шаг — его внешние gates после отдельного разрешения.
Каждый этап проверяется до перехода к зависимому этапу. Сначала
локальные проверки; публичные и VPS-действия остаются отдельными действиями
в пределах явно полученного разрешения.

Итоговый критерий: Cabinet можно выпустить с прежним Installer, затем собрать
и проверить новый Bundle; старые Bundle URL продолжают поддерживаться,
а production выбирается отдельным разрешённым переходом, без автообновления.
