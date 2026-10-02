"""Verify project and Bundle tag roles without changing runtime Bundle identities."""

from pathlib import Path
import re
import subprocess


VERSION = r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}(?:\.[0-9]+)?"


def git_bytes(workspace: Path, *arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(workspace), *arguments],
            check=True, capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("unable to verify publication Git identity") from error


def git_value(workspace: Path, *arguments: str) -> str:
    return git_bytes(workspace, *arguments).decode("utf-8").strip()


def validate_tag_roles(installer_tag: str, bundle_tag: str | None, release: str | None) -> None:
    if not re.fullmatch(rf"installer-v{VERSION}", installer_tag):
        raise ValueError("Installer source tag must use installer-vYYYY.MM.DD[.N]")
    if bundle_tag is not None:
        if not re.fullmatch(rf"bundle-v{VERSION}", bundle_tag) or bundle_tag != f"bundle-v{release}":
            raise ValueError("Bundle tag must match bundle-v<release>")


def verify_source_tags(
    workspace: Path, *, installer_tag: str, installer_sha: str,
    bundle_tag: str | None = None, release: str | None = None,
) -> dict[str, str]:
    validate_tag_roles(installer_tag, bundle_tag, release)
    if not re.fullmatch(r"[0-9a-f]{40}", installer_sha):
        raise ValueError("Installer SHA must be an exact commit")
    if git_value(workspace, "rev-parse", "HEAD^{commit}") != installer_sha:
        raise ValueError("checkout does not match Installer SHA")
    if git_value(workspace, "rev-parse", "--verify", f"refs/tags/{installer_tag}^{{commit}}") != installer_sha:
        raise ValueError("Installer tag does not match Installer SHA")
    if bundle_tag is not None:
        if git_value(workspace, "rev-parse", "--verify", f"refs/tags/{bundle_tag}^{{commit}}") != installer_sha:
            raise ValueError("Bundle tag does not match Installer SHA")
    return {
        "installer_sha": installer_sha,
        "installer_tree_sha": git_value(workspace, "rev-parse", f"{installer_sha}^{{tree}}"),
    }
