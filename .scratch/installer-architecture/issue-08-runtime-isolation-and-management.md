---
type: issue
title: Изоляция runtime и стабильное управление installer
execution: AFK
status: ready-for-agent
labels:
  - ready-for-agent
created: 2026-08-14
---

# Изоляция runtime и стабильное управление installer

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Уменьшить privileges работающего стека и отвязать управление от случайного исходного clone installer. Bot должен работать как non-root application user с корректно подготовленными persistent directories. Compose resources должны изолироваться стабильным project identity без глобальных container names. Management launcher должен указывать на установленную версионированную копию installer и сохраняться при обычном удалении Bot Stack.

Срез должен доказать, что production и изолированный staging project могут сосуществовать при разных domains и host ports, а uninstall удаляет только выбранный stack и не уничтожает инструмент восстановления без отдельного подтверждения.

## Acceptance criteria

- [ ] Bot container работает как non-root application user.
- [ ] Data, logs, uploads и backups получают минимально необходимые ownership и permissions без запуска Bot как root.
- [ ] Compose использует стабильный project identity и не требует global container names.
- [ ] Два изолированных projects могут пройти Compose validation и запуск без resource-name collisions при разных host ports и domains.
- [ ] Backend остаётся привязанным к loopback или private network, а internal application port не меняется вместе с host port.
- [ ] Management launcher указывает на стабильную установленную версию installer, а не на первоначальный clone.
- [ ] Удаление исходного clone не ломает maintenance launcher.
- [ ] Обычный uninstall удаляет только выбранный stack и сохраняет management/recovery tooling.
- [ ] Полное удаление installer требует отдельного явного подтверждения.
- [ ] Автоматические integration tests покрывают non-root writes, two-project isolation и launcher behavior после uninstall.
- [ ] Runbook описывает project identity, filesystem permissions и варианты удаления.

## Blocked by

- [Issue 01: Безопасный минимальный профиль установки](./issue-01-secure-minimal-installation-profile.md)
