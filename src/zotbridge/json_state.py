from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import time
from typing import Callable

from zotbridge.locking import import_lock


class JsonStateError(RuntimeError):
    pass


class JsonStateStore:
    """JSON state shared with the tablet shell backend."""

    def __init__(self, path: str):
        self.path = Path(path)

    @staticmethod
    def _valid_cache(cache: object) -> bool:
        if not isinstance(cache, dict):
            return False
        for queries in cache.values():
            if not isinstance(queries, dict):
                return False
            for entry in queries.values():
                if not isinstance(entry, dict):
                    return False
                fetched = entry.get("fetched_at")
                names = entry.get("tags")
                if not (type(fetched) in (int, float) and fetched >= 0 and fetched % 1 == 0):
                    return False
                if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
                    return False
                if names != sorted(set(names)):
                    return False
        return True

    @staticmethod
    def _valid_collection_cache(cache: object) -> bool:
        if not isinstance(cache, dict):
            return False
        for entry in cache.values():
            if not isinstance(entry, dict):
                return False
            fetched = entry.get("fetched_at")
            collections = entry.get("collections")
            if not (type(fetched) in (int, float) and fetched >= 0 and fetched % 1 == 0):
                return False
            if not isinstance(collections, list):
                return False
            for collection in collections:
                if not isinstance(collection, dict):
                    return False
                if not isinstance(collection.get("key"), str) or not isinstance(collection.get("name"), str):
                    return False
        return True

    def _load(self) -> dict:
        if self.path.is_symlink():
            raise JsonStateError("JSON state must not be a symbolic link.")
        if not self.path.exists():
            return {"version": 1, "mappings": {}, "attempts": {}, "tag_cache": {}, "collection_cache": {}}
        if not self.path.is_file():
            raise JsonStateError("JSON state must be a regular file.")
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (ValueError, UnicodeError) as exc:
            raise JsonStateError("Invalid JSON state; the existing file has not been reset.") from exc
        if not (
            isinstance(data, dict)
            and type(data.get("version")) in (int, float) and data["version"] == 1
            and isinstance(data.get("mappings"), dict)
            and isinstance(data.get("attempts"), dict)
            and self._valid_cache(data.get("tag_cache", {}))
            and self._valid_collection_cache(data.get("collection_cache", {}))
        ):
            raise JsonStateError("Invalid JSON state schema; the existing file has not been reset.")
        data.setdefault("tag_cache", {})
        data.setdefault("collection_cache", {})
        return data

    def _save(self, data: dict) -> None:
        descriptor, name = tempfile.mkstemp(prefix=self.path.name + ".new.", dir=self.path.parent)
        staging = Path(name)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(data, handle, ensure_ascii=False, allow_nan=False)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(staging, self.path)
        finally:
            staging.unlink(missing_ok=True)

    def tags(
        self, scope: str, query: str, fetch: Callable[[], list[str]], refresh: bool = False,
    ) -> list[str]:
        with import_lock(self.path.with_name(self.path.name + ".lock")):
            data = self._load()
            queries = data["tag_cache"].setdefault(scope, {})
            if query not in queries or refresh:
                names = fetch()
                if not isinstance(names, list) or any(not isinstance(name, str) for name in names):
                    raise JsonStateError("Cannot cache invalid tag data.")
                queries[query] = {"fetched_at": int(time.time()), "tags": sorted(set(names))}
                self._save(data)
            return queries[query]["tags"]

    def collections(
        self, scope: str, fetch: Callable[[], list[dict]], refresh: bool = False,
    ) -> list[dict]:
        with import_lock(self.path.with_name(self.path.name + ".lock")):
            data = self._load()
            if scope not in data["collection_cache"] or refresh:
                collections = fetch()
                if not isinstance(collections, list) or any(
                    not isinstance(entry, dict) or not isinstance(entry.get("key"), str)
                    or not isinstance(entry.get("name"), str) for entry in collections
                ):
                    raise JsonStateError("Cannot cache invalid collection data.")
                data["collection_cache"][scope] = {
                    "fetched_at": int(time.time()), "collections": collections,
                }
                self._save(data)
            return data["collection_cache"][scope]["collections"]

    def clear_mappings(self, library_type: str, library_id: str) -> int:
        with import_lock(self.path.with_name(self.path.name + ".lock")):
            data = self._load()
            mappings = data["mappings"]
            if any(not isinstance(record, dict) for record in mappings.values()):
                raise JsonStateError("Cannot clear mappings: invalid document mapping data.")
            kept = {
                uuid: record for uuid, record in mappings.items()
                if record.get("zotero_library_type") != library_type
                or record.get("zotero_library_id") != library_id
            }
            cleared = len(mappings) - len(kept)
            if cleared:
                data["mappings"] = kept
                self._save(data)
            return cleared
