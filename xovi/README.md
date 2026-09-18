# xovi integration notes

The UI is a **Zotero Quick Settings action** plus a 3.28 Settings page, not an
AppLoad app. It sits alongside the installed Bluetooth action without replacing
that mod.

Reference: [quickSettingsBluetooth.qmd](https://github.com/rmitchellscott/xovi-qmd-extensions),
with firmware-specific copies in `3.27` and `3.28`. They insert a native Quick
Settings control through QMLDiff and use `qt-command-executor`.

## Install

This repository supplies the Quick Settings action for reMarkable OS/XOVI resource
layouts **3.27** and **3.28**, plus a **3.28-only** Zotero Bridge Settings page:

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

It builds both public archives, transfers them through SSH as `root`, extracts
the bridge runtime, and installs both 3.28 QMD files in
`/home/root/xovi/exthome/qt-resource-rebuilder/`. The runtime archive contains
neither `config.toml` nor bridge state, so those files are not overwritten.
Restart XOVI afterward to load the QMD changes.

The 3.28 Settings app sidebar gains **Zotero Bridge**. It edits the WebDAV URL,
username, password replacement, default reMarkable folder, and queue/completion
tags. It also reports whether the bundled rmapi is paired with reMarkable Cloud
and accepts the eight-character code generated at
`my.remarkable.com/device/browser/connect`. Pairing uses a short-lived private
draft; the code field is cleared immediately, and neither the code nor cloud
tokens are returned to QML or recorded in the activity log. The pairing status is
shown independently. **Pair** creates the first pairing; **Re-pair** safely
replaces an existing token only after the new cloud credentials are verified.
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

The backend entry point is:

```sh
sh /home/root/xovi-zotero-bridge/scripts/zotbridge-run.sh sync-tagged
```

The Quick Settings button now invokes `sync-all`: it first exports and uploads
documents from `reverse_sync_folder`, then runs `sync-tagged`. The reverse phase
moves only fully verified uploads to `Copied2Zotero`; failures remain in the
source folder and appear in the activity log with UUID, stage, and error code.

The forward phase reads live `to_sync` tags on both references and attachments. A tagged
reference selects its first stored PDF; a tagged attachment selects that exact
PDF. Overlapping selections reuse the UUID mapping instead of importing twice.
After a confirmed import, the backend changes only the source's `to_sync` tag to
`synced`. It separately asks rm-librarian to add the source's other Zotero tags
while preserving existing reMarkable tags; tag failure is reported but does not
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

The Zotero browser (search, cached tags, pagination, long-press import) is a later
UI. Its existing `list`, `tags`, `import` and `status` APIs remain available.

Recommended runtime dependency for command execution from QML:
- `qt-command-executor` xovi extension
- `qt-resource-rebuilder` for the Quick Settings QMD patch

Recommended runtime dependency for library operations:
- `rm-librarian`
