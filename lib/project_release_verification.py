"""Project identity guard for future stable Bundle promotion; no remote mutation."""

from pathlib import Path
import re

from lib.github_release_publication import GitHubReleases
from lib.publication_identity import VERSION, validate_tag_roles
from lib.release_bundle import load_release_bundle, resolve_git_ref


def verify_project_releases(
    manifest: Path, installer_repository: str, installer_tag: str,
    installer_sha: str, cabinet_tag: str, token: str,
) -> None:
    validate_tag_roles(installer_tag, None, None)
    if (not re.fullmatch(r"[0-9a-f]{40}", installer_sha)
            or not re.fullmatch(rf"cabinet-v{VERSION}", cabinet_tag)):
        raise ValueError("exact project SHA and Cabinet source tag are required")
    bundle = load_release_bundle(manifest, 1)
    match = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git",
                         bundle.cabinet.repository or "")
    if not match:
        raise ValueError("stable promotion requires an explicit GitHub Cabinet source repository")
    projects = (
        (installer_repository, f"https://github.com/{installer_repository}.git", installer_tag, installer_sha),
        (match[1], bundle.cabinet.repository, cabinet_tag, bundle.cabinet.source_sha),
    )
    for repository, source_url, tag, expected_sha in projects:
        release = GitHubReleases(repository, token).find(tag)
        if (not isinstance(release, dict) or release.get("tag_name") != tag
                or release.get("draft") is not False or release.get("prerelease") is not False):
            raise ValueError("selected project must have a stable Release on its exact source tag")
        if resolve_git_ref(source_url, f"refs/tags/{tag}").sha != expected_sha:
            raise ValueError("stable project Release tag does not match selected source SHA")
    # Historic stable Cabinet Releases need no new metadata asset. Compatibility
    # with a changed Bot belongs in new Bundle evidence, not in the old Release.
