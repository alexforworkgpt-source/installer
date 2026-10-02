import io
import json
import contextlib
import os
from pathlib import Path
import tempfile
from unittest import mock
import unittest

from test_bundle_promotion import candidate
from test_publication_identity import git, repository
from scripts.promote_release_bundle import main as promotion_cli


class BundlePromotionControlTests(unittest.TestCase):
    def test_pass_json_without_durable_reviewed_log_never_reaches_github(self):
        from lib.bundle_promotion_control import promote_bundle

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "repo"
            workspace.mkdir()
            sha = repository(workspace)
            git(workspace, "tag", "installer-v2026.10.01")
            git(workspace, "tag", "bundle-v2026.10.02")
            _, _, proof, _, _ = candidate(root)
            evidence = workspace / "releases/evidence/bundle.json"
            evidence.parent.mkdir(parents=True)
            evidence.write_text(json.dumps(proof))
            git(workspace, "add", "releases/evidence")
            git(workspace, "commit", "--quiet", "-m", "Incomplete proof fixture")
            reviewed = git(workspace, "rev-parse", "HEAD")
            git(workspace, "update-ref", "refs/remotes/origin/main", reviewed)
            git(workspace, "checkout", "--quiet", "--detach", sha)
            with mock.patch("urllib.request.urlopen") as network:
                for path in ("releases/evidence/bundle.json", "releases/evidence/../../server.prod.env"):
                    with self.assertRaises(ValueError):
                        promote_bundle(workspace, root / "download", reviewed, path, "main", "OWNER/installer",
                            "installer-v2026.10.01", sha, "bundle-v2026.10.02", sha, True, "fictional-token")
                network.assert_not_called()

    def test_reviewed_exact_public_candidate_promotes_and_retry_has_no_write(self):
        from lib.bundle_promotion_control import promote_bundle
        from lib.integration_source import create_source_archive

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / "repo"
            workspace.mkdir()
            sha = repository(workspace)
            git(workspace, "tag", "installer-v2026.10.01")
            git(workspace, "tag", "bundle-v2026.10.02")
            assets, _, proof, previous, lifecycle = candidate(root)
            archive = root / "source.tar.gz"
            source = create_source_archive(workspace, archive, expected_sha=sha)
            installer = assets / "installer-2026.10.02.tar.gz"
            installer.write_bytes(archive.read_bytes())
            (assets / "installer-2026.10.02.tar.gz.sha256").write_text(
                f"{source['archive_sha256']}  installer-2026.10.02.tar.gz\n")
            proof["installer"] = source
            proof["assets"][installer.name] = source["archive_sha256"]
            from lib.bundle_promotion_evidence import file_digest
            proof["assets"][installer.name + ".sha256"] = file_digest(assets / (installer.name + ".sha256"))
            proof["publication"]["workflow_sha"] = sha
            lifecycle["installer"] = source
            evidence = workspace / "releases/evidence"
            evidence.mkdir(parents=True)
            (evidence / "lifecycle.json").write_text(json.dumps(lifecycle))
            (evidence / "lifecycle.log").write_bytes(b"fictional lifecycle log")
            git(workspace, "add", "releases/evidence")
            git(workspace, "commit", "--quiet", "-m", "Reviewed lifecycle fixture")
            proof["lifecycle"]["commit"] = git(workspace, "rev-parse", "HEAD")
            (evidence / "bundle.json").write_text(json.dumps(proof))
            (evidence / "bundle.log").write_bytes(b"fictional redacted smoke log")
            git(workspace, "add", "releases/evidence")
            git(workspace, "commit", "--quiet", "-m", "Reviewed Bundle fixture")
            reviewed = git(workspace, "rev-parse", "HEAD")
            git(workspace, "update-ref", "refs/remotes/origin/main", reviewed)
            git(workspace, "checkout", "--quiet", "--detach", sha)
            downloads = {f"https://github.com/OWNER/installer/releases/download/bundle-v2026.10.02/{p.name}": p.read_bytes()
                         for p in assets.iterdir()}
            downloads[proof["previous"]["manifest_url"]] = previous.read_bytes()
            release = {"id": 12, "tag_name": proof["bundle_tag"], "draft": False, "prerelease": True,
                       "immutable": True, "body": "Candidate\n<!-- publication-run: 123/1 -->",
                       "assets": [{"id": i + 20, "name": p.name, "size": p.stat().st_size,
                                   "state": "uploaded", "digest": f"sha256:{proof['assets'][p.name]}",
                                   "browser_download_url": f"https://github.com/OWNER/installer/releases/download/{proof['bundle_tag']}/{p.name}"}
                                  for i, p in enumerate(assets.iterdir())]}
            calls = []
            run_changes = {}

            def network(request, timeout):
                calls.append((request.full_url, request.get_method()))
                if request.full_url in downloads:
                    self.assertNotIn("Authorization", request.headers)
                    response = io.BytesIO(downloads[request.full_url])
                    response.geturl = lambda: request.full_url
                    return response
                if "/actions/runs/" in request.full_url:
                    value = {"id": 123, "run_attempt": 1, "head_sha": sha, "status": "completed",
                             "conclusion": "success", "path": ".github/workflows/publish-release-bundle.yml",
                             "event": "workflow_dispatch", "repository": {"full_name": "OWNER/installer"}}
                    value.update(run_changes)
                elif request.get_method() == "PATCH":
                    self.assertEqual(json.loads(request.data), {"prerelease": False, "make_latest": "true"})
                    release["prerelease"] = False
                    value = release
                elif request.full_url.endswith("/releases/12"):
                    value = release
                else:
                    value = [release, {"tag_name": "installer-v2026.10.01", "draft": False, "prerelease": False},
                             {"tag_name": "v2026.10.01", "draft": False, "prerelease": False}]
                    if "/custom-cabinet/" in request.full_url:
                        value = [{"tag_name": proof["cabinet_tag"], "draft": False, "prerelease": False}]
                return io.BytesIO(json.dumps(value).encode())

            with mock.patch("urllib.request.urlopen", side_effect=network), mock.patch(
                "lib.bundle_promotion_control.resolve_git_ref", return_value=type("Ref", (), {"sha": sha})()
            ), mock.patch("lib.project_release_verification.resolve_git_ref", side_effect=lambda url, ref:
                type("Ref", (), {"sha": sha if url.endswith("/installer.git") else "c" * 40})()):
                for index, changes in enumerate(({"head_sha": "f" * 40}, {"conclusion": "failure"},
                        {"status": "in_progress"}, {"run_attempt": 2}, {"path": ".github/workflows/unrelated.yml"})):
                    run_changes.update(changes)
                    with self.assertRaisesRegex(ValueError, "publication workflow"):
                        promote_bundle(workspace, root / f"invalid-run-{index}", reviewed,
                            "releases/evidence/bundle.json", "main", "OWNER/installer",
                            "installer-v2026.10.01", sha, "bundle-v2026.10.02", sha, True, "fictional-token")
                    run_changes.clear()
                bad_url = next(url for url in downloads if url.endswith("/cabinet-dist.tar.gz"))
                original = downloads[bad_url]
                downloads[bad_url] = bytes(byte ^ 1 for byte in original)
                with self.assertRaisesRegex(ValueError, "asset"):
                    promote_bundle(workspace, root / "invalid-bytes", reviewed,
                        "releases/evidence/bundle.json", "main", "OWNER/installer",
                        "installer-v2026.10.01", sha, "bundle-v2026.10.02", sha, True, "fictional-token")
                downloads[bad_url] = original
                self.assertFalse(any(method != "GET" for _, method in calls))
                environment = {"RUNNER_TEMP": str(root), "MAKE_LATEST": "true",
                    "PROMOTION_EVIDENCE_SHA": reviewed, "PROMOTION_EVIDENCE_PATH": "releases/evidence/bundle.json",
                    "DEFAULT_BRANCH": "main", "GITHUB_REPOSITORY": "OWNER/installer",
                    "INSTALLER_TAG": "installer-v2026.10.01", "INSTALLER_SHA": sha,
                    "BUNDLE_TAG": "bundle-v2026.10.02", "WORKFLOW_SHA": sha, "GH_TOKEN": "fictional-token"}
                with mock.patch.dict(os.environ, environment), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(promotion_cli(["verify", "--workspace", str(workspace),
                                                   "--output", str(root / "read-only")]), 0)
                    with self.assertRaises(ValueError):
                        promotion_cli(["promote", "--workspace", str(workspace), "--output", str(root)])
                self.assertFalse(any(method != "GET" for _, method in calls))
                for index in range(2):
                    changed = promote_bundle(workspace, root / f"download-{index}", reviewed,
                        "releases/evidence/bundle.json", "main", "OWNER/installer",
                        "installer-v2026.10.01", sha, "bundle-v2026.10.02", sha, True, "fictional-token")
                    self.assertEqual(changed, index == 0)
            self.assertEqual(sum(method == "PATCH" for _, method in calls), 1)
            self.assertFalse(any(method in {"POST", "DELETE"} for _, method in calls))
            self.assertEqual(git(workspace, "status", "--porcelain"), "")
