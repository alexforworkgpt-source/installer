import contextlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts.publication_control import main, protected_stack
from test_lifecycle_evidence import record
from test_publication_identity import git, repository
from test_release_bundle import valid_manifest


class PublicationControlTests(unittest.TestCase):
    def test_committed_proof_is_reused_only_for_unchanged_protected_stack(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            workspace = temp / "repo"
            workspace.mkdir()
            sha = repository(workspace)
            git(workspace, "tag", "installer-v2026.10.01")
            git(workspace, "tag", "bundle-v2026.10.01")
            source_path, archive = temp / "source.json", temp / "source.tar.gz"
            manifest_path = temp / "release.json"
            manifest = valid_manifest()
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            environment = {"INSTALLER_SHA": sha, "WORKFLOW_SHA": sha,
                           "INSTALLER_TAG": "installer-v2026.10.01",
                           "BUNDLE_TAG": "bundle-v2026.10.01", "RELEASE_NAME": "2026.10.01",
                           "DEFAULT_BRANCH": "main", "LIFECYCLE_EVIDENCE_PATH": "releases/evidence/lifecycle.json"}
            with mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(["source", "--workspace", str(workspace),
                                       "--source", str(source_path), "--archive", str(archive)]), 0)
                evidence = record()
                evidence["installer"] = json.loads(source_path.read_text(encoding="utf-8"))
                evidence["protected"] = protected_stack(manifest_path)
                evidence_dir = workspace / "releases/evidence"
                evidence_dir.mkdir(parents=True)
                (evidence_dir / "lifecycle.json").write_text(json.dumps(evidence), encoding="utf-8")
                (evidence_dir / "lifecycle.log").write_bytes(b"fictional lifecycle log")
                git(workspace, "add", "releases/evidence")
                git(workspace, "commit", "--quiet", "-m", "Reviewed evidence fixture")
                evidence_sha = git(workspace, "rev-parse", "HEAD")
                git(workspace, "update-ref", "refs/remotes/origin/main", evidence_sha)
                git(workspace, "checkout", "--quiet", "--detach", sha)
                with mock.patch.dict(os.environ, {"LIFECYCLE_EVIDENCE_SHA": evidence_sha}):
                    command = ["evidence", "--workspace", str(workspace),
                               "--source", str(source_path), "--manifest", str(manifest_path)]
                    self.assertEqual(main(command), 0)
                    manifest["cabinet"]["source_sha"] = "f" * 40
                    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
                    self.assertEqual(main(command), 0)
                    manifest["bot"]["sha"] = "f" * 40
                    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "protected stack"):
                        main(command)

    def test_stable_bundle_publication_is_blocked_until_promotion_gate_exists(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory) / "receipt.json"
            receipt.write_text(json.dumps({"tag": "bundle-v2026.10.01"}), encoding="utf-8")
            environment = {"BUNDLE_TAG": "bundle-v2026.10.01", "GITHUB_REPOSITORY": "OWNER/installer",
                           "GH_TOKEN": "fictional-token", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"}
            with mock.patch.dict(os.environ, environment), mock.patch("urllib.request.urlopen") as network:
                with self.assertRaisesRegex(ValueError, "separate candidate evidence gate"):
                    main(["publish-draft", "--stable", "--receipt", str(receipt)])
                network.assert_not_called()
