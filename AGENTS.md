# Installer Repository

- Never read, print, stage or publish `server.env` or `env.txt`.
- Preserve exact upstream repository URLs, source SHA, image digests,
  checksums, provenance and shipped runtime identifiers.
- Existing tags and Release assets are immutable. Publish changed assets only
  from a new tag after the full gate in `RUNBOOK.md`.
- Keep `README.md`, `INSTALL.md`, `MIGRATION.md`, `RUNBOOK.md` and the Release
  Bundle contract usable when this repository is opened independently.
