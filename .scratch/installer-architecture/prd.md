---
type: prd
title: Безопасная и воспроизводимая установка Bedolaga Bot Stack
status: ready-for-agent
labels:
  - ready-for-agent
created: 2026-08-14
---

# Безопасная и воспроизводимая установка Bedolaga Bot Stack

## Problem Statement

Администратору нужна предсказуемая установка Bedolaga Bot и Cabinet на чистую VPS, безопасное изменение настроек, совместимое обновление, понятная диагностика и надёжное восстановление после ошибки.

Текущий installer уже автоматизирует подготовку Ubuntu, Docker Compose, PostgreSQL, Redis, Bot, Cabinet, Caddy и Telegram webhook. Однако установка и обслуживание зависят от нескольких представлений конфигурации, большого набора глобальных shell-переменных и последовательности побочных эффектов, которая не оформлена как единая транзакция.

На практике это создаёт следующие проблемы для администратора:

- PostgreSQL может быть установлен с известным паролем по умолчанию.
- Секреты дублируются в нескольких служебных файлах, сгенерированных конфигурациях, snapshots и backup-архивах.
- Ручное редактирование может рассинхронизировать desired configuration, сгенерированные файлы и реально работающий runtime.
- Частичная ошибка во время deploy может оставить Bot, Cabinet, Caddy и Telegram webhook в разных состояниях.
- Повторная установка может перезаписать состояние до создания корректной точки восстановления.
- Обновление исходников может выполнить миграцию PostgreSQL, которую нельзя безопасно отменить простым возвратом Git checkout.
- Bot и Cabinet можно обновлять независимо без формально заданного контракта совместимости.
- Плавающие ветки и Docker tags не гарантируют воспроизводимость повторной установки и rollback.
- Файловое восстановление может вернуть hashes применённого состояния и затем ошибочно сообщить, что применять нечего.
- Проверка чистой VPS смешана с проверками уже установленного Docker, Caddy и runtime.
- HTTP 200 от Cabinet SPA не доказывает, что frontend совместим с backend и действительно работает.
- Ошибка одной операции завершает всё меню вместо предоставления контролируемого retry, rollback или диагностики.

Пользователь не должен знать внутренний порядок генерации env, сборки Cabinet, запуска Compose, установки Caddy и регистрации webhook. Installer должен скрывать эту сложность и давать простой результат: операция либо полностью завершена и проверена, либо предыдущее рабочее состояние восстановлено, либо стек безопасно остановлен с точным recovery plan.

## Solution

Модернизировать installer поэтапно, сохранив существующее интерактивное меню и рабочие сценарии, но поместив сложное поведение за небольшими проверяемыми интерфейсами.

Решение включает:

- Канонический Installation Configuration module, который владеет схемой параметров, defaults, validation, derived values, secret classification, загрузкой, diff и рендером всех производных конфигураций.
- Отдельное root-only хранилище секретов с атомарной записью и минимальным количеством копий.
- Разделение состояния на desired, applied и observed, чтобы редактирование не выдавало черновик за работающую конфигурацию.
- Runtime Change Transaction module, который выполняет plan, protect, apply, verify, commit и rollback policy для первой установки, применения настроек, обновления и восстановления.
- Release Bundle module, который разрешает выбранный release в точные Bot SHA, Cabinet SHA, Docker image digests, версию backend contract и политику миграций.
- Recovery module, который восстанавливает не только файлы, но и согласованный работающий runtime либо возвращает safety backup.
- Installation Health module с общей матрицей фактов и отдельными политиками bootstrap preflight, deployment readiness и functional health.
- Сужение публичной поверхности Caddy до реально необходимых маршрутов и атомарная установка его конфигурации.
- Стабильный контракт поставки Cabinet, который не требует от installer знания внутреннего устройства произвольного Dockerfile.
- Инкрементальная совместимость с существующими установками и явная миграция старого state в новую модель.

Результатом должна стать установка, которую можно повторить, проверить, обновить и восстановить без скрытых расхождений между заявленным и фактическим состоянием.

## User Stories

1. As an administrator, I want to install Bot and Cabinet with one guided operation, so that I do not need to manually coordinate Docker, Caddy and Telegram.
2. As an administrator, I want the installer to check the VPS before requesting irreversible changes, so that obvious infrastructure problems are found early.
3. As an administrator, I want bootstrap checks to work on a clean VPS, so that missing Docker or Caddy is treated as an installation task rather than an unexplained failure.
4. As an administrator, I want the installer to validate supported Ubuntu versions, CPU, RAM and disk, so that the stack is not deployed onto an unsuitable server.
5. As an administrator, I want the installer to validate that ports 80 and 443 can be used safely, so that deployment does not break an unrelated web server.
6. As an administrator, I want the installer to verify that both domains point to the intended VPS, so that Caddy and Telegram are not configured against incorrect DNS.
7. As an administrator, I want the installer to validate the Telegram bot token and administrator IDs, so that invalid credentials are rejected before deployment.
8. As an administrator, I want the installer to verify Remnawave connectivity and authentication, so that the bot does not start in an unusable state.
9. As an administrator, I want PostgreSQL to receive a cryptographically random password during first installation, so that the database is not protected by a known default.
10. As an administrator, I want generated secrets to be independent from each other, so that compromise of one credential does not compromise every interface.
11. As an administrator, I want secrets to be written only to root-readable files, so that other users on the VPS cannot read production credentials.
12. As an administrator, I want temporary files containing secrets to be removed after success or failure, so that interrupted installation does not leave credentials behind.
13. As an administrator, I want the installer to warn me before exporting an archive containing secrets, so that I handle the artifact appropriately.
14. As an administrator, I want one canonical configuration model, so that the same setting cannot silently have different values in state and runtime files.
15. As an administrator, I want every configuration value to be validated before it becomes desired configuration, so that malformed domains, ports and identifiers are rejected.
16. As an administrator, I want derived values such as Cabinet URL and CORS origins to be generated consistently, so that related settings cannot drift apart.
17. As an administrator, I want viewing configuration to be read-only, so that merely opening a summary cannot alter production state.
18. As an administrator, I want edited settings to remain a draft until I explicitly apply them, so that repair actions continue to use the active configuration.
19. As an administrator, I want to see a redacted diff before applying settings, so that I understand what will change without exposing secret values.
20. As an administrator, I want database identity settings to be protected from ordinary env editing, so that changing text does not disconnect Bot from an existing PostgreSQL volume.
21. As an administrator, I want database credential rotation to be a dedicated verified operation, so that PostgreSQL and Bot credentials change together.
22. As an administrator, I want generated env, Compose and Caddy files to be created atomically, so that an interrupted render cannot leave a partial configuration.
23. As an administrator, I want the installer to reject unresolved template placeholders, so that incomplete configuration cannot reach runtime.
24. As an administrator, I want repeat installation to preserve the previous applied state before writing anything, so that a real rollback point always exists.
25. As an administrator, I want installation to follow a visible sequence of stages, so that I can identify exactly where a failure occurred.
26. As an administrator, I want an operation to commit only after all required health checks pass, so that installer success means the stack is usable.
27. As an administrator, I want a failed reversible operation to restore the previous runtime automatically, so that partial deploys do not remain active.
28. As an administrator, I want an irreversible database migration to stop with a precise recovery plan, so that the installer does not claim a rollback it cannot safely perform.
29. As an administrator, I want a database backup before a Bot update that may migrate schema, so that data can be recovered when compatibility is lost.
30. As an administrator, I want the current Alembic revision recorded before and after update, so that database state can be correlated with the Bot release.
31. As an administrator, I want Bot and Cabinet to be installed as a compatible release bundle, so that frontend and backend versions are known to work together.
32. As an administrator, I want a selected branch or tag resolved to an immutable commit SHA, so that the installed version cannot change later under the same name.
33. As an administrator, I want exact Docker image digests recorded, so that a restored installation uses the same database and cache images.
34. As an administrator, I want checkout errors to stop deployment, so that the installer cannot silently build a different revision from the requested one.
35. As an administrator, I want the installer to verify that repository HEAD equals the resolved SHA before build, so that release metadata matches actual source.
36. As an administrator, I want rollback to use the previous exact SHA rather than pull the current branch head, so that rollback is deterministic.
37. As an administrator, I want incompatible independent Bot or Cabinet updates to be blocked or explicitly marked unsafe, so that API incompatibility is not introduced accidentally.
38. As an administrator, I want Cabinet delivery to use a stable artifact contract, so that installer behavior is not coupled to an internal container path.
39. As an administrator, I want Cabinet assets to be replaced atomically, so that users never receive a half-built frontend.
40. As an administrator, I want Cabinet health checks to verify a backend contract and runtime configuration, so that a static HTTP 200 is not mistaken for a working application.
41. As an administrator, I want the local backend port to remain a stable container contract, so that changing a host port cannot make the health check target the wrong internal port.
42. As an administrator, I want PostgreSQL and Redis to remain inaccessible from the public network, so that infrastructure data stores are not exposed.
43. As an administrator, I want the Bot backend bound to loopback or an internal Docker network, so that Caddy is the only public ingress.
44. As an administrator, I want the webhook domain to expose only required routes, so that administrative and Cabinet routes are not unnecessarily public.
45. As an administrator, I want TLS checks to validate the real certificate, so that an invalid certificate is reported rather than accepted with an insecure probe.
46. As an administrator, I want Caddy configuration to be validated before activation, so that an invalid candidate cannot replace the working configuration.
47. As an administrator, I want Caddy rollback to cover reload and external post-check failures, so that a syntactically valid but unusable configuration is not committed.
48. As an administrator, I want proxy headers to preserve the real client IP, so that rate limiting, payment checks and authentication receive correct network information.
49. As an administrator, I want Telegram webhook registration to be part of the runtime transaction, so that Bot runtime and Telegram routing cannot diverge silently.
50. As an administrator, I want the pending-update policy to be explicit, so that an update does not unexpectedly discard Telegram events.
51. As an administrator, I want a file backup to have a name that clearly distinguishes it from a disaster-recovery package, so that I know whether PostgreSQL and Redis are included.
52. As an administrator, I want recovery to validate archive structure and checksums before stopping services, so that a corrupt artifact does not disrupt a working installation.
53. As an administrator, I want recovery to stop processes that use restored bind mounts, so that files are not replaced while Bot is writing to them.
54. As an administrator, I want recovery to invalidate transient applied hashes, so that restored configuration is always activated and checked.
55. As an administrator, I want successful recovery to include Docker, Caddy and Telegram activation, so that recovery ends with a verified working stack rather than copied files.
56. As an administrator, I want a safety backup created before recovery, so that I can return to the state that existed immediately before the attempt.
57. As an administrator, I want a failed recovery to restore its safety backup automatically when possible, so that the attempt does not worsen the incident.
58. As an administrator, I want off-host backup guidance and verification, so that local disk failure does not destroy both production and all backups.
59. As an administrator, I want installer errors to return me to a controlled menu state, so that one failed command does not terminate the whole maintenance session.
60. As an administrator, I want failed stages to show a concise reason and log location, so that I can diagnose the issue without reading all source code.
61. As an administrator, I want retry, rollback and log actions after a failed operation, so that the next safe action is obvious.
62. As an administrator, I want command stderr preserved in the private installer log, so that useful diagnostics are not lost.
63. As an administrator, I want the maintenance launcher to point to a stable installed copy of the installer, so that deleting the original clone does not break management.
64. As an administrator, I want uninstall to preserve the installer management path unless explicitly requested, so that recovery remains possible after stack removal.
65. As an administrator, I want fixed Compose project names instead of global container names, so that staging and production can coexist on one VPS when needed.
66. As an administrator, I want Bot to run as a non-root container user, so that a Bot vulnerability has fewer privileges over the host-mounted data.
67. As an administrator, I want filesystem ownership prepared for the Bot user, so that non-root execution does not break uploads, logs or backups.
68. As an administrator, I want configuration and runtime state migration to preserve existing installations, so that architectural improvements do not require reinstalling production.
69. As an administrator, I want old state to be backed up before migration, so that migration can be reversed if validation fails.
70. As an administrator, I want the installer documentation to match actual service names, network names and required settings, so that manual recovery instructions remain accurate.
71. As a maintainer, I want configuration round-trip behavior tested through one high-level seam, so that every supported key survives load, edit, render and reload.
72. As a maintainer, I want runtime changes tested by injecting failure after each stage, so that rollback behavior is proven rather than assumed.
73. As a maintainer, I want release resolution tested independently from Git network availability, so that compatibility logic is deterministic.
74. As a maintainer, I want recovery tested with real archive fixtures and transient state, so that false successful no-op recovery cannot regress.
75. As a maintainer, I want generated Compose and Caddy configurations validated by their native tools, so that syntax tests reflect production behavior.
76. As a maintainer, I want an end-to-end installation test on Ubuntu 24.04, so that package installation and host integration are covered.
77. As a maintainer, I want tests to assert external results rather than shell helper call order, so that internal refactoring does not make the suite brittle.
78. As a maintainer, I want a documented failure classification, so that reversible failures, unsafe migrations and user errors receive different recovery behavior.
79. As a maintainer, I want installation operations to return structured results, so that the menu can present failure details without library code terminating the process.
80. As a maintainer, I want documentation discrepancies discovered by installer validation to be captured and resolved, so that the product has one operational truth.
81. As an administrator, I want obsolete Heleket settings removed from the installer, so that partially supported payment fields do not create misleading or inconsistent configuration.
82. As an administrator, I want the installer to generate a minimal Bot environment for Telegram, Cabinet Mini App and Remnawave webhooks, so that the production configuration contains only settings owned and required by the installation flow.

## Implementation Decisions

- The modernization will be incremental. The existing interactive menu and successful installation workflows remain the user-facing entry point. A complete rewrite in another language is not required.
- The installer remains targeted at Ubuntu 24.04 for this PRD. Broader Linux support requires a separate product decision and adapter strategy.
- Installation Configuration becomes a deep module. Its external interface covers loading existing installation intent, validating a draft, calculating a redacted change plan, rendering derived artifacts and committing desired configuration.
- The existing Python configuration helper is the preferred starting seam because it already parses env and state without sourcing untrusted shell content. It will absorb schema, defaults, validation, derivation and rendering responsibilities that are currently spread across shell modules.
- One canonical schema defines every supported key, type, default, validator, secret classification, mutability rule and destination. Adding a key in multiple manually synchronized lists is not an accepted design.
- Heleket-specific settings are removed from installer state, configuration schemas, generated environment handling, diagnostics and user-facing configuration. This removes the installer's incomplete special case without changing Heleket support inside Bot itself.
- The generated Bot environment is reduced to the installer-owned production minimum. It contains only Telegram identity and administration, PostgreSQL and Redis connectivity, Remnawave API access, Remnawave webhook reception, Telegram webhook runtime, Web API, Cabinet authentication and CORS, Cabinet Mini App routing, timezone and other values proven necessary to boot and verify this installation profile.
- Optional Bot features, payment providers, marketing features, monitoring tuning and product defaults are not copied into the generated environment merely because they exist in a reference example. When absent, Bot's validated application defaults remain authoritative.
- Cabinet Mini App mode is explicit in the minimal environment. The installer enables Cabinet and Web API, sets the Cabinet public URL and allowed origins, selects Cabinet as the main menu mode and provides the Mini App URL derived from the Cabinet domain.
- Remnawave webhook mode is explicit in the minimal environment. The installer enables reception, sets the canonical webhook path and supplies the shared signing secret collected from the administrator.
- The minimal environment keeps production-safe values explicit where relying on an application default would create operational or security ambiguity, including disabled public API documentation, explicit CORS origins and the Telegram pending-update policy.
- Existing custom Bot settings are not discarded when migrating from the full reference environment. Non-minimal values that differ from Bot defaults are moved to a separate user-owned override environment or otherwise preserved outside the installer-owned generated file.
- Installer regeneration owns only the minimal generated environment. It must not overwrite the user-owned advanced override, and Compose loads the override with deterministic precedence when it exists.
- State is explicitly separated into desired, applied and observed. Desired is administrator intent, applied identifies the last successfully committed configuration and release, and observed is collected from Git, Docker, Caddy, Telegram and health endpoints.
- Reading or displaying configuration is side-effect free. Editing creates a draft. Desired state changes only after validation and explicit confirmation.
- Secrets are stored in a dedicated root-only file or equivalent root-only secret store. Non-secret state references secret identifiers rather than duplicating secret values.
- Secret-bearing files are created with restrictive permissions from the start, written to temporary files in the destination directory and atomically renamed. Cleanup runs on both success and failure.
- The PostgreSQL password is generated cryptographically during first installation. Known fallback passwords are rejected.
- PostgreSQL database name, user and password become immutable through the generic settings editor after volume initialization. Credential rotation is a dedicated transactional workflow.
- The generated Compose configuration consumes PostgreSQL credentials through the root-only environment or secret mechanism rather than embedding the password directly in the generated document.
- Generated artifacts are validated for unresolved placeholders and required values before they can enter a runtime transaction.
- Runtime Change becomes a deep module with the lifecycle plan, protect, apply, verify, commit and rollback policy.
- The runtime transaction operates on an explicit plan containing affected areas, reversible actions, required protection artifacts, health policy and rollback policy.
- The transaction owns Cabinet artifact activation, Compose changes, Caddy activation and Telegram webhook state when those areas are affected. Callers do not manually reproduce their ordering constraints.
- Snapshots and database dumps are created before the first mutation, not after desired configuration or repository state has already changed.
- Library-level operations return structured success or failure information. Only the top-level command decides whether to return to the menu or exit the process.
- Failure results identify the failed stage, a safe next action, whether rollback was attempted, whether rollback verification passed and where diagnostics were logged.
- Database migration safety is explicit. The installer records the current schema revision, takes a PostgreSQL dump before potentially schema-changing Bot updates and records the post-update revision.
- Automatic rollback is promised only when the release metadata declares the database change compatible with the previous Bot. Otherwise the safe failure mode is to stop the affected runtime and present a recovery plan.
- Release Bundle becomes the canonical release unit for production installation and grouped updates.
- A release bundle records immutable Bot and Cabinet commits, immutable runtime image identifiers, backend contract version, required configuration schema version and database migration compatibility.
- User-selected branches and tags are resolved to immutable commits before mutation. Requested ref and resolved SHA are stored separately.
- Checkout failures are fatal. The resolved commit is verified against repository HEAD before build.
- Rollback targets exact previous commits and image identifiers. Rollback does not pull a moving branch.
- Independent Bot or Cabinet updates remain possible only when compatibility metadata confirms the resulting pair. Unsafe manual combinations require explicit expert override and are not the default path.
- Existing VPS migration packages remain a supported release adapter because they already carry exact source and image artifacts. Fresh release installation is the second real adapter.
- Cabinet delivery uses a documented release artifact contract. The installer must not depend on undocumented paths inside an arbitrary image.
- Cabinet assets are built or unpacked into a candidate directory and switched atomically only after validation.
- The fixed internal backend port remains part of the container contract. A separately named host loopback port may be configurable; editing the host port does not change the container listener or internal health endpoint.
- Fixed container names are removed in favor of a stable Compose project name. This avoids global collisions and permits isolated staging when explicitly configured.
- Bot runs as the image's non-root application user. Runtime directories are prepared with matching ownership rather than bypassing permissions by running the process as root.
- Caddy is a real deployment adapter because host Caddy and potential future proxy arrangements genuinely vary. No extra abstractions are introduced around individual file-copy or curl operations.
- The webhook host exposes an allowlist of required routes. Cabinet and administrative routes are not publicly exposed through the webhook host unless a documented integration requires them.
- Caddy candidate activation includes full-config validation, atomic file replacement, reload, local probe and public TLS probe. The previous configuration remains available until all required checks pass.
- Public TLS verification validates certificates normally. Insecure local routing probes, if needed, are a separate explicitly named check and cannot satisfy public TLS health.
- Telegram webhook state is observed before change and updated within the runtime transaction. Pending update deletion remains disabled by default and is represented as an explicit policy.
- Recovery becomes a deep module with artifact validation, service quiescing, safety backup, restore, transient-state invalidation, runtime activation, verification and commit or rollback.
- Applied hashes, in-progress migration markers, temporary overrides and other transient control files are excluded from restorable desired state or invalidated before activation.
- The existing local archive is renamed in the user interface to indicate that it is a file backup without PostgreSQL and Redis. The migration package remains the disaster-recovery and cross-VPS artifact.
- Installation Health provides one fact collection model with separate policies for bootstrap preflight, deployment readiness, post-deploy functional health and comprehensive doctor diagnostics.
- Bootstrap preflight does not require packages that the installer is expected to install.
- Deployment readiness validates generated artifacts, repository revisions, Docker and Caddy availability, DNS destination, ports and required external connectivity.
- Functional health checks PostgreSQL, Redis, Bot health, expected database revision, Cabinet backend contract, Cabinet runtime configuration, public frontend delivery, Caddy and Telegram routing.
- A plain Cabinet root HTTP 200 is supporting evidence only and cannot by itself mark deployment healthy.
- Remnawave synchronization required for purchases is verified after initial startup or clearly reported as an outstanding product setup action.
- Installer stderr is retained in a root-only log. The terminal presents a concise explanation rather than suppressing diagnostic output.
- The management launcher points to a stable installed copy of the installer, not the directory from which installation happened to be launched.
- Existing installations receive a one-time state migration. Migration creates a backup, detects initialized PostgreSQL credentials, resolves actual repository commits and validates generated artifacts before committing the new state format.
- Documentation is updated in the same workstream to use actual Compose service names, canonical network names, required Cabinet settings and the new backup terminology.
- No new seam is introduced unless behavior genuinely varies or the seam is the highest practical point for external-behavior testing.

## Testing Decisions

- Good tests assert behavior visible through a module's public interface: accepted or rejected configuration, generated artifacts, committed state, observed runtime, rollback outcome and recovery result. Tests do not assert internal helper call order, shell function count or private implementation details.
- The highest preferred configuration seam is the Installation Configuration interface. Tests load a representative existing installation, apply a draft, validate it, render artifacts and load them back to prove that all schema keys survive a state-to-env-to-state round trip without loss or mutation.
- Configuration tests cover valid and invalid domains, URLs, ports, Telegram credentials, administrator IDs, PostgreSQL identifiers, timezones, booleans, optional integrations and inline comments from legacy env files.
- Minimal-environment tests verify that a fresh render contains every value required for Telegram webhook mode, Cabinet Mini App, PostgreSQL, Redis, Web API and Remnawave webhooks, while excluding unrelated payment, marketing and optional feature settings.
- A clean-stack integration test starts Bot and Cabinet using only the generated minimal environment and verifies Telegram webhook configuration, Cabinet backend and frontend readiness, Mini App routing and signed Remnawave webhook reception.
- Environment migration tests verify that existing non-default advanced settings are preserved in the user-owned override and that subsequent installer regeneration does not modify them.
- Secret tests verify independent random generation, absence of known defaults, restrictive permissions from file creation, atomic replacement, redacted diff output and cleanup after an injected interruption.
- Database identity tests verify that generic editing rejects initialized PostgreSQL identity changes and that dedicated credential rotation updates PostgreSQL and Bot together or restores the old credential.
- The highest runtime seam is the Runtime Change Transaction interface. Tests provide controlled adapters and inject failure after protect, Cabinet activation, Compose activation, Caddy activation, Telegram update and final verification.
- Runtime transaction tests verify that commit occurs only after successful verification, rollback uses the captured previous state, rollback itself is verified and unsafe database states produce a safe stop plus recovery plan.
- Native Compose and Caddy tools validate generated candidates in integration tests. Text matching alone is not sufficient for syntax or semantic validation.
- Release Bundle tests resolve tags and branches to immutable commits, reject missing refs, detect mismatched repository HEAD, preserve requested ref separately from SHA and return exact rollback artifacts.
- Compatibility tests reject unsupported Bot/Cabinet pairs, missing backend contract versions and releases whose configuration schema is newer than the installer can support.
- Cabinet artifact tests treat the documented artifact contract as the seam. They verify complete extraction into a candidate, validation, atomic switch and preservation of the previous frontend on failure.
- Recovery tests operate through the Recovery interface with real archive fixtures. They cover corrupt archives, unsafe paths, foreign project roots, transient applied hashes, interrupted extraction, service stop failure, activation failure and successful safety rollback.
- Recovery success tests assert running and verified Docker, Caddy and Telegram state, not merely restored files.
- Health tests operate through Installation Health policies. The same observed facts must produce appropriate results for bootstrap, deployment readiness and functional health without duplicating probe logic.
- Functional Cabinet tests verify a backend contract endpoint and runtime configuration in addition to static frontend delivery. Browser-level smoke coverage may be added for authentication bootstrapping when a deterministic test identity is available.
- TLS tests include a valid certificate, hostname mismatch, expired certificate and connection failure. Insecure probes cannot make the public TLS policy pass.
- Migration tests start from representative legacy state and env fixtures. They verify backup creation, correct secret extraction, exact Git SHA discovery, preservation of user configuration and rollback on validation failure.
- End-to-end tests run on an isolated Ubuntu 24.04 VM or equivalent disposable environment and cover first install, repeat install, configuration apply, grouped update, injected update failure, file recovery and uninstall preservation of the management launcher.
- A database migration end-to-end scenario verifies pre-update dump creation, schema revision recording and the declared rollback policy.
- A two-project scenario verifies that removal of fixed container names permits isolated Compose projects without port or resource collisions when distinct host ports and domains are configured.
- Existing installer code has no established automated test suite or CI prior art. The closest behavioral prior art is the current environment helper, doctor checks, migration checksum validation, Compose validation and Caddy validation. New tests should preserve these useful production checks while moving assertions to the higher module seams.
- Shell syntax validation and static analysis remain supporting checks, not substitutes for behavioral tests.
- Test fixtures never contain real production tokens or customer data.

## Out of Scope

- Rewriting the entire installer in Python, Go or another language solely for stylistic consistency.
- Replacing Docker Compose with Kubernetes, Nomad or another orchestrator.
- Introducing Ansible, Terraform or a general-purpose configuration-management platform as a prerequisite for one-VPS installation.
- Supporting every Linux distribution in the first modernization phase.
- Changing Bedolaga Bot, Cabinet or Remnawave business behavior unrelated to installation and operations.
- Redesigning payment provider logic or collecting credentials for every optional provider during the base installation. Removing the installer's stale Heleket-specific fields is explicitly in scope and does not change Bot payment behavior.
- Replacing Caddy with a new mandatory reverse proxy. Other proxy adapters may be considered separately if there is a real supported deployment mode.
- Building a hosted control plane for managing multiple customer VPS instances.
- Implementing high availability, multi-node PostgreSQL or Redis clustering.
- Replacing local root-only secret storage with an external Vault or cloud secret manager. The design must not prevent such an adapter later, but it is not required now.
- Guaranteeing automatic downgrade of arbitrary Alembic migrations.
- Automatically testing real financial transactions during deployment health checks.
- Automatically changing external DNS, BotFather settings, payment-provider callbacks or third-party firewall configuration without a separately approved integration.
- Treating local file backup as an off-host disaster-recovery solution.
- Reopening unrelated Cabinet UI or Bot architecture decisions.

## Further Notes

- The installer repository currently has no domain glossary or accepted ADRs. This PRD therefore uses the terms Installation Configuration, desired state, applied state, observed state, Runtime Change, Release Bundle, Recovery, file backup and migration package as canonical working vocabulary for this workstream.
- The documentation describes Redis as optional, while the complete production Compose and several Cabinet flows depend on it. This PRD treats Redis as required for the full Bot plus Cabinet installation profile.
- Documentation contains inconsistent Compose service names and Docker network names. Generated installer configuration is the operational source during implementation, and documentation must be reconciled with it.
- Cabinet requires Web API, Cabinet URL and explicit CORS configuration even where individual setup pages omit some of those settings.
- The installer currently carries partial Heleket configuration in state and diagnostics without a complete installation flow. Those fields are intentionally removed rather than promoted into the base installation wizard.
- The current reference environment is much broader than the installation profile and contains values that can unintentionally enable or alter unrelated product behavior. It will remain documentation or example material only; it is no longer the source copied wholesale into production Bot configuration.
- The current installer already improves security over the generic documentation by binding the backend to loopback. That behavior must be preserved.
- Existing VPS migration functionality is more complete than the same-VPS file backup and should be reused rather than replaced where exact images, source revisions, PostgreSQL and Redis are required.
- The test seams in this PRD are intentionally placed above individual shell helpers: Installation Configuration, Runtime Change Transaction, Release Bundle, Recovery and Installation Health. This follows the requirement to test the highest practical external behavior.
- Because this PRD was synthesized without an interview, the test seams and terminology above are working decisions ready for agent implementation planning. Any later change to these decisions should be recorded before tickets are generated.
- Recommended delivery order is: configuration and secrets, recovery correctness, immutable release identity, Runtime Change transaction, Caddy and Cabinet hardening, health and menu error UX, then non-root and multi-project improvements.
- The work should be decomposed into independently deployable tracer-bullet tickets before implementation. Security and recovery fixes should not wait for completion of the entire architectural program.
