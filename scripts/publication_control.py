"""Local, testable guards used by the two publication workflows."""

import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from lib.github_release_publication import GitHubReleases
from lib.github_release_assets import upload_assets, download_assets
from lib.integration_source import create_source_archive
from lib.lifecycle_evidence import read_reviewed_evidence, verify_lifecycle_evidence
from lib.publication_identity import validate_tag_roles, verify_source_tags
from lib.project_release_verification import verify_project_releases
from lib.release_bundle import resolve_git_ref
from lib.runtime_image_verification import verify_runtime_images
from lib.publication_stack import protected_stack


def selected_tag() -> str:
    return os.environ.get("BUNDLE_TAG") or os.environ["INSTALLER_TAG"]


def verify_remote_tags() -> None:
    validate_tag_roles(os.environ["INSTALLER_TAG"], os.environ.get("BUNDLE_TAG"), os.environ.get("RELEASE_NAME"))
    repository = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}.git"
    for tag in {selected_tag(), os.environ["INSTALLER_TAG"]}:
        if resolve_git_ref(repository, f"refs/tags/{tag}").sha != os.environ["INSTALLER_SHA"]:
            raise ValueError("remote publication tag does not match Installer SHA")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Guard exact Installer and Bundle publications")
    parser.add_argument("command", choices=(
        "source", "evidence", "images", "project-releases", "check-release", "create-draft", "publish-draft", "cleanup-draft",
        "upload-assets", "download-assets",
    ))
    parser.add_argument("--workspace", type=Path, default=ROOT)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--cabinet-tag")
    parser.add_argument("--stable", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "source":
        if not args.source or not args.archive:
            parser.error("source requires --source and --archive")
        if os.environ["WORKFLOW_SHA"] != os.environ["INSTALLER_SHA"]:
            raise ValueError("workflow must run from the exact selected Installer commit")
        verify_source_tags(
            args.workspace, installer_tag=os.environ["INSTALLER_TAG"],
            installer_sha=os.environ["INSTALLER_SHA"], bundle_tag=os.environ.get("BUNDLE_TAG"),
            release=os.environ.get("RELEASE_NAME"),
        )
        source = create_source_archive(args.workspace, args.archive, expected_sha=os.environ["INSTALLER_SHA"])
        args.source.write_text(json.dumps(source, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(source, sort_keys=True))
        return 0
    if args.command == "evidence":
        if not args.source:
            parser.error("evidence requires --source")
        record = read_reviewed_evidence(
            args.workspace, os.environ["LIFECYCLE_EVIDENCE_SHA"], os.environ["LIFECYCLE_EVIDENCE_PATH"],
            os.environ["DEFAULT_BRANCH"],
        )
        source = json.loads(args.source.read_text(encoding="utf-8"))
        expected = protected_stack(args.manifest) if args.manifest else record.get("protected")
        verify_lifecycle_evidence(record, source, expected)
        print("Reviewed lifecycle evidence matches source and protected stack")
        return 0
    if args.command == "images":
        verify_runtime_images(os.environ["POSTGRES_IMAGE"], os.environ["REDIS_IMAGE"])
        return 0
    if args.command == "project-releases":
        if not args.manifest or not args.cabinet_tag:
            parser.error("project-releases requires --manifest and --cabinet-tag")
        verify_project_releases(
            args.manifest, os.environ["GITHUB_REPOSITORY"], os.environ["INSTALLER_TAG"],
            os.environ["INSTALLER_SHA"], args.cabinet_tag, os.environ["GH_TOKEN"],
        )
        print("Stable project Releases match selected Installer and Bundle Cabinet source")
        return 0
    api = GitHubReleases(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"])
    tag = selected_tag()
    run = f"{os.environ['GITHUB_RUN_ID']}/{os.environ['GITHUB_RUN_ATTEMPT']}"
    if args.command == "check-release":
        if api.find(tag) is not None:
            raise ValueError("Release already exists; use a new publication tag")
        return 0
    if not args.receipt:
        parser.error("draft operations require --receipt")
    if args.command == "create-draft":
        if not args.notes:
            parser.error("create-draft requires --notes")
        verify_remote_tags()
        title = (f"Release Bundle {os.environ['RELEASE_NAME']}" if os.environ.get("BUNDLE_TAG")
                 else f"Installer {os.environ['INSTALLER_TAG'].removeprefix('installer-v')}")
        receipt = api.create_draft(tag, title, args.notes.read_text(encoding="utf-8"), run,
                                   source_sha=os.environ["INSTALLER_SHA"])
        args.receipt.write_text(json.dumps(receipt) + "\n", encoding="utf-8")
        return 0
    if not args.receipt.exists():
        if args.command == "cleanup-draft":
            return 0
        raise ValueError("owned draft receipt is missing")
    receipt = json.loads(args.receipt.read_text(encoding="utf-8"))
    if receipt.get("tag") != tag:
        raise ValueError("draft receipt tag does not match selected publication")
    if args.command == "cleanup-draft":
        api.cleanup(receipt, run)
    elif args.command in {"upload-assets", "download-assets"}:
        if not args.assets:
            parser.error("asset transfer requires --assets")
        transfer = upload_assets if args.command == "upload-assets" else download_assets
        transfer(api, receipt, run, args.assets)
    else:
        if args.stable and os.environ.get("BUNDLE_TAG"):
            raise ValueError("stable Bundle promotion requires the separate candidate evidence gate")
        verify_remote_tags()
        api.publish(receipt, run, prerelease=not args.stable)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (ValueError, RuntimeError, OSError, KeyError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None
