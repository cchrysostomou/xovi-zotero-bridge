# xovi-zotero-bridge

On-demand Zotero integration for reMarkable using xovi + rm-librarian.
The backend runs on the tablet only when invoked; it needs no laptop service
or additional background daemon.

## Zotero library API

The tablet-facing library operation is now a reusable backend function,
`list_zotero_library`, exposed through the CLI:

```sh
sh scripts/zotbridge-run.sh list --limit 5 --json
sh scripts/zotbridge-run.sh list --query "attention" --limit 20 --json
sh scripts/zotbridge-run.sh list --tag "to_sync" --tag "unread" --limit 20 --skip 0 --page-info
sh scripts/zotbridge-run.sh tags --json
```

The future xovi UI will invoke this command and parse its stdout. It reads the
tablet's `config.toml` directly; it does not use the exported diagnostic curl files.
Results are an array of `{item_key, title, year, has_pdf, mapping, attempt}` objects.
`has_pdf` is determined from stored PDF attachment metadata, not a file download.
The shell listing includes the configured library's saved mapping or unconfirmed
attempt, or null when absent. `year` currently carries the Zotero date string.

Success exits 0. Operational failures exit nonzero and return a JSON object with
`ok: false`, `error` and `message`, not a partial item list. Without `--json`,
the command prints tab-separated item key, PDF availability, date and title.

### Tags, filters and pagination

`--tag NAME` can be repeated. Multiple selected tags match **any tag (OR)**; the
tag group is combined with `--query` using AND. Tag names are passed literally,
including spaces and a leading hyphen. Names containing `||`, control characters
or a leading `\-` are rejected rather than interpreted as query expressions.
The filter applies to the parent bibliographic item's tags; tags on child
attachments are not inherited automatically.

`tags --json` returns all distinct tag names in the configured Zotero library,
sorted as a JSON string array. On a cache miss, it fetches every API page rather
than stopping at 100 names and saves the complete result in the bridge's JSON
store. Later calls reuse it without contacting Zotero, including when offline.
**There is no expiry or automatic refresh of cached results.**

```sh
sh scripts/zotbridge-run.sh tags --json
sh scripts/zotbridge-run.sh tags --refresh --json
sh scripts/zotbridge-run.sh tags --query "read" --json
```

`--refresh` explicitly fetches fresh data and replaces that cached result.
`--query` searches tag names through Zotero; each exact query has a separate cache
entry to preserve the server's search behavior. The empty query is the full tag
list. Changing a query or library fetches data if that entry is missing. Refreshing
one query does not refresh the others. Without `--json`, each name is printed on
its own line. Output formats are unchanged and `--refresh` is valid only for
`tags`; library item listings still fetch live data.

### Bridge-owned JSON store

`state_json_path` defaults to `state_db_path` plus `.json`, normally
`zotbridge-state.db.json` beside `config.toml`. Both backends use this file for
cached tags. Its version-1 object contains:

- `mappings`: persistent records keyed by the **reMarkable document UUID**.
  A record contains the Zotero library type/ID, original source item key (reference
  or directly imported attachment), attachment key,
  import destination, state and timestamp. The import scaffold writes a mapping
  only after librarian imports the document and local verification succeeds.
  Listing items, caching/refreshing tags and creating a folder do not populate it.
- `attempts`: unconfirmed import attempts, keyed by library scope then Zotero item
  key because a document UUID may not yet be known. These are not successful
  document mappings.
- `tag_cache`: entries keyed by `user:<library-id>` or `group:<library-id>`, then
  by the exact query. Each entry contains `tags` and `fetched_at` (Unix seconds).

Only a verified bridge import populates `mappings`; browsing and tag caching
leave it empty. The record shape is:

```json
{
  "mappings": {
    "cc4c1d9d-a04a-4f6e-bb08-d6f54cde88b8": {
      "zotero_library_type": "user",
      "zotero_library_id": "123456",
      "zotero_item_key": "ABCD1234",
      "zotero_attachment_key": "EFGH5678",
      "rm_path": "Zotero/unread",
      "state": "imported",
      "updated_at": "2026-09-17 07:00:00"
    }
  }
}
```

Renaming or moving a document within reMarkable does not change its UUID or
create a new mapping. `rm_path` records the import destination, not a live folder
location. Reverse lookup uses the stored Zotero library identity and source item
key; attachment-key lookup prevents a reference and its tagged PDF from creating
two copies. No second persistent index is maintained. Existing UUID mappings
remain usable without migration. `status --item-key` also accepts the saved
attachment key. A reference whose PDF was imported through the attachment alone
does not acquire a separate mapping; query that attachment key for offline status.
Tag refreshes preserve document mappings. Legacy item-keyed import records are
preserved by caching but require explicit migration before import/status use;
they are never silently reinterpreted or discarded.

To forget document associations for **only the currently configured Zotero
library**, run:

```sh
sh scripts/zotbridge-run.sh clear-mappings
```

The command returns JSON such as:

```json
{"ok":true,"library_type":"user","library_id":"123456","cleared":2}
```

It uses the JSON store's lock and atomic write, and leaves other libraries'
mappings, cached tags, unconfirmed attempts and all actual reMarkable documents
untouched. It makes no Zotero, WebDAV or librarian requests. Repeating the command
returns `cleared: 0` without rewriting the state; an absent store is also a no-op.
Records without explicit Zotero library identity are left untouched rather than
guessed. Malformed state is an error, not permission to reset the file.
**Clearing mappings forgets duplicate-import protection and can allow later
re-imports to create duplicates.** The command affects only the bridge-owned JSON
store, not Python's legacy SQLite import database.

No API keys or WebDAV credentials are added to the store. Library identity, not
the API key, selects the cache: explicitly refresh after changing access
credentials. Cached names may become stale until you refresh, and this local file
is not automatically included in reMarkable cloud sync. Keep it outside the
xochitl-managed library directory and back it up with the bridge configuration.

The shell's tag command additionally needs `flock` and `mv`, but no SQLite or
Python. The entire read/fetch/update operation holds `<state_json_path>.lock`;
concurrent callers receive an explicit `busy` error and can retry after it ends.
Writes use a private staging file in the same directory followed by an atomic
rename. This avoids partially written JSON, but is not a guarantee against sudden
power loss. The small lock file is synchronization, not a second data store.

An invalid existing store is an error, even with `--refresh`; it is never silently
reset. A failed fetch, incomplete page sequence, or failed save returns an error,
not a partial or stale success, and leaves the previous saved cache intact.
Normal later calls can still read that cache. The Python backend's legacy SQLite
import state is separate and is not automatically migrated.

`list --skip N` starts at a zero-based offset; `--start` is an alias. `--limit`
remains 1-100. Query, tag and bibliographic-type filters are applied by Zotero
**before** pagination, so excluded attachments and notes do not leave gaps in the
displayed pages.

`--sort title|creator|dateAdded|dateModified` and `--direction asc|desc` are
passed through to Zotero, which sorts before paginating. Sorting defaults to
`dateModified` descending.

`--starts-with A-Z|#` keeps only the items whose title begins with that
character, case-insensitively and ignoring leading whitespace; `#` selects
titles that do not begin with a letter. Zotero has no server-side prefix filter
and its `q` search matches substrings anywhere rather than anchoring to the
start, so this filter cannot be pushed to the API. Instead the backend pages
through the **entire** already-filtered result set 100 items at a time, filters
locally, and then applies `--skip`/`--limit` to the filtered list, so
`pagination.total` reports the filtered count. Combine it with `--query`,
`--tag` or `--collection` to keep the scan small; a scan that would exceed 3000
items fails rather than issuing an unbounded number of requests.

Existing `list --json` callers still receive an array. For a UI, use `--page-info`,
which implies JSON and returns:

```json
{
  "ok": true,
  "items": [
    {
      "item_key": "ABCD1234",
      "title": "Example paper",
      "year": "2024",
      "creator": "Darwin",
      "has_pdf": true,
      "mapping": null,
      "attempt": null
    }
  ],
  "pagination": {
    "skip": 0,
    "limit": 1,
    "total": 57,
    "has_more": true,
    "next_skip": 1
  }
}
```

The total is the filtered bibliographic result count from Zotero's `Total-Results`
header, except under `--starts-with`, where it is the locally filtered count.
`creator` is Zotero's `creatorSummary` and is an empty string when the item has
no creators. Preserve the query/tags/limit and pass `next_skip` to retrieve the next
page. On the last page, `has_more` is false and `next_skip` is null. An offset
past the end returns an empty page. Reset the offset when filters change.
Offset pagination is not a snapshot: library edits between requests can shift
results, so refresh from offset zero after changes.

Build/install `dist\xovi-zotero-library-aarch64.zip` as described below. It includes
the ARM64 jq executable for reliable JSON parsing. Listing needs Bash, curl, jq,
wc, dirname, mkdir, chmod and rm; it does not require Python, unzip, head, flock,
the message broker or rm-librarian. The separate `library` command refers to the
reMarkable library and remains unavailable in this shell release.

## Minimal tablet access check

The immediate tablet deliverable is a **curl-only connection probe**, not the
full shell backend. It requires only `sh` and curl: no Python, jq, Base64 tool,
PDF extraction, import support or state database.

On the development computer, with the Python backend installed and the private
`config.toml` configured, run:

```powershell
.\.venv\Scripts\python.exe .\scripts\export-connection-probe.py
```

This creates `dist\zotero-connection-check-private.zip` using the current Zotero
and WebDAV credentials. **The ZIP contains credentials: do not share or commit it.**
The exporter refuses to overwrite an existing probe. The private curl files are
a snapshot, not a live link to subsequent changes in `config.toml`.

Copy the ZIP to `/home/root/xovi-zotero-bridge` on the tablet and run:

```sh
cd /home/root/xovi-zotero-bridge
unzip -o zotero-connection-check-private.zip
chmod 600 connection-check/*.curl
sh connection-check/check-zotero-connection.sh
```

Expected results are `PASS: Zotero metadata access (HTTP 200)` and
`PASS: WebDAV directory access (HTTP 207)`. These use GET and depth-zero PROPFIND,
respectively; no files or metadata are changed remotely. Neither check downloads
or validates a PDF or imports into reMarkable. Credentials stay out of command-line
arguments and output. TLS validation stays enabled, and requests time out after
30 seconds. Your existing tablet `config.toml` is not modified.

**The shell release supports Zotero listing, cached tags, PDF import/status,
mapping reset and librarian folder creation.** ReMarkable library browsing is
deferred from the MVP. These standalone probes remain useful for diagnosing
connectivity separately from the API.

### Standalone one-PDF diagnostic probe

After both access checks pass on the tablet, prepare a separate private probe
on the development computer:

```powershell
.\.venv\Scripts\python.exe .\scripts\export-connection-probe.py --pdf
```

The exporter selects the first item with a stored PDF among ten Zotero items,
downloads it on the computer, and records the exact ZIP member and expected size.
Use `--pdf --item-key ABCD1234` to select a specific parent item instead.
It creates `dist\zotero-pdf-check-private.zip`, containing credentials but **not**
the PDF. Copy this ZIP to the tablet's bridge directory and run:

```sh
unzip -o zotero-pdf-check-private.zip
chmod 600 pdf-check/*.curl
sh pdf-check/check-pdf-download.sh
```

This uses curl, unzip, dd, wc and standard shell utilities, without Python or jq on the
tablet. Both BusyBox and Info-ZIP unzip are supported; the probe detects which
options are available. The PDF header is read with portable `dd` operands, not
`head -c`, which is absent on the tablet. It downloads one ZIP, extracts only the selected member into private
temporary storage, checks ZIP/CRC success, the PDF header and the prepared byte
count, then removes temporary files. It does not render the PDF, import it into
reMarkable, or modify remote data. File output is bounded during extraction.
If the remote attachment changes, regenerate the probe rather than accepting a
size mismatch. Keep both private probe ZIPs out of Git and shared storage.

## Current status

The tablet backend implements Zotero search, Zotero Storage or WebDAV PDF
downloads, fixed-folder PDF import, UUID-keyed JSON mappings and import status.
The destination is configured; reMarkable browsing/folder selection is deferred.
The broker contract is verified against
upstream source and exercised with real Linux FIFOs and a simulated broker.
Single-document import, saved status and document visibility have been confirmed
on the tablet. Tagged batch sync is new and still needs tablet acceptance.
**The Quick Settings UI is not implemented yet.**

Annotation export, bidirectional document synchronization and automatic PDF
updates are outside this MVP. Stored mappings are not a roundtrip sync engine.

## Backend flow

```text
CLI (eventually launched asynchronously by the xovi UI)
  -> Zotero Web API: find items and PDF attachment identifiers
  -> Zotero Storage OR configured WebDAV server: download the PDF
  -> xovi-message-broker: ensure target folder, import PDF
  -> read back imported PDF/metadata/content on the tablet
  -> sync the source's non-queue Zotero tags to the reMarkable document
  -> local state: save Zotero item/attachment keys and reMarkable UUID
  -> sync commands only: conditionally replace the source's queue tag in Zotero
  -> JSON result, temporary-file cleanup, process exit
```

Search includes top-level bibliographic items, not just journal articles.
`has_pdf` means a stored PDF attachment was found in metadata; downloading
can still fail if its file has not been synced or is inaccessible. Laptop-only
linked files are not supported. When WebDAV is enabled, metadata still comes
from Zotero's Web API, but the actual PDF comes from your WebDAV server.

## Fixed-folder import and status

Set this in the tablet's existing `config.toml` without replacing its credentials:

```toml
default_target_folder = "Zotero/unread"
```

This is also the default when the setting is omitted. Missing folders are created
through librarian, so the MVP does not need a destination-folder browser.

```sh
# Optional read-only check of the general downloader for a selected parent item.
sh scripts/zotbridge-run.sh check-connection --item-key ABCD1234

# Copies the first stored PDF attachment into the configured destination.
sh scripts/zotbridge-run.sh import --item-key ABCD1234
sh scripts/zotbridge-run.sh status --item-key ABCD1234

# Override the destination for a new import.
sh scripts/zotbridge-run.sh import --item-key EFGH5678 --target-folder "Research/inbox"
```

Use real reference keys from `list --json`, or a stored PDF attachment's own key
to import that exact file. Plain `import` does not change Zotero tags or remove
anything from Zotero or WebDAV. A successful import returns the item/attachment keys, document
UUID, destination path and `already_imported: false`. Before saving the mapping,
the backend checks local metadata/content, PDF signature and copied byte count.
The final tablet acceptance step is to confirm the document appears and opens.
Repeating the same item returns `already_imported: true` without network or broker
work, even if the default folder changed; this is not a document-move command.

The shared JSON store keeps attempts separate from successful UUID mappings.
An unconfirmed import returns an error and remains visible through `status`.
Status and duplicate checks use library type/ID plus Zotero item key; item listings
also include that saved state. See the recovery instructions below before using
`--retry-uncertain`.

WebDAV extraction supports BusyBox and Info-ZIP `unzip -l`/`-p`, including Zotero
`%ZB64` names. It selects one unambiguous PDF, bounds extraction by its declared
size and the configured limit, requires the exact byte count, and rejects
unsupported/ambiguous names and reported unzip errors. It streams to a private
file rather than extracting archive paths into the filesystem. No `head -c`,
zipinfo (`-Z`), standalone Base64 decoder or Python is required. These are
signature/size checks, not a full PDF parser; unzip integrity checks vary by
implementation and compression method.

## Tagged sync for the Quick Settings action

The shell backend supports both tagging patterns:

| Tag location | PDF selected | Tag updated after success |
|---|---|---|
| Reference item | First stored PDF returned by its children endpoint | The reference's tag |
| PDF attachment | That exact stored PDF | That attachment's tag |
| Both select the same PDF | One import, deduplicated by library and attachment key | Both independently queued sources |

A reference and a different tagged child can therefore import two PDFs. Notes,
annotations, linked files/URLs and references without a stored PDF are reported as
failures, not marked synced. Existing mappings select the original imported file;
if a reference now selects a different first PDF, sync reports `source_changed`
rather than silently replacing its association.

**These commands write Zotero tags. The API key needs write access to the target
library.** They do not edit local reMarkable tags or Zotero's PDF bytes.

```sh
# Live queue: to_sync -> synced, using default_target_folder.
sh scripts/zotbridge-run.sh sync-tagged

# If your actual tag is spelled tosync rather than to_sync:
sh scripts/zotbridge-run.sh sync-tagged --tag tosync

# Deliberately sync only one tagged reference or attachment first.
sh scripts/zotbridge-run.sh sync-item --item-key ABCD1234
```

Both commands accept `--tag NAME`, `--synced-tag NAME` and `--target-folder PATH`.
Defaults are exactly `to_sync`, `synced` and the configured destination. The
commands are currently shell-only; the optional legacy Python backend does not
implement tagged sync or direct-attachment import.

`sync-tagged` collects every queue page before changing any tag, including child
attachments rather than only top-level references. It checks the library version,
total and duplicate keys across pages; changes during enumeration cause an error
before importing. Queues over 10000 sources are explicitly rejected. Each source
is checked again before processing; a removed queue tag means a reported skip.

Imports run serially. A batch lock rejects another simultaneous batch; each item
holds the existing state/import locks through import and tag writeback. A verified
mapping is saved before any tag update. Already mapped PDFs are checked for a
present PDF/content/metadata and a non-deleted folder ancestry, allowing ordinary
renames and moves but refusing missing or trashed documents. These checks do not
prove that every byte of a previously imported PDF is unchanged.

Writeback fetches the latest source, rechecks which PDF it selects, preserves all
unrelated tags (including their types), and PATCHes only `tags` with
`If-Unmodified-Since-Version`. HTTP 412 conflicts get at most three attempts with
fresh data; they are never blindly overwritten. If writeback fails after import,
the mapping remains. Rerunning sync can retry the tag update without another
download/import. Network failures can leave the write outcome unknown; the next
run reconciles against the live tags. Uncertain broker imports are never retried
automatically.

After verified PDF import or mapping reuse, the bridge changes the Zotero queue
tag to the completion tag. It then separately asks rm-librarian to add every
other source tag to the reMarkable document, plus two fixed marker tags,
`zotero-import` and `unread`, while preserving existing reMarkable tags.
Tag propagation is best effort: failure is reported as `remarkable_tags_error`
but does not undo or block Zotero completion.

Batch output contains `ok`, `total`, `processed`, `synced`, `skipped`, `failed`,
`remaining` (unprocessed keys), and per-source `results`. `synced` counts source
items, not newly created PDFs; results expose `already_imported` and `rm_uuid`.
Partial failure exits nonzero. Item-specific failures can continue; shared
network, permission, state or broker failures stop processing and report remaining
keys. `sync-item` returns one result or a structured error. Use `status` to inspect
retained import state after a writeback failure.

Invalid, encrypted, ambiguous, corrupt, or oversized attachment archives are
reported as per-item `archive_error` failures and do not stop later queue items.
The failure log includes the Zotero source key and API attachment filename.
Shared WebDAV connectivity or authentication failures still stop the batch.

The imported reMarkable display name is derived from the Zotero item title.
Supported inline Zotero markup is stripped, filesystem/protocol delimiters and
control characters are removed, whitespace is normalized, and valid Unicode is
preserved. The original ZIP member filename is not rewritten.

The activity log records a `hit` entry for every queued source whose PDF resolves,
including the Zotero source item key and the attachment's `.data.filename` read
from the Zotero API.

The tag-name cache is deliberately unchanged: the batch always queries live
items, while `tags` keeps the agreed manual-refresh policy. Run
`tags --refresh --json` when you want newly created names reflected in that cache.

## Settings API

The tablet Settings page calls these shell-only commands:

```sh
sh scripts/zotbridge-run.sh settings --json
sh scripts/zotbridge-run.sh settings-apply
sh scripts/zotbridge-run.sh reverse-sync
sh scripts/zotbridge-run.sh sync-all
```

`settings --json` returns the WebDAV URL and username, `password_set` rather than
the password, default target folder, and configured queue/completion tags. It
never returns the Zotero API key or WebDAV password. `settings-apply` consumes
only `.zotbridge-settings-draft.json` beside `config.toml`, validates it, writes
an atomically replaced configuration, and deletes the draft on success. A missing
`webdav_password` preserves the existing stored password; a supplied nonempty
value replaces it. Invalid drafts do not change configuration and remain available
for correction.

The configuration remains a flat TOML subset. Applying settings rewrites its
supported scalar values and therefore does not preserve comments/formatting;
unknown scalar keys are retained. Keep a backup before manual edits.

There is no reMarkable Cloud pairing step. reverse-sync reads directly from the
on-device xochitl library using the bundled `zotbridge-localgeta` binary, so no
cloud account, one-time pairing code, or stored cloud token is ever required.
`reverse_sync_folder` defaults to `Zotero/Read` and identifies the reMarkable
folder that reverse synchronization inspects.

`reverse-sync` locates each direct document in that folder on-device, runs
`zotbridge-localgeta` to merge its stored `.pdf` with its `.rm` annotation layers
into an annotated PDF, then attaches that PDF under its mapped Zotero parent, or
creates a new `document` parent tagged `from-rmk` when no mapping exists. For WebDAV libraries,
it writes `<attachment-key>.zip` before the `.prop` commit marker and verifies
the Zotero attachment metadata, `.prop`, and downloaded ZIP contents. Only then
does it move the source document to `<reverse_sync_folder>/Copied2Zotero`.
Failures retain the source and log its UUID, failed stage, structured error, and
`retained_in_source: true`. `sync-all` performs this reverse phase and then the
existing tag-driven Zotero-to-reMarkable phase; this is the Quick Settings action.

The 3.28 Settings UI’s **Test Zotero connection** runs:

```sh
sh scripts/zotbridge-run.sh check-connection --webdav
```

It first checks Zotero metadata access, then sends a depth-zero WebDAV `PROPFIND`
to the configured directory. Success means `metadata: "accessible"` and
`webdav: "accessible"`; no PDFs are downloaded and no remote data changes.

## Activity log

Every configured shell operation except reading/clearing the log itself writes a
compact start and completion/failure event to
`<state_json_path>.activity.jsonl`, normally `zotbridge-state.db.json.activity.jsonl`.
It records UTC timestamp, command, safe item key when supplied, event, and
structured error code. It never records API keys, WebDAV credentials, request
URLs, titles, search text, filenames, or error messages. The log retains its
latest 200 events and is protected from symlink paths.

```sh
sh scripts/zotbridge-run.sh activity-log
sh scripts/zotbridge-run.sh clear-activity-log
```

`activity-log` returns `{ok:true,entries:[...]}` and `clear-activity-log` returns
the number removed. The log is a local diagnostic record, not a sync cache or
durable audit system. If it is malformed or its path is unsafe, operations fail
explicitly rather than write elsewhere; clear it only after retaining any evidence
you need. A log lock is best-effort: if another invocation holds it briefly, that
invocation's activity entry can be omitted, but the actual operation still reports
its own result.

## XOVI Quick Settings button

Firmware-specific QMLDiff patches are in `xovi\3.27\zoteroQuickSync.qmd` and
`xovi\3.28\zoteroQuickSync.qmd`. They add a stock download-icon button beside the
existing Bluetooth Quick Settings action. The button invokes `sync-all` through
`AsyncCommandExecutor`, disables itself during the operation, buffers JSON stdout
until the process completes, and sends a compact success/partial-failure/failure
toast. No credentials appear in the QMD patch.

See [`xovi/README.md`](xovi/README.md) for installation. Use only the patch matching
`cat /etc/version`; resource hashes are firmware-specific. It requires installed
`qt-resource-rebuilder` and `qt-command-executor`, plus the bridge installed at
`/home/root/xovi-zotero-bridge`. Do not close xochitl/XOVI while a batch runs:
an interruption is recorded as an uncertain import rather than automatically
retried. The button does not start a daemon or a detached background command.

## AppLoad Zotero Library app

The AppLoad app is in `xovi\appload\zotero-library`. It is a frontend-only QML
application packaged as `manifest.json`, `icon.png`, and `resources.rcc`; it does
not ship a second backend. The UI reuses the existing bridge commands:

```sh
sh scripts/zotbridge-run.sh tags --json
sh scripts/zotbridge-run.sh list --page-info --limit 8 --skip 0 --query "attention" --tag unread
sh scripts/zotbridge-run.sh import --item-key ABCD1234
```

This gives the app searchable tags, selected-tag filters, offset pagination and
long-press import without duplicating Zotero API, mapping, duplicate-check or
rm-librarian code. Build it with:

```powershell
.\scripts\package-xovi-appload.ps1
```

If Qt `rcc` is not installed on Windows, the packager uses WSL to download and
extract the required Qt `rcc` packages into a local cache, then builds
`dist\xovi-zotero-appload-app.zip`. The standard
`.\scripts\update-remarkable.ps1` command installs that app to
`/home/root/xovi/exthome/appload/zotero-library/` together with the runtime and
QMD patches.

## Librarian folder probe

The first reMarkable-side operation is deliberately separate from PDF import:

```sh
sh scripts/zotbridge-run.sh ensure-folder --target-folder "Zotero/unread"
```

**This finds or creates the folder path on the tablet**, including missing parent
folders. Repeating the same path asks librarian to reuse the existing folder.
The destination must be an explicit nonempty path, not a UUID. A successful
response is:

```json
{"ok":true,"folder_path":"Zotero/unread","folder_uuid":"e90be5e8-32f6-46ec-bb75-32d827af9eee"}
```

The UUID is supplied by librarian; the example above is illustrative. This
command makes no Zotero/WebDAV requests, imports no documents, and writes no import
mapping. It uses the existing configuration's broker paths and timeout, plus Bash,
jq, stat, flock, mv and sleep with fractional-second support. Python's optional
backend exposes the same command and response.

Install the updated `dist\xovi-zotero-library-aarch64.zip` over the existing tablet
installation; `config.toml` is not included and is preserved. XOVI must have
rm-librarian and xovi-message-broker loaded. Extension files and FIFO existence
alone do not prove the handler is responding.

The wrapper serializes bridge requests, validates UUID responses and times out
instead of leaving the shell blocked on a pipe. Do not run other broker clients
concurrently. After an unconfirmed request, a recovery marker blocks another
operation: the folder may already have been created. Restart xochitl with XOVI
using your installation's normal restart procedure so the broker recreates its
FIFOs before retrying; do not simply remove the recovery marker.

## Verified broker contract

The source references are [rm-librarian v0.4.1](https://github.com/rmitchellscott/rm-librarian/tree/v0.4.1)
and [rm-xovi-extensions v19-23052026](https://github.com/asivery/rm-xovi-extensions/tree/v19-23052026).
Relevant implementations are librarian `src/main.cpp` and message broker
`xovi-message-broker/src/pipes.cpp`.

| Operation | Request to `/run/xovi-mb` | Reply from `/run/xovi-mb-out` |
|---|---|---|
| Ensure nested folder | `>eensureFolder:Zotero/unread\n` | Final folder UUID |
| Import PDF | `>eimportDocument:/absolute/path/Paper.pdf,<folder-uuid>\n` | New document UUID |

Here `\n` denotes an actual newline. Requests have a 1024-byte UTF-8 limit.
Replies have **no newline terminator**: the broker writes a string and closes its
output writer; EOF completes the response. Empty replies, `ERROR:` replies and
invalid UUIDs are failures. There are no request IDs or per-client response pipes.

The transport validates FIFO paths, bounds opening/writing/reading with a timeout,
and locks each complete transaction. It accepts chunked responses.
The returned import UUID is followed by a read-only check of the destination PDF,
metadata and content before a successful mapping is saved. This does not certify
that xochitl has finished displaying the document or synced it to the cloud.

There is no verified librarian API for enumerating the library. ReMarkable
browsing is deferred, and the shell `library` command remains gated. The optional
Python development backend has a read-only local `*.metadata` listing.

## Tablet requirements and setup (no Python)

- Bash, curl with HTTPS support and standard Linux shell utilities for listing.
- BusyBox or Info-ZIP unzip is needed for WebDAV downloads and ZIP installation,
  not for listing. PDF operations also use portable `dd` and `wc`.
- jq for JSON and Base64 processing. The ARM64 package includes a verified static
  jq executable; a separate `base64` or `timeout` program is not needed.
- Folder operations and imports require XOVI, xovi-message-broker and rm-librarian,
  plus stat, flock, mv and fractional-second sleep.
  They are not needed for the read-only Zotero library API.
- Network access and a Zotero API key with read access to the configured library.
- For WebDAV file storage: server URL, username and password/app password, and
  network access from the tablet to that server.
- JSON tag caches and imports are library-scoped. Python's legacy SQLite import
  state is not: use a separate SQLite file per library if using that backend.

The user-tested device architecture is `aarch64`. On your Windows computer, build
the tablet package from this checkout:

```powershell
.\scripts\package-tablet.ps1
```

This downloads jq 1.8.2 from its official release, verifies its pinned SHA-256
hash, builds `zotbridge-localgeta` (the local, offline PDF+annotation merger)
from its Go source, and creates
`dist\xovi-zotero-library-aarch64.zip`. The ZIP contains LF-terminated shell
scripts, both ARM64 binaries, and redistribution notices including the AGPL-3.0
license for the reMarkable-format parsing code `zotbridge-localgeta` is derived
from. It excludes credentials, state, and the Python environment. It is for
**aarch64 only**, not reMarkable 1/2's ARM32 CPU.

Copy that ZIP into `/home/root/xovi-zotero-bridge` on the tablet, then run there:

```sh
cd /home/root/xovi-zotero-bridge
unzip -o xovi-zotero-library-aarch64.zip
chmod 755 bin/jq
chmod 755 bin/zotbridge-localgeta
chmod 600 config.toml
./bin/jq --version
sh scripts/zotbridge-run.sh check-connection
sh scripts/zotbridge-run.sh list --limit 5 --json
```

The ZIP does **not** contain `config.toml`, so extracting it preserves your existing
credentials. On a new installation, copy `config.example.toml` to `config.toml`
and fill in the Zotero/WebDAV settings first. Never commit the credentials.

The launcher defaults to the Bash backend. Your existing config remains usable.
The example enables WebDAV for a personal library; set `use_webdav = false` for
Zotero Storage instead. WebDAV is not supported for Zotero group libraries.

If copied scripts produce `set: invalid option` or `$'\r': command not found`,
they have Windows line endings. The packaged scripts avoid this problem. To fix
a manually copied launcher:

```sh
sed -i 's/\r$//' scripts/zotbridge-run.sh
```

Tag commands now persist their cache in the bridge-owned JSON store while
preserving any existing import records. Folder operations use the separate broker
lock and recovery marker described above. The Python backend's existing SQLite
import database is unchanged.

### Commands

```sh
sh scripts/zotbridge-run.sh check-connection
sh scripts/zotbridge-run.sh list --query "attention" --limit 20 --json
sh scripts/zotbridge-run.sh import --item-key ABCD1234
sh scripts/zotbridge-run.sh status --item-key ABCD1234
```

Omitting the query lists top-level bibliographic items; the limit is 1-100, with
`--skip` for subsequent pages. The general `check-connection --item-key` downloader
now supports BusyBox; the older exported PDF probe is optional.

`list --json` returns an array with item metadata, any recorded `mapping`, and any
unconfirmed `attempt`. `tags --json` returns a string array; operation commands
return JSON objects. Successful commands exit
0; operation failures return `{"ok": false, "error": "...", "message": "..."}` and
exit 1. Unknown status returns `error: "not_found"`; an unconfirmed import returns
`error: "import_uncertain"` plus its attempt. Callers must always check exit codes
as well as JSON; startup failures such as missing tools are written to stderr.

### Configuration

| Setting | Meaning/default |
|---|---|
| `library_id`, `library_type`, `api_key` | Required Zotero credentials |
| `mb_in_path` | `/run/xovi-mb` |
| `mb_out_path` | `/run/xovi-mb-out` |
| `default_target_folder` | ReMarkable folder path for new imports; `Zotero/unread`. `--target-folder` overrides it. |
| `sync_queue_tag` | Tag selected for the Quick Settings batch; `to_sync`. |
| `sync_synced_tag` | Replacement tag after a verified batch import; `synced`. |
| `broker_timeout_s` | 30 seconds per transaction, greater than 0 and at most 300 |
| `state_db_path` | Python SQLite path, `./zotbridge-state.db`, relative to the config file |
| `state_json_path` | JSON state/tag cache shared by both backends; defaults to `state_db_path` followed by `.json`, relative to the config file |
| `xochitl_dir` | `/home/root/.local/share/remarkable/xochitl` |
| `use_webdav` | Boolean; false when omitted, true in the WebDAV example |
| `webdav_url` | Exact directory containing `<attachment-key>.zip` files, typically ending in `/zotero/` |
| `webdav_username`, `webdav_password` | Required when WebDAV is enabled; prefer a read-only app password |
| `webdav_timeout_s` | 60 seconds; greater than 0 and at most 300 |
| `webdav_max_download_mb` | 100 MiB limit for both downloaded ZIP and extracted PDF; configurable from 1 to 2048 |
| `webdav_allow_http` | False unless explicitly enabled; HTTP exposes credentials/files on the network |

`ZOTBRIDGE_CONFIG` selects another config file; use an absolute path with the launcher.
If `xochitl_dir` is omitted, `XOCHITL_DIR` is honored before the default.
The broker timeout does not impose a deadline on the complete Zotero search/download.
The shell backend supports the flat, single-line settings used in the example and
the generated config, including JSON-compatible quoted strings, numbers, booleans
and comments. It is not a general TOML parser; unsupported syntax is rejected.
Never change this file into an executable shell script.

### Optional Python backend for development

Python 3.12+ remains supported on computers where it is available. It is not
required on the tablet:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e .
ZOTBRIDGE_BACKEND=python sh scripts/zotbridge-run.sh check-connection
```

`ZOTBRIDGE_PYTHON` selects a different Python executable for that backend.
The shell backend can use `ZOTBRIDGE_JQ` to select an installed jq instead of
the bundled ARM64 executable (useful when testing on an x86-64 computer).

### WebDAV connection

Use HTTPS with a valid server certificate. Redirects are not followed, so configure
the final WebDAV URL. Unlike Zotero desktop's server setting, `webdav_url` must
include the actual attachment directory: this bridge does **not** append `zotero/`.
For a local server, use an address reachable from the tablet, not `localhost`.

The backend reads `<attachment-key>.zip` with authenticated GET, supports Zotero's
`%ZB64` encoded filenames, and extracts only the selected PDF into temporary storage.
Unsafe archive paths, ambiguous PDFs and oversized downloads are rejected. It
does not write ZIPs, `.prop` files, tags or metadata back to either server.
WebDAV failures are reported, not silently redirected to Zotero Storage.

`check-connection` tests metadata access only. Add `--item-key` for a parent item
containing a PDF to validate the complete download path. It deletes the temporary
download, does not touch import mappings and does not need a connected reMarkable.
The result reports the storage backend and byte count, not credentials or titles.

To migrate an existing `zotero2remarkable_bridge` `config.yml`, run
`scripts/import-legacy-config.py SOURCE DESTINATION` using a Python environment with
PyYAML and this package available (`PYTHONPATH=src` also works from the repo).
It maps the legacy Zotero and WebDAV settings, validates the new TOML configuration,
and refuses to overwrite an existing destination. It preserves the WebDAV URL;
check that this points to the attachment directory. The new file is created with
owner-only permissions on POSIX; on Windows, restrict its ACL to your account.
Use `config.toml` as the destination so Git ignores it. The source file is unchanged.

## Repeat runs and recovery

An import lock prevents overlapping imports using the same state file. A separate
lock beside the input FIFO serializes cooperating bridge broker transactions.
**Do not run other scripts that consume the broker's output FIFO concurrently**:
the upstream protocol cannot correlate their responses.

Importing an already mapped item returns `already_imported: true` and its existing
mapping without downloading or importing again. This is cached state, not a check
that the document still exists on the tablet.

Before sending an import, the backend records an unconfirmed attempt. A crash,
timeout or failed destination verification leaves that attempt visible through
`status`; normal retry is blocked to avoid duplicate documents. After checking the
tablet library, `--retry-uncertain` explicitly allows a retry that may create a
duplicate.

A broker transaction also leaves a marker beside the input FIFO until its reply
has been fully consumed. If the process dies or the reply times out, subsequent
broker requests are blocked: a late reply could otherwise be mistaken for a new
one, and the broker may be waiting for an output reader. Restart xochitl with XOVI
to recreate the FIFOs before retrying. Changed FIFO identities clear the marker
automatically; do not delete it merely to bypass a timeout. A restart can return
the tablet to stock mode, so re-enable XOVI using your existing installation method.

## Testing

The automated tests require no credentials, network calls or connected tablet:

```sh
python -m unittest discover -s tests -v
```

On Windows, after installing into `.venv`:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

The FIFO tests are skipped on Windows. From this Windows checkout, WSL can run
those tests using its standard-library Python, without installing the package:

```powershell
wsl --cd "$PWD" --exec env PYTHONPATH=src python3 -m unittest discover -s tests -p test_librarian.py -v
```

Coverage includes exact newline-framed requests, chunked EOF-framed replies, input
and response timeouts, stale-response recovery, malformed responses, invalid FIFO
paths, import locking, safe download cleanup, durable uncertainty, repeated import
suppression, structured errors, and read-only library enumeration/verification.
WebDAV tests cover authentication, URL construction, plain/encoded ZIP filenames,
archive safety, response errors, configuration validation and read-only checks.
Library tests cover OR-tag encoding, complete tag discovery across pages,
filtered totals, successive/last/empty pages, offset validation, and compatibility
of array responses with the optional page-info envelope.
Zotero is mocked; Linux FIFO tests use a simulated broker, not upstream binaries.

The remaining end-to-end acceptance test is on a compatible tablet: search for a
known remotely stored PDF, import it, confirm the returned UUID and visible document,
then repeat the import and confirm no duplicate. This deliberately creates a folder
and document; listing/status alone do not exercise the import path.
