# xovi-zotero-bridge

On-demand Zotero integration for reMarkable using xovi + rm-librarian.

This MVP follows a **no-daemon** model:
- xovi UI calls a lightweight script only when needed (`list`, `import`, `status`).
- The script talks to Zotero directly and uses `rm-librarian` through `xovi-message-broker`.
- A local sqlite file keeps item-to-document mappings for reliable roundtrips.

## MVP capabilities

- Search Zotero items with PDF attachments
- Import a selected Zotero paper into a target reMarkable folder
- Track mapping state (`zotero item key` -> `reMarkable UUID`)

## Architecture

```text
xovi UI (QML)
   -> zotbridge CLI (one-shot execution)
      -> Zotero API / file download
      -> xovi-message-broker -> rm-librarian (ensureFolder/importDocument)
      -> sqlite state
```

## Requirements

- Python 3.12+
- Access to Zotero Web API (library id/type and API key)
- xovi + rm-librarian installed on the reMarkable
- xovi message broker pipes:
  - `/run/xovi-mb`
  - `/run/xovi-mb-out`

## Quick start

1. Copy and edit `config.example.toml`:

```bash
cp config.example.toml config.toml
```

2. Install:

```bash
pip install -e .
```

3. Search:

```bash
zotbridge list --query "attention" --limit 20
```

4. Import:

```bash
zotbridge import --item-key ABCD1234 --target-folder "Zotero/unread"
```

5. Check mapping:

```bash
zotbridge status --item-key ABCD1234
```

## Configuration

All values are read from `config.toml` (or `ZOTBRIDGE_CONFIG`):

- `library_id`
- `library_type` (`user` or `group`)
- `api_key`
- `mb_in_path` (default `/run/xovi-mb`)
- `mb_out_path` (default `/run/xovi-mb-out`)
- `state_db_path` (default `./zotbridge-state.db`)

## xovi integration sketch

The xovi side can long-press an item and run:

```bash
zotbridge import --item-key <key> --target-folder "Zotero/unread"
```

Use `zotbridge list --json` for UI population.
