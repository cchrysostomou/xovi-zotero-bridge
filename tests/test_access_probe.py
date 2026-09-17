import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.name == "posix", "Probe shell tests require POSIX sh")
class AccessProbeTests(unittest.TestCase):
    def run_probe(self, zotero_code="200", webdav_code="207", network_error="0"):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            script = root / "check.sh"
            script.write_text((ROOT / "scripts" / "check-zotero-connection.sh").read_text())
            (root / "zotero.curl").write_text('header = "Zotero-API-Key: private-test-key"\n')
            (root / "webdav.curl").write_text('user = "reader:private-test-password"\n')
            fake = root / "curl"
            fake.write_text(
                '#!/bin/sh\n'
                '[ "$NETWORK_ERROR" = 0 ] || exit "$NETWORK_ERROR"\n'
                'case "$*" in\n'
                '  *zotero.curl*) printf "%s" "$ZOTERO_CODE" ;;\n'
                '  *) printf "%s" "$WEBDAV_CODE" ;;\n'
                'esac\n'
            )
            fake.chmod(0o755)
            env = dict(os.environ, ZOTBRIDGE_CURL=str(fake), NETWORK_ERROR=network_error,
                       ZOTERO_CODE=zotero_code, WEBDAV_CODE=webdav_code)
            return subprocess.run(["sh", str(script)], env=env, capture_output=True,
                                  text=True, timeout=5)

    def test_success_requires_both_expected_statuses(self):
        result = self.run_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Zotero metadata access (HTTP 200)", result.stdout)
        self.assertIn("WebDAV directory access (HTTP 207)", result.stdout)
        self.assertNotIn("private-test", result.stdout + result.stderr)

    def test_webdav_auth_failure_is_not_success(self):
        result = self.run_probe(webdav_code="401")
        self.assertEqual(result.returncode, 1)
        self.assertIn("HTTP 401", result.stderr)
        self.assertNotIn("private-test", result.stdout + result.stderr)

    def test_tls_failure_is_reported_without_disabling_verification(self):
        result = self.run_probe(network_error="60")
        self.assertEqual(result.returncode, 1)
        self.assertIn("TLS/certificate validation failed", result.stderr)


@unittest.skipUnless(os.name == "posix" and shutil.which("unzip"), "PDF probe tests require sh and unzip")
class PDFProbeTests(unittest.TestCase):
    def run_pdf_probe(self, content=b"%PDF-1.7\nTest PDF\n", status="200", invalid_zip=False,
                      busybox=False):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            scratch = root / "tmp"
            scratch.mkdir()
            script = root / "check.sh"
            script.write_text((ROOT / "scripts" / "check-pdf-download.sh").read_text())
            (root / "webdav-pdf.curl").write_text('user = "reader:private-test-password"\n')
            (root / "member.txt").write_text("Paper.pdf\n")
            (root / "expected-size.txt").write_text(str(len(content)) + "\n")
            archive = root / "source.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr("Paper.pdf", content)
            if invalid_zip:
                archive.write_text("not a zip")
            fake = root / "curl"
            fake.write_text(
                '#!/bin/sh\n'
                'while [ "$#" -gt 0 ]; do\n'
                '  case "$1" in --output) shift; cp "$FAKE_ARCHIVE" "$1";; esac\n'
                '  shift\n'
                'done\n'
                'printf "%s" "$FAKE_STATUS"\n'
            )
            fake.chmod(0o755)
            env = dict(os.environ, ZOTBRIDGE_CURL=str(fake), TMPDIR=str(scratch),
                       FAKE_ARCHIVE=str(archive), FAKE_STATUS=status)
            if busybox:
                binaries = root / "bin"
                binaries.mkdir()
                wrapper = binaries / "unzip"
                wrapper.write_text(
                    '#!/bin/sh\n'
                    'if [ "$1" = -h ]; then\n'
                    '  printf "%s\\n" "BusyBox v1.36.1 () multi-call binary." >&2\n'
                    '  exit 1\n'
                    'fi\n'
                    'for argument do\n'
                    '  [ "$argument" != -P ] || exit 2\n'
                    'done\n'
                    'exec "$REAL_UNZIP" "$@"\n'
                )
                wrapper.chmod(0o755)
                unsupported_head = binaries / "head"
                unsupported_head.write_text('#!/bin/sh\nprintf "head: unsupported option\\n" >&2\nexit 2\n')
                unsupported_head.chmod(0o755)
                env.update(REAL_UNZIP=shutil.which("unzip"),
                           PATH=str(binaries) + os.pathsep + env["PATH"])
            result = subprocess.run(["sh", str(script)], env=env, capture_output=True,
                                    text=True, timeout=5)
            self.assertEqual(list(scratch.iterdir()), [], "Probe temporary files were not removed")
            self.assertNotIn("private-test", result.stdout + result.stderr)
            return result

    def test_pdf_download_validation_and_cleanup(self):
        result = self.run_pdf_probe()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PDF extracted and validated", result.stdout)

    def test_busybox_without_unzip_password_option_or_head_byte_option(self):
        result = self.run_pdf_probe(busybox=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PDF extracted and validated", result.stdout)

    def test_download_and_pdf_errors_are_explicit(self):
        for options in ({"status": "401"}, {"invalid_zip": True}, {"content": b"not a PDF"}):
            with self.subTest(options=options):
                result = self.run_pdf_probe(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("FAIL:", result.stderr)


if __name__ == "__main__":
    unittest.main()
