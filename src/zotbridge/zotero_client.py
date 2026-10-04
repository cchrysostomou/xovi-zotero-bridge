from __future__ import annotations

from dataclasses import dataclass
from contextlib import contextmanager
from pathlib import Path
import re
import tempfile
from typing import Iterator, Optional

from pyzotero.zotero import Zotero
from zotbridge.config import WebDAVConfig
from zotbridge.webdav import WebDAVStorage


@dataclass(frozen=True)
class Paper:
    item_key: str
    title: str
    year: str
    has_pdf: bool
    num_children: int


@dataclass(frozen=True)
class Attachment:
    attachment_key: str
    title: str


@dataclass(frozen=True)
class Collection:
    key: str
    name: str


@dataclass(frozen=True)
class LibraryPage:
    items: list[Paper]
    skip: int
    limit: int
    total: int
    next_skip: int | None


def tag_expression(tags: list[str]) -> str:
    if any(not tag or "||" in tag or tag.startswith("\\-") or
           any(ord(character) < 32 or ord(character) == 127 for character in tag) for tag in tags):
        raise ValueError("Tags must be nonempty literal names without controls, '||', or a leading '\\-'")
    expression = " || ".join(tags)
    return "\\" + expression if expression.startswith("-") else expression


class ZoteroBridge:
    def __init__(
        self, library_id: str, library_type: str, api_key: str, webdav: WebDAVConfig | None = None
    ):
        self.zot = Zotero(library_id, library_type, api_key)
        self.webdav = WebDAVStorage(webdav) if webdav is not None else None

    def check_metadata(self) -> None:
        self.zot.top(limit=1)

    def search(
        self, query: str, limit: int = 20, skip: int = 0, tags: list[str] | None = None,
        collection: str | None = None,
    ) -> list[Paper]:
        return self.search_page(query, limit, skip, tags, collection).items

    def search_page(
        self, query: str, limit: int = 20, skip: int = 0, tags: list[str] | None = None,
        collection: str | None = None,
    ) -> LibraryPage:
        if not 1 <= limit <= 100 or not 0 <= skip <= 2147483647:
            raise ValueError("limit must be 1-100 and skip must be 0-2147483647")
        if collection is not None and re.fullmatch(r"[A-Z0-9]{8}", collection) is None:
            raise ValueError("collection must contain exactly eight uppercase letters or digits")
        filters = {"tag": tag_expression(tags)} if tags else {}
        common_kwargs = dict(
            q=query, limit=limit, start=skip, sort="dateModified", direction="desc",
            itemType="-attachment || note || annotation", **filters,
        )
        items = (
            self.zot.collection_items_top(collection, **common_kwargs)
            if collection is not None
            else self.zot.top(**common_kwargs)
        )
        raw_total = self.zot.request.headers.get("Total-Results", "")
        if not isinstance(raw_total, str) or re.fullmatch(r"[0-9]+", raw_total) is None:
            raise RuntimeError("Zotero response is missing a valid Total-Results header")
        total = int(raw_total)
        if not isinstance(items, list) or len(items) > limit:
            raise RuntimeError("Zotero returned an invalid library page")
        next_skip = skip + len(items) if skip + len(items) < total else None
        if not items and next_skip is not None:
            raise RuntimeError("Zotero returned an empty page before the end; refresh the listing")
        papers: list[Paper] = []
        for item in items:
            data = item.get("data", {})
            if data.get("itemType") in ("attachment", "note", "annotation"):
                continue
            item_key = data.get("key", "")
            title = data.get("title", "").strip()
            year = str(data.get("date", "")).strip()
            num_children = item.get("meta", {}).get("numChildren", 0)
            if not isinstance(num_children, int):
                num_children = 0
            has_pdf = num_children > 0
            papers.append(
                Paper(item_key=item_key, title=title, year=year, has_pdf=has_pdf,
                      num_children=num_children)
            )
        return LibraryPage(papers, skip, limit, total, next_skip)

    def list_tags(self, query: str = "") -> list[str]:
        tags = self.zot.everything(self.zot.tags(q=query, limit=100))
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise RuntimeError("Zotero returned invalid tag data")
        return sorted(set(tags))

    def list_collections(self) -> list[Collection]:
        raw = self.zot.everything(self.zot.collections_top(limit=100))
        if not isinstance(raw, list):
            raise RuntimeError("Zotero returned invalid collection data")
        collections: list[Collection] = []
        for entry in raw:
            if not isinstance(entry, dict):
                raise RuntimeError("Zotero returned invalid collection data")
            data = entry.get("data", {})
            key = str(data.get("key", ""))
            if re.fullmatch(r"[A-Z0-9]{8}", key) is None:
                raise RuntimeError("Zotero returned an invalid collection key")
            name = str(data.get("name", "")).strip()
            collections.append(Collection(key=key, name=name))
        return collections

    def _first_pdf_attachment_key(self, item_key: str) -> Optional[str]:
        for child in self.zot.everything(self.zot.children(item_key)):
            data = child.get("data", {})
            if (
                data.get("contentType") == "application/pdf"
                and data.get("linkMode") in ("imported_file", "imported_url")
            ):
                return str(data["key"])
        return None

    def list_pdf_attachments(self, item_key: str) -> list[Attachment]:
        attachments: list[Attachment] = []
        for child in self.zot.everything(self.zot.children(item_key)):
            data = child.get("data", {})
            if (
                data.get("contentType") == "application/pdf"
                and data.get("linkMode") in ("imported_file", "imported_url")
            ):
                title = str(data.get("title") or data.get("filename") or "")
                attachments.append(Attachment(attachment_key=str(data["key"]), title=title))
        return attachments

    @contextmanager
    def download_first_pdf(self, item_key: str) -> Iterator[tuple[Path, str]]:
        attachment_key = self._first_pdf_attachment_key(item_key)
        if attachment_key is None:
            raise RuntimeError(f"No stored PDF attachment found for item {item_key}")
        with self._download_attachment(item_key, attachment_key) as result:
            yield result

    @contextmanager
    def download_attachment(self, item_key: str, attachment_key: str) -> Iterator[tuple[Path, str]]:
        attachment = self.zot.item(attachment_key).get("data", {})
        if (
            attachment.get("parentItem") != item_key
            or attachment.get("contentType") != "application/pdf"
            or attachment.get("linkMode") not in ("imported_file", "imported_url")
        ):
            raise RuntimeError(
                f"The requested attachment {attachment_key} is not a stored PDF that belongs to item {item_key}"
            )
        with self._download_attachment(item_key, attachment_key) as result:
            yield result

    @contextmanager
    def _download_attachment(self, item_key: str, attachment_key: str) -> Iterator[tuple[Path, str]]:
        with tempfile.TemporaryDirectory(prefix="zotbridge-") as td:
            downloaded = Path(td) / "document.pdf"
            if self.webdav is not None:
                attachment = self.zot.item(attachment_key)["data"]
                self.webdav.download_pdf(attachment_key, attachment.get("filename", ""), downloaded)
            else:
                self.zot.dump(attachment_key, filename="document.pdf", path=td)
            if not downloaded.is_file():
                raise RuntimeError(f"Download produced no PDF for {item_key}")
            with downloaded.open("rb") as pdf:
                if not pdf.read(1024).lstrip().startswith(b"%PDF-"):
                    raise RuntimeError(f"Downloaded attachment is not a PDF for {item_key}")
            data = self.zot.item(item_key).get("data", {})
            title = str(data.get("title", "")).strip() or item_key
            title = re.sub(r'[<>:"/\\|?*\x00-\x1f,]', "_", title).strip(" .")
            title = title.encode("utf-8")[:180].decode("utf-8", errors="ignore").rstrip(" .") or item_key
            if title.upper().split(".")[0] in {
                "CON", "PRN", "AUX", "NUL",
                *(f"COM{index}" for index in range(1, 10)),
                *(f"LPT{index}" for index in range(1, 10)),
            }:
                title = "_" + title
            named_pdf = downloaded.with_name(f"{title}.pdf")
            downloaded.rename(named_pdf)
            yield named_pdf, attachment_key
