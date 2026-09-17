import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
JQ = os.environ.get("ZOTBRIDGE_JQ") or shutil.which("jq")
UUID = "e90be5e8-32f6-46ec-bb75-32d827af9eee"
OTHER_UUID = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
SOURCE = '"user"; "123"; "ITEM1234"; "PDF12345"; "Zotero/unread"'


@unittest.skipUnless(os.name == "posix" and JQ, "Requires Linux and jq")
class ShellMappingTests(unittest.TestCase):
    def setUp(self):
        self.state = {
            "version": 1, "mappings": {}, "attempts": {},
            "tag_cache": {"user:123": {"": {"fetched_at": 100, "tags": ["one"]}}},
        }

    def evaluate(self, expression, state=None, success=True):
        result = subprocess.run(
            [JQ, "-L", str(ROOT / "scripts"), 'include "zotbridge-shell-mapping"; ' + expression],
            input=json.dumps(self.state if state is None else state),
            text=True, capture_output=True, timeout=10,
        )
        if not success:
            self.assertNotEqual(result.returncode, 0)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_attempt_is_not_a_document_mapping(self):
        attempted = self.evaluate(f"record_attempt({SOURCE})")
        self.assertEqual(attempted["mappings"], {})
        self.assertEqual(attempted["attempts"]["user:123"]["ITEM1234"]["state"], "uncertain")
        self.assertEqual(attempted["tag_cache"], self.state["tag_cache"])

    def test_mapping_is_uuid_keyed_and_keeps_zotero_identifiers(self):
        attempted = self.evaluate(f"record_attempt({SOURCE})")
        mapped = self.evaluate(f'record_mapping({SOURCE}; "{UUID}")', attempted)
        self.assertEqual(set(mapped["mappings"]), {UUID})
        entry = mapped["mappings"][UUID]
        self.assertEqual(entry["zotero_library_type"], "user")
        self.assertEqual(entry["zotero_library_id"], "123")
        self.assertEqual(entry["zotero_item_key"], "ITEM1234")
        self.assertEqual(entry["zotero_attachment_key"], "PDF12345")
        self.assertEqual(entry["state"], "imported")
        self.assertNotIn("ITEM1234", mapped["attempts"]["user:123"])
        self.assertEqual(mapped["tag_cache"], self.state["tag_cache"])
        found = self.evaluate('mapping_for_item("user"; "123"; "ITEM1234")', mapped)
        self.assertEqual(found["rm_uuid"], UUID)
        self.assertIsNone(self.evaluate('mapping_for_item("group"; "123"; "ITEM1234")', mapped))

    def test_same_item_key_in_different_libraries_does_not_collide(self):
        mapped = self.evaluate(f'record_mapping({SOURCE}; "{UUID}")')
        group_source = SOURCE.replace('"user"', '"group"')
        mapped = self.evaluate(f'record_mapping({group_source}; "{OTHER_UUID}")', mapped)
        self.assertEqual(set(mapped["mappings"]), {UUID, OTHER_UUID})
        found = self.evaluate('mapping_for_item("group"; "123"; "ITEM1234")', mapped)
        self.assertEqual(found["rm_uuid"], OTHER_UUID)

    def test_invalid_or_conflicting_ids_fail_instead_of_overwriting(self):
        self.evaluate(f'record_mapping({SOURCE}; "ITEM1234")', success=False)
        mapped = self.evaluate(f'record_mapping({SOURCE}; "{UUID}")')
        self.evaluate(f'record_mapping({SOURCE}; "{OTHER_UUID}")', mapped, success=False)
        different = SOURCE.replace("ITEM1234", "OTHER123")
        self.evaluate(f'record_mapping({different}; "{UUID}")', mapped, success=False)

    def test_legacy_records_are_not_silently_ignored_or_migrated(self):
        self.state["mappings"] = {"ITEM1234": {"rm_uuid": UUID}}
        self.evaluate('mapping_for_item("user"; "123"; "ITEM1234")', success=False)
        self.state["mappings"] = {}
        self.state["attempts"] = {"ITEM1234": {"state": "uncertain"}}
        self.evaluate('mapping_for_item("user"; "123"; "ITEM1234")', success=False)

    def test_attachment_lookup_and_cross_source_duplicate_protection(self):
        mapped = self.evaluate(f'record_mapping({SOURCE}; "{UUID}")')
        found = self.evaluate('mapping_for_item("user"; "123"; "PDF12345")', mapped)
        self.assertEqual(found["rm_uuid"], UUID)
        self.assertEqual(self.evaluate('mapping_for_attachment("user"; "123"; "PDF12345")', mapped), found)
        direct = SOURCE.replace("ITEM1234", "PDF12345")
        self.evaluate(f'record_mapping({direct}; "{OTHER_UUID}")', mapped, success=False)
        second = SOURCE.replace("ITEM1234", "PDF56789").replace("PDF12345", "PDF56789")
        mapped = self.evaluate(f'record_mapping({second}; "{OTHER_UUID}")', mapped)
        self.assertEqual(len(mapped["mappings"]), 2)

    def test_confirming_pdf_clears_attempts_for_same_attachment_only(self):
        attempted = self.evaluate(f"record_attempt({SOURCE})")
        direct = SOURCE.replace("ITEM1234", "PDF12345")
        mapped = self.evaluate(f'record_mapping({direct}; "{UUID}")', attempted)
        self.assertEqual(mapped["attempts"]["user:123"], {})

    def test_clear_only_the_selected_library(self):
        mapped = self.evaluate(f'record_mapping({SOURCE}; "{UUID}")')
        other = SOURCE.replace('"user"', '"group"')
        mapped = self.evaluate(f'record_mapping({other}; "{OTHER_UUID}")', mapped)
        cleared = self.evaluate('clear_mappings("user"; "123")', mapped)
        self.assertEqual(set(cleared["mappings"]), {OTHER_UUID})
        self.assertEqual(cleared["tag_cache"], mapped["tag_cache"])
        self.assertEqual(cleared["attempts"], mapped["attempts"])


if __name__ == "__main__":
    unittest.main()
