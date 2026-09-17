from pathlib import Path
import os
import tempfile
import unittest
from unittest.mock import patch

from zotbridge.config import load_config
from zotbridge.locking import BridgeBusyError, import_lock
from zotbridge.state import StateStore


class CoreTests(unittest.TestCase):
    def test_config_paths_are_relative_to_config_not_working_directory(self):
        with tempfile.TemporaryDirectory() as td:
            config = Path(td) / "config.toml"
            config.write_text('library_id="123"\nlibrary_type="user"\napi_key="test"\n')
            with patch.dict(os.environ, {"ZOTBRIDGE_CONFIG": str(config)}):
                self.assertEqual(load_config().state_db_path, str(Path(td) / "zotbridge-state.db"))

    def test_invalid_config_values_are_rejected(self):
        for extra in ('library_type="invalid"', 'library_type="user"\nbroker_timeout_s=0'):
            with self.subTest(extra=extra), tempfile.TemporaryDirectory() as td:
                config = Path(td) / "config.toml"
                config.write_text('library_id="123"\napi_key="test"\n' + extra)
                with patch.dict(os.environ, {"ZOTBRIDGE_CONFIG": str(config)}):
                    with self.assertRaises(ValueError):
                        load_config()

    def test_lock_excludes_second_run_and_releases_after_failure(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "import.lock"
            with self.assertRaisesRegex(RuntimeError, "operation failed"):
                with import_lock(path):
                    with self.assertRaises(BridgeBusyError):
                        with import_lock(path):
                            self.fail("second run acquired lock")
                    raise RuntimeError("operation failed")
            with import_lock(path):
                pass

    def test_attempt_persists_until_mapping_is_saved(self):
        with tempfile.TemporaryDirectory() as td:
            db = str(Path(td) / "state.db")
            store = StateStore(db)
            store.begin_import("ITEM1234", "PDF12345", "Zotero/unread")
            self.assertEqual(StateStore(db).get_attempt("ITEM1234")["state"], "uncertain")
            store.upsert_mapping("ITEM1234", "PDF12345", "uuid", "Zotero/unread", "imported")
            self.assertIsNone(store.get_attempt("ITEM1234"))
            self.assertEqual(store.get_mapping("ITEM1234")["rm_uuid"], "uuid")


if __name__ == "__main__":
    unittest.main()
