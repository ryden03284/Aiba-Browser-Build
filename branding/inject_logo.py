#!/usr/bin/env python3
"""Resize aiba_icon.png into Chromium product logos under build/src."""

from __future__ import annotations

import os
import sys
from pathlib import Path

from PIL import Image

SIZES = (128, 32, 16)
ICON_FILES = {
    128: "product_logo_128.png",
    32: "product_logo_32.png",
    16: "product_logo_16.png",
}


def project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def chromium_src_root() -> Path:
    root = project_root()
    src = os.environ.get("AIBA_CHROMIUM_SRC")
    if src:
        return Path(src)
    for candidate in (
        root / "ungoogled-chromium-debian",
        root / "ungoogled-chromium" / "build" / "src",
    ):
        theme = candidate / "chrome" / "app" / "theme" / "chromium"
        if theme.is_dir():
            return candidate
    return root / "ungoogled-chromium" / "build" / "src"


def chromium_theme_dir() -> Path:
    return chromium_src_root() / "chrome" / "app" / "theme" / "chromium"


def main() -> int:
    root = project_root()
    icon_path = root / "branding" / "aiba_icon.png"
    theme_dir = chromium_theme_dir()

    if not icon_path.is_file():
        print(f"ERROR: Icon not found: {icon_path}", file=sys.stderr)
        return 1
    if not theme_dir.is_dir():
        print(
            f"ERROR: Chromium theme directory not found: {theme_dir}\n"
            "Run build_aiba.sh through source unpack first, or set AIBA_CHROMIUM_SRC.",
            file=sys.stderr,
        )
        return 1

    try:
        source = Image.open(icon_path).convert("RGBA")
    except OSError as exc:
        print(f"ERROR: Failed to open icon: {exc}", file=sys.stderr)
        return 1

    for size in SIZES:
        out = theme_dir / ICON_FILES[size]
        resized = source.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(out, "PNG")
        print(f"Wrote {out}")

    print("Logo injection complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
