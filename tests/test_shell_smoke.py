from contextlib import contextmanager
import base64
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import warnings
import zipfile


ROOT = Path(__file__).resolve().parents[1]
JQ = os.environ.get("ZOTBRIDGE_JQ") or shutil.which("jq")

FAKE_CURL = r'''
import json, os, re, shlex, sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit
args = sys.argv[1:]
if "--version" in args:
    print("curl 8.10.1 (test fixture)")
    raise SystemExit(0)
options = {}
aliases = {"-K":"config", "--config":"config", "-o":"output", "--output":"output",
           "-D":"dump-header", "--dump-header":"dump-header", "-w":"write-out",
           "--write-out":"write-out", "--url":"url", "-X":"request", "--request":"request"}
index = 0
while index < len(args):
    arg = args[index]
    if arg in aliases:
        options[aliases[arg]] = args[index + 1]
        index += 2
    elif arg.startswith(("http://", "https://")):
        options["url"] = arg
        index += 1
    else:
        index += 1
if "config" in options:
    for line in Path(options["config"]).read_text().splitlines():
        if "=" not in line:
            continue
        name, value = line.split("=", 1)
        values = shlex.split(value.strip())
        if values:
            options.setdefault(name.strip(), values[0])
url = options.get("url", "")
path = urlsplit(url).path
parameters = parse_qs(urlsplit(url).query)
start = int(parameters.get("start", ["0"])[0])
limit = int(parameters.get("limit", ["100"])[0])
data = {"key":"ITEM1234","data":{"key":"ITEM1234","itemType":"journalArticle","title":"Test Paper","date":"2024",
    "dateAdded":"2024-01-02T03:04:05Z","dateModified":"2024-05-06T07:08:09Z",
    "tags":[{"tag":"important"}]}}
attachment = {"key":"HOSTED12","data":{"key":"HOSTED12","itemType":"attachment",
    "parentItem":"ITEM1234","contentType":"application/pdf","linkMode":"imported_file","filename":"Paper.pdf"}}
status = "200"
total = 1
if re.search(r"/collections/[A-Z0-9]{8}/items/top$", path):
    total = int(os.environ.get("FAKE_COLLECTION_ITEM_TOTAL", "1"))
    items = []
    for i in range(start, min(start + limit, total)):
        key = "ITEM1234" if i == 0 else f"ITEM{i:04}"
        items.append({"key":key,"data":dict(data["data"],key=key),"meta":{"numChildren":1}})
    body = json.dumps(items).encode()
elif path.endswith("/collections/top"):
    total = int(os.environ.get("FAKE_COLLECTION_TOTAL", "2"))
    prefix = os.environ.get("FAKE_COLLECTION_PREFIX", "Folder")
    collections = [{"key":f"COL{i:05d}","data":{"key":f"COL{i:05d}","name":f"{prefix} {i}"}}
                   for i in range(start, min(start + limit, total))]
    if start >= int(os.environ.get("FAKE_COLLECTION_FAILURE_START", "999999")): status = "500"
    body = json.dumps(collections).encode()
elif path.endswith("/items/top"):
    total = int(os.environ.get("FAKE_ITEM_TOTAL", "1"))
    num_children = int(os.environ.get("FAKE_ITEM_NUM_CHILDREN", "1"))
    titles = json.loads(os.environ.get("FAKE_ITEM_TITLES", "[]"))
    creators = json.loads(os.environ.get("FAKE_ITEM_CREATORS", "[]"))
    items = []
    for i in range(start, min(start + limit, total)):
        key = "ITEM1234" if i == 0 else f"ITEM{i:04}"
        item_data = dict(data["data"], key=key)
        if titles:
            item_data["title"] = titles[i % len(titles)]
        meta = {"numChildren":num_children}
        if creators:
            meta["creatorSummary"] = creators[i % len(creators)]
        items.append({"key":key,"data":item_data,"meta":meta})
    body = json.dumps(items).encode()
elif re.search(r"/items/ITEM[A-Z0-9]{4}/children$", path):
    body = json.dumps([attachment]).encode()
elif path.endswith("/tags"):
    total = int(os.environ.get("FAKE_TAG_TOTAL", "150"))
    prefix = os.environ.get("FAKE_TAG_PREFIX", "tag")
    tags = [{"tag":f"{prefix}{i:03}"} for i in range(start, min(start + limit, total))]
    if os.environ.get("FAKE_EMPTY_TAG_PAGE"): tags = []
    if start >= int(os.environ.get("FAKE_TAG_FAILURE_START", "999999")): status = "500"
    body = json.dumps(tags).encode()
elif path.endswith("/items/ITEM1234"):
    body = json.dumps(data).encode()
elif path.endswith("/items/HOSTED12"):
    body = json.dumps(attachment).encode()
elif path.endswith("/zotero/") and options.get("request") == "PROPFIND":
    status, body = "207", b"<multistatus/>"
elif path.endswith("/HOSTED12.zip"):
    status = os.environ.get("FAKE_WEBDAV_STATUS", "200")
    body = Path(os.environ["FAKE_ARCHIVE"]).read_bytes() if status == "200" else b"Unauthorized"
else:
    status, body = "404", b"Not found"
if path.startswith("/users/"):
    status = os.environ.get("FAKE_METADATA_STATUS", status)
with Path(os.environ["FAKE_REQUESTS"]).open("a") as log:
    log.write(json.dumps({"path":path,"query":urlsplit(url).query,"method":options.get("request","GET")})+"\n")
if "dump-header" in options:
    header = "" if os.environ.get("FAKE_MISSING_TOTAL") else f"Total-Results: {total}\r\n"
    Path(options["dump-header"]).write_text("HTTP/1.1 "+status+" response\r\n"+header+"\r\n")
if "output" in options:
    Path(options["output"]).write_bytes(body)
else:
    sys.stdout.buffer.write(body)
if "write-out" in options:
    sys.stdout.write(options["write-out"].replace("%{http_code}",status).replace("\\n","\n"))
'''

@unittest.skipUnless(os.name == "posix" and JQ and shutil.which("unzip"),
                     "Shell smoke tests require Linux, jq and unzip")
class ShellSmokeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Deliberately omit Python, timeout and base64 from the backend's PATH.
        for name in ("sh", "bash", "curl", "unzip", "flock", "awk", "sed", "grep", "head",
                     "tail", "stat", "mktemp", "mkdir", "rmdir", "rm", "mv", "cp", "cat",
                     "chmod", "date", "sleep", "wc", "dd", "tr", "sort", "find", "dirname",
                     "basename", "readlink", "cut", "od", "getconf", "sync", "kill", "touch"):
            source = shutil.which(name)
            if source:
                (self.bin / name).symlink_to(source)
        for name in ("md5sum", "sha256sum"):
            source = shutil.which(name)
            if source:
                (self.bin / name).symlink_to(source)
        self.curl = self.root / "fake-curl"
        self.curl.write_text(f"#!{sys.executable}\n" + FAKE_CURL)
        self.curl.chmod(0o755)
        self.archive = self.root / "attachment.zip"
        with zipfile.ZipFile(self.archive, "w") as zipped:
            zipped.writestr("Paper.pdf", b"%PDF-1.7\nTest PDF\n")
        self.config = self.root / "config.toml"
        self.config.write_text(
            'library_id = "123"\nlibrary_type = "user"\napi_key = "test-secret"\n'
            'use_webdav = true\nwebdav_url = "https://dav.example/zotero/"\n'
            'webdav_username = "reader"\nwebdav_password = "password-secret"\n'
            'state_db_path = "./state.db"\n'
        )
        self.requests = self.root / "requests.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin), ZOTBRIDGE_JQ=str(JQ),
                        ZOTBRIDGE_CURL=str(self.curl), ZOTBRIDGE_CONFIG=str(self.config),
                        ZOTBRIDGE_BACKEND="shell", FAKE_ARCHIVE=str(self.archive),
                        FAKE_REQUESTS=str(self.requests), ZOTBRIDGE_WORK_DIR=str(self.root))

    def run_cli(self, *arguments):
        return subprocess.run([str(self.bin / "sh"), str(ROOT / "scripts" / "zotbridge-run.sh"),
                               *arguments], env=self.env, cwd=self.root,
                              capture_output=True, text=True, timeout=30)

    def test_metadata_check_without_python_or_tablet_broker(self):
        result = self.run_cli("check-connection")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["metadata"], "accessible")
        self.assertEqual(data["storage"], "webdav")
        self.assertEqual(data["pdf_download"], "not_tested")
        self.assertFalse((self.root / "state.db.json").exists())

    def test_connection_check_can_verify_metadata_and_webdav_without_import(self):
        result = self.run_cli("check-connection", "--webdav")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "ok": True, "metadata": "accessible", "webdav": "accessible",
            "pdf_download": "not_tested",
            "message": "Read-only Zotero metadata and WebDAV directory checks passed.",
        })
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertEqual([request["method"] for request in requests], ["GET", "PROPFIND"])
        self.assertFalse((self.root / "state.db.json").exists())

    def test_activity_log_records_safe_outcomes_and_can_be_cleared(self):
        success = self.run_cli("check-connection")
        self.assertEqual(success.returncode, 0, success.stdout + success.stderr)
        failure = self.run_cli("status", "--item-key", "ITEM1234")
        self.assertNotEqual(failure.returncode, 0)
        logged = self.run_cli("activity-log")
        self.assertEqual(logged.returncode, 0, logged.stdout + logged.stderr)
        entries = json.loads(logged.stdout)["entries"]
        self.assertEqual(
            [(entry["action"], entry["event"], entry.get("error")) for entry in entries],
            [
                ("check-connection", "started", None),
                ("check-connection", "completed", None),
                ("status", "started", None),
                ("status", "failed", "nonzero_exit"),
            ],
        )
        self.assertTrue(all("message" not in entry for entry in entries))
        self.assertTrue(all("test-secret" not in json.dumps(entry) for entry in entries))
        cleared = self.run_cli("clear-activity-log")
        self.assertEqual(cleared.returncode, 0, cleared.stdout + cleared.stderr)
        self.assertEqual(json.loads(cleared.stdout), {"ok": True, "cleared": 4})
        self.assertEqual(json.loads(self.run_cli("activity-log").stdout), {"ok": True, "entries": []})

    def test_activity_log_keeps_latest_two_hundred_entries(self):
        log = self.root / "state.db.json.activity.jsonl"
        with log.open("w") as handle:
            for number in range(200):
                handle.write(json.dumps({
                    "timestamp": "2026-01-01T00:00:00Z", "action": f"old-{number}",
                    "event": "completed",
                }) + "\n")
        result = self.run_cli("check-connection")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        entries = json.loads(self.run_cli("activity-log").stdout)["entries"]
        self.assertEqual(len(entries), 200)
        self.assertEqual(entries[0]["action"], "old-2")
        self.assertEqual(entries[-2]["event"], "started")
        self.assertEqual(entries[-1]["event"], "completed")

    def test_activity_log_refuses_unsafe_or_invalid_existing_file(self):
        log = self.root / "state.db.json.activity.jsonl"
        log.write_text("not JSON\n")
        invalid = self.run_cli("activity-log")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(json.loads(invalid.stdout)["error"], "activity_log_error")
        log.unlink()
        log.symlink_to(self.root / "other")
        unsafe = self.run_cli("check-connection")
        self.assertNotEqual(unsafe.returncode, 0)
        self.assertEqual(json.loads(unsafe.stdout)["error"], "activity_log_error")

    def test_settings_hides_password_and_applies_valid_draft_atomically(self):
        settings = self.run_cli("settings", "--json")
        self.assertEqual(settings.returncode, 0, settings.stdout + settings.stderr)
        public = json.loads(settings.stdout)
        self.assertEqual(public["webdav"], {
            "enabled": True, "url": "https://dav.example/zotero/", "username": "reader",
            "password_set": True,
        })
        self.assertNotIn("password-secret", settings.stdout)
        self.assertEqual(public["sync_queue_tag"], "to_sync")
        self.assertEqual(public["reverse_sync_folder"], "Zotero/Read")
        self.assertEqual(public["list_page_limit"], 8)
        draft = self.root / ".zotbridge-settings-draft.json"
        draft.write_text(json.dumps({
            "version": 1, "webdav_url": "https://next.example/files",
            "webdav_username": "next-user", "default_target_folder": "Zotero/ready",
            "list_page_limit": 25,
            "reverse_sync_folder": "Zotero/Read and annotated",
            "sync_queue_tag": "waiting", "sync_synced_tag": "complete",
        }))
        applied = self.run_cli("settings-apply")
        self.assertEqual(applied.returncode, 0, applied.stdout + applied.stderr)
        data = json.loads(applied.stdout)
        self.assertTrue(data["applied"])
        self.assertEqual(data["webdav"]["url"], "https://next.example/files/")
        self.assertTrue(data["webdav"]["password_set"])
        self.assertEqual(data["list_page_limit"], 25)
        self.assertFalse(draft.exists())
        saved = self.config.read_text()
        self.assertIn('webdav_password = "password-secret"', saved)
        self.assertIn('sync_queue_tag = "waiting"', saved)
        self.assertIn('reverse_sync_folder = "Zotero/Read and annotated"', saved)
        self.assertNotIn("password-secret", applied.stdout)

    def test_reverse_sync_reports_broker_unavailable_instead_of_silent_failure(self):
        # Regression test: reverse-sync used to redirect its stdout to a WORK file
        # that was deleted before an internal fail() (e.g. broker unreachable) could
        # ever be printed, so the command exited nonzero with completely empty
        # stdout/stderr. It must now surface the JSON error normally.
        self.install_stub_localgeta_and_seven_zip()
        with self.config.open("a") as config:
            config.write('reverse_sync_folder = "Zotero"\n')
        result = self.run_cli("reverse-sync")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.strip(), "reverse-sync must not fail silently")
        data = json.loads(result.stdout)
        self.assertEqual(data["ok"], False)
        self.assertEqual(data["error"], "ValueError")
        self.assertIn("FIFOs", data["message"])

    def test_sync_all_reports_broker_unavailable_instead_of_silent_failure(self):
        # Regression test for the same silent-failure pattern inside sync_all()'s
        # internal reverse_sync call.
        self.install_stub_localgeta_and_seven_zip()
        with self.config.open("a") as config:
            config.write('reverse_sync_folder = "Zotero"\ndefault_target_folder = "Zotero"\n'
                         'sync_queue_tag = "waiting"\nsync_synced_tag = "complete"\n')
        result = self.run_cli("sync-all")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(result.stdout.strip(), "sync-all must not fail silently")
        data = json.loads(result.stdout)
        self.assertEqual(data["ok"], False)
        self.assertEqual(data["reverse"]["error"], "ValueError")
        self.assertIn("FIFOs", data["reverse"]["message"])

    def test_reverse_sync_retains_unexportable_document_and_logs_stage(self):
        self.prepare_import()
        uuid = self.document.decode()
        (self.library / f"{uuid}.metadata").write_text(json.dumps({
            "type": "DocumentType", "parent": self.folder.decode(),
            "visibleName": "Unsupported EPUB",
        }))
        local_geta = self.bin / "zotbridge-localgeta"
        local_geta.write_text("#!/bin/sh\nexit 1\n")
        local_geta.chmod(0o755)
        seven_zip = self.bin / "7zz"
        seven_zip.write_text("#!/bin/sh\nexit 1\n")
        seven_zip.chmod(0o755)
        self.env["ZOTBRIDGE_LOCALGETA"] = str(local_geta)
        self.env["ZOTBRIDGE_7ZZ"] = str(seven_zip)
        with self.broker_reply([self.folder]):
            result = self.run_cli("reverse-sync")
        self.assertNotEqual(result.returncode, 0)
        data = json.loads(result.stdout)
        self.assertEqual(data["retained_failures"], 1)
        self.assertEqual(data["results"][0], {
            "ok": False, "rm_uuid": uuid, "stage": "export",
            "error": "unsupported_export", "retained_in_source": True,
        })
        entries = json.loads(self.run_cli("activity-log").stdout)["entries"]
        failure = next(entry for entry in entries if entry["event"] == "failed")
        self.assertEqual(failure["rm_uuid"], uuid)
        self.assertEqual(failure["stage"], "export")
        self.assertTrue(failure["retained_in_source"])

    def test_settings_rejects_invalid_draft_without_changing_config(self):
        original = self.config.read_bytes()
        draft = self.root / ".zotbridge-settings-draft.json"
        draft.write_text(json.dumps({
            "version": 1, "webdav_url": "http://not-secure.example/",
            "webdav_username": "reader", "webdav_password": "",
            "default_target_folder": "Zotero//bad", "reverse_sync_folder": "Zotero/Read",
            "sync_queue_tag": "same",
            "sync_synced_tag": "same",
        }))
        result = self.run_cli("settings-apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "settings_error")
        self.assertEqual(self.config.read_bytes(), original)
        self.assertTrue(draft.exists())

    def test_pdf_check_uses_webdav_without_remote_writes_or_import_state(self):
        result = self.run_cli("check-connection", "--item-key", "ITEM1234")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["pdf_download"], "verified")
        self.assertGreater(data["bytes"], 0)
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertTrue(any(request["path"].endswith("/HOSTED12.zip") for request in requests))
        self.assertTrue(all(request["method"] == "GET" for request in requests))
        self.assertFalse((self.root / "state.db.json").exists())
        self.assertFalse(list(self.root.glob("*.pdf")))

    def test_search_json_shape(self):
        result = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data[0]["item_key"], "ITEM1234")
        self.assertTrue(data[0]["has_pdf"])
        self.assertEqual(data[0]["num_children"], 1)
        self.assertIsNone(data[0]["mapping"])
        self.assertIsNone(data[0]["attempt"])

    def test_has_pdf_uses_numchildren_without_a_children_request(self):
        result = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertFalse(any(request["path"].endswith("/children") for request in requests))
        self.env["FAKE_ITEM_NUM_CHILDREN"] = "0"
        # --refresh because the identical listing above is now cached on disk.
        result = self.run_cli("list", "--limit", "5", "--json", "--refresh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(json.loads(result.stdout)[0]["has_pdf"])
        self.assertEqual(json.loads(result.stdout)[0]["num_children"], 0)

    def item_requests(self):
        return [json.loads(line) for line in self.requests.read_text().splitlines()
                if json.loads(line)["path"].endswith("/items/top")]

    def test_repeated_listing_is_served_from_the_on_disk_cache(self):
        self.assertEqual(self.run_cli("list", "--limit", "5", "--json").returncode, 0)
        first = len(self.item_requests())
        self.assertEqual(self.run_cli("list", "--limit", "5", "--json").returncode, 0)
        # The second identical listing must not reach Zotero at all.
        self.assertEqual(len(self.item_requests()), first)
        self.assertTrue((self.root / "state.db.json.list-cache.json").exists())

    def test_cached_listing_returns_the_same_payload(self):
        live = self.run_cli("list", "--limit", "5", "--json")
        cached = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(json.loads(live.stdout), json.loads(cached.stdout))

    def test_refresh_bypasses_and_replaces_the_cached_listing(self):
        self.run_cli("list", "--limit", "5", "--json")
        before = len(self.item_requests())
        result = self.run_cli("list", "--limit", "5", "--json", "--refresh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.item_requests()), before + 1)

    def test_a_different_page_or_sort_is_cached_separately(self):
        self.run_cli("list", "--limit", "5", "--json")
        before = len(self.item_requests())
        self.run_cli("list", "--limit", "5", "--json", "--skip", "5")
        self.run_cli("list", "--limit", "5", "--json", "--sort", "title")
        self.assertEqual(len(self.item_requests()), before + 2)

    def test_expired_cache_entries_are_refetched(self):
        self.config.write_text(self.config.read_text() + "\nlist_cache_ttl_s = 0\n")
        self.run_cli("list", "--limit", "5", "--json")
        before = len(self.item_requests())
        self.run_cli("list", "--limit", "5", "--json")
        # A zero TTL disables the cache, so every listing goes to Zotero.
        self.assertEqual(len(self.item_requests()), before + 1)

    def test_cached_listing_still_reflects_new_import_mappings(self):
        first = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertIsNone(json.loads(first.stdout)[0]["mapping"])
        # Record a mapping directly; the point is that the cached page picks it
        # up, not how the import got there.
        state = self.root / "state.db.json"
        stored = json.loads(state.read_text()) if state.exists() else {
            "version": 1, "mappings": {}, "attempts": {},
            "tag_cache": {}, "collection_cache": {}}
        stored["mappings"]["e90be5e8-32f6-46ec-bb75-32d827af9eee"] = {
            "zotero_library_type": "user", "zotero_library_id": "123",
            "zotero_item_key": "ITEM1234", "zotero_attachment_key": "HOSTED12",
            "rm_path": "Zotero/unread", "state": "imported"}
        state.write_text(json.dumps(stored))
        before = len(self.item_requests())
        cached = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(cached.returncode, 0, cached.stdout + cached.stderr)
        # Served from cache (no new request) yet the live mapping is applied.
        self.assertEqual(len(self.item_requests()), before)
        self.assertIsNotNone(json.loads(cached.stdout)[0]["mapping"])

    def test_sort_and_direction_are_forwarded_to_zotero(self):
        result = self.run_cli("list", "--limit", "5", "--json", "--sort", "title",
                              "--direction", "asc")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        queries = [json.loads(line)["query"] for line in self.requests.read_text().splitlines()]
        self.assertTrue(any("sort=title" in query and "direction=asc" in query for query in queries))

    def test_listing_defaults_to_recently_modified_first(self):
        self.run_cli("list", "--limit", "5", "--json")
        queries = [json.loads(line)["query"] for line in self.requests.read_text().splitlines()]
        self.assertTrue(any("sort=dateModified" in query and "direction=desc" in query
                            for query in queries))

    def test_sort_and_direction_reject_unsupported_values(self):
        for arguments in (("--sort", "publisher"), ("--direction", "sideways")):
            result = self.run_cli("list", *arguments)
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertEqual(json.loads(result.stdout)["error"], "ValueError")

    def test_listing_reports_the_zotero_timestamps_used_for_local_sorting(self):
        result = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        first = json.loads(result.stdout)[0]
        self.assertEqual(first["date_added"], "2024-01-02T03:04:05Z")
        self.assertEqual(first["date_modified"], "2024-05-06T07:08:09Z")

    def test_listing_reports_the_creator_summary(self):
        self.env["FAKE_ITEM_CREATORS"] = json.dumps(["Darwin"])
        result = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["creator"], "Darwin")

    def test_listing_reports_an_empty_creator_when_zotero_omits_one(self):
        result = self.run_cli("list", "--limit", "5", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["creator"], "")

    def test_list_plain_text_shows_estimated_file_item_count_not_pdf_marker(self):
        result = self.run_cli("list", "--limit", "5")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("files~1", result.stdout)
        self.assertNotIn("PDF", result.stdout)

    def test_list_needs_no_unzip_head_stat_or_broker_tools(self):
        for tool in ("unzip", "head", "stat", "od", "flock", "mv", "sleep"):
            (self.bin / tool).unlink(missing_ok=True)
        result = self.run_cli("list", "--query", "graph & learning", "--limit", "5", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)[0]["title"], "Test Paper")
        request = json.loads(self.requests.read_text().splitlines()[0])
        from urllib.parse import parse_qs
        query = parse_qs(request["query"])
        self.assertEqual(query["q"], ["graph & learning"])
        self.assertEqual(query["start"], ["0"])
        self.assertEqual(query["itemType"], ["-attachment || note || annotation"])
        self.assertFalse((self.root / "state.db.json").exists())

    def test_listing_auth_failure_is_structured(self):
        self.env["FAKE_METADATA_STATUS"] = "401"
        result = self.run_cli("list", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "zotero_error")
        self.assertNotIn("test-secret", result.stdout + result.stderr)

    def test_or_tag_filter_is_url_encoded_as_literal_names(self):
        from urllib.parse import parse_qs
        for tags, expression in (
            (["machine learning", "-review"], "machine learning || -review"),
            (["-review", "machine learning"], "\\-review || machine learning"),
        ):
            with self.subTest(tags=tags):
                result = self.run_cli("list", "--tag", tags[0], "--tag", tags[1], "--json")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
                request = [r for r in requests if r["path"].endswith("/items/top")][-1]
                self.assertEqual(parse_qs(request["query"])["tag"], [expression])

    def test_default_list_limit_comes_from_config_and_collection_filters_endpoint(self):
        from urllib.parse import parse_qs
        result = self.run_cli("list", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        request = json.loads(self.requests.read_text().splitlines()[-1])
        self.assertEqual(request["path"], "/users/123/items/top")
        self.assertEqual(parse_qs(request["query"])["limit"], ["8"])
        self.config.write_text(self.config.read_text() + 'list_page_limit = 42\n')
        result = self.run_cli("list", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        request = json.loads(self.requests.read_text().splitlines()[-1])
        self.assertEqual(parse_qs(request["query"])["limit"], ["42"])
        override = self.run_cli("list", "--limit", "3", "--json")
        self.assertEqual(override.returncode, 0, override.stdout + override.stderr)
        request = json.loads(self.requests.read_text().splitlines()[-1])
        self.assertEqual(parse_qs(request["query"])["limit"], ["3"])
        collection = self.run_cli("list", "--collection", "COLLECTA", "--json")
        self.assertEqual(collection.returncode, 0, collection.stdout + collection.stderr)
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertEqual(requests[-1]["path"], "/users/123/collections/COLLECTA/items/top")
        invalid = self.run_cli("list", "--collection", "bad-key")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(json.loads(invalid.stdout)["error"], "ValueError")

    def test_invalid_list_page_limit_configuration_is_rejected(self):
        self.config.write_text(self.config.read_text() + 'list_page_limit = 0\n')
        result = self.run_cli("list", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "configuration_error")

    def test_pages_advance_then_end_and_keep_filtered_total(self):
        self.env["FAKE_ITEM_TOTAL"] = "3"
        first = self.run_cli("list", "--limit", "2", "--page-info")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        one = json.loads(first.stdout)
        self.assertEqual(one["pagination"], {
            "skip": 0, "limit": 2, "total": 3, "has_more": True, "next_skip": 2,
        })
        second = self.run_cli("list", "--limit", "2", "--skip", "2", "--page-info")
        two = json.loads(second.stdout)
        self.assertEqual(two["pagination"]["total"], 3)
        self.assertIsNone(two["pagination"]["next_skip"])
        self.assertEqual(len(two["items"]), 1)
        self.assertFalse({item["item_key"] for item in one["items"]} &
                         {item["item_key"] for item in two["items"]})
        empty = self.run_cli("list", "--start", "3", "--page-info")
        self.assertEqual(json.loads(empty.stdout)["items"], [])

    def test_tags_fetch_every_page(self):
        result = self.run_cli("tags", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        names = json.loads(result.stdout)
        self.assertEqual(len(names), 150)
        self.assertEqual(names[0], "tag000")
        self.assertEqual(names[-1], "tag149")
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertEqual(len(requests), 2)
        stored = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(stored["mappings"], {})
        self.assertEqual(stored["attempts"], {})

    def test_tag_cache_reuses_even_empty_results_without_network(self):
        self.env["FAKE_TAG_TOTAL"] = "0"
        first = self.run_cli("tags", "--json")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(json.loads(first.stdout), [])
        original = self.requests.read_bytes()
        self.env["FAKE_METADATA_STATUS"] = "401"
        cached = self.run_cli("tags", "--json")
        self.assertEqual(cached.returncode, 0, cached.stdout + cached.stderr)
        self.assertEqual(json.loads(cached.stdout), [])
        self.assertEqual(self.requests.read_bytes(), original)

    def test_tag_refresh_preserves_other_state_and_private_file_mode(self):
        state = self.root / "state.db.json"
        previous = {
            "version": 1,
            "mappings": {"e90be5e8-32f6-46ec-bb75-32d827af9eee": {
                "zotero_library_type": "user", "zotero_library_id": "123",
                "zotero_item_key": "ITEM1234", "zotero_attachment_key": "PDF12345",
            }},
            "attempts": {"user:123": {"OTHER123": {"state": "uncertain"}}},
            "future_field": {"keep": True},
        }
        state.write_text(json.dumps(previous))
        first = self.run_cli("tags", "--json")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.env["FAKE_TAG_PREFIX"] = "fresh"
        cached = self.run_cli("tags", "--json")
        self.assertEqual(json.loads(cached.stdout)[0], "tag000")
        refreshed = self.run_cli("tags", "--refresh", "--json")
        self.assertEqual(refreshed.returncode, 0, refreshed.stdout + refreshed.stderr)
        self.assertEqual(json.loads(refreshed.stdout)[0], "fresh000")
        stored = json.loads(state.read_text())
        for key, value in previous.items():
            self.assertEqual(stored[key], value)
        self.assertEqual(stored["tag_cache"]["user:123"][""]["tags"], json.loads(refreshed.stdout))
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("test-secret", state.read_text())
        self.assertNotIn("password-secret", state.read_text())

    def test_tag_cache_is_scoped_by_exact_query_and_library(self):
        from urllib.parse import parse_qs
        for args in ((), ("--query", "read & review")):
            result = self.run_cli("tags", "--json", *args)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.config.write_text(self.config.read_text().replace('library_id = "123"', 'library_id = "456"'))
        result = self.run_cli("tags", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        stored = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(set(stored["tag_cache"]), {"user:123", "user:456"})
        self.assertEqual(set(stored["tag_cache"]["user:123"]), {"", "read & review"})
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertEqual(len(requests), 6)
        self.assertEqual(parse_qs(requests[2]["query"])["q"], ["read & review"])
        self.env["FAKE_METADATA_STATUS"] = "401"
        cached = self.run_cli("tags")
        self.assertEqual(cached.returncode, 0, cached.stdout + cached.stderr)
        self.assertTrue(cached.stdout.startswith("tag000\n"))
        self.assertEqual(len(self.requests.read_text().splitlines()), 6)

    def test_failed_second_refresh_page_retains_complete_old_cache(self):
        first = self.run_cli("tags", "--json")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        state = self.root / "state.db.json"
        original = state.read_bytes()
        self.env["FAKE_TAG_FAILURE_START"] = "100"
        result = self.run_cli("tags", "--refresh", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "zotero_error")
        self.assertEqual(state.read_bytes(), original)
        cached = self.run_cli("tags", "--json")
        self.assertEqual(cached.returncode, 0, cached.stdout + cached.stderr)
        self.assertEqual(json.loads(cached.stdout), json.loads(first.stdout))

    def test_tag_cache_corruption_is_not_silently_reset_even_on_refresh(self):
        state = self.root / "state.db.json"
        for contents in ("", "{broken", "[]",
                         '{"version":2,"mappings":{},"attempts":{}}',
                         '{"version":1,"mappings":{},"attempts":{},"tag_cache":null}',
                         '{"version":1,"mappings":{},"attempts":{}}\n'
                         '{"version":1,"mappings":{},"attempts":{}}'):
            with self.subTest(contents=contents):
                state.write_text(contents)
                result = self.run_cli("tags", "--refresh", "--json")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], "state_error")
                self.assertEqual(state.read_text(), contents)
        self.assertFalse(self.requests.exists())

    def test_tag_store_lock_is_shared_with_other_writers(self):
        import fcntl
        with (self.root / "state.db.json.lock").open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_cli("tags", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "busy")
        self.assertFalse(self.requests.exists())

    def test_tag_store_failed_rename_keeps_original_and_cleans_staging(self):
        first = self.run_cli("tags", "--json")
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        state = self.root / "state.db.json"
        original = state.read_bytes()
        move = self.bin / "mv"
        move.unlink()
        move.write_text("#!/bin/sh\nexit 1\n")
        move.chmod(0o755)
        result = self.run_cli("tags", "--refresh", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state.read_bytes(), original)
        self.assertEqual(list(self.root.glob("state.db.json.new.*")), [])

    def test_python_and_shell_share_the_same_tag_cache(self):
        from zotbridge.json_state import JsonStateStore
        store = JsonStateStore(str(self.root / "state.db.json"))
        store.tags("user:123", "", lambda: ["cached in Python"])
        self.env["FAKE_METADATA_STATUS"] = "401"
        result = self.run_cli("tags", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), ["cached in Python"])
        self.assertFalse(self.requests.exists())
        del self.env["FAKE_METADATA_STATUS"]
        refreshed = self.run_cli("tags", "--refresh", "--json")
        self.assertEqual(refreshed.returncode, 0, refreshed.stdout + refreshed.stderr)
        def unexpected_fetch():
            self.fail("Python must read the shell cache without fetching")
        self.assertEqual(store.tags("user:123", "", unexpected_fetch), json.loads(refreshed.stdout))

    def test_collections_fetch_and_cache_across_pages(self):
        self.env["FAKE_COLLECTION_TOTAL"] = "150"
        result = self.run_cli("collections", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        names = json.loads(result.stdout)
        self.assertEqual(len(names), 150)
        self.assertEqual(names[0], {"key": "COL00000", "name": "Folder 0"})
        requests = [json.loads(line) for line in self.requests.read_text().splitlines()]
        self.assertEqual(len(requests), 2)
        original = self.requests.read_bytes()
        self.env["FAKE_METADATA_STATUS"] = "401"
        cached = self.run_cli("collections", "--json")
        self.assertEqual(cached.returncode, 0, cached.stdout + cached.stderr)
        self.assertEqual(json.loads(cached.stdout), names)
        self.assertEqual(self.requests.read_bytes(), original)
        del self.env["FAKE_METADATA_STATUS"]
        self.env["FAKE_COLLECTION_PREFIX"] = "Fresh"
        refreshed = self.run_cli("collections", "--refresh", "--json")
        self.assertEqual(refreshed.returncode, 0, refreshed.stdout + refreshed.stderr)
        self.assertEqual(json.loads(refreshed.stdout)[0], {"key": "COL00000", "name": "Fresh 0"})
        stored = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(stored["collection_cache"]["user:123"]["collections"], json.loads(refreshed.stdout))

    def test_collection_cache_corruption_is_not_silently_reset(self):
        state = self.root / "state.db.json"
        for contents in ('{"version":1,"mappings":{},"attempts":{},"collection_cache":{"user:123":1}}',
                         '{"version":1,"mappings":{},"attempts":{},"collection_cache":null}'):
            with self.subTest(contents=contents):
                state.write_text(contents)
                result = self.run_cli("collections", "--refresh", "--json")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], "state_error")
                self.assertEqual(state.read_text(), contents)
        self.assertFalse(self.requests.exists())

    def test_python_and_shell_share_the_same_collection_cache(self):
        from zotbridge.json_state import JsonStateStore
        store = JsonStateStore(str(self.root / "state.db.json"))
        store.collections("user:123", lambda: [{"key": "COLLECTA", "name": "Papers"}])
        self.env["FAKE_METADATA_STATUS"] = "401"
        result = self.run_cli("collections", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), [{"key": "COLLECTA", "name": "Papers"}])
        self.assertFalse(self.requests.exists())

    def test_invalid_offsets_and_tag_expressions(self):
        for args in (("list", "--skip", "-1"), ("list", "--skip", "2147483648"),
                     ("list", "--tag", ""), ("list", "--tag", "one||two")):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertFalse(self.requests.exists())

    def test_missing_page_header_is_a_structured_error(self):
        self.env["FAKE_MISSING_TOTAL"] = "1"
        result = self.run_cli("list", "--page-info")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "zotero_error")

    def test_tag_listing_does_not_return_a_partial_success(self):
        self.env["FAKE_EMPTY_TAG_PAGE"] = "1"
        result = self.run_cli("tags", "--json")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "zotero_error")

    def test_webdav_failure_is_explicit_and_does_not_leak_secrets(self):
        self.env["FAKE_WEBDAV_STATUS"] = "401"
        result = self.run_cli("check-connection", "--item-key", "ITEM1234")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["ok"])
        self.assertNotIn("password-secret", result.stdout + result.stderr)
        self.assertNotIn("test-secret", result.stdout + result.stderr)

    def test_configuration_is_data_not_executable_shell(self):
        marker = self.root / "executed"
        with self.config.open("a") as config:
            config.write(f'unknown_setting = "$(touch {marker})"\n')
        self.run_cli("check-connection")
        self.assertFalse(marker.exists())

    def test_deferred_library_does_not_create_document_mapping(self):
        result = self.run_cli("library")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "not_implemented")
        self.assertFalse(self.requests.exists())
        self.assertFalse((self.root / "state.db.json").exists())

    def test_clear_mappings_is_library_scoped_and_preserves_documents_and_cache(self):
        state = self.root / "state.db.json"
        original = {
            "version": 1,
            "mappings": {
                "e90be5e8-32f6-46ec-bb75-32d827af9eee": {
                    "zotero_library_type": "user", "zotero_library_id": "123"},
                "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8": {
                    "zotero_library_type": "user", "zotero_library_id": "456"},
                "0242f228-8689-45c9-8303-5b0bc6a732c7": {
                    "zotero_library_type": "group", "zotero_library_id": "123"},
                "legacy": {"rm_uuid": "unscoped"},
            },
            "attempts": {"user:123": {"ITEM1234": {"state": "uncertain"}}},
            "tag_cache": {"user:123": {"": {"fetched_at": 100, "tags": ["one"]}}},
            "future": {"keep": True},
        }
        state.write_text(json.dumps(original))
        document = self.root / "document.pdf"
        document.write_bytes(b"%PDF-1.7\n")
        result = self.run_cli("clear-mappings")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "ok": True, "library_type": "user", "library_id": "123", "cleared": 1,
        })
        del original["mappings"]["e90be5e8-32f6-46ec-bb75-32d827af9eee"]
        original["collection_cache"] = {}
        self.assertEqual(json.loads(state.read_text()), original)
        self.assertEqual(document.read_bytes(), b"%PDF-1.7\n")
        unchanged = state.read_bytes()
        again = self.run_cli("clear-mappings")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(json.loads(again.stdout)["cleared"], 0)
        self.assertEqual(state.read_bytes(), unchanged)
        self.assertFalse(self.requests.exists())

    def test_clear_missing_state_does_not_create_a_store(self):
        result = self.run_cli("clear-mappings")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["cleared"], 0)
        self.assertFalse((self.root / "state.db.json").exists())
        self.assertFalse(self.requests.exists())

    def test_clear_corrupt_state_is_an_error_not_a_reset(self):
        state = self.root / "state.db.json"
        for contents in ("broken", '{"version":1,"mappings":{"bad":42},"attempts":{}}'):
            state.write_text(contents)
            result = self.run_cli("clear-mappings")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stdout)["error"], "state_error")
            self.assertEqual(state.read_text(), contents)
        self.assertFalse(self.requests.exists())

    def test_clear_lock_or_write_failure_preserves_existing_records(self):
        import fcntl
        state = self.root / "state.db.json"
        state.write_text(json.dumps({
            "version": 1, "mappings": {"e90be5e8-32f6-46ec-bb75-32d827af9eee": {
                "zotero_library_type": "user", "zotero_library_id": "123",
            }}, "attempts": {},
        }))
        original = state.read_bytes()
        with (self.root / "state.db.json.lock").open("a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            busy = self.run_cli("clear-mappings")
        self.assertNotEqual(busy.returncode, 0)
        self.assertEqual(json.loads(busy.stdout)["error"], "busy")
        self.assertEqual(state.read_bytes(), original)
        move = self.bin / "mv"
        move.unlink()
        move.write_text("#!/bin/sh\nexit 1\n")
        move.chmod(0o755)
        failed = self.run_cli("clear-mappings")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(json.loads(failed.stdout)["error"], "runtime_error")
        self.assertEqual(state.read_bytes(), original)
        self.assertEqual(list(self.root.glob("state.db.json.new.*")), [])

    def configure_broker(self):
        self.mb_in = self.root / "broker-in"
        self.mb_out = self.root / "broker-out"
        os.mkfifo(self.mb_in)
        os.mkfifo(self.mb_out)
        with self.config.open("a") as config:
            config.write(f'mb_in_path = "{self.mb_in}"\nmb_out_path = "{self.mb_out}"\n'
                         'broker_timeout_s = 0.3\n')

    @contextmanager
    def broker_reply(self, reply, on_request=None):
        ready, stop = threading.Event(), threading.Event()
        received, errors = [], []

        def serve():
            reader = os.open(self.mb_in, os.O_RDONLY | os.O_NONBLOCK)
            ready.set()
            try:
                for response in reply if isinstance(reply, list) else [reply]:
                    data = b""
                    while not stop.is_set() and b"\n" not in data:
                        try:
                            data += os.read(reader, 1024)
                        except BlockingIOError:
                            pass
                        stop.wait(0.001)
                    if stop.is_set():
                        return
                    received.append(data)
                    if on_request is not None:
                        on_request(data)
                    if response is None:
                        stop.wait(5)
                        return
                    while not stop.is_set():
                        try:
                            writer = os.open(self.mb_out, os.O_WRONLY | os.O_NONBLOCK)
                        except OSError as exc:
                            if exc.errno != errno.ENXIO:
                                raise
                            stop.wait(0.001)
                            continue
                        try:
                            os.write(writer, response[:10])
                            stop.wait(0.01)
                            os.write(writer, response[10:])
                        finally:
                            os.close(writer)
                        break
            except Exception as exc:
                errors.append(exc)
            finally:
                os.close(reader)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        try:
            self.assertTrue(ready.wait(3))
            yield received
        finally:
            stop.set()
            thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])

    def test_folder_command_uses_broker_without_network_or_import_state(self):
        self.configure_broker()
        uuid = "e90be5e8-32f6-46ec-bb75-32d827af9eee"
        for _ in range(2):
            with self.broker_reply(uuid.encode()) as received:
                result = self.run_cli("ensure-folder", "--target-folder", "Zotero/Test")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(received, [b">eensureFolder:Zotero/Test\n"])
            self.assertEqual(json.loads(result.stdout), {
                "ok": True, "folder_path": "Zotero/Test", "folder_uuid": uuid,
            })
        self.assertFalse(self.requests.exists())
        self.assertFalse((self.root / "state.db.json").exists())
        self.assertFalse(Path(str(self.mb_in) + ".zotbridge-pending").exists())

    def test_folder_timeout_blocks_retry_after_unconfirmed_request(self):
        self.configure_broker()
        with self.broker_reply(None) as received:
            result = self.run_cli("ensure-folder", "--target-folder", "Zotero/Test")
        self.assertEqual(received, [b">eensureFolder:Zotero/Test\n"])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "TimeoutError")
        retry = self.run_cli("ensure-folder", "--target-folder", "Zotero/Test")
        self.assertEqual(json.loads(retry.stdout)["error"], "BrokerRecoveryRequired")
        self.assertNotEqual(retry.returncode, 0)

    def test_folder_no_broker_reader_times_out(self):
        self.configure_broker()
        result = self.run_cli("ensure-folder", "--target-folder", "Zotero/Test")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "TimeoutError")

    def test_folder_rejects_error_and_malformed_broker_replies(self):
        self.configure_broker()
        for reply in (b"ERROR: handler failed", b"not-a-uuid", b""):
            with self.subTest(reply=reply), self.broker_reply(reply):
                result = self.run_cli("ensure-folder", "--target-folder", "Zotero/Test")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], "broker_error")

    def test_folder_requires_explicit_valid_path_and_real_fifos(self):
        for args in ((), ("--target-folder", ""), ("--target-folder", "Zotero//Test"),
                     ("--target-folder", "e90be5e8-32f6-46ec-bb75-32d827af9eee")):
            with self.subTest(args=args):
                result = self.run_cli("ensure-folder", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], "ValueError")
        self.configure_broker()
        self.mb_in.unlink()
        self.mb_in.write_text("not a FIFO")
        result = self.run_cli("ensure-folder", "--target-folder", "Zotero/Test")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.mb_in.read_text(), "not a FIFO")
        self.assertFalse(self.requests.exists())

    def use_busybox(self):
        binary = os.environ.get("ZOTBRIDGE_TEST_BUSYBOX")
        if not binary:
            self.skipTest("Set ZOTBRIDGE_TEST_BUSYBOX to exercise real BusyBox applets")
        for name in ("unzip", "dd", "stat", "sleep"):
            (self.bin / name).unlink(missing_ok=True)
            (self.bin / name).symlink_to(binary)

    def prepare_import(self):
        self.configure_broker()
        self.library = self.root / "library"
        self.library.mkdir()
        with self.config.open("a") as config:
            config.write(f'xochitl_dir = "{self.library}"\n')
        self.folder = b"e90be5e8-32f6-46ec-bb75-32d827af9eee"
        self.document = b"cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"

    def simulate_import(self, request):
        if not request.startswith(b">eimportDocument:"):
            return
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(state["mappings"], {})
        self.assertEqual(state["attempts"]["user:123"]["ITEM1234"]["state"], "uncertain")
        source, parent = request.decode().strip().split(":", 1)[1].rsplit(",", 1)
        self.assertEqual(parent, self.folder.decode())
        uuid = self.document.decode()
        shutil.copyfile(source, self.library / f"{uuid}.pdf")
        (self.library / f"{uuid}.metadata").write_text(json.dumps({
            "type": "DocumentType", "parent": parent, "visibleName": "Test Paper",
        }))
        (self.library / f"{uuid}.content").write_text('{"fileType":"pdf"}')

    def test_import_default_folder_mapping_status_and_repeat(self):
        self.use_busybox()
        self.prepare_import()
        with self.config.open("a") as config:
            config.write('default_target_folder = "Research/unread"\n')
        with self.broker_reply([self.folder, self.document], self.simulate_import) as requests:
            result = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(requests[0], b">eensureFolder:Research/unread\n")
        self.assertEqual(json.loads(result.stdout)["rm_uuid"], self.document.decode())
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(set(state["mappings"]), {self.document.decode()})
        self.assertEqual(state["mappings"][self.document.decode()]["rm_path"], "Research/unread")
        self.assertNotIn("ITEM1234", state["attempts"]["user:123"])
        network = self.requests.read_bytes()
        again = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertTrue(json.loads(again.stdout)["already_imported"])
        status = self.run_cli("status", "--item-key", "ITEM1234")
        self.assertEqual(status.returncode, 0, status.stdout + status.stderr)
        self.assertEqual(json.loads(status.stdout)["mapping"]["rm_uuid"], self.document.decode())
        self.assertEqual(self.requests.read_bytes(), network)
        listed = self.run_cli("list", "--json")
        self.assertEqual(listed.returncode, 0, listed.stdout + listed.stderr)
        self.assertEqual(json.loads(listed.stdout)[0]["mapping"]["rm_uuid"], self.document.decode())
        self.assertFalse(list(self.root.glob(".zotbridge-work.*")))

    def test_import_explicit_folder_overrides_config(self):
        self.prepare_import()
        with self.config.open("a") as config:
            config.write('default_target_folder = "Research/unread"\n')
        with self.broker_reply([self.folder, self.document], self.simulate_import) as requests:
            result = self.run_cli("import", "--item-key", "ITEM1234", "--target-folder", "Manual/inbox")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(requests[0], b">eensureFolder:Manual/inbox\n")

    def test_children_lists_only_downloadable_pdf_attachments(self):
        result = self.run_cli("children", "--item-key", "ITEM1234", "--json")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["ok"])
        self.assertEqual(data["item_key"], "ITEM1234")
        self.assertEqual(data["attachments"], [{"attachment_key": "HOSTED12", "title": "Paper.pdf"}])

    def test_import_with_explicit_attachment_key_and_selected_tags(self):
        self.prepare_import()
        with self.config.open("a") as config:
            config.write('default_target_folder = "Research/unread"\n')

        def on_request(request):
            self.simulate_import(request)
            if request.startswith(b">esetTags:"):
                payload = request.decode().strip().split(":", 1)[1]
                _, tags_csv = payload.split(",", 1)
                path = self.library / f"{self.document.decode()}.metadata"
                metadata = json.loads(path.read_text())
                metadata["tags"] = tags_csv.split(";")
                path.write_text(json.dumps(metadata))

        with self.broker_reply([self.folder, self.document, b"ok"], on_request) as requests:
            result = self.run_cli(
                "import", "--item-key", "ITEM1234", "--attachment-key", "HOSTED12",
                "--include-zotero-tags", "--add-unread-tag",
            )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["attachment_key"], "HOSTED12")
        self.assertTrue(data["remarkable_tags_updated"])
        self.assertEqual(len(requests), 3)
        self.assertTrue(requests[2].startswith(b">esetTags:" + self.document))
        tags = requests[2].decode().strip().split(",", 1)[1].split(";")
        self.assertEqual(set(tags), {"important", "unread"})

    def test_import_without_tag_flags_does_not_call_settags(self):
        self.prepare_import()
        with self.config.open("a") as config:
            config.write('default_target_folder = "Research/unread"\n')
        with self.broker_reply([self.folder, self.document], self.simulate_import) as requests:
            result = self.run_cli("import", "--item-key", "ITEM1234", "--attachment-key", "HOSTED12")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertFalse(data["remarkable_tags_updated"])
        self.assertEqual(len(requests), 2)

    def test_import_rejects_attachment_key_not_belonging_to_item(self):
        self.prepare_import()
        result = self.run_cli("import", "--item-key", "ITEM1234", "--attachment-key", "BADKEY99")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "zotero_error")

    def test_unconfirmed_import_blocks_repeat_and_reports_status(self):
        self.prepare_import()
        with self.broker_reply([self.folder, None], self.simulate_import):
            result = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "TimeoutError")
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(state["mappings"], {})
        network = self.requests.read_bytes()
        status = self.run_cli("status", "--item-key", "ITEM1234")
        self.assertNotEqual(status.returncode, 0)
        self.assertEqual(json.loads(status.stdout)["error"], "import_uncertain")
        repeat = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertEqual(json.loads(repeat.stdout)["error"], "import_uncertain")
        self.assertEqual(self.requests.read_bytes(), network)
        retry = self.run_cli("import", "--item-key", "ITEM1234", "--retry-uncertain")
        self.assertEqual(json.loads(retry.stdout)["error"], "BrokerRecoveryRequired")

    def test_unverified_import_does_not_create_a_mapping(self):
        self.prepare_import()
        with self.broker_reply([self.folder, self.document]):
            result = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "verification_error")
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(state["mappings"], {})
        self.assertEqual(state["attempts"]["user:123"]["ITEM1234"]["state"], "uncertain")

    def test_explicit_retry_after_broker_restart_records_new_uuid(self):
        self.prepare_import()
        with self.broker_reply([self.folder, None], self.simulate_import):
            first = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertEqual(json.loads(first.stdout)["error"], "TimeoutError")
        self.mb_in.rename(self.root / "old-in")
        self.mb_out.rename(self.root / "old-out")
        os.mkfifo(self.mb_in)
        os.mkfifo(self.mb_out)
        self.document = b"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        with self.broker_reply([self.folder, self.document], self.simulate_import):
            retry = self.run_cli("import", "--item-key", "ITEM1234", "--retry-uncertain")
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(set(state["mappings"]), {self.document.decode()})
        self.assertNotIn("ITEM1234", state["attempts"]["user:123"])
        self.assertFalse(Path(str(self.mb_in) + ".zotbridge-pending").exists())

    def test_truncated_import_is_not_marked_successful(self):
        self.prepare_import()
        def truncated(request):
            self.simulate_import(request)
            if request.startswith(b">eimportDocument:"):
                pdf = self.library / (self.document.decode() + ".pdf")
                pdf.write_bytes(pdf.read_bytes()[:-2])
        with self.broker_reply([self.folder, self.document], truncated):
            result = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "verification_error")
        self.assertEqual(json.loads((self.root / "state.db.json").read_text())["mappings"], {})

    def test_status_missing_and_invalid_default_folder(self):
        result = self.run_cli("status", "--item-key", "ITEM1234")
        self.assertEqual(json.loads(result.stdout)["error"], "not_found")
        self.assertFalse((self.root / "state.db.json").exists())
        with self.config.open("a") as config:
            config.write('default_target_folder = "Zotero//unread"\n')
        bad = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertNotEqual(bad.returncode, 0)
        self.assertEqual(json.loads(bad.stdout)["error"], "configuration_error")
        self.assertFalse(self.requests.exists())

    def test_busybox_downloads_encoded_pdf_without_head_or_od(self):
        self.use_busybox()
        for name in ("head", "od"):
            (self.bin / name).unlink(missing_ok=True)
        member = base64.b64encode(b"Paper.pdf").decode() + "%ZB64"
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(member, b"%PDF-1.7\nTest PDF\n")
        result = self.run_cli("check-connection", "--item-key", "ITEM1234")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["pdf_download"], "verified")
        self.assertFalse((self.root / "state.db.json").exists())

    def test_busybox_rejects_ambiguous_duplicate_and_unsafe_encoded_names(self):
        self.use_busybox()
        unsafe = base64.b64encode(b"../outside.pdf").decode() + "%ZB64"
        for names in (["a.pdf", "b.pdf"], ["Paper.pdf", "Paper.pdf"], [unsafe], ["[1].pdf"]):
            with self.subTest(names=names), warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
                    for name in names:
                        archive.writestr(name, b"%PDF-1.7\nTest PDF\n")
                result = self.run_cli("check-connection", "--item-key", "ITEM1234")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], "archive_error")

    def test_busybox_rejects_oversized_and_corrupt_pdf(self):
        self.use_busybox()
        with self.config.open("a") as config:
            config.write("webdav_max_download_mb = 1\n")
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Paper.pdf", b"%PDF-1.7\n" + b"x" * (1024 * 1024))
        large = self.run_cli("check-connection", "--item-key", "ITEM1234")
        self.assertEqual(json.loads(large.stdout)["error"], "archive_error")
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Paper.pdf", b"%PDF-1.7\nTest PDF\n" * 50)
            info = archive.getinfo("Paper.pdf")
        data = bytearray(self.archive.read_bytes())
        data[info.header_offset + 30 + len(info.filename) + info.compress_size // 2] ^= 1
        self.archive.write_bytes(data)
        corrupt = self.run_cli("check-connection", "--item-key", "ITEM1234")
        self.assertNotEqual(corrupt.returncode, 0)
        self.assertEqual(json.loads(corrupt.stdout)["error"], "archive_error")

    def setup_library_document(self, uuid, name="Test Paper", parent="", tags=None, deleted=False):
        self.library = self.root / "library"
        self.library.mkdir(exist_ok=True)
        if "xochitl_dir" not in self.config.read_text():
            with self.config.open("a") as config:
                config.write(f'xochitl_dir = "{self.library}"\n')
        metadata = {"type": "DocumentType", "parent": parent, "visibleName": name,
                    "deleted": deleted}
        if tags is not None:
            metadata["tags"] = tags
        (self.library / f"{uuid}.metadata").write_text(json.dumps(metadata))

    def install_stub_localgeta_and_seven_zip(self):
        local_geta = self.bin / "zotbridge-localgeta"
        local_geta.write_text("#!/bin/sh\nexit 1\n")
        local_geta.chmod(0o755)
        self.env["ZOTBRIDGE_LOCALGETA"] = str(local_geta)
        seven_zip = self.bin / "7zz"
        seven_zip.write_text("#!/bin/sh\nexit 1\n")
        seven_zip.chmod(0o755)
        self.env["ZOTBRIDGE_7ZZ"] = str(seven_zip)

    def test_doc_status_reports_unmapped_document(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        result = self.run_cli("doc-status", "--uuid", uuid)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "rm_uuid": uuid, "mapped": False})

    def test_doc_status_reports_mapped_document_with_zotero_title(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        state = self.root / "state.db.json"
        state.write_text(json.dumps({
            "version": 1, "mappings": {uuid: {
                "zotero_library_type": "user", "zotero_library_id": "123",
                "zotero_item_key": "ITEM1234", "zotero_attachment_key": "HOSTED12",
                "rm_path": "Research/unread", "updated_at": "2026-01-01 00:00:00"}},
            "attempts": {}, "tag_cache": {}, "collection_cache": {}}))
        result = self.run_cli("doc-status", "--uuid", uuid)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["mapped"])
        self.assertEqual(data["zotero_item_key"], "ITEM1234")
        self.assertEqual(data["zotero_attachment_key"], "HOSTED12")
        self.assertEqual(data["zotero_item_title"], "Test Paper")

    def test_doc_status_rejects_invalid_uuid(self):
        result = self.run_cli("doc-status", "--uuid", "not-a-uuid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "ValueError")

    def test_doc_tags_reads_remarkable_metadata_tags(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.setup_library_document(uuid, tags=["important", "unread"])
        result = self.run_cli("doc-tags", "--uuid", uuid)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["ok"], True)
        self.assertEqual(data["rm_uuid"], uuid)
        self.assertEqual(sorted(data["tags"]), ["important", "unread"])

    def test_doc_tags_rejects_missing_or_deleted_document(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.library = self.root / "library"
        self.library.mkdir()
        with self.config.open("a") as config:
            config.write(f'xochitl_dir = "{self.library}"\n')
        missing = self.run_cli("doc-tags", "--uuid", uuid)
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(json.loads(missing.stdout)["error"], "FileNotFoundError")
        self.setup_library_document(uuid, deleted=True)
        deleted = self.run_cli("doc-tags", "--uuid", uuid)
        self.assertNotEqual(deleted.returncode, 0)
        self.assertEqual(json.loads(deleted.stdout)["error"], "FileNotFoundError")

    def test_queue_for_zotero_validates_mode_and_related_options(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        cases = [
            (["--uuid", uuid, "--mode", "bogus"], "ValueError"),
            (["--uuid", uuid, "--mode", "attach"], "ValueError"),
            (["--uuid", uuid, "--mode", "new", "--parent-key", "ITEM1234"], "ValueError"),
            (["--uuid", uuid, "--mode", "attach", "--parent-key", "ITEM1234",
              "--collection", "COLL1234"], "ValueError"),
            (["--uuid", uuid, "--mode", "new", "--tags", "bad,tag,"], "ValueError"),
            (["--uuid", "not-a-uuid", "--mode", "new"], "ValueError"),
        ]
        for args, expected_error in cases:
            with self.subTest(args=args):
                result = self.run_cli("queue-for-zotero", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], expected_error)

    def test_queue_for_zotero_reports_missing_config_then_missing_document(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        # queue-for-zotero never touches localgeta/7z (no export happens), so the
        # first failure without a configured reverse_sync_folder is a plain
        # ValueError from validate_target_folder, not missing_dependency.
        missing_folder = self.run_cli("queue-for-zotero", "--uuid", uuid, "--mode", "new")
        self.assertNotEqual(missing_folder.returncode, 0)
        self.assertEqual(json.loads(missing_folder.stdout)["error"], "ValueError")
        self.library = self.root / "library"
        self.library.mkdir()
        with self.config.open("a") as config:
            config.write(f'xochitl_dir = "{self.library}"\n')
            config.write('reverse_sync_folder = "Zotero"\n')
        self.configure_broker()
        with self.broker_reply([b"11111111-1111-4111-8111-111111111111"]):
            not_found = self.run_cli("queue-for-zotero", "--uuid", uuid, "--mode", "new")
        self.assertNotEqual(not_found.returncode, 0)
        self.assertEqual(json.loads(not_found.stdout)["error"], "state_error")

    def setup_pdf_library_document(self, uuid, name="Test Paper", parent=""):
        self.setup_library_document(uuid, name=name, parent=parent)
        (self.library / f"{uuid}.content").write_text(json.dumps({"fileType": "pdf"}))
        (self.library / f"{uuid}.pdf").write_bytes(b"%PDF-1.7\nTest PDF\n")
        (self.library / f"{uuid}.pagedata").write_text("Blank\n")
        annotations_dir = self.library / uuid
        annotations_dir.mkdir()
        (annotations_dir / "page1.rm").write_bytes(b"reMarkable .lines file, version=6\n")

    def test_queue_for_zotero_new_mode_duplicates_and_stamps_metadata(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.setup_pdf_library_document(uuid)
        self.install_stub_localgeta_and_seven_zip()
        self.configure_broker()
        folder_uuid = "11111111-1111-4111-8111-111111111111"
        (self.library / f"{folder_uuid}.metadata").write_text(json.dumps(
            {"type": "CollectionType", "parent": "", "visibleName": "Zotero", "deleted": False}))
        with self.config.open("a") as config:
            config.write('reverse_sync_folder = "Zotero"\n')
        with self.broker_reply([folder_uuid.encode(), b"ok"]):
            result = self.run_cli("queue-for-zotero", "--uuid", uuid, "--mode", "new",
                                   "--tags", "important,unread", "--annotated-only")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data, {
            "ok": True, "rm_uuid": uuid, "duplicate_uuid": data["duplicate_uuid"],
            "name": "Test Paper", "mode": "new", "queued_folder": True,
        })
        duplicate_content = json.loads(
            (self.library / f"{data['duplicate_uuid']}.content").read_text())
        extra = duplicate_content["extraMetadata"]
        self.assertEqual(extra["ZotbridgeSourceUuid"], uuid)
        self.assertEqual(extra["ZotbridgeMode"], "new")
        self.assertEqual(extra["ZotbridgeTags"], "important,unread")
        self.assertEqual(extra["ZotbridgeAnnotatedOnly"], "true")
        self.assertTrue((self.library / f"{data['duplicate_uuid']}.pdf").exists())
        self.assertEqual(
            (self.library / f"{data['duplicate_uuid']}.pagedata").read_text(), "Blank\n")
        self.assertTrue(
            (self.library / data['duplicate_uuid'] / "page1.rm").exists())
        duplicate_metadata = json.loads(
            (self.library / f"{data['duplicate_uuid']}.metadata").read_text())
        self.assertEqual(duplicate_metadata["parent"], folder_uuid)
        self.assertFalse((self.root / "state.db.json").exists())

    def test_queue_for_zotero_attach_mode_records_mapping_immediately(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.setup_pdf_library_document(uuid)
        self.install_stub_localgeta_and_seven_zip()
        self.configure_broker()
        folder_uuid = "11111111-1111-4111-8111-111111111111"
        (self.library / f"{folder_uuid}.metadata").write_text(json.dumps(
            {"type": "CollectionType", "parent": "", "visibleName": "Zotero", "deleted": False}))
        with self.config.open("a") as config:
            config.write('reverse_sync_folder = "Zotero"\n')
        with self.broker_reply([folder_uuid.encode(), b"ok"]):
            result = self.run_cli("queue-for-zotero", "--uuid", uuid, "--mode", "attach",
                                   "--parent-key", "ITEM1234")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual(data["mode"], "attach")
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(state["mappings"][uuid]["zotero_item_key"], "ITEM1234")

    def test_send_to_zotero_requires_at_least_one_variant(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        result = self.run_cli("send-to-zotero", "--uuid", uuid, "--mode", "new")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "ValueError")

    def test_send_to_zotero_validates_mode_and_related_options(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        cases = [
            (["--uuid", uuid, "--mode", "bogus", "--send-plain"], "ValueError"),
            (["--uuid", uuid, "--mode", "attach", "--send-plain"], "ValueError"),
            (["--uuid", uuid, "--mode", "new", "--parent-key", "ITEM1234", "--send-plain"], "ValueError"),
            (["--uuid", uuid, "--mode", "attach", "--parent-key", "ITEM1234",
              "--collection", "COLL1234", "--send-plain"], "ValueError"),
            (["--uuid", "not-a-uuid", "--mode", "new", "--send-plain"], "ValueError"),
        ]
        for args, expected_error in cases:
            with self.subTest(args=args):
                result = self.run_cli("send-to-zotero", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(json.loads(result.stdout)["error"], expected_error)

    def test_send_to_zotero_rejects_missing_or_non_pdf_document(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.library = self.root / "library"
        self.library.mkdir()
        with self.config.open("a") as config:
            config.write(f'xochitl_dir = "{self.library}"\n')
            config.write('reverse_sync_folder = "Zotero"\n')
        self.install_stub_localgeta_and_seven_zip()
        # zotbridge-shell.sh already checked --send-plain-or-similar presence and
        # webdav/library configuration before this point can be reached; here we
        # confirm send_to_zotero's own document existence/type checks.
        missing = self.run_cli("send-to-zotero", "--uuid", uuid, "--mode", "new", "--send-plain")
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(json.loads(missing.stdout)["error"], "FileNotFoundError")
        self.setup_library_document(uuid)
        (self.library / f"{uuid}.content").write_text(json.dumps({"fileType": "epub"}))
        (self.library / f"{uuid}.pdf").write_bytes(b"not actually used")
        not_pdf = self.run_cli("send-to-zotero", "--uuid", uuid, "--mode", "new", "--send-plain")
        self.assertNotEqual(not_pdf.returncode, 0)
        self.assertEqual(json.loads(not_pdf.stdout)["error"], "unsupported_export")

    def test_send_to_zotero_rejects_invalid_attach_parent(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.setup_pdf_library_document(uuid)
        self.install_stub_localgeta_and_seven_zip()
        result = self.run_cli("send-to-zotero", "--uuid", uuid, "--mode", "attach",
                               "--parent-key", "HOSTED12", "--send-plain")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["error"], "ValueError")

    def test_send_to_zotero_requires_localgeta_only_for_markup_variants(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.setup_pdf_library_document(uuid)
        seven_zip = self.bin / "7zz"
        seven_zip.write_text("#!/bin/sh\nexit 1\n")
        seven_zip.chmod(0o755)
        self.env["ZOTBRIDGE_7ZZ"] = str(seven_zip)
        merged = self.run_cli("send-to-zotero", "--uuid", uuid, "--mode", "new", "--send-merged")
        self.assertNotEqual(merged.returncode, 0)
        self.assertEqual(json.loads(merged.stdout)["error"], "missing_dependency")

    def test_send_to_zotero_skips_markup_variants_without_uploading_when_no_annotations(self):
        uuid = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"
        self.setup_pdf_library_document(uuid)
        # zotbridge-localgeta itself now decides whether a document has any
        # markup: -k means "annotated pages only", and it exits 3 when none
        # qualify. There is no broker call in this path anymore.
        local_geta = self.bin / "zotbridge-localgeta"
        local_geta.write_text(
            "#!/bin/sh\n"
            'k=; for arg do case "$prev" in -output) out=$arg;; esac\n'
            '  case "$arg" in -k) k=1;; esac; prev=$arg; done\n'
            '[ -n "$k" ] && exit 3\n'
            'printf "%%PDF-1.7\\nExported\\n" >"$out"\n'
        )
        local_geta.chmod(0o755)
        self.env["ZOTBRIDGE_LOCALGETA"] = str(local_geta)
        seven_zip = self.bin / "7zz"
        seven_zip.write_text("#!/bin/sh\nexit 1\n")
        seven_zip.chmod(0o755)
        self.env["ZOTBRIDGE_7ZZ"] = str(seven_zip)
        result = self.run_cli("send-to-zotero", "--uuid", uuid, "--mode", "new", "--send-merged")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = json.loads(result.stdout)
        self.assertTrue(data["ok"])
        self.assertIsNone(data["zotero_item_key"])
        self.assertEqual(data["variants"], [{"variant": "merged", "status": "skipped_no_markup"}])
        self.assertFalse(data["tags_updated"])
        self.assertFalse(self.requests.exists())
        self.assertFalse((self.root / "state.db.json").exists())


if __name__ == "__main__":
    unittest.main()
