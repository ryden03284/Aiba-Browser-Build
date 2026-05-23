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
DEBIAN_BRANCH="${DEBIAN_BRANCH:-unified}"
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

# Directory holding our patch(1) shim — prepended to PATH before any step
# that invokes patches.py so already-applied hunks don't abort the build.
PATCH_WRAPPER_DIR="${STATE_DIR}/patch_shim"

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

# Resolve which branch to use:
#   1. Requested branch exists remotely  → use it
#   2. Remote HEAD is set                → fall back to it automatically
#   3. Neither                           → fail with full branch list
#
# Runs entirely via git ls-remote so no local clone is needed first.
# The resolved name is printed to stdout; callers capture it.
_resolve_branch() {
    local url="$1"
    local requested="$2"

    local remote_info
    # Capture exit code separately; ls-remote can fail on network errors
    if ! remote_info="$(git ls-remote --heads --symref "$url" 2>/dev/null)"; then
        fail "Cannot reach remote: $url"
    fi

    if [[ -z "$remote_info" ]]; then
        fail "git ls-remote returned empty output for: $url"
    fi

    # Strip any trailing whitespace/carriage returns that can corrupt matching
    remote_info="$(echo "$remote_info" | tr -d '\r')"

    # Check whether the requested branch exists
    if echo "$remote_info" | grep -qE $'\trefs/heads/'"${requested}"'$'; then
        info "Branch '${requested}' confirmed on remote"
        printf '%s' "$requested"
        return 0
    fi

    warn "Branch '${requested}' not found on remote"

    # Attempt to read the remote HEAD symbolic ref
    local default_branch
    default_branch="$(
        echo "$remote_info" | awk '
            /^ref: refs\/heads\// {
                sub(/^ref: refs\/heads\//, "")
                print
                exit
            }
        '
    )"

    if [[ -n "$default_branch" ]]; then
        warn "Falling back to remote default branch: '${default_branch}'"
        printf '%s' "$default_branch"
        return 0
    fi

    # Nothing worked — list available branches and bail
    local branch_list
    branch_list="$(
        echo "$remote_info" | awk -F'\t' '
            /\trefs\/heads\// {
                sub(/refs\/heads\//, "", $2)
                print "  " $2
            }
        '
    )"
    fail "Branch '${requested}' not found and remote HEAD is ambiguous.
Available branches:
${branch_list}
Set DEBIAN_BRANCH=<name> and re-run."
}

clone_or_update_repo() {
    step "Preparing ungoogled-chromium-debian repository"

    # Resolve the branch up front — fail with a clear message before
    # touching the filesystem if the branch does not exist.
    local resolved
    resolved="$(_resolve_branch "$DEBIAN_REPO_URL" "$DEBIAN_BRANCH")"
    DEBIAN_BRANCH="$resolved"
    info "Using branch: $DEBIAN_BRANCH"

    # If a partial/broken directory exists but has no .git, wipe it so the
    # clone below does not hit "destination path already exists" errors.
    if [[ -e "$DEBIAN_DIR" && ! -d "${DEBIAN_DIR}/.git" ]]; then
        warn "Found non-git directory at $DEBIAN_DIR — removing before clone"
        rm -rf "$DEBIAN_DIR"
    fi

    if [[ ! -d "${DEBIAN_DIR}/.git" ]]; then
        info "Cloning $DEBIAN_REPO_URL into $DEBIAN_DIR"
        git clone --recurse-submodules --branch "$DEBIAN_BRANCH"             "$DEBIAN_REPO_URL" "$DEBIAN_DIR"
    else
        info "Existing repository found — checking for updates"

        local current_branch current_commit remote_commit
        current_branch="$(git -C "$DEBIAN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        current_commit="$(git -C "$DEBIAN_DIR"  rev-parse HEAD                          2>/dev/null || true)"

        git -C "$DEBIAN_DIR" fetch origin --prune --tags --quiet
        remote_commit="$(git -C "$DEBIAN_DIR" rev-parse "origin/${DEBIAN_BRANCH}" 2>/dev/null || true)"

        if [[ "$current_branch" == "$DEBIAN_BRANCH" && "$current_commit" == "$remote_commit" ]]; then
            # Fully up to date — preserve everything (avoids re-downloading
            # the 30 GB Chromium source tree on subsequent runs).
            info "Already up to date on '$DEBIAN_BRANCH' at $current_commit — skipping reset"
        else
            info "Updating: $current_commit → $remote_commit"
            # reset --hard only touches tracked files.
            # git clean is intentionally omitted so the Chromium source
            # tree and any built .deb files are NOT wiped between runs.
            git -C "$DEBIAN_DIR" checkout "$DEBIAN_BRANCH"
            git -C "$DEBIAN_DIR" reset --hard "origin/${DEBIAN_BRANCH}"
            info "Reset complete — untracked files (source tree, .deb) preserved"
        fi
    fi

    # Allow git to operate regardless of directory owner (common in CI).
    git config --global --add safe.directory "$DEBIAN_DIR" 2>/dev/null || true

    info "Repository ready — branch: $DEBIAN_BRANCH"
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

# ====================================================================
# AUTO-REGENERATION OF MISSING DEBIAN PACKAGING FILES
#
# The ungoogled-chromium-debian "unified" branch (and others) do NOT
# ship debian/rules or debian/control as static files.  They are
# generated by repo-specific tooling that must be discovered and run.
#
# Strategy waterfall for debian/rules
# ─────────────────────────────────────
#   0. Diagnostic: log what IS present so failures are debuggable
#   1. Copy debian/rules.in  (classic template pattern)
#   2. Any generate_rules.{sh,py} anywhere in the repo
#   3. Root-level setup scripts (setup.sh, prepare.sh, init.sh, …)
#   4. make targets: prepare / setup / generate / all
#   5. python3 setup.py (setuptools-style repos)
#   6. dpkg-source --before-build  (some Debian source packages)
#
# Strategy waterfall for debian/control
# ─────────────────────────────────────
#   0. Diagnostic: same
#   1. make -f debian/rules debian/control  (control.in + rules target)
#   2. Named generator scripts (generate_debian_control.{sh,py}, …)
#   3. make targets: setup / prepare / generate
#   4. Broad grep scan for scripts that write "control" output
#   5. Root-level setup/prepare/init scripts (same as rules strategy 3)
#   6. dpkg-source --before-build
# ====================================================================

_log_debian_dir() {
    info "--- debian/ directory listing (for diagnostics) ---"
    if [[ -d "${DEBIAN_DIR}/debian" ]]; then
        find "${DEBIAN_DIR}/debian" -maxdepth 2 | LC_ALL=C sort | while read -r p; do
            info "  $p"
        done
    else
        info "  (debian/ directory does not exist)"
    fi
    info "--- root directory listing ---"
    find "${DEBIAN_DIR}" -maxdepth 1 | LC_ALL=C sort | while read -r p; do
        info "  $p"
    done
    info "--- end of listing ---"
}

# Run a script (*.sh or *.py) inside DEBIAN_DIR, ignoring errors.
# Returns 0 always — callers check whether the target file appeared.
_run_gen_script() {
    local script="$1"
    case "$script" in
        *.py) run_in_dir "$DEBIAN_DIR" "$PYTHON" "$script" 2>/dev/null || true ;;
        *.sh) run_in_dir "$DEBIAN_DIR" bash      "$script" 2>/dev/null || true ;;
        *)    run_in_dir "$DEBIAN_DIR" bash      "$script" 2>/dev/null || true ;;
    esac
}

# Try every root-level setup/prepare/init script we can find.
# Used as a shared last-resort by both _try_regenerate_* functions.
_try_root_setup_scripts() {
    local script
    local -a candidates=()
    mapfile -t candidates < <(
        find "$DEBIAN_DIR" -maxdepth 1 -type f \
            \( -name 'setup.sh'    -o -name 'setup.py'    \
            -o -name 'prepare.sh'  -o -name 'prepare.py'  \
            -o -name 'init.sh'     -o -name 'init.py'     \
            -o -name 'generate.sh' -o -name 'generate.py' \
            -o -name 'bootstrap.sh' \) \
            | LC_ALL=C sort
    )
    for script in "${candidates[@]}"; do
        info "    Running root setup script: $(basename "$script")"
        _run_gen_script "$script"
    done
}

_try_dpkg_source_before_build() {
    if command -v dpkg-source >/dev/null 2>&1; then
        info "    Trying dpkg-source --before-build"
        run_in_dir "$DEBIAN_DIR" dpkg-source --before-build . 2>/dev/null || true
    fi
}

_try_regenerate_rules() {
    local rules="${DEBIAN_DIR}/debian/rules"
    [[ -f "$rules" ]] && return 0

    info "debian/rules is missing — running diagnostic then trying all strategies"
    _log_debian_dir

    # Strategy 1: copy from .in template
    if [[ -f "${DEBIAN_DIR}/debian/rules.in" ]]; then
        info "  [1] Copying debian/rules.in → debian/rules"
        cp -f "${DEBIAN_DIR}/debian/rules.in" "$rules"
        chmod +x "$rules"
        [[ -f "$rules" ]] && { info "  ✓ Strategy 1 succeeded"; return 0; }
    fi

    # Strategy 2: dedicated generator scripts anywhere in repo
    local gen
    local -a gen_scripts=()
    mapfile -t gen_scripts < <(
        find "$DEBIAN_DIR" -maxdepth 4 -type f \
            \( -name 'generate_rules.sh'  -o -name 'generate_rules.py'  \
            -o -name 'make_rules.sh'      -o -name 'make_rules.py'      \) \
            | LC_ALL=C sort
    )
    for gen in "${gen_scripts[@]}"; do
        info "  [2] Running generator: $(basename "$gen")"
        _run_gen_script "$gen"
        [[ -f "$rules" ]] && { info "  ✓ Strategy 2 succeeded via $(basename "$gen")"; return 0; }
    done

    # Strategy 3: root-level setup scripts
    info "  [3] Trying root-level setup/prepare/init scripts"
    _try_root_setup_scripts
    [[ -f "$rules" ]] && { info "  ✓ Strategy 3 (root scripts) succeeded"; return 0; }

    # Strategy 4: make targets against whatever Makefile exists
    local t
    for t in prepare setup generate all; do
        info "  [4] Trying make target: $t"
        run_in_dir "$DEBIAN_DIR" bash -c "
            if [[ -f Makefile ]]; then
                make $t 2>/dev/null || true
            fi
        "
        [[ -f "$rules" ]] && { info "  ✓ Strategy 4 (make $t) succeeded"; return 0; }
    done

    # Strategy 5: python3 setup.py (setuptools-style)
    if [[ -f "${DEBIAN_DIR}/setup.py" ]]; then
        info "  [5] Trying python3 setup.py"
        run_in_dir "$DEBIAN_DIR" "$PYTHON" setup.py 2>/dev/null || true
        [[ -f "$rules" ]] && { info "  ✓ Strategy 5 (setup.py) succeeded"; return 0; }
    fi

    # Strategy 6: dpkg-source --before-build
    info "  [6] Trying dpkg-source --before-build"
    _try_dpkg_source_before_build
    [[ -f "$rules" ]] && { info "  ✓ Strategy 6 (dpkg-source) succeeded"; return 0; }

    warn "All debian/rules regeneration strategies exhausted"
    return 1
}

_try_regenerate_control() {
    local control="${DEBIAN_DIR}/debian/control"
    [[ -f "$control" ]] && return 0

    info "debian/control is missing — trying all strategies"

    # Strategy 1: rules target (needs rules + control.in to exist)
    if [[ -f "${DEBIAN_DIR}/debian/rules" && -f "${DEBIAN_DIR}/debian/control.in" ]]; then
        info "  [1] Running 'debian/rules debian/control'"
        run_rules_target "debian/control" >/dev/null 2>&1 || true
        [[ -f "$control" ]] && { info "  ✓ Strategy 1 succeeded"; return 0; }
    fi

    # Strategy 2: named generator scripts — all of them in sorted order
    local gen
    local -a gen_scripts=()
    mapfile -t gen_scripts < <(
        find "$DEBIAN_DIR" -maxdepth 4 -type f \
            \( -name 'generate_debian_control.sh' -o -name 'generate_debian_control.py' \
            -o -name 'generate_control.sh'        -o -name 'generate_control.py'        \
            -o -name '*control*.py'               -o -name '*control*.sh'               \) \
            | LC_ALL=C sort
    )
    for gen in "${gen_scripts[@]}"; do
        info "  [2] Running generator: $(basename "$gen")"
        _run_gen_script "$gen"
        [[ -f "$control" ]] && { info "  ✓ Strategy 2 succeeded via $(basename "$gen")"; return 0; }
    done

    # Strategy 3: make targets
    local t
    for t in setup prepare generate; do
        info "  [3] Trying rules target: $t"
        run_rules_target "$t" >/dev/null 2>&1 || true
        [[ -f "$control" ]] && { info "  ✓ Strategy 3 (rules $t) succeeded"; return 0; }
    done

    # Strategy 4: broad grep scan — any script under debian/ mentioning "control"
    local -a broad_hits=()
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
        info "  [4] Broad-match: $(basename "$gen")"
        _run_gen_script "$gen"
        [[ -f "$control" ]] && { info "  ✓ Strategy 4 succeeded via $(basename "$gen")"; return 0; }
    done

    # Strategy 5: root-level setup scripts (same as rules strategy 3)
    info "  [5] Trying root-level setup/prepare/init scripts"
    _try_root_setup_scripts
    [[ -f "$control" ]] && { info "  ✓ Strategy 5 (root scripts) succeeded"; return 0; }

    # Strategy 6: make targets directly on the Makefile (not debian/rules)
    for t in setup prepare generate all; do
        info "  [6] Trying make target: $t"
        run_in_dir "$DEBIAN_DIR" bash -c "
            if [[ -f Makefile ]]; then
                make $t 2>/dev/null || true
            fi
        "
        [[ -f "$control" ]] && { info "  ✓ Strategy 6 (make $t) succeeded"; return 0; }
    done

    # Strategy 7: dpkg-source --before-build
    info "  [7] Trying dpkg-source --before-build"
    _try_dpkg_source_before_build
    [[ -f "$control" ]] && { info "  ✓ Strategy 7 (dpkg-source) succeeded"; return 0; }

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

    # The setup target downloads and patches the full Chromium source — ~30 GB
    # and 20-40 minutes on a fresh machine.  Skip it if the source tree is
    # already present and intact so that re-runs after a failed compile do not
    # have to start from scratch.
    #
    # Detection heuristic: the chrome/VERSION file is one of the last things
    # written by the setup target, so its presence is a reliable proxy for a
    # complete, successfully patched source tree.
    local version_file="${DEBIAN_DIR}/chrome/VERSION"

    if [[ -f "$version_file" ]]; then
        local src_ver
        src_ver="$(awk -F= 'BEGIN{M=m=b=p=""} /^MAJOR/{M=$2} /^MINOR/{m=$2} /^BUILD/{b=$2} /^PATCH/{p=$2} END{print M"."m"."b"."p}' "$version_file")"
        info "Chromium source tree already present (version $src_ver) — skipping setup"
    else
        info "Chromium source tree not found — running setup (this will take a while)"
        run_rules_target setup
    fi

    export AIBA_CHROMIUM_SRC="${DEBIAN_DIR}"
}

# --------------------------------------------------------------------
# BRANDING PATCHES
# --------------------------------------------------------------------
ensure_patch_series() {
    ensure_dir "$PATCHES_DIR"
    [[ -f "${PATCHES_DIR}/series" ]] || : > "${PATCHES_DIR}/series"
}

# --------------------------------------------------------------------
# PATCH SHIM
#
# patches.py calls:
#   patch -p1 --ignore-whitespace -i <file> -d <dir> --no-backup-if-mismatch --forward
# with Python's subprocess.run(check=True).
#
# The problem: patch(1) exits 1 even when --forward causes it to merely
# *skip* already-applied hunks — it does not distinguish "clean skip"
# from "real failure".  When the Chromium source tree already has the
# ungoogled patches applied (e.g. a resumed build), every patch invocation
# exits 1 and the whole build aborts.
#
# Fix: install a thin wrapper at the front of PATH that runs the real patch,
# inspects stderr/stdout, and exits 0 when every non-zero exit is explained
# entirely by "Reversed (or previously applied)" skips.  Any genuine failure
# (failed hunks, missing files, malformed patches) still propagates exit 1.
# --------------------------------------------------------------------
install_patch_shim() {
    ensure_dir "$PATCH_WRAPPER_DIR"

    cat > "${PATCH_WRAPPER_DIR}/patch" << 'SHIM'
#!/usr/bin/env bash
# Thin wrapper around /usr/bin/patch that turns "already applied" exits
# into success so that patches.py does not abort on resumed builds.

REAL_PATCH="$(command -v patch || true)"
# Walk PATH entries to find the real patch binary, skipping ourselves.
for _dir in $(echo "$PATH" | tr ':' '
'); do
    [[ "$_dir" == "$(dirname "$(readlink -f "$0")")" ]] && continue
    if [[ -x "$_dir/patch" ]]; then
        REAL_PATCH="$_dir/patch"
        break
    fi
done

[[ -x "$REAL_PATCH" ]] || { echo "patch shim: real patch not found" >&2; exit 1; }

# Capture combined output; we need it for analysis AND want it on screen.
TMPOUT="$(mktemp)"
trap 'rm -f "$TMPOUT"' EXIT

"$REAL_PATCH" "$@" 2>&1 | tee "$TMPOUT"
RC="${PIPESTATUS[0]}"

if (( RC == 0 )); then
    exit 0
fi

# Non-zero exit — check whether EVERY ignored/skipped hunk is explained
# by "already applied" language.  If any line looks like a genuine failure
# (failed hunks, can't find file, malformed patch), propagate the error.
if grep -qE     'FAILED|can'''t find file|can'''t open|malformed|No such file|rejects'     "$TMPOUT"; then
    exit "$RC"
fi

if grep -qE     'Reversed \(or previously applied\)|already applied|Skipping patch'     "$TMPOUT"; then
    # Every failure was an already-applied hunk — treat as success.
    exit 0
fi

# Unknown non-zero — propagate to be safe.
exit "$RC"
SHIM

    chmod +x "${PATCH_WRAPPER_DIR}/patch"

    # Prepend shim dir to PATH for this process and all children.
    export PATH="${PATCH_WRAPPER_DIR}:${PATH}"
    info "Patch shim installed (already-applied hunks will no longer abort the build)"
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
    install_patch_shim
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
