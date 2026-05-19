#!/bin/bash
# build_aiba.sh - Automated build script for custom Aiba browser (ungoogled-chromium fork)

set -e  # Exit on error

# Configuration
REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium.git"
REPO_DIR="ungoogled-chromium"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================="
echo "Aiba Browser Build Script"
echo "=========================================="
echo ""

# Step 1: Source Code Fetching
echo "[1/6] Checking for ungoogled-chromium repository..."
if [ ! -d "$REPO_DIR" ]; then
    echo "Repository not found. Cloning from GitHub..."
    git clone "$REPO_URL"
    echo "Repository cloned successfully."
else
    echo "Repository already exists. Skipping clone."
fi

echo ""
echo "[2/6] Entering repository directory..."
cd "$REPO_DIR"

echo ""
echo "[3/6] Creating download cache directory..."
mkdir -p download_cache

echo ""
echo "[4/6] Downloading Chromium source code..."
python3 utils/downloads.py retrieve -i downloads.ini -c download_cache

echo ""
echo "[5/6] Extracting Chromium source code..."
python3 utils/downloads.py unpack -i downloads.ini -c download_cache build/src

# Step 2: Image Processing and Branding
echo ""
echo "[6/7] Running setup_aiba.py for icon processing and branding..."
cd "$SCRIPT_DIR"
python3 setup_aiba.py

# Step 3: Apply Privacy Features and Custom Branding
echo ""
echo "[7/8] Applying privacy features and custom patches..."
cd "$REPO_DIR"
python3 utils/prune_binaries.py
python3 utils/patches.py apply build/src patches

# Step 4: Configure Build with Optimized Settings
echo ""
echo "[8/9] Configuring build with GN (optimized for 10GB RAM)..."
cd build/src

# Create args.gn with concurrent_links=1 to prevent OOM
cat > out/Default/args.gn << 'EOF'
# Build configuration for Aiba browser
# Optimized for systems with 10GB RAM

# Prevent OOM by limiting concurrent links
concurrent_links = 1

# Standard Chromium build flags
is_debug = false
is_official_build = true
enable_nacl = false
enable_remoting = false
use_goma = false
EOF

echo "Running gn gen..."
gn gen out/Default

# Step 5: Compile with Optimized Settings
echo ""
echo "[9/9] Starting compilation with nice -n 19 and -j4..."
echo "This will use all 4 CPU cores with low priority to prevent desktop freezing."
echo "Build time may take several hours depending on your system."
echo ""

nice -n 19 ninja -C out/Default chrome -j4

echo ""
echo "=========================================="
echo "Build complete!"
echo "=========================================="
echo "The Aiba browser binary is located at:"
echo "  $REPO_DIR/build/src/out/Default/chrome"
echo ""
echo "You can run it with:"
echo "  cd $REPO_DIR/build/src/out/Default && ./chrome"
