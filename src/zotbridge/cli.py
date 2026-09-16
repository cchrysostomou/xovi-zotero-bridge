from __future__ import annotations

import json
from pathlib import Path
import typer

from zotbridge.config import load_config
from zotbridge.librarian import LibrarianBridge
from zotbridge.state import StateStore
from zotbridge.zotero_client import ZoteroBridge

app = typer.Typer(help="On-demand Zotero bridge for reMarkable xovi integrations.")


@app.command("list")
def list_items(
    query: str = typer.Option(..., "--query", "-q"),
    limit: int = typer.Option(20, "--limit", "-n"),
    as_json: bool = typer.Option(False, "--json"),
) -> None:
    cfg = load_config()
    zot = ZoteroBridge(cfg.library_id, cfg.library_type, cfg.api_key)
    papers = zot.search(query, limit=limit)

    payload = [
        {
            "item_key": p.item_key,
            "title": p.title,
            "year": p.year,
            "has_pdf": p.has_pdf,
        }
        for p in papers
    ]
    if as_json:
        typer.echo(json.dumps(payload))
        return

    for p in payload:
        marker = "PDF" if p["has_pdf"] else "NO_PDF"
        typer.echo(f'{p["item_key"]}\t{marker}\t{p["year"]}\t{p["title"]}')


@app.command("import")
def import_item(
    item_key: str = typer.Option(..., "--item-key"),
    target_folder: str = typer.Option("Zotero/unread", "--target-folder"),
) -> None:
    cfg = load_config()
    zot = ZoteroBridge(cfg.library_id, cfg.library_type, cfg.api_key)
    librarian = LibrarianBridge(cfg.mb_in_path, cfg.mb_out_path)
    state = StateStore(cfg.state_db_path)

    temp_file, attachment_key = zot.download_first_pdf(item_key)
    temp_path = Path(temp_file)
    try:
        folder_uuid = librarian.ensure_folder(target_folder)
        rm_uuid = librarian.import_document(str(temp_path), folder_uuid)
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
                    "item_key": item_key,
                    "attachment_key": attachment_key,
                    "rm_uuid": rm_uuid,
                    "rm_path": target_folder,
                }
            )
        )
    finally:
        if temp_path.exists():
            temp_path.unlink()


@app.command("status")
def status(item_key: str = typer.Option(..., "--item-key")) -> None:
    cfg = load_config()
    state = StateStore(cfg.state_db_path)
    mapping = state.get_mapping(item_key)
    if mapping is None:
        typer.echo(json.dumps({"ok": False, "error": "not_found", "item_key": item_key}))
        raise typer.Exit(code=1)
    typer.echo(json.dumps({"ok": True, "mapping": mapping}))
