---
type: issue
title: Проверяемое восстановление и понятные backup artifacts
execution: AFK
status: done
labels:
  - done
created: 2026-08-14
---

# Проверяемое восстановление и понятные backup artifacts

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Превратить восстановление файловой копии в завершённый Recovery lifecycle. Installer должен отличать file backup без PostgreSQL/Redis от migration package, проверять artifact до остановки сервисов, создавать safety backup, quiesce затронутые процессы, восстанавливать данные, инвалидировать transient control state, активировать runtime и проверять итог. Успех означает работающий восстановленный стек, а не только скопированные файлы.

При ошибке recovery должен по возможности вернуть safety backup и проверить возврат. Пользователь должен видеть, какие данные входят в каждый artifact и почему локальная файловая копия не заменяет off-host disaster recovery.

## Acceptance criteria

- [x] UI и документация однозначно различают file backup и migration package.
- [x] Artifact structure, paths и checksums проверяются до остановки работающих сервисов.
- [x] Перед restore создаётся проверенный safety backup текущего состояния.
- [x] Processes, использующие восстанавливаемые bind mounts, останавливаются до замены файлов.
- [x] Applied hashes, temporary overrides и migration markers не могут превратить восстановление в ложный no-op.
- [x] Restore самостоятельно активирует Docker, Caddy и Telegram state через Runtime Change lifecycle.
- [x] Recovery success требует полного post-restore health, а не только успешной распаковки.
- [x] Failure после начала restore возвращает и проверяет safety backup, когда rollback технически возможен.
- [x] Corrupt, unsafe или foreign-project artifact отклоняется без изменения runtime.
- [x] Runbook содержит off-host storage guidance и явно описывает состав каждого artifact.
- [x] Автоматические тесты используют реальные archive fixtures и покрывают interrupted recovery и rollback failure.

## Blocked by

- [Issue 04: Runtime Change Transaction для установки и настроек](./issue-04-runtime-change-transaction.md)

## Verification

- Windows regression: 37 tests passed, 1 POSIX permission test skipped.
- Clean `ubuntu:24.04` regression: 37 tests passed, including POSIX permissions.
- Package-manager lock and Recovery runtime adapter harnesses passed on Ubuntu.
- Disposable Ubuntu 24.04 VPS gate passed on 1 CPU, 2 GB RAM and 10 GB disk.
- The VPS gate verified fresh deployment, PostgreSQL, Redis, Bot, public Caddy TLS,
  Telegram webhook, Cabinet API/frontend, file-backup creation, file mutation,
  completed Recovery activation and post-recovery health.
- Postflight verified removal of the test project, containers, Caddy snippet and
  remote integration environment file.
