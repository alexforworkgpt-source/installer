---
type: issue
title: Миграция legacy-конфигурации и управляемый settings draft
execution: AFK
status: done
labels:
  - done
created: 2026-08-14
---

# Миграция legacy-конфигурации и управляемый settings draft

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Перевести существующие установки с широкого reference environment и нескольких расходящихся представлений конфигурации на каноническую Installation Configuration без потери пользовательских настроек. Installer должен отделить installer-owned minimum от user-owned advanced override, показывать конфигурацию без побочных эффектов, сохранять редактирование как draft и перед применением выдавать валидированный redacted change plan.

Миграция должна создавать safety backup, обнаруживать реальные значения старой установки, переносить non-default advanced settings в override и коммитить новый формат только после проверки round trip и производных artifacts.

## Acceptance criteria

- [x] Каноническая схема определяет тип, default, validation, secret classification, mutability и destinations каждого installer-owned параметра.
- [x] Просмотр конфигурации не изменяет desired, applied или runtime state.
- [x] Редактирование создаёт draft и не влияет на repair или другие операции до явного apply.
- [x] Перед apply пользователь видит redacted plan, в котором секреты никогда не раскрываются.
- [x] Legacy migration создаёт safety backup до изменения существующего state или environment.
- [x] Значения, необходимые минимальному профилю, корректно переходят в installer-owned configuration.
- [x] Non-default advanced settings сохраняются в user-owned override с детерминированным приоритетом.
- [x] Повторная генерация installer-owned environment не изменяет advanced override.
- [x] State-to-environment-to-state round trip сохраняет все поддерживаемые значения без изменения или потери.
- [x] Ошибка migration validation возвращает прежний state и environment.
- [x] Автоматические тесты покрывают representative legacy fixtures, inline comments, missing values и custom advanced settings.

## Blocked by

- [Issue 01: Безопасный минимальный профиль установки](./issue-01-secure-minimal-installation-profile.md)

## Verification

- Typed Installation Configuration round-trip passed on Windows and clean Ubuntu 24.04.
- Legacy fixtures cover backup, comments, missing values, advanced override preservation and validation failure without mutation.
