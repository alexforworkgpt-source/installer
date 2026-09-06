from pathlib import Path
import tempfile
import unittest

from scripts.release_bundle_publication import create_pinned_cabinet_dockerfile


class CabinetNodeBuilderContractTests(unittest.TestCase):
    def test_node24_cabinet_build_pins_both_images(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "Dockerfile"
            output = root / "Dockerfile.pinned"
            source.write_text(
                "FROM node:24-alpine AS builder\nWORKDIR /app\nFROM nginx:alpine\n",
                encoding="utf-8",
            )
            node_image = f"node@sha256:{'1' * 64}"
            nginx_image = f"nginx@sha256:{'2' * 64}"

            create_pinned_cabinet_dockerfile(source, output, node_image, nginx_image)

            self.assertEqual(
                output.read_text(encoding="utf-8"),
                f"FROM {node_image} AS builder\nWORKDIR /app\nFROM {nginx_image}\n",
            )

    def test_unsupported_or_ambiguous_stages_do_not_create_an_artifact(self) -> None:
        cases = (
            "FROM node:22-alpine AS builder\nFROM nginx:alpine\n",
            "FROM node:24-alpine AS builder\nFROM node:20-alpine AS builder\nFROM nginx:alpine\n",
            "FROM node:24-alpine AS builder\nFROM nginx:alpine\nFROM alpine:latest\n",
            "# FROM node:24-alpine AS builder\nFROM nginx:alpine\n",
            "FROM node:24-alpine AS builder\nFROM nginx:alpine-extra\n",
        )
        for content in cases:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temp_dir:
                root = Path(temp_dir)
                source = root / "Dockerfile"
                output = root / "Dockerfile.pinned"
                source.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(ValueError, "base image contract changed"):
                    create_pinned_cabinet_dockerfile(
                        source, output, f"node@sha256:{'1' * 64}", f"nginx@sha256:{'2' * 64}"
                    )
                self.assertFalse(output.exists())

    def test_image_pinning_preserves_comments(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "Dockerfile"
            output = root / "Dockerfile.pinned"
            comment = "# Supported: FROM node:24-alpine AS builder\n"
            source.write_text(
                comment + "FROM node:24-alpine AS builder\nFROM nginx:alpine\n",
                encoding="utf-8",
            )
            create_pinned_cabinet_dockerfile(
                source, output, f"node@sha256:{'1' * 64}", f"nginx@sha256:{'2' * 64}"
            )
            self.assertTrue(output.read_text(encoding="utf-8").startswith(comment))
