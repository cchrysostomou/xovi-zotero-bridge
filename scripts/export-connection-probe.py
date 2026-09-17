"""Export a private, curl-only tablet access check using the local config.toml."""

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import quote
import zipfile

from zotbridge.config import Config, load_config


def curl_string(value: str) -> str:
    if any(character in value for character in ("\r", "\n", "\0")):
        raise ValueError("Connection settings must not contain newline or NUL characters")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def private_write(path: Path, content: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
        output.write(content)


def write_package(root: Path, name: str, archive_name: str, files: dict[str, str]) -> None:
    directory = root / "dist" / name
    archive = root / "dist" / archive_name
    if directory.exists() or archive.exists():
        raise ValueError("Probe already exists; choose a new export after removing the previous private copy.")
    directory.mkdir(parents=True, exist_ok=False)
    for filename, content in files.items():
        private_write(directory / filename, content)
    descriptor = os.open(archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output, zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as zipped:
        for filename in files:
            entry = zipfile.ZipInfo(name + "/" + filename)
            entry.create_system = 3
            entry.external_attr = 0o100600 << 16
            zipped.writestr(entry, (directory / filename).read_bytes())
    print(f"Created dist/{archive_name} (contains credentials; do not share).")


def export_pdf(root: Path, config: Config, item_key: str | None) -> None:
    import httpx2
    from pyzotero import zotero_errors
    from zotbridge.zotero_client import ZoteroBridge

    if (root / "dist" / "pdf-check").exists():
        raise ValueError("PDF probe already exists; existing private files were not changed.")
    if item_key is not None and re.fullmatch(r"[A-Z0-9]{8}", item_key) is None:
        raise ValueError("item-key must contain eight uppercase letters or digits")
    zotero = ZoteroBridge(config.library_id, config.library_type, config.api_key, config.webdav)
    if config.webdav is None or zotero.webdav is None:
        raise ValueError("The PDF probe requires WebDAV configuration.")
    try:
        if item_key is None:
            papers = zotero.search("", limit=10)
            selected = next((paper for paper in papers if paper.has_pdf), None)
            if selected is None:
                raise ValueError("No stored PDF found among the first ten items; supply --item-key.")
            item_key = selected.item_key
        attachment_key = zotero._first_pdf_attachment_key(item_key)
        if attachment_key is None:
            raise ValueError("Selected item has no stored PDF attachment.")
        attachment = zotero.zot.item(attachment_key)["data"]
        with tempfile.TemporaryDirectory(prefix="zotbridge-probe-") as td:
            pdf = Path(td) / "document.pdf"
            member = zotero.webdav.download_pdf(attachment_key, attachment.get("filename", ""), pdf)
            with pdf.open("rb") as stream:
                if stream.read(5) != b"%PDF-":
                    raise ValueError("Selected attachment does not have the expected PDF header.")
            size = pdf.stat().st_size
    except (httpx2.HTTPError, zotero_errors.PyZoteroError) as exc:
        raise ValueError(f"Zotero metadata request failed ({type(exc).__name__}); credentials withheld.") from None
    if member.startswith("-") or any(character in member for character in "*?[]\r\n\0"):
        raise ValueError("Selected ZIP member name is not supported by this minimal unzip probe.")
    curl_config = "\n".join((
        "url = " + curl_string(config.webdav.url + attachment_key + ".zip"),
        "user = " + curl_string(config.webdav.username + ":" + config.webdav.password),
        'proto = "=https"' if config.webdav.url.startswith("https:") else 'proto = "=http,https"',
        "max-filesize = " + str(config.webdav.max_download_mb * 1024 * 1024),
    )) + "\n"
    write_package(root, "pdf-check", "zotero-pdf-check-private.zip", {
        "check-pdf-download.sh": (root / "scripts" / "check-pdf-download.sh").read_text(encoding="utf-8"),
        "webdav-pdf.curl": curl_config,
        "member.txt": member + "\n",
        "expected-size.txt": str(size) + "\n",
    })
    print(f"Prepared one verified PDF ({size} bytes); no remote changes.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pdf", action="store_true", help="Prepare a one-PDF download probe instead of access checks")
    parser.add_argument("--item-key", help="Parent item for --pdf; defaults to the first PDF among ten items")
    args = parser.parse_args()
    if args.item_key and not args.pdf:
        parser.error("--item-key requires --pdf")
    root = Path(__file__).resolve().parents[1]
    config = load_config()
    if config.webdav is None:
        raise ValueError("This probe requires use_webdav = true")
    if args.pdf:
        export_pdf(root, config, args.item_key)
        return
    library = "users" if config.library_type == "user" else "groups"
    url = f"https://api.zotero.org/{library}/{quote(config.library_id, safe='')}/items/top?limit=1"
    zotero = "\n".join((
        "url = " + curl_string(url),
        "header = " + curl_string("Zotero-API-Key: " + config.api_key),
        'header = "Zotero-API-Version: 3"',
        'proto = "=https"',
    )) + "\n"
    webdav = "\n".join((
        "url = " + curl_string(config.webdav.url),
        "user = " + curl_string(config.webdav.username + ":" + config.webdav.password),
        'request = "PROPFIND"',
        'header = "Depth: 0"',
        'header = "Content-Type: application/xml"',
        'data = "<propfind xmlns=\\"DAV:\\"><prop><resourcetype/></prop></propfind>"',
        'proto = "=https"' if config.webdav.url.startswith("https:") else 'proto = "=http,https"',
    )) + "\n"
    write_package(root, "connection-check", "zotero-connection-check-private.zip", {
        "check-zotero-connection.sh": (root / "scripts" / "check-zotero-connection.sh").read_text(encoding="utf-8"),
        "zotero.curl": zotero,
        "webdav.curl": webdav,
    })


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Export failed: {exc}", file=sys.stderr)
        sys.exit(1)
