import json
from pathlib import Path
import tempfile
import unittest

from zotbridge.library import RemarkableLibrary


FOLDER_ID = "e90be5e8-32f6-46ec-bb75-32d827af9eee"
DOCUMENT_ID = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"


class LibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.library = RemarkableLibrary(str(self.root))

    def entry(self, entry_id, title, parent, entry_type):
        (self.root / f"{entry_id}.metadata").write_text(json.dumps(
            {"visibleName": title, "parent": parent, "type": entry_type}
        ))

    def test_tree_paths_and_trashed_ancestors(self):
        self.entry(FOLDER_ID, "Zotero", "", "CollectionType")
        self.entry(DOCUMENT_ID, "Paper", FOLDER_ID, "DocumentType")
        result = self.library.list_entries()
        self.assertEqual([entry["path"] for entry in result["entries"]], ["Zotero", "Zotero/Paper"])
        self.assertEqual(result["warnings"], [])
        self.entry(FOLDER_ID, "Zotero", "trash", "CollectionType")
        self.assertEqual(self.library.list_entries()["entries"], [])

    def test_malformed_files_and_cycles_produce_visible_warnings(self):
        self.entry(FOLDER_ID, "Folder", DOCUMENT_ID, "CollectionType")
        self.entry(DOCUMENT_ID, "Document", FOLDER_ID, "DocumentType")
        (self.root / "invalid.metadata").write_text("{")
        result = self.library.list_entries()
        self.assertEqual(result["entries"], [])
        self.assertEqual(len(result["warnings"]), 3)

    def test_verify_import_requires_real_pdf_and_matching_metadata(self):
        self.entry(DOCUMENT_ID, "Paper", FOLDER_ID, "DocumentType")
        (self.root / f"{DOCUMENT_ID}.content").write_text('{"fileType":"pdf"}')
        pdf = self.root / f"{DOCUMENT_ID}.pdf"
        pdf.write_bytes(b"%PDF-1.7\n")
        self.library.verify_import(DOCUMENT_ID, FOLDER_ID)
        pdf.write_text("not a pdf")
        with self.assertRaisesRegex(RuntimeError, "invalid"):
            self.library.verify_import(DOCUMENT_ID, FOLDER_ID)

    def test_missing_directory_is_not_an_empty_success(self):
        with self.assertRaises(FileNotFoundError):
            RemarkableLibrary(str(self.root / "missing")).list_entries()


if __name__ == "__main__":
    unittest.main()
