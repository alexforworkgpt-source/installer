# Первый primary выпуск по ADR 0001 — завершён

Дата: 2026-10-02. Три отдельные Releases опубликованы как stable, immutable; `make_latest=false`.

| Выпуск | Release | Точный source SHA |
| --- | --- | --- |
| Installer | [installer-v2026.10.02](https://github.com/alexforworkgpt-source/installer/releases/tag/installer-v2026.10.02) (ID 401931127) | `75c49bec9c2a764e123fc0ef675f8c45fc22a1ab` |
| Custom Cabinet | [cabinet-v2026.10.02.1](https://github.com/alexforworkgpt-source/custom-cabinet/releases/tag/cabinet-v2026.10.02.1) (ID 401932788) | `8fb8cbec19d651fcfaee3bce32621031b3e69965` |
| Release Bundle | [bundle-v2026.10.02.1](https://github.com/alexforworkgpt-source/installer/releases/tag/bundle-v2026.10.02.1) (ID 401931755) | `75c49bec9c2a764e123fc0ef675f8c45fc22a1ab` |

Bundle identity: `c6c048cce8ad679706c48f35922e98ee36c0cc1923ab801f9f682bb80d607911`.

## Проверки и доказательства

- Публикации Installer, Custom Cabinet и Release Bundle: SUCCESS; точные run IDs, asset IDs, URLs и SHA-256 — в [машинном отчёте](primary-first-release-completion-20261002.json).
- Custom Cabinet: [CI](https://github.com/alexforworkgpt-source/custom-cabinet/actions/runs/37026262757) SUCCESS, 991 frontend + 15 publication tests на каждом Node 24/26; lint/typecheck/build/CodeQL SUCCESS.
- Независимое скачивание без авторизации: все 10 публичных assets проверены; SHA-256, размеры, source/tag/provenance и безопасность архивов PASS.
- Installer lifecycle: PASS через точное повторное использование принятого [evidence](https://github.com/alexforworkgpt-source/installer/blob/37289e3cd3b135f4b5a31f2b7a0291ccaede081c/releases/evidence/primary-lifecycle-reused-75c49be-20261002.json). Полный lifecycle не повторялся: Installer, Upstream Bot, runtime images, contract и Ubuntu 24.04 не изменились.
- Новый Bundle установлен на назначенной одноразовой integration VPS с подтверждённым disposable lock. Outcome committed; три containers; Cabinet/instruction/branding HTTP 200, health ok, webhook root 404, no-store. Cleanup PASS, ресурсы теста отсутствуют, management сохранён.
- Реальные evidence/log приняты через [PR #3](https://github.com/alexforworkgpt-source/installer/pull/3); [promotion record](https://github.com/alexforworkgpt-source/installer/blob/4740f95e7878759f34f1519291c892c2655126b1/releases/evidence/primary-bundle-2026.10.02.1-promotion.json) связывает exact assets и gates.
- [Metadata-only promotion Bundle](https://github.com/alexforworkgpt-source/installer/actions/runs/37044289678): SUCCESS; Custom Cabinet переведён в stable после проверок. Итоговый API read-back: все три stable, immutable; source tags, notes и assets сохранены.
- Переход между версиями: NOT_REQUIRED относительно v2026.10.01; protected tuple не изменился. Проверка другого backend/DB transition не заявляется.

## Принятые ограничения и границы

Compatibility PASS ограничен принятым владельцем PASS_SOURCE_CONTRACT_SCOPE. Это не полный live PASS для Telegram, платежей, продления, concurrency или panel. Все принятые OPEN/BLOCKED ограничения из promotion record сохранены в машинном отчёте.

Историческая строка `new-bundle-smoke` в неизменяемом Cabinet publication snapshot описывает момент до сборки и теста нового Bundle. Позднейший фактический Bundle-specific smoke выше прошёл PASS; прежний asset не переписывался.

`latest` сохранён: Installer `v2026.10.01`, Custom Cabinet `cabinet-v2026.09.05.1`. Исторические Releases/tags/assets и GitHub settings не изменены. Production, backend и runtime-код не изменены; локальные изменения владельца сохранены.

Запрет изменения backend закреплён в локальных AGENTS.md root, Installer и Custom Cabinet. Решения, требующие backend changes, не предлагаются.

ADR 0001 и его implementation plan завершены. Этот выпуск представляет текущий проверенный пакет; публикация всех исторических версий заново не выполнялась.
