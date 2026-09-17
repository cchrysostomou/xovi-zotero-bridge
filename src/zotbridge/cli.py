from __future__ import annotations

import json
from functools import wraps
from pathlib import Path
import re
import sqlite3
from typing import Callable, ParamSpec, TypeVar
import httpx2
import typer
from pyzotero import zotero_errors

from zotbridge.config import load_config
from zotbridge.librarian import LibrarianBridge
from zotbridge.json_state import JsonStateError, JsonStateStore
from zotbridge.library import RemarkableLibrary
from zotbridge.locking import BridgeBusyError, import_lock
from zotbridge.state import StateStore
from zotbridge.zotero_client import ZoteroBridge
from zotbridge.webdav import WebDAVError

app = typer.Typer(help="On-demand Zotero bridge for reMarkable xovi integrations.")
P = ParamSpec("P")
R = TypeVar("R")


def json_errors(command: Callable[P, R]) -> Callable[P, R]:
    @wraps(command)
    def wrapped(*args: P.args, **kwargs: P.kwargs) -> R:
        try:
            return command(*args, **kwargs)
        except typer.Exit:
            raise
        except BridgeBusyError as exc:
            code, message = "busy", str(exc)
        except JsonStateError as exc:
            code, message = "state_error", str(exc)
        except WebDAVError as exc:
            code, message = "webdav_error", str(exc)
        except (zotero_errors.PyZoteroError, httpx2.HTTPError) as exc:
            code = "zotero_error"
            message = f"Zotero request failed ({type(exc).__name__}). Check connectivity, credentials and attachment availability."
        except (OSError, RuntimeError, ValueError, sqlite3.Error) as exc:
            code, message = type(exc).__name__, str(exc)
        typer.echo(json.dumps({"ok": False, "error": code, "message": message}))
        raise typer.Exit(code=1)

    return wrapped


def validate_item_key(item_key: str) -> None:
    if re.fullmatch(r"[A-Z0-9]{8}", item_key) is None:
        raise ValueError("item-key must contain exactly eight uppercase letters or digits")


@app.command("list")
@json_errors
def list_items(
    query: str = typer.Option("", "--query", "-q"),
    limit: int = typer.Option(20, "--limit", "-n", min=1, max=100),
    as_json: bool = typer.Option(False, "--json"),
    skip: int = typer.Option(0, "--skip", "--start", min=0, max=2147483647),
    tag: list[str] | None = typer.Option(None, "--tag", "-t", help="Repeat to match any selected tag (OR)."),
    page_info: bool = typer.Option(False, "--page-info", help="Return JSON items and pagination information."),
) -> None:
    cfg = load_config()
    zot = ZoteroBridge(cfg.library_id, cfg.library_type, cfg.api_key, cfg.webdav)
    page = zot.search_page(query, limit=limit, skip=skip, tags=tag)
    state = StateStore(cfg.state_db_path)

    payload = [
        {
            "item_key": p.item_key,
            "title": p.title,
            "year": p.year,
            "has_pdf": p.has_pdf,
            "mapping": state.get_mapping(p.item_key),
            "attempt": state.get_attempt(p.item_key),
        }
        for p in page.items
    ]
    if page_info:
        typer.echo(json.dumps({
            "ok": True,
            "items": payload,
            "pagination": {
                "skip": page.skip, "limit": page.limit, "total": page.total,
                "has_more": page.next_skip is not None, "next_skip": page.next_skip,
            },
        }))
        return
    if as_json:
        typer.echo(json.dumps(payload))
        return

    for p in payload:
        marker = "PDF" if p["has_pdf"] else "NO_PDF"
        typer.echo(f'{p["item_key"]}\t{marker}\t{p["year"]}\t{p["title"]}')


@app.command("tags")
@json_errors
def tags(
    query: str = typer.Option("", "--query", "-q"),
    as_json: bool = typer.Option(False, "--json"),
    refresh: bool = typer.Option(False, "--refresh", help="Replace cached tags from Zotero; otherwise reuse them."),
) -> None:
    """List tag names, caching each library/query until explicitly refreshed."""
    cfg = load_config()

    def fetch() -> list[str]:
        zot = ZoteroBridge(cfg.library_id, cfg.library_type, cfg.api_key, cfg.webdav)
        return zot.list_tags(query)

    names = JsonStateStore(cfg.state_json_path).tags(
        f"{cfg.library_type}:{cfg.library_id}", query, fetch, refresh,
    )
    typer.echo(json.dumps(names) if as_json else "\n".join(names))


@app.command("clear-mappings")
@json_errors
def clear_mappings() -> None:
    """Forget this library's JSON document mappings without deleting documents or cached tags."""
    cfg = load_config()
    cleared = JsonStateStore(cfg.state_json_path).clear_mappings(cfg.library_type, cfg.library_id)
    typer.echo(json.dumps({
        "ok": True, "library_type": cfg.library_type, "library_id": cfg.library_id, "cleared": cleared,
    }))


@app.command("ensure-folder")
@json_errors
def ensure_folder(
    target_folder: str = typer.Option(..., "--target-folder"),
) -> None:
    """Find or create a reMarkable folder without importing a document."""
    cfg = load_config()
    librarian = LibrarianBridge(cfg.mb_in_path, cfg.mb_out_path, cfg.broker_timeout_s)
    folder_uuid = librarian.ensure_folder(target_folder)
    typer.echo(json.dumps({
        "ok": True, "folder_path": target_folder, "folder_uuid": folder_uuid,
    }))


@app.command("import")
@json_errors
def import_item(
    item_key: str = typer.Option(..., "--item-key"),
    target_folder: str | None = typer.Option(None, "--target-folder"),
    retry_uncertain: bool = typer.Option(
        False, "--retry-uncertain", help="Retry an unconfirmed import; may create a duplicate."
    ),
) -> None:
    validate_item_key(item_key)
    cfg = load_config()
    target_folder = cfg.default_target_folder if target_folder is None else target_folder
    with import_lock(Path(cfg.state_db_path).with_suffix(".lock")):
        state = StateStore(cfg.state_db_path)
        existing = state.get_mapping(item_key)
        if existing is not None:
            typer.echo(json.dumps({"ok": True, "already_imported": True, "mapping": existing}))
            return
        if state.get_attempt(item_key) is not None and not retry_uncertain:
            raise RuntimeError(
                "A previous import was not confirmed. Check the tablet library before using "
                "--retry-uncertain; retrying may create a duplicate."
            )
        zot = ZoteroBridge(cfg.library_id, cfg.library_type, cfg.api_key, cfg.webdav)
        librarian = LibrarianBridge(cfg.mb_in_path, cfg.mb_out_path, cfg.broker_timeout_s)
        with zot.download_first_pdf(item_key) as (temp_path, attachment_key):
            folder_uuid = librarian.ensure_folder(target_folder)
            state.begin_import(item_key, attachment_key, target_folder)
            rm_uuid = librarian.import_document(str(temp_path), folder_uuid)
            RemarkableLibrary(cfg.xochitl_dir).verify_import(rm_uuid, folder_uuid)
            state.upsert_mapping(
                zotero_item_key=item_key,
                zotero_attachment_key=attachment_key,
                rm_uuid=rm_uuid,
                rm_path=target_folder,
                state="imported",
            )
            typer.echo(
                json.dumps(
                    {
                        "ok": True,
                        "already_imported": False,
                        "item_key": item_key,
                        "attachment_key": attachment_key,
                        "rm_uuid": rm_uuid,
                        "rm_path": target_folder,
                    }
                )
            )


@app.command("status")
@json_errors
def status(item_key: str = typer.Option(..., "--item-key")) -> None:
    validate_item_key(item_key)
    cfg = load_config()
    state = StateStore(cfg.state_db_path)
    mapping = state.get_mapping(item_key)
    if mapping is None:
        attempt = state.get_attempt(item_key)
        if attempt is not None:
            typer.echo(json.dumps({"ok": False, "error": "import_uncertain", "attempt": attempt}))
            raise typer.Exit(code=1)
        typer.echo(json.dumps({"ok": False, "error": "not_found", "item_key": item_key}))
        raise typer.Exit(code=1)
    typer.echo(json.dumps({"ok": True, "mapping": mapping}))


@app.command("library")
@json_errors
def library() -> None:
    """List local reMarkable folders and documents without modifying library files."""
    cfg = load_config()
    typer.echo(json.dumps(RemarkableLibrary(cfg.xochitl_dir).list_entries()))


@app.command("check-connection")
@json_errors
def check_connection(
    item_key: str | None = typer.Option(None, "--item-key"),
) -> None:
    """Read metadata and optionally download one PDF, without importing or updating anything."""
    cfg = load_config()
    zot = ZoteroBridge(cfg.library_id, cfg.library_type, cfg.api_key, cfg.webdav)
    if item_key is not None:
        validate_item_key(item_key)
        with zot.download_first_pdf(item_key) as (path, _):
            size = path.stat().st_size
        typer.echo(json.dumps({
            "ok": True, "metadata": "accessible",
            "storage": "webdav" if cfg.webdav else "zotero",
            "pdf_download": "verified", "bytes": size,
        }))
    else:
        zot.check_metadata()
        typer.echo(json.dumps({
            "ok": True, "metadata": "accessible",
            "storage": "webdav" if cfg.webdav else "zotero",
            "pdf_download": "not_tested",
            "message": "Use --item-key with a parent item containing a PDF to test file access.",
        }))
