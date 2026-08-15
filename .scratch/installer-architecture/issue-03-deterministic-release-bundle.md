---
type: issue
title: Детерминированный Release Bundle и Cabinet artifact
execution: HITL
status: ready-for-human
labels:
  - ready-for-human
created: 2026-08-14
---

# Детерминированный Release Bundle и Cabinet artifact

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Определить и провести end-to-end контракт production release: от выбранного пользователем release до точных Bot и Cabinet commits, immutable runtime images, проверенной совместимости, стабильного Cabinet artifact и детерминированного rollback. Перед реализацией человек должен утвердить владельца release manifest, место его публикации, способ поставки Cabinet artifact и процесс подтверждения совместимости Bot/Cabinet.

После утверждения installer должен разрешать moving refs в immutable identities, проверять фактические source revisions, устанавливать только совместимый bundle и сохранять точные предыдущие artifacts для rollback.

## Acceptance criteria

- [x] Человек утвердил владельца и место публикации release manifest.
- [x] Человек утвердил Cabinet artifact contract и ответственность за публикацию artifact.
- [ ] Release Bundle фиксирует точные Bot SHA, Cabinet SHA, runtime image digests, backend contract version, configuration schema version и migration compatibility.
- [ ] Branches и tags разрешаются в immutable commits до первого изменения runtime.
- [ ] Checkout failure или несовпадение repository HEAD с resolved SHA блокирует установку или обновление.
- [ ] Несовместимая пара Bot/Cabinet отклоняется по умолчанию.
- [ ] Cabinet доставляется через утверждённый artifact contract и активируется атомарно после проверки.
- [ ] Rollback использует точные предыдущие commits, images и Cabinet artifact, а не текущую вершину moving branch.
- [ ] Автоматические тесты покрывают успешное разрешение bundle, отсутствующий ref, несовместимую пару и deterministic rollback identity.
- [ ] Release и update документация описывает утверждённый contract без привязки к внутренностям Cabinet build image.

## Approved ownership

Release Bundle полностью принадлежит installer. Release pipeline installer
собирает Cabinet из точного source SHA, создаёт `cabinet-dist.tar.gz`, считает
SHA-256 и публикует manifest и artifact как assets одного GitHub Release installer.
Пользователь не собирает и не публикует эти artifacts вручную.

## Blocked by

None - can start immediately
