---
type: issue
title: End-to-end доказательство lifecycle на Ubuntu 24.04
execution: AFK
status: ready-for-agent
labels:
  - ready-for-agent
created: 2026-08-14
---

# End-to-end доказательство lifecycle на Ubuntu 24.04

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Доказать полный пользовательский lifecycle модернизированного installer в disposable Ubuntu 24.04 environment. Один воспроизводимый сценарий должен пройти clean-VPS preflight, свежую установку минимального профиля, повторную установку, settings draft и apply, compatible release update, injected failure и verified rollback, file recovery, functional health, non-root runtime и безопасный uninstall.

Это финальный tracer bullet всей программы: он проверяет взаимодействие опубликованных slices через их внешние интерфейсы и создаёт понятный release gate для будущих изменений installer.

## Acceptance criteria

- [ ] Disposable Ubuntu 24.04 environment создаётся и очищается воспроизводимо.
- [ ] Clean-VPS preflight проходит до установки Docker и Caddy и выдаёт ожидаемые результаты.
- [ ] Fresh install запрашивает только утверждённые пользовательские поля и успешно запускает минимальный профиль.
- [ ] Bot, Cabinet Mini App, PostgreSQL, Redis, Remnawave webhook, Caddy TLS и Telegram webhook проходят functional health.
- [ ] Bot runtime подтверждён как non-root, а public ingress не открывает database, Redis или лишние backend routes.
- [ ] Repeat install сохраняет настоящий pre-change recovery point и завершает транзакцию без потери данных.
- [ ] Legacy configuration fixture мигрируется в minimal environment и advanced override без потери non-default values.
- [ ] Settings draft остаётся неактивным до apply, показывает redacted plan и после apply отражается в observed runtime.
- [ ] Compatible Release Bundle обновляется вместе с PostgreSQL protection и фиксированными schema revisions.
- [ ] Injected failure после runtime mutation приводит к verified rollback либо ожидаемому safely stopped outcome с recovery plan.
- [ ] File recovery возвращает проверенный runtime и не завершается ложным no-op из-за transient state.
- [ ] Два Compose projects не конфликтуют при изолированной конфигурации.
- [ ] Uninstall удаляет выбранный stack, но сохраняет management launcher и recovery tooling.
- [ ] Test output сохраняет stage results и private diagnostic logs без раскрытия secrets.
- [ ] Lifecycle scenario запускается как обязательный release gate installer и документирован для maintainers.

## Blocked by

- [Issue 02: Миграция legacy-конфигурации и управляемый settings draft](./issue-02-legacy-config-migration-and-drafts.md)
- [Issue 03: Детерминированный Release Bundle и Cabinet artifact](./issue-03-deterministic-release-bundle.md)
- [Issue 04: Runtime Change Transaction для установки и настроек](./issue-04-runtime-change-transaction.md)
- [Issue 05: Безопасное обновление Bot Stack с защитой PostgreSQL](./issue-05-safe-stack-update.md)
- [Issue 06: Проверяемое восстановление и понятные backup artifacts](./issue-06-verified-file-recovery.md)
- [Issue 07: Production ingress, clean-VPS preflight и functional health](./issue-07-production-ingress-and-health.md)
- [Issue 08: Изоляция runtime и стабильное управление installer](./issue-08-runtime-isolation-and-management.md)
