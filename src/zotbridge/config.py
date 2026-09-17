from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import os
import tomllib
from uuid import UUID
from urllib.parse import urlsplit


@dataclass(frozen=True)
class WebDAVConfig:
    url: str
    username: str
    password: str = field(repr=False)
    timeout_s: float = 60.0
    max_download_mb: int = 100


@dataclass(frozen=True)
class Config:
    library_id: str
    library_type: str
    api_key: str = field(repr=False)
    mb_in_path: str = "/run/xovi-mb"
    mb_out_path: str = "/run/xovi-mb-out"
    state_db_path: str = "./zotbridge-state.db"
    broker_timeout_s: float = 30.0
    xochitl_dir: str = "/home/root/.local/share/remarkable/xochitl"
    webdav: WebDAVConfig | None = None
    state_json_path: str = "./zotbridge-state.db.json"
    default_target_folder: str = "Zotero/unread"


def load_config(path: Path | None = None) -> Config:
    config_path = (path or Path(os.environ.get("ZOTBRIDGE_CONFIG", "config.toml"))).expanduser().resolve()
    if not config_path.exists():
        raise FileNotFoundError(
            f"Missing config file: {config_path}. Copy config.example.toml to config.toml."
        )

    with config_path.open("rb") as f:
        raw = tomllib.load(f)
    return config_from_dict(raw, config_path)


def config_from_dict(raw: dict, config_path: Path) -> Config:
    required = ("library_id", "library_type", "api_key")
    missing = [key for key in required if not raw.get(key)]
    if missing:
        raise ValueError(f"Missing required config keys: {', '.join(missing)}")
    if raw["library_type"] not in ("user", "group"):
        raise ValueError("library_type must be 'user' or 'group'")
    timeout = float(raw.get("broker_timeout_s", 30.0))
    if not 0 < timeout <= 300:
        raise ValueError("broker_timeout_s must be greater than 0 and at most 300")
    state_path = Path(raw.get("state_db_path", "./zotbridge-state.db")).expanduser()
    if not state_path.is_absolute():
        state_path = config_path.parent / state_path
    json_setting = raw.get("state_json_path", str(raw.get("state_db_path", "./zotbridge-state.db")) + ".json")
    if not isinstance(json_setting, str) or not json_setting.strip():
        raise ValueError("state_json_path must be a nonempty path")
    json_path = Path(json_setting).expanduser()
    if not json_path.is_absolute():
        json_path = config_path.parent / json_path
    if json_path.resolve() == state_path.resolve():
        raise ValueError("state_json_path must differ from state_db_path")
    target = raw.get("default_target_folder", "Zotero/unread")
    if (not isinstance(target, str) or any(not part.strip() for part in target.split("/"))
            or any(ord(character) < 32 or ord(character) == 127 for character in target)):
        raise ValueError("default_target_folder must be a nonempty folder path without controls or empty components")
    try:
        UUID(target)
    except ValueError:
        pass
    else:
        raise ValueError("default_target_folder must be a path, not an unchecked UUID")
    webdav = None
    enabled = raw.get("use_webdav", False)
    if not isinstance(enabled, bool):
        raise ValueError("use_webdav must be a TOML boolean: true or false")
    if enabled:
        if raw["library_type"] != "user":
            raise ValueError("Zotero WebDAV file storage is supported only for personal libraries")
        keys = ("webdav_url", "webdav_username", "webdav_password")
        if any(not isinstance(raw.get(key), str) or not raw[key].strip() for key in keys):
            raise ValueError("WebDAV requires webdav_url, webdav_username and webdav_password")
        url = urlsplit(raw["webdav_url"])
        if url.scheme not in ("http", "https") or not url.hostname:
            raise ValueError("webdav_url must be an absolute HTTP(S) URL")
        if url.username or url.password or url.query or url.fragment:
            raise ValueError("webdav_url cannot contain credentials, a query or a fragment")
        if url.scheme == "http" and raw.get("webdav_allow_http") is not True:
            raise ValueError(
                "HTTP exposes WebDAV credentials and files. Use HTTPS, or explicitly set "
                "webdav_allow_http = true for a trusted network."
            )
        webdav_timeout = float(raw.get("webdav_timeout_s", 60.0))
        max_mb = raw.get("webdav_max_download_mb", 100)
        if not 0 < webdav_timeout <= 300:
            raise ValueError("webdav_timeout_s must be greater than 0 and at most 300")
        if type(max_mb) is not int or not 1 <= max_mb <= 2048:
            raise ValueError("webdav_max_download_mb must be an integer from 1 to 2048")
        webdav = WebDAVConfig(
            url=raw["webdav_url"].rstrip("/") + "/",
            username=raw["webdav_username"],
            password=raw["webdav_password"],
            timeout_s=webdav_timeout,
            max_download_mb=max_mb,
        )

    return Config(
        library_id=str(raw["library_id"]),
        library_type=str(raw["library_type"]),
        api_key=str(raw["api_key"]),
        mb_in_path=str(raw.get("mb_in_path", "/run/xovi-mb")),
        mb_out_path=str(raw.get("mb_out_path", "/run/xovi-mb-out")),
        state_db_path=str(state_path),
        state_json_path=str(json_path),
        default_target_folder=target,
        broker_timeout_s=timeout,
        xochitl_dir=str(
            raw.get("xochitl_dir", os.environ.get("XOCHITL_DIR", Config.xochitl_dir))
        ),
        webdav=webdav,
    )
