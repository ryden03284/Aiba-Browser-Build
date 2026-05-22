#!/usr/bin/env bash
# ====================================================================
# Aiba Browser Build Script
# Hardened CI/CD build pipeline for ungoogled-chromium Debian packaging
# ====================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 022
shopt -s nullglob

# --------------------------------------------------------------------
# CONFIG
# --------------------------------------------------------------------
AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEBIAN_REPO_URL="${DEBIAN_REPO_URL:-https://github.com/ungoogled-software/ungoogled-chromium-debian.git}"
DEBIAN_BRANCH="${DEBIAN_BRANCH:-master}"
DEBIAN_DIR="${DEBIAN_DIR:-${AIBA_ROOT}/ungoogled-chromium-debian}"
UC_UTILS="${DEBIAN_DIR}/debian/submodules/ungoogled-chromium/utils"

BRANDING_DIR="${BRANDING_DIR:-${AIBA_ROOT}/branding}"
PATCHES_DIR="${PATCHES_DIR:-${BRANDING_DIR}/patches}"
SCRIPTS_DIR="${SCRIPTS_DIR:-${AIBA_ROOT}/scripts}"

STATE_DIR="${STATE_DIR:-${AIBA_ROOT}/.aiba_state}"
LOG_FILE="${LOG_FILE:-${STATE_DIR}/build.log}"
BUILD_KEY_FILE="${BUILD_KEY_FILE:-${STATE_DIR}/branding.buildkey}"
PATCH_STAMP="${PATCH_STAMP:-${STATE_DIR}/patches.stamp}"

VENV="${VENV:-${AIBA_ROOT}/.venv}"
PYTHON="${VENV}/bin/python3"
PIP="${VENV}/bin/pip"

BUILD_JOBS="${BUILD_JOBS:-2}"
CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-9G}"
ENABLE_SWAP="${ENABLE_SWAP:-1}"
SWAP_SIZE="${SWAP_SIZE:-8G}"

# Global array populated by find_built_packages.
# Declared here so it lives in the top-level scope, not inside a function.
declare -a BUILT_DEBS=()

# --------------------------------------------------------------------
# LOGGING
# --------------------------------------------------------------------
_ts() { date '+%H:%M:%S'; }

step() {
    echo
    echo "===================================================================="
    echo "==> [$(_ts)] $*"
    echo "===================================================================="
}

info() { echo "    [$(_ts)] $*"; }
warn() { echo "    [$(_ts)] WARNING: $*" >&2; }
fail() { echo "    [$(_ts)] ERROR: $*" >&2; exit 1; }

# --------------------------------------------------------------------
# CLEANUP / ERROR HANDLING
# --------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR:-}" ]]; then
        rm -rf "$TMP_DIR"
    fi
    # Give the tee background process time to flush before the shell exits.
    wait 2>/dev/null || true
    return "$rc"
}

on_err() {
    # bash preserves $? when entering an ERR trap — capture it immediately.
    local exit_code=$?
    local line="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"
    echo "    [$(_ts)] ERROR: build failed at line ${line}: ${cmd}" >&2
    exit "$exit_code"
}

mkdir -p "$STATE_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

trap cleanup EXIT
trap on_err ERR

# --------------------------------------------------------------------
# ROOT / SUDO
# --------------------------------------------------------------------
# SUDO_CMD is empty when already root, set to (sudo) otherwise.
# The dead 'require_sudo=1' variable from the original has been removed —
# it was set but never read anywhere.
SUDO_CMD=()
if (( EUID != 0 )); then
    if command -v sudo >/dev/null 2>&1; then
        SUDO_CMD=(sudo)
    else
        fail "sudo is required when not running as root"
    fi
fi

run_root() {
    if (( ${#SUDO_CMD[@]} > 0 )); then
        "${SUDO_CMD[@]}" "$@"
    else
        "$@"
    fi
}

# --------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
    [[ -e "$1" ]] || fail "Required file missing: $1"
}

require_executable() {
    [[ -x "$1" ]] || fail "Required executable missing or not executable: $1"
}

ensure_dir() {
    mkdir -p "$1"
}

# Run a command inside a specific directory using a subshell.
# This replaces all pushd/popd usage and avoids directory-stack corruption
# when a command inside the block fails under set -e.
run_in_dir() {
    local dir="$1"; shift
    ( cd "$dir" && "$@" )
}

# Run a debian/rules make target inside DEBIAN_DIR.
run_rules_target() {
    local target="$1"
    run_in_dir "$DEBIAN_DIR" bash -c '
        target="$1"
        if [[ -x "./debian/rules" ]]; then
            ./debian/rules "$target"
        else
            make -f debian/rules "$target"
        fi
    ' _ "$target"
}

# Hash all regular files under <dir> that match the given find predicates.
# Separating the directory from predicates makes callers clearer and avoids
# the fragile "pass everything through $@" interface of the original.
#
# Usage: hash_file_list <dir> [find-predicates...]
hash_file_list() {
    local dir="$1"; shift
    local file
    while IFS= read -r -d '' file; do
        sha256sum "$file"
    done < <(
        find "$dir" -type f "$@" -print0 2>/dev/null | LC_ALL=C sort -z
    )
}

hash_inputs() {
    {
        if [[ -d "$DEBIAN_DIR/.git" ]]; then
            git -C "$DEBIAN_DIR" rev-parse HEAD 2>/dev/null || true
            git -C "$DEBIAN_DIR" submodule status --recursive 2>/dev/null || true
        fi

        [[ -f "${DEBIAN_DIR}/debian/control" ]]    && sha256sum "${DEBIAN_DIR}/debian/control"
        [[ -f "${DEBIAN_DIR}/debian/rules" ]]      && sha256sum "${DEBIAN_DIR}/debian/rules"
        [[ -f "${DEBIAN_DIR}/debian/control.in" ]] && sha256sum "${DEBIAN_DIR}/debian/control.in"

        [[ -d "$BRANDING_DIR" ]] && hash_file_list "$BRANDING_DIR" \
            \( -name '*.py' -o -name '*.sh' -o -name '*.patch' -o -name 'series' \)

        [[ -d "$SCRIPTS_DIR" ]] && hash_file_list "$SCRIPTS_DIR" \
            \( -name '*.py' -o -name '*.sh' -o -name '*.patch' -o -name 'series' \)

        [[ -d "$PATCHES_DIR" ]] && hash_file_list "$PATCHES_DIR" \
            \( -name '*.patch' -o -name 'series' \)
    } | sha256sum | awk '{print $1}'
}

# Convert a human-readable size (8G, 512M, 4096) to mebibytes.
# Used to derive the correct dd count= when fallocate is unavailable.
size_to_mib() {
    local raw="${1:-0}"
    case "${raw^^}" in
        *G) echo $(( ${raw%[Gg]} * 1024 )) ;;
        *M) echo $(( ${raw%[Mm]} ))         ;;
        *)  echo $(( raw ))                 ;;
    esac
}

# --------------------------------------------------------------------
# APT SOURCE CONFIGURATION
# --------------------------------------------------------------------
enable_deb_src() {
    step "Configuring APT sources for source packages"

    if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
        # DEB822 format (Ubuntu 24.04+)
        if ! grep -qE '^Types:.*\bdeb-src\b' /etc/apt/sources.list.d/ubuntu.sources; then
            info "Adding deb-src to ubuntu.sources (DEB822 format)"
            run_root sed -Ei \
                's/^Types:[[:space:]]*deb$/Types: deb deb-src/' \
                /etc/apt/sources.list.d/ubuntu.sources
        else
            info "deb-src already present in ubuntu.sources"
        fi
    else
        # Classic one-line format.
        #
        # FIX: the original sed was 'p;s/…/…/' — the bare 'p' had no address,
        # so it duplicated EVERY line, not just deb lines.  The fix wraps both
        # commands in an address block '/^deb /{…}' so they only fire on
        # matching lines.  Note: 'deb-src' lines do NOT match '^deb[[:space:]]'
        # because the character after 'deb' is '-', not a space — so existing
        # deb-src lines are never accidentally doubled.
        local f
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
            [[ -f "$f" ]] || continue
            if grep -qE '^[[:space:]]*deb-src[[:space:]]' "$f"; then
                info "deb-src already present in $f"
                continue
            fi
            info "Adding deb-src lines to $f"
            run_root sed -i \
                '/^[[:space:]]*deb[[:space:]]/{p;s/^[[:space:]]*deb[[:space:]]/deb-src /}' \
                "$f"
        done
    fi
}

# --------------------------------------------------------------------
# SYSTEM PACKAGES
# --------------------------------------------------------------------
install_system_packages() {
    step "Installing system packages"

    export DEBIAN_FRONTEND=noninteractive

    local packages=(
        build-essential
        ca-certificates
        ccache
        curl
        devscripts
        equivs
        fakeroot
        git
        gnupg
        lsb-release
        patch
        pkg-config
        python3
        python3-pip
        python3-venv
        rsync
        unzip
        xz-utils
        dpkg-dev
    )

    run_root apt-get update -qq
    run_root apt-get install -y --no-install-recommends "${packages[@]}"
}

# --------------------------------------------------------------------
# COMMAND VERIFICATION
# Report ALL missing commands in one pass instead of stopping at the first.
# --------------------------------------------------------------------
verify_required_commands() {
    step "Verifying required commands"

    local cmds=(
        git curl patch python3
        dpkg-buildpackage mk-build-deps equivs-build
        apt-get ccache sha256sum pkg-config
        find awk sort
    )

    local cmd missing=0
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            warn "Missing required command: $cmd"
            (( missing++ )) || true
        fi
    done

    (( missing == 0 )) || fail "$missing required command(s) not found — install them and retry"
}

# --------------------------------------------------------------------
# SWAP
# --------------------------------------------------------------------
configure_swap() {
    step "Configuring swap memory"

    if [[ "$ENABLE_SWAP" != "1" ]]; then
        warn "Swap setup disabled by ENABLE_SWAP=0"
        return 0
    fi

    if ! command -v swapon >/dev/null 2>&1; then
        warn "swapon not available; skipping swap setup"
        return 0
    fi

    if swapon --show 2>/dev/null | awk '{print $1}' | grep -qx '/swapfile'; then
        info "Swapfile already active"
        return 0
    fi

    if [[ -e /swapfile ]]; then
        warn "/swapfile exists but is not active; attempting to enable it"
        run_root chmod 600 /swapfile
        run_root mkswap /swapfile
        run_root swapon /swapfile || warn "Could not enable existing /swapfile"
        return 0
    fi

    # Derive MiB count from SWAP_SIZE so dd always matches fallocate's intent.
    # The original hardcoded count=8192 (8 GiB) regardless of SWAP_SIZE.
    local swap_mib
    swap_mib="$(size_to_mib "$SWAP_SIZE")"
    info "Allocating ${SWAP_SIZE} swapfile"

    if ! run_root fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
        info "fallocate unavailable; falling back to dd (${swap_mib} MiB)"
        run_root dd if=/dev/zero of=/swapfile bs=1M count="$swap_mib" status=none
    fi

    run_root chmod 600 /swapfile
    run_root mkswap /swapfile
    run_root swapon /swapfile || warn "Swap enable failed; continuing without swap"
}

# --------------------------------------------------------------------
# PYTHON VENV
# --------------------------------------------------------------------
prepare_venv() {
    step "Preparing Python virtual environment"

    if [[ ! -d "$VENV" ]]; then
        python3 -m venv "$VENV"
    fi

    "$PYTHON" -m pip install --quiet --upgrade pip setuptools wheel

    local req
    for req in "${AIBA_ROOT}/requirements.txt" "${SCRIPTS_DIR}/requirements.txt"; do
        if [[ -f "$req" ]]; then
            info "Installing requirements: $req"
            "$PIP" install --quiet -r "$req"
        fi
    done
}

# --------------------------------------------------------------------
# CCACHE
# --------------------------------------------------------------------
configure_ccache() {
    step "Configuring compiler cache"

    export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
    export CCACHE_COMPRESS="${CCACHE_COMPRESS:-1}"
    export CCACHE_COMPRESSLEVEL="${CCACHE_COMPRESSLEVEL:-6}"
    export PATH="/usr/lib/ccache:$PATH"

    ensure_dir "$CCACHE_DIR"
    ccache -M "$CCACHE_MAXSIZE" || true
    ccache -s || true
}

# --------------------------------------------------------------------
# REPOSITORY
# --------------------------------------------------------------------
clone_or_update_repo() {
    step "Preparing ungoogled-chromium-debian repository"

    if [[ ! -d "${DEBIAN_DIR}/.git" ]]; then
        info "Cloning $DEBIAN_REPO_URL (branch: $DEBIAN_BRANCH)"
        git clone --recurse-submodules --branch "$DEBIAN_BRANCH" \
            "$DEBIAN_REPO_URL" "$DEBIAN_DIR"
    else
        info "Updating existing repository"
        git -C "$DEBIAN_DIR" fetch origin --prune --tags
        git -C "$DEBIAN_DIR" checkout "$DEBIAN_BRANCH"
        git -C "$DEBIAN_DIR" reset --hard "origin/${DEBIAN_BRANCH}"
        git -C "$DEBIAN_DIR" clean -xfd
    fi

    # Allow git to operate on this directory regardless of owner (common in CI).
    git config --global --add safe.directory "$DEBIAN_DIR" 2>/dev/null || true
}

update_submodules() {
    step "Updating submodules"

    git -C "$DEBIAN_DIR" submodule sync --recursive
    git -C "$DEBIAN_DIR" submodule update --init --recursive
}

# ====================================================================
# AUTO-REGENERATION OF MISSING DEBIAN PACKAGING FILES
#
# Each private helper (_try_regenerate_rules / _try_regenerate_control)
# works through an ordered list of strategies and returns 0 the moment
# one succeeds, or 1 if every strategy fails.
#
# Strategy order for debian/rules
# ─────────────────────────────────
#   1. Copy debian/rules.in  (most common upstream pattern)
#   2. Search repo for any generate_rules.sh / generate_rules.py
#   3. Run 'debian/rules prepare' or 'debian/rules setup' make targets
#      (some repos emit rules as a side-effect of these targets)
#
# Strategy order for debian/control
# ─────────────────────────────────
#   1. 'make -f debian/rules debian/control'  (has control.in → rules target)
#   2. Known generator scripts in any order:
#        generate_debian_control.sh, generate_control.sh, *control*.py
#   3. 'debian/rules setup' / 'prepare' / 'generate' targets
#   4. Broad scan: any script under debian/ whose source mentions "control"
# ====================================================================

_try_regenerate_rules() {
    local rules="${DEBIAN_DIR}/debian/rules"
    [[ -f "$rules" ]] && return 0   # nothing to do

    info "debian/rules is missing — trying regeneration strategies"

    # Strategy 1: copy from .in template
    if [[ -f "${DEBIAN_DIR}/debian/rules.in" ]]; then
        info "  [strategy 1] Copying debian/rules.in → debian/rules"
        cp -f "${DEBIAN_DIR}/debian/rules.in" "$rules"
        chmod +x "$rules"
        if [[ -f "$rules" ]]; then
            info "  ✓ debian/rules restored from .in template"
            return 0
        fi
    fi

    # Strategy 2: dedicated generator script anywhere in the repo
    local gen
    gen="$(
        find "$DEBIAN_DIR" -maxdepth 4 -type f \
            \( -name 'generate_rules.sh'  \
            -o -name 'generate_rules.py'  \
            -o -name 'make_rules.sh'      \
            -o -name 'make_rules.py'      \) \
            | LC_ALL=C sort | head -n 1 || true
    )"

    if [[ -n "$gen" ]]; then
        info "  [strategy 2] Running generator: $gen"
        case "$gen" in
            *.py) run_in_dir "$DEBIAN_DIR" "$PYTHON" "$gen" 2>/dev/null || true ;;
            *.sh) run_in_dir "$DEBIAN_DIR" bash      "$gen" 2>/dev/null || true ;;
        esac
        if [[ -f "$rules" ]]; then
            info "  ✓ debian/rules produced by generator script"
            return 0
        fi
    fi

    # Strategy 3: make targets that sometimes emit rules as a side-effect
    local t
    for t in prepare setup generate; do
        info "  [strategy 3] Trying rules target: $t"
        if run_rules_target "$t" >/dev/null 2>&1; then
            if [[ -f "$rules" ]]; then
                info "  ✓ debian/rules produced by '$t' target"
                return 0
            fi
        fi
    done

    warn "All debian/rules regeneration strategies exhausted"
    return 1
}

_try_regenerate_control() {
    local control="${DEBIAN_DIR}/debian/control"
    [[ -f "$control" ]] && return 0   # nothing to do

    info "debian/control is missing — trying regeneration strategies"

    # Strategy 1: dedicated rules target (requires control.in to exist upstream)
    if [[ -f "${DEBIAN_DIR}/debian/control.in" ]]; then
        info "  [strategy 1] Running 'debian/rules debian/control' (control.in found)"
        if run_rules_target "debian/control" >/dev/null 2>&1; then
            if [[ -f "$control" ]]; then
                info "  ✓ debian/control built by rules target"
                return 0
            fi
        fi
    fi

    # Strategy 2: known generator scripts — try ALL of them in sorted order
    local gen_scripts=()
    mapfile -t gen_scripts < <(
        find "$DEBIAN_DIR" -maxdepth 4 -type f \
            \( -name 'generate_debian_control.sh' \
            -o -name 'generate_debian_control.py' \
            -o -name 'generate_control.sh'        \
            -o -name 'generate_control.py'        \
            -o -name '*control*.py'               \
            -o -name '*control*.sh'               \) \
            | LC_ALL=C sort
    )

    local gen
    for gen in "${gen_scripts[@]}"; do
        info "  [strategy 2] Running generator: $gen"
        case "$gen" in
            *.py) run_in_dir "$DEBIAN_DIR" "$PYTHON" "$gen" 2>/dev/null || true ;;
            *.sh) run_in_dir "$DEBIAN_DIR" bash      "$gen" 2>/dev/null || true ;;
        esac
        if [[ -f "$control" ]]; then
            info "  ✓ debian/control produced by $gen"
            return 0
        fi
    done

    # Strategy 3: make targets — 'setup' / 'prepare' / 'generate'
    local t
    for t in setup prepare generate; do
        info "  [strategy 3] Trying rules target: $t"
        if run_rules_target "$t" >/dev/null 2>&1; then
            if [[ -f "$control" ]]; then
                info "  ✓ debian/control produced by '$t' target"
                return 0
            fi
        fi
    done

    # Strategy 4: broad scan — any script under debian/ that mentions "control"
    # in its source.  Sorted for determinism; each is tried independently.
    local broad_hits=()
    mapfile -t broad_hits < <(
        find "${DEBIAN_DIR}/debian" -maxdepth 3 -type f \
            \( -name '*.py' -o -name '*.sh' \) \
            | xargs grep -l \
                -e 'debian/control' \
                -e 'write.*control'  \
                -e 'control.*write'  \
                2>/dev/null \
            | LC_ALL=C sort \
        || true
    )

    for gen in "${broad_hits[@]}"; do
        info "  [strategy 4] Broad-match generator: $gen"
        case "$gen" in
            *.py) run_in_dir "$DEBIAN_DIR" "$PYTHON" "$gen" 2>/dev/null || true ;;
            *.sh) run_in_dir "$DEBIAN_DIR" bash      "$gen" 2>/dev/null || true ;;
        esac
        if [[ -f "$control" ]]; then
            info "  ✓ debian/control produced by broad-match: $gen"
            return 0
        fi
    done

    warn "All debian/control regeneration strategies exhausted"
    return 1
}

regenerate_missing_packaging_files() {
    step "Checking and regenerating Debian packaging files"

    local all_ok=1

    # Regenerate rules first; control generation may depend on it.
    if ! _try_regenerate_rules; then
        all_ok=0
    fi

    # Ensure rules is always executable after any regeneration attempt.
    if [[ -f "${DEBIAN_DIR}/debian/rules" ]]; then
        chmod +x "${DEBIAN_DIR}/debian/rules"
    fi

    if ! _try_regenerate_control; then
        all_ok=0
    fi

    # Hard failure if either file is still absent after all strategies.
    [[ -f "${DEBIAN_DIR}/debian/rules" ]] \
        || fail "debian/rules is missing and could not be regenerated by any strategy"
    [[ -f "${DEBIAN_DIR}/debian/control" ]] \
        || fail "debian/control is missing and could not be regenerated by any strategy"

    if (( all_ok == 1 )); then
        info "All required Debian packaging files are present"
    fi
}

# --------------------------------------------------------------------
# BUILD DEPENDENCIES
# FIX: the original used bare 'sudo' instead of run_root, which breaks
# when the script is already running as root (no sudo available/needed).
# --------------------------------------------------------------------
prepare_build_deps() {
    step "Installing Debian build dependencies"

    run_root mk-build-deps \
        --install \
        --remove \
        --tool 'apt-get -y --no-install-recommends' \
        "${DEBIAN_DIR}/debian/control"
}

# --------------------------------------------------------------------
# SOURCE SETUP
# FIX: export of AIBA_CHROMIUM_SRC was previously inside a pushd/popd
# block, making it look like the export depended on the directory change.
# It does not — the value is just $DEBIAN_DIR, always known.  Moving it
# out of the subshell also ensures the export actually reaches the caller.
# --------------------------------------------------------------------
run_source_setup() {
    step "Preparing ungoogled-chromium source tree"

    run_rules_target setup
    export AIBA_CHROMIUM_SRC="${DEBIAN_DIR}"
}

# --------------------------------------------------------------------
# BRANDING PATCHES
# --------------------------------------------------------------------
ensure_patch_series() {
    ensure_dir "$PATCHES_DIR"
    [[ -f "${PATCHES_DIR}/series" ]] || : > "${PATCHES_DIR}/series"
}

apply_branding_patches() {
    step "Applying branding patches"

    ensure_dir "$PATCHES_DIR"
    ensure_dir "$STATE_DIR"
    ensure_patch_series

    if [[ ! -f "${UC_UTILS}/patches.py" ]]; then
        warn "ungoogled-chromium patch utility not found: ${UC_UTILS}/patches.py"
        return 0
    fi

    if ! find "$PATCHES_DIR" -type f -name '*.patch' -print -quit | grep -q .; then
        info "No branding patches to apply"
        return 0
    fi

    local patch_hash previous_hash
    patch_hash="$(
        {
            sha256sum "${PATCHES_DIR}/series" 2>/dev/null || true
            hash_file_list "$PATCHES_DIR" -name '*.patch'
        } | sha256sum | awk '{print $1}'
    )"
    previous_hash="$(cat "$PATCH_STAMP" 2>/dev/null || true)"

    if [[ "$patch_hash" == "$previous_hash" ]]; then
        info "Patch set already applied for this exact state"
        return 0
    fi

    "$PYTHON" "${UC_UTILS}/patches.py" apply "$DEBIAN_DIR" "$PATCHES_DIR"
    printf '%s\n' "$patch_hash" > "$PATCH_STAMP"
}

# --------------------------------------------------------------------
# BRANDING CUSTOMIZATIONS
# --------------------------------------------------------------------
apply_branding_customizations() {
    step "Applying Aiba customizations"

    require_file "${BRANDING_DIR}/setup_aiba.py"
    require_file "${SCRIPTS_DIR}/apply_debian_prefs.py"
    require_file "${SCRIPTS_DIR}/install_ublock_default_app.sh"

    "$PYTHON" "${BRANDING_DIR}/setup_aiba.py"
    "$PYTHON" "${SCRIPTS_DIR}/apply_debian_prefs.py" "$DEBIAN_DIR"
    bash "${SCRIPTS_DIR}/install_ublock_default_app.sh" "$DEBIAN_DIR"
}

apply_branding_if_needed() {
    local current_key previous_key needs_branding=0

    current_key="$(hash_inputs)"
    previous_key="$(cat "$BUILD_KEY_FILE" 2>/dev/null || true)"

    if [[ "$current_key" != "$previous_key" ]]; then
        info "Build inputs changed — branding will be re-applied"
        needs_branding=1
    fi

    if [[ ! -f "${DEBIAN_DIR}/debian/control" || ! -f "${DEBIAN_DIR}/debian/rules" ]]; then
        info "Packaging files missing — forcing branding re-apply"
        needs_branding=1
    fi

    if (( needs_branding == 1 )); then
        apply_branding_customizations
        printf '%s\n' "$current_key" > "$BUILD_KEY_FILE"
    else
        step "Branding already up to date"
    fi
}

# --------------------------------------------------------------------
# PACKAGE BUILD
# --------------------------------------------------------------------
build_package() {
    step "Building ungoogled-chromium Debian packages"

    export NINJA_SUMMARIZE_BUILD=1

    if [[ "${DEB_BUILD_OPTIONS:-}" == *parallel=* ]]; then
        : # caller already set parallel=; don't override
    elif [[ -n "${DEB_BUILD_OPTIONS:-}" ]]; then
        export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS} parallel=${BUILD_JOBS}"
    else
        export DEB_BUILD_OPTIONS="parallel=${BUILD_JOBS}"
    fi

    run_in_dir "$DEBIAN_DIR" \
        nice -n 19 dpkg-buildpackage -b -us -uc -j"${BUILD_JOBS}"
}

# --------------------------------------------------------------------
# POST-BUILD
# --------------------------------------------------------------------
cleanup_ccache() {
    step "Cleaning compiler cache"
    ccache --cleanup || true
}

find_built_packages() {
    step "Searching for built packages"

    local deb_out_dir
    deb_out_dir="$(dirname "$DEBIAN_DIR")"

    mapfile -t BUILT_DEBS < <(
        find "$deb_out_dir" \
            -maxdepth 1 -type f \
            -name 'ungoogled-chromium_*.deb' \
            ! -name '*build-deps*' \
            | LC_ALL=C sort
    )

    if (( ${#BUILT_DEBS[@]} == 0 )); then
        fail "No ungoogled-chromium .deb packages were produced"
    fi

    echo
    echo "Generated package(s):"
    printf '  %s\n' "${BUILT_DEBS[@]}"

    echo
    echo "Install with:"
    printf '  sudo dpkg -i %s\n' "${BUILT_DEBS[0]}"

    echo
    echo "Binary path after install:    /usr/lib/chromium/chrome"
    echo "Initial preferences path:     /usr/lib/chromium/initial_preferences"
}

# --------------------------------------------------------------------
# MAIN
# --------------------------------------------------------------------
main() {
    step "Aiba Browser Build — $(date '+%Y-%m-%d %H:%M:%S')"

    step "Checking required Aiba project files"
    require_file "${BRANDING_DIR}/setup_aiba.py"
    require_file "${SCRIPTS_DIR}/install_ublock_default_app.sh"
    require_file "${SCRIPTS_DIR}/apply_debian_prefs.py"

    enable_deb_src
    install_system_packages
    verify_required_commands
    configure_swap
    prepare_venv
    configure_ccache
    clone_or_update_repo
    update_submodules
    regenerate_missing_packaging_files
    prepare_build_deps
    run_source_setup
    apply_branding_patches
    apply_branding_if_needed
    build_package
    cleanup_ccache
    find_built_packages

    echo
    step "Build completed successfully — $(date '+%Y-%m-%d %H:%M:%S')"
}

main "$@"
