"""Transfer assets by owned Release ID; a tag may resolve to another draft."""

import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote

from lib.github_release_publication import GitHubReleases


def safe_name(name: str) -> bool:
    return isinstance(name, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name))


def gh_api(api: GitHubReleases, arguments: list[str], *, output=None):
    try:
        result = subprocess.run(
            ["gh", "api", *arguments], check=True, stdout=output or subprocess.PIPE,
            stderr=subprocess.PIPE, env=dict(os.environ, GH_TOKEN=api.token),
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError("GitHub asset transfer failed; inspect the owned draft") from error
    return result.stdout


def upload_assets(api: GitHubReleases, receipt: dict, run: str, directory: Path) -> None:
    release = api.unique_owned_draft(receipt, run)
    if release.get("assets") != []:
        raise ValueError("owned draft must have no existing assets before upload")
    files = sorted(directory.iterdir())
    if not files or any(not path.is_file() or path.is_symlink() or not safe_name(path.name) for path in files):
        raise ValueError("prepared assets must be regular files with safe names")
    for path in files:
        endpoint = (f"https://uploads.github.com/repos/{api.repository}/releases/{receipt['id']}/assets"
                    f"?name={quote(path.name, safe='')}")
        response = gh_api(api, [endpoint, "--method", "POST", "-H", "Content-Type: application/octet-stream",
                                "--input", str(path)])
        try:
            asset = json.loads(response)
        except (TypeError, ValueError) as error:
            raise ValueError("uploaded asset response is invalid") from error
        if (not isinstance(asset, dict) or type(asset.get("id")) is not int or asset["id"] <= 0
                or asset.get("name") != path.name or asset.get("state") != "uploaded"):
            raise ValueError("uploaded asset identity is invalid")


def download_assets(api: GitHubReleases, receipt: dict, run: str, directory: Path) -> None:
    assets = api.unique_owned_draft(receipt, run).get("assets")
    if (not isinstance(assets, list) or not assets
            or any(not isinstance(asset, dict) or type(asset.get("id")) is not int or asset["id"] <= 0
                   or not safe_name(asset.get("name")) or asset.get("state") != "uploaded" for asset in assets)
            or len({asset["name"] for asset in assets}) != len(assets)
            or len({asset["id"] for asset in assets}) != len(assets)):
        raise ValueError("owned draft asset identities are invalid")
    directory.mkdir(parents=True, exist_ok=False)
    for asset in assets:
        endpoint = f"repos/{api.repository}/releases/assets/{asset['id']}"
        with (directory / asset["name"]).open("xb") as output:
            gh_api(api, [endpoint, "-H", "Accept: application/octet-stream"], output=output)
