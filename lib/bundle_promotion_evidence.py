"""Bind durable reviewed promotion evidence to the exact downloaded Bundle."""

import hashlib
import json
from pathlib import Path
import re

from lib.lifecycle_evidence import validate_log_identity, validate_protected_stack
from lib.publication_identity import VERSION, validate_tag_roles
from lib.publication_stack import protected_stack
from lib.release_bundle import load_release_bundle, release_bundle_identity, verify_cabinet_artifact


def exact_fields(value, fields) -> bool:
    return isinstance(value, dict) and set(value) == set(fields)


def public_evidence(value) -> bool:
    return isinstance(value, str) and re.fullmatch(
        r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/"
        r"(?:actions/runs/[0-9]+|blob/[0-9a-f]{40}/releases/evidence/[A-Za-z0-9_./-]+)", value) is not None


def previous_tag(record: dict) -> str:
    previous = record.get("previous")
    if not exact_fields(previous, {"manifest_url", "manifest_sha256", "bundle_identity"}):
        raise ValueError("previous Bundle reference is incomplete")
    url = previous["manifest_url"]
    match = re.fullmatch(
        rf"https://github\.com/{re.escape(record['repository'])}/releases/download/((?:bundle-)?v{VERSION})/release\.json",
        url if isinstance(url, str) else "")
    if (not match or match[1] == record["bundle_tag"]
            or any(not isinstance(previous[key], str) or not re.fullmatch(r"[0-9a-f]{64}", previous[key])
                   for key in ("manifest_sha256", "bundle_identity"))):
        raise ValueError("previous Bundle URL and identities must be explicit and different from candidate")
    return match[1]


def validate_record(record: dict, source: dict, repository: str, installer_tag: str,
                    bundle_tag: str, workflow_sha: str, make_latest: bool) -> None:
    fields = {"schema_version", "kind", "result", "owner_approved", "repository", "bundle_tag",
              "release_id", "installer_tag", "installer", "cabinet_tag", "protected", "bundle_identity",
              "assets", "publication", "previous", "gates", "limitations", "lifecycle", "make_latest",
              "log_path", "log_sha256"}
    if (not exact_fields(record, fields) or type(record["schema_version"]) is not int
            or record["schema_version"] != 1 or record["kind"] != "bundle-promotion"
            or record["result"] != "PASS" or record["owner_approved"] is not True):
        raise ValueError("promotion requires complete approved successful evidence")
    validate_tag_roles(installer_tag, bundle_tag, bundle_tag.removeprefix("bundle-v"))
    if (record["repository"] != repository or record["bundle_tag"] != bundle_tag
            or record["installer_tag"] != installer_tag or record["installer"] != source
            or not isinstance(record["cabinet_tag"], str)
            or not re.fullmatch(rf"cabinet-v{VERSION}", record["cabinet_tag"])):
        raise ValueError("promotion project identities do not match selected source")
    if (type(record["release_id"]) is not int or record["release_id"] <= 0
            or type(make_latest) is not bool or type(record["make_latest"]) is not bool
            or record["make_latest"] != make_latest):
        raise ValueError("promotion Release identity or explicit latest policy is invalid")
    publication = record["publication"]
    if (not exact_fields(publication, {"workflow_sha", "run_id", "run_attempt"})
            or publication["workflow_sha"] != workflow_sha or workflow_sha != source["installer_sha"]
            or any(type(publication[key]) is not int or publication[key] <= 0 for key in ("run_id", "run_attempt"))):
        raise ValueError("publication workflow does not match the exact tested Installer source")
    if not exact_fields(record["gates"], {"cabinet_source", "compatibility", "smoke", "transition"}):
        raise ValueError("required promotion gates are incomplete")
    for name, gate in record["gates"].items():
        allowed = {"PASS", "NOT_REQUIRED"} if name == "transition" else {"PASS"}
        if (not exact_fields(gate, {"result", "evidence_url"}) or not isinstance(gate["result"], str)
                or gate["result"] not in allowed or not public_evidence(gate["evidence_url"])):
            raise ValueError("missing or unsuccessful gate cannot be accepted as PASS")
    limitations = record["limitations"]
    if (not isinstance(limitations, list) or not limitations
            or any(not exact_fields(item, {"id", "status", "summary", "accepted"})
                   or not isinstance(item["id"], str) or not item["id"].strip()
                   or not isinstance(item["status"], str) or item["status"] not in {"OPEN", "BLOCKED"}
                   or not isinstance(item["summary"], str) or not item["summary"].strip()
                   or item["accepted"] is not True for item in limitations)
            or not any(item["id"] == "classic-auto-purchase" and item["status"] == "OPEN" for item in limitations)):
        raise ValueError("known limits must remain explicit and accepted by the owner")
    if (not exact_fields(record["lifecycle"], {"commit", "path"})
            or not isinstance(record["lifecycle"]["commit"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", record["lifecycle"]["commit"])):
        raise ValueError("exact reviewed lifecycle reference is required")
    validate_log_identity(record)
    previous_tag(record)
    if (not exact_fields(record["assets"], asset_names(bundle_tag))
            or any(not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
                   for value in record["assets"].values())):
        raise ValueError("promotion asset identities are incomplete or invalid")


def file_digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def asset_names(bundle_tag: str) -> set[str]:
    release = bundle_tag.removeprefix("bundle-v")
    return {"cabinet-dist.tar.gz", "cabinet-dist.tar.gz.sha256", "release.json",
            "release-provenance.json", f"installer-{release}.tar.gz", f"installer-{release}.tar.gz.sha256"}


def verify_candidate_evidence(record: dict, assets: Path, source: dict, repository: str,
                              installer_tag: str, bundle_tag: str, workflow_sha: str,
                              previous_manifest: Path, make_latest: bool):
    validate_record(record, source, repository, installer_tag, bundle_tag, workflow_sha, make_latest)
    names = asset_names(bundle_tag)
    if (not isinstance(record.get("assets"), dict) or set(record["assets"]) != names
            or {path.name for path in assets.iterdir()} != names):
        raise ValueError("promotion asset set is incomplete or unexpected")
    for name in names:
        path = assets / name
        if path.is_symlink() or not path.is_file() or file_digest(path) != record["assets"][name]:
            raise ValueError("promotion asset bytes do not match reviewed evidence")
    manifest = assets / "release.json"
    bundle = load_release_bundle(manifest, 1)
    protected = protected_stack(manifest)
    validate_protected_stack(protected)
    if record["protected"] != protected or release_bundle_identity(bundle) != record["bundle_identity"]:
        raise ValueError("promotion Bundle identity or protected stack does not match candidate")
    if (bundle.release != bundle_tag.removeprefix("bundle-v") or bundle.cabinet.artifact_url !=
            f"https://github.com/{repository}/releases/download/{bundle_tag}/cabinet-dist.tar.gz"):
        raise ValueError("candidate manifest does not use the final Bundle identity and URLs")
    for name in ("cabinet-dist.tar.gz", f"installer-{bundle.release}.tar.gz"):
        if (assets / f"{name}.sha256").read_text(encoding="utf-8") != f"{record['assets'][name]}  {name}\n":
            raise ValueError("candidate checksum does not match exact asset")
    if record["assets"][f"installer-{bundle.release}.tar.gz"] != source["archive_sha256"]:
        raise ValueError("candidate Installer archive does not match tested source snapshot")
    verify_cabinet_artifact(assets / "cabinet-dist.tar.gz", bundle.cabinet.artifact_sha256)
    provenance = json.loads((assets / "release-provenance.json").read_text(encoding="utf-8"))
    if (not exact_fields(provenance, {"cabinet_repository", "cabinet_sha", "node_builder_image", "nginx_runtime_image"})
            or provenance["cabinet_repository"] != bundle.cabinet.repository
            or provenance["cabinet_sha"] != bundle.cabinet.source_sha
            or any(not isinstance(provenance[key], str)
                   or not re.fullmatch(r"[^@\s]+@sha256:[0-9a-f]{64}", provenance[key])
                   for key in ("node_builder_image", "nginx_runtime_image"))):
        raise ValueError("candidate provenance is inconsistent or incomplete")
    prior_tag = previous_tag(record)
    if file_digest(previous_manifest) != record["previous"]["manifest_sha256"]:
        raise ValueError("previous Bundle manifest does not match reviewed baseline")
    prior = load_release_bundle(previous_manifest, 1)
    if (release_bundle_identity(prior) != record["previous"]["bundle_identity"]
            or prior.release != prior_tag.removeprefix("bundle-").removeprefix("v")):
        raise ValueError("previous Bundle manifest does not match reviewed baseline")
    transition_fields = ("bot", "images", "backend_contract", "backend_contracts",
                         "configuration_schema", "migration_policy")
    if (any(getattr(prior, name) != getattr(bundle, name) for name in transition_fields)
            and record["gates"]["transition"]["result"] != "PASS"):
        raise ValueError("changed Bot, runtime or contract requires previous-to-candidate transition PASS")
    return bundle
