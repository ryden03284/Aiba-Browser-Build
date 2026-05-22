#!/usr/bin/env bash
# ====================================================================
# Aiba Browser Build Script
# Production CI/CD Version for ungoogled-chromium Debian packaging
# ====================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------
# CONFIG
# --------------------------------------------------------------------
AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBIAN_REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-debian.git"
DEBIAN_DIR="${AIBA_ROOT}/ungoogled-chromium-debian"
UC_UTILS="${DEBIAN_DIR}/debian/submodules/ungoogled-chromium/utils"

VENV="${AIBA_ROOT}/.venv"

BRANDING_DIR="${AIBA_ROOT}/branding"
PATCHES_DIR="${BRANDING_DIR}/patches"

SCRIPTS_DIR="${AIBA_ROOT}/scripts"

STATE_DIR="${AIBA_ROOT}/.aiba_state"
BUILD_KEY_FILE="${STATE_DIR}/branding.buildkey"
PATCH_STAMP="${STATE_DIR}/patches_applied"

# --------------------------------------------------------------------
# LOGGING / ERROR HANDLING
# --------------------------------------------------------------------
step() {
    echo
    echo "===================================================================="
    echo "==> $*"
    echo "===================================================================="
}

warn() {
    echo "WARNING: $*" >&2
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    echo
    echo "Cleaning temporary state..."
}

trap cleanup EXIT
trap 'echo "Build failed at line $LINENO" >&2' ERR

# --------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------
require_file() {
    [[ -f "$1" ]] || fail "Required file missing: $1"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 \
        || fail "Missing required command: $1"
}

hash_inputs() {
    {
        git -C "$DEBIAN_DIR" rev-parse HEAD 2>/dev/null || true

        find "$BRANDING_DIR" "$SCRIPTS_DIR" \
            -type f \
            \( \
                -name '*.py' \
                -o -name '*.sh' \
                -o -name '*.patch' \
                -o -name 'series' \
            \) \
            -print0 2>/dev/null \
        | LC_ALL=C sort -z \
        | xargs -0 sha256sum 2>/dev/null || true

    } | sha256sum | awk '{print $1}'
}

# --------------------------------------------------------------------
# CHECK REQUIRED PROJECT FILES
# --------------------------------------------------------------------
step "Checking required Aiba project files"

require_file "${BRANDING_DIR}/setup_aiba.py"
require_file "${SCRIPTS_DIR}/install_ublock_default_app.sh"
require_file "${SCRIPTS_DIR}/apply_debian_prefs.py"

# --------------------------------------------------------------------
# INSTALL SYSTEM PACKAGES
# --------------------------------------------------------------------
step "Installing system packages"

sudo apt-get update -y

sudo apt-get install -y \
    build-essential \
    devscripts \
    equivs \
    ccache \
    git \
    curl \
    patch \
    python3 \
    python3-venv \
    python3-pip \
    unzip \
    ca-certificates \
    gnupg \
    lsb-release \
    pkg-config

# --------------------------------------------------------------------
# VERIFY REQUIRED COMMANDS
# --------------------------------------------------------------------
step "Verifying required commands"

for cmd in \
    git \
    curl \
    patch \
    python3 \
    dpkg-buildpackage \
    mk-build-deps \
    equivs-build \
    apt-get \
    ccache \
    sha256sum \
    pkg-config
do
    require_cmd "$cmd"
done

# --------------------------------------------------------------------
# ENABLE SWAP FOR CLOUD RUNNERS
# --------------------------------------------------------------------
step "Configuring swap memory"

if ! swapon --show | grep -q '/swapfile'; then

    sudo fallocate -l 8G /swapfile \
        || sudo dd if=/dev/zero of=/swapfile bs=1M count=8192

    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
fi

# --------------------------------------------------------------------
# PYTHON VIRTUAL ENVIRONMENT
# --------------------------------------------------------------------
step "Preparing Python virtual environment"

if [[ ! -d "$VENV" ]]; then
    python3 -m venv "$VENV"
fi

PYTHON="${VENV}/bin/python3"
PIP="${VENV}/bin/pip"

"$PIP" install --upgrade pip

if [[ -f "${AIBA_ROOT}/requirements.txt" ]]; then
    "$PIP" install -r "${AIBA_ROOT}/requirements.txt"
fi

# --------------------------------------------------------------------
# CCACHE CONFIGURATION
# --------------------------------------------------------------------
step "Configuring compiler cache"

export CCACHE_DIR="$HOME/.cache/ccache"

mkdir -p "$CCACHE_DIR"

export CCACHE_COMPRESS=1
export CCACHE_COMPRESSLEVEL=6

export PATH="/usr/lib/ccache:$PATH"

ccache -M 9G || true
ccache -s || true

# --------------------------------------------------------------------
# CLONE OR UPDATE REPOSITORY
# --------------------------------------------------------------------
step "Preparing ungoogled-chromium-debian repository"

if [[ ! -d "${DEBIAN_DIR}/.git" ]]; then
    git clone "$DEBIAN_REPO_URL" "$DEBIAN_DIR"
else
    git -C "$DEBIAN_DIR" fetch --all --prune
    git -C "$DEBIAN_DIR" pull --ff-only
fi

cd "$DEBIAN_DIR"

require_file "debian/rules"

# --------------------------------------------------------------------
# UPDATE SUBMODULES
# --------------------------------------------------------------------
step "Updating submodules"

git submodule sync --recursive
git submodule update --init --recursive

# --------------------------------------------------------------------
# INSTALL BUILD DEPENDENCIES
# --------------------------------------------------------------------
step "Installing Debian build dependencies"

sudo mk-build-deps \
    --install \
    --remove \
    --tool 'apt-get -y --no-install-recommends' \
    debian/control

# --------------------------------------------------------------------
# SOURCE SETUP
# --------------------------------------------------------------------
step "Preparing ungoogled-chromium source tree"

# Upstream packaging already supports incremental setup safely.
debian/rules setup

export AIBA_CHROMIUM_SRC="${DEBIAN_DIR}"

# --------------------------------------------------------------------
# APPLY PATCHES SAFELY
# --------------------------------------------------------------------
step "Applying branding patches"

mkdir -p "$PATCHES_DIR"
mkdir -p "$STATE_DIR"

touch "${PATCHES_DIR}/series"

if [[ -f "${UC_UTILS}/patches.py" ]] \
   && find "$PATCHES_DIR" -type f -name '*.patch' -print -quit | grep -q .
then

    if [[ ! -f "$PATCH_STAMP" ]]; then

        "$PYTHON" \
            "${UC_UTILS}/patches.py" \
            apply \
            "$DEBIAN_DIR" \
            "$PATCHES_DIR"

        touch "$PATCH_STAMP"

    else
        echo "Patches already applied"
    fi

else
    warn "No branding patches found or ungoogled-chromium utils missing"
fi

# --------------------------------------------------------------------
# BRANDING / CUSTOMIZATION
# --------------------------------------------------------------------
CURRENT_KEY="$(hash_inputs)"
PREVIOUS_KEY="$(cat "$BUILD_KEY_FILE" 2>/dev/null || true)"

if [[ "$CURRENT_KEY" != "$PREVIOUS_KEY" ]]; then

    step "Applying Aiba customizations"

    "$PYTHON" "${BRANDING_DIR}/setup_aiba.py"

    "$PYTHON" \
        "${SCRIPTS_DIR}/apply_debian_prefs.py" \
        "$DEBIAN_DIR"

    "${SCRIPTS_DIR}/install_ublock_default_app.sh" \
        "$DEBIAN_DIR"

    printf '%s\n' "$CURRENT_KEY" > "$BUILD_KEY_FILE"

else

    step "Branding already up-to-date"

fi

# --------------------------------------------------------------------
# BUILD PACKAGE
# --------------------------------------------------------------------
step "Building ungoogled-chromium Debian packages"

# Chromium is RAM-heavy.
# Conservative parallelism prevents OOM crashes in CI.
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-} parallel=2"

export NINJA_SUMMARIZE_BUILD=1

nice -n 19 dpkg-buildpackage -b -uc

# --------------------------------------------------------------------
# CLEANUP
# --------------------------------------------------------------------
step "Cleaning compiler cache"

ccache --cleanup || true

# --------------------------------------------------------------------
# FIND OUTPUT PACKAGES
# --------------------------------------------------------------------
step "Searching for built packages"

DEB_OUT_DIR="$(dirname "$DEBIAN_DIR")"

mapfile -t BUILT_DEBS < <(
    find "$DEB_OUT_DIR" \
        -maxdepth 1 \
        -type f \
        -name 'ungoogled-chromium_*.deb' \
        ! -name '*build-deps*' \
        | sort
)

if (( ${#BUILT_DEBS[@]} == 0 )); then
    fail "No ungoogled-chromium .deb packages were produced"
fi

echo
echo "Generated package(s):"

printf '  %s\n' "${BUILT_DEBS[@]}"

echo
echo "Install with:"
echo "sudo dpkg -i ${BUILT_DEBS[0]}"

echo
echo "Binary path after install:"
echo "/usr/lib/chromium/chrome"

echo
echo "Initial preferences path:"
echo "/usr/lib/chromium/initial_preferences"

echo
step "Build completed successfully"
