from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import tempfile
from typing import Optional

from pyzotero.zotero import Zotero


@dataclass(frozen=True)
class Paper:
    item_key: str
    title: str
    year: str
    has_pdf: bool


class ZoteroBridge:
    def __init__(self, library_id: str, library_type: str, api_key: str):
        self.zot = Zotero(library_id, library_type, api_key)

    def search(self, query: str, limit: int = 20) -> list[Paper]:
        items = self.zot.items(q=query, limit=limit)
        papers: list[Paper] = []
        for item in items:
            data = item.get("data", {})
            if data.get("itemType") != "journalArticle":
                continue
            item_key = data.get("key", "")
            title = data.get("title", "").strip()
            year = str(data.get("date", "")).strip()
            has_pdf = self._first_pdf_attachment_key(item_key) is not None
            papers.append(
                Paper(item_key=item_key, title=title, year=year, has_pdf=has_pdf)
            )
        return papers

    def _first_pdf_attachment_key(self, item_key: str) -> Optional[str]:
        for child in self.zot.children(item_key):
            data = child.get("data", {})
            if data.get("contentType") == "application/pdf":
                return str(data["key"])
        return None

    def download_first_pdf(self, item_key: str) -> tuple[str, str]:
        attachment_key = self._first_pdf_attachment_key(item_key)
        if attachment_key is None:
            raise RuntimeError(f"No PDF attachment found for item {item_key}")

        with tempfile.TemporaryDirectory() as td:
            self.zot.dump(attachment_key, path=td)
            files = list(Path(td).glob("*"))
            if not files:
                raise RuntimeError(f"Download succeeded but no file found for {item_key}")
            src = files[0]
            out = Path.cwd() / f".tmp-{src.name}"
            out.write_bytes(src.read_bytes())
            return str(out), attachment_key
