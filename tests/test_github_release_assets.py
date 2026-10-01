import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import subprocess

from lib.github_release_publication import GitHubReleases


class GitHubReleaseAssetTests(unittest.TestCase):
    def test_assets_use_owned_release_and_asset_ids_even_when_tag_lookup_is_stale(self):
        from lib.github_release_assets import upload_assets, download_assets

        receipt = {"repository": "OWNER/installer", "tag": "bundle-v2026.10.01",
                   "id": 12, "marker": "<!-- publication-run: 123/1 -->"}
        asset = {"id": 20, "name": "fixture.tar.gz", "state": "uploaded"}
        owned = {"id": 12, "tag_name": receipt["tag"], "draft": True, "body": receipt["marker"], "assets": []}
        responses = [owned, [owned], dict(owned, assets=[asset]), [owned]]
        with tempfile.TemporaryDirectory() as directory:
            prepared = Path(directory) / "prepared"
            prepared.mkdir()
            (prepared / asset["name"]).write_bytes(b"controlled fixture")
            with mock.patch("urllib.request.urlopen", side_effect=[io.BytesIO(json.dumps(r).encode()) for r in responses]), \
                    mock.patch("subprocess.run") as gh:
                def transfer(args, **kwargs):
                    if "--input" in args:
                        return subprocess.CompletedProcess(args, 0, json.dumps(asset).encode())
                    kwargs["stdout"].write(b"controlled fixture")
                    return subprocess.CompletedProcess(args, 0)
                gh.side_effect = transfer
                api = GitHubReleases(receipt["repository"], "fictional-token")
                upload_assets(api, receipt, "123/1", prepared)
                downloaded = Path(directory) / "downloaded"
                download_assets(api, receipt, "123/1", downloaded)
                self.assertEqual((downloaded / asset["name"]).read_bytes(), b"controlled fixture")
                self.assertIn("/releases/12/assets?name=fixture.tar.gz", gh.call_args_list[0].args[0][2])
                self.assertEqual(gh.call_args_list[1].args[0][2], "repos/OWNER/installer/releases/assets/20")
                self.assertTrue(all("release" not in call.args[0] for call in gh.call_args_list))
