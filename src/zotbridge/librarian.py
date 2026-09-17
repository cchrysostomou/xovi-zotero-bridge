from __future__ import annotations

import errno
import json
import os
from pathlib import Path
import select
import stat
import time
from uuid import UUID

from zotbridge.locking import import_lock


class BrokerRecoveryRequired(RuntimeError):
    pass


class LibrarianBridge:
    def __init__(self, mb_in_path: str, mb_out_path: str, timeout_s: float = 30.0):
        self.mb_in = Path(mb_in_path)
        self.mb_out = Path(mb_out_path)
        self.timeout_s = timeout_s
        self.lock_path = self.mb_in.with_name(self.mb_in.name + ".zotbridge.lock")
        self.pending_path = self.mb_in.with_name(self.mb_in.name + ".zotbridge-pending")

    def _identity(self) -> list[list[int]]:
        identity = []
        for path in (self.mb_in, self.mb_out):
            info = path.stat()
            if not stat.S_ISFIFO(info.st_mode):
                raise ValueError(f"Message broker path is not a FIFO: {path}")
            identity.append([info.st_dev, info.st_ino])
        return identity

    @staticmethod
    def _remaining(deadline: float) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                "Timed out waiting for xovi-message-broker. If a request was sent, "
                "restart xochitl with XOVI before another broker operation."
            )
        return remaining

    def _open_writer(self, deadline: float) -> int:
        while True:
            self._remaining(deadline)
            try:
                return os.open(self.mb_in, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as exc:
                if exc.errno != errno.ENXIO:
                    raise
                time.sleep(min(0.02, self._remaining(deadline)))

    def _read_response(self, descriptor: int, deadline: float) -> str:
        poller = select.poll()
        poller.register(descriptor, select.POLLIN | select.POLLHUP | select.POLLERR)
        chunks = bytearray()
        while True:
            events = poller.poll(max(1, int(self._remaining(deadline) * 1000)))
            if not events:
                continue
            for _, event in events:
                if event & (select.POLLERR | select.POLLNVAL):
                    raise OSError("Message broker response pipe failed")
                try:
                    chunk = os.read(descriptor, 4096)
                except BlockingIOError:
                    continue
                if not chunk:
                    return chunks.decode("utf-8").strip()
                chunks.extend(chunk)
                if len(chunks) > 65536:
                    raise ValueError("Message broker response exceeded 65536 bytes")

    def _send(self, signal: str, params: str) -> str:
        if os.name != "posix":
            raise RuntimeError("The xovi FIFO transport requires Linux on the tablet")
        if any(character in params for character in ("\n", "\r", "\0")):
            raise ValueError("Broker parameters cannot contain newline or NUL characters")
        payload = f">e{signal}:{params}\n".encode("utf-8")
        if len(payload) > 1024:
            raise ValueError("Message broker request exceeds its 1024-byte limit")

        with import_lock(self.lock_path):
            identity = self._identity()
            if self.pending_path.exists():
                previous = json.loads(self.pending_path.read_text(encoding="utf-8"))
                if previous == identity:
                    raise BrokerRecoveryRequired(
                        "An earlier broker request was not confirmed. Restart xochitl with "
                        "XOVI to recreate its FIFOs before retrying; imports may already exist."
                    )
                self.pending_path.unlink()
            deadline = time.monotonic() + self.timeout_s
            reader = os.open(self.mb_out, os.O_RDONLY | os.O_NONBLOCK)
            try:
                writer = self._open_writer(deadline)
                try:
                    # A crash after sending must not let the next run consume a stale reply.
                    self.pending_path.write_text(json.dumps(identity), encoding="utf-8")
                    while True:
                        self._remaining(deadline)
                        try:
                            written = os.write(writer, payload)
                            break
                        except BlockingIOError:
                            time.sleep(min(0.02, self._remaining(deadline)))
                    if written != len(payload):
                        raise OSError("Incomplete message broker request write")
                finally:
                    os.close(writer)
                response = self._read_response(reader, deadline)
                self.pending_path.unlink()
            finally:
                os.close(reader)
        if response.startswith("ERROR:"):
            raise RuntimeError(response)
        if not response:
            raise RuntimeError(f"rm-librarian returned an empty response to {signal}")
        return response

    @staticmethod
    def _uuid(value: str) -> str:
        try:
            parsed = UUID(value)
        except ValueError as exc:
            raise ValueError(f"rm-librarian returned an invalid UUID: {value!r}") from exc
        if str(parsed) != value.lower():
            raise ValueError(f"rm-librarian returned a noncanonical UUID: {value!r}")
        return str(parsed)

    def ensure_folder(self, folder: str) -> str:
        if not folder.strip("/") or any(not part.strip() for part in folder.split("/")):
            raise ValueError("target-folder must be a nonempty path without empty components")
        # Upstream accepts UUID input without checking whether it exists or is a folder.
        try:
            UUID(folder)
        except ValueError:
            pass
        else:
            raise ValueError("target-folder must be a folder path, not an unchecked UUID")
        return self._uuid(self._send("ensureFolder", folder))

    def import_document(self, local_file_path: str, parent: str) -> str:
        path = Path(local_file_path)
        if not path.is_absolute() or not path.is_file() or path.suffix.lower() != ".pdf":
            raise ValueError("Import source must be an existing absolute PDF path")
        return self._uuid(self._send("importDocument", f"{path},{self._uuid(parent)}"))
