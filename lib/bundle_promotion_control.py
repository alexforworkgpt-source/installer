"""Verify durable evidence and public bytes before a metadata-only Bundle promotion."""

from pathlib import Path

from lib.bundle_promotion_evidence import asset_names, previous_tag, validate_record, verify_candidate_evidence
from lib.github_release_publication import GitHubReleases
from lib.integration_source import create_source_archive
from lib.lifecycle_evidence import read_reviewed_evidence, verify_lifecycle_evidence
from lib.project_release_verification import verify_project_releases
from lib.public_bundle_download import download_public_file
from lib.publication_identity import verify_source_tags
from lib.publication_stack import protected_stack
from lib.release_bundle import resolve_git_ref


def verify_release(release: dict, record: dict) -> None:
    marker = f"<!-- publication-run: {record['publication']['run_id']}/{record['publication']['run_attempt']} -->"
    if (not isinstance(release, dict) or release.get("id") != record["release_id"]
            or release.get("tag_name") != record["bundle_tag"] or release.get("draft") is not False
            or release.get("immutable") is not True or type(release.get("prerelease")) is not bool
            or not isinstance(release.get("body"), str) or not release["body"].endswith(marker)):
        raise ValueError("promotion requires the exact published immutable candidate and publication run")
    assets = release.get("assets")
    names = asset_names(record["bundle_tag"])
    if (not isinstance(assets, list) or len(assets) != len(names)
            or any(not isinstance(item, dict) for item in assets)
            or {item.get("name") for item in assets} != names):
        raise ValueError("published candidate asset set is incomplete or unexpected")
    for item in assets:
        url = f"https://github.com/{record['repository']}/releases/download/{record['bundle_tag']}/{item['name']}"
        if (item.get("browser_download_url") != url or item.get("state") != "uploaded"
                or type(item.get("id")) is not int or item["id"] <= 0
                or type(item.get("size")) is not int or item["size"] <= 0
                or (item.get("digest") is not None and item["digest"] != f"sha256:{record['assets'][item['name']]}")):
            raise ValueError("published candidate asset identity does not match reviewed evidence")


def verify_publication_run(api: GitHubReleases, record: dict) -> None:
    publication = record["publication"]
    run = api.workflow_run(publication["run_id"], publication["run_attempt"])
    if (not isinstance(run, dict) or run.get("id") != publication["run_id"]
            or run.get("run_attempt") != publication["run_attempt"]
            or run.get("head_sha") != publication["workflow_sha"]
            or run.get("status") != "completed" or run.get("conclusion") != "success"
            or run.get("event") != "workflow_dispatch"
            or not isinstance(run.get("path"), str)
            or run["path"].split("@", 1)[0] != ".github/workflows/publish-release-bundle.yml"
            or not isinstance(run.get("repository"), dict)
            or run["repository"].get("full_name") != record["repository"]):
        raise ValueError("exact candidate publication workflow must have completed successfully")


def promote_bundle(workspace: Path, output: Path, evidence_commit: str, evidence_path: str,
                   default_branch: str, repository: str, installer_tag: str, installer_sha: str,
                   bundle_tag: str, workflow_sha: str, make_latest: bool, token: str,
                   *, verify_only: bool = False) -> bool:
    if workflow_sha != installer_sha:
        raise ValueError("promotion workflow must match the exact Installer source commit")
    if output.resolve().is_relative_to(workspace.resolve()):
        raise ValueError("promotion downloads must stay outside Installer source")
    verify_source_tags(workspace, installer_tag=installer_tag, installer_sha=installer_sha,
                       bundle_tag=bundle_tag, release=bundle_tag.removeprefix("bundle-v"))
    record = read_reviewed_evidence(workspace, evidence_commit, evidence_path, default_branch)
    output.mkdir(parents=True, exist_ok=False)
    source = create_source_archive(workspace, output / "verified-source.tar.gz", expected_sha=installer_sha)
    validate_record(record, source, repository, installer_tag, bundle_tag, workflow_sha, make_latest)
    api = GitHubReleases(repository, token)
    release = api.find(bundle_tag)
    verify_release(release, record)
    verify_publication_run(api, record)
    assets = output / "assets"
    assets.mkdir()
    for item in release["assets"]:
        download_public_file(item["browser_download_url"], assets / item["name"])
        if (assets / item["name"]).stat().st_size != item["size"]:
            raise ValueError("public asset size differs from published metadata")
    previous = output / "previous.json"
    download_public_file(record["previous"]["manifest_url"], previous)
    verify_candidate_evidence(record, assets, source, repository, installer_tag, bundle_tag,
                              workflow_sha, previous, make_latest)
    prior_tag = previous_tag(record)
    prior_release = api.find(prior_tag)
    if (not isinstance(prior_release, dict) or prior_release.get("tag_name") != prior_tag
            or prior_release.get("draft") is not False or prior_release.get("prerelease") is not False):
        raise ValueError("previous Bundle baseline must have a stable public Release")
    lifecycle = read_reviewed_evidence(workspace, record["lifecycle"]["commit"],
                                       record["lifecycle"]["path"], default_branch)
    verify_lifecycle_evidence(lifecycle, source, protected_stack(assets / "release.json"))
    verify_project_releases(assets / "release.json", repository, installer_tag, installer_sha,
                            record["cabinet_tag"], token)
    for tag in (installer_tag, bundle_tag):
        if resolve_git_ref(f"https://github.com/{repository}.git", f"refs/tags/{tag}").sha != installer_sha:
            raise ValueError("remote publication tag does not match tested Installer source")
    if verify_only:
        return False
    return api.promote(release, make_latest=make_latest)
