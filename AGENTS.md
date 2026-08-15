# Agent Instructions

## Communication

Communicate with the user in Russian unless the user explicitly requests another language.

## Agent skills

### Issue tracker

Issues and PRDs use local markdown under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels plus `done` for completed work. See `docs/agents/triage-labels.md`.

### Domain docs

This is a single-context project using root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.

### Matt Pocock skills

The engineering workflows from [mattpocock/skills](https://github.com/mattpocock/skills) are installed locally. Invoke the appropriate skill proactively when the request clearly matches its purpose; the user should not need to type a slash command or name the skill explicitly.

Before using one of these workflows, read its installed `SKILL.md` completely and follow it. Do not invoke a skill merely to mention it: use it to drive the actual work.

#### Automatic triggers

- `diagnose`: use automatically when the user reports broken, failing, incorrect, slow, hanging, or inconsistent behavior. Follow reproduce → minimise → hypothesise → instrument → fix → regression-test. For a trivial, already-proven typo, a full diagnosis loop is unnecessary.
- `tdd`: use automatically for financial calculations, Accounting Core rules, sync behavior, data transformations, bug fixes with regression risk, and other testable domain behavior. Start with a failing test, then implement and refactor. Skip only for documentation-only, styling-only, generated configuration, or infrastructure changes where a meaningful pre-implementation test is not practical; still add the strongest available verification.
- `triage`: use automatically when creating or reviewing bugs, feature requests, incomplete reports, or work items; when deciding whether an issue needs information, is ready for an agent/human, or should be rejected; and when updating local issue workflow state.
- `grill-with-docs`: use when a plan or feature still contains unresolved domain terms, business rules, boundaries, or hard-to-reverse architectural choices. Ask one question at a time and update `CONTEXT.md` or ADRs as decisions are resolved. Do not use it for routine implementation of an already approved issue.
- `grill-me`: use when the user asks to stress-test a plan but does not want project documentation updated inline. Prefer `grill-with-docs` when the decisions belong in this repository.
- `to-prd`: use when a sufficiently resolved conversation, plan, or feature brief should become a formal PRD. Synthesize existing decisions without restarting discovery or interviewing the user again.
- `to-issues`: use after a PRD or implementation plan is approved and needs to be decomposed into dependency-ordered, independently deliverable vertical slices. Present the proposed breakdown for approval before publishing issues.
- `prototype`: use before committing to an uncertain interaction, state machine, data model, or UI direction when a throwaway implementation can answer the question faster than discussion. Do not treat prototype code as production code or silently merge it into the product.
- `improve-codebase-architecture`: use when the user asks for architectural improvement, refactoring opportunities, reduced coupling, deeper modules, better testability, or easier agent navigation. Ground recommendations in `CONTEXT.md` and ADRs rather than generic patterns.
- `zoom-out`: use when a code area is unfamiliar or a local change cannot be evaluated safely without mapping its callers, dependencies, and domain role. Explore one abstraction level higher before editing.
- `handoff`: use when work must continue in another session or agent. Save a compact handoff in the OS temporary directory, reference existing artifacts instead of duplicating them, suggest relevant skills, and redact secrets.
- `setup-matt-pocock-skills`: use only when this repository's issue tracker, triage vocabulary, or domain-document layout is missing or intentionally changing. Do not rerun it for ordinary tasks now that setup is complete.

#### Workflow combinations

- Bug report: `diagnose`, then `tdd` for the regression fix, then `triage` if an issue must be created or updated.
- New business rule: `grill-with-docs` if unresolved; once approved, `tdd` for implementation.
- New substantial feature: `grill-with-docs` when needed → `to-prd` → `to-issues` → implement each AFK issue with `tdd` where applicable.
- Uncertain UI direction: `prototype` first; after approval, implement with the design tooling below and verify in a browser.
- Architecture review: `zoom-out` to map the area when necessary, then `improve-codebase-architecture` for concrete recommendations.

These triggers are defaults, not ceremony. Choose the smallest workflow that materially improves correctness, clarity, or handoff quality.

### Правила разработки

Не ломай существующую логику и не переписывай рабочий код без необходимости.
Перед изменениями изучай текущую структуру проекта и придерживайся уже принятого стиля кода, компонентов и UI.
Не раздувай файлы: один файл — одна зона ответственности. Обычные компоненты, хуки,
сервисы и API-обработчики старайся держать до 200–300 строк; если файл приближается к 400–500 строкам, сначала оцени декомпозицию.
Не прячь бизнес-логику внутри UI, выноси сложную логику в отдельные модули, хуки или сервисы.
Если данных не хватает — не выдумывай, а явно укажи допущение или задай вопрос.
При внесении изменений придерживайся такого порядка:

1. В первую очередь используй уже существующие компоненты, классы, переменные, токены, utility-классы и паттерны проекта.
2. Не создавай новые классы и стили, если задачу можно решить через существующую систему стилей.
3. Если без нового класса или нового стиля не обойтись, сначала проверь, действительно ли нет подходящего существующего решения.
4. Не дублируй стили, которые уже есть в проекте под другим именем.
5. Не добавляй инлайн-стили без крайней необходимости.
6. Не ломай существующую структуру, не меняй глобальные стили без необходимости.
7. Все изменения должны быть в логике текущей дизайн-системы проекта.
8. Если создаешь новый класс, делай это только как исключение и только если это нельзя решить через существующие сущности.

Перед тем как добавлять новый класс или стиль:
- проверь, есть ли в проекте аналогичный элемент;
- проверь, можно ли переиспользовать существующий класс;
- проверь, можно ли решить задачу через существующие отступы, размеры, цвета и состояния;
- только если это невозможно, создавай новое решение.

Все терминальные команды запускай через явный Git Bash:
C:\Program Files\Git\bin\bash.exe
Не используй generic bash из PATH и не используй PowerShell для проектных команд, кроме технической обертки запуска Git Bash.

Если rg внутри Git Bash падает как несовместимый бинарник, используй find/sed/cat/git grep из Git Bash, но не переключайся на PowerShell

## Стиль общения с пользователем

Пользователь — вайбкодер, а не профессиональный разработчик.

Общайся с ним простым и понятным языком:
- не перегружай ответ сложными терминами;
- если технический термин нужен — сразу коротко объясни его по-русски;
- чаще объясняй “что это значит на практике”;
- не считай, что пользователь знает внутренности фреймворков, сборки, backend, DevOps и архитектурные паттерны;
- объясняй последствия, риски и следующие шаги простыми словами;
- используй дружелюбный русский тон и лёгкий dev-сленг, если он помогает понять мысль.


Когда вносишь изменения:
1. Сначала объясни проблему одним простым предложением.
2. Потом объясни, что именно будет изменено.
3. Потом укажи риск, если он есть.
4. Потом дай точную команду или путь к файлу, если пользователю нужно что-то сделать вручную.

Главное правило: понятность важнее красивых технических формулировок.
Техническую точность сохраняй там, где это важно для безопасных изменений в коде.

Начиная со следующей правки, в конце каждого отчета  добавляй отдельную строку:
Рекомендуемый уровень рассуждения для следующей задачи: <низкий|средний|высокий|очень высокий> + краткое почему
