from pathlib import Path
import unittest
from unittest.mock import Mock

from zotbridge.zotero_client import ZoteroBridge, tag_expression


class ZoteroTests(unittest.TestCase):
    def setUp(self):
        self.bridge = ZoteroBridge.__new__(ZoteroBridge)
        self.bridge.zot = Mock()
        self.bridge.zot.request.headers = {"Total-Results": "1"}
        self.bridge.webdav = None
        self.bridge.zot.everything.side_effect = lambda items: items
        self.bridge.zot.item.return_value = {"data": {"title": "A paper: with / separators"}}
        self.bridge.zot.children.return_value = [
            {"data": {"key": "LINKED12", "contentType": "application/pdf", "linkMode": "linked_file"}},
            {"data": {"key": "HOSTED12", "contentType": "application/pdf", "linkMode": "imported_file"}},
        ]

    def test_search_includes_books_and_uses_parent_items(self):
        self.bridge.zot.top.return_value = [
            {"data": {"key": "BOOK1234", "itemType": "book", "title": "A book", "date": "2020"},
             "meta": {"numChildren": 1}}
        ]
        papers = self.bridge.search("book", limit=5)
        self.bridge.zot.top.assert_called_once_with(
            q="book", limit=5, start=0, sort="dateModified", direction="desc",
            itemType="-attachment || note || annotation",
        )
        self.assertEqual(papers[0].title, "A book")
        self.assertTrue(papers[0].has_pdf)
        self.bridge.zot.children.assert_not_called()

    def test_has_pdf_reflects_numchildren_without_a_children_request(self):
        self.bridge.zot.top.return_value = [
            {"data": {"key": "BOOK1234", "itemType": "book", "title": "No children"},
             "meta": {"numChildren": 0}},
            {"data": {"key": "BOOK5678", "itemType": "book", "title": "Missing meta"}},
        ]
        papers = self.bridge.search("book", limit=5)
        self.assertFalse(papers[0].has_pdf)
        self.assertFalse(papers[1].has_pdf)
        self.bridge.zot.children.assert_not_called()

    def test_or_tags_and_pagination_preserve_the_item_total(self):
        self.bridge.zot.top.return_value = [
            {"data": {"key": "BOOK1234", "itemType": "book", "title": "A book"}}
        ]
        self.bridge.zot.request.headers = {"Total-Results": "3"}
        def children(key):
            self.bridge.zot.request.headers = {"Total-Results": "99"}
            return []
        self.bridge.zot.children.side_effect = children
        page = self.bridge.search_page("book", limit=1, skip=1, tags=["machine learning", "-review"])
        self.assertEqual(page.total, 3)
        self.assertEqual(page.next_skip, 2)
        self.assertEqual(self.bridge.zot.top.call_args.kwargs["tag"], "machine learning || -review")
        self.assertEqual(self.bridge.zot.top.call_args.kwargs["start"], 1)

    def test_last_empty_and_invalid_pages(self):
        self.bridge.zot.top.return_value = []
        self.assertIsNone(self.bridge.search_page("", skip=1).next_skip)
        with self.assertRaisesRegex(RuntimeError, "empty page"):
            self.bridge.search_page("")
        self.bridge.zot.request.headers = {}
        with self.assertRaisesRegex(RuntimeError, "Total-Results"):
            self.bridge.search_page("")

    def test_literal_tag_validation(self):
        self.assertEqual(tag_expression(["one", "two words"]), "one || two words")
        self.assertEqual(tag_expression(["-review", "one"]), "\\-review || one")
        for tags in ([""], ["one||two"], ["\\-literal"], ["new\nline"]):
            with self.subTest(tags=tags), self.assertRaises(ValueError):
                tag_expression(tags)

    def test_tags_fetch_all_pages_and_sort_unique_names(self):
        self.bridge.zot.tags.return_value = ["z"]
        self.bridge.zot.everything.side_effect = None
        self.bridge.zot.everything.return_value = ["z", "a", "z"]
        self.assertEqual(self.bridge.list_tags(""), ["a", "z"])
        self.bridge.zot.tags.assert_called_once_with(q="", limit=100)
        self.bridge.zot.everything.assert_called_once_with(["z"])

    def test_list_pdf_attachments_returns_only_stored_pdfs(self):
        self.bridge.zot.children.return_value = [
            {"data": {"key": "LINKED12", "contentType": "application/pdf", "linkMode": "linked_file"}},
            {"data": {"key": "HOSTED12", "contentType": "application/pdf", "linkMode": "imported_file",
                      "title": "Paper.pdf"}},
            {"data": {"key": "NOTEEE12", "itemType": "note"}},
        ]
        attachments = self.bridge.list_pdf_attachments("BOOK1234")
        self.assertEqual(len(attachments), 1)
        self.assertEqual(attachments[0].attachment_key, "HOSTED12")
        self.assertEqual(attachments[0].title, "Paper.pdf")

    def test_download_attachment_rejects_wrong_parent_or_non_pdf(self):
        self.bridge.zot.item.return_value = {"data": {
            "key": "HOSTED12", "parentItem": "OTHER123", "contentType": "application/pdf",
            "linkMode": "imported_file",
        }}
        with self.assertRaisesRegex(RuntimeError, "not a stored PDF"):
            with self.bridge.download_attachment("BOOK1234", "HOSTED12"):
                self.fail("mismatched parent accepted")

    def test_download_attachment_downloads_a_specific_attachment(self):
        self.bridge.zot.item.side_effect = lambda key: (
            {"data": {"key": "HOSTED12", "parentItem": "BOOK1234", "contentType": "application/pdf",
                      "linkMode": "imported_file", "filename": "Paper.pdf"}}
            if key == "HOSTED12" else {"data": {"title": "A paper"}}
        )
        self.bridge.zot.dump.side_effect = lambda key, filename, path: (
            Path(path) / filename
        ).write_bytes(b"%PDF-1.7\nexample")
        with self.bridge.download_attachment("BOOK1234", "HOSTED12") as (path, key):
            self.assertEqual(key, "HOSTED12")
            self.assertTrue(path.exists())

    def test_download_is_private_and_cleaned_after_consumer_error(self):
        def dump(key, filename, path):
            self.assertEqual(key, "HOSTED12")
            (Path(path) / filename).write_bytes(b"%PDF-1.7\nexample")

        self.bridge.zot.dump.side_effect = dump
        with self.assertRaisesRegex(RuntimeError, "import failed"):
            with self.bridge.download_first_pdf("BOOK1234") as (path, key):
                self.assertTrue(path.exists())
                self.assertEqual(path.name, "A paper_ with _ separators.pdf")
                self.assertEqual(key, "HOSTED12")
                raise RuntimeError("import failed")
        self.assertFalse(path.exists())

    def test_invalid_download_is_rejected(self):
        self.bridge.zot.dump.side_effect = lambda key, filename, path: (
            Path(path) / filename
        ).write_text("<html>login</html>")
        with self.assertRaisesRegex(RuntimeError, "not a PDF"):
            with self.bridge.download_first_pdf("BOOK1234"):
                self.fail("invalid PDF accepted")

    def test_linked_only_pdf_is_not_downloadable(self):
        self.bridge.zot.children.return_value = self.bridge.zot.children.return_value[:1]
        with self.assertRaisesRegex(RuntimeError, "No stored PDF"):
            with self.bridge.download_first_pdf("BOOK1234"):
                self.fail("linked PDF accepted")

    def test_webdav_download_does_not_use_zotero_file_storage(self):
        self.bridge.webdav = Mock()
        self.bridge.webdav.download_pdf.side_effect = lambda key, filename, path: path.write_bytes(
            b"%PDF-1.7\nWebDAV"
        )
        with self.bridge.download_first_pdf("BOOK1234") as (path, key):
            self.assertEqual(path.read_bytes(), b"%PDF-1.7\nWebDAV")
            self.assertEqual(key, "HOSTED12")
        self.bridge.webdav.download_pdf.assert_called_once()
        self.bridge.zot.dump.assert_not_called()
        self.assertFalse(path.exists())

    def test_webdav_failure_never_falls_back_to_zotero_storage(self):
        self.bridge.webdav = Mock()
        self.bridge.webdav.download_pdf.side_effect = RuntimeError("WebDAV unavailable")
        with self.assertRaisesRegex(RuntimeError, "WebDAV unavailable"):
            with self.bridge.download_first_pdf("BOOK1234"):
                self.fail("Failed WebDAV download accepted")
        self.bridge.zot.dump.assert_not_called()


if __name__ == "__main__":
    unittest.main()
