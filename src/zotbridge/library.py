from __future__ import annotations

import json
from pathlib import Path
from uuid import UUID


class RemarkableLibrary:
    """Read-only adapter for the tablet's xochitl metadata."""

    def __init__(self, directory: str):
        self.directory = Path(directory)

    def list_entries(self) -> dict:
        if not self.directory.is_dir():
            raise FileNotFoundError(f"reMarkable library directory not found: {self.directory}")
        entries: dict[str, dict] = {}
        warnings: list[str] = []
        for path in sorted(self.directory.glob("*.metadata")):
            try:
                entry_id = str(UUID(path.stem))
                metadata = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(metadata, dict) or not all(
                    isinstance(metadata.get(field), str) for field in ("visibleName", "parent", "type")
                ):
                    raise ValueError("missing or invalid metadata fields")
                if metadata["type"] not in ("DocumentType", "CollectionType"):
                    raise ValueError("unsupported metadata type")
                entries[entry_id] = {
                    "rm_uuid": entry_id,
                    "title": metadata["visibleName"],
                    "parent": metadata["parent"],
                    "type": metadata["type"],
                    "deleted": metadata.get("deleted", False),
                }
            except (OSError, ValueError) as exc:
                warnings.append(f"{path.name}: {exc}")

        visible = []
        for entry_id, entry in entries.items():
            current = entry_id
            visited: set[str] = set()
            names = []
            while current:
                if current == "trash":
                    break
                if current in visited:
                    warnings.append(f"{entry_id}: cyclic parent hierarchy")
                    break
                visited.add(current)
                ancestor = entries.get(current)
                if ancestor is None:
                    warnings.append(f"{entry_id}: missing parent {current}")
                    break
                if ancestor["deleted"]:
                    break
                names.append(ancestor["title"])
                current = ancestor["parent"]
            else:
                visible.append(
                    {key: value for key, value in entry.items() if key != "deleted"}
                    | {"path": "/".join(reversed(names))}
                )
        visible.sort(key=lambda entry: (entry["type"] != "CollectionType", entry["path"].casefold()))
        return {"ok": True, "entries": visible, "warnings": warnings}

    def verify_import(self, document_id: str, parent: str) -> None:
        document_id = str(UUID(document_id))
        metadata = json.loads((self.directory / f"{document_id}.metadata").read_text(encoding="utf-8"))
        content = json.loads((self.directory / f"{document_id}.content").read_text(encoding="utf-8"))
        if (
            not isinstance(metadata, dict)
            or metadata.get("type") != "DocumentType"
            or metadata.get("parent") != parent
            or not isinstance(content, dict)
            or content.get("fileType") != "pdf"
        ):
            raise RuntimeError("Imported document metadata/content did not match the expected PDF")
        with (self.directory / f"{document_id}.pdf").open("rb") as pdf:
            if not pdf.read(1024).lstrip().startswith(b"%PDF-"):
                raise RuntimeError("Imported PDF is missing or invalid")
