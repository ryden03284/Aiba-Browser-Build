#!/usr/bin/env bash
#
# build_ungoogled_chromium.sh  —  "Aiba" automated build  (v3 — production)
#
# Builds ungoogled-chromium-debian with:
#   • Patch excision of known-conflicting upstream patches before setup
#   • Adaptive source-root detection
#   • uBlock Origin Lite pre-bundling
#   • Custom "Aiba" branding & icon asset pipeline
#   • Path-safe Debian package control renaming (3-pass placeholder)
#   • GN compiler optimizations patched directly into debian/rules
#   • OOM memory guard with dual PIPESTATUS capture
#
# Usage:  chmod +x build_ungoogled_chromium.sh && ./build_ungoogled_chromium.sh
#

set -euo pipefail
IFS=$'\n\t'

# ─── Capture original script arguments for fail() re-exec ────────────────────
# $@ inside fail() refers to fail()'s own args, NOT the script's args.
# We must snapshot them here at the top level.
SCRIPT_ARGS=("$@")

# ─── Global Logging ──────────────────────────────────────────────────────────
LOG_FILE="$(pwd)/aiba_build_debug.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ─── Retry Guard ─────────────────────────────────────────────────────────────
AIBA_RETRY_COUNT="${AIBA_RETRY_COUNT:-0}"
AIBA_MAX_RETRIES=2
export AIBA_RETRY_COUNT

# ─── Configuration ───────────────────────────────────────────────────────────
REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-debian.git"
REPO_DIR="ungoogled-chromium-debian"
SENTINEL="chrome/app/chromium_strings.grd"

UBLOCK_EXT_ID="ddkjiahejlhfcafbddmgiahcphecmpfh"
UBLOCK_CRX_URL="https://clients2.google.com/service/update2/crx?response=redirect&os=linux&arch=x64&os_arch=x86_64&nacl_arch=x86-64&prod=chromiumcrx&prodchannel=unknown&prodversion=130.0.6723.116&acceptformat=crx2,crx3&x=id%3D${UBLOCK_EXT_ID}%26uc"

BRAND_OLD="ungoogled-chromium"
BRAND_NEW="aiba"
BRAND_DISPLAY_NEW="Aiba"

AIBA_LOGO_PNG="${GITHUB_WORKSPACE:-$(pwd)}/aiba_logo.png"
ICON_SIZES=(16 24 32 48 64 128 256)

# Known-conflicting upstream patches to excise before debian/rules setup.
# These cause fatal subprocess.CalledProcessError via patches.py apply.
EXCISE_PATCHES=(
    "core/inox-patchset/0001-fix-building-without-safebrowsing.patch"
)

# Resolved after Step 4
CHROMIUM_SRC_DIR=""
REPO_ROOT=""

# ─── Helpers ─────────────────────────────────────────────────────────────────
step() {
    echo ""
    echo "══════════════════════════════════════════════════════════════"
    echo "  STEP $1: $2"
    echo "══════════════════════════════════════════════════════════════"
    echo ""
}

fail() {
    local msg="$1"
    echo "" >&2
    echo "❌  FATAL (step failed): $msg" >&2
    echo "    Working directory was: $(pwd)" >&2

    if [ "${AIBA_RETRY_COUNT}" -ge "${AIBA_MAX_RETRIES}" ]; then
        echo "🛑  Max retries (${AIBA_MAX_RETRIES}) exhausted. Aborting." >&2
        exit 1
    fi

    echo "🔍  Autonomous diagnosis (attempt $((AIBA_RETRY_COUNT + 1))/${AIBA_MAX_RETRIES})..."
    local log_tail
    log_tail=$(tail -n 150 "${LOG_FILE}" 2>/dev/null || true)

    # Diagnosis A: Missing commands
    # Uses ERE (-E) instead of PCRE (-P) for portability across grep builds.
    if echo "$log_tail" | grep -qi "command not found"; then
        local missing_cmd
        missing_cmd=$(echo "$log_tail" | grep -ioE 'bash: [^:]+: command not found' \
            | tail -1 | sed -E 's/bash: ([^:]+): command not found/\1/' || true)
        if [ -n "$missing_cmd" ]; then
            echo "🔧  Missing dependency '${missing_cmd}'. Installing..."
            if sudo apt-get update -qq && sudo apt-get install -y "${missing_cmd}"; then
                export AIBA_RETRY_COUNT=$((AIBA_RETRY_COUNT + 1))
                exec "$0" "${SCRIPT_ARGS[@]}"
            fi
        fi
    fi

    # Diagnosis B: Unmet dependencies
    if echo "$log_tail" | grep -qi "unmet dependencies"; then
        echo "🔧  Fixing broken dependencies..."
        if sudo apt-get --fix-broken install -y; then
            export AIBA_RETRY_COUNT=$((AIBA_RETRY_COUNT + 1))
            exec "$0" "${SCRIPT_ARGS[@]}"
        fi
    fi

    # Diagnosis C: Permission blocks
    if echo "$log_tail" | grep -qi "Permission denied"; then
        echo "🔧  Resetting workspace permissions..."
        sudo chown -R "$(id -u):$(id -g)" .
        sudo chmod -R u+rw .
        export AIBA_RETRY_COUNT=$((AIBA_RETRY_COUNT + 1))
        exec "$0" "${SCRIPT_ARGS[@]}"
    fi

    echo "🛑  Structural error — manual intervention required."
    exit 1
}

info()  { echo "ℹ️   $1"; }
ok()    { echo "✅  $1"; }
warn()  { echo "⚠️   $1"; }

file_size() {
    if [ -f "$1" ]; then
        du -h "$1" | awk '{print $1}'
    else
        echo "???"
    fi
}

detect_imagemagick() {
    if command -v magick &>/dev/null; then
        IM_CONVERT="magick"
    elif command -v convert &>/dev/null; then
        IM_CONVERT="convert"
    else
        fail "ImageMagick not installed. Run: sudo apt install imagemagick"
    fi
    echo "🖼️   ImageMagick command: ${IM_CONVERT}"
}

# 3-pass path-safe rebranding: protect submodule paths → rename → restore.
# Combined into a single sed invocation to halve I/O operations.
PLACEHOLDER="__AIBA_SUBMOD_PLACEHOLDER__"
rebrand_file() {
    local f="$1"
    [ -f "$f" ] || return 0
    sed -i \
        -e "s|submodules/${BRAND_OLD}|submodules/${PLACEHOLDER}|g" \
        -e "s/${BRAND_OLD}/${BRAND_NEW}/g" \
        -e "s|submodules/${PLACEHOLDER}|submodules/${BRAND_OLD}|g" \
        "$f"
}


###############################################################################
#   STEP 1 — Install initial packages                                        #
###############################################################################
step 1 "Installing initial packages"

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    devscripts equivs imagemagick icnsutils perl \
    || fail "Could not install required packages"

ok "Packages installed."


###############################################################################
#   STEP 2 — Clone the repository                                            #
###############################################################################
step 2 "Cloning ungoogled-chromium-debian repository"

if [ -d "${REPO_DIR}/.git" ]; then
    info "Repository '${REPO_DIR}' already exists — skipping clone."
else
    [ -d "${REPO_DIR}" ] && rm -rf "${REPO_DIR}"
    git clone "${REPO_URL}" "${REPO_DIR}" \
        || fail "git clone failed"
    ok "Repository cloned."
fi

cd "${REPO_DIR}"
REPO_ROOT="$(pwd)"
echo "📂  Working directory: ${REPO_ROOT}"


###############################################################################
#   STEP 3 — Initialise submodules                                           #
###############################################################################
step 3 "Initialising git submodules"

git submodule update --init --recursive \
    || fail "Submodule init failed"

ok "Submodules initialised."


###############################################################################
#   STEP 3.5 — Excise known-conflicting upstream patches                     #
###############################################################################
step "3.5" "Excising known-conflicting upstream patches"

# ──────────────────────────────────────────────────────────────────────────────
# CHRONOLOGY: This step MUST run AFTER submodule init (Step 3) and BEFORE
# debian/rules setup (Step 4). The setup target calls `patches.py apply`,
# which will fatally abort on patches that don't cleanly apply against the
# extracted Chromium source tree (version mismatch / upstream drift).
#
# SAFETY: The patch files live inside the ungoogled-chromium submodule.
# git clean -xfd (run by setup on the parent repo) does NOT recurse into
# submodules, so deletions here survive into Step 4.
# ──────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="${REPO_ROOT}/debian/submodules/ungoogled-chromium/patches"
SERIES_FILE="${PATCHES_DIR}/series"

if [ ! -f "${SERIES_FILE}" ]; then
    warn "Patch series file not found at ${SERIES_FILE} — skipping excision."
else
    for patch_rel in "${EXCISE_PATCHES[@]}"; do
        patch_abs="${PATCHES_DIR}/${patch_rel}"

        # Remove the patch file from disk
        if [ -f "${patch_abs}" ]; then
            rm -v "${patch_abs}"
            ok "Deleted: ${patch_rel}"
        else
            info "Already absent: ${patch_rel}"
        fi

        # Remove the entry from the series file (exact line match)
        if grep -qxF "${patch_rel}" "${SERIES_FILE}" 2>/dev/null; then
            # Use a different sed delimiter since paths contain /
            sed -i "\|^${patch_rel}\$|d" "${SERIES_FILE}"
            ok "Removed from series: ${patch_rel}"
        else
            info "Not in series file: ${patch_rel}"
        fi
    done

    echo "📋  Series file now starts with:"
    head -3 "${SERIES_FILE}" | sed 's/^/    │ /'
fi

ok "Patch excision complete."


###############################################################################
#   STEP 4 — Official source preparation                                     #
###############################################################################
step 4 "Running official source prep (debian/rules setup)"

debian/rules setup \
    || fail "'debian/rules setup' failed"

ok "Source preparation complete."


###############################################################################
#   STEP 4.5 — Detect Chromium source root                                   #
###############################################################################
step "4.5" "Detecting Chromium source root (sentinel: ${SENTINEL})"

# After debian/rules setup, the source is extracted directly into REPO_ROOT.
# Check there first, then fall back to sibling/nested layouts.

if [ -f "${REPO_ROOT}/${SENTINEL}" ]; then
    CHROMIUM_SRC_DIR="${REPO_ROOT}"
    ok "Source at repo root: ${CHROMIUM_SRC_DIR}"
else
    _old_ng=$(shopt -p nullglob || true)
    shopt -s nullglob
    for candidate in "${REPO_ROOT}"/../chromium-*/; do
        if [ -f "${candidate}${SENTINEL}" ]; then
            CHROMIUM_SRC_DIR="$(cd "${candidate}" && pwd)"
            ok "Source in sibling dir: ${CHROMIUM_SRC_DIR}"
            break
        fi
    done
    eval "${_old_ng}"
fi

if [ -z "${CHROMIUM_SRC_DIR}" ] && [ -f "${REPO_ROOT}/src/${SENTINEL}" ]; then
    CHROMIUM_SRC_DIR="${REPO_ROOT}/src"
    ok "Source in nested src/: ${CHROMIUM_SRC_DIR}"
fi

if [ -z "${CHROMIUM_SRC_DIR}" ]; then
    echo "" >&2
    echo "🛑  Could not locate '${SENTINEL}' under any expected layout." >&2
    echo "    Searched: repo root, ../chromium-*/, ./src/" >&2
    ls -1F "${REPO_ROOT}" >&2
    fail "Chromium source root detection failed."
fi

echo "📌  CHROMIUM_SRC_DIR = ${CHROMIUM_SRC_DIR}"


###############################################################################
#   STEP 5a — Pre-bundle uBlock Origin Lite extension                        #
###############################################################################
step "5a" "Pre-bundling uBlock Origin Lite (${UBLOCK_EXT_ID})"

EXT_DIR="${CHROMIUM_SRC_DIR}/chrome/browser/extensions/default_extensions"
CRX_FILE="${EXT_DIR}/${UBLOCK_EXT_ID}.crx"
EXT_JSON="${EXT_DIR}/${UBLOCK_EXT_ID}.json"

mkdir -p "${EXT_DIR}"

echo "⬇️   Downloading uBlock Origin Lite CRX …"
curl -L --fail --retry 3 --retry-delay 5 \
    -o "${CRX_FILE}" \
    "${UBLOCK_CRX_URL}" \
    || fail "CRX download failed for ${UBLOCK_EXT_ID}"

CRX_MAGIC="$(head -c 4 "${CRX_FILE}")"
if [ "${CRX_MAGIC}" != "Cr24" ]; then
    ACTUAL_HEX="$(xxd -l 4 -p "${CRX_FILE}")"
    fail "CRX header check failed. Expected 'Cr24', got hex: ${ACTUAL_HEX}"
fi
ok "CRX verified ($(file_size "${CRX_FILE}"))"

cat > "${EXT_JSON}" <<EXTJSON
{
  "external_crx": "/usr/lib/aiba/extensions/${UBLOCK_EXT_ID}.crx",
  "external_version": "1.0"
}
EXTJSON
ok "Extension manifest written."

BUILDGN="${EXT_DIR}/BUILD.gn"

if [ ! -f "${BUILDGN}" ]; then
    info "Creating BUILD.gn for extension bundling."
    {
        cat <<'BUILDGN_HEADER'
# Auto-generated by Aiba build script
import("//build/config/features.gni")
copy("default_extensions") {
  sources = [
BUILDGN_HEADER

        _old_ng=$(shopt -p nullglob || true)
        shopt -s nullglob
        for f in "${EXT_DIR}"/*.crx "${EXT_DIR}"/*.json; do
            [ -f "$f" ] && echo "    \"$(basename "$f")\","
        done
        eval "${_old_ng}"

        cat <<'BUILDGN_FOOTER'
  ]
  outputs = [ "$root_out_dir/extensions/{{source_file_part}}" ]
}
BUILDGN_FOOTER
    } > "${BUILDGN}"
    ok "BUILD.gn created."
else
    info "Existing BUILD.gn found — injecting extension entries."
    python3 <<PYINJECT
import re, sys

path = "${BUILDGN}"
crx = '"${UBLOCK_EXT_ID}.crx"'
jsn = '"${UBLOCK_EXT_ID}.json"'

with open(path, "r") as f:
    content = f.read()

m = re.search(r'(sources\s*=\s*\[)(.*?)(\])', content, re.DOTALL)
if not m:
    with open(path, "a") as f:
        f.write('\ncopy("aiba_default_extensions") {\n  sources = [\n    "${UBLOCK_EXT_ID}.crx",\n    "${UBLOCK_EXT_ID}.json",\n  ]\n  outputs = [ "\$root_out_dir/extensions/{{source_file_part}}" ]\n}\n')
    sys.exit(0)

block = m.group(2)
adds = []
if crx not in block: adds.append("    " + crx + ",")
if jsn not in block: adds.append("    " + jsn + ",")
if not adds:
    print("ℹ️  Extension entries already present.")
    sys.exit(0)

inject = "\n".join(adds) + "\n"
out = content[:m.end(1)] + "\n" + inject + content[m.end(1):]
with open(path, "w") as f:
    f.write(out)
print("✅  Injected " + str(len(adds)) + " entry/entries.")
PYINJECT
    ok "BUILD.gn patched."
fi

ok "uBlock Origin Lite pre-bundling complete."


###############################################################################
#   STEP 5b — Inject custom Aiba branding & assets                           #
###############################################################################
step "5b" "Injecting Aiba branding & icon assets"

cd "${REPO_ROOT}"

echo "📝  Patching .grd display name → '${BRAND_DISPLAY_NEW}' …"

GRD_FILES=(
    "${CHROMIUM_SRC_DIR}/chrome/app/chromium_strings.grd"
    "${CHROMIUM_SRC_DIR}/components/strings/components_chromium_strings.grd"
)

for grd in "${GRD_FILES[@]}"; do
    if [ -f "${grd}" ]; then
        perl -pi -e 's/\bChromium\b/Aiba/g' "${grd}"
        ok "Patched: $(basename "${grd}")"
    else
        warn "Skipped (not found): ${grd}"
    fi
done

BRANDING_FILE="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium/BRANDING"
if [ -f "${BRANDING_FILE}" ]; then
    sed -i \
        -e 's/^COMPANY_FULLNAME=.*/COMPANY_FULLNAME=Aiba Project/' \
        -e 's/^COMPANY_SHORTNAME=.*/COMPANY_SHORTNAME=Aiba/' \
        -e 's/^PRODUCT_FULLNAME=.*/PRODUCT_FULLNAME=Aiba Browser/' \
        -e 's/^PRODUCT_SHORTNAME=.*/PRODUCT_SHORTNAME=Aiba/' \
        -e 's/^PRODUCT_INSTALLER_FULLNAME=.*/PRODUCT_INSTALLER_FULLNAME=Aiba Browser/' \
        -e 's/^PRODUCT_INSTALLER_SHORTNAME=.*/PRODUCT_INSTALLER_SHORTNAME=Aiba/' \
        -e 's/^MAC_BUNDLE_ID=.*/MAC_BUNDLE_ID=org.AibaProject.Aiba/' \
        "${BRANDING_FILE}"
    ok "BRANDING file updated."
else
    warn "BRANDING file not found: ${BRANDING_FILE}"
fi

DESKTOP_TEMPLATE="${CHROMIUM_SRC_DIR}/chrome/installer/linux/common/desktop.template"
if [ -f "${DESKTOP_TEMPLATE}" ]; then
    perl -pi -e '
        s/\bChromium\b/Aiba/g;
        s/\bchromium-browser\b/aiba-browser/g;
        s/\bchromium\b/aiba/g;
    ' "${DESKTOP_TEMPLATE}"
    ok "desktop.template patched."
else
    warn "desktop.template not found."
fi

echo "🖼️   Generating icon assets from: ${AIBA_LOGO_PNG}"

if [ ! -f "${AIBA_LOGO_PNG}" ]; then
    fail "Logo not found at '${AIBA_LOGO_PNG}'. Place aiba_logo.png in workspace root."
fi

detect_imagemagick

THEME_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium"
mkdir -p "${THEME_DIR}"

for size in "${ICON_SIZES[@]}"; do
    OUT="${THEME_DIR}/product_logo_${size}.png"
    if ! ${IM_CONVERT} "${AIBA_LOGO_PNG}" \
        -alpha set -resize "${size}x${size}" \
        -background none -gravity center -extent "${size}x${size}" \
        -strip "png32:${OUT}" 2>&1; then
        warn "ImageMagick failed for ${size}px — check policy.xml restrictions."
    else
        echo "    ✓ product_logo_${size}.png  ($(file_size "${OUT}"))"
    fi
done
ok "PNG icon matrix generated."

ICO_OUT="${THEME_DIR}/chromium.ico"
if ! ${IM_CONVERT} "${AIBA_LOGO_PNG}" \
    -alpha set -define icon:auto-resize=256,48,32,16 \
    -background none -strip "${ICO_OUT}" 2>&1; then
    warn "ICO generation failed — non-fatal for Linux builds."
else
    ok "Windows ICO generated ($(file_size "${ICO_OUT}"))"
fi

ICNS_OUT="${THEME_DIR}/app.icns"
if command -v png2icns &>/dev/null; then
    ICNS_INPUTS=()
    for s in 16 32 48 128 256; do
        ICNS_INPUTS+=("${THEME_DIR}/product_logo_${s}.png")
    done
    png2icns "${ICNS_OUT}" "${ICNS_INPUTS[@]}" || warn "png2icns exited non-zero."
    ok "macOS ICNS generated ($(file_size "${ICNS_OUT}"))"
else
    warn "png2icns not available — skipping .icns (non-fatal)."
fi

ok "Aiba branding injection complete."


###############################################################################
#   STEP 5c — Patch Debian packaging controls (path-safe)                    #
###############################################################################
step "5c" "Patching Debian packaging controls (${BRAND_OLD} → ${BRAND_NEW})"

cd "${REPO_ROOT}"

# debian/control
DEBIAN_CONTROL="debian/control"
if [ -f "${DEBIAN_CONTROL}" ]; then
    rebrand_file "${DEBIAN_CONTROL}"
    sed -i \
        -e "s/Ungoogled Chromium/Aiba Browser/g" \
        -e "s/ungoogled chromium/aiba browser/g" \
        "${DEBIAN_CONTROL}"
    ok "debian/control patched."
else
    warn "debian/control not found."
fi

# debian/changelog (only first line — the package name in suite header)
DEBIAN_CHANGELOG="debian/changelog"
if [ -f "${DEBIAN_CHANGELOG}" ]; then
    sed -i "1s/${BRAND_OLD}/${BRAND_NEW}/g" "${DEBIAN_CHANGELOG}"
    ok "debian/changelog patched."
else
    warn "debian/changelog not found."
fi

# debian/rules (critical — contains submodule paths on nearly every line)
DEBIAN_RULES="debian/rules"
if [ -f "${DEBIAN_RULES}" ]; then
    rebrand_file "${DEBIAN_RULES}"
    ok "debian/rules patched."
else
    warn "debian/rules not found."
fi

# Rename per-package manifests (*.install, *.links, maintainer scripts)
RENAME_COUNT=0
_old_ng=$(shopt -p nullglob || true)
shopt -s nullglob

for old_file in debian/${BRAND_OLD}*; do
    base="$(basename "${old_file}")"
    new_base="${base/${BRAND_OLD}/${BRAND_NEW}}"
    new_file="debian/${new_base}"
    mv "${old_file}" "${new_file}"
    [ -f "${new_file}" ] && rebrand_file "${new_file}"
    echo "    ✓ ${base} → ${new_base}"
    RENAME_COUNT=$((RENAME_COUNT + 1))
done

eval "${_old_ng}"

[ "${RENAME_COUNT}" -eq 0 ] \
    && info "No debian/${BRAND_OLD}* manifests found to rename." \
    || ok "Renamed and patched ${RENAME_COUNT} debian manifest(s)."

# Catch-all sweep for remaining stale references in debian/
# EXCLUDES: .in templates (regenerated by setup), binary files
echo "📝  Scanning remaining debian/ files for stale '${BRAND_OLD}' references …"
STALE_COUNT=0

while IFS= read -r -d '' dfile; do
    [ -f "${dfile}" ] || continue
    case "${dfile}" in *.in) continue ;; esac
    mime_type="$(file --brief --mime-type "${dfile}" 2>/dev/null || true)"
    case "${mime_type}" in
        text/*)
            if grep -q "${BRAND_OLD}" "${dfile}" 2>/dev/null; then
                rebrand_file "${dfile}"
                echo "    ✓ Patched: $(basename "${dfile}")"
                STALE_COUNT=$((STALE_COUNT + 1))
            fi
            ;;
    esac
done < <(find debian/ -maxdepth 1 -print0)

[ "${STALE_COUNT}" -eq 0 ] \
    && ok "No stale references — debian/ is clean." \
    || ok "Patched ${STALE_COUNT} additional file(s)."

ok "Debian packaging controls rebranded to '${BRAND_NEW}'."


###############################################################################
#   STEP 5d — GN compiler optimizations (patched directly into debian/rules) #
###############################################################################
step "5d" "Injecting GN compiler optimizations into debian/rules"

cd "${REPO_ROOT}"

DEBIAN_RULES_FILE="${REPO_ROOT}/debian/rules"

if [ ! -f "${DEBIAN_RULES_FILE}" ]; then
    fail "debian/rules not found — cannot inject GN flags."
fi

# ──────────────────────────────────────────────────────────────────────────────
# STRATEGY: debian/rules builds GN_FLAGS by reading flags.gn first, then
# appending its own hardcoded values (last-write-wins). Writing to flags.gn
# is useless for any flag that debian/rules also sets.
#
# We patch the hardcoded values in debian/rules DIRECTLY via sed.
# Flags NOT present in debian/rules are appended to flags.gn instead.
# ──────────────────────────────────────────────────────────────────────────────

declare -A GN_OVERRIDES=(
    ["symbol_level"]="0"                # was 1 — strip debug symbols for speed
    ["use_thin_lto"]="true"             # was false — enable link-time optimization
)

FLAGS_GN="${REPO_ROOT}/debian/submodules/ungoogled-chromium/flags.gn"

for key in "${!GN_OVERRIDES[@]}"; do
    new_val="${GN_OVERRIDES[$key]}"
    # Use ERE (-E) for grep and sed; avoid PCRE (-P) for portability.
    if grep -qE "^[[:space:]]*${key}=" "${DEBIAN_RULES_FILE}" 2>/dev/null; then
        sed -i -E "s|(^[[:space:]]*)${key}=[^ \\\\]*|\1${key}=${new_val}|" "${DEBIAN_RULES_FILE}"
        ok "Patched debian/rules: ${key}=${new_val}"
    elif [ -f "${FLAGS_GN}" ]; then
        # Flag not in debian/rules — falls through to flags.gn
        if ! grep -q "^${key}=" "${FLAGS_GN}" 2>/dev/null; then
            echo "${key}=${new_val}" >> "${FLAGS_GN}"
            ok "Appended to flags.gn: ${key}=${new_val}"
        else
            info "Already in flags.gn: ${key}"
        fi
    else
        warn "Cannot set ${key}=${new_val} — not found in debian/rules or flags.gn"
    fi
done

# Inject additional flags that debian/rules doesn't set at all into flags.gn
GN_EXTRAS=(
    'blink_symbol_level=0'
    'enable_nacl=false'
    'enable_widevine=false'
    'chrome_pgo_phase=0'
)

if [ -f "${FLAGS_GN}" ]; then
    for arg in "${GN_EXTRAS[@]}"; do
        key="${arg%%=*}"
        if ! grep -q "^${key}=" "${FLAGS_GN}" 2>/dev/null; then
            echo "${arg}" >> "${FLAGS_GN}"
            echo "    ✓ ${arg} → flags.gn"
        else
            info "Skipped (already set): ${arg}"
        fi
    done
    ok "flags.gn extras injected."
else
    warn "flags.gn not found at expected path — skipping extras."
fi

echo ""
echo "📋  Final debian/rules GN_FLAGS excerpt:"
grep -E '^[[:space:]]*(symbol_level|use_thin_lto|blink_symbol_level|is_official_build)' \
    "${DEBIAN_RULES_FILE}" 2>/dev/null | sed 's/^/    │ /' || true

ok "GN compiler optimizations configured."


###############################################################################
#   STEP 6 — Install build dependencies                                      #
###############################################################################
step 6 "Installing build dependencies via mk-build-deps"

cd "${REPO_ROOT}"

sudo mk-build-deps -i debian/control \
    --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y' \
    --remove \
    || fail "mk-build-deps failed"

find . -maxdepth 1 -name "${BRAND_NEW}-build-deps_*" -delete 2>/dev/null || true
find . -maxdepth 1 -name "${BRAND_OLD}-build-deps_*" -delete 2>/dev/null || true

ok "Build dependencies installed."


###############################################################################
#   STEP 7 — Start the build                                                 #
###############################################################################
step 7 "Starting build (dpkg-buildpackage -b -uc)"

cd "${REPO_ROOT}"

CORES="$(nproc)"
echo "🚀  Launching production build with ${CORES} parallel jobs..."

# ──────────────────────────────────────────────────────────────────────────────
# PIPESTATUS SAFETY: We disable pipefail for the pipeline, then capture BOTH
# elements of PIPESTATUS in a snapshot array BEFORE any subsequent command
# can overwrite it. PIPESTATUS is volatile — it's reset by every command.
# ──────────────────────────────────────────────────────────────────────────────
set +o pipefail

dpkg-buildpackage -b -uc -j"${CORES}" 2>&1 | awk '{
    print $0
    if (/virtual memory exhausted|Cannot allocate memory|fatal error: error writing to.*pipe|out of memory/) {
        print "\n🚨  BUILD MACHINE MEMORY EXHAUSTED  🚨"
        system("killall -9 dpkg-buildpackage ninja cc1plus clang 2>/dev/null")
        exit 1
    }
}'

# Snapshot PIPESTATUS immediately — the next command will overwrite it.
_PIPE=("${PIPESTATUS[@]}")
set -o pipefail

BUILD_EXIT=${_PIPE[0]}
AWK_EXIT=${_PIPE[1]:-0}

# If awk detected OOM and exited non-zero, that takes priority.
if [ "${AWK_EXIT}" -ne 0 ]; then
    fail "Build terminated by OOM memory guard (awk exit=${AWK_EXIT})"
fi

# 141 = SIGPIPE (normal if awk closes the pipe before dpkg finishes writing)
if [ "${BUILD_EXIT}" -ne 0 ] && [ "${BUILD_EXIT}" -ne 141 ]; then
    fail "dpkg-buildpackage failed (exit code ${BUILD_EXIT})"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  🎉  BUILD COMPLETE — Aiba Browser"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Output .deb packages:"

find .. -maxdepth 1 -name "*.deb" -exec ls -lh {} + 2>/dev/null \
    || echo "(no .deb files found)"
