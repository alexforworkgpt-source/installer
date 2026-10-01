import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from scripts.release_bundle_publication import create_release_manifest


class ProjectReleaseVerificationTests(unittest.TestCase):
    def manifest(self, root: Path) -> Path:
        path = root / "release.json"
        create_release_manifest(
            output_path=path, release="2026.10.02", installer_repository="OWNER/installer",
            installer_tag="installer-v2026.10.01", bundle_tag="bundle-v2026.10.02",
            bot_repository="https://github.com/OWNER/bot.git", bot_sha="b" * 40,
            cabinet_repository="https://github.com/OWNER/custom-cabinet.git", cabinet_sha="c" * 40,
            artifact_sha256="a" * 64, postgres_image=f"postgres@sha256:{'d' * 64}",
            redis_image=f"redis@sha256:{'e' * 64}", migration_policy="rollback-compatible",
        )
        return path

    def test_existing_stable_cabinet_release_is_reusable_without_new_metadata_asset(self):
        from lib.project_release_verification import verify_project_releases

        with tempfile.TemporaryDirectory() as directory:
            path = self.manifest(Path(directory))
            for bot_sha in ("b" * 40, "f" * 40):
                manifest = json.loads(path.read_text())
                manifest["bot"]["sha"] = bot_sha
                path.write_text(json.dumps(manifest))
                with mock.patch("lib.project_release_verification.GitHubReleases") as api, mock.patch(
                    "lib.project_release_verification.resolve_git_ref",
                    side_effect=[SimpleNamespace(sha="a" * 40), SimpleNamespace(sha="c" * 40)],
                ) as resolve:
                    api.return_value.find.side_effect = [
                        {"tag_name": "installer-v2026.10.01", "draft": False, "prerelease": False},
                        {"tag_name": "cabinet-v2026.10.01", "draft": False, "prerelease": False},
                    ]
                    verify_project_releases(path, "OWNER/installer", "installer-v2026.10.01",
                                            "a" * 40, "cabinet-v2026.10.01", "fictional-token")
                    self.assertEqual(resolve.call_args_list[1].args, (
                        "https://github.com/OWNER/custom-cabinet.git", "refs/tags/cabinet-v2026.10.01"))

    def test_missing_candidate_wrong_tag_and_unknown_release_state_block(self):
        from lib.project_release_verification import verify_project_releases

        with tempfile.TemporaryDirectory() as directory:
            path = self.manifest(Path(directory))
            for release in (None, {"tag_name": "other", "draft": False, "prerelease": False},
                            {"tag_name": "installer-v2026.10.01", "draft": True, "prerelease": False},
                            {"tag_name": "installer-v2026.10.01", "draft": False, "prerelease": True},
                            {"tag_name": "installer-v2026.10.01"}):
                for selected in (0, 1):
                    stable = {"tag_name": "installer-v2026.10.01", "draft": False, "prerelease": False}
                    invalid = dict(release) if release else None
                    if selected and invalid and invalid["tag_name"] == stable["tag_name"]:
                        invalid["tag_name"] = "cabinet-v2026.10.01"
                    with mock.patch("lib.project_release_verification.GitHubReleases") as api, mock.patch(
                        "lib.project_release_verification.resolve_git_ref", return_value=SimpleNamespace(sha="a" * 40),
                    ):
                        api.return_value.find.side_effect = [invalid] if selected == 0 else [stable, invalid]
                        with self.assertRaisesRegex(ValueError, "stable"):
                            verify_project_releases(path, "OWNER/installer", "installer-v2026.10.01",
                                                    "a" * 40, "cabinet-v2026.10.01", "fictional-token")

    def test_tag_source_mismatch_and_api_error_block(self):
        from lib.project_release_verification import verify_project_releases

        with tempfile.TemporaryDirectory() as directory:
            path = self.manifest(Path(directory))
            for wrong in (0, 1):
                with mock.patch("lib.project_release_verification.GitHubReleases") as api, mock.patch(
                    "lib.project_release_verification.resolve_git_ref",
                    side_effect=[SimpleNamespace(sha="f" * 40 if wrong == 0 else "a" * 40),
                                 SimpleNamespace(sha="f" * 40 if wrong == 1 else "c" * 40)],
                ):
                    api.return_value.find.side_effect = [
                        {"tag_name": "installer-v2026.10.01", "draft": False, "prerelease": False},
                        {"tag_name": "cabinet-v2026.10.01", "draft": False, "prerelease": False},
                    ]
                    with self.assertRaisesRegex(ValueError, "SHA"):
                        verify_project_releases(path, "OWNER/installer", "installer-v2026.10.01",
                                                "a" * 40, "cabinet-v2026.10.01", "fictional-token")
            with mock.patch("lib.project_release_verification.GitHubReleases") as api:
                api.return_value.find.side_effect = ValueError("GitHub API failed: HTTP 403")
                with self.assertRaisesRegex(ValueError, "HTTP 403"):
                    verify_project_releases(path, "OWNER/installer", "installer-v2026.10.01",
                                            "a" * 40, "cabinet-v2026.10.01", "fictional-token")
