# Перевод Release Bundle из candidate в stable

Status: подготовлено локально, 2026-10-01. Настоящие Releases и production
в ходе этой работы не изменялись. Решение: [ADR 0001](adr/0001-independent-project-releases-and-bundles.md).

Candidate — опубликованный prerelease для проверки. Stable — тот же комплект,
который прошёл необходимые проверки и согласован владельцем. Promotion меняет
только `prerelease=false` и явно выбранный `make_latest`. Тег, notes, manifest,
архивы и checksums остаются прежними. Новый workflow не создаёт и не удаляет
Releases, не загружает assets и не выполняет deployment.

## Порядок действий

1. **В Installer:** опубликовать новый candidate через `Publish Release Bundle`.
   Он использует конечный `bundle-vYYYY.MM.DD[.N]` и конечные public URLs,
   содержит все шесть assets и имеет `latest=false`. Для нового процесса
   native GitHub immutability должна быть включена до публикации: promotion
   отклоняет Release с `immutable=false` или отсутствующим полем. Старые
   исторические Releases не переделываются в candidates нового процесса.
2. **На разрешённом disposable Ubuntu 24.04:** скачать candidate без токена
   и проверить именно его файлы. Провести targeted smoke нового Bundle.
   Lifecycle можно повторно использовать только для exact Installer source
   и неизменного protected stack по [lifecycle-evidence.md](lifecycle-evidence.md).
   Если источник или protected tuple изменился, требуется новый full lifecycle.
   При изменении Bot/images/contracts проверить предыдущий Bundle → candidate;
   свежая установка и same-version update не заменяют такой переход.
3. **В Custom Cabinet и Installer Releases:** выбранные project Releases
   должны стать stable на тех же source SHA. Cabinet Release может быть
   создан сразу stable после согласования либо его public candidate может
   пройти отдельный разрешённый metadata-only переход; нельзя запускать
   повторную загрузку под прежним tag. Bundle candidate допускается проверить
   раньше этих project Releases, поэтому зависимости не замыкаются.
   Historical stable Cabinet Release допускается использовать повторно
   без добавления metadata assets; совместимость с новым Bot подтверждается
   отдельно для нового Bundle.
4. **На default branch Installer:** сохранить публичный очищенный журнал
   проверок и record в `releases/evidence/`. Reviewer проверяет реальные
   результаты, exact identities и отсутствие секретов; record получает
   точный Git SHA. Запись добавляется после source tag и не меняет tested
   source. CI artifacts могут дополнять журнал, но не заменяют его: истечение
   срока хранения CI artifact не должно уничтожить долговременное proof.
5. **В GitHub Actions Installer:** вручную запустить `Promote Release Bundle`
   из exact Installer commit, содержащего этот workflow. Передать
   `installer_tag`, `installer_sha`, `bundle_tag`, `promotion_evidence_sha`,
   `promotion_evidence_path`, `make_latest`. Последний по умолчанию false;
   для рекомендации нового stable Bundle выбрать true и согласовать такое же
   значение в record. Workflow сначала проверяет всё с read-only правами,
   затем после environment gate повторяет всю проверку перед PATCH по Release ID.
6. **В Releases Installer:** проверить результат. Повторная promotion уже
   stable Release проходит те же проверки и не записывает metadata снова,
   поэтому старый выпуск не вытесняет новый `latest` повторным запуском.
   Failed public candidate сохраняется prerelease. Исправленные bytes требуют
   нового tag и нового полного комплекта проверок. Production — отдельная
   разрешённая операция по RUNBOOK, а не часть promotion.

## Record schema v1

Ниже **непригодный к promotion** шаблон: BLOCKED, false, placeholders и
пустые hashes требуют фактических проверок и review. Он не является proof.
Старые records и Release assets не редактируются ради заполнения этого шаблона.

```json
{
  "schema_version": 1,
  "kind": "bundle-promotion",
  "result": "BLOCKED",
  "owner_approved": false,
  "repository": "OWNER/installer",
  "bundle_tag": "bundle-vYYYY.MM.DD",
  "release_id": 0,
  "installer_tag": "installer-vYYYY.MM.DD",
  "installer": {
    "installer_sha": "EXACT_SOURCE_COMMIT",
    "installer_tree_sha": "EXACT_SOURCE_TREE",
    "archive_sha256": "EXACT_TESTED_INSTALLER_ARCHIVE_HASH"
  },
  "cabinet_tag": "cabinet-vYYYY.MM.DD",
  "protected": {
    "bot_repository": "EXACT_UPSTREAM_BOT_URL",
    "bot_sha": "EXACT_VERIFIED_BOT_COMMIT",
    "postgres_image": "postgres@sha256:EXACT_DIGEST",
    "redis_image": "redis@sha256:EXACT_DIGEST",
    "backend_contract": "1",
    "bot_backend_contract": "1",
    "cabinet_backend_contract": "1",
    "configuration_schema": 1,
    "manifest_schema": 2,
    "migration_policy": "rollback-compatible",
    "target_os": "ubuntu-24.04",
    "target_platform": "linux/amd64"
  },
  "bundle_identity": "EXACT_RUNTIME_BUNDLE_IDENTITY",
  "assets": {
    "cabinet-dist.tar.gz": "EXACT_SHA256",
    "cabinet-dist.tar.gz.sha256": "SHA256_OF_CHECKSUM_FILE_BYTES",
    "release.json": "EXACT_MANIFEST_SHA256",
    "release-provenance.json": "EXACT_PROVENANCE_SHA256",
    "installer-YYYY.MM.DD.tar.gz": "EXACT_INSTALLER_ARCHIVE_SHA256",
    "installer-YYYY.MM.DD.tar.gz.sha256": "SHA256_OF_CHECKSUM_FILE_BYTES"
  },
  "publication": {
    "workflow_sha": "EXACT_INSTALLER_SOURCE_COMMIT",
    "run_id": 0,
    "run_attempt": 0
  },
  "previous": {
    "manifest_url": "https://github.com/OWNER/installer/releases/download/vPREVIOUS/release.json",
    "manifest_sha256": "EXACT_PREVIOUS_PUBLIC_MANIFEST_SHA256",
    "bundle_identity": "EXACT_PREVIOUS_BUNDLE_IDENTITY"
  },
  "gates": {
    "cabinet_source": {"result": "BLOCKED", "evidence_url": "PUBLIC_EXACT_EVIDENCE"},
    "compatibility": {"result": "BLOCKED", "evidence_url": "PUBLIC_EXACT_EVIDENCE"},
    "smoke": {"result": "BLOCKED", "evidence_url": "PUBLIC_EXACT_EVIDENCE"},
    "transition": {"result": "BLOCKED", "evidence_url": "PUBLIC_EXACT_EVIDENCE"}
  },
  "limitations": [
    {
      "id": "classic-auto-purchase",
      "status": "OPEN",
      "summary": "Известный backend defect остаётся открытым",
      "accepted": false
    },
    {
      "id": "live-integrations",
      "status": "BLOCKED",
      "summary": "Указать фактически непроверенные Telegram/payment/panel/renewal сценарии",
      "accepted": false
    }
  ],
  "lifecycle": {
    "commit": "EXACT_REVIEWED_LIFECYCLE_COMMIT",
    "path": "releases/evidence/lifecycle.json"
  },
  "make_latest": false,
  "log_path": "releases/evidence/bundle-checks.log",
  "log_sha256": "SHA256_OF_COMMITTED_REDACTED_LOG"
}
```

`assets` фиксирует SHA-256 **каждого** скачанного файла, включая checksum files.
Поле `release_id` берётся из GitHub API, а `publication` — из exact успешного
`Publish Release Bundle` run/attempt, чей marker находится в candidate notes.
`installer` получают из проверенного committed source archive; hash архива
должен совпасть с Installer asset, уже опубликованным в candidate.
`protected` получается из manifest schema v2 и фактически проверенного stack.
Cabinet/Bot SHA, image digests и builder provenance дополнительно связаны
неизменяемыми manifest/provenance hashes; `bundle_identity` считается штатным
runtime parser, без изменения старого алгоритма identity.

`previous` всегда указывает явно выбранный предыдущий stable Bundle того же
репозитория; допускаются historical `v...` и новые `bundle-v...` tags.
Promotion скачивает его manifest без токена и сверяет hash/identity/version,
а также stable статус предыдущего Release. `transition=NOT_REQUIRED` допускается
только если Bot/repository, PostgreSQL/Redis, backend/configuration contracts
и migration policy не менялись относительно этого manifest. Смена Cabinet
всё равно требует успешного smoke нового Bundle.

`cabinet_source`, `compatibility`, `smoke` должны иметь PASS и public evidence URL.
Разрешены GitHub Actions run URL либо GitHub blob URL с точным commit под
`releases/evidence/`. Все OPEN/BLOCKED ограничения должны быть явно приняты
владельцем; это не разрешает FAILED/BLOCKED обязательный gate или отсутствующее
integrity/lifecycle proof. BSCHEKER/Simple Mode policy Cabinet сохраняется;
classic auto-purchase остаётся OPEN до отдельного подтверждённого backend fix.

## Что проверяется автоматически

- Source tag/SHA/tree/archive, Bundle tag, publication и promotion workflow SHA.
- Record и его checksum-bound redacted log на exact commit в default branch;
  аналогично — lifecycle record/log и protected tuple.
- Release ID/tag/run marker, `immutable=true`, published состояние, exact набор
  assets и канонические конечные URLs; API errors всегда останавливают gate.
- Exact publication run/attempt: repository, workflow path, source SHA,
  `workflow_dispatch`, completed/success. Результат другого workflow не подходит.
- Все public downloads без Authorization: hashes, размеры, checksum contents,
  Cabinet archive safety, manifest identity и builder provenance.
- Stable project Releases на exact source SHA, previous stable Release и
  применимость transition gate. Наличие project Release не доказывает совместимость.
- Перед PATCH повторно читается тот же immutable Release ID и неизменный набор
  asset identities. Единственный payload записи — prerelease/make_latest.

JSON и ancestry не доказывают человеческий review и правдивость журнала.
Reviewer отвечает за соответствие evidence реальным сценариям и выбранным SHA.
Branch protection, environment approval и native immutability — необходимые
внешние настройки, которые эта локальная работа не меняла. GitHub допускает
metadata-only изменения у immutable Release:
[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases).
Run/attempt metadata API:
[Workflow runs](https://docs.github.com/en/rest/actions/workflow-runs?apiVersion=2022-11-28).

## Границы проверки

Локальные fixtures проверяют настоящий Git/source packaging, durable records,
public downloads через подменённый HTTP API, отказ без необходимых proof,
подмену bytes, неверный publication run и повторную promotion без записи.
Настоящий Linux CI, GitHub environment/permissions/immutability и metadata PATCH
в отдельном GitHub test repository пока не проверены. VPS lifecycle,
transition, живые интеграции и production здесь не выполнялись.
