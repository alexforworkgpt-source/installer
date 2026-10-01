"""Resolve runtime image digests on the same platform used by the lifecycle gate."""

import json
import re
import subprocess


def verify_runtime_images(postgres: str, redis: str) -> None:
    for image in (postgres, redis):
        if not re.fullmatch(r"[^@\s]+@sha256:[0-9a-f]{64}", image):
            raise ValueError("runtime image must use an exact sha256 digest")
        try:
            subprocess.run(
                ["docker", "pull", "--platform", "linux/amd64", image],
                check=True, capture_output=True, text=True,
            )
            result = subprocess.run(
                ["docker", "image", "inspect", "--format", "{{json .}}", image],
                check=True, capture_output=True, text=True,
            )
            metadata = json.loads(result.stdout)
        except (OSError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
            raise ValueError("exact runtime image is unavailable for linux/amd64") from error
        digest = image.split("@", 1)[1]
        if (not isinstance(metadata, dict) or metadata.get("Os") != "linux"
                or metadata.get("Architecture") != "amd64"
                or not any(isinstance(ref, str) and ref.endswith("@" + digest)
                           for ref in (metadata.get("RepoDigests") or []))):
            raise ValueError("runtime image digest or platform does not match")
