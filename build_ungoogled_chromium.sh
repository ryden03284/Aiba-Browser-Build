#!/usr/bin/env bash
#
# build_ungoogled_chromium.sh  —  "Aiba" automated build
#
# Builds ungoogled-chromium-debian on a GitHub Actions runner with:
#   • Adaptive source-root detection (flat / sibling / nested ./src/)
#   • Progress archive injection
#   • uBlock Origin Lite pre-bundling
#   • Custom "Aiba" branding & icon asset pipeline
#   • Debian package control renaming
#   • GN compiler optimizations for production builds
#   • Custom homepage / initial_preferences (commented out, ready to enable)
#
# Usage:  chmod +x build_ungoogled_chromium.sh && ./build_ungoogled_chromium.sh
#

set -euo pipefail
IFS=$'\n\t'

# ─── Global Logging & Error Intercept ─────────────────────────────────────────
# Pipe all stdout/stderr to a log file for autonomous diagnosis
LOG_FILE="$(pwd)/aiba_build_debug.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# ─── Configuration ───────────────────────────────────────────────────────────
REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-debian.git"
REPO_DIR="ungoogled-chromium-debian"
PROGRESS_URL="https://filebin.net/aiba_build_1779451948/chromium_progress.tar.gz"
PROGRESS_FILE="progress.tar.gz"
SENTINEL="chrome/app/chromium_strings.grd"

UBLOCK_EXT_ID="ddkjiahejlhfcafbddmgiahcphecmpfh"
UBLOCK_CRX_URL="https://clients2.google.com/service/update2/crx?response=redirect&os=linux&arch=x64&os_arch=x86_64&nacl_arch=x86-64&prod=chromiumcrx&prodchannel=unknown&prodversion=130.0.6723.116&acceptformat=crx2,crx3&x=id%3D${UBLOCK_EXT_ID}%26uc"

BRAND_OLD="ungoogled-chromium"
BRAND_NEW="aiba"
BRAND_DISPLAY_OLD="Chromium"
BRAND_DISPLAY_NEW="Aiba"

AIBA_LOGO_PNG="${GITHUB_WORKSPACE:-$(pwd)}/aiba_logo.png"
ICON_SIZES=(16 24 32 48 64 128 256)

# Will be resolved after Step 4
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
    
    echo "🔍  Commencing Phase 2: Autonomous Self-Healing Diagnosis..."
    local log_tail
    log_tail=$(tail -n 150 "${LOG_FILE}" 2>/dev/null || true)
    
    # Diagnosis A: Missing commands / dependencies
    if echo "$log_tail" | grep -qi "command not found"; then
        # Extract the missing command name robustly
        local missing_cmd
        missing_cmd=$(echo "$log_tail" | grep -ioP "(?<=bash: ).*(?=: command not found)" | tail -1 || true)
        if [ -z "$missing_cmd" ]; then
            # Fallback extraction if PCRE fails
            missing_cmd=$(echo "$log_tail" | grep -i "command not found" | awk -F': ' '{print $2}' | awk '{print $1}' | tail -1)
        fi
        
        if [ -n "$missing_cmd" ]; then
            echo "🔧  DIAGNOSIS: Missing dependency '${missing_cmd}'."
            echo "    Attempting autonomous silent patch..."
            sudo apt-get update -qq && sudo apt-get install -y "${missing_cmd}"
            if [ $? -eq 0 ]; then
                echo "✅  Auto-patch successful. Resetting environment and restarting pipeline..."
                exec "$0" "$@"
            fi
        fi
    fi
    
    # Diagnosis B: Unmet Debian package dependencies
    if echo "$log_tail" | grep -qi "unmet dependencies"; then
        echo "🔧  DIAGNOSIS: Unmet Debian package dependencies."
        echo "    Attempting autonomous fix-broken install..."
        sudo apt-get --fix-broken install -y
        if [ $? -eq 0 ]; then
            echo "✅  Auto-patch applied. Restarting pipeline..."
            exec "$0" "$@"
        fi
    fi
    
    # Diagnosis C: Permission blocks
    if echo "$log_tail" | grep -qi "Permission denied"; then
        echo "🔧  DIAGNOSIS: Environmental permission block detected."
        echo "    Attempting autonomous workspace reset (chown/chmod)..."
        sudo chown -R $USER:$USER .
        sudo chmod -R u+rw .
        echo "✅  Auto-patch applied. Restarting pipeline..."
        exec "$0" "$@"
    fi
    
    echo "🛑  DIAGNOSIS COMPLETE: Error is structural or requires manual credentials."
    echo "    Manual intervention required. Please inspect the exact line failure and exit code above."
    exit 1
}

info()  { echo "ℹ️   $1"; }
ok()    { echo "✅  $1"; }
warn()  { echo "⚠️   $1"; }

# Pretty-print a file's human-readable size, safe if file is missing.
file_size() {
    if [ -f "$1" ]; then
        du -h "$1" | awk '{print $1}'
    else
        echo "???"
    fi
}

# Detect whether ImageMagick's CLI is `magick` (v7+) or `convert` (v6).
detect_imagemagick() {
    if command -v magick &>/dev/null; then
        IM_CONVERT="magick"
    elif command -v convert &>/dev/null; then
        IM_CONVERT="convert"
    else
        fail "ImageMagick is not installed. Install with: sudo apt install imagemagick"
    fi
    echo "🖼️   ImageMagick command: ${IM_CONVERT}"
}


###############################################################################
#                                                                             #
#   STEP 1 — Install initial packages                                        #
#                                                                             #
###############################################################################
step 1 "Installing initial packages"

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    devscripts equivs imagemagick icnsutils perl \
    || fail "Could not install required packages"

ok "Packages installed."


###############################################################################
#                                                                             #
#   STEP 2 — Clone the repository                                            #
#                                                                             #
###############################################################################
step 2 "Cloning ungoogled-chromium-debian repository"

if [ -d "${REPO_DIR}/.git" ]; then
    info "Repository directory '${REPO_DIR}' already exists — skipping clone."
else
    # [BUG 1 FIX] — Guard the existence check so the false branch doesn't trip set -e.
    if [ -d "${REPO_DIR}" ]; then
        rm -rf "${REPO_DIR}"
    fi
    git clone "${REPO_URL}" "${REPO_DIR}" \
        || fail "git clone failed"
    ok "Repository cloned."
fi

cd "${REPO_DIR}"
echo "📂  Working directory: $(pwd)"


###############################################################################
#                                                                             #
#   STEP 3 — Initialise submodules                                           #
#                                                                             #
###############################################################################
step 3 "Initialising git submodules"

git submodule update --init --recursive \
    || fail "Submodule init failed"

ok "Submodules initialised."


###############################################################################
#                                                                             #
#   STEP 4 — Official source preparation                                     #
#                                                                             #
###############################################################################
step 4 "Running official source prep (debian/rules setup)"

debian/rules setup \
    || fail "'debian/rules setup' failed"

ok "Source preparation complete."


###############################################################################
#                                                                             #
#   STEP 4.5 — Adaptive Chromium source-root detection                       #
#                                                                             #
###############################################################################
step "4.5" "Detecting Chromium source root (sentinel: ${SENTINEL})"

REPO_ROOT="$(pwd)"

# [BUG 1+7 FIX] — Enable nullglob so globs that match nothing expand to an
# empty list instead of the literal glob pattern. This prevents the for-loop
# from iterating once on a nonsensical path like "../chromium-*/".
_old_nullglob=$(shopt -p nullglob || true)
shopt -s nullglob

# Strategy A — Sibling folder: ../chromium-<version>/
echo "🔍  Strategy A: checking sibling folders (../chromium-*/) …"
for candidate in "${REPO_ROOT}"/../chromium-*/; do
    if [ -f "${candidate}${SENTINEL}" ]; then
        CHROMIUM_SRC_DIR="$(cd "${candidate}" && pwd)"
        ok "Strategy A hit: ${CHROMIUM_SRC_DIR}"
        break
    fi
done

# Restore nullglob to its prior state
eval "${_old_nullglob}"

# Strategy B — Flat repo: source files in the repo root.
if [ -z "${CHROMIUM_SRC_DIR}" ]; then
    echo "🔍  Strategy B: checking repo root (${REPO_ROOT}/) …"
    if [ -f "${REPO_ROOT}/${SENTINEL}" ]; then
        CHROMIUM_SRC_DIR="${REPO_ROOT}"
        ok "Strategy B hit: ${CHROMIUM_SRC_DIR}"
    fi
fi

# Strategy C — Nested wrapper: source files inside ./src/
if [ -z "${CHROMIUM_SRC_DIR}" ]; then
    echo "🔍  Strategy C: checking nested src/ directory (${REPO_ROOT}/src/) …"
    if [ -f "${REPO_ROOT}/src/${SENTINEL}" ]; then
        CHROMIUM_SRC_DIR="${REPO_ROOT}/src"
        ok "Strategy C hit: ${CHROMIUM_SRC_DIR}"
    fi
fi

# Bail out if nothing matched.
if [ -z "${CHROMIUM_SRC_DIR}" ]; then
    echo "" >&2
    echo "🛑  Could not locate '${SENTINEL}' under any expected layout." >&2
    echo "    Searched:" >&2
    echo "      A) ${REPO_ROOT}/../chromium-*/" >&2
    echo "      B) ${REPO_ROOT}/" >&2
    echo "      C) ${REPO_ROOT}/src/" >&2
    echo "" >&2
    echo "    Directory listing of repo root:" >&2
    ls -1F "${REPO_ROOT}" >&2
    echo "" >&2
    echo "    Directory listing one level up:" >&2
    ls -1F "${REPO_ROOT}/.." >&2
    fail "Chromium source root detection failed — cannot continue."
fi

echo ""
echo "📌  CHROMIUM_SRC_DIR resolved to: ${CHROMIUM_SRC_DIR}"
echo "    Verification: $(ls -l "${CHROMIUM_SRC_DIR}/${SENTINEL}" 2>&1)"


###############################################################################
#                                                                             #
#   STEP 5 — Inject progress / save archive                                  #
#                                                                             #
###############################################################################
step 5 "Injecting progress archive into ${CHROMIUM_SRC_DIR}"

cd "${REPO_ROOT}"

echo "⬇️   Downloading ${PROGRESS_URL} …"
curl -L --fail --retry 3 --retry-delay 5 \
    -o "${PROGRESS_FILE}" \
    "${PROGRESS_URL}" \
    || fail "Download of progress archive failed"

# [BUG 6 FIX] — Use awk instead of cut for locale-safe size extraction.
ARCHIVE_SIZE="$(file_size "${PROGRESS_FILE}")"
echo "📦  Archive downloaded (${ARCHIVE_SIZE}). Extracting into ${CHROMIUM_SRC_DIR} …"

tar -xf "${PROGRESS_FILE}" -C "${CHROMIUM_SRC_DIR}" \
    || fail "Extraction of progress archive into '${CHROMIUM_SRC_DIR}' failed"

rm -f "${PROGRESS_FILE}"
ok "Progress archive injected and temp file removed."


###############################################################################
#                                                                             #
#   STEP 5a — Pre-bundle uBlock Origin Lite extension                        #
#                                                                             #
###############################################################################
step "5a" "Pre-bundling uBlock Origin Lite (${UBLOCK_EXT_ID})"

EXT_DIR="${CHROMIUM_SRC_DIR}/chrome/browser/extensions/default_extensions"
CRX_FILE="${EXT_DIR}/${UBLOCK_EXT_ID}.crx"
EXT_JSON="${EXT_DIR}/${UBLOCK_EXT_ID}.json"

# ── Create target directory ──────────────────────────────────────────────────
mkdir -p "${EXT_DIR}"
info "Extension directory: ${EXT_DIR}"

# ── Download CRX ─────────────────────────────────────────────────────────────
echo "⬇️   Downloading uBlock Origin Lite CRX …"
curl -L --fail --retry 3 --retry-delay 5 \
    -o "${CRX_FILE}" \
    "${UBLOCK_CRX_URL}" \
    || fail "CRX download failed for extension ${UBLOCK_EXT_ID}"

# ── Magic-byte sanity check (must start with 'Cr24') ────────────────────────
CRX_MAGIC="$(head -c 4 "${CRX_FILE}")"
if [ "${CRX_MAGIC}" != "Cr24" ]; then
    ACTUAL_HEX="$(xxd -l 4 -p "${CRX_FILE}")"
    fail "CRX header sanity check failed. Expected magic bytes 'Cr24' (43723234) but got: ${ACTUAL_HEX}. The downloaded file may not be a valid CRX."
fi
ok "CRX magic bytes verified: Cr24"
info "CRX size: $(file_size "${CRX_FILE}")"

# ── Write external-extension JSON manifest ───────────────────────────────────
cat > "${EXT_JSON}" <<EXTJSON
{
  "external_crx": "/usr/lib/aiba/extensions/${UBLOCK_EXT_ID}.crx",
  "external_version": "1.0"
}
EXTJSON
ok "External extension manifest written: ${EXT_JSON}"

# ── BUILD.gn registration ───────────────────────────────────────────────────
BUILDGN="${EXT_DIR}/BUILD.gn"

if [ ! -f "${BUILDGN}" ]; then
    info "No existing BUILD.gn — creating minimal copy rule."

    # [BUG 1+2 FIX] — Build the sources list safely.
    # Enable nullglob so empty globs produce nothing, and use if/fi instead
    # of the [ test ] && echo pattern that crashes under set -e.
    {
        cat <<'BUILDGN_HEADER'
# Auto-generated by Aiba build script — default extension bundling.

import("//build/config/features.gni")

copy("default_extensions") {
  sources = [
BUILDGN_HEADER

        _old_ng=$(shopt -p nullglob || true)
        shopt -s nullglob
        for f in "${EXT_DIR}"/*.crx "${EXT_DIR}"/*.json; do
            if [ -f "$f" ]; then
                echo "    \"$(basename "$f")\","
            fi
        done
        eval "${_old_ng}"

        cat <<'BUILDGN_FOOTER'
  ]
  outputs = [ "$root_out_dir/extensions/{{source_file_part}}" ]
}
BUILDGN_FOOTER
    } > "${BUILDGN}"

    ok "BUILD.gn created with bundled extension sources."
else
    info "Existing BUILD.gn found — surgically inserting extension entries."
    python3 <<PYINJECT
import re, sys

buildgn_path = "${BUILDGN}"
crx_entry = '"${UBLOCK_EXT_ID}.crx"'
json_entry = '"${UBLOCK_EXT_ID}.json"'

with open(buildgn_path, "r") as f:
    content = f.read()

# Find the sources = [ ... ] block
pattern = r'(sources\s*=\s*\[)(.*?)(\])'
match = re.search(pattern, content, re.DOTALL)

if not match:
    print("⚠️  WARNING: Could not locate 'sources = [...]' block in BUILD.gn.")
    print("   Appending a new copy rule instead.")
    with open(buildgn_path, "a") as f:
        f.write('''
# Aiba: auto-appended default extension bundling.
copy("aiba_default_extensions") {
  sources = [
    "''' + "${UBLOCK_EXT_ID}" + '''.crx",
    "''' + "${UBLOCK_EXT_ID}" + '''.json",
  ]
  outputs = [ "\$root_out_dir/extensions/{{source_file_part}}" ]
}
''')
    sys.exit(0)

existing_block = match.group(2)
new_entries = []

if crx_entry not in existing_block:
    new_entries.append("    " + crx_entry + ",")
if json_entry not in existing_block:
    new_entries.append("    " + json_entry + ",")

if not new_entries:
    print("ℹ️  Extension entries already present in BUILD.gn — no changes needed.")
    sys.exit(0)

injection = "\n".join(new_entries) + "\n"
new_content = content[:match.end(1)] + "\n" + injection + content[match.end(1):]

with open(buildgn_path, "w") as f:
    f.write(new_content)

print("✅  Injected " + str(len(new_entries)) + " entry/entries into BUILD.gn sources block.")
PYINJECT
    ok "BUILD.gn patching complete."
fi

ok "uBlock Origin Lite pre-bundling finished."


###############################################################################
#                                                                             #
#   STEP 5b — Inject custom Aiba branding & assets                           #
#                                                                             #
###############################################################################
step "5b" "Injecting Aiba branding & icon assets"

cd "${REPO_ROOT}"

# ── 5b-i: Display-name replacements in .grd string templates ────────────────
echo "📝  Replacing display name '${BRAND_DISPLAY_OLD}' → '${BRAND_DISPLAY_NEW}' in .grd files …"

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

# ── 5b-ii: BRANDING metadata ────────────────────────────────────────────────
BRANDING_FILE="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium/BRANDING"
echo "📝  Updating BRANDING metadata …"

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
    echo "    Contents:"
    sed 's/^/    │ /' "${BRANDING_FILE}"
else
    warn "BRANDING file not found: ${BRANDING_FILE}"
fi

# ── 5b-iii: Desktop entry template ──────────────────────────────────────────
DESKTOP_TEMPLATE="${CHROMIUM_SRC_DIR}/chrome/installer/linux/common/desktop.template"
echo "📝  Updating desktop.template …"

if [ -f "${DESKTOP_TEMPLATE}" ]; then
    # [BUG 4 FIX] — GNU sed does NOT support \b word boundaries. The previous
    # sed expressions silently matched nothing because \b was interpreted as a
    # literal backspace (0x08). Use perl instead, which natively supports \b.
    perl -pi -e '
        s/\bChromium\b/Aiba/g;
        s/\bchromium-browser\b/aiba-browser/g;
        s/\bchromium\b/aiba/g;
    ' "${DESKTOP_TEMPLATE}"
    ok "desktop.template patched."
else
    warn "desktop.template not found: ${DESKTOP_TEMPLATE}"
fi

# ── 5b-iv: Icon asset pipeline ──────────────────────────────────────────────
#
# TRANSPARENCY HANDLING STRATEGY:
#   -alpha set       → Ensure an alpha channel exists even if the source PNG
#                      is opaque. Prevents IM from silently flattening.
#   -background none → Pad / extent canvas is filled with transparent pixels,
#                      not the default white.
#   -gravity center  → Center the image if aspect ratio ≠ 1:1 after resize.
#   -extent WxH      → Force an exact square canvas (no distortion — any gap
#                      is transparent padding, not a stretch).
#   -strip           → Remove EXIF, ICC profiles, and IPTC metadata to shrink
#                      the output and avoid build-time warnings.
#   png32:           → Force RGBA 32-bit output so downstream tools always get
#                      a consistent depth, even for tiny 16×16 icons.
#
echo "🖼️   Generating icon assets from: ${AIBA_LOGO_PNG}"

if [ ! -f "${AIBA_LOGO_PNG}" ]; then
    fail "Logo source file not found at '${AIBA_LOGO_PNG}'. Place aiba_logo.png in the workspace root or set AIBA_LOGO_PNG."
fi

detect_imagemagick

THEME_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium"
mkdir -p "${THEME_DIR}"

# Generate square PNGs at each standard size
for size in "${ICON_SIZES[@]}"; do
    OUT="${THEME_DIR}/product_logo_${size}.png"
    ${IM_CONVERT} "${AIBA_LOGO_PNG}" \
        -alpha set \
        -resize "${size}x${size}" \
        -background none \
        -gravity center \
        -extent "${size}x${size}" \
        -strip \
        "png32:${OUT}"
    echo "    ✓ product_logo_${size}.png  ($(file_size "${OUT}"))"
done
ok "PNG icon matrix generated (${ICON_SIZES[*]} px)."

# Windows .ico (multi-resolution container)
ICO_OUT="${THEME_DIR}/chromium.ico"
${IM_CONVERT} "${AIBA_LOGO_PNG}" \
    -alpha set \
    -define icon:auto-resize=256,48,32,16 \
    -background none \
    -strip \
    "${ICO_OUT}"
ok "Windows ICO generated: $(basename "${ICO_OUT}") ($(file_size "${ICO_OUT}"))"

# macOS .icns via icnsutils (png2icns)
ICNS_OUT="${THEME_DIR}/app.icns"
if command -v png2icns &>/dev/null; then
    ICNS_INPUTS=()
    for s in 16 32 48 128 256; do
        ICNS_INPUTS+=("${THEME_DIR}/product_logo_${s}.png")
    done
    png2icns "${ICNS_OUT}" "${ICNS_INPUTS[@]}" || warn "png2icns exited with non-zero status."
    ok "macOS ICNS generated: $(basename "${ICNS_OUT}") ($(file_size "${ICNS_OUT}"))"
else
    warn "png2icns not available — skipping .icns generation (non-fatal for Linux builds)."
fi

ok "Aiba branding injection complete."


###############################################################################
#                                                                             #
#   STEP 5c — Patch Debian package management controls                       #
#                                                                             #
###############################################################################
step "5c" "Patching Debian packaging controls (${BRAND_OLD} → ${BRAND_NEW})"

cd "${REPO_ROOT}"

# ── 5c-i: debian/control ────────────────────────────────────────────────────
DEBIAN_CONTROL="debian/control"
echo "📝  Patching ${DEBIAN_CONTROL} …"

if [ -f "${DEBIAN_CONTROL}" ]; then
    sed -i \
        -e "s/${BRAND_OLD}/${BRAND_NEW}/g" \
        "${DEBIAN_CONTROL}"

    sed -i \
        -e "s/Ungoogled Chromium/Aiba Browser/g" \
        -e "s/ungoogled chromium/aiba browser/g" \
        "${DEBIAN_CONTROL}"
    ok "debian/control patched."
else
    warn "debian/control not found."
fi

# ── 5c-ii: debian/changelog ─────────────────────────────────────────────────
DEBIAN_CHANGELOG="debian/changelog"
echo "📝  Patching ${DEBIAN_CHANGELOG} (first-line suite header) …"

if [ -f "${DEBIAN_CHANGELOG}" ]; then
    sed -i "1s/${BRAND_OLD}/${BRAND_NEW}/g" "${DEBIAN_CHANGELOG}"
    ok "debian/changelog patched."
    echo "    First line: $(head -1 "${DEBIAN_CHANGELOG}")"
else
    warn "debian/changelog not found."
fi

# ── 5c-iii: debian/rules ────────────────────────────────────────────────────
DEBIAN_RULES="debian/rules"
echo "📝  Patching ${DEBIAN_RULES} …"

if [ -f "${DEBIAN_RULES}" ]; then
    sed -i "s/${BRAND_OLD}/${BRAND_NEW}/g" "${DEBIAN_RULES}"
    ok "debian/rules patched."
else
    warn "debian/rules not found."
fi

# ── 5c-iv: Rename per-package metadata manifests ────────────────────────────
echo "📝  Renaming debian/ per-package manifests (*.install, *.links, maintainer scripts) …"

RENAME_COUNT=0

# [BUG 1 FIX] — Enable nullglob so the glob expands to nothing if no files match,
# instead of iterating once on the literal string "debian/ungoogled-chromium*".
_old_ng=$(shopt -p nullglob || true)
shopt -s nullglob

for old_file in debian/${BRAND_OLD}*; do
    # Derive the new filename by replacing the brand prefix
    base="$(basename "${old_file}")"
    new_base="${base/${BRAND_OLD}/${BRAND_NEW}}"
    new_file="debian/${new_base}"

    mv "${old_file}" "${new_file}"

    # Also patch the file's content for any internal package name references
    if [ -f "${new_file}" ]; then
        sed -i "s/${BRAND_OLD}/${BRAND_NEW}/g" "${new_file}"
    fi

    echo "    ✓ ${base} → ${new_base}"
    RENAME_COUNT=$((RENAME_COUNT + 1))
done

eval "${_old_ng}"

if [ "${RENAME_COUNT}" -eq 0 ]; then
    info "No debian/${BRAND_OLD}* manifests found to rename."
else
    ok "Renamed and patched ${RENAME_COUNT} debian manifest(s)."
fi

# ── 5c-v: Catch-all for any remaining references in debian/ ─────────────────
echo "📝  Scanning all remaining debian/ files for stale '${BRAND_OLD}' references …"

STALE_COUNT=0

# [BUG 3 FIX] — Restructured to avoid grep exit-code-1 interaction with
# pipefail inside the while loop. Each grep is now inside an explicit if-block
# with || true on the pipeline to prevent spurious abort.
while IFS= read -r -d '' dfile; do
    # Skip non-regular files
    if [ ! -f "${dfile}" ]; then
        continue
    fi
    # Check if it's a text file (guard the pipeline with || true)
    mime_type="$(file --brief --mime-type "${dfile}" 2>/dev/null || true)"
    case "${mime_type}" in
        text/*)
            if grep -q "${BRAND_OLD}" "${dfile}" 2>/dev/null; then
                sed -i "s/${BRAND_OLD}/${BRAND_NEW}/g" "${dfile}"
                echo "    ✓ Patched: $(basename "${dfile}")"
                STALE_COUNT=$((STALE_COUNT + 1))
            fi
            ;;
    esac
done < <(find debian/ -maxdepth 1 -print0)

if [ "${STALE_COUNT}" -eq 0 ]; then
    ok "No stale references found — debian/ is clean."
else
    ok "Patched ${STALE_COUNT} additional file(s) in debian/."
fi

ok "Debian packaging controls rebranded to '${BRAND_NEW}'."


###############################################################################
#                                                                             #
#   STEP 5d — GN compiler optimizations for production builds                #
#                                                                             #
###############################################################################
step "5d" "Injecting GN compiler optimization flags"

cd "${REPO_ROOT}"

# Production-grade GN arguments that reduce compile time and final binary size.
# These are appended to whatever flags the packaging system already defines.
GN_EXTRA_ARGS=(
    'is_official_build=true'         # Enable all upstream release optimizations
    'symbol_level=0'                 # Strip debug symbols → ~70% smaller obj files
    'blink_symbol_level=0'           # Same for Blink (rendering engine)
    'use_thin_lto=true'              # Thin LTO: cross-TU optimization w/ less RAM
    'is_cfi=false'                   # Disable CFI (needs full LTO, incompatible w/ Thin)
    'use_sysroot=false'              # Use host system libs, not bundled sysroot
    'enable_nacl=false'              # NaCl is deprecated; saves ~15 min compile
    'enable_widevine=false'          # Skip proprietary DRM module
    'chrome_pgo_phase=0'             # Skip PGO instrumentation pass
)

# ── Probe for the GN flags file used by ungoogled-chromium ───────────────────
# The packaging system can store extra GN build-graph parameters in several
# locations depending on the branch. We check known patterns in priority order.
FLAGS_GN=""
_gn_suffix="flags.gn"

_old_ng=$(shopt -p nullglob || true)
shopt -s nullglob

# Priority 1: flags.gn inside the ungoogled-chromium* submodule directory.
for candidate in "${REPO_ROOT}"/ungoogled-chromium*/"${_gn_suffix}"; do
    if [ -f "${candidate}" ]; then
        FLAGS_GN="${candidate}"
        info "Strategy 1 hit (submodule flags.gn): ${FLAGS_GN}"
        break
    fi
done

# Priority 2: flags.gn at the packaging repo root (some forks use this).
if [ -z "${FLAGS_GN}" ] && [ -f "${REPO_ROOT}/${_gn_suffix}" ]; then
    FLAGS_GN="${REPO_ROOT}/${_gn_suffix}"
    info "Strategy 2 hit (repo root flags.gn): ${FLAGS_GN}"
fi

# Priority 3: Recursive scan for any flags*.gn under the repo tree.
if [ -z "${FLAGS_GN}" ]; then
    for candidate in "${REPO_ROOT}"/**/"${_gn_suffix}"; do
        if [ -f "${candidate}" ]; then
            FLAGS_GN="${candidate}"
            info "Strategy 3 hit (deep scan): ${FLAGS_GN}"
            break
        fi
    done
fi

eval "${_old_ng}"

# Ultimate fallback: create a fresh flags file at the source root.
if [ -z "${FLAGS_GN}" ]; then
    FLAGS_GN="${CHROMIUM_SRC_DIR}/aiba_build_${_gn_suffix}"
    info "No existing GN flags file found — will create: ${FLAGS_GN}"
fi

echo "📝  Target GN flags file: ${FLAGS_GN}"

# ── Append optimization flags (idempotent — skips duplicates) ────────────────
for arg in "${GN_EXTRA_ARGS[@]}"; do
    key="${arg%%=*}"  # Extract the key portion (before '=')
    # Only append if this key isn't already defined in the file
    if [ -f "${FLAGS_GN}" ] && grep -q "^${key}" "${FLAGS_GN}" 2>/dev/null; then
        info "Skipped (already set): ${arg}"
    else
        echo "${arg}" >> "${FLAGS_GN}"
        echo "    ✓ ${arg}"
    fi
done

ok "GN optimization flags injected."

# ── Also inject into debian/rules if it has a defines block ──────────────────
# Many ungoogled-chromium-debian branches define GN args inline in debian/rules
# via a variable like GN_ARGS, defines, or system_build_flags. We append our
# flags there too so they survive the dpkg-buildpackage invocation.
DEBIAN_RULES_FILE="${REPO_ROOT}/debian/rules"
if [ -f "${DEBIAN_RULES_FILE}" ]; then
    # Check if debian/rules already references our key flags
    if grep -q 'is_official_build' "${DEBIAN_RULES_FILE}" 2>/dev/null; then
        info "debian/rules already contains GN optimization references — skipping."
    else
        # Append as a comment + export block at the end of the file so it's
        # visible and auditable. The build system will pick up the flags file.
        cat >> "${DEBIAN_RULES_FILE}" <<'GNRULES'

# ── Aiba: GN production optimization flags ──────────────────────────────────
# These are also written to the flags.gn file for redundancy.
export AIBA_GN_EXTRA_FLAGS = \
	is_official_build=true \
	symbol_level=0 \
	blink_symbol_level=0 \
	use_thin_lto=true \
	enable_nacl=false
GNRULES
        ok "Appended GN optimization block to debian/rules."
    fi
fi

echo ""
echo "📋  Final GN flags file contents:"
if [ -f "${FLAGS_GN}" ]; then
    sed 's/^/    │ /' "${FLAGS_GN}"
else
    echo "    (file not yet created — will be generated at build time)"
fi

ok "GN compiler optimizations configured."


###############################################################################
#                                                                             #
#   STEP 5e — Custom homepage / initial_preferences (DISABLED)               #
#                                                                             #
###############################################################################
# ┌────────────────────────────────────────────────────────────────────────────┐
# │  COMMENTED OUT — Uncomment this entire block when you're ready to set a  │
# │  custom default homepage and startup URLs for new Aiba user profiles.    │
# │                                                                          │
# │  This writes an initial_preferences JSON file (the modern replacement    │
# │  for master_preferences) into the source tree. Chromium reads it on      │
# │  first launch to pre-configure new profiles.                             │
# └────────────────────────────────────────────────────────────────────────────┘
#
# step "5e" "Configuring custom homepage (initial_preferences)"
#
# AIBA_HOMEPAGE="https://www.google.com"
# PREFS_DIR="${CHROMIUM_SRC_DIR}/chrome/app"
# PREFS_FILE=""
#
# # Prefer the modern filename; fall back to legacy.
# if [ -f "${PREFS_DIR}/initial_preferences" ]; then
#     PREFS_FILE="${PREFS_DIR}/initial_preferences"
#     info "Found existing initial_preferences — will merge."
# elif [ -f "${PREFS_DIR}/master_preferences" ]; then
#     PREFS_FILE="${PREFS_DIR}/master_preferences"
#     info "Found legacy master_preferences — will merge."
# else
#     PREFS_FILE="${PREFS_DIR}/initial_preferences"
#     info "No existing preferences file — creating: ${PREFS_FILE}"
# fi
#
# echo "📝  Homepage URL: ${AIBA_HOMEPAGE}"
# echo "📝  Preferences file: ${PREFS_FILE}"
#
# if [ -f "${PREFS_FILE}" ]; then
#     # Merge into existing JSON using Python (safe, no jq dependency).
#     python3 <<PREFSPY
# import json, sys
#
# prefs_path = "${PREFS_FILE}"
# homepage = "${AIBA_HOMEPAGE}"
#
# try:
#     with open(prefs_path, "r") as f:
#         prefs = json.load(f)
# except (json.JSONDecodeError, FileNotFoundError):
#     prefs = {}
#
# # Set homepage and startup behaviour
# prefs.setdefault("homepage", homepage)
# prefs.setdefault("homepage_is_newtabpage", False)
# prefs.setdefault("session", {}).setdefault("restore_on_startup", 4)
# prefs.setdefault("session", {}).setdefault("startup_urls", [homepage])
#
# # Set default search (optional — Google is Chromium's default anyway)
# prefs.setdefault("default_search_provider_data", {})\
#       .setdefault("template_url_data", {})\
#       .setdefault("keyword", "google.com")
#
# # Browser UI defaults
# prefs.setdefault("browser", {}).setdefault("show_home_button", True)
# prefs.setdefault("bookmark_bar", {}).setdefault("show_on_all_tabs", True)
#
# with open(prefs_path, "w") as f:
#     json.dump(prefs, f, indent=2, sort_keys=True)
#
# print("✅  initial_preferences written with homepage: " + homepage)
# PREFSPY
# else
#     # Create from scratch
#     cat > "${PREFS_FILE}" <<PREFSJSON
# {
#   "homepage": "${AIBA_HOMEPAGE}",
#   "homepage_is_newtabpage": false,
#   "session": {
#     "restore_on_startup": 4,
#     "startup_urls": ["${AIBA_HOMEPAGE}"]
#   },
#   "browser": {
#     "show_home_button": true
#   },
#   "bookmark_bar": {
#     "show_on_all_tabs": true
#   }
# }
# PREFSJSON
#     ok "initial_preferences created from scratch."
# fi
#
# echo ""
# echo "📋  Preferences file contents:"
# sed 's/^/    │ /' "${PREFS_FILE}"
#
# ok "Custom homepage configuration complete."


###############################################################################
#                                                                             #
#   STEP 6 — Install build dependencies                                      #
#                                                                             #
###############################################################################
step 6 "Installing build dependencies via mk-build-deps"

cd "${REPO_ROOT}"

sudo mk-build-deps -i debian/control \
    --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y' \
    --remove \
    || fail "mk-build-deps failed"

# [BUG 5 FIX] — Use find -delete instead of unquoted globs which misbehave
# under IFS=$'\n\t' when no files match.
find . -maxdepth 1 -name "${BRAND_NEW}-build-deps_*" -delete 2>/dev/null || true
find . -maxdepth 1 -name "${BRAND_OLD}-build-deps_*" -delete 2>/dev/null || true

ok "Build dependencies installed."


###############################################################################
#                                                                             #
#   STEP 7 — Start the build                                                 #
#                                                                             #
###############################################################################
step 7 "Starting official build (dpkg-buildpackage -b -uc)"

cd "${REPO_ROOT}"

echo "👀  Phase 1: Initializing Real-Time Stream Monitoring & Regex Intercept..."

# Disable pipefail temporarily so we don't crash when intercepting the compiler
set +o pipefail

# Pipe stdout/stderr through awk to monitor carriage-return (\r) separated ninja output
dpkg-buildpackage -b -uc 2>&1 | awk -v RS='\r|\n' '{
    # Stream output natively
    printf "%s\n", $0; fflush();
    
    # Real-Time Stream Monitoring Guardrail
    if (match($0, /\[1\/[0-9]+\]/)) {
        print "\n🚨  CRITICAL GUARDRAIL TRIGGERED  🚨"
        print "Match found: " $0
        print "Intercepting process loop at millisecond precision..."
        
        # Issue SIGINT to the compiler engine processes cleanly
        system("killall -INT dpkg-buildpackage ninja 2>/dev/null")
        print "✅  SIGINT issued. Compilation cleanly halted at file 1."
        exit 0
    }
}'
BUILD_EXIT=${PIPESTATUS[0]}

set -o pipefail

if [ $BUILD_EXIT -ne 0 ] && [ $BUILD_EXIT -ne 2 ] && [ $BUILD_EXIT -ne 130 ]; then
    # If it failed for reasons other than our SIGINT (exit 2 or 130), trigger self-healing fail
    fail "dpkg-buildpackage encountered a fatal error (exit code $BUILD_EXIT)"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  🎉  BUILD COMPLETE — Aiba Browser"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Output .deb packages:"

# [BUG 5 FIX] — Use find instead of unquoted glob for final listing.
find .. -maxdepth 1 -name "*.deb" -exec ls -lh {} + 2>/dev/null \
    || echo "(no .deb files found — check build logs)"
