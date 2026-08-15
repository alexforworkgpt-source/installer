# Release Bundle

Release Bundle фиксирует совместимый production-набор Bot, Cabinet и runtime
images. Manifest публикуется release pipeline installer вместе с release installer и проходит проверку до
изменения работающего стека.

## Состав manifest

- версия схемы manifest
- публичное имя release
- repository и точный 40-символьный Git SHA Bot
- точный 40-символьный source SHA Cabinet
- HTTPS URL готового `cabinet-dist.tar.gz`
- SHA-256 Cabinet artifact
- PostgreSQL и Redis images, закреплённые через `@sha256`
- версия backend contract
- версия configuration schema
- migration policy

Актуальный формат показан в `releases/release.example.json`. Это только пример с
нерабочими значениями, его нельзя применять как release.

## Cabinet artifact

Release pipeline installer собирает frontend из точного Cabinet source SHA и создаёт `cabinet-dist.tar.gz`. В корне
архива обязательно находится `index.html`; каталог `assets` и остальные файлы
располагаются рядом с ним. Symlinks, hardlinks, devices, абсолютные пути и пути
с `..` запрещены.

Artifact, manifest и SHA-256 публикуются как assets одного GitHub Release installer. Значение checksum
дублируется в Release Bundle manifest. Installer проверяет checksum до
распаковки и активирует frontend атомарной заменой каталога.

Artifact собирается tenant-neutral: `VITE_API_URL=/api`, Telegram widget config
и branding загружаются из Bot backend, а compile-time username/branding остаются
только fallback. Поэтому один immutable artifact используется на разных VPS.

Publication pipeline находится в
`.github/workflows/publish-release-bundle.yml`. Он разрешает refs в SHA, собирает
Cabinet, создаёт deterministic archive и manifest через production parser,
публикует draft release, скачивает assets обратно, проверяет checksums и только
после этого публикует release. Реальный опубликованный Bundle и VPS smoke должны
быть зафиксированы отдельно; наличие workflow само по себе не является таким proof.
Node builder и Nginx runtime для сборки artifact задаются только immutable image
digests; pipeline выполняет две сборки и сравнивает архивы byte-for-byte, а точные
builder identities сохраняет в `release-provenance.json`.

## Совместимость

Maintainer installer перед публикацией manifest подтверждает:

1. Bot и Cabinet используют совместимый backend contract.
2. Installer поддерживает указанную configuration schema.
3. PostgreSQL migration допускает выбранную policy.
4. Cabinet artifact собран из указанного source SHA.
5. Images доступны по указанным immutable digests.

Допустимые migration policies:

- `rollback-compatible`: предыдущий Bot может быть восстановлен после migration.
- `forward-only`: автоматический возврат старого Bot после migration запрещён.

Перед применением `rollback-compatible` bundle installer создаёт custom-format
PostgreSQL dump, проверяет его через `pg_restore --list` и фиксирует Alembic
revision. После успешного health check рядом с dump сохраняется metadata с
before/after revisions. `forward-only` bundle не применяется, пока installer не
может гарантировать отдельный безопасный recovery flow.

При reversible failure installer останавливает Bot, возвращает точные предыдущие
Git HEAD, Cabinet dist и image digests, поднимает только PostgreSQL/Redis,
восстанавливает dump и проверяет исходную Alembic revision. Старый Bot запускается
только после успешного восстановления БД. Если rollback или его проверка не
удались, Bot остаётся остановленным, а recovery plan сохраняется в
`state/last-runtime-change.json`.

## Применение

В меню выберите:

```text
Обслуживание -> Обновления -> Обновить всё из Release Bundle
```

Укажите HTTPS URL manifest или локальный абсолютный путь. Installer до первой
mutation проверит compatibility metadata, наличие обоих Git SHA, Cabinet checksum
и структуру archive. После каждого checkout фактический repository HEAD должен
совпасть с SHA из manifest. Затем installer покажет release summary и запросит
подтверждение.

После commit в private state сохраняются deterministic Release Bundle identity и
точный Cabinet artifact SHA-256. Предыдущие identities сохраняются для аудита.
Автоматический rollback во время текущего update использует временно защищённую
точную копию предыдущего Cabinet dist; отдельный поздний rollback по identity пока
не предоставляется.

Ручные обновления по tags и `main` остаются в расширенном меню для разработки и
требуют ввода `EXPERT`. Они не имеют compatibility guarantee и не являются
production-сценарием.
