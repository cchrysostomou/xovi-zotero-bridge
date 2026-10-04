import io
import os
from pathlib import Path
import struct
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "dist" / "vellum" / "xovi-zotero-bridge-0.1.0-aarch64.tar.gz"
RUNTIME = "home/root/xovi-zotero-bridge"
LICENSES = "home/root/.vellum/licenses/zotero-remarkable-sync"


@unittest.skipUnless(ARCHIVE.exists(), "Build with scripts/package-vellum.ps1 -Local first")
class VellumPackagingTests(unittest.TestCase):
    def test_runtime_binaries_are_executable_arm64(self):
        with tarfile.open(ARCHIVE) as archive:
            for tool in ("jq", "7zz", "zotbridge-localgeta"):
                member = archive.getmember(f"{RUNTIME}/bin/{tool}")
                self.assertEqual(member.mode, 0o755)
                stream = archive.extractfile(member)
                self.assertIsNotNone(stream)
                header = stream.read(64)
                self.assertEqual(header[:4], b"\x7fELF")
                self.assertEqual(struct.unpack_from("<H", header, 18)[0], 183)

    def test_corresponding_source_includes_dependency_licenses(self):
        with tarfile.open(ARCHIVE) as archive:
            stream = archive.extractfile(f"{LICENSES}/helper-source.tar.gz")
            self.assertIsNotNone(stream)
            with tarfile.open(fileobj=io.BytesIO(stream.read())) as source:
                names = set(source.getnames())
                for name in (
                    "./BUILD-INFO", "./go.mod", "./go.sum", "./LICENSE",
                    "./cmd/zotbridge-localgeta/main.go", "./vendor/modules.txt",
                    "./vendor/github.com/unidoc/unipdf/v3/LICENSE.AGPL",
                    "./vendor/github.com/golang/freetype/licenses/gpl.txt",
                    "./vendor/gopkg.in/yaml.v2/LICENSE",
                ):
                    self.assertIn(name, names)

    @unittest.skipUnless(os.name == "nt", "PowerShell archive verification runs on Windows")
    def test_verifier_accepts_payload_and_rejects_personal_config(self):
        command = ["powershell", "-ExecutionPolicy", "Bypass", "-File",
                   str(ROOT / "scripts" / "verify-vellum-package.ps1"), "-Archive"]
        result = subprocess.run(command + [str(ARCHIVE)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with tempfile.TemporaryDirectory() as directory:
            unsafe = Path(directory) / "unsafe.tar.gz"
            with tarfile.open(ARCHIVE) as source, tarfile.open(unsafe, "w:gz") as target:
                for member in source.getmembers():
                    target.addfile(member, source.extractfile(member) if member.isfile() else None)
                member = tarfile.TarInfo(f"{RUNTIME}/config.toml")
                member.mode = 0o644
                member.size = 4
                target.addfile(member, io.BytesIO(b"test"))
            result = subprocess.run(command + [str(unsafe)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("exact allowed file list", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
