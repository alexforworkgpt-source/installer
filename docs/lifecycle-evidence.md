# Lifecycle evidence для новых публикаций

Lifecycle — полный тест установки, обновления, отката и удаления Installer на
одноразовом Ubuntu 24.04. Зелёные unit tests и строка `PASS` в JSON не заменяют
этот тест. Реальный новый lifecycle в ходе локальной реализации не выполнялся.

## Где хранится подтверждение

После разрешённого lifecycle сохраните очищенный от секретов log и JSON record
в Installer `releases/evidence/`. Владелец или доверенный reviewer проверяет
реальный результат, exact identities и redaction до принятия record на default
branch. Публикация выбирает эту запись по полному Git SHA и пути, не по `latest`.

Workflow проверяет принадлежность evidence commit к default branch, наличие
log на том же commit и его SHA-256. Локальный файл или запись на сторонней branch
не принимаются. Проверка Git ancestry подтверждает место записи в истории,
но не доказывает, что человек провёл review или что текст log правдив.
Доверие к default branch и контролируемый review — обязательная часть процесса;
настройки защиты branch/environment ещё не изменены.

## Что записывается

Пример структуры ниже намеренно содержит `BLOCKED` и placeholders. Это описание
формата, не готовое подтверждение проверки. Не заменяйте результат на `PASS`
до реального успешного gate и review. Реальные private environment и сырые
production logs в public records не входят.

```json
{
  "schema_version": 1,
  "kind": "installer-lifecycle",
  "result": "BLOCKED",
  "installer": {
    "installer_sha": "<tested 40-character commit SHA>",
    "installer_tree_sha": "<tested 40-character tree SHA>",
    "archive_sha256": "<tested 64-character source archive SHA-256>"
  },
  "protected": {
    "bot_repository": "https://github.com/OWNER/bot.git",
    "bot_sha": "<tested 40-character Bot commit SHA>",
    "postgres_image": "postgres@sha256:<tested digest>",
    "redis_image": "redis@sha256:<tested digest>",
    "backend_contract": "1",
    "bot_backend_contract": "1",
    "cabinet_backend_contract": "1",
    "configuration_schema": 1,
    "manifest_schema": 2,
    "migration_policy": "rollback-compatible",
    "target_os": "ubuntu-24.04",
    "target_platform": "linux/amd64"
  },
  "evidence_url": "https://github.com/OWNER/installer/blob/<exact evidence commit>/releases/evidence/lifecycle.log",
  "log_path": "releases/evidence/lifecycle.log",
  "log_sha256": "<64-character SHA-256 of committed redacted log bytes>"
}
```

Значения `installer` берутся из строки `Installer source` remote runner.
Архив строится из Git commit с private/generated exclusions; tree SHA относится
к полному Git tree. Publication независимо строит такой же public archive и
сравнивает все три identities. Отличающийся checksum останавливает выпуск;
его нельзя исправить вручную в proof без проверки нового snapshot.

Protected stack фиксируется по фактически протестированному Bundle и платформе.
Поддерживается только `ubuntu-24.04` / `linux/amd64`; contracts соответствуют
текущим runtime schema v2 и configuration schema 1. Исторические schema v1/v2
продолжают читаться runtime; этот record относится к новому publication flow.
`evidence_url` допускает public Actions run либо exact committed public log.
Само наличие ссылки или успешного contract workflow не является VPS proof.

Git может нормализовать переводы строк при добавлении log. Считайте `log_sha256`
по committed bytes, например из `git show <log-commit>:releases/evidence/lifecycle.log`,
а не по отличающейся Windows-копии. JSON и log могут быть приняты следующим
evidence commit; source tag при этом продолжает указывать на tested Installer.
Не добавляйте evidence в source snapshot задним числом: это изменило бы source SHA.

## Когда можно повторно использовать proof

Custom Cabinet source SHA и его artifact hash намеренно не входят в protected
lifecycle tuple: Cabinet-only Bundle может использовать прежний proof, если
Installer SHA/tree/archive, Upstream Bot, runtime digests, contracts и target OS
не изменились. Builder Node/Nginx identities остаются в Bundle provenance;
Cabinet собирается дважды с одинаковыми bytes. Для нового Cabinet всё равно
нужны его source gates и targeted smoke именно нового Bundle.

При любом изменении protected tuple, source/workflow commit или отсутствии
доверенного proof повторите полный lifecycle. Переход между Bot/schema versions
нужно проверять отдельно относительно предыдущего Bundle; same-version update
не доказывает корректность такого перехода.

## Границы локального этапа

Workflows проверяют этот record до создания public Release. Standalone Installer
публикует архив/checksum с `latest=false`; Bundle workflow публикует только
prerelease candidate с `latest=false`. Его прямой `publish-draft --stable`
по-прежнему блокируется. Отдельный `Promote Release Bundle` требует evidence
на manifest, все assets, workflow SHA, source identities и smoke/transition
results: [bundle-promotion-evidence.md](bundle-promotion-evidence.md), по
[ADR 0001](adr/0001-independent-project-releases-and-bundles.md).

Проверки GitHub API и Docker registry пока выполнены только через test doubles
в локальных tests. Реальная загрузка digest, публикация/re-download и lifecycle
нового процесса остаются обязательными следующими gates; локальный PASS их
не заменяет. Публикация автоматически не обновляет production.
