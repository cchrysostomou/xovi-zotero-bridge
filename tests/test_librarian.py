from contextlib import contextmanager
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest

from zotbridge.librarian import BrokerRecoveryRequired, LibrarianBridge


FOLDER_ID = "e90be5e8-32f6-46ec-bb75-32d827af9eee"
DOCUMENT_ID = "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8"


@unittest.skipUnless(os.name == "posix", "Real FIFO tests require Linux")
class FifoTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.input = self.root / "input"
        self.output = self.root / "output"
        os.mkfifo(self.input)
        os.mkfifo(self.output)
        self.bridge = LibrarianBridge(str(self.input), str(self.output), timeout_s=0.3)

    @contextmanager
    def broker(self, response, chunks=False, keep_open=False):
        ready = threading.Event()
        stop = threading.Event()
        received = []
        errors = []

        def serve():
            reader = os.open(self.input, os.O_RDONLY | os.O_NONBLOCK)
            try:
                ready.set()
                data = bytearray()
                while not stop.is_set():
                    try:
                        data.extend(os.read(reader, 1024))
                    except BlockingIOError:
                        pass
                    if b"\n" in data:
                        received.append(bytes(data))
                        if response is not None:
                            writer = os.open(self.output, os.O_WRONLY | os.O_NONBLOCK)
                            try:
                                encoded = response.encode("utf-8")
                                if chunks:
                                    os.write(writer, encoded[:10])
                                    time.sleep(0.02)
                                    os.write(writer, encoded[10:])
                                else:
                                    os.write(writer, encoded)
                                if keep_open:
                                    stop.wait(1)
                            finally:
                                os.close(writer)
                        return
                    stop.wait(0.002)
            except OSError as exc:
                errors.append(exc)
            finally:
                os.close(reader)

        worker = threading.Thread(target=serve)
        worker.start()
        self.assertTrue(ready.wait(1), "fake broker did not start")
        try:
            yield received
        finally:
            stop.set()
            worker.join(1)
            self.assertFalse(worker.is_alive(), "fake broker did not stop")
            self.assertEqual(errors, [])

    def test_exact_request_and_eof_framed_chunked_uuid_response(self):
        with self.broker(FOLDER_ID, chunks=True) as requests:
            self.assertEqual(self.bridge.ensure_folder("Zotero/unread"), FOLDER_ID)
        self.assertEqual(requests, [b">eensureFolder:Zotero/unread\n"])
        self.assertFalse(self.bridge.pending_path.exists())

    def test_import_uses_absolute_pdf_and_parent_uuid(self):
        pdf = self.root / "Paper.pdf"
        pdf.write_bytes(b"%PDF-1.7\n")
        with self.broker(DOCUMENT_ID) as requests:
            self.assertEqual(self.bridge.import_document(str(pdf), FOLDER_ID), DOCUMENT_ID)
        self.assertEqual(requests, [f">eimportDocument:{pdf},{FOLDER_ID}\n".encode()])

    def test_error_empty_and_invalid_uuid_are_never_success(self):
        for response in ("ERROR: import failed", "", "ok", FOLDER_ID + "\n" + DOCUMENT_ID):
            with self.subTest(response=response):
                with self.broker(response):
                    with self.assertRaises((RuntimeError, ValueError)):
                        self.bridge.ensure_folder("Zotero")
                self.assertFalse(self.bridge.pending_path.exists())

    def test_input_open_timeout_is_bounded_without_a_broker_reader(self):
        start = time.monotonic()
        with self.assertRaises(TimeoutError):
            self.bridge.ensure_folder("Zotero")
        self.assertLess(time.monotonic() - start, 1.0)
        self.assertFalse(self.bridge.pending_path.exists())

    def test_missing_reply_is_bounded_and_blocks_stale_reply_reuse(self):
        start = time.monotonic()
        with self.broker(None):
            with self.assertRaises(TimeoutError):
                self.bridge.ensure_folder("Zotero")
        self.assertLess(time.monotonic() - start, 1.0)
        self.assertTrue(self.bridge.pending_path.exists())
        with self.assertRaises(BrokerRecoveryRequired):
            self.bridge.ensure_folder("Zotero")

    def test_response_without_eof_times_out_even_with_a_valid_uuid(self):
        start = time.monotonic()
        with self.broker(FOLDER_ID, keep_open=True):
            with self.assertRaises(TimeoutError):
                self.bridge.ensure_folder("Zotero")
        self.assertLess(time.monotonic() - start, 1.0)
        self.assertTrue(self.bridge.pending_path.exists())

    def test_full_input_pipe_write_has_a_deadline(self):
        descriptor = os.open(self.input, os.O_RDWR | os.O_NONBLOCK)
        try:
            while True:
                try:
                    os.write(descriptor, b"x" * 4096)
                except BlockingIOError:
                    break
            start = time.monotonic()
            with self.assertRaises(TimeoutError):
                self.bridge.ensure_folder("Zotero")
            self.assertLess(time.monotonic() - start, 1.0)
        finally:
            os.close(descriptor)

    def test_request_limit_is_utf8_bytes_including_framing(self):
        overhead = len(b">eensureFolder:\n")
        folder = "x" * (1024 - overhead)
        with self.broker(FOLDER_ID) as requests:
            self.assertEqual(self.bridge.ensure_folder(folder), FOLDER_ID)
        self.assertEqual(len(requests[0]), 1024)
        with self.assertRaises(ValueError):
            self.bridge.ensure_folder(folder + "x")
        with self.assertRaises(ValueError):
            self.bridge.ensure_folder("\N{GREEK SMALL LETTER ALPHA}" * 512)

    def test_recreated_pipes_allow_recovery(self):
        with self.broker(None):
            with self.assertRaises(TimeoutError):
                self.bridge.ensure_folder("Zotero")
        self.input.rename(self.root / "old-input")
        self.output.rename(self.root / "old-output")
        os.mkfifo(self.input)
        os.mkfifo(self.output)
        with self.broker(FOLDER_ID):
            self.assertEqual(self.bridge.ensure_folder("Zotero"), FOLDER_ID)
        self.assertFalse(self.bridge.pending_path.exists())

    def test_non_fifo_paths_are_rejected(self):
        self.output.unlink()
        self.output.write_text(FOLDER_ID)
        with self.assertRaisesRegex(ValueError, "not a FIFO"):
            self.bridge.ensure_folder("Zotero")

    def test_unsafe_and_oversized_arguments_never_write(self):
        for folder in ("Zotero\n>eother:arg", "Zotero\0", "x" * 1024, "/", "A//B", FOLDER_ID):
            with self.subTest(folder=folder):
                with self.assertRaises(ValueError):
                    self.bridge.ensure_folder(folder)


if __name__ == "__main__":
    unittest.main()
