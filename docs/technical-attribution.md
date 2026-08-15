# Technical Attribution

Installer uses external projects while keeping its own public product name
neutral.

## Upstream Sources

- Upstream Bot: <https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git>
- Upstream Cabinet: <https://github.com/BEDOLAGA-DEV/bedolaga-cabinet.git>
- Remnawave: <https://github.com/remnawave/backend>

## Maintained Source

- Custom Cabinet: <https://github.com/alexforworkgpt-source/custom-cabinet.git>

Installer uses Custom Cabinet as its default Cabinet source. `UPSTREAM.md` and
the unchanged license in that repository record its exact Upstream Cabinet
origin.

Release Bundle manifests and provenance preserve exact repository identities,
Git SHA, Docker image digests and artifact checksums. These strings are
technical attribution and must not be replaced with neutral placeholders.

## Compatibility Identifiers

Existing installations and backups use legacy persisted identifiers including
`/opt/bedolaga-installer`, Compose names beginning with `bedolaga-`, migration
archive names beginning with `bedolaga-migration-`, ownership markers and the
`bedolaga-file-backup` artifact type. They remain supported so upgrades,
rollback and recovery continue to work. They are not public product names.

The upstream projects retain their own licenses and copyright notices. Installer
does not claim ownership of upstream source code and does not remove or rewrite
those notices.
