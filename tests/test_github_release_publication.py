import io
import json
import unittest
from unittest import mock
from urllib.error import HTTPError


class GitHubReleasePublicationTests(unittest.TestCase):
    def test_duplicate_or_invisible_owned_draft_cannot_be_published(self):
        from lib.github_release_publication import GitHubReleases

        receipt = {"repository": "OWNER/installer", "tag": "bundle-v2026.10.01",
                   "id": 12, "marker": "<!-- publication-run: 123/1 -->"}
        owned = {"id": 12, "tag_name": receipt["tag"], "draft": True, "body": receipt["marker"]}
        foreign = dict(owned, id=13, body="another publication")
        for visible in ([], [foreign], [owned, foreign]):
            def response(request, **kwargs):
                return io.BytesIO(json.dumps(owned if request.full_url.endswith('/12') else visible).encode())
            with mock.patch("urllib.request.urlopen", side_effect=response) as network, mock.patch("time.sleep"):
                with self.assertRaisesRegex(ValueError, "unique visible owned draft"):
                    GitHubReleases(receipt["repository"], "fictional-token").publish(
                        receipt, "123/1", prerelease=True,
                    )
                self.assertTrue(all(call.args[0].get_method() == "GET" for call in network.call_args_list))

    def test_publication_waits_for_own_draft_visibility_without_creating_another_draft(self):
        from lib.github_release_publication import GitHubReleases

        receipt = {"repository": "OWNER/installer", "tag": "bundle-v2026.10.01",
                   "id": 12, "marker": "<!-- publication-run: 123/1 -->"}
        owned = {"id": 12, "tag_name": receipt["tag"], "draft": True, "body": receipt["marker"]}
        responses = [owned, [], owned, [owned], {}]
        with mock.patch("urllib.request.urlopen", side_effect=[io.BytesIO(json.dumps(r).encode()) for r in responses]) as network, mock.patch("time.sleep"):
            GitHubReleases(receipt["repository"], "fictional-token").publish(receipt, "123/1", prerelease=True)
            self.assertEqual([call.args[0].get_method() for call in network.call_args_list], ["GET", "GET", "GET", "GET", "PATCH"])

    def test_promotion_refuses_mutable_draft_or_replaced_asset_without_a_patch(self):
        from lib.github_release_publication import GitHubReleases

        verified = {"id": 12, "tag_name": "bundle-v2026.10.02", "draft": False,
                    "prerelease": True, "immutable": True, "assets": [{"id": 20, "name": "fixture"}]}
        for changes in ({"draft": True}, {"immutable": False}, {"tag_name": "another"},
                        {"assets": [{"id": 21, "name": "fixture"}]}, {"prerelease": None}):
            response = io.BytesIO(json.dumps(dict(verified, **changes)).encode())
            with mock.patch("urllib.request.urlopen", return_value=response) as network:
                with self.assertRaises(ValueError):
                    GitHubReleases("OWNER/installer", "fictional-token").promote(verified, make_latest=True)
                self.assertEqual(network.call_count, 1)
                self.assertEqual(network.call_args.args[0].get_method(), "GET")

    def test_promotion_only_changes_prerelease_and_explicit_latest_metadata(self):
        from lib.github_release_publication import GitHubReleases

        release = {"id": 12, "tag_name": "bundle-v2026.10.02", "draft": False,
                   "prerelease": True, "immutable": True, "assets": [{"id": 20, "name": "fixture"}]}
        for stable in (False, True):
            current = dict(release, prerelease=not stable)
            updated = dict(current, prerelease=False)
            responses = [io.BytesIO(json.dumps(current).encode()), io.BytesIO(json.dumps(updated).encode())]
            with mock.patch("urllib.request.urlopen", side_effect=responses) as network:
                changed = GitHubReleases("OWNER/installer", "fictional-token").promote(current, make_latest=True)
                self.assertEqual(changed, not stable)
                self.assertEqual(network.call_count, 1 if stable else 2)
                if not stable:
                    request = network.call_args.args[0]
                    self.assertEqual(request.get_method(), "PATCH")
                    self.assertEqual(json.loads(request.data), {"prerelease": False, "make_latest": "true"})
                    self.assertTrue(request.full_url.endswith("/12"))

    def test_new_draft_uses_exact_commit_after_complete_paginated_lookup(self) -> None:
        from lib.github_release_publication import GitHubReleases

        tag = "bundle-v2026.10.01"
        pages = [[{"tag_name": f"historic-{index}"} for index in range(100)], [],
                 {"id": 12, "tag_name": tag, "draft": True}]
        responses = [io.BytesIO(json.dumps(page).encode()) for page in pages]
        with mock.patch("urllib.request.urlopen", side_effect=responses) as api:
            receipt = GitHubReleases("OWNER/installer", "fictional-token").create_draft(
                tag, "Release Bundle", "Candidate", "123/1", source_sha="a" * 40,
            )
            self.assertEqual(api.call_count, 3)
            self.assertIn("page=2", api.call_args_list[1].args[0].full_url)
            payload = json.loads(api.call_args.args[0].data)
            self.assertEqual(payload["target_commitish"], "a" * 40)
            self.assertEqual(payload["make_latest"], "false")
            self.assertTrue(payload["draft"])
            self.assertEqual(receipt["id"], 12)
            self.assertEqual(receipt["marker"], "<!-- publication-run: 123/1 -->")

    def test_publication_preserves_assets_and_never_implicitly_sets_latest(self) -> None:
        from lib.github_release_publication import GitHubReleases

        receipt = {"repository": "OWNER/installer", "tag": "bundle-v2026.10.01",
                   "id": 12, "marker": "<!-- publication-run: 123/1 -->"}
        release = {"id": 12, "tag_name": receipt["tag"], "draft": True,
                   "body": receipt["marker"]}
        for prerelease in (True, False):
            responses = [io.BytesIO(json.dumps(release).encode()),
                         io.BytesIO(json.dumps([release]).encode()), io.BytesIO(b"{}")]
            with mock.patch("urllib.request.urlopen", side_effect=responses) as api:
                GitHubReleases("OWNER/installer", "fictional-token").publish(receipt, "123/1", prerelease=prerelease)
                request = api.call_args.args[0]
                self.assertEqual(request.get_method(), "PATCH")
                self.assertEqual(json.loads(request.data), {
                    "draft": False, "prerelease": prerelease, "make_latest": "false",
                })

    def test_cleanup_deletes_only_owned_draft_id_and_never_public_release(self) -> None:
        from lib.github_release_publication import GitHubReleases

        receipt = {"repository": "OWNER/installer", "tag": "bundle-v2026.10.01",
                   "id": 12, "marker": "<!-- publication-run: 123/1 -->"}
        for draft, body, expected_delete in (
            (True, receipt["marker"], True),
            (False, receipt["marker"], False),
            (True, "another workflow", False),
        ):
            release = {"id": 12, "tag_name": receipt["tag"], "draft": draft, "body": body}
            responses = [io.BytesIO(json.dumps(release).encode()), io.BytesIO(b"")]
            with mock.patch("urllib.request.urlopen", side_effect=responses) as api:
                deleted = GitHubReleases("OWNER/installer", "fictional-token").cleanup(receipt, "123/1")
                self.assertEqual(deleted, expected_delete)
                self.assertEqual(api.call_count, 2 if expected_delete else 1)
                if expected_delete:
                    self.assertTrue(api.call_args.args[0].full_url.endswith("/12"))
                    self.assertEqual(api.call_args.args[0].get_method(), "DELETE")

    def test_existing_draft_or_public_release_is_preserved(self) -> None:
        from lib.github_release_publication import GitHubReleases

        for draft in (True, False):
            response = io.BytesIO(json.dumps([
                {"id": 12, "tag_name": "bundle-v2026.10.01", "draft": draft}
            ]).encode())
            with mock.patch("urllib.request.urlopen", return_value=response) as api:
                with self.assertRaisesRegex(ValueError, "already exists"):
                    GitHubReleases("OWNER/installer", "fictional-token").create_draft(
                        "bundle-v2026.10.01", "Bundle", "Notes", "123/1"
                    )
                self.assertEqual(api.call_count, 1)
                self.assertEqual(api.call_args.args[0].get_method(), "GET")

    def test_api_failure_cannot_be_treated_as_missing_release(self) -> None:
        from lib.github_release_publication import GitHubReleases

        for status in (401, 403, 404, 429, 500):
            with self.subTest(status=status):
                error = HTTPError("https://api.github.com/fixture", status, "failure", {}, None)
                with mock.patch("urllib.request.urlopen", side_effect=error):
                    with self.assertRaisesRegex(ValueError, f"HTTP {status}"):
                        GitHubReleases("OWNER/installer", "fictional-token").find("bundle-v2026.10.01")
