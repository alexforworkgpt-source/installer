from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from lib.release_bundle import load_release_bundle, verify_cabinet_artifact
from scripts.release_bundle_publication import (
    create_deterministic_cabinet_archive,
    create_pinned_cabinet_dockerfile,
    create_release_manifest,
)


class ReleaseBundlePublicationTests(unittest.TestCase):
    def test_downloaded_archive_and_replaced_checksum_cannot_pass_verification(self) -> None:
        from scripts.release_bundle_publication import verify_downloaded_assets

        with tempfile.TemporaryDirectory() as directory:
            expected, downloaded = Path(directory) / "expected", Path(directory) / "downloaded"
            expected.mkdir()
            downloaded.mkdir()
            names = ("cabinet-dist.tar.gz", "cabinet-dist.tar.gz.sha256", "release.json",
                     "release-provenance.json", "installer-2026.10.01.tar.gz",
                     "installer-2026.10.01.tar.gz.sha256")
            for name in names:
                (expected / name).write_bytes(b"trusted fixture")
                (downloaded / name).write_bytes(b"trusted fixture")
            verify_downloaded_assets(expected, downloaded, "2026.10.01")
            (downloaded / "cabinet-dist.tar.gz").write_bytes(b"different archive")
            (downloaded / "cabinet-dist.tar.gz.sha256").write_bytes(b"different matching checksum")
            with self.assertRaisesRegex(ValueError, "differ"):
                verify_downloaded_assets(expected, downloaded, "2026.10.01")

    def test_new_publication_rejects_swapped_or_mismatched_tag_roles(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for source, bundle in (
                ("bundle-v2026.10.01", "bundle-v2026.10.02"),
                ("installer-v2026.10.01", "installer-v2026.10.01"),
                ("installer-v2026.10.01", "bundle-v2026.10.03"),
            ):
                with self.subTest(source=source, bundle=bundle), self.assertRaises(ValueError):
                    create_release_manifest(
                        output_path=Path(directory) / "release.json", release="2026.10.02",
                        installer_repository="OWNER/installer", installer_tag=source, bundle_tag=bundle,
                        bot_repository="https://github.com/OWNER/bot.git", bot_sha="b" * 40,
                        cabinet_repository="https://github.com/OWNER/custom-cabinet.git", cabinet_sha="c" * 40,
                        artifact_sha256="a" * 64, postgres_image=f"postgres@sha256:{'d' * 64}",
                        redis_image=f"redis@sha256:{'e' * 64}", migration_policy="rollback-compatible",
                    )

    def test_two_bundles_can_use_one_installer_source_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            for release in ("2026.10.01", "2026.10.02"):
                output = Path(temp_dir) / f"{release}.json"
                create_release_manifest(
                    output_path=output,
                    release=release,
                    installer_repository="OWNER/installer",
                    installer_tag="installer-v2026.10.01",
                    bundle_tag=f"bundle-v{release}",
                    bot_repository="https://github.com/OWNER/bot.git",
                    bot_sha="b" * 40,
                    cabinet_repository="https://github.com/OWNER/custom-cabinet.git",
                    cabinet_sha="c" * 40,
                    artifact_sha256="a" * 64,
                    postgres_image=f"postgres@sha256:{'d' * 64}",
                    redis_image=f"redis@sha256:{'e' * 64}",
                    migration_policy="rollback-compatible",
                )
                bundle = load_release_bundle(output, 1)
                self.assertEqual(
                    bundle.cabinet.artifact_url,
                    f"https://github.com/OWNER/installer/releases/download/bundle-v{release}/cabinet-dist.tar.gz",
                )

    def test_publication_cli_runs_outside_repository_root(self) -> None:
        script = (
            Path(__file__).resolve().parents[1]
            / "scripts"
            / "release_bundle_publication.py"
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            result = subprocess.run(
                [sys.executable, str(script), "--help"],
                cwd=temp_dir,
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_release_build_pins_cabinet_base_images(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "Dockerfile"
            output = root / "Dockerfile.pinned"
            source.write_text(
                "FROM node:20-alpine AS builder\nFROM nginx:alpine\n",
                encoding="utf-8",
            )
            node_image = f"node@sha256:{'1' * 64}"
            nginx_image = f"nginx@sha256:{'2' * 64}"

            create_pinned_cabinet_dockerfile(
                source,
                output,
                node_image,
                nginx_image,
            )

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                f"FROM {node_image} AS builder\nFROM {nginx_image}\n",
            )

    def test_release_build_disables_git_bash_path_conversion(self) -> None:
        script = (
            Path(__file__).resolve().parents[1]
            / "scripts"
            / "build-cabinet-release-artifact.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("MSYS2_ARG_CONV_EXCL='VITE_API_URL=' docker build", script)

    def test_cabinet_archive_is_byte_for_byte_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cabinet_dist = root / "dist"
            (cabinet_dist / "assets").mkdir(parents=True)
            (cabinet_dist / "index.html").write_text("fresh cabinet", encoding="utf-8")
            (cabinet_dist / "assets" / "app.js").write_text(
                "console.log('cabinet')", encoding="utf-8"
            )
            first_archive = root / "first.tar.gz"
            second_archive = root / "second.tar.gz"

            first_checksum = create_deterministic_cabinet_archive(
                cabinet_dist, first_archive
            )
            second_checksum = create_deterministic_cabinet_archive(
                cabinet_dist, second_archive
            )

            self.assertEqual(first_archive.read_bytes(), second_archive.read_bytes())
            self.assertEqual(first_checksum, second_checksum)
            verify_cabinet_artifact(first_archive, first_checksum)

    def test_cabinet_archive_rejects_git_bash_path_conversion_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            cabinet_dist = root / "dist"
            (cabinet_dist / "assets").mkdir(parents=True)
            (cabinet_dist / "index.html").write_text("cabinet", encoding="utf-8")
            (cabinet_dist / "assets" / "app.js").write_text(
                'const apiBase = "C:/Program Files/Git/api";',
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "Git Bash path-conversion"):
                create_deterministic_cabinet_archive(
                    cabinet_dist,
                    root / "cabinet-dist.tar.gz",
                )

    def test_generated_manifest_uses_installer_release_assets_and_production_parser(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "release.json"

            create_release_manifest(
                output_path=output,
                release="2026.08.0",
                installer_repository="OWNER/installer",
                installer_tag="v2026.08.0",
                bot_repository="https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git",
                bot_sha="b" * 40,
                cabinet_repository="https://github.com/OWNER/custom-cabinet.git",
                cabinet_sha="c" * 40,
                artifact_sha256="a" * 64,
                postgres_image=f"postgres@sha256:{'d' * 64}",
                redis_image=f"redis@sha256:{'e' * 64}",
                migration_policy="rollback-compatible",
            )

            manifest = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(manifest["schema_version"], 2)
            self.assertEqual(
                manifest["cabinet"]["repository"],
                "https://github.com/OWNER/custom-cabinet.git",
            )
            self.assertEqual(
                manifest["cabinet"]["artifact_url"],
                "https://github.com/OWNER/installer/releases/download/v2026.08.0/cabinet-dist.tar.gz",
            )
            bundle = load_release_bundle(output, supported_configuration_schema=1)
            self.assertEqual(bundle.release, "2026.08.0")
            self.assertEqual(bundle.bot.sha, "b" * 40)
            self.assertEqual(
                bundle.cabinet.repository,
                "https://github.com/OWNER/custom-cabinet.git",
            )


if __name__ == "__main__":
    unittest.main()
