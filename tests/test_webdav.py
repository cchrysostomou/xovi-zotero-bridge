import base64
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import httpx2

from zotbridge.config import WebDAVConfig, config_from_dict
from zotbridge.webdav import WebDAVError, WebDAVStorage


class WebDAVTests(unittest.TestCase):
    def setUp(self):
        self.config = WebDAVConfig("https://dav.example/zotero/", "reader", "secret")
        self.storage = WebDAVStorage(self.config)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.output = Path(self.temp.name) / "document.pdf"

    def archive(self, files):
        content = io.BytesIO()
        with zipfile.ZipFile(content, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
            for name, data in files:
                zipped.writestr(name, data)
        return content.getvalue()

    def download(self, body, filename="Paper.pdf", status=200):
        requests = []
        def handler(request):
            requests.append(request)
            return httpx2.Response(status, content=body, headers={"Location": "https://other.example/"})
        real_client = httpx2.Client
        transport = httpx2.MockTransport(handler)
        with patch("zotbridge.webdav.httpx2.Client", side_effect=lambda **kwargs: real_client(
            transport=transport, **kwargs
        )):
            self.member = self.storage.download_pdf("ABCD1234", filename, self.output)
        return requests

    def test_authenticated_read_only_download_and_archive_cleanup(self):
        requests = self.download(self.archive([("Paper.pdf", b"%PDF-1.7\n")]))
        self.assertEqual(self.output.read_bytes(), b"%PDF-1.7\n")
        self.assertFalse(self.output.with_suffix(".zip").exists())
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0].method, "GET")
        self.assertEqual(str(requests[0].url), "https://dav.example/zotero/ABCD1234.zip")
        self.assertEqual(requests[0].headers["Authorization"], "Basic cmVhZGVyOnNlY3JldA==")
        self.assertNotIn("Zotero-API-Key", requests[0].headers)

    def test_zotero_base64_filename(self):
        name = base64.b64encode("Paper.pdf".encode()).decode() + "%ZB64"
        self.download(self.archive([(name, b"%PDF-1.7\n")]))
        self.assertTrue(self.output.exists())
        self.assertEqual(self.member, name)

    def test_renamed_single_pdf_is_accepted_but_ambiguous_archive_is_not(self):
        self.download(self.archive([("old-name.pdf", b"%PDF-1.7\n")]))
        with self.assertRaisesRegex(WebDAVError, "uniquely"):
            self.download(self.archive([("one.pdf", b"x"), ("two.pdf", b"x")]))

    def test_unsafe_paths_are_never_extracted(self):
        for name in ("../Paper.pdf", "/Paper.pdf", "C:\\Paper.pdf",
                     base64.b64encode(b"../Paper.pdf").decode() + "%ZB64"):
            with self.subTest(name=name), self.assertRaisesRegex(WebDAVError, "unsafe"):
                self.download(self.archive([(name, b"%PDF-1.7\n")]))
        self.assertFalse(self.output.exists())

    def test_redirect_and_auth_errors_do_not_leak_credentials(self):
        for status in (301, 302, 401, 403, 404):
            with self.subTest(status=status), self.assertRaises(WebDAVError) as caught:
                self.download(b"", status=status)
            self.assertNotIn("secret", str(caught.exception))
            self.assertNotIn("dav.example", str(caught.exception))

    def test_invalid_zip_is_reported_and_cleaned(self):
        with self.assertRaisesRegex(WebDAVError, "invalid"):
            self.download(b"<html>not a zip</html>")
        self.assertFalse(self.output.with_suffix(".zip").exists())

    def test_expanded_size_limit(self):
        self.storage = WebDAVStorage(WebDAVConfig(self.config.url, "reader", "secret", max_download_mb=1))
        with self.assertRaisesRegex(WebDAVError, "exceeds"):
            self.download(self.archive([("Paper.pdf", b"x" * (1024 * 1024 + 1))]))
        self.assertFalse(self.output.exists())


class WebDAVConfigTests(unittest.TestCase):
    def setUp(self):
        self.raw = {
            "library_id": "123", "library_type": "user", "api_key": "private-key",
            "use_webdav": True, "webdav_url": "https://dav.example/zotero",
            "webdav_username": "reader", "webdav_password": "private-password",
        }

    def test_settings_and_secret_safe_repr(self):
        config = config_from_dict(self.raw, Path("config.toml").resolve())
        self.assertEqual(config.webdav.url, "https://dav.example/zotero/")
        self.assertNotIn("private-key", repr(config))
        self.assertNotIn("private-password", repr(config))

    def test_invalid_settings(self):
        for update in (
            {"use_webdav": "True"}, {"library_type": "group"}, {"webdav_password": ""},
            {"webdav_url": "http://dav.example/zotero/"},
            {"webdav_url": "https://user:secret@dav.example/"},
            {"webdav_timeout_s": 0}, {"webdav_max_download_mb": True},
        ):
            with self.subTest(update=update), self.assertRaises(ValueError):
                config_from_dict(self.raw | update, Path("config.toml"))

    def test_http_requires_explicit_opt_in(self):
        config = config_from_dict(
            self.raw | {"webdav_url": "http://dav.example/", "webdav_allow_http": True},
            Path("config.toml"),
        )
        self.assertTrue(config.webdav.url.startswith("http:"))


if __name__ == "__main__":
    unittest.main()
