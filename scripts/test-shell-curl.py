#!/usr/bin/python3
"""Offline curl fixture for test-shell.py; never performs a network request."""
import json
import os
from pathlib import Path
import shutil
import stat
import sys


args = sys.argv[1:]
root = Path(os.environ["SHELL_TEST_ROOT"])
assert args[0] == "-q", "curl defaults must be disabled"
config = Path(args[args.index("--config") + 1])
if os.environ.get("SHELL_TEST_REQUIRE_MODES", "1") == "1":
    assert stat.S_IMODE(config.stat().st_mode) == 0o600
assert "fixture-api-secret" not in " ".join(args)
assert "fixture-password" not in " ".join(args)
options = {}
for line in config.read_text().splitlines():
    key, separator, value = line.partition(" = ")
    if separator:
        options.setdefault(key, []).append(json.loads(value))
url = options["url"][0]
headers = options.get("header", [])
with (root / "calls.jsonl").open("a") as stream:
    stream.write(json.dumps({"url": url, "api": any("Zotero-API-Key:" in h for h in headers),
                             "basic": "user" in options}) + "\n")
routes = json.loads((root / "routes.json").read_text())
route = routes.get(url, {"status": 404, "body": ""})
output = Path(args[args.index("--output") + 1])
header_file = Path(args[args.index("--dump-header") + 1])
header_file.write_text(f"HTTP/1.1 {route.get('status', 200)} fixture\r\n" +
                       "".join(f"{key}: {value}\r\n" for key, value in route.get("headers", {}).items()) +
                       "\r\n")
if "file" in route:
    shutil.copyfile(root / route["file"], output)
else:
    body = route.get("body", "")
    output.write_text(body if isinstance(body, str) else json.dumps(body))
sys.stdout.write(str(route.get("status", 200)))
