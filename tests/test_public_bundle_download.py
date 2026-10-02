import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError


class PublicBundleDownloadTests(unittest.TestCase):
    def test_downloads_use_no_authentication_and_fail_on_http_or_non_https(self):
        from lib.public_bundle_download import download_public_file

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "asset"
            response = io.BytesIO(b"public bytes")
            response.geturl = lambda: "https://release-assets.githubusercontent.com/public-fixture"
            with mock.patch("urllib.request.urlopen", return_value=response) as network:
                download_public_file("https://github.com/OWNER/installer/releases/download/bundle-v2026.10.02/release.json", destination)
                request = network.call_args.args[0]
                self.assertNotIn("Authorization", request.headers)
                self.assertEqual(destination.read_bytes(), b"public bytes")
            with mock.patch("urllib.request.urlopen", side_effect=HTTPError("fixture", 404, "missing", {}, None)):
                with self.assertRaisesRegex(ValueError, "HTTP 404"):
                    download_public_file("https://github.com/OWNER/installer/releases/download/bundle-v2026.10.02/release.json", destination)
            with mock.patch("urllib.request.urlopen") as network:
                with self.assertRaises(ValueError):
                    download_public_file("http://github.com/fixture", destination)
                network.assert_not_called()
