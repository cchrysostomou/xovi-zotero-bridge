import hashlib
from pathlib import Path
import struct
import unittest
import zipfile


PACKAGE = Path(__file__).resolve().parents[1] / "dist" / "xovi-zotero-library-aarch64.zip"


@unittest.skipUnless(PACKAGE.exists(), "Build the tablet archive with scripts/package-tablet.ps1 first")
class TabletPackageTests(unittest.TestCase):
    def test_packaged_runtime_matches_current_source(self):
        root = PACKAGE.parents[1]
        with zipfile.ZipFile(PACKAGE) as package:
            for name in ("scripts/zotbridge-run.sh", "scripts/zotbridge-shell.sh",
                         "scripts/zotbridge-shell-config.jq", "scripts/zotbridge-shell-mapping.jq",
                         "scripts/zotbridge-shell-zip.jq", "scripts/zotbridge-shell-sync.sh",
                         "scripts/zotbridge-shell-reverse.sh",
                         "scripts/zotbridge-shell-settings.jq"):
                self.assertEqual(package.read(name).decode("utf-8"),
                                 (root / name).read_text(encoding="utf-8"))

    def test_contains_only_tablet_runtime_and_not_credentials(self):
        with zipfile.ZipFile(PACKAGE) as package:
            names = set(package.namelist())
            self.assertTrue({
                "scripts/zotbridge-run.sh", "scripts/zotbridge-shell.sh",
                "scripts/zotbridge-shell-config.jq",
                "scripts/zotbridge-shell-mapping.jq",
                "scripts/zotbridge-shell-zip.jq",
                "scripts/zotbridge-shell-sync.sh",
                "scripts/zotbridge-shell-reverse.sh",
                "scripts/zotbridge-shell-settings.jq",
                "bin/jq", "bin/rmapi", "bin/7zz", "config.example.toml", "README.md",
                "licenses/jq-COPYING", "licenses/oniguruma-COPYING", "licenses/musl-COPYRIGHT",
                "licenses/rmapi-AGPL-3.0.txt", "licenses/7zip-License.txt",
            }.issubset(names))
            self.assertNotIn("scripts/check-pdf-download.sh", names)
            self.assertNotIn("scripts/zotbridge-shell-library.jq", names)
            for name in names:
                self.assertNotIn("\\", name)
                self.assertNotIn("..", Path(name).parts)
                self.assertNotEqual(name, "config.toml")
                self.assertFalse(name.endswith((".db", ".db.json", ".py", ".pyc")))
                self.assertNotIn(".venv", name)

    def test_shell_files_have_linux_line_endings_and_executable_bits(self):
        with zipfile.ZipFile(PACKAGE) as package:
            for entry in package.infolist():
                if entry.filename.endswith(".sh"):
                    data = package.read(entry)
                    self.assertNotIn(b"\r", data)
                    self.assertTrue(data.startswith(b"#!"))
                    self.assertEqual((entry.external_attr >> 16) & 0o777, 0o755)

    def test_jq_is_the_verified_static_arm64_binary(self):
        with zipfile.ZipFile(PACKAGE) as package:
            data = package.read("bin/jq")
            self.assertEqual(hashlib.sha256(data).hexdigest(),
                             "8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309")
            self.assertEqual(data[:4], b"\x7fELF")
            self.assertEqual(struct.unpack_from("<H", data, 18)[0], 183)
            offset = struct.unpack_from("<Q", data, 32)[0]
            size, count = struct.unpack_from("<HH", data, 54)
            self.assertFalse(any(struct.unpack_from("<I", data, offset + i * size)[0] == 3
                                 for i in range(count)))
            self.assertEqual((package.getinfo("bin/jq").external_attr >> 16) & 0o777, 0o755)

    def test_rmapi_is_the_pinned_arm64_release_binary(self):
        with zipfile.ZipFile(PACKAGE) as package:
            data = package.read("bin/rmapi")
            self.assertEqual(hashlib.sha256(data).hexdigest(),
                             "544da553a210051e5d0ade2bd24d16c30fa6fa7236215b460c6b7f6d62ec3029")
            self.assertEqual(data[:4], b"\x7fELF")
            self.assertEqual(struct.unpack_from("<H", data, 18)[0], 183)
            self.assertEqual((package.getinfo("bin/rmapi").external_attr >> 16) & 0o777, 0o755)

    def test_7zz_is_the_pinned_arm64_release_binary(self):
        with zipfile.ZipFile(PACKAGE) as package:
            data = package.read("bin/7zz")
            self.assertEqual(hashlib.sha256(data).hexdigest(),
                             "9a26e7d54bfdae8a8f1750cdb70697547b738c2334aa89f3d3f2c8645c8443fe")
            self.assertEqual(data[:4], b"\x7fELF")
            self.assertEqual(struct.unpack_from("<H", data, 18)[0], 183)
            self.assertEqual((package.getinfo("bin/7zz").external_attr >> 16) & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
