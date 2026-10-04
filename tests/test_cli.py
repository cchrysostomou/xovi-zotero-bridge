from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import httpx2
from typer.testing import CliRunner

from zotbridge.cli import app
from zotbridge.state import StateStore
from zotbridge.zotero_client import Attachment, Collection, LibraryPage, Paper


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        config = self.root / "config.toml"
        config.write_text('library_id="123"\nlibrary_type="user"\napi_key="test"\n')
        env = patch.dict(os.environ, {"ZOTBRIDGE_CONFIG": str(config)})
        env.start()
        self.addCleanup(env.stop)
        self.runner = CliRunner()
        self.store = StateStore(str(self.root / "zotbridge-state.db"))
        library = patch("zotbridge.cli.RemarkableLibrary")
        self.library = library.start()
        self.addCleanup(library.stop)

    @contextmanager
    def download(self, item_key):
        path = self.root / "document.pdf"
        path.write_bytes(b"%PDF-1.7\n")
        try:
            yield path, "PDF12345"
        finally:
            path.unlink()

    @contextmanager
    def download_attachment(self, item_key, attachment_key):
        path = self.root / "document.pdf"
        path.write_bytes(b"%PDF-1.7\n")
        try:
            yield path, attachment_key
        finally:
            path.unlink()

    def test_import_records_mapping_and_repeated_import_does_no_work(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            librarian.return_value.ensure_folder.return_value = "folder-uuid"
            librarian.return_value.import_document.return_value = "document-uuid"
            first = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
            self.assertEqual(first.exit_code, 0, first.output)
            self.assertEqual(json.loads(first.output)["rm_uuid"], "document-uuid")
            second = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
            self.assertEqual(second.exit_code, 0, second.output)
            self.assertTrue(json.loads(second.output)["already_imported"])
            librarian.return_value.import_document.assert_called_once()
            zotero.assert_called_once()
        self.assertFalse((self.root / "document.pdf").exists())

    def test_import_with_attachment_key_downloads_that_specific_attachment(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_attachment.side_effect = self.download_attachment
            librarian.return_value.ensure_folder.return_value = "folder-uuid"
            librarian.return_value.import_document.return_value = "document-uuid"
            result = self.runner.invoke(
                app, ["import", "--item-key", "ITEM1234", "--attachment-key", "PDF12345"]
            )
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertEqual(json.loads(result.output)["attachment_key"], "PDF12345")
            zotero.return_value.download_attachment.assert_called_once_with("ITEM1234", "PDF12345")
            zotero.return_value.download_first_pdf.assert_not_called()

    def test_children_lists_downloadable_pdf_attachments(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.list_pdf_attachments.return_value = [
                Attachment(attachment_key="PDF12345", title="Paper.pdf"),
            ]
            result = self.runner.invoke(app, ["children", "--item-key", "ITEM1234", "--json"])
        self.assertEqual(result.exit_code, 0, result.output)
        payload = json.loads(result.output)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["attachments"], [{"attachment_key": "PDF12345", "title": "Paper.pdf"}])

    def test_timeout_keeps_uncertain_attempt_and_blocks_automatic_retry(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            librarian.return_value.import_document.side_effect = TimeoutError("No response")
            first = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
            self.assertEqual(first.exit_code, 1, first.output)
            self.assertEqual(json.loads(first.output)["error"], "TimeoutError")
            self.assertIsNone(self.store.get_mapping("ITEM1234"))
            second = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
            self.assertEqual(second.exit_code, 1, second.output)
            self.assertIn("--retry-uncertain", json.loads(second.output)["message"])
            librarian.return_value.import_document.assert_called_once()
            status = self.runner.invoke(app, ["status", "--item-key", "ITEM1234"])
            self.assertEqual(json.loads(status.output)["error"], "import_uncertain")
        self.assertFalse((self.root / "document.pdf").exists())

    def test_missing_config_is_json_error(self):
        (self.root / "config.toml").unlink()
        result = self.runner.invoke(app, ["list", "--json"])
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(json.loads(result.output)["error"], "FileNotFoundError")

    def test_invalid_item_key_never_contacts_zotero(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            result = self.runner.invoke(app, ["import", "--item-key", "bad;key"])
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(json.loads(result.output)["error"], "ValueError")
        zotero.assert_not_called()

    def test_folder_failure_does_not_mark_import_as_started(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            librarian.return_value.ensure_folder.side_effect = TimeoutError("No folder response")
            result = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
        self.assertEqual(result.exit_code, 1, result.output)
        self.assertIsNone(self.store.get_attempt("ITEM1234"))

    def test_import_configured_folder_and_cli_override(self):
        with (self.root / "config.toml").open("a") as config:
            config.write('default_target_folder = "Research/inbox"\n')
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            librarian.return_value.ensure_folder.return_value = "folder-uuid"
            librarian.return_value.import_document.return_value = "document-uuid"
            result = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
            self.assertEqual(result.exit_code, 0, result.output)
            librarian.return_value.ensure_folder.assert_called_with("Research/inbox")
            override = self.runner.invoke(app, [
                "import", "--item-key", "ITEM5678", "--target-folder", "Manual/inbox",
            ])
            self.assertEqual(override.exit_code, 0, override.output)
            librarian.return_value.ensure_folder.assert_called_with("Manual/inbox")

    def test_ensure_folder_does_not_contact_zotero_or_import(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            librarian.return_value.ensure_folder.return_value = "e90be5e8-32f6-46ec-bb75-32d827af9eee"
            result = self.runner.invoke(app, ["ensure-folder", "--target-folder", "Zotero/Test"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(json.loads(result.output), {
            "ok": True, "folder_path": "Zotero/Test",
            "folder_uuid": "e90be5e8-32f6-46ec-bb75-32d827af9eee",
        })
        librarian.return_value.ensure_folder.assert_called_once_with("Zotero/Test")
        librarian.return_value.import_document.assert_not_called()
        zotero.assert_not_called()

    def test_network_failure_is_json_without_request_details(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.search_page.side_effect = httpx2.ConnectError("private request details")
            result = self.runner.invoke(app, ["list", "--json"])
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(json.loads(result.output)["error"], "zotero_error")
        self.assertNotIn("private request details", result.output)

    def test_explicit_retry_replaces_uncertainty_with_mapping(self):
        self.store.begin_import("ITEM1234", "PDF12345", "Zotero/unread")
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            librarian.return_value.import_document.return_value = "document-uuid"
            result = self.runner.invoke(app, ["import", "--item-key", "ITEM1234", "--retry-uncertain"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertIsNone(self.store.get_attempt("ITEM1234"))
        self.assertEqual(self.store.get_mapping("ITEM1234")["rm_uuid"], "document-uuid")

    def test_failed_destination_verification_is_not_a_successful_import(self):
        self.library.return_value.verify_import.side_effect = RuntimeError("Missing PDF")
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            librarian.return_value.import_document.return_value = "document-uuid"
            result = self.runner.invoke(app, ["import", "--item-key", "ITEM1234"])
        self.assertEqual(result.exit_code, 1, result.output)
        self.assertIsNone(self.store.get_mapping("ITEM1234"))
        self.assertIsNotNone(self.store.get_attempt("ITEM1234"))

    def test_connection_check_does_not_import_or_save_state(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            zotero.return_value.download_first_pdf.side_effect = self.download
            result = self.runner.invoke(app, ["check-connection", "--item-key", "ITEM1234"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(json.loads(result.output)["pdf_download"], "verified")
        librarian.assert_not_called()
        self.assertIsNone(self.store.get_mapping("ITEM1234"))
        self.assertIsNone(self.store.get_attempt("ITEM1234"))
        self.assertFalse((self.root / "document.pdf").exists())

    def test_metadata_check_does_not_claim_pdf_access(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            result = self.runner.invoke(app, ["check-connection"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(json.loads(result.output)["pdf_download"], "not_tested")
        zotero.return_value.check_metadata.assert_called_once()
        zotero.return_value.download_first_pdf.assert_not_called()

    def test_filtered_page_api_and_array_compatibility(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.search_page.return_value = LibraryPage(
                [Paper("ITEM1234", "Paper", "2024", True, 1)], 5, 5, 6, None
            )
            result = self.runner.invoke(app, [
                "list", "--tag", "one", "--tag", "two", "--skip", "5", "--limit", "5", "--page-info",
            ])
            self.assertEqual(result.exit_code, 0, result.output)
            data = json.loads(result.output)
            self.assertEqual(data["pagination"], {
                "skip": 5, "limit": 5, "total": 6, "has_more": False, "next_skip": None,
            })
            zotero.return_value.search_page.assert_called_once_with(
                "", limit=5, skip=5, tags=["one", "two"], collection=None
            )
            legacy = self.runner.invoke(app, ["list", "--json"])
            self.assertIsInstance(json.loads(legacy.output), list)
            self.assertEqual(json.loads(legacy.output)[0]["num_children"], 1)

    def test_list_plain_text_shows_estimated_file_item_count_not_pdf_marker(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.search_page.return_value = LibraryPage(
                [Paper("ITEM1234", "Paper", "2024", True, 3)], 0, 5, 1, None
            )
            result = self.runner.invoke(app, ["list"])
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertIn("files~3", result.output)
            self.assertNotIn("PDF", result.output)

    def test_list_default_limit_comes_from_config_and_collection_is_forwarded(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.search_page.return_value = LibraryPage([], 0, 8, 0, None)
            result = self.runner.invoke(app, ["list", "--collection", "COLLECTA", "--json"])
            self.assertEqual(result.exit_code, 0, result.output)
            zotero.return_value.search_page.assert_called_once_with(
                "", limit=8, skip=0, tags=None, collection="COLLECTA"
            )

    def test_invalid_collection_key_never_contacts_zotero(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            result = self.runner.invoke(app, ["list", "--collection", "bad-key"])
        self.assertEqual(result.exit_code, 1)
        self.assertEqual(json.loads(result.output)["error"], "ValueError")
        zotero.assert_not_called()

    def test_collection_discovery_json(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.list_collections.return_value = [
                Collection("COLLECTA", "Papers"), Collection("COLLECTB", "Notes"),
            ]
            result = self.runner.invoke(app, ["collections", "--json"])
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertEqual(json.loads(result.output), [
                {"key": "COLLECTA", "name": "Papers"}, {"key": "COLLECTB", "name": "Notes"},
            ])
            cached = self.runner.invoke(app, ["collections", "--json"])
            self.assertEqual(json.loads(cached.output), json.loads(result.output))
            zotero.return_value.list_collections.assert_called_once()
            zotero.return_value.list_collections.return_value = [Collection("COLLECTC", "Fresh")]
            refreshed = self.runner.invoke(app, ["collections", "--refresh", "--json"])
            self.assertEqual(refreshed.exit_code, 0, refreshed.output)
            self.assertEqual(json.loads(refreshed.output), [{"key": "COLLECTC", "name": "Fresh"}])

    def test_tag_discovery_json(self):
        with patch("zotbridge.cli.ZoteroBridge") as zotero:
            zotero.return_value.list_tags.return_value = ["one", "two"]
            result = self.runner.invoke(app, ["tags", "--json"])
            self.assertEqual(result.exit_code, 0, result.output)
            self.assertEqual(json.loads(result.output), ["one", "two"])
            cached = self.runner.invoke(app, ["tags", "--json"])
            self.assertEqual(json.loads(cached.output), ["one", "two"])
            zotero.return_value.list_tags.assert_called_once_with("")
            zotero.return_value.list_tags.return_value = ["fresh"]
            refreshed = self.runner.invoke(app, ["tags", "--refresh", "--json"])
            self.assertEqual(refreshed.exit_code, 0, refreshed.output)
            self.assertEqual(json.loads(refreshed.output), ["fresh"])

    def test_clear_mappings_returns_count_without_remote_operations(self):
        state = self.root / "zotbridge-state.db.json"
        state.write_text(json.dumps({
            "version": 1, "mappings": {"e90be5e8-32f6-46ec-bb75-32d827af9eee": {
                "zotero_library_type": "user", "zotero_library_id": "123",
            }}, "attempts": {},
        }))
        with patch("zotbridge.cli.ZoteroBridge") as zotero, patch("zotbridge.cli.LibrarianBridge") as librarian:
            result = self.runner.invoke(app, ["clear-mappings"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(json.loads(result.output), {
            "ok": True, "library_type": "user", "library_id": "123", "cleared": 1,
        })
        self.assertEqual(json.loads(state.read_text())["mappings"], {})
        zotero.assert_not_called()
        librarian.assert_not_called()


if __name__ == "__main__":
    unittest.main()
