import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.release_bundle_publication import create_deterministic_cabinet_archive, create_release_manifest
from test_lifecycle_evidence import PROTECTED, record as lifecycle_record


def candidate(root):
    from lib.release_bundle import load_release_bundle, release_bundle_identity

    assets = root / "assets"
    assets.mkdir()
    dist = root / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("Public fixture")
    digest = create_deterministic_cabinet_archive(dist, assets / "cabinet-dist.tar.gz")
    (assets / "cabinet-dist.tar.gz.sha256").write_text(f"{digest}  cabinet-dist.tar.gz\n")
    (assets / "installer-2026.10.02.tar.gz").write_bytes(b"fictional Installer snapshot")
    installer_digest = hashlib.sha256(b"fictional Installer snapshot").hexdigest()
    (assets / "installer-2026.10.02.tar.gz.sha256").write_text(
        f"{installer_digest}  installer-2026.10.02.tar.gz\n")
    create_release_manifest(
        output_path=assets / "release.json", release="2026.10.02",
        installer_repository="OWNER/installer", installer_tag="installer-v2026.10.01",
        bundle_tag="bundle-v2026.10.02", bot_repository=PROTECTED["bot_repository"],
        bot_sha=PROTECTED["bot_sha"], cabinet_repository="https://github.com/OWNER/custom-cabinet.git",
        cabinet_sha="c" * 40, artifact_sha256=digest,
        postgres_image=PROTECTED["postgres_image"], redis_image=PROTECTED["redis_image"],
        migration_policy="rollback-compatible",
    )
    provenance = {"cabinet_repository": "https://github.com/OWNER/custom-cabinet.git",
                  "cabinet_sha": "c" * 40, "node_builder_image": f"node@sha256:{'1' * 64}",
                  "nginx_runtime_image": f"nginx@sha256:{'2' * 64}"}
    (assets / "release-provenance.json").write_text(json.dumps(provenance))
    source = {"installer_sha": "a" * 40, "installer_tree_sha": "b" * 40,
              "archive_sha256": installer_digest}
    gates = {name: {"result": "PASS", "evidence_url": "https://github.com/OWNER/installer/actions/runs/123"}
             for name in ("cabinet_source", "compatibility", "smoke")}
    gates["transition"] = {"result": "NOT_REQUIRED", "evidence_url": "https://github.com/OWNER/installer/actions/runs/123"}
    bundle = load_release_bundle(assets / "release.json", 1)
    previous = json.loads((assets / "release.json").read_text())
    previous["release"] = "2026.10.01"
    previous["cabinet"]["artifact_url"] = previous["cabinet"]["artifact_url"].replace("bundle-v2026.10.02", "v2026.10.01")
    previous_path = root / "previous.json"
    previous_path.write_text(json.dumps(previous))
    proof = {
        "schema_version": 1, "kind": "bundle-promotion", "result": "PASS", "owner_approved": True,
        "repository": "OWNER/installer", "bundle_tag": "bundle-v2026.10.02", "release_id": 12,
        "installer_tag": "installer-v2026.10.01", "installer": source,
        "cabinet_tag": "cabinet-v2026.10.02", "protected": dict(PROTECTED),
        "bundle_identity": release_bundle_identity(bundle),
        "assets": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in assets.iterdir()},
        "publication": {"workflow_sha": source["installer_sha"], "run_id": 123, "run_attempt": 1},
        "previous": {"manifest_url": "https://github.com/OWNER/installer/releases/download/v2026.10.01/release.json",
                     "manifest_sha256": hashlib.sha256(previous_path.read_bytes()).hexdigest(),
                     "bundle_identity": release_bundle_identity(load_release_bundle(previous_path, 1))},
        "gates": gates, "limitations": [{"id": "classic-auto-purchase", "status": "OPEN",
                   "summary": "Known backend defect remains open", "accepted": True}],
        "lifecycle": {"commit": "e" * 40, "path": "releases/evidence/lifecycle.json"},
        "make_latest": True, "log_path": "releases/evidence/bundle.log",
        "log_sha256": hashlib.sha256(b"fictional redacted smoke log").hexdigest(),
    }
    lifecycle = lifecycle_record()
    lifecycle["installer"] = source
    return assets, source, proof, previous_path, lifecycle


class BundlePromotionTests(unittest.TestCase):
    def test_provenance_preserves_valid_tagged_and_fully_qualified_digest_references(self):
        from lib.bundle_promotion_evidence import file_digest, verify_candidate_evidence

        with tempfile.TemporaryDirectory() as directory:
            assets, source, proof, previous, _ = candidate(Path(directory))
            path = assets / "release-provenance.json"
            provenance = json.loads(path.read_text())
            provenance["node_builder_image"] = f"node:24-alpine@sha256:{'1' * 64}"
            provenance["nginx_runtime_image"] = f"docker.io/library/nginx@sha256:{'2' * 64}"
            path.write_text(json.dumps(provenance))
            proof["assets"][path.name] = file_digest(path)
            verify_candidate_evidence(proof, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                      "bundle-v2026.10.02", source["installer_sha"], previous, True)

    def test_changed_bot_requires_real_previous_to_candidate_transition_gate(self):
        from lib.bundle_promotion_evidence import verify_candidate_evidence
        from lib.release_bundle import load_release_bundle, release_bundle_identity

        with tempfile.TemporaryDirectory() as directory:
            assets, source, proof, previous, _ = candidate(Path(directory))
            value = json.loads(previous.read_text())
            value["bot"]["sha"] = "f" * 40
            previous.write_text(json.dumps(value))
            proof["previous"]["manifest_sha256"] = hashlib.sha256(previous.read_bytes()).hexdigest()
            proof["previous"]["bundle_identity"] = release_bundle_identity(load_release_bundle(previous, 1))
            with self.assertRaisesRegex(ValueError, "transition"):
                verify_candidate_evidence(proof, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                          "bundle-v2026.10.02", source["installer_sha"], previous, True)
            proof["gates"]["transition"]["result"] = "PASS"
            verify_candidate_evidence(proof, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                      "bundle-v2026.10.02", source["installer_sha"], previous, True)
            proof["previous"]["manifest_sha256"] = "a" * 64
            with self.assertRaisesRegex(ValueError, "previous"):
                verify_candidate_evidence(proof, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                          "bundle-v2026.10.02", source["installer_sha"], previous, True)

    def test_failed_missing_unapproved_or_foreign_source_record_blocks(self):
        from lib.bundle_promotion_evidence import verify_candidate_evidence

        with tempfile.TemporaryDirectory() as directory:
            assets, source, proof, previous, _ = candidate(Path(directory))
            for key, value in (("result", "BLOCKED"), ("schema_version", True),
                               ("owner_approved", False), ("repository", "OWNER/other"),
                               ("installer", {}), ("publication", {}), ("bundle_tag", "bundle-v2026.10.03"),
                               ("bundle_identity", "f" * 64), ("protected", {}), ("gates", {}),
                               ("limitations", []), ("make_latest", False), ("cabinet_tag", None),
                               ("assets", {}), ("lifecycle", {"commit": None, "path": "fixture.json"})):
                changed = copy.deepcopy(proof)
                changed[key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    verify_candidate_evidence(changed, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                              "bundle-v2026.10.02", source["installer_sha"], previous, True)

    def test_candidate_evidence_binds_all_assets_not_just_manifest_or_checksum_pair(self):
        from lib.bundle_promotion_evidence import verify_candidate_evidence

        with tempfile.TemporaryDirectory() as directory:
            assets, source, proof, previous, _ = candidate(Path(directory))
            verify_candidate_evidence(proof, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                      "bundle-v2026.10.02", source["installer_sha"], previous, True)
            (assets / "cabinet-dist.tar.gz").write_bytes(b"changed artifact")
            (assets / "cabinet-dist.tar.gz.sha256").write_text("changed matching checksum")
            with self.assertRaisesRegex(ValueError, "asset"):
                verify_candidate_evidence(proof, assets, source, "OWNER/installer", "installer-v2026.10.01",
                                          "bundle-v2026.10.02", source["installer_sha"], previous, True)
