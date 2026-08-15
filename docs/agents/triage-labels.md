# Triage Labels

Use these exact label strings in local work-item metadata:

| Role | Label |
| --- | --- |
| Needs triage | `needs-triage` |
| Needs information | `needs-info` |
| Ready for agent | `ready-for-agent` |
| Ready for human | `ready-for-human` |
| Will not fix | `wontfix` |
| Completed | `done` |

## Rules

- The first five labels are the canonical triage states.
- `done` is an additional terminal state for work that has been implemented and verified.
- A work item must have only one state label at a time.
- Replace its previous state with `done` only after the acceptance criteria and required checks pass.
- Do not use `done` for rejected work; use `wontfix`.
