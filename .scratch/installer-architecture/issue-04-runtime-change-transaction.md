---
type: issue
title: Runtime Change Transaction для установки и настроек
execution: AFK
status: done
labels:
  - done
created: 2026-08-14
---

# Runtime Change Transaction для установки и настроек

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Сделать первую установку, повторную установку и применение settings draft одной проверяемой Runtime Change Transaction. Операция должна построить план, защитить старое состояние до первой мутации, применить затронутые runtime areas, проверить результат и только затем закоммитить desired/applied state. Обратимые ошибки должны возвращать старый runtime; необратимые состояния должны безопасно останавливать затронутую часть и давать точный recovery plan.

В этот срез входит отдельная безопасная операция ротации PostgreSQL credentials, чтобы database role и Bot environment менялись вместе, а generic editor не мог выполнять такую смену текстовой правкой.

## Acceptance criteria

- [x] Runtime change использует явные стадии plan, protect, apply, verify, commit и rollback policy.
- [x] Recovery point создаётся до изменения desired state, generated artifacts, repositories или runtime.
- [x] Первая и повторная установка коммитят applied state только после обязательных health checks.
- [x] Settings draft активируется только после подтверждения redacted plan.
- [x] Failure result содержит failed stage, rollback status, safe next action и log reference.
- [x] Library operation возвращает structured result и не завершает всё интерактивное меню самостоятельно.
- [x] Reversible failure восстанавливает и проверяет предыдущий runtime.
- [x] Generic settings editor блокирует смену identity и credentials инициализированной PostgreSQL.
- [x] Dedicated credential rotation проверяет старое подключение, меняет database role и Bot secret согласованно и откатывается при failure.
- [x] Failure-injection tests покрывают сбой после каждой стадии первой установки, repeat install, settings apply и credential rotation.
- [x] Runbook описывает значение committed, rolled back и safely stopped outcomes.

## Verification

- Windows regression: 75 tests passed, 5 POSIX tests skipped.
- Clean Ubuntu 24.04: 75 tests passed and every local integration harness passed.
- First-install failure injection covers plan, protect, apply, verify, commit and rollback failure.

## Blocked by

- [Issue 02: Миграция legacy-конфигурации и управляемый settings draft](./issue-02-legacy-config-migration-and-drafts.md)
