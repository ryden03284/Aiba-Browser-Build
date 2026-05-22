#!/usr/bin/env python3
"""
Standalone branding helper: inject logos and patch string resources.

The main build uses inject_logo.py + branding/patches via build_aiba.sh.
This script is for re-running branding after source is already unpacked.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

BRANDING_REPLACEMENTS = (
    ("COMPANY_FULLNAME=The Chromium Authors", "COMPANY_FULLNAME=Aiba Authors"),
    ("COMPANY_SHORTNAME=The Chromium Authors", "COMPANY_SHORTNAME=Aiba Authors"),
    ("PRODUCT_FULLNAME=Chromium", "PRODUCT_FULLNAME=Aiba"),
    ("PRODUCT_SHORTNAME=Chromium", "PRODUCT_SHORTNAME=Aiba"),
    ("PRODUCT_INSTALLER_FULLNAME=Chromium Installer", "PRODUCT_INSTALLER_FULLNAME=Aiba Installer"),
    ("PRODUCT_INSTALLER_SHORTNAME=Chromium Installer", "PRODUCT_INSTALLER_SHORTNAME=Aiba Installer"),
    ("The Chromium Authors", "Aiba Authors"),
    ("MAC_BUNDLE_ID=org.chromium.Chromium", "MAC_BUNDLE_ID=org.aiba.browser"),
)

STRING_FILES = (
    "chrome/app/google_chrome_strings.grd",
    "chrome/app/chromium_strings.grd",
)


def project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def chromium_src() -> Path:
    root = project_root()
    src = os.environ.get("AIBA_CHROMIUM_SRC")
    if src:
        return Path(src)
    for candidate in (
        root / "ungoogled-chromium-debian",
        root / "ungoogled-chromium" / "build" / "src",
    ):
        if (candidate / "chrome" / "app" / "theme" / "chromium" / "BRANDING").is_file():
            return candidate
    return root / "ungoogled-chromium" / "build" / "src"


def patch_file(path: Path) -> None:
    text = path.read_text(encoding="utf-8")
    original = text
    for old, new in BRANDING_REPLACEMENTS:
        text = text.replace(old, new)
    text = re.sub(r"\bChromium\b", "Aiba", text)
    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"Patched {path}")
    else:
        print(f"No changes needed: {path}")


def main() -> int:
    root = project_root()
    src_dir = chromium_src()

    if not src_dir.is_dir():
        print(f"ERROR: Chromium source not found: {src_dir}", file=sys.stderr)
        return 1

    if os.environ.get("AIBA_SKIP_LOGO") != "1":
        inject = root / "branding" / "inject_logo.py"
        result = subprocess.run([sys.executable, str(inject)], check=False)
        if result.returncode != 0:
            return result.returncode

    branding_file = src_dir / "chrome" / "app" / "theme" / "chromium" / "BRANDING"
    if branding_file.is_file():
        patch_file(branding_file)
    else:
        print(f"ERROR: BRANDING file not found: {branding_file}", file=sys.stderr)
        return 1

    patched_any = False
    for rel in STRING_FILES:
        path = src_dir / rel
        if path.is_file():
            patch_file(path)
            patched_any = True
        else:
            print(f"Skipped (not present): {path}")

    if not patched_any:
        print("ERROR: No string resource files were patched.", file=sys.stderr)
        return 1

    print("Aiba branding setup complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
