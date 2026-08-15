from __future__ import annotations

from pathlib import Path
import re
import subprocess
import unittest
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_BOT_URL = (
    "https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git"
)
UPSTREAM_CABINET_URL = "https://github.com/BEDOLAGA-DEV/bedolaga-cabinet.git"
ALLOWED_TECHNICAL_FRAGMENTS_BY_FILE = {
    ".github/workflows/publish-release-bundle.yml": (
        UPSTREAM_BOT_URL,
        UPSTREAM_CABINET_URL,
    ),
    "README.md": ("/opt/bedolaga-installer/current",),
    "INSTALL.md": ("/opt/bedolaga-installer",),
    "MIGRATION.md": (
        "/root/bedolaga-migration-YYYYMMDD-HHMMSS.tar.gz",
        "/root/bedolaga-migration-YYYYMMDD-HHMMSS.tar.gz.sha256",
        "/root/bedolaga-migration-*",
    ),
    "RUNBOOK.md": (
        "/opt/bedolaga-installer/current/",
        "bedolaga-<basename>-<hash PROJECT_ROOT>",
    ),
    "docs/technical-attribution.md": (
        UPSTREAM_BOT_URL,
        UPSTREAM_CABINET_URL,
        "`/opt/bedolaga-installer`, Compose names beginning with `bedolaga-`",
        "`bedolaga-migration-`",
        "`bedolaga-file-backup`",
    ),
}


class PublicBrandingTests(unittest.TestCase):
    def public_files(self) -> list[Path]:
        files = [
            ROOT / "README.md",
            ROOT / "INSTALL.md",
            ROOT / "MIGRATION.md",
            ROOT / "RUNBOOK.md",
        ]
        files.extend((ROOT / "docs").rglob("*.md"))
        files.extend((ROOT / ".github" / "workflows").glob("*.yml"))
        return sorted(files)

    def test_old_brand_is_absent_from_public_text_outside_allowlist(self) -> None:
        violations = []
        for path in self.public_files():
            text = path.read_text(encoding="utf-8")
            relative_path = path.relative_to(ROOT).as_posix()
            for fragment in ALLOWED_TECHNICAL_FRAGMENTS_BY_FILE.get(
                relative_path, ()
            ):
                text = text.replace(fragment, "")
            if re.search(r"bedolaga", text, flags=re.IGNORECASE):
                violations.append(relative_path)
        self.assertEqual(violations, [])

    def test_old_brand_is_absent_from_publishable_paths(self) -> None:
        violations = []
        for path in ROOT.rglob("*"):
            if ".git" in path.parts or ".scratch" in path.parts:
                continue
            if "bedolaga" in path.name.lower():
                violations.append(path.relative_to(ROOT).as_posix())
        self.assertEqual(violations, [])

    def test_release_metadata_is_neutral(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "publish-release-bundle.yml"
        ).read_text(encoding="utf-8")
        self.assertIn('--title "Installer ${RELEASE_NAME}"', workflow)
        self.assertIn('--notes "Immutable Release Bundle ${RELEASE_NAME}"', workflow)
        self.assertIn("cabinet_repository: $cabinet_repository", workflow)
        self.assertIn("parts.username is not None", workflow)
        self.assertIn('test "${LIFECYCLE_SHA}" = "$(git rev-parse HEAD)"', workflow)

    def test_exact_upstream_attribution_is_preserved(self) -> None:
        expected = (UPSTREAM_BOT_URL, UPSTREAM_CABINET_URL)
        production_files = (
            ROOT / ".github" / "workflows" / "publish-release-bundle.yml",
            ROOT / "lib" / "common.sh",
            ROOT / "docs" / "technical-attribution.md",
        )
        combined = "\n".join(
            path.read_text(encoding="utf-8") for path in production_files
        )
        for url in expected:
            self.assertIn(url, combined)

    def test_scratch_history_is_excluded_from_release_archives(self) -> None:
        result = subprocess.run(
            [
                "git",
                "check-attr",
                "export-ignore",
                "--",
                ".scratch/installer-architecture/prd.md",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.stdout.strip(),
            ".scratch/installer-architecture/prd.md: export-ignore: set",
        )

    def test_publishable_markdown_links_resolve(self) -> None:
        missing = []
        for path in [file for file in self.public_files() if file.suffix == ".md"]:
            text = path.read_text(encoding="utf-8")
            for target in re.findall(r"!?\[[^\]]*\]\(([^)]+)\)", text):
                clean_target = unquote(target.split("#", 1)[0]).strip()
                if not clean_target or clean_target.startswith(
                    ("http://", "https://", "mailto:")
                ):
                    continue
                resolved = (path.parent / clean_target).resolve()
                if not resolved.exists():
                    missing.append(
                        f"{path.relative_to(ROOT).as_posix()} -> {clean_target}"
                    )
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
