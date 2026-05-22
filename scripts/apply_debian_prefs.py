#!/usr/bin/env python3
"""Merge Aiba prefs into ungoogled-chromium-debian/debian/initial_preferences."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def deep_merge(base: dict, overlay: dict) -> dict:
    for key, value in overlay.items():
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            deep_merge(base[key], value)
        else:
            base[key] = value
    return base


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} DEBIAN_REPO_ROOT", file=sys.stderr)
        return 1

    debian_root = Path(sys.argv[1])
    prefs_path = debian_root / "debian" / "initial_preferences"
    overlay_path = Path(__file__).resolve().parent.parent / "config" / "aiba_prefs_overlay.json"

    if not prefs_path.is_file():
        print(f"ERROR: {prefs_path} not found (run debian/rules setup first?)", file=sys.stderr)
        return 1
    if not overlay_path.is_file():
        print(f"ERROR: {overlay_path} not found", file=sys.stderr)
        return 1

    prefs = json.loads(prefs_path.read_text(encoding="utf-8"))
    overlay = json.loads(overlay_path.read_text(encoding="utf-8"))
    deep_merge(prefs, overlay)

    # Debian template disables default apps; allow bundled CRX install.
    prefs.pop("default_apps", None)
    prefs["default_apps_install_state"] = 1

    prefs_path.write_text(json.dumps(prefs, indent=4) + "\n", encoding="utf-8")
    print(f"Updated {prefs_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
