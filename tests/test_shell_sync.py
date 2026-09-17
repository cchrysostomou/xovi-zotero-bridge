import json
import os
from pathlib import Path
import shutil
import sys
import unittest

import test_shell_smoke as smoke


FAKE_SYNC_CURL = r'''
import json, os, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
args = sys.argv[1:]
options, headers = {}, []
for line in Path(args[args.index("--config")+1]).read_text().splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    key, value = key.strip(), value.strip()
    value = json.loads(value) if value.startswith('"') else value
    if key == "header":
        headers.append(value)
    else:
        options[key] = value
db_path = Path(os.environ["FAKE_SYNC_DB"])
db = json.loads(db_path.read_text())
url = urlsplit(options["url"])
query = parse_qs(url.query)
method = options["request"]
status, body, total = "200", None, 1
entry = {"path":url.path, "method":method, "query":query}
if method == "PATCH":
    key = url.path.rsplit("/", 1)[-1]
    item = db["items"][key]
    payload = json.loads(Path(options["data-binary"][1:]).read_text())
    assert set(payload) == {"tags"}, payload
    version = next(h.split(": ", 1)[1] for h in headers if h.startswith("If-Unmodified-Since-Version:"))
    entry.update(version=int(version), tags=payload["tags"])
    state = json.loads((db_path.parent / "state.db.json").read_text())
    assert state["mappings"], "PATCH occurred before a saved import"
    assert any((db_path.parent / "library" / (uuid + ".pdf")).is_file()
               for uuid in state["mappings"]), "PATCH occurred before PDF creation"
    if db.get("conflicts", 0):
        db["conflicts"] -= 1
        item["version"] += 1
        if not any(t["tag"] == "concurrent" for t in item["data"]["tags"]):
            item["data"]["tags"].append({"tag":"concurrent", "type":1})
        if db.get("change_selection"):
            db["items"]["HOSTED12"]["data"]["contentType"] = "text/plain"
        status = "412"
    elif int(version) != item["version"]:
        status = "412"
    else:
        status = str(db.get("patch_status", 204))
        if status == "204":
            item["data"]["tags"] = payload["tags"]
            item["version"] += 1
            db["library_version"] += 1
    body = b""
elif url.path.endswith("/items"):
    tag = query["tag"][0]
    if tag.startswith("\\-"):
        tag = tag[1:]
    rows = [v for v in db["items"].values() if any(t["tag"] == tag for t in v["data"]["tags"])]
    total = len(rows)
    start = int(query.get("start", ["0"])[0])
    limit = min(int(query.get("limit", ["100"])[0]), db.get("page_size", 100))
    body = json.dumps(rows[start:start+limit]).encode()
    if start and db.get("change_queue"):
        db["library_version"] += 1
elif url.path.endswith("/children"):
    key = url.path.split("/")[-2]
    rows = [v for v in db["items"].values() if v["data"].get("parentItem") == key]
    total = len(rows)
    body = json.dumps(rows).encode()
elif "/items/" in url.path:
    key = url.path.rsplit("/", 1)[-1]
    item = db["items"].get(key)
    if item is None:
        status, body = "404", b"Not found"
    else:
        if db.get("remove_queue_on_get") == key:
            item["data"]["tags"] = [t for t in item["data"]["tags"] if t["tag"] != "to_sync"]
        body = json.dumps(item).encode()
elif url.path.endswith(".zip"):
    body = Path(os.environ["FAKE_ARCHIVE"]).read_bytes()
else:
    status, body = "404", b"Not found"
db_path.write_text(json.dumps(db))
with Path(os.environ["FAKE_REQUESTS"]).open("a") as log:
    log.write(json.dumps(entry)+"\n")
Path(args[args.index("--dump-header")+1]).write_text(
    f"HTTP/1.1 {status} response\r\nTotal-Results: {total}\r\n"
    f"Last-Modified-Version: {db['library_version']}\r\n\r\n")
Path(args[args.index("--output")+1]).write_bytes(body)
sys.stdout.write(status)
'''


def item(key, kind="journalArticle", tags=(), parent=None):
    data = {"key": key, "itemType": kind, "title": key,
            "tags": [{"tag": tag, "type": 0} for tag in tags]}
    if kind == "attachment":
        data.update(contentType="application/pdf", linkMode="imported_file", filename="Paper.pdf")
        if parent:
            data["parentItem"] = parent
    return {"key": key, "version": 1, "data": data}


@unittest.skipUnless(os.name == "posix" and smoke.JQ and shutil.which("unzip"),
                     "Requires Linux, jq and unzip")
class TaggedSyncTests(unittest.TestCase):
    run_cli = smoke.ShellSmokeTests.run_cli
    configure_broker = smoke.ShellSmokeTests.configure_broker
    broker_reply = smoke.ShellSmokeTests.broker_reply
    prepare_import = smoke.ShellSmokeTests.prepare_import

    def setUp(self):
        smoke.ShellSmokeTests.setUp(self)
        self.prepare_import()
        self.curl.write_text(f"#!{sys.executable}\n" + FAKE_SYNC_CURL)
        self.db = self.root / "zotero.json"
        self.env["FAKE_SYNC_DB"] = str(self.db)
        self.second_document = b"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        self.imported = []

    def seed(self, rows, **options):
        self.db.write_text(json.dumps({
            "items": {row["key"]: row for row in rows}, "library_version": 1, **options,
        }))

    def tags(self, key):
        return json.loads(self.db.read_text())["items"][key]["data"]["tags"]

    def requests_made(self):
        return [json.loads(line) for line in self.requests.read_text().splitlines()]

    def simulate(self, request):
        if request.startswith(b">eensureFolder:"):
            (self.library / f"{self.folder.decode()}.metadata").write_text(
                '{"type":"CollectionType","parent":""}')
        else:
            source, parent = request.decode().strip().split(":", 1)[1].rsplit(",", 1)
            uuid = [self.document, self.second_document][len(self.imported)].decode()
            self.imported.append(uuid)
            shutil.copyfile(source, self.library / f"{uuid}.pdf")
            (self.library / f"{uuid}.metadata").write_text(json.dumps({
                "type": "DocumentType", "parent": parent, "visibleName": "Renamable",
            }))
            (self.library / f"{uuid}.content").write_text('{"fileType":"pdf"}')

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def test_parent_and_two_tagged_pdfs_import_two_documents_not_three(self):
        self.seed([
            item("ITEM1234", tags=["to_sync", "unread"]),
            item("HOSTED12", "attachment", ["to_sync"], "ITEM1234"),
            item("SECOND12", "attachment", ["to_sync"], "ITEM1234"),
        ], page_size=1)
        with self.broker_reply([self.folder, self.document, self.folder, self.second_document],
                               self.simulate) as broker:
            result = self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual(len(broker), 4)
        self.assertEqual((result["total"], result["synced"], result["failed"]), (3, 3, 0))
        self.assertTrue(result["results"][1]["already_imported"])
        self.assertEqual(result["results"][0]["rm_uuid"], result["results"][1]["rm_uuid"])
        calls = self.requests_made()
        queue_pages = [i for i, call in enumerate(calls) if call["path"].endswith("/items")]
        first_write = next(i for i, call in enumerate(calls) if call["method"] == "PATCH")
        self.assertEqual(len(queue_pages), 3)
        self.assertLess(max(queue_pages), first_write)
        self.assertEqual([c["path"].split("/")[-1] for c in calls if c["path"].endswith(".zip")],
                         ["HOSTED12.zip", "SECOND12.zip"])
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(len(state["mappings"]), 2)
        self.assertEqual({t["tag"] for t in self.tags("ITEM1234")}, {"synced", "unread"})
        self.assertEqual(self.tags("HOSTED12"), [{"tag": "synced", "type": 0}])
        status = self.assert_ok(self.run_cli("status", "--item-key", "HOSTED12"))
        self.assertEqual(status["mapping"]["rm_uuid"], self.document.decode())
        self.assertFalse(list(self.root.glob(".zotbridge-work.*")))

    def test_attachment_before_parent_also_reuses_same_pdf(self):
        self.seed([
            item("HOSTED12", "attachment", ["to_sync"], "ITEM1234"),
            item("ITEM1234", tags=["to_sync"]),
        ])
        with self.broker_reply([self.folder, self.document], self.simulate) as requests:
            result = self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual(len(requests), 2)
        self.assertEqual(result["synced"], 2)
        self.assertTrue(result["results"][1]["already_imported"])

    def test_only_tagged_second_attachment_imports_exact_pdf(self):
        self.seed([
            item("ITEM1234"),
            item("HOSTED12", "attachment", parent="ITEM1234"),
            item("SECOND12", "attachment", ["to_sync"], "ITEM1234"),
        ])
        with self.broker_reply([self.folder, self.document], self.simulate):
            result = self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual(result["results"][0]["attachment_key"], "SECOND12")
        self.assertFalse(any(c["path"].endswith("/HOSTED12.zip") for c in self.requests_made()))
        self.assertEqual(self.tags("ITEM1234"), [])
        self.assertEqual(self.tags("HOSTED12"), [])

    def test_tagged_reference_imports_first_pdf_and_does_not_tag_children(self):
        self.seed([
            item("ITEM1234", tags=["to_sync"]),
            item("HOSTED12", "attachment", parent="ITEM1234"),
            item("SECOND12", "attachment", parent="ITEM1234"),
        ])
        with self.broker_reply([self.folder, self.document], self.simulate):
            result = self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual(result["results"][0]["attachment_key"], "HOSTED12")
        self.assertEqual(self.tags("HOSTED12"), [])
        self.assertEqual(self.tags("SECOND12"), [])

    def test_write_failure_retains_mapping_and_retry_does_not_reimport(self):
        self.seed([
            item("ITEM1234", tags=["to_sync"]),
            item("HOSTED12", "attachment", parent="ITEM1234"),
            item("MISSING1", tags=["to_sync"]),
        ], patch_status=403)
        with self.broker_reply([self.folder, self.document], self.simulate):
            first = self.run_cli("sync-tagged")
        self.assertNotEqual(first.returncode, 0)
        failed = json.loads(first.stdout)
        self.assertEqual(failed["results"][0]["error"], "write_permission")
        self.assertEqual(failed["remaining"], ["MISSING1"])
        self.assertEqual(self.tags("ITEM1234"), [{"tag": "to_sync", "type": 0}])
        db = json.loads(self.db.read_text())
        db["patch_status"] = 204
        self.db.write_text(json.dumps(db))
        retried = self.assert_ok(self.run_cli("sync-item", "--item-key", "ITEM1234"))
        self.assertTrue(retried["already_imported"])
        self.assertEqual(len([c for c in self.requests_made() if c["path"].endswith(".zip")]), 1)
        self.assertEqual(self.tags("ITEM1234"), [{"tag": "synced", "type": 0}])

    def test_conflict_refetch_preserves_other_tags_and_existing_synced_tag(self):
        self.seed([
            item("HOSTED12", "attachment", ["to_sync", "keep", "synced"]),
        ], conflicts=1)
        with self.broker_reply([self.folder, self.document], self.simulate):
            self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual(self.tags("HOSTED12"), [
            {"tag": "keep", "type": 0}, {"tag": "synced", "type": 0},
            {"tag": "concurrent", "type": 1},
        ])
        self.assertEqual([c["version"] for c in self.requests_made() if c["method"] == "PATCH"], [1, 2])

    def test_repeated_conflicts_leave_queue_tag_and_verified_mapping(self):
        self.seed([item("HOSTED12", "attachment", ["to_sync"])], conflicts=3)
        with self.broker_reply([self.folder, self.document], self.simulate):
            result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["results"][0]["error"], "write_conflict")
        self.assertIn("to_sync", [t["tag"] for t in self.tags("HOSTED12")])
        self.assertEqual(len(json.loads((self.root / "state.db.json").read_text())["mappings"]), 1)

    def test_selection_change_on_conflict_does_not_tag_reference_synced(self):
        self.seed([
            item("ITEM1234", tags=["to_sync"]),
            item("HOSTED12", "attachment", parent="ITEM1234"),
            item("SECOND12", "attachment", parent="ITEM1234"),
        ], conflicts=1, change_selection=True)
        with self.broker_reply([self.folder, self.document], self.simulate):
            result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["results"][0]["error"], "source_changed")
        self.assertNotIn("synced", [t["tag"] for t in self.tags("ITEM1234")])

    def test_no_pdf_failure_does_not_prevent_other_item_success(self):
        self.seed([
            item("MISSING1", tags=["to_sync"]),
            item("HOSTED12", "attachment", ["to_sync"]),
        ])
        with self.broker_reply([self.folder, self.document], self.simulate):
            result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertEqual((data["failed"], data["synced"], data["remaining"]), (1, 1, []))
        self.assertEqual(self.tags("MISSING1"), [{"tag": "to_sync", "type": 0}])

    def test_queue_changes_between_pages_abort_before_import_or_write(self):
        self.seed([
            item("ITEM1234", tags=["to_sync"]),
            item("HOSTED12", "attachment", ["to_sync"], "ITEM1234"),
        ], page_size=1, change_queue=True)
        result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "queue_changed")
        self.assertTrue(all(c["method"] == "GET" for c in self.requests_made()))
        self.assertFalse((self.root / "state.db.json").exists())

    def test_removed_queue_tag_is_skipped_without_import(self):
        self.seed([item("HOSTED12", "attachment", ["to_sync"])], remove_queue_on_get="HOSTED12")
        result = self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual((result["synced"], result["skipped"]), (0, 1))
        self.assertFalse(any(c["path"].endswith(".zip") for c in self.requests_made()))
        self.assertFalse((self.root / "state.db.json").exists())

    def test_tag_names_are_exact_and_overridable(self):
        self.seed([item("HOSTED12", "attachment", ["tosync"])])
        self.assertEqual(self.assert_ok(self.run_cli("sync-tagged"))["total"], 0)
        with self.broker_reply([self.folder, self.document], self.simulate):
            result = self.assert_ok(self.run_cli("sync-tagged", "--tag", "tosync", "--synced-tag", "done"))
        self.assertEqual(result["synced"], 1)
        self.assertEqual(self.tags("HOSTED12"), [{"tag": "done", "type": 0}])

    def test_invalid_tags_are_rejected_before_network(self):
        for args in (("--tag", ""), ("--tag", "synced"), ("--tag", "one || two")):
            with self.subTest(args=args):
                result = self.run_cli("sync-tagged", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], "ValueError")
        self.assertFalse(self.requests.exists())

    def test_missing_or_trashed_mapped_document_blocks_tag_writeback(self):
        self.seed([item("HOSTED12", "attachment", ["to_sync"])], patch_status=403)
        with self.broker_reply([self.folder, self.document], self.simulate):
            self.assertNotEqual(self.run_cli("sync-tagged").returncode, 0)
        writes_before = len([c for c in self.requests_made() if c["method"] == "PATCH"])
        folder = self.library / f"{self.folder.decode()}.metadata"
        folder.write_text('{"type":"CollectionType","parent":"trash"}')
        trashed = self.run_cli("sync-item", "--item-key", "HOSTED12")
        self.assertEqual(json.loads(trashed.stdout)["error"], "verification_error")
        (self.library / f"{self.document.decode()}.pdf").unlink()
        missing = self.run_cli("sync-item", "--item-key", "HOSTED12")
        self.assertEqual(json.loads(missing.stdout)["error"], "verification_error")
        self.assertEqual(len([c for c in self.requests_made() if c["method"] == "PATCH"]), writes_before)

    def test_uncertain_parent_import_blocks_exact_attachment_retry(self):
        self.seed([
            item("ITEM1234"),
            item("HOSTED12", "attachment", ["to_sync"], "ITEM1234"),
        ])
        with self.broker_reply([self.folder, None]):
            first = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertEqual(json.loads(first.stdout)["error"], "TimeoutError")
        result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["results"][0]["error"], "import_uncertain")
        self.assertFalse(any(c["method"] == "PATCH" for c in self.requests_made()))

    def test_batch_lock_rejects_second_sync(self):
        import fcntl
        with (self.root / "state.db.json.sync.lock").open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "busy")
        self.assertFalse(self.requests.exists())

    def test_plain_import_accepts_exact_attachment_and_parent_reuses_it(self):
        self.seed([
            item("ITEM1234"),
            item("HOSTED12", "attachment", parent="ITEM1234"),
        ])
        with self.broker_reply([self.folder, self.document], self.simulate):
            exact = self.assert_ok(self.run_cli("import", "--item-key", "HOSTED12"))
        self.assertEqual(exact["attachment_key"], "HOSTED12")
        parent = self.assert_ok(self.run_cli("import", "--item-key", "ITEM1234"))
        self.assertTrue(parent["already_imported"])
        self.assertEqual(parent["rm_uuid"], exact["rm_uuid"])
        self.assertEqual(len([c for c in self.requests_made() if c["path"].endswith(".zip")]), 1)
        self.assertFalse(any(c["method"] == "PATCH" for c in self.requests_made()))

    def test_unverified_batch_import_never_writes_tags_or_retries_import(self):
        self.seed([item("HOSTED12", "attachment", ["to_sync"])])
        with self.broker_reply([self.folder, self.document]):
            result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["results"][0]["error"], "verification_error")
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(state["mappings"], {})
        self.assertEqual(state["attempts"]["user:123"]["HOSTED12"]["state"], "uncertain")
        again = self.run_cli("sync-tagged")
        self.assertEqual(json.loads(again.stdout)["results"][0]["error"], "import_uncertain")
        self.assertEqual(len([c for c in self.requests_made() if c["path"].endswith(".zip")]), 1)
        self.assertFalse(any(c["method"] == "PATCH" for c in self.requests_made()))
        self.assertEqual(self.tags("HOSTED12"), [{"tag": "to_sync", "type": 0}])

    def test_linked_attachment_is_rejected_without_download_or_write(self):
        linked = item("HOSTED12", "attachment", ["to_sync"])
        linked["data"]["linkMode"] = "linked_file"
        self.seed([linked])
        result = self.run_cli("sync-tagged")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["results"][0]["error"], "unsupported_item")
        self.assertFalse(any(c["method"] == "PATCH" or c["path"].endswith(".zip")
                             for c in self.requests_made()))

    def test_sync_preserves_manual_tag_cache(self):
        state = {"version": 1, "mappings": {}, "attempts": {},
                 "tag_cache": {"user:123": {"": {"fetched_at": 100, "tags": ["to_sync"]}}}}
        path = self.root / "state.db.json"
        path.write_text(json.dumps(state))
        self.seed([item("HOSTED12", "attachment", ["to_sync"])])
        with self.broker_reply([self.folder, self.document], self.simulate):
            self.assert_ok(self.run_cli("sync-tagged"))
        self.assertEqual(json.loads(path.read_text())["tag_cache"], state["tag_cache"])


if __name__ == "__main__":
    unittest.main()
