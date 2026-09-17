#!/usr/bin/env python3
"""Offline shell-backend integration tests; all fixtures stay under the repo.

Run: python3 scripts/test-shell.py
Requires Bash, jq, Info-ZIP unzip, flock, and standard Linux utilities.
Never reads the user's config or touches tablet paths.
"""
import base64
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import signal
import threading
import time
import unittest
import zipfile


ROOT = Path(__file__).resolve().parent.parent
API = "https://api.zotero.org/users/123"
FOLDER = "e90be5e8-32f6-46ec-bb75-32d827af9eee"
DOCUMENT = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"


class ShellTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / f".shell-tests-{os.getpid()}-{self._testMethodName}"
        self.root.mkdir(mode=0o700)
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "bin").mkdir()
        mock = self.root / "bin" / "curl"
        shutil.copyfile(ROOT / "scripts" / "test-shell-curl.py", mock)
        mock.chmod(0o700)
        self.library = self.root / "library"
        self.library.mkdir()
        self.input = self.root / "input"
        self.output = self.root / "output"
        self.config = {
            "library_id": "123", "library_type": "user", "api_key": "fixture-api-secret",
            "mb_in_path": str(self.input), "mb_out_path": str(self.output),
            "xochitl_dir": str(self.library), "state_db_path": "state.db",
            "broker_timeout_s": 0.3,
        }
        self.routes = {
            API + "/items/top?limit=1": {"body": []},
            API + "/items/ITEM1234/children?limit=100&start=0": {"body": [
                {"data": {"key": "LINKED12", "contentType": "application/pdf", "linkMode": "linked_file"}},
                {"data": {"key": "HOSTED12", "contentType": "application/pdf", "linkMode": "imported_file"}}]},
            API + "/items/HOSTED12/file": {"body": "%PDF-1.7\nfixture"},
            API + "/items/HOSTED12": {"body": {"data": {"filename": "Paper.pdf"}}},
            API + "/items/ITEM1234": {"body": {"data": {"title": "A paper: with / separators"}}},
        }
        self.env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                        ZOTBRIDGE_CONFIG=str(self.root / "fixture.toml"),
                        ZOTBRIDGE_WORK_DIR=str(self.root), SHELL_TEST_ROOT=str(self.root),
                        ZOTBRIDGE_BACKEND="shell", ZOTBRIDGE_CURL=str(mock))
        # WSL's Windows mounts without metadata cannot represent Unix modes.
        # Native Linux runs enforce the curl configuration permission assertion.
        self.env["SHELL_TEST_REQUIRE_MODES"] = str(int(stat.S_IMODE(mock.stat().st_mode) == 0o700))
        self.write_config()

    def write_config(self):
        (self.root / "fixture.toml").write_bytes(("# fixture with CRLF\r\n" + "\r\n".join(
            f"{key} = {json.dumps(value)} # comment" for key, value in self.config.items()
        ) + "\r\n").encode())

    def run_cli(self, *args, expected=0):
        (self.root / "routes.json").write_text(json.dumps(self.routes))
        result = subprocess.run(["sh", str(ROOT / "scripts" / "zotbridge-run.sh"), *args],
                                env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("fixture-api-secret", result.stdout + result.stderr)
        self.assertNotIn("fixture-password", result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertEqual(list(self.root.glob(".zotbridge-work.*")), [])
        return json.loads(result.stdout)

    def calls(self):
        path = self.root / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    @contextmanager
    def broker(self, replies, verify=True, keep_open=False):
        self.make_fifos()
        received = []
        errors = []
        stop = threading.Event()
        ready = threading.Event()

        def serve():
            reader = os.open(self.input, os.O_RDONLY | os.O_NONBLOCK)
            ready.set()
            try:
                for reply in replies:
                    data = b""
                    while b"\n" not in data and not stop.is_set():
                        try:
                            data += os.read(reader, 4096)
                        except BlockingIOError:
                            pass
                        stop.wait(0.001)
                    if stop.is_set():
                        return
                    received.append(data)
                    if verify and data.startswith(b">eimportDocument:"):
                        source, parent = data.decode().strip().split(":", 1)[1].rsplit(",", 1)
                        self.assertEqual(parent, FOLDER)
                        shutil.copyfile(source, self.library / f"{DOCUMENT}.pdf")
                        (self.library / f"{DOCUMENT}.metadata").write_text(json.dumps(
                            {"type": "DocumentType", "parent": FOLDER, "visibleName": "Paper"}))
                        (self.library / f"{DOCUMENT}.content").write_text('{"fileType":"pdf"}')
                    if reply is None:
                        stop.wait(2)
                        return
                    writer = None
                    while not stop.is_set():
                        try:
                            writer = os.open(self.output, os.O_WRONLY | os.O_NONBLOCK)
                            break
                        except OSError:
                            stop.wait(0.001)
                    if writer is None:
                        return
                    try:
                        reply = reply.encode() if isinstance(reply, str) else reply
                        os.write(writer, reply[:10])
                        time.sleep(0.005)
                        os.write(writer, reply[10:])
                        if keep_open:
                            stop.wait(2)
                    finally:
                        os.close(writer)
            except Exception as exc:
                errors.append(exc)
            finally:
                os.close(reader)

        thread = threading.Thread(target=serve)
        thread.start()
        self.assertTrue(ready.wait(1))
        try:
            yield received
        finally:
            stop.set()
            thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])

    def make_fifos(self):
        if not self.input.exists():
            try:
                os.mkfifo(self.input)
                os.mkfifo(self.output)
            except OSError as exc:
                if exc.errno == 95:
                    self.skipTest("FIFO tests require the checkout on a Linux filesystem, not WSL /mnt/c")
                raise

    def webdav(self, entries):
        self.config.update(use_webdav=True, webdav_url="https://dav.example/zotero",
                           webdav_username="fixture-user", webdav_password="fixture-password",
                           webdav_max_download_mb=1)
        self.write_config()
        with zipfile.ZipFile(self.root / "archive.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, body in entries:
                archive.writestr(name, body)
        self.routes["https://dav.example/zotero/HOSTED12.zip"] = {"file": "archive.zip"}

    def test_metadata_only_no_state(self):
        result = self.run_cli("check-connection")
        self.assertEqual(result["pdf_download"], "not_tested")
        self.assertEqual(len(self.calls()), 1)
        self.assertFalse((self.root / "state.db.json").exists())
        self.assertFalse((self.root / "state.db").exists())

    def test_curl_override_is_validated(self):
        self.env["ZOTBRIDGE_CURL"] = str(self.root / "missing-curl")
        self.assertEqual(self.run_cli("check-connection", expected=1)["error"], "missing_dependency")
        self.assertEqual(self.calls(), [])

    def test_private_curl_configuration(self):
        if self.env["SHELL_TEST_REQUIRE_MODES"] != "1":
            self.skipTest("Unix permission checks require a native Linux filesystem")
        self.run_cli("check-connection")

    def test_existing_mapping_and_uncertainty_do_no_network_work(self):
        state = {"version": 1, "mappings": {"ITEM1234": {
            "zotero_item_key": "ITEM1234", "zotero_attachment_key": "HOSTED12",
            "rm_uuid": DOCUMENT, "rm_path": "Zotero/unread", "state": "imported",
            "updated_at": "2026-09-16 00:00:00",
        }}, "attempts": {}}
        (self.root / "state.db.json").write_text(json.dumps(state))
        self.assertTrue(self.run_cli("import", "--item-key", "ITEM1234")["already_imported"])
        state["attempts"]["ITEM1234"] = dict(state["mappings"].pop("ITEM1234"), state="uncertain")
        (self.root / "state.db.json").write_text(json.dumps(state))
        self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "import_uncertain")
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234", expected=1)["error"], "import_uncertain")
        self.assertEqual(self.calls(), [])

    def test_sqlite_state_is_never_read_or_overwritten(self):
        database = self.root / "state.db"
        database.write_bytes(b"SQLite format 3\0fixture")
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234", expected=1)["error"], "not_found")
        self.assertEqual(database.read_bytes(), b"SQLite format 3\0fixture")
        (self.root / "state.db.json").write_text("{invalid")
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234", expected=1)["error"], "state_error")

    def test_download_header_and_stream_size_limits(self):
        for body in ("\0%PDF-1.7", "<html>login</html>"):
            self.routes[API + "/items/HOSTED12/file"] = {"body": body}
            self.assertEqual(self.run_cli("check-connection", "--item-key", "ITEM1234", expected=1)["error"],
                             "download_error")
        self.config["zotero_max_download_mb"] = 1
        self.write_config()
        (self.root / "too-large.pdf").write_bytes(b"%PDF-1.7\n" + b"x" * (1024 * 1024))
        self.routes[API + "/items/HOSTED12/file"] = {"file": "too-large.pdf"}
        self.assertEqual(self.run_cli("check-connection", "--item-key", "ITEM1234", expected=1)["error"],
                         "network_error")

    def test_invalid_config_and_no_shell_evaluation(self):
        self.config["api_key"] = 'a#b"\\$(touch SHELL_CONFIG_EXECUTED)'
        self.write_config()
        self.run_cli("check-connection")
        self.assertFalse((ROOT / "SHELL_CONFIG_EXECUTED").exists())
        for bad in ('library_type="invalid"', '[zotero]', 'library_id="123"',
                    "unknown='literal'", "use_webdav=\"True\""):
            self.write_config()
            with (self.root / "fixture.toml").open("a") as stream:
                stream.write(bad + "\n")
            self.assertEqual(self.run_cli("check-connection", expected=1)["error"], "configuration_error")

    def test_list_fields_and_pagination(self):
        self.routes[API + "/items/top?limit=20&q=hello%20world"] = {"body": [
            {"data": {"key": "ITEM1234", "itemType": "book", "title": " A book ", "date": "2020"}},
            {"data": {"key": "NOTE1234", "itemType": "note"}}]}
        self.routes[API + "/items/ITEM1234/children?limit=100&start=0"] = {"body": [
            {"data": {"contentType": "text/plain"}}] * 100}
        self.routes[API + "/items/ITEM1234/children?limit=100&start=100"] = {"body": [
            {"data": {"key": "HOSTED12", "contentType": "application/pdf", "linkMode": "imported_url"}}]}
        result = self.run_cli("list", "--query", "hello world", "--json")
        self.assertEqual(result, [{"item_key": "ITEM1234", "title": "A book", "year": "2020",
                                  "has_pdf": True, "mapping": None, "attempt": None}])

    def test_zotero_redirect_drops_credentials(self):
        self.routes[API + "/items/HOSTED12/file"] = {
            "status": 302, "headers": {"Location": "https://storage.example/paper?signature=fixture"}}
        self.routes["https://storage.example/paper?signature=fixture"] = {"body": "%PDF-1.7\nfixture"}
        result = self.run_cli("check-connection", "--item-key", "ITEM1234")
        self.assertEqual(result["pdf_download"], "verified")
        storage = next(call for call in self.calls() if "storage.example" in call["url"])
        self.assertFalse(storage["api"])
        self.assertFalse(storage["basic"])

    def test_import_and_repeat_suppression(self):
        with self.broker([FOLDER, DOCUMENT]) as requests:
            result = self.run_cli("import", "--item-key", "ITEM1234")
        self.assertEqual(result["rm_uuid"], DOCUMENT)
        self.assertEqual(requests[0], b">eensureFolder:Zotero/unread\n")
        self.assertIn(b"/A paper_ with _ separators.pdf," + FOLDER.encode(), requests[1])
        count = len(self.calls())
        self.assertTrue(self.run_cli("import", "--item-key", "ITEM1234")["already_imported"])
        self.assertEqual(len(self.calls()), count)
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234")["mapping"]["rm_uuid"], DOCUMENT)
        self.assertFalse((self.root / "state.db").exists())

    def test_missing_import_reply_remains_uncertain(self):
        with self.broker([FOLDER, None]):
            self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "TimeoutError")
        result = self.run_cli("status", "--item-key", "ITEM1234", expected=1)
        self.assertEqual(result["error"], "import_uncertain")
        self.assertTrue(Path(str(self.input) + ".zotbridge-pending").exists())
        self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "import_uncertain")
        self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", "--retry-uncertain", expected=1)["error"],
                         "BrokerRecoveryRequired")

    def test_recreated_pipes_allow_explicit_uncertain_retry(self):
        with self.broker([FOLDER, None]):
            self.run_cli("import", "--item-key", "ITEM1234", expected=1)
        self.input.rename(self.root / "old-input")
        self.output.rename(self.root / "old-output")
        self.make_fifos()
        with self.broker([FOLDER, DOCUMENT]):
            self.assertFalse(self.run_cli("import", "--item-key", "ITEM1234", "--retry-uncertain")["already_imported"])
        state = json.loads((self.root / "state.db.json").read_text())
        self.assertEqual(state["attempts"], {})
        self.assertEqual(state["mappings"]["ITEM1234"]["rm_uuid"], DOCUMENT)
        self.assertFalse(Path(str(self.input) + ".zotbridge-pending").exists())
        self.assertEqual(list(self.root.glob("state.db.json.new.*")), [])

    def test_existing_python_recovery_marker_is_honored(self):
        self.make_fifos()
        identity = [[path.stat().st_dev, path.stat().st_ino] for path in (self.input, self.output)]
        pending = Path(str(self.input) + ".zotbridge-pending")
        pending.write_text(json.dumps(identity))
        self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"],
                         "BrokerRecoveryRequired")
        self.assertEqual(json.loads(pending.read_text()), identity)

    def test_import_and_broker_lock_contention(self):
        for lock_path in (self.root / "state.db.json.lock", self.root / "state.lock"):
            with lock_path.open("w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "busy")
        self.assertEqual(self.calls(), [])
        self.make_fifos()
        with Path(str(self.input) + ".zotbridge.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "busy")
        self.assertFalse(Path(str(self.input) + ".zotbridge-pending").exists())

    def test_full_input_fifo_write_is_bounded(self):
        self.make_fifos()
        descriptor = os.open(self.input, os.O_RDWR | os.O_NONBLOCK)
        try:
            while True:
                try:
                    os.write(descriptor, b"x" * 4096)
                except BlockingIOError:
                    break
            start = time.monotonic()
            self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "TimeoutError")
            self.assertLess(time.monotonic() - start, 5)
            self.assertTrue(Path(str(self.input) + ".zotbridge-pending").exists())
        finally:
            os.close(descriptor)

    def test_broker_request_byte_limit_and_unsafe_folder_rejection(self):
        maximum = "x" * (1024 - len(b">eensureFolder:\n"))
        with self.broker([FOLDER, DOCUMENT]) as requests:
            self.run_cli("import", "--item-key", "ITEM1234", "--target-folder", maximum)
        self.assertEqual(len(requests[0]), 1024)
        (self.root / "state.db.json").unlink()
        for target in (maximum + "x", "\u03b1" * 512, "A//B", "A\nB", FOLDER.replace("-", ""), "{"+FOLDER+"}"):
            self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", "--target-folder", target,
                                         expected=1)["error"], "ValueError")
        self.assertFalse(Path(str(self.input) + ".zotbridge-pending").exists())

    def test_termination_kills_owned_fifo_worker(self):
        self.make_fifos()
        self.config["broker_timeout_s"] = 10
        self.write_config()
        (self.root / "routes.json").write_text(json.dumps(self.routes))
        process = subprocess.Popen(["sh", str(ROOT / "scripts" / "zotbridge-run.sh"), "import",
                                    "--item-key", "ITEM1234"], env=self.env, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        worker = None
        try:
            until = time.monotonic() + 8
            while time.monotonic() < until and process.poll() is None:
                if Path(str(self.input) + ".zotbridge-pending").exists():
                    children = Path(f"/proc/{process.pid}/task/{process.pid}/children").read_text().split()
                    for child in children:
                        try:
                            command = Path(f"/proc/{child}/cmdline").read_bytes().split(b"\0")[0]
                        except FileNotFoundError:
                            continue
                        if command.endswith(b"bash"):
                            worker = int(child)
                            break
                if worker is not None:
                    break
                time.sleep(0.005)
            self.assertIsNotNone(worker, "blocked FIFO worker did not start")
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(json.loads(stdout)["error"], "interrupted")
            self.assertEqual(stderr, "")
            self.assertFalse(Path(f"/proc/{worker}").exists(), "FIFO worker survived the parent")
            self.assertEqual(list(self.root.glob(".zotbridge-work.*")), [])
            self.assertTrue(Path(str(self.input) + ".zotbridge-pending").exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            if worker is not None and Path(f"/proc/{worker}").exists():
                os.kill(worker, signal.SIGKILL)

    def test_fifo_open_timeout_is_bounded(self):
        self.make_fifos()
        start = time.monotonic()
        self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "TimeoutError")
        self.assertLess(time.monotonic() - start, 5)
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234", expected=1)["error"], "not_found")

    def test_valid_uuid_without_eof_is_not_confirmation(self):
        with self.broker([FOLDER], keep_open=True):
            self.assertEqual(self.run_cli("import", "--item-key", "ITEM1234", expected=1)["error"], "TimeoutError")
        self.assertTrue(Path(str(self.input) + ".zotbridge-pending").exists())
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234", expected=1)["error"], "not_found")

    def test_broker_invalid_responses_and_nul(self):
        for reply in ("ERROR: fixture-password", "", "ok", "a" * 32, FOLDER + "\n" + DOCUMENT, FOLDER.encode() + b"\0"):
            with self.broker([reply]):
                result = self.run_cli("import", "--item-key", "ITEM1234", expected=1)
                self.assertEqual(result["error"], "broker_error")
            pending = Path(str(self.input) + ".zotbridge-pending")
            pending.unlink(missing_ok=True)

    def test_verification_failure_is_not_success(self):
        with self.broker([FOLDER, DOCUMENT], verify=False):
            result = self.run_cli("import", "--item-key", "ITEM1234", expected=1)
        self.assertEqual(result["error"], "verification_error")
        self.assertEqual(self.run_cli("status", "--item-key", "ITEM1234", expected=1)["error"], "import_uncertain")

    def test_webdav_plain_and_encoded_filename(self):
        for name in ("Paper.pdf", base64.b64encode(b"Paper.pdf").decode() + "%ZB64"):
            self.webdav([(name, b"%PDF-1.7\nfixture")])
            self.assertEqual(self.run_cli("check-connection", "--item-key", "ITEM1234")["storage"], "webdav")
        for call in self.calls():
            if "dav.example" in call["url"]:
                self.assertTrue(call["basic"])
                self.assertFalse(call["api"])
        self.assertFalse((self.root / "state.db.json").exists())

    def test_webdav_unsafe_ambiguous_and_oversize(self):
        cases = [
            [("../Paper.pdf", b"%PDF-1.7")],
            [("/Paper.pdf", b"%PDF-1.7")],
            [("C:\\Paper.pdf", b"%PDF-1.7")],
            [(base64.b64encode(b"../Paper.pdf").decode() + "%ZB64", b"%PDF-1.7")],
            [(base64.b64encode(b"\xffPaper.pdf").decode() + "%ZB64", b"%PDF-1.7")],
            [("!not-base64!%ZB64", b"%PDF-1.7")],
            [("new\nline.pdf", b"%PDF-1.7")],
            [("one.pdf", b"x"), ("two.pdf", b"x")],
            [("Paper.pdf", b"x" * (1024 * 1024 + 1))],
            [("bad[1].pdf", b"%PDF-1.7")],
            [("bad].pdf", b"%PDF-1.7")],
            [("bad*.pdf", b"%PDF-1.7")],
            [("bad?.pdf", b"%PDF-1.7")],
        ]
        for entries in cases:
            self.webdav(entries)
            self.assertEqual(self.run_cli("check-connection", "--item-key", "ITEM1234", expected=1)["error"], "webdav_error")

    def test_webdav_symlinks_are_rejected(self):
        self.webdav([])
        entry = zipfile.ZipInfo("Paper.pdf")
        entry.create_system = 3
        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.root / "archive.zip", "w") as archive:
            archive.writestr(entry, b"%PDF-1.7\n")
        self.assertEqual(self.run_cli("check-connection", "--item-key", "ITEM1234", expected=1)["error"], "webdav_error")

    def test_webdav_redirect_never_followed(self):
        self.webdav([("Paper.pdf", b"%PDF-1.7")])
        self.routes["https://dav.example/zotero/HOSTED12.zip"] = {
            "status": 302, "headers": {"Location": "https://untrusted.example/"}}
        self.run_cli("check-connection", "--item-key", "ITEM1234", expected=1)
        self.assertFalse(any("untrusted.example" in call["url"] for call in self.calls()))

    def test_library_read_only_trash_and_warnings(self):
        folder = {"visibleName": "Zotero", "parent": "", "type": "CollectionType"}
        document = {"visibleName": "Paper", "parent": FOLDER, "type": "DocumentType"}
        (self.library / f"{FOLDER}.metadata").write_text(json.dumps(folder))
        (self.library / f"{DOCUMENT}.metadata").write_text(json.dumps(document))
        (self.library / "bad.metadata").write_text("{")
        result = self.run_cli("library")
        self.assertEqual([entry["path"] for entry in result["entries"]], ["Zotero", "Zotero/Paper"])
        self.assertEqual(len(result["warnings"]), 1)
        folder["parent"] = "trash"
        (self.library / f"{FOLDER}.metadata").write_text(json.dumps(folder))
        self.assertEqual(self.run_cli("library")["entries"], [])
        self.assertEqual(self.calls(), [])
        self.assertFalse((self.root / "state.db.json").exists())


if __name__ == "__main__":
    if Path("/home/root/.vellum/bin/curl").exists():
        raise SystemExit("Refusing to run fixture tests on a tablet using the dedicated curl path.")
    unittest.main()
