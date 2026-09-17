#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

export ZOTBRIDGE_CONFIG="${ZOTBRIDGE_CONFIG:-$ROOT_DIR/config.toml}"
case "${ZOTBRIDGE_BACKEND:-shell}" in
  shell)
    if command -v bash >/dev/null 2>&1; then
      exec bash "$ROOT_DIR/scripts/zotbridge-shell.sh" "$@"
    fi
    if [ -x /usr/bin/bash ]; then
      exec /usr/bin/bash "$ROOT_DIR/scripts/zotbridge-shell.sh" "$@"
    fi
    if [ -x /bin/bash ]; then
      exec /bin/bash "$ROOT_DIR/scripts/zotbridge-shell.sh" "$@"
    fi
    printf '%s\n' '{"ok":false,"error":"missing_dependency","message":"Bash is required for the shell backend. Install Bash or set ZOTBRIDGE_BACKEND=python."}'
    exit 1
    ;;
  python) ;;
  *)
    printf '%s\n' '{"ok":false,"error":"configuration_error","message":"ZOTBRIDGE_BACKEND must be shell or python."}'
    exit 1
    ;;
esac
if [ -z "${ZOTBRIDGE_PYTHON:-}" ]; then
  if [ -x "$ROOT_DIR/.venv/bin/python" ]; then
    ZOTBRIDGE_PYTHON="$ROOT_DIR/.venv/bin/python"
  else
    ZOTBRIDGE_PYTHON=python3
  fi
fi

exec "$ZOTBRIDGE_PYTHON" -m zotbridge.main "$@"
