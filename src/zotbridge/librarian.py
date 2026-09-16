from __future__ import annotations

from pathlib import Path
import time


class LibrarianBridge:
    def __init__(self, mb_in_path: str, mb_out_path: str):
        self.mb_in = Path(mb_in_path)
        self.mb_out = Path(mb_out_path)

    def _send(self, signal: str, params: str) -> str:
        if not self.mb_in.exists() or not self.mb_out.exists():
            raise FileNotFoundError(
                f"xovi-message-broker pipes not found: {self.mb_in} / {self.mb_out}"
            )

        payload = f">e{signal}:{params}"
        self.mb_in.write_text(payload, encoding="utf-8")

        timeout_s = 8.0
        start = time.time()
        while time.time() - start < timeout_s:
            out = self.mb_out.read_text(encoding="utf-8").strip()
            if out:
                if out.startswith("ERROR:"):
                    raise RuntimeError(out)
                return out
            time.sleep(0.05)

        raise TimeoutError(f"Timed out waiting for response to signal {signal}")

    def ensure_folder(self, folder: str) -> str:
        return self._send("ensureFolder", folder)

    def import_document(self, local_file_path: str, parent: str) -> str:
        return self._send("importDocument", f"{local_file_path},{parent}")
