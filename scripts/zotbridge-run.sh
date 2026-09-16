#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

if [ ! -f config.toml ]; then
  echo "Missing config.toml. Copy config.example.toml and edit credentials." >&2
  exit 1
fi

python3 -m zotbridge.main "$@"
