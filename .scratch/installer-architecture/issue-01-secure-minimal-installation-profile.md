---
type: issue
title: Безопасный минимальный профиль установки
execution: AFK
status: done
labels:
  - done
created: 2026-08-14
---

# Безопасный минимальный профиль установки

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Сделать свежую установку безопасной и минимальной от первого вопроса мастера до успешно запущенного Bot Stack. Installer должен удалить устаревшую специальную конфигурацию Heleket, генерировать независимые секреты и случайный пароль PostgreSQL, атомарно сохранять secret-bearing artifacts и создавать только production environment, необходимый для Telegram Bot в webhook-режиме, PostgreSQL, Redis, Cabinet Mini App, Web API и подписанных Remnawave webhooks.

Необязательные возможности Bot должны использовать application defaults и не копироваться в production environment. Результат проверяется запуском основного профиля и отсутствием unrelated settings в сгенерированной конфигурации.

## Acceptance criteria

- [x] Новая установка никогда не использует известный или статический пароль PostgreSQL.
- [x] Telegram webhook secret, Web API token, Cabinet JWT secret и PostgreSQL password генерируются независимо криптографически безопасным способом.
- [x] Файлы с секретами имеют restrictive permissions с момента создания, заменяются атомарно и очищают временные данные при ошибке.
- [x] Сгенерированный Bot environment содержит только installer-owned параметры основного профиля и не копирует полный reference environment.
- [x] Cabinet, Web API, Cabinet Mini App и корректные CORS origins явно включены и производятся из введённого Cabinet domain.
- [x] Remnawave webhook явно включён, использует канонический path и введённый signing secret.
- [x] Heleket-specific state, generation, diagnostics и user-facing settings полностью удалены из installer.
- [x] Generic settings apply не может незаметно заменить identity уже инициализированной PostgreSQL.
- [x] Автоматические тесты проверяют состав минимального environment, отсутствие stale placeholders и запуск основного профиля.
- [x] Пользовательская документация описывает новый минимальный набор вводимых и генерируемых значений.

## Blocked by

None - can start immediately

## Verification

- Clean Ubuntu 24.04 suite: 41 tests passed, including POSIX permissions and atomic interruption cleanup.
- Disposable VPS fresh-install gate passed for the minimal Bot/Cabinet profile.
