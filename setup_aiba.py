#!/usr/bin/env python3
"""
setup_aiba.py - Image processing and branding patch for Aiba browser
"""

import os
import sys
from pathlib import Path
from PIL import Image

def process_icon_image(icon_path, src_dir):
    """
    Resize the custom icon into three required sizes and replace Chromium icons.
    """
    print(f"Processing icon image: {icon_path}")
    
    # Target sizes for Chromium icons
    sizes = [128, 32, 16]
    
    # Open the source image
    try:
        img = Image.open(icon_path)
        img = img.convert("RGBA")  # Ensure RGBA for transparency support
    except Exception as e:
        print(f"Error opening icon image: {e}")
        sys.exit(1)
    
    # Target directory for Chromium icons
    chromium_theme_dir = Path(src_dir) / "chrome" / "app" / "theme" / "chromium"
    
    if not chromium_theme_dir.exists():
        print(f"Error: Chromium theme directory not found: {chromium_theme_dir}")
        sys.exit(1)
    
    # Generate resized icons
    for size in sizes:
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        output_file = chromium_theme_dir / f"product_logo_{size}.png"
        resized.save(output_file, "PNG")
        print(f"Created: {output_file}")
    
    print("Icon processing complete.")

def create_branding_patch():
    """
    Create a patch file for the BRANDING file to customize browser name.
    """
    print("Creating branding patch...")
    
    patch_dir = Path("patches")
    patch_dir.mkdir(exist_ok=True)
    
    patch_content = """--- a/chrome/app/theme/chromium/BRANDING
+++ b/chrome/app/theme/chromium/BRANDING
@@ -1,4 +1,4 @@
-Copyright The Chromium Authors. All rights reserved.
+Copyright The Aiba Authors. All rights reserved.
 Use of this source code is governed by a BSD-style license that can be
 found in the LICENSE file.
"""
    
    patch_file = patch_dir / "aiba-branding.patch"
    with open(patch_file, "w") as f:
        f.write(patch_content)
    
    print(f"Created patch file: {patch_file}")
    
    # Append to series file
    series_file = patch_dir / "series"
    patch_entry = "aiba-branding.patch\n"
    
    if series_file.exists():
        with open(series_file, "r") as f:
            content = f.read()
        if patch_entry.strip() not in content:
            with open(series_file, "a") as f:
                f.write(patch_entry)
            print(f"Appended patch to series file: {series_file}")
        else:
            print(f"Patch already in series file")
    else:
        with open(series_file, "w") as f:
            f.write(patch_entry)
        print(f"Created series file with patch: {series_file}")

def main():
    """
    Main function to orchestrate setup tasks.
    """
    # Paths
    script_dir = Path(__file__).parent
    icon_path = script_dir / "aiba_icon.png"
    src_dir = script_dir / "build" / "src"
    
    # Check if icon exists
    if not icon_path.exists():
        print(f"Error: Icon image not found at {icon_path}")
        print("Please save your custom icon as 'aiba_icon.png' in the same directory as this script.")
        sys.exit(1)
    
    # Check if source directory exists
    if not src_dir.exists():
        print(f"Error: Source directory not found: {src_dir}")
        print("Please run build_aiba.sh first to download and extract the Chromium source.")
        sys.exit(1)
    
    # Process icon image
    process_icon_image(icon_path, src_dir)
    
    # Create branding patch
    create_branding_patch()
    
    print("\nSetup complete! You can now proceed with the build process.")

if __name__ == "__main__":
    main()
