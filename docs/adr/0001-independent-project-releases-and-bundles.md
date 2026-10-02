# ADR 0001: отдельные Releases Installer, Custom Cabinet и Release Bundle

Status: Accepted — направление локальной реализации<br>
Date: 2026-10-01<br>
Implementation: In progress — этапы 1–2 подготовлены локально<br>
Plan: [План реализации](../release-process-implementation-plan.md)

Этот ADR фиксирует выбранное направление после исследования истории и разрешения
продолжить локальную реализацию. Разделение Installer/Bundle подготовлено
локально, но ещё не опубликовано в GitHub; собственный Cabinet workflow
и stable promotion остаются следующими этапами. Актуальные inputs и границы —
в [RUNBOOK.md](../../RUNBOOK.md). Создание документа не разрешает push, изменение
настроек GitHub, публикацию Releases или действия на production.

## Context

Installer и Custom Cabinet — самостоятельные проекты. Installer владеет
публикацией Release Bundle; Upstream Bot остаётся внешним неизменённым source.

В опорном Installer commit `b54219d` `installer_tag` одновременно выбирал исходники Installer и GitHub
Release всего комплекта. Поэтому изменение только Custom Cabinet создаёт
очередной Release с названием Installer, хотя Installer SHA может не меняться.
Локальная реализация [publication workflow](../../.github/workflows/publish-release-bundle.yml)
уже разделяет source tag и Bundle tag; исторические Releases не меняются.

Собственная публикация Custom Cabinet не автоматизирована. Его README передаёт
сборку production-артефакта Installer. Bundle workflow требует Cabinet SHA,
но не требует собственного Cabinet tag или GitHub Release.

На дату исследования у Installer 42 удалённых tags и 41 Release, включая
5 prereleases; у Custom Cabinet 17 собственных tags и 11 Releases. Шесть
Cabinet tags после `cabinet-v2026.09.05.1` имеют исходники в Bundles, но не имеют
своих GitHub Releases. Это пробел прослеживаемости, а не доказательство
отсутствия обновлений Cabinet или нарушения прежнего Bundle contract.

Другие подтверждённые ограничения: ручной ввод publication identities,
неполное связывание lifecycle proof с проверенным комплектом и source tree,
CI Cabinet только для `main/dev`, технический smoke без всех пользовательских
сценариев. Стандартный lifecycle обновляет Bundle на него же; проверка перехода
между версиями Upstream Bot и схемами БД нужна отдельно.

## Decision

### 1. Разделить три вида выпуска

| Выпуск | Где публикуется | Назначение |
| --- | --- | --- |
| Installer | `alexforworkgpt-source/installer` | Точная версия инструмента установки, обслуживания и восстановления |
| Custom Cabinet | `alexforworkgpt-source/custom-cabinet` | Точная версия frontend, изменения, совместимость и ограничения |
| Release Bundle | `alexforworkgpt-source/installer` | Проверенный устанавливаемый комплект Installer, Custom Cabinet, Upstream Bot и images |

Для новых выпусков предлагаются разные префиксы tags: `installer-v` для
Installer, существующий `cabinet-v` для Custom Cabinet и `bundle-v` для Bundle.
После префикса используется дата `YYYY.MM.DD` с дополнительным номером выпуска
при необходимости. Старые `v2026.*` и `test-*` остаются как есть.

Изменение Cabinet не требует нового Installer Release, если Installer SHA
не изменился. Изменение Upstream Bot не требует нового Cabinet Release, если
прежний Cabinet проверен с новым Bot. В обоих случаях нужен новый Bundle.
Версия `package.json`, унаследованная от Upstream Cabinet, не заменяет собственный
Cabinet tag. Нового репозитория, root monorepo или форка Upstream Bot не создаём.

### 2. Разделить исходники Installer и identity Bundle

Publication выбирает точный Installer tag/SHA отдельно от нового Bundle tag.
Bundle tag в репозитории Installer указывает на тот же проверенный Installer
commit; он не становится новой версией кода Installer. Это соответствие
проверяется до загрузки assets.

Для нового процесса роли inputs и prefixes проверяются отдельно. Lookup,
upload, promotion и cleanup Bundle не обращаются к Installer Release.
Cleanup удаляет только draft, созданный этим запуском; API error не считается
отсутствием Release. Публичный candidate или stable Release не удаляется.

Standalone Installer Release содержит архив Installer и checksum, без Cabinet
artifact и Bundle manifest. Cabinet Release фиксирует исходники, source gates,
проверенную совместимость и известные ограничения; отдельный production dist
в нём не обязателен.

Bundle продолжает содержать готовый `cabinet-dist.tar.gz`, его checksum,
архив выбранного Installer с checksum, `release.json` и provenance.
Имя `installer-<bundle_release>.tar.gz` обозначает копию Installer в комплекте,
а не самостоятельную новую версию Installer. Стандартные GitHub Source code
archives Bundle относятся к Installer, не к исходникам Cabinet или Bot.

### 3. Сохранить действующий runtime contract

Применение остаётся через точный URL `release.json`, Cabinet SHA и checksum.
Разделение publication identities само по себе не требует schema v3,
переписывания runtime Installer или переноса Cabinet artifact в другой проект.
Чтение legacy schema v1/v2 и исторические URL сохраняются.

Сохраняется и алгоритм `release_bundle_identity`: canonical fields и fallback
для legacy Cabinet repository. Publication metadata не добавляется в старую
runtime identity. Regression fixtures должны сохранять прежние identity hashes,
а не только успешно разбирать JSON.

Installer identity и ссылки на проверки фиксируются явно в publication records.
Дополнительные записи доказательств не меняют существующие manifests и не
считаются проверяемыми runtime-полями, если parser их не учитывает. Одного
добавления проигнорированного поля JSON недостаточно для защиты identity.

### 4. Проверять кандидат до стабильной публикации

Порядок: exact source gates → полный состав кандидата → draft со всеми assets
и re-download verification → public prerelease с `latest=false` → независимые
public downloads и применимые VPS/browser gates → stable promotion.

Для будущих кандидатов используется конечный Bundle tag и конечные asset URLs.
После проверок меняются только prerelease/latest metadata: tag, manifest,
archives и checksums не пересобираются и не заменяются. Неудачный публичный
кандидат остаётся prerelease; исправление получает новый tag.

Проверки, выполненные после public candidate, фиксируются отдельно от его
locked assets: в версионированных evidence records репозитория Installer.
Promotion читает запись по точному Git SHA, сверяет manifest hash, runtime
Bundle identity и hashes всех assets, а также source/workflow SHA и результаты.
Записи содержат только публичные identities, redacted результаты и ссылки на
проверки; секреты и production logs в них не включаются. Временный CI artifact
может дополнять запись, но не является единственным долговременным proof.

Перед stable promotion выбранный Custom Cabinet должен иметь собственные tag
и GitHub Release на том же SHA, который прошёл source gates и вошёл в artifact.
Выбранный Installer также должен иметь собственный stable Release на exact SHA.
Оба project Releases могут завершить свои проверки на общем Bundle candidate;
они переводятся в stable до stable promotion Bundle, без циклической зависимости.
Уже проверенный Cabinet Release можно использовать в нескольких Bundles.
Непроверенные сценарии остаются BLOCKED либо явно принятым владельцем риском;
ни наличие Release, ни зелёная сборка не превращают их в PASS.

При повторном использовании Cabinet с новым Bot compatibility proof хранится
в новом Bundle/evidence record, без редактирования прежнего Cabinet Release.
Integrity gates — exact SHA, checksum, archive safety, source/evidence binding
и поддерживаемый contract — остаются обязательными. Принятый риск ограниченного
покрытия не разрешает записать failed/missing integrity proof как PASS.

Prerelease сам по себе не запрещает ручную установку по URL существующим
Installer. Его не предлагают для production. Production остаётся отдельным
разрешённым владельцем переходом; публикация ничего автоматически не обновляет.

### 5. Связать проверки с точными identities

Lifecycle proof содержит проверенный Installer commit/source tree, Upstream Bot
SHA, runtime image digests, Bundle/configuration/backend contracts, target OS,
результат и ссылку на evidence. Строка `ubuntu-24.04-passed` сама по себе не
считается достаточным доказательством.

Полный lifecycle повторяется при изменении Installer SHA, Upstream Bot SHA,
runtime image digests, Bundle contract или target OS, а также при отсутствии
доверенного proof. Для Cabinet-only Bundle при неизменном защищённом составе
доверенный proof переиспользуется по workspace AGENTS.md; выполняются Cabinet
gates и targeted smoke именно нового Bundle. Builder identities всё равно
фиксируются, а Cabinet build проверяется на воспроизводимость.

Переход между версиями Bot/БД проверяется относительно указанного предыдущего
Bundle и schema revision. Проверки оплаты, скидок и продления покрывают реальные
entry points изменённого frontend и совместимые ответы exact Bot; mocked browser
tests и свежая установка не заменяют эту проверку.

### 6. Сохранить историю и защитить будущие выпуски

Существующие tags, Releases, notes, assets и production не переписываются.
Исторические проблемы и заменяющие выпуски записываются в отдельном реестре.
Недостающие Cabinet Releases допускается создать на существующих tags с
реальной датой новой публикации, описанием исторической версии и ссылками на
Release Bundle; без выдуманных старых PASS и автоматического изменения `latest`.

Сначала учитываются шесть tags, имеющих исходники в Bundles. Для ранних SHA
без tag достаточно реестра; новые исторические tags создаются только при
обоснованной необходимости, без перемещения старых.

Native GitHub release immutability и защита новых tag prefixes включаются
отдельным разрешённым действием до новых публичных выпусков. Это не делает
старые Releases автоматически immutable. GitHub допускает изменение
prerelease/latest metadata при сохранении неизменяемых tag и assets:
[Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases),
[Preventing changes](https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/establish-provenance-and-integrity/prevent-release-changes).

## Consequences

- История версии Installer отделяется от истории устанавливаемого комплекта.
- Каждый стабильный Cabinet имеет собственную понятную запись выпуска.
- Bundle остаётся единственной production-рекомендацией для совместимых версий.
- Цена решения — отдельные публикации, связанное evidence и проверка promotion.
- Existing runtime flow сохраняется; совместимость ещё должна быть подтверждена
  regression gates и disposable Ubuntu 24.04 до первого нового stable Bundle.
- Публичные публикации, backfill, GitHub settings и production не входят в
  подготовку этого ADR. План определяет отдельные этапы их выполнения.
