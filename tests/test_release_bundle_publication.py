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

    def test_generated_manifest_uses_installer_release_assets_and_production_parser(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "release.json"

            create_release_manifest(
                output_path=output,
                release="2026.08.0",
                installer_repository="BEDOLAGA-DEV/bedolaga-installer",
                installer_tag="v2026.08.0",
                bot_repository="https://github.com/BEDOLAGA-DEV/remnawave-bedolaga-telegram-bot.git",
                bot_sha="b" * 40,
                cabinet_sha="c" * 40,
                artifact_sha256="a" * 64,
                postgres_image=f"postgres@sha256:{'d' * 64}",
                redis_image=f"redis@sha256:{'e' * 64}",
                migration_policy="rollback-compatible",
            )

            manifest = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(
                manifest["cabinet"]["artifact_url"],
                "https://github.com/BEDOLAGA-DEV/bedolaga-installer/releases/download/v2026.08.0/cabinet-dist.tar.gz",
            )
            bundle = load_release_bundle(output, supported_configuration_schema=1)
            self.assertEqual(bundle.release, "2026.08.0")
            self.assertEqual(bundle.bot.sha, "b" * 40)


if __name__ == "__main__":
    unittest.main()
