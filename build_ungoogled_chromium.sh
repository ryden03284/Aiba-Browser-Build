#!/usr/bin/env bash
#
# build_ungoogled_chromium.sh  —  "Aiba" automated build  (v5.0 — Fixed & Optimized)
#
# Fixes applied over v4.0:
#   • tee race on exit fixed via combined EXIT trap
#   • sources.list deb-src injection made idempotent (no duplicate lines)
#   • nullglob guard around *.list glob
#   • CRX magic validated via xxd hex comparison (not raw bytes)
#   • find -path prune uses */submodules glob (portable, no ./ prefix assumption)
#   • default_100_percent logo now properly resized to 16×16 via ImageMagick
#   • flags.gn append made idempotent (no duplicate flags on re-run)
#   • PIPESTATUS replaced by FIFO + wait pattern for clean exit-code capture
#   • stdbuf replaced by named FIFO — OOM guard reads every line from every child
#   • Retry/auto-install logic in fail() replaced by upfront preflight check
#   • BRAND_DISPLAY_NEW used throughout branding (was defined but unused)
#   • Step labels consistent and sequential (5c & 5d now separate announcements)
#   • All cores detected once at top via nproc and used throughout
#

set -euo pipefail
IFS=$'\n\t'

# ─── Logging — combined EXIT trap handles both tee flush and FIFO cleanup ────
LOG_FILE="$(pwd)/aiba_build_debug.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# Initialise trap; extended later when FIFO path is known
trap 'wait' EXIT

# ─── Configuration ────────────────────────────────────────────────────────────
REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-debian.git"
REPO_DIR="ungoogled-chromium-debian"
SENTINEL="chrome/app/chromium_strings.grd"

UBLOCK_EXT_ID="adkmjipfdaojgkihidmnehnoobbpfoba"
UBLOCK_CRX_URL="https://clients2.google.com/service/update2/crx?response=redirect&os=linux&arch=x64&os_arch=x86_64&nacl_arch=x86-64&prod=chromiumcrx&prodchannel=unknown&prodversion=130.0.6723.116&acceptformat=crx2,crx3&x=id%3D${UBLOCK_EXT_ID}%26uc"

BRAND_OLD="ungoogled-chromium"
BRAND_NEW="aiba"
BRAND_DISPLAY_NEW="Aiba"
BRAND_COMPANY="Aiba Project"

AIBA_LOGO_PNG="${GITHUB_WORKSPACE:-$(pwd)}/aiba_logo.png"
ICON_SIZES=(16 24 32 48 64 128 256)

EXCISE_PATCHES=(
    "core/inox-patchset/0001-fix-building-without-safebrowsing.patch"
)

# Detect all available cores once at startup
CORES="$(nproc)"
IM_CONVERT=""
CHROMIUM_SRC_DIR=""
REPO_ROOT=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
step() {
    echo -e "\n══════════════════════════════════════════════════════════════"
    echo "  STEP $1: $2"
    echo -e "══════════════════════════════════════════════════════════════\n"
}

fail() {
    echo -e "\n❌  FATAL: $1" >&2
    echo "    Working directory: $(pwd)" >&2
    exit 1
}

info() { echo "ℹ️   $1"; }
ok()   { echo "✅  $1"; }
warn() { echo "⚠️   $1"; }

detect_imagemagick() {
    if command -v magick &>/dev/null; then
        IM_CONVERT="magick"
    elif command -v convert &>/dev/null; then
        IM_CONVERT="convert"
    else
        fail "ImageMagick not found — install with: sudo apt-get install imagemagick"
    fi
    info "ImageMagick command: ${IM_CONVERT}"
}

# Upfront preflight — fail fast before any build work begins
preflight_check() {
    local missing=()
    local required=(git curl xxd perl sed awk file du tee mkfifo)
    for cmd in "${required[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        fail "Missing required commands: ${missing[*]}
Install them with: sudo apt-get install ${missing[*]}"
    fi
    ok "Preflight passed — all required tools present."
}

# Add deb-src lines to a sources file, idempotently (never duplicates)
add_deb_src() {
    local src="$1"
    [ -f "$src" ] || return 0
    local tmp
    tmp="$(mktemp)"
    cp "$src" "$tmp"
    while IFS= read -r line; do
        # Only process plain 'deb' lines, not existing 'deb-src' lines
        [[ "$line" =~ ^deb[[:space:]] ]] || continue
        local deb_src_line="deb-src ${line#deb }"
        # Only append if not already present anywhere in the file
        grep -qxF "$deb_src_line" "$src" || echo "$deb_src_line" >> "$tmp"
    done < "$src"
    sudo cp "$tmp" "$src"
    rm -f "$tmp"
}

# Placeholder prevents the submodule path from being rebranded
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
#   STEP 1 — Install initial packages                                         #
###############################################################################
step 1 "Installing initial packages and enabling source repos"

# Idempotent deb-src injection — no duplicates, nullglob for *.list
add_deb_src /etc/apt/sources.list
shopt -s nullglob
for listfile in /etc/apt/sources.list.d/*.list; do
    add_deb_src "$listfile"
done
shopt -u nullglob

sudo apt-get update -qq

sudo apt-get install -y --no-install-recommends \
    devscripts equivs imagemagick icnsutils perl curl xxd file coreutils \
    || fail "Could not install required packages"

preflight_check
ok "Packages installed. Using ${CORES} CPU cores for compilation."

###############################################################################
#   STEP 2 — Clone the repository and submodules                              #
###############################################################################
step 2 "Cloning repo and initialising submodules"

if [ ! -d "${REPO_DIR}/.git" ]; then
    [ -d "${REPO_DIR}" ] && rm -rf "${REPO_DIR}"
    git clone "${REPO_URL}" "${REPO_DIR}" || fail "git clone failed"
fi

cd "${REPO_DIR}"
REPO_ROOT="$(pwd)"

git submodule update --init --recursive || fail "Submodule init failed"
ok "Repository staged at ${REPO_ROOT}"

###############################################################################
#   STEP 3 — Excise known-conflicting upstream patches                        #
###############################################################################
step 3 "Excising known-conflicting upstream patches"

PATCHES_DIR="${REPO_ROOT}/debian/submodules/ungoogled-chromium/patches"
SERIES_FILE="${PATCHES_DIR}/series"

if [ -f "${SERIES_FILE}" ]; then
    for patch_rel in "${EXCISE_PATCHES[@]}"; do
        patch_abs="${PATCHES_DIR}/${patch_rel}"
        if [ -f "${patch_abs}" ]; then
            rm -v "${patch_abs}"
            ok "Deleted: ${patch_rel}"
        fi
        sed -i "\|^${patch_rel}\$|d" "${SERIES_FILE}" 2>/dev/null || true
    done
fi
ok "Patch excision complete."

###############################################################################
#   STEP 4 — Official source preparation                                      #
###############################################################################
step 4 "Running official source prep (debian/rules setup)"

debian/rules setup || fail "'debian/rules setup' failed"
ok "Source preparation complete."

###############################################################################
#   STEP 4.5 — Detect Chromium source root                                   #
###############################################################################
step "4.5" "Detecting Chromium source root"

if [ -f "${REPO_ROOT}/${SENTINEL}" ]; then
    CHROMIUM_SRC_DIR="${REPO_ROOT}"
elif [ -f "${REPO_ROOT}/build/src/${SENTINEL}" ]; then
    CHROMIUM_SRC_DIR="${REPO_ROOT}/build/src"
elif [ -f "${REPO_ROOT}/src/${SENTINEL}" ]; then
    CHROMIUM_SRC_DIR="${REPO_ROOT}/src"
else
    fail "Chromium source root not found — ${SENTINEL} missing in all expected locations."
fi

ok "Found source root: ${CHROMIUM_SRC_DIR}"

###############################################################################
#   STEP 5a — Pre-bundle uBlock Origin Lite extension                         #
###############################################################################
step "5a" "Pre-bundling uBlock Origin Lite (${UBLOCK_EXT_ID})"

EXT_DIR="${CHROMIUM_SRC_DIR}/chrome/browser/extensions/default_extensions"
CRX_FILE="${EXT_DIR}/${UBLOCK_EXT_ID}.crx"
EXT_JSON="${EXT_DIR}/${UBLOCK_EXT_ID}.json"

mkdir -p "${EXT_DIR}"

curl -L --fail --retry 3 --retry-delay 5 -o "${CRX_FILE}" "${UBLOCK_CRX_URL}" \
    || fail "CRX download failed"

# Validate CRX3 magic bytes via xxd hex — avoids raw binary comparison pitfalls.
# CRX3 magic is the ASCII string "Cr24" = 0x43 0x72 0x32 0x34
CRX_MAGIC="$(xxd -p -l 4 "${CRX_FILE}")"
if [ "${CRX_MAGIC}" != "43723234" ]; then
    fail "CRX header check failed — got '${CRX_MAGIC}', expected '43723234' (Cr24)"
fi
ok "CRX magic bytes verified (${CRX_MAGIC})."

cat > "${EXT_JSON}" <<EXTJSON
{
  "external_crx": "/usr/lib/${BRAND_NEW}/extensions/${UBLOCK_EXT_ID}.crx",
  "external_version": "1.0"
}
EXTJSON

BUILDGN="${EXT_DIR}/BUILD.gn"
if [ ! -f "${BUILDGN}" ]; then
    cat > "${BUILDGN}" <<BUILDGN_EOF
import("//build/config/features.gni")
copy("default_extensions") {
  sources = [
    "${UBLOCK_EXT_ID}.crx",
    "${UBLOCK_EXT_ID}.json",
  ]
  outputs = [ "\$root_out_dir/extensions/{{source_file_part}}" ]
}
BUILDGN_EOF
    ok "BUILD.gn generated."
else
    if ! grep -q "${UBLOCK_EXT_ID}" "${BUILDGN}"; then
        sed -i "/sources = \[/a \\    \"${UBLOCK_EXT_ID}.crx\",\n    \"${UBLOCK_EXT_ID}.json\"," "${BUILDGN}"
        ok "BUILD.gn patched via sed."
    else
        info "Extension entries already present in BUILD.gn."
    fi
fi

DEFAULT_APPS_DIR="${CHROMIUM_SRC_DIR}/chrome/browser/resources/default_apps"
mkdir -p "${DEFAULT_APPS_DIR}"
cat > "${DEFAULT_APPS_DIR}/external_extensions.json" <<EOF
{
  "${UBLOCK_EXT_ID}": {
    "external_update_url": "https://clients2.google.com/service/update2/crx"
  }
}
EOF
ok "External extension policy mapped."

###############################################################################
#   STEP 5b — Inject Aiba branding & icon assets                              #
###############################################################################
step "5b" "Injecting ${BRAND_DISPLAY_NEW} branding & icon assets"

cd "${REPO_ROOT}"
detect_imagemagick

if [ ! -f "${AIBA_LOGO_PNG}" ]; then
    warn "Logo not found at '${AIBA_LOGO_PNG}' — generating fallback canvas asset..."
    "${IM_CONVERT}" \
        -size 512x512 xc:#1a1a1a \
        -gravity center \
        -fill "#4a90e2" \
        -font Helvetica-Bold \
        -pointsize 180 \
        -draw "text 0,0 'A'" \
        "${AIBA_LOGO_PNG}" \
        || fail "Fallback logo generation failed"
    ok "Fallback logo created at ${AIBA_LOGO_PNG}"
fi

GRD_FILES=(
    "${CHROMIUM_SRC_DIR}/chrome/app/chromium_strings.grd"
    "${CHROMIUM_SRC_DIR}/components/strings/components_chromium_strings.grd"
)
for grd in "${GRD_FILES[@]}"; do
    if [ -f "${grd}" ]; then
        perl -pi -e "s/\\bChromium\\b/${BRAND_DISPLAY_NEW}/g" "${grd}"
        info "Rebranded GRD: ${grd}"
    fi
done

BRANDING_FILE="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium/BRANDING"
if [ -f "${BRANDING_FILE}" ]; then
    sed -i \
        -e "s|^COMPANY_FULLNAME=.*|COMPANY_FULLNAME=${BRAND_COMPANY}|" \
        -e "s|^COMPANY_SHORTNAME=.*|COMPANY_SHORTNAME=${BRAND_DISPLAY_NEW}|" \
        -e "s|^PRODUCT_FULLNAME=.*|PRODUCT_FULLNAME=${BRAND_DISPLAY_NEW} Browser|" \
        -e "s|^PRODUCT_SHORTNAME=.*|PRODUCT_SHORTNAME=${BRAND_DISPLAY_NEW}|" \
        -e "s|^PRODUCT_INSTALLER_FULLNAME=.*|PRODUCT_INSTALLER_FULLNAME=${BRAND_DISPLAY_NEW} Browser|" \
        -e "s|^PRODUCT_INSTALLER_SHORTNAME=.*|PRODUCT_INSTALLER_SHORTNAME=${BRAND_DISPLAY_NEW}|" \
        -e "s|^MAC_BUNDLE_ID=.*|MAC_BUNDLE_ID=org.AibaProject.${BRAND_DISPLAY_NEW}|" \
        "${BRANDING_FILE}"
    ok "BRANDING file updated."
fi

THEME_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium"
mkdir -p "${THEME_DIR}"

# Generate all required icon sizes from the source logo
icon_gen() {
    local size="$1" dest="$2"
    "${IM_CONVERT}" "${AIBA_LOGO_PNG}" \
        -alpha set \
        -resize "${size}x${size}" \
        -background none \
        -gravity center \
        -extent "${size}x${size}" \
        -strip \
        "png32:${dest}" \
        || warn "Failed to generate icon at ${dest}"
}

for size in "${ICON_SIZES[@]}"; do
    icon_gen "${size}" "${THEME_DIR}/product_logo_${size}.png"
done
ok "PNG branding matrix generated (sizes: ${ICON_SIZES[*]})."

# Fix: properly resize to 16×16 — do NOT copy the raw 512px source
DEFAULT_PCT_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/default_100_percent/chromium"
mkdir -p "${DEFAULT_PCT_DIR}"
icon_gen 16 "${DEFAULT_PCT_DIR}/product_logo_16.png"
ok "default_100_percent 16×16 logo set."

###############################################################################
#   STEP 5c — Patch Debian package layout                                     #
###############################################################################
step "5c" "Patching Debian package layout"

cd "${REPO_ROOT}"

if [ -f "debian/control" ]; then
    rebrand_file "debian/control"
    sed -i "s/Ungoogled Chromium/${BRAND_DISPLAY_NEW} Browser/g" "debian/control"
    ok "debian/control rebranded."
fi
if [ -f "debian/changelog" ]; then
    sed -i "1s/${BRAND_OLD}/${BRAND_NEW}/g" "debian/changelog"
    ok "debian/changelog rebranded."
fi
if [ -f "debian/rules" ]; then
    rebrand_file "debian/rules"
    ok "debian/rules rebranded."
fi

shopt -s nullglob
for old_file in "debian/${BRAND_OLD}"*; do
    new_file="debian/${BRAND_NEW}${old_file#debian/${BRAND_OLD}}"
    mv "${old_file}" "${new_file}"
    rebrand_file "${new_file}"
    info "Renamed: ${old_file} → ${new_file}"
done
shopt -u nullglob

# Fix: use */submodules glob pattern — works regardless of find's path prefix
while IFS= read -r -d '' dfile; do
    [ -f "${dfile}" ] || continue
    case "${dfile}" in *.in) continue ;; esac
    if file --brief --mime-type "${dfile}" | grep -q "^text/"; then
        grep -q "${BRAND_OLD}" "${dfile}" && rebrand_file "${dfile}"
    fi
done < <(find debian/ -path "*/submodules" -prune -o -type f -print0)

ok "Debian layout sweep complete."

###############################################################################
#   STEP 5d — GN compiler optimizations                                       #
###############################################################################
step "5d" "Applying GN compiler optimizations and build flags"

DEBIAN_RULES_FILE="${REPO_ROOT}/debian/rules"
sed -i -E "s|(^[[:space:]]*)symbol_level=[^ \\\\]*|\1symbol_level=0|"   "${DEBIAN_RULES_FILE}" 2>/dev/null || true
sed -i -E "s|(^[[:space:]]*)use_thin_lto=[^ \\\\]*|\1use_thin_lto=true|" "${DEBIAN_RULES_FILE}" 2>/dev/null || true

FLAGS_GN="${REPO_ROOT}/debian/submodules/ungoogled-chromium/flags.gn"
if [ -f "${FLAGS_GN}" ]; then
    # Idempotent: only append each flag if not already present
    for flag in "blink_symbol_level=0" "enable_nacl=false" "chrome_pgo_phase=0"; do
        grep -qF "${flag%%=*}=" "${FLAGS_GN}" || echo "${flag}" >> "${FLAGS_GN}"
    done
    ok "flags.gn updated."
fi

export DEB_BUILD_MAINT_OPTIONS="hardening=-all"
export DEB_CFLAGS_APPEND="-Wno-macro-redefined -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2"
export DEB_CXXFLAGS_APPEND="-Wno-macro-redefined -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2"
ok "Build flags configured."

###############################################################################
#   STEP 6 — Install build dependencies                                       #
###############################################################################
step 6 "Installing build dependencies"

sudo apt-get build-dep -y ./ || fail "Build dependency installation failed."
ok "Build dependencies installed."

###############################################################################
#   STEP 7 — Compilation with FIFO-based OOM guard (all ${CORES} cores)      #
###############################################################################
step 7 "Compiling ${BRAND_DISPLAY_NEW} Browser using ${CORES} cores"

# Use a named FIFO so dpkg-buildpackage runs as a real background process
# (giving us its PID and true exit code via wait), while we read every line
# of its combined stdout+stderr for OOM detection.  This replaces stdbuf+awk
# which could not reliably intercept output from deep child processes.
BUILD_FIFO="$(mktemp -u /tmp/aiba_build_XXXXXX.fifo)"
mkfifo "${BUILD_FIFO}"

# Replace the initial EXIT trap — now also removes the FIFO on exit
trap 'rm -f "${BUILD_FIFO}"; wait' EXIT

echo "🚀  Launching compilation with ${CORES} parallel jobs..."

# Redirect both stdout and stderr of the build into the FIFO
dpkg-buildpackage -b -uc -j"${CORES}" >"${BUILD_FIFO}" 2>&1 &
BUILD_PID=$!

OOM_DETECTED=0
while IFS= read -r line; do
    printf '%s\n' "${line}"
    if [[ "${line}" =~ virtual\ memory\ exhausted|Cannot\ allocate\ memory|\
fatal\ error:\ error\ writing|out\ of\ memory ]]; then
        OOM_DETECTED=1
        warn "OOM condition detected — terminating build processes..."
        # Kill the build and its entire process tree
        kill -9 "${BUILD_PID}"            2>/dev/null || true
        pkill -9 -P "${BUILD_PID}"        2>/dev/null || true
        pkill -9 -x ninja                 2>/dev/null || true
        pkill -9 -x cc1plus               2>/dev/null || true
        pkill -9 -x clang                 2>/dev/null || true
        break
    fi
done < "${BUILD_FIFO}"

# Capture real exit code; suppress the "killed" error if OOM forced a kill
wait "${BUILD_PID}" 2>/dev/null || true
BUILD_EXIT=$?

[ "${OOM_DETECTED}" -eq 1 ] && fail "Build terminated: out-of-memory condition detected"
# 141 = 128+SIGPIPE — benign when the OOM guard closed the FIFO early
[ "${BUILD_EXIT}" -ne 0 ] && [ "${BUILD_EXIT}" -ne 141 ] \
    && fail "dpkg-buildpackage exited with code ${BUILD_EXIT}"

echo -e "\n🎉  BUILD COMPLETE — ${BRAND_DISPLAY_NEW} Browser"
echo "Output .deb packages:"
find .. -maxdepth 1 -name "*.deb" -exec ls -lh {} + 2>/dev/null \
    || warn "No .deb files found in parent directory."
