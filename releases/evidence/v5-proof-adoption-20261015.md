# Adoption of existing Bot v5 / PG15 proofs — 2026-10-15

Status: reviewed/adopted for the owner-authorized 2026.10.15.1 release package.
No lifecycle, transition, payment or backend acceptance suite was rerun.

Installer 75c49bec9c2a764e123fc0ef675f8c45fc22a1ab, tree 6606a783904f81959441b846e757004530728908, archive
eff17b515f9714dcefee88652d884e64598300941f3b9519d77bcf9e2e75752d; unchanged Bot 5bda3c56f0afd9f4813e9c6fa48934948b05ebae.
All protected fields are explicit in [lifecycle-v5-pg15-75c49be-20261015.json](lifecycle-v5-pg15-75c49be-20261015.json).
Ubuntu24.04/Linux-amd64, PG15/Redis7 digests and contract/schema identities match.
The public archive will be independently reconstructed and workflow-verified.

The native ten-stage same-version lifecycle on14 October completed, including
injected rollback and uninstall. Original SSH transport disconnected; final log
and independent terminal receipt were recovered. No original SSH exit0 is claimed.
The separate native Bot4.15/schema0127 → Bot5/schema0131 transition exited0,
verified fixture data through injected rollback and committed update. Transition
cleanup was SKIPPED_OWNER_REQUEST; its image integrity probe was not run at stop.
The lifecycle's separate raw-source image integrity and cleanup retain their own scope.

Preserved excerpts: [lifecycle](bot-v5-pg15-lifecycle-20261014.log) and
[transition](bot-v5-pg15-transition-20261014.log), committed at f670135e8587e4f08aa88fbb6db70b102e3e998d.
Their historical NOT_ACCEPTED lines record the original collection state, before
this adoption. Logs are sanitized excerpts, not complete private native logs.
Log checksum, all ten/four ordered stage markers, terminal success and exact
source/protected tuple were reviewed against the existing canonical receipts.

This evidence does not establish new Cabinet public bytes, installation of the
new Bundle, full runtime compatibility or production readiness. The new Bundle
still requires public verification and targeted disposable installation/smoke.
Existing OPEN/BLOCKED facts remain scoped history; the owner waived current
physical Telegram/device coverage as SKIPPED_OWNER_ACCEPTED. Upstream Bot is the
working baseline and is not changed or reaccepted by this release task.
