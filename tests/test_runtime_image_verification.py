import json
import subprocess
import unittest
from unittest import mock


class RuntimeImageVerificationTests(unittest.TestCase):
    def test_exact_digest_and_platform_must_be_available(self) -> None:
        from lib.runtime_image_verification import verify_runtime_images

        image = f"postgres@sha256:{'a' * 64}"
        for metadata, accepted in (
            ({"Os": "linux", "Architecture": "amd64", "RepoDigests": [image]}, True),
            ({"Os": "linux", "Architecture": "arm64", "RepoDigests": [image]}, False),
            ({"Os": "linux", "Architecture": "amd64", "RepoDigests": [f"postgres@sha256:{'b' * 64}"]}, False),
        ):
            responses = [subprocess.CompletedProcess([], 0, ""),
                         subprocess.CompletedProcess([], 0, json.dumps(metadata))] * 2
            with mock.patch("subprocess.run", side_effect=responses) as docker:
                if accepted:
                    verify_runtime_images(image, image)
                    self.assertIn("linux/amd64", docker.call_args_list[0].args[0])
                else:
                    with self.assertRaises(ValueError):
                        verify_runtime_images(image, image)
        with mock.patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, ["docker"])):
            with self.assertRaisesRegex(ValueError, "unavailable"):
                verify_runtime_images(image, image)
