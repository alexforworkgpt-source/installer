"""Unauthenticated public downloads used to verify an already published Bundle."""

import os
from pathlib import Path
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
import urllib.request


def download_public_file(url: str, destination: Path) -> None:
    parts = urlsplit(url)
    if (parts.scheme != "https" or parts.hostname != "github.com"
            or parts.username or parts.password or parts.port or parts.query or parts.fragment
            or not parts.path.startswith("/") or url != url.strip()):
        raise ValueError("public Bundle downloads require a plain GitHub HTTPS URL")
    request = urllib.request.Request(url, headers={"Accept": "application/octet-stream"})
    temporary = None
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            final = urlsplit(response.geturl())
            if (final.scheme != "https" or final.username or final.password
                    or final.hostname not in {"github.com", "objects.githubusercontent.com",
                                               "release-assets.githubusercontent.com"}):
                raise ValueError("public Bundle download redirected outside GitHub HTTPS assets")
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
                temporary = Path(stream.name)
                size = 0
                for chunk in iter(lambda: response.read(1024 * 1024), b""):
                    size += len(chunk)
                    if size > 1024 * 1024 * 1024:
                        raise ValueError("public Bundle asset exceeds the supported size")
                    stream.write(chunk)
            os.replace(temporary, destination)
    except HTTPError as error:
        error.close()
        raise ValueError(f"public Bundle download failed: HTTP {error.code}") from error
    except (URLError, OSError) as error:
        raise ValueError("public Bundle download is unavailable") from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
