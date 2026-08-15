# Domain Documentation

This repository uses a single-context domain layout.

## Locations

- `CONTEXT.md` at the repository root contains the shared domain glossary.
- `docs/adr/` contains architectural decision records.

## Consumer Rules

- Read `CONTEXT.md` before changing domain behavior or terminology.
- Use its canonical terms in code, documentation, issues, and user-facing text.
- Read relevant ADRs before changing architecture in their area.
- Do not reopen an accepted architectural decision without identifying the new information that justifies reconsideration.
- Keep implementation details out of `CONTEXT.md`; it is a domain glossary, not a specification.
- Create `CONTEXT.md` only when the first domain term is ready to document.
- Create `docs/adr/` only when the first qualifying architectural decision must be recorded.
