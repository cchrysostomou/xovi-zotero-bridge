from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Optional


SCHEMA = """
CREATE TABLE IF NOT EXISTS sync_map (
  zotero_item_key TEXT PRIMARY KEY,
  zotero_attachment_key TEXT NOT NULL,
  rm_uuid TEXT NOT NULL,
  rm_path TEXT NOT NULL,
  state TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
"""


class StateStore:
    def __init__(self, db_path: str):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _conn(self) -> sqlite3.Connection:
        return sqlite3.connect(self.db_path)

    def _init_db(self) -> None:
        with self._conn() as conn:
            conn.executescript(SCHEMA)

    def upsert_mapping(
        self,
        zotero_item_key: str,
        zotero_attachment_key: str,
        rm_uuid: str,
        rm_path: str,
        state: str,
    ) -> None:
        with self._conn() as conn:
            conn.execute(
                """
                INSERT INTO sync_map (
                  zotero_item_key, zotero_attachment_key, rm_uuid, rm_path, state
                )
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(zotero_item_key) DO UPDATE SET
                  zotero_attachment_key=excluded.zotero_attachment_key,
                  rm_uuid=excluded.rm_uuid,
                  rm_path=excluded.rm_path,
                  state=excluded.state,
                  updated_at=datetime('now')
                """,
                (zotero_item_key, zotero_attachment_key, rm_uuid, rm_path, state),
            )

    def get_mapping(self, zotero_item_key: str) -> Optional[dict]:
        with self._conn() as conn:
            row = conn.execute(
                """
                SELECT zotero_item_key, zotero_attachment_key, rm_uuid, rm_path, state, updated_at
                FROM sync_map
                WHERE zotero_item_key = ?
                """,
                (zotero_item_key,),
            ).fetchone()
            if row is None:
                return None
            return {
                "zotero_item_key": row[0],
                "zotero_attachment_key": row[1],
                "rm_uuid": row[2],
                "rm_path": row[3],
                "state": row[4],
                "updated_at": row[5],
            }
