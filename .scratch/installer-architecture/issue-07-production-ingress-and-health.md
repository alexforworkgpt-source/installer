---
type: issue
title: Production ingress, clean-VPS preflight и functional health
execution: AFK
status: ready-for-agent
labels:
  - ready-for-agent
created: 2026-08-14
---

# Production ingress, clean-VPS preflight и functional health

## Parent

[PRD: Безопасная и воспроизводимая установка Bedolaga Bot Stack](./prd.md)

## What to build

Дать администратору один достоверный путь от проверки чистой VPS до подтверждения работоспособности публичного Bot Stack. Bootstrap preflight должен проверять только то, что возможно до установки пакетов. Deployment readiness должен валидировать infrastructure и candidates. Functional health должен доказывать работу PostgreSQL, Redis, Bot, Cabinet frontend/backend contract, Mini App routing, подписанных Remnawave webhooks, Caddy TLS и Telegram webhook.

Одновременно webhook host должен открывать только необходимые routes. Caddy candidate должен активироваться атомарно с настоящей certificate verification и возвратом предыдущей конфигурации при reload или public post-check failure.

## Acceptance criteria

- [ ] Bootstrap preflight работает на чистой поддерживаемой Ubuntu без требования уже установленного Docker, Compose, Caddy или jq.
- [ ] Preflight проверяет OS, resources, ports, DNS destination и обязательную external connectivity с понятными причинами failure.
- [ ] Deployment readiness валидирует generated configuration, resolved release, Docker, Caddy и требуемые domains до runtime mutation.
- [ ] Webhook host проксирует allowlist Telegram, Remnawave и явно включённых integration routes вместо всего backend.
- [ ] PostgreSQL, Redis и backend не публикуются напрямую в интернет.
- [ ] Caddy candidate проходит full-config validation, atomic activation, reload, local probe и public post-check.
- [ ] Public TLS health отклоняет expired, untrusted и hostname-mismatched certificates; insecure probe не может дать успешный public result.
- [ ] Cabinet health проверяет versioned backend contract и runtime configuration, а не только HTTP 200 главной SPA.
- [ ] Remnawave health проверяет API connectivity, webhook configuration и результат обязательной initial synchronization либо сообщает outstanding setup action.
- [ ] Telegram health проверяет точный webhook URL и policy без удаления pending updates по умолчанию.
- [ ] Один observed fact model используется разными policies bootstrap, readiness, functional health и doctor.
- [ ] Native Compose и Caddy validation входят в автоматические integration tests.
- [ ] Документация использует фактические service names, network names, Cabinet requirements и health outcomes.

## Blocked by

- [Issue 01: Безопасный минимальный профиль установки](./issue-01-secure-minimal-installation-profile.md)
- [Issue 03: Детерминированный Release Bundle и Cabinet artifact](./issue-03-deterministic-release-bundle.md)
- [Issue 04: Runtime Change Transaction для установки и настроек](./issue-04-runtime-change-transaction.md)
