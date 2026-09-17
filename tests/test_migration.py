import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


@unittest.skipUnless(importlib.util.find_spec("yaml"), "One-time migration tests require PyYAML")
class MigrationTests(unittest.TestCase):
    def test_private_migration_preserves_secrets_and_refuses_overwrite(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "legacy.yml"
            destination = Path(td) / "config.toml"
            content = (
                'LIBRARY_ID: 123\nLIBRARY_TYPE: user\nAPI_KEY: "secret-key"\n'
                'USE_WEBDAV: "True"\nWEBDAV_HOSTNAME: https://dav.example/zotero/\n'
                'WEBDAV_USER: reader\nWEBDAV_PWD: "secret-password"\n'
            )
            source.write_text(content, encoding="utf-8")
            command = [sys.executable, str(root / "scripts" / "import-legacy-config.py"),
                       str(source), str(destination)]
            env = dict(os.environ, PYTHONPATH=str(root / "src"))
            result = subprocess.run(command, capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("secret-key", result.stdout + result.stderr)
            self.assertNotIn("secret-password", result.stdout + result.stderr)
            data = tomllib.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(data["api_key"], "secret-key")
            self.assertEqual(data["webdav_password"], "secret-password")
            self.assertTrue(data["use_webdav"])
            self.assertEqual(source.read_text(encoding="utf-8"), content)
            if os.name == "posix":
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            before = destination.read_bytes()
            second = subprocess.run(command, capture_output=True, text=True, env=env)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(destination.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
