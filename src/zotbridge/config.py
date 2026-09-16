from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    import tomli as tomllib


@dataclass(frozen=True)
class Config:
    library_id: str
    library_type: str
    api_key: str
    mb_in_path: str = "/run/xovi-mb"
    mb_out_path: str = "/run/xovi-mb-out"
    state_db_path: str = "./zotbridge-state.db"


def load_config() -> Config:
    config_path = Path(os.environ.get("ZOTBRIDGE_CONFIG", "config.toml"))
    if not config_path.exists():
        raise FileNotFoundError(
            f"Missing config file: {config_path}. Copy config.example.toml to config.toml."
        )

    with config_path.open("rb") as f:
        raw = tomllib.load(f)

    required = ("library_id", "library_type", "api_key")
    missing = [key for key in required if not raw.get(key)]
    if missing:
        raise ValueError(f"Missing required config keys: {', '.join(missing)}")

    return Config(
        library_id=str(raw["library_id"]),
        library_type=str(raw["library_type"]),
        api_key=str(raw["api_key"]),
        mb_in_path=str(raw.get("mb_in_path", "/run/xovi-mb")),
        mb_out_path=str(raw.get("mb_out_path", "/run/xovi-mb-out")),
        state_db_path=str(raw.get("state_db_path", "./zotbridge-state.db")),
    )
