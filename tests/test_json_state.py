import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

from zotbridge.config import config_from_dict
from zotbridge.json_state import JsonStateError, JsonStateStore
from zotbridge.locking import BridgeBusyError, import_lock


class JsonStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "nested" / "state.json"
        self.store = JsonStateStore(str(self.path))

    def test_cache_miss_hit_refresh_and_scope(self):
        fetch = Mock(return_value=["two", "one", "one"])
        self.assertEqual(self.store.tags("user:123", "", fetch), ["one", "two"])
        fetch.side_effect = AssertionError("Unexpected network call")
        self.assertEqual(self.store.tags("user:123", "", fetch), ["one", "two"])
        fetch.side_effect = None
        fetch.return_value = []
        self.assertEqual(self.store.tags("user:123", "", fetch, refresh=True), [])
        self.assertEqual(self.store.tags("user:123", "", fetch), [])
        self.store.tags("user:123", "one", fetch)
        self.store.tags("group:123", "", fetch)
        self.assertEqual(fetch.call_count, 4)
        if os.name == "posix":
            self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_existing_records_and_extensions_are_preserved(self):
        self.path.parent.mkdir()
        old = {"version": 1, "mappings": {"ITEM1234": {"rm_uuid": "saved"}},
               "attempts": {"OTHER123": {"state": "uncertain"}}, "future": [1, 2]}
        self.path.write_text(json.dumps(old))
        self.store.tags("user:123", "", lambda: ["one"])
        saved = json.loads(self.path.read_text())
        for key, value in old.items():
            self.assertEqual(saved[key], value)

    def test_tag_refresh_preserves_uuid_keyed_document_records(self):
        self.path.parent.mkdir()
        mappings = {"e90be5e8-32f6-46ec-bb75-32d827af9eee": {
            "zotero_library_type": "user", "zotero_library_id": "123",
            "zotero_item_key": "ITEM1234", "zotero_attachment_key": "PDF12345",
        }}
        self.path.write_text(json.dumps({"version": 1, "mappings": mappings, "attempts": {}}))
        self.store.tags("user:123", "", lambda: ["fresh"], refresh=True)
        self.assertEqual(json.loads(self.path.read_text())["mappings"], mappings)

    def test_failed_fetch_or_replace_keeps_old_file(self):
        self.store.tags("user:123", "", lambda: ["one"])
        original = self.path.read_bytes()
        with self.assertRaises(RuntimeError):
            self.store.tags("user:123", "", Mock(side_effect=RuntimeError("network")), True)
        with patch("zotbridge.json_state.os.replace", side_effect=OSError("disk failure")):
            with self.assertRaises(OSError):
                self.store.tags("user:123", "", lambda: ["new"], True)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(list(self.path.parent.glob("state.json.new.*")), [])

    def test_corrupt_and_unsupported_state_never_reset(self):
        self.path.parent.mkdir()
        for text in ("", "[]", "{broken", '{"version":2,"mappings":{},"attempts":{}}',
                     '{"version":1,"mappings":{},"attempts":{},"tag_cache":null}'):
            with self.subTest(text=text):
                self.path.write_text(text)
                fetch = Mock()
                with self.assertRaises(JsonStateError):
                    self.store.tags("user:123", "", fetch, True)
                fetch.assert_not_called()
                self.assertEqual(self.path.read_text(), text)

    def test_lock_contention_is_explicit(self):
        with import_lock(self.path.with_name(self.path.name + ".lock")):
            with self.assertRaises(BridgeBusyError):
                self.store.tags("user:123", "", lambda: ["one"])
        self.assertFalse(self.path.exists())

    def test_collection_cache_miss_hit_and_refresh(self):
        fetch = Mock(return_value=[{"key": "COLLECTA", "name": "Papers"}])
        self.assertEqual(self.store.collections("user:123", fetch), [{"key": "COLLECTA", "name": "Papers"}])
        fetch.side_effect = AssertionError("Unexpected network call")
        self.assertEqual(self.store.collections("user:123", fetch), [{"key": "COLLECTA", "name": "Papers"}])
        fetch.side_effect = None
        fetch.return_value = [{"key": "COLLECTB", "name": "Notes"}]
        self.assertEqual(
            self.store.collections("user:123", fetch, refresh=True),
            [{"key": "COLLECTB", "name": "Notes"}],
        )

    def test_corrupt_collection_cache_never_reset(self):
        self.path.parent.mkdir()
        self.path.write_text('{"version":1,"mappings":{},"attempts":{},"collection_cache":{"user:123":1}}')
        fetch = Mock()
        with self.assertRaises(JsonStateError):
            self.store.collections("user:123", fetch, True)
        fetch.assert_not_called()


        config_path = Path(self.temp.name) / "config.toml"
        raw = {"library_id": "123", "library_type": "user", "api_key": "fixture",
               "state_db_path": "./custom.db"}
        self.assertEqual(Path(config_from_dict(raw, config_path).state_json_path),
                         config_path.parent / "custom.db.json")
        raw["state_json_path"] = "./bridge.json"
        self.assertEqual(Path(config_from_dict(raw, config_path).state_json_path),
                         config_path.parent / "bridge.json")
        raw["state_json_path"] = "./custom.db"
        with self.assertRaises(ValueError):
            config_from_dict(raw, config_path)

    def test_default_target_folder_configuration(self):
        config_path = Path(self.temp.name) / "config.toml"
        raw = {"library_id": "123", "library_type": "user", "api_key": "fixture"}
        self.assertEqual(config_from_dict(raw, config_path).default_target_folder, "Zotero/unread")
        raw["default_target_folder"] = "Research/inbox"
        self.assertEqual(config_from_dict(raw, config_path).default_target_folder, "Research/inbox")
        for invalid in ("", "/Root", "Root//Child", " \t", "e90be5e8-32f6-46ec-bb75-32d827af9eee"):
            raw["default_target_folder"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                config_from_dict(raw, config_path)

    def test_list_page_limit_configuration(self):
        config_path = Path(self.temp.name) / "config.toml"
        raw = {"library_id": "123", "library_type": "user", "api_key": "fixture"}
        self.assertEqual(config_from_dict(raw, config_path).list_page_limit, 8)
        raw["list_page_limit"] = 42
        self.assertEqual(config_from_dict(raw, config_path).list_page_limit, 42)
        for invalid in (0, 101, -1, "8", 8.5, True):
            raw["list_page_limit"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                config_from_dict(raw, config_path)

    def test_clear_mappings_only_removes_the_selected_library(self):
        self.path.parent.mkdir()
        previous = {
            "version": 1,
            "mappings": {
                "document-one": {"zotero_library_type": "user", "zotero_library_id": "123"},
                "document-two": {"zotero_library_type": "user", "zotero_library_id": "456"},
                "document-three": {"zotero_library_type": "group", "zotero_library_id": "123"},
                "legacy": {"rm_uuid": "unscoped"},
            },
            "attempts": {"user:123": {"ITEM1234": {"state": "uncertain"}}},
            "tag_cache": {"user:123": {"": {"fetched_at": 100, "tags": ["one"]}}},
            "future": {"keep": True},
        }
        self.path.write_text(json.dumps(previous))
        self.assertEqual(self.store.clear_mappings("user", "123"), 1)
        current = json.loads(self.path.read_text())
        expected = json.loads(json.dumps(previous))
        expected.setdefault("collection_cache", {})
        del expected["mappings"]["document-one"]
        self.assertEqual(current, expected)
        unchanged = self.path.read_bytes()
        self.assertEqual(self.store.clear_mappings("user", "123"), 0)
        self.assertEqual(self.path.read_bytes(), unchanged)

    def test_clear_missing_state_is_a_noop(self):
        self.assertEqual(self.store.clear_mappings("user", "123"), 0)
        self.assertFalse(self.path.exists())

    def test_clear_failure_does_not_change_state(self):
        self.path.parent.mkdir()
        previous = {"version": 1, "mappings": {
            "document": {"zotero_library_type": "user", "zotero_library_id": "123"}
        }, "attempts": {}}
        self.path.write_text(json.dumps(previous))
        original = self.path.read_bytes()
        with patch("zotbridge.json_state.os.replace", side_effect=OSError("disk failure")):
            with self.assertRaises(OSError):
                self.store.clear_mappings("user", "123")
        self.assertEqual(self.path.read_bytes(), original)
        with import_lock(self.path.with_name(self.path.name + ".lock")):
            with self.assertRaises(BridgeBusyError):
                self.store.clear_mappings("user", "123")
        self.assertEqual(self.path.read_bytes(), original)
        previous["mappings"]["document"] = 42
        self.path.write_text(json.dumps(previous))
        with self.assertRaises(JsonStateError):
            self.store.clear_mappings("user", "123")
        self.assertEqual(json.loads(self.path.read_text()), previous)


if __name__ == "__main__":
    unittest.main()
