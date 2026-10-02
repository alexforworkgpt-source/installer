from pathlib import Path
import subprocess
import tempfile
import unittest


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True
    ).stdout.strip()


def repository(root: Path) -> str:
    git(root, "init", "--quiet")
    git(root, "config", "user.name", "Publication fixture")
    git(root, "config", "user.email", "fixture@example.test")
    git(root, "config", "commit.gpgsign", "false")
    git(root, "config", "tag.gpgsign", "false")
    git(root, "config", "core.hooksPath", str(root / "no-hooks"))
    (root / "source.txt").write_text("public fixture", encoding="utf-8")
    git(root, "add", "source.txt")
    git(root, "commit", "--quiet", "-m", "Source fixture")
    return git(root, "rev-parse", "HEAD")


class PublicationIdentityTests(unittest.TestCase):
    def test_annotated_source_and_two_bundle_tags_share_one_commit(self) -> None:
        from lib.publication_identity import verify_source_tags

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sha = repository(root)
            git(root, "tag", "-a", "installer-v2026.10.01", "-m", "Source tag")
            for release in ("2026.10.01", "2026.10.02"):
                git(root, "tag", f"bundle-v{release}")
                identity = verify_source_tags(
                    root, installer_tag="installer-v2026.10.01", installer_sha=sha,
                    bundle_tag=f"bundle-v{release}", release=release,
                )
                self.assertEqual(identity["installer_sha"], sha)
                self.assertEqual(identity["installer_tree_sha"], git(root, "rev-parse", "HEAD^{tree}"))
            for source, bundle, release in (
                ("bundle-v2026.10.01", "bundle-v2026.10.02", "2026.10.02"),
                ("installer-v2026.10.01", "installer-v2026.10.01", "2026.10.01"),
                ("installer-v2026.10.01", "bundle-v2026.10.02", "2026.10.01"),
            ):
                with self.assertRaises(ValueError):
                    verify_source_tags(root, installer_tag=source, installer_sha=sha,
                                       bundle_tag=bundle, release=release)

    def test_bundle_tag_must_reference_selected_installer_commit(self) -> None:
        from lib.publication_identity import verify_source_tags

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sha = repository(root)
            git(root, "tag", "installer-v2026.10.01")
            git(root, "commit", "--quiet", "--allow-empty", "-m", "Other source")
            git(root, "tag", "bundle-v2026.10.02")
            git(root, "checkout", "--quiet", "--detach", sha)
            with self.assertRaisesRegex(ValueError, "Bundle tag"):
                verify_source_tags(
                    root, installer_tag="installer-v2026.10.01", installer_sha=sha,
                    bundle_tag="bundle-v2026.10.02", release="2026.10.02",
                )
