# xovi integration notes

This folder is a placeholder for the xovi QML extension UI.

MVP UI behavior:
- render search box + result list
- call `zotbridge list --query <text> --json`
- on long-press item, call:
  - `zotbridge import --item-key <key> --target-folder "Zotero/unread"`
- show latest status via:
  - `zotbridge status --item-key <key>`

Recommended runtime dependency for command execution from QML:
- `qt-command-executor` xovi extension

Recommended runtime dependency for library operations:
- `rm-librarian`
