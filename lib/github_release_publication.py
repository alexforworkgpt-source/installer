"""Release operations that fail closed and never take ownership of another draft."""

import json
import re
import time
from urllib.error import HTTPError, URLError
import urllib.request


class GitHubReleases:
    def __init__(self, repository: str, token: str):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) or not token:
            raise ValueError("GitHub repository and token are required")
        self.repository = repository
        self.base_url = f"https://api.github.com/repos/{repository}/releases"
        self.token = token

    def request(self, suffix: str = "", *, method: str = "GET", data: dict | None = None, resource: str = "releases"):
        if resource not in {"releases", "actions"}:
            raise ValueError("unsupported GitHub publication API resource")
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repository}/{resource}" + suffix,
            data=json.dumps(data).encode() if data is not None else None,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/vnd.github+json",
                "Content-Type": "application/json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            error.close()
            raise ValueError(f"GitHub release API failed: HTTP {error.code}") from error
        except (URLError, OSError, json.JSONDecodeError) as error:
            raise ValueError("GitHub release API response is unavailable or invalid") from error

    def matching_releases(self, tag: str) -> list[dict]:
        # GitHub's list can briefly omit a just-created draft. Absence is only
        # a preflight hint, never permission to address uploaded assets by tag.
        page = 1
        matches = []
        while True:
            releases = self.request(f"?per_page=100&page={page}")
            if (not isinstance(releases, list)
                    or any(not isinstance(item, dict) or not isinstance(item.get("tag_name"), str)
                           for item in releases)):
                raise ValueError("GitHub release list is invalid")
            matches.extend(release for release in releases if release.get("tag_name") == tag)
            if len(releases) < 100:
                return matches
            page += 1

    def find(self, tag: str) -> dict | None:
        matches = self.matching_releases(tag)
        return matches[0] if matches else None

    def unique_owned_draft(self, receipt: dict, run: str) -> dict:
        for attempt in range(6):
            release = self.owned_draft(receipt, run)
            if release is None:
                raise ValueError("only the owned draft may be published")
            matches = self.matching_releases(receipt["tag"])
            if len(matches) == 1 and matches[0].get("id") == receipt["id"]:
                return release
            if matches or attempt == 5:
                raise ValueError("publication requires a unique visible owned draft; preserve other Releases")
            time.sleep(1)

    def workflow_run(self, run_id: int, attempt: int) -> dict:
        if any(type(value) is not int or value <= 0 for value in (run_id, attempt)):
            raise ValueError("exact publication run and attempt are required")
        return self.request(f"/runs/{run_id}/attempts/{attempt}", resource="actions")

    def create_draft(self, tag: str, title: str, notes: str, run: str, *, source_sha: str | None = None) -> dict:
        if self.find(tag) is not None:
            raise ValueError("Release already exists; existing drafts and public assets are preserved")
        if not re.fullmatch(r"[0-9]+/[0-9]+", run):
            raise ValueError("publication run identity is invalid")
        if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
            raise ValueError("draft requires the exact selected source SHA")
        marker = f"<!-- publication-run: {run} -->"
        release = self.request(method="POST", data={
            "tag_name": tag, "target_commitish": source_sha,
            "name": title, "body": notes + "\n\n" + marker,
            "draft": True, "prerelease": True, "make_latest": "false",
        })
        if (not isinstance(release, dict) or type(release.get("id")) is not int or release["id"] <= 0
                or release.get("draft") is not True or release.get("tag_name") != tag):
            raise ValueError("created Release response is invalid; manual draft inspection required")
        return {"repository": self.repository, "tag": tag, "id": release["id"], "marker": marker}

    def owned_draft(self, receipt: dict, run: str) -> dict | None:
        if (receipt.get("repository") != self.repository
                or type(receipt.get("id")) is not int or receipt["id"] <= 0
                or not re.fullmatch(r"[0-9]+/[0-9]+", run)
                or receipt.get("marker") != f"<!-- publication-run: {run} -->"):
            raise ValueError("draft receipt does not belong to this publication run")
        release = self.request(f"/{receipt['id']}")
        if (not isinstance(release, dict) or release.get("id") != receipt["id"]
                or release.get("tag_name") != receipt.get("tag")):
            raise ValueError("draft identity does not match publication receipt")
        body = release.get("body")
        if (release.get("draft") is not True or not isinstance(body, str)
                or not body.endswith(receipt["marker"])):
            return None
        return release

    def cleanup(self, receipt: dict, run: str) -> bool:
        if self.owned_draft(receipt, run) is None:
            return False
        self.request(f"/{receipt['id']}", method="DELETE")
        return True

    def publish(self, receipt: dict, run: str, *, prerelease: bool) -> None:
        self.unique_owned_draft(receipt, run)
        self.request(f"/{receipt['id']}", method="PATCH", data={
            "draft": False, "prerelease": prerelease, "make_latest": "false",
        })

    @staticmethod
    def release_binding(release: dict) -> dict:
        fields = ("id", "name", "size", "digest", "state", "browser_download_url")
        assets = release.get("assets")
        if not isinstance(assets, list) or any(not isinstance(item, dict) for item in assets):
            raise ValueError("published Release asset metadata is invalid")
        return {
            "id": release.get("id"), "tag": release.get("tag_name"),
            "body": release.get("body"),
            "assets": sorted([{key: item.get(key) for key in fields} for item in assets],
                             key=lambda item: str(item["name"])),
        }

    def promote(self, verified: dict, *, make_latest: bool) -> bool:
        if type(verified.get("id")) is not int or verified["id"] <= 0 or type(make_latest) is not bool:
            raise ValueError("verified Release ID and explicit latest policy are required")
        current = self.request(f"/{verified['id']}")
        if (not isinstance(current, dict) or current.get("draft") is not False
                or current.get("immutable") is not True or type(current.get("prerelease")) is not bool
                or self.release_binding(current) != self.release_binding(verified)):
            raise ValueError("published immutable candidate changed since verification")
        if current["prerelease"] is False:
            return False  # Do not reassign latest when retrying an already stable Release.
        result = self.request(f"/{verified['id']}", method="PATCH", data={
            "prerelease": False, "make_latest": "true" if make_latest else "false",
        })
        if (not isinstance(result, dict) or result.get("prerelease") is not False
                or result.get("draft") is not False or result.get("immutable") is not True
                or self.release_binding(result) != self.release_binding(verified)):
            raise ValueError("promotion response is inconsistent; inspect metadata without replacing assets")
        return True
