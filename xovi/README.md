# xovi integration notes

The UI has three independent pieces:

- a **Zotero Quick Settings action** for one-tap bidirectional sync
- a **3.28 Settings page** for bridge configuration
- an **AppLoad Zotero Library app** for browsing, filtering and importing papers

They all reuse the same `/home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh`
backend commands; there is no separate AppLoad daemon or duplicated Zotero client.

Reference: [quickSettingsBluetooth.qmd](https://github.com/rmitchellscott/xovi-qmd-extensions),
with firmware-specific copies in `3.27` and `3.28`. They insert a native Quick
Settings control through QMLDiff and use `qt-command-executor`.

## Install

This repository supplies the Quick Settings action for reMarkable OS/XOVI resource
layouts **3.27** and **3.28**, a **3.28-only** Zotero Bridge Settings page, and a
frontend-only AppLoad application:

```sh
cat /etc/version
```

Copy only the matching file to the resource-rebuilder extension directory, then
restart XOVI using your normal procedure:

```sh
# For version 3.27:
cp xovi/3.27/zoteroQuickSync.qmd \
  /home/root/xovi/exthome/qt-resource-rebuilder/

# For version 3.28:
cp xovi/3.28/zoteroQuickSync.qmd \
  /home/root/xovi/exthome/qt-resource-rebuilder/
cp xovi/3.28/zoteroBridgeSettings.qmd \
  /home/root/xovi/exthome/qt-resource-rebuilder/
```

Do not install either patch on another version, beta firmware, or an unverified
XOVI resource build: QMLDiff selectors are intentionally firmware-specific. Keep
the existing Bluetooth QMD installed; the Zotero patch adds a separate button after
the same anchor. To uninstall, remove only `zoteroQuickSync.qmd` and restart XOVI.

## Reader "Send to Zotero" button (3.28 only)

`xovi/3.28/zoteroSendToZotero.qmd` adds a toolbar icon (falling back to a
Settings/More Tools menu entry when the toolbar is cramped) to the document
reader. Tapping it opens a full-screen dialog that sends the open document
directly to Zotero over WebDAV — no folder duplication and no reverse-sync
wait step.

If the document already has a Zotero item (via `doc-status`), the dialog
skips the new/attach choice entirely and shows two independent checkboxes:
"Send PDF + markup" and "Markup only". The already-uploaded unmarked PDF is
never resent. If neither box is checked, no attachment is uploaded, but any
changed tag selection is still applied to the existing item.

If the document has no Zotero item yet, the dialog offers "Create new item"
or "Attach to existing item" (with search), plus three independent
checkboxes: "Send unmarked PDF" (checked by default), "Send PDF + markup",
and "Markup only". At least one must stay checked.

Checked variants map to distinct attachment filenames: the unmarked PDF as
`<name>.pdf`, the merged PDF-with-markup as `<name>.rm.pdf`, and the
annotated-pages-only PDF as `<name>.rm.annot.pdf`. If a merged/markup-only
variant is requested but the document has no annotations at all, that
variant is silently skipped (nothing new to send) rather than uploading an
unchanged copy of the plain PDF under a markup filename. Tag changes always
apply regardless of which variants were sent.

It calls the existing `doc-status` and `doc-tags` bridge commands to read
current state, and the new `send-to-zotero` command
(`--uuid`, `--mode {new,attach}`, `--parent-key`, `--collection`, `--tags`,
`--send-plain`, `--send-merged`, `--send-annotated-only`) to do the upload
and tag-update work. `send-to-zotero` exports/trims markup locally with the
bundled `zotbridge-localgeta` binary and uploads over WebDAV — it never
contacts reMarkable Cloud.

```sh
cp xovi/3.28/zoteroSendToZotero.qmd \
  /home/root/xovi/exthome/qt-resource-rebuilder/
```

`.\scripts\update-remarkable.ps1` installs this file automatically alongside
the other two 3.28 QMD patches, and copies its glyph icon
(`xovi/assets/zotero-send-icon.png`, a plain "Z" glyph, not a native firmware
icon resource) to `/home/root/xovi-zotero-bridge/assets/`.

This patch has **not** been validated on-device yet. Its toolbar/menu insertion
points and native property tokens are copied from the community-published
`touchLock.qmd` (matching this firmware build), but the button and dialog
behavior themselves are new and should be tested carefully — ideally with a way
to revert (remove the file and restart XOVI) if the reader toolbar or menus
misbehave.

The displayed Quick Settings icon is a circular **Z** badge. It inverts while the operation runs,
and cannot be tapped again during that time. Xochitl's logging feedback reports
start, completion counts, partial failure counts, launch failure, or invalid output.

To transfer only the UI files from Windows, build
`dist\xovi-zotero-quick-settings-qmd.zip`:

```powershell
.\scripts\package-xovi-quick-settings.ps1
```

Copy that ZIP to `/home/root/xovi-zotero-bridge`, extract it, and use the matching
`3.27` or `3.28` path from the commands above. The UI ZIP contains no credentials,
configuration, state, or backend scripts.

For the standard 3.28 tablet at `192.168.1.33`, run this from the repository in
Windows PowerShell:

```powershell
.\scripts\update-remarkable.ps1
```

It builds the public archives, transfers them through SSH as `root`, extracts
the bridge runtime, installs both 3.28 QMD files in
`/home/root/xovi/exthome/qt-resource-rebuilder/`, and installs the AppLoad app in
`/home/root/xovi/exthome/appload/zotero-library/`. The runtime archive contains
neither `config.toml` nor bridge state, so those files are not overwritten.
Restart XOVI afterward to load the QMD changes and AppLoad's app list.

The 3.28 Settings app sidebar gains **Zotero Bridge**. It edits the WebDAV URL,
username, password replacement, default reMarkable folder, and queue/completion
tags. There is no reMarkable Cloud pairing step: reverse synchronization reads
directly from the on-device xochitl library and merges annotations locally with
the bundled `zotbridge-localgeta` binary, so no cloud account or one-time code
is ever needed.
The **reMarkable source folder** setting defaults to `Zotero/Read` and will be
used by reverse synchronization.

The stored WebDAV password is never returned to QML: the page shows only its
presence and an empty password field preserves it. Refresh tags and refresh-log
buttons call the bridge asynchronously and display their JSON results. The
activity section provides **Refresh log** and **Clear log** controls; clearing
also immediately empties the displayed event list.

The Settings page loads cached tags on entry and provides **Refresh tags** for the
explicit live refresh. All available Zotero tags appear in a bounded, scrollable
panel below it; use the horizontally-scrollable **All**, **#**, or **A–Z** filter
buttons to narrow that display. Queue and completion tags are chosen from
scrollable, searchable tag pickers rather than freeform entries; save is rejected
if they are identical.
**Test Zotero connection** makes read-only Zotero metadata and WebDAV directory
requests. It does not download a PDF, import a document, or modify Zotero/WebDAV.

The Quick Settings backend entry point is:

```sh
sh /home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh sync-all
```

The Quick Settings button now invokes `sync-all`: it first exports and uploads
documents from `reverse_sync_folder`, then runs `sync-tagged`. The reverse phase
moves only fully verified uploads to `Copied2Zotero`; failures remain in the
source folder and appear in the activity log with UUID, stage, and error code.

The forward phase reads live `to_sync` tags on both references and attachments. A tagged
reference selects its first stored PDF; a tagged attachment selects that exact
PDF. Overlapping selections reuse the UUID mapping instead of importing twice.
After a confirmed import, the backend changes only the source's `to_sync` tag to
`synced`. It separately asks rm-librarian to add the source's other Zotero tags,
plus two fixed marker tags, `zotero-import` and `unread`, while preserving
existing reMarkable tags; tag failure is reported but does not
block Zotero completion. Zotero API write permission is required.

Each resolved forward-sync hit is written to the activity log with its queued
Zotero item key and the PDF attachment filename returned by the Zotero API.
Attachment archive failures are logged per item and the batch continues with
later queue entries. Imported display names remove unsupported delimiters,
control characters, and inline Zotero markup while preserving valid Unicode.

Imports use `default_target_folder` from `config.toml` (default `Zotero/unread`).
ReMarkable library browsing and a destination picker are deferred from this MVP.
Use `AsyncCommandExecutor` (`net.asivery.CommandExecutor 1.0`), not the Bluetooth
mod's synchronous command execution for this longer network/import operation.
The UI must pass arguments as an array, disable repeat taps, accumulate complete
stdout until completion, and check both the exit code and parsed `ok` field.
Handle launch failure explicitly. Display honest running/completed/partial-failure
states using the batch summary, not invented percentage progress.

The executor is inserted into the Quick Settings root, matching the Bluetooth
patch's placement, rather than into a transient dialog. Its practical lifetime
while closing and reopening Quick Settings must still be validated on-device.
Do not close xochitl/XOVI while a sync is running; that ends the process and leaves
an in-flight import intentionally uncertain. Do not detach an untracked background
job or automatically retry uncertain imports. The backend's `remaining` keys and
per-source results explain partial completion. There is no idle polling service.

If no visible feedback appears after a tap, inspect the local activity log:

```sh
sh /home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh activity-log
```

It records safe command/outcome/error-code events only—never credentials, request
URLs, titles, or error messages. Clear it with `clear-activity-log` after retaining
any useful failure evidence.

## AppLoad Zotero Library app

The AppLoad app lives in `xovi/appload/zotero-library/`. It is frontend-only QML
with `manifest.json`, `icon.png`, and a compiled `resources.rcc`; it imports
`net.asivery.CommandExecutor 1.0` and invokes existing bridge commands:

```sh
sh /home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh tags --json
sh /home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh list --page-info --limit 8 --skip N --query TEXT --tag TAG
sh /home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh import --item-key KEY
```

The app shows a searchable Zotero library, cached/live tag filters, previous/next
offset pagination and long-press-to-import rows. The `list --page-info` command
does all filtering and pagination; the app only passes selected tags/query/offset
and renders the returned JSON. Long-press import uses the existing `import`
command, so mapping, duplicate checks, target folder behavior and broker safety
remain centralized in the backend.

To build only the AppLoad archive:

```powershell
.\scripts\package-xovi-appload.ps1
```

The package script uses a native `rcc` when available. If not, it can bootstrap a
local WSL-only Qt `rcc` cache with `apt-get download`; no Qt files are committed
or copied to the tablet. The resulting
`dist\xovi-zotero-appload-app.zip` contains only:

```text
zotero-library/manifest.json
zotero-library/icon.png
zotero-library/resources.rcc
```

Extract that directory under `/home/root/xovi/exthome/appload/` if installing
manually, then restart or refresh AppLoad so it rescans applications.

Recommended runtime dependency for command execution from QML:
- `qt-command-executor` xovi extension
- `qt-resource-rebuilder` for the Quick Settings QMD patch
- `rm-appload` for the Zotero Library app

Recommended runtime dependency for library operations:
- `rm-librarian`
