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
        local missing_cmd
        missing_cmd=$(echo "$log_tail" | grep -ioP "(?<=bash: ).*(?=: command not found)" | tail -1 || true)
        if [ -z "$missing_cmd" ]; then
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
        sudo chown -R "$(id -u):$(id -g)" .
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

_old_nullglob=$(shopt -p nullglob || true)
shopt -s nullglob

echo "🔍  Strategy A: checking sibling folders (../chromium-*/) …"
for candidate in "${REPO_ROOT}"/../chromium-*/; do
    if [ -f "${candidate}${SENTINEL}" ]; then
        CHROMIUM_SRC_DIR="$(cd "${candidate}" && pwd)"
        ok "Strategy A hit: ${CHROMIUM_SRC_DIR}"
        break
    fi
done

eval "${_old_nullglob}"

if [ -z "${CHROMIUM_SRC_DIR}" ]; then
    echo "🔍  Strategy B: checking repo root (${REPO_ROOT}/) …"
    if [ -f "${REPO_ROOT}/${SENTINEL}" ]; then
        CHROMIUM_SRC_DIR="${REPO_ROOT}"
        ok "Strategy B hit: ${CHROMIUM_SRC_DIR}"
    fi
fi

if [ -z "${CHROMIUM_SRC_DIR}" ]; then
    echo "🔍  Strategy C: checking nested src/ directory (${REPO_ROOT}/src/) …"
    if [ -f "${REPO_ROOT}/src/${SENTINEL}" ]; then
        CHROMIUM_SRC_DIR="${REPO_ROOT}/src"
        ok "Strategy C hit: ${CHROMIUM_SRC_DIR}"
    fi
fi

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

mkdir -p "${EXT_DIR}"
info "Extension directory: ${EXT_DIR}"

echo "⬇️   Downloading uBlock Origin Lite CRX …"
curl -L --fail --retry 3 --retry-delay 5 \
    -o "${CRX_FILE}" \
    "${UBLOCK_CRX_URL}" \
    || fail "CRX download failed for extension ${UBLOCK_EXT_ID}"

CRX_MAGIC="$(head -c 4 "${CRX_FILE}")"
if [ "${CRX_MAGIC}" != "Cr24" ]; then
    ACTUAL_HEX="$(xxd -l 4 -p "${CRX_FILE}")"
    fail "CRX header sanity check failed. Expected magic bytes 'Cr24' (43723234) but got: ${ACTUAL_HEX}."
fi
ok "CRX magic bytes verified: Cr24"
info "CRX size: $(file_size "${CRX_FILE}")"

cat > "${EXT_JSON}" <<EXTJSON
{
  "external_crx": "/usr/lib/aiba/extensions/${UBLOCK_EXT_ID}.crx",
  "external_version": "1.0"
}
EXTJSON
ok "External extension manifest written: ${EXT_JSON}"

BUILDGN="${EXT_DIR}/BUILD.gn"

if [ ! -f "${BUILDGN}" ]; then
    info "No existing BUILD.gn — creating minimal copy rule."
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

DESKTOP_TEMPLATE="${CHROMIUM_SRC_DIR}/chrome/installer/linux/common/desktop.template"
echo "📝  Updating desktop.template …"

if [ -f "${DESKTOP_TEMPLATE}" ]; then
    perl -pi -e '
        s/\bChromium\b/Aiba/g;
        s/\bchromium-browser\b/aiba-browser/g;
        s/\bchromium\b/aiba/g;
    ' "${DESKTOP_TEMPLATE}"
    ok "desktop.template patched."
else
    warn "desktop.template not found: ${DESKTOP_TEMPLATE}"
fi

echo "🖼️   Generating icon assets from: ${AIBA_LOGO_PNG}"

if [ ! -f "${AIBA_LOGO_PNG}" ]; then
    fail "Logo source file not found at '${AIBA_LOGO_PNG}'. Place aiba_logo.png in the workspace root or set AIBA_LOGO_PNG."
fi

detect_imagemagick

THEME_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium"
mkdir -p "${THEME_DIR}"

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

ICO_OUT="${THEME_DIR}/chromium.ico"
${IM_CONVERT} "${AIBA_LOGO_PNG}" \
    -alpha set \
    -define icon:auto-resize=256,48,32,16 \
    -background none \
    -strip \
    "${ICO_OUT}"
ok "Windows ICO generated: $(basename "${ICO_OUT}") ($(file_size "${ICO_OUT}"))"

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

DEBIAN_CHANGELOG="debian/changelog"
echo "📝  Patching ${DEBIAN_CHANGELOG} (first-line suite header) …"

if [ -f "${DEBIAN_CHANGELOG}" ]; then
    sed -i "1s/${BRAND_OLD}/${BRAND_NEW}/g" "${DEBIAN_CHANGELOG}"
    ok "debian/changelog patched."
    echo "    First line: $(head -1 "${DEBIAN_CHANGELOG}")"
else
    warn "debian/changelog not found."
fi

DEBIAN_RULES="debian/rules"
echo "📝  Patching ${DEBIAN_RULES} …"

if [ -f "${DEBIAN_RULES}" ]; then
    sed -i "s/${BRAND_OLD}/${BRAND_NEW}/g" "${DEBIAN_RULES}"
    ok "debian/rules patched."
else
    warn "debian/rules not found."
fi

echo "📝  Renaming debian/ per-package manifests (*.install, *.links, maintainer scripts) …"

RENAME_COUNT=0
_old_ng=$(shopt -p nullglob || true)
shopt -s nullglob

for old_file in debian/${BRAND_OLD}*; do
    base="$(basename "${old_file}")"
    new_base="${base/${BRAND_OLD}/${BRAND_NEW}}"
    new_file="debian/${new_base}"

    mv "${old_file}" "${new_file}"

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

echo "📝  Scanning all remaining debian/ files for stale '${BRAND_OLD}' references …"
STALE_COUNT=0

while IFS= read -r -d '' dfile; do
    if [ ! -f "${dfile}" ]; then
        continue
    fi
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
#   STEP 5d — GN compiler optimizations for production builds                 #
#                                                                             #
###############################################################################
step "5d" "Injecting GN compiler optimization flags"

cd "${REPO_ROOT}"

GN_EXTRA_ARGS=(
    'is_official_build=true'         
    'symbol_level=0'                 
    'blink_symbol_level=0'           
    'use_thin_lto=true'              
    'is_cfi=false'                   
    'use_sysroot=false'              
    'enable_nacl=false'              
    'enable_widevine=false'          
    'chrome_pgo_phase=0'             
)

FLAGS_GN=""
_gn_suffix="flags.gn"

_old_ng=$(shopt -p nullglob || true)
shopt -s nullglob

for candidate in "${REPO_ROOT}"/ungoogled-chromium*/"${_gn_suffix}"; do
    if [ -f "${candidate}" ]; then
        FLAGS_GN="${candidate}"
        info "Strategy 1 hit (submodule flags.gn): ${FLAGS_GN}"
        break
    fi
done

if [ -z "${FLAGS_GN}" ] && [ -f "${REPO_ROOT}/${_gn_suffix}" ]; then
    FLAGS_GN="${REPO_ROOT}/${_gn_suffix}"
    info "Strategy 2 hit (repo root flags.gn): ${FLAGS_GN}"
fi

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

if [ -z "${FLAGS_GN}" ]; then
    FLAGS_GN="${CHROMIUM_SRC_DIR}/aiba_build_${_gn_suffix}"
    info "No existing GN flags file found — will create: ${FLAGS_GN}"
fi

echo "📝  Target GN flags file: ${FLAGS_GN}"

for arg in "${GN_EXTRA_ARGS[@]}"; do
    key="${arg%%=*}"  
    if [ -f "${FLAGS_GN}" ] && grep -q "^${key}" "${FLAGS_GN}" 2>/dev/null; then
        info "Skipped (already set): ${arg}"
    else
        echo "${arg}" >> "${FLAGS_GN}"
        echo "    ✓ ${arg}"
    fi
done

ok "GN optimization flags injected."

DEBIAN_RULES_FILE="${REPO_ROOT}/debian/rules"
if [ -f "${DEBIAN_RULES_FILE}" ]; then
    if grep -q 'AIBA_GN_EXTRA_FLAGS' "${DEBIAN_RULES_FILE}" 2>/dev/null; then
        info "debian/rules already contains GN optimization references — skipping."
    else
        cat >> "${DEBIAN_RULES_FILE}" <<'GNRULES'

# ── Aiba: GN production optimization flags ──────────────────────────────────
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
#   STEP 5e — Custom homepage / initial_preferences (DISABLED)                #
#                                                                             #
###############################################################################
# (Staged preferences logic blocks remain structured here for future use)


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

echo "🚀  Launching production build pipeline..."
echo "📊  Live stream logging enabled. Compiling browser natively using all $(nproc) available cores..."

set +o pipefail

# Run the build natively with max jobs. No fflush() is used to prevent I/O bottlenecks.
dpkg-buildpackage -b -uc -j"$(nproc)" 2>&1 | awk '{
    print $0
    
    # Proactive Memory/OOM Safety Valve
    if (match($0, /virtual memory exhausted|fatal error: error writing to.*pipe/)) {
        print "\n🚨  BUILD MACHINE MEMORY EXHAUSTED  🚨"
        system("killall -9 dpkg-buildpackage ninja cc1plus clang 2>/dev/null")
        exit 1
    }
}'

BUILD_EXIT=${PIPESTATUS[0]}
set -o pipefail

# 141 represents standard SIGPIPE handling if the pipeline is ever broken cleanly
if [ $BUILD_EXIT -ne 0 ] && [ $BUILD_EXIT -ne 141 ]; then
    fail "dpkg-buildpackage encountered a structural compilation failure (exit code $BUILD_EXIT)"
fi

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  🎉  BUILD COMPLETE — Aiba Browser"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "Output .deb packages:"

find .. -maxdepth 1 -name "*.deb" -exec ls -lh {} + 2>/dev/null \
    || echo "(no .deb files found — check build logs)"
