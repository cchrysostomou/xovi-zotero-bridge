"""Migrate an existing bridge YAML config without displaying its credentials.

Requires PyYAML in the interpreter running this migration, not on the tablet.
Run from the repository with PYTHONPATH=src if the package is not installed.
"""

import argparse
import json
import os
from pathlib import Path
import sys
import tomllib

from zotbridge.config import config_from_dict


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        import yaml
    except ImportError:
        raise RuntimeError("This one-time migration requires PyYAML.") from None
    try:
        legacy = yaml.safe_load(args.source.read_text(encoding="utf-8"))
    except yaml.YAMLError:
        raise ValueError("The source is not valid YAML; credential values were withheld.") from None
    if not isinstance(legacy, dict):
        raise ValueError("Expected a YAML configuration mapping")
    enabled = str(legacy.get("USE_WEBDAV", False)).lower()
    if enabled not in ("true", "false"):
        raise ValueError("Legacy USE_WEBDAV must be true or false")
    data = {
        "library_id": str(legacy.get("LIBRARY_ID", "")),
        "library_type": legacy.get("LIBRARY_TYPE", ""),
        "api_key": legacy.get("API_KEY", ""),
        "use_webdav": enabled == "true",
    }
    if data["use_webdav"]:
        data.update({
            "webdav_url": legacy.get("WEBDAV_HOSTNAME", ""),
            "webdav_username": legacy.get("WEBDAV_USER", ""),
            "webdav_password": legacy.get("WEBDAV_PWD", ""),
            "webdav_timeout_s": 60.0,
            "webdav_max_download_mb": 100,
        })
    data.update({
        "mb_in_path": "/run/xovi-mb",
        "mb_out_path": "/run/xovi-mb-out",
        "state_db_path": "./zotbridge-state.db",
        "broker_timeout_s": 30.0,
        "xochitl_dir": "/home/root/.local/share/remarkable/xochitl",
    })
    content = "\n".join(
        f"{key} = {json.dumps(value, ensure_ascii=False).replace(chr(127), r'\u007f')}"
        for key, value in data.items()
    ) + "\n"
    config_from_dict(tomllib.loads(content), args.destination.resolve())
    descriptor = os.open(args.destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        output.write(content)
    print("Created local configuration. Credentials were not displayed; source was unchanged.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Migration failed: {exc}", file=sys.stderr)
        sys.exit(1)
