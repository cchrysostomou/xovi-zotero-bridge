from __future__ import annotations

from pathlib import Path, PurePosixPath
import base64
import binascii
import re
import stat
import time
import zipfile
import zlib

import httpx2

from zotbridge.config import WebDAVConfig


class WebDAVError(RuntimeError):
    pass


class WebDAVStorage:
    def __init__(self, config: WebDAVConfig):
        self.config = config

    def download_pdf(self, attachment_key: str, filename: str, destination: Path) -> str:
        """Download the selected PDF and return its original ZIP member name."""
        if re.fullmatch(r"[A-Z0-9]{8}", attachment_key) is None:
            raise WebDAVError("Zotero returned an invalid attachment key")
        limit = self.config.max_download_mb * 1024 * 1024
        archive_path = destination.with_suffix(".zip")
        deadline = time.monotonic() + self.config.timeout_s
        try:
            with httpx2.Client(
                auth=(self.config.username, self.config.password),
                timeout=self.config.timeout_s,
                follow_redirects=False,
            ) as client:
                with client.stream("GET", self.config.url + attachment_key + ".zip") as response:
                    if response.status_code != 200:
                        raise WebDAVError(
                            f"WebDAV attachment download returned HTTP {response.status_code}. "
                            "Check credentials and the exact directory containing Zotero .zip files."
                        )
                    size = 0
                    with archive_path.open("wb") as output:
                        for chunk in response.iter_bytes():
                            size += len(chunk)
                            if size > limit:
                                raise WebDAVError("WebDAV archive exceeds webdav_max_download_mb")
                            if time.monotonic() > deadline:
                                raise WebDAVError("WebDAV download exceeded webdav_timeout_s")
                            output.write(chunk)
            return self._extract_pdf(archive_path, filename, destination, limit)
        except httpx2.HTTPError as exc:
            raise WebDAVError(
                f"WebDAV connection failed ({type(exc).__name__}). "
                "Check server reachability and its TLS certificate."
            ) from None
        except (zipfile.BadZipFile, NotImplementedError, zlib.error):
            raise WebDAVError("WebDAV returned an invalid or unsupported Zotero ZIP archive") from None
        finally:
            archive_path.unlink(missing_ok=True)

    @staticmethod
    def _extract_pdf(archive: Path, filename: str, destination: Path, limit: int) -> str:
        with zipfile.ZipFile(archive) as zipped:
            candidates = []
            for member in zipped.infolist():
                name = member.filename
                if name.endswith("%ZB64"):
                    try:
                        name = base64.b64decode(name[:-5], validate=True).decode("utf-8")
                    except (binascii.Error, UnicodeError):
                        raise WebDAVError("WebDAV ZIP has an invalid encoded filename") from None
                path = PurePosixPath(name)
                mode = member.external_attr >> 16
                if (
                    path.is_absolute() or ".." in path.parts or "\\" in name
                    or ":" in name or "\0" in name or stat.S_ISLNK(mode)
                ):
                    raise WebDAVError("WebDAV archive contains an unsafe entry")
                if not member.is_dir() and path.suffix.lower() == ".pdf":
                    candidates.append((member, name))
            matches = [member for member, name in candidates if name == filename]
            if len(matches) == 1:
                selected = matches[0]
            elif len(candidates) == 1:
                # Some Zotero archives retain the name from before an attachment was renamed.
                selected = candidates[0][0]
            else:
                raise WebDAVError("WebDAV archive has no uniquely identifiable PDF attachment")
            if selected.file_size > limit:
                raise WebDAVError("WebDAV PDF exceeds webdav_max_download_mb")
            if selected.flag_bits & 1:
                raise WebDAVError("Encrypted WebDAV ZIP entries are not supported")
            with zipped.open(selected) as source, destination.open("wb") as output:
                size = 0
                while chunk := source.read(65536):
                    size += len(chunk)
                    if size > limit:
                        raise WebDAVError("WebDAV PDF exceeds webdav_max_download_mb")
                    output.write(chunk)
            return selected.filename
