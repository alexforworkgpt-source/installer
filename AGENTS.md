# Installer Repository

- Preserve exact upstream repository URLs, source SHA, image digests,
  checksums, provenance and shipped runtime identifiers.
- Existing tags and Release assets are immutable. Publish changed assets only
  from a new tag after the full gate in `RUNBOOK.md`.
- Keep `README.md`, `INSTALL.md`, `MIGRATION.md`, `RUNBOOK.md` and the Release
  Bundle contract usable when this repository is opened independently.
- The owner explicitly accepts compromise or disclosure of the isolated test
  integration VPS and credentials stored in local `server.env`; do not treat it
  as a production incident, require credential rotation, or block integration
  work solely for that reason. This exception does not apply to production
  hosts or credentials and does not permit committing, publishing, or repeating
  secret values. Always obey the `SERVER_IS_DISPOSABLE` safety lock before
  modifying or cleaning the test VPS.
