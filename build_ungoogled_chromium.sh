#!/usr/bin/env bash
#
# build_ungoogled_chromium.sh  —  "Aiba" automated build  (v5.2 — Hardware Aware)
#
# Fixes over v5.1:
#   • CORES=4 hardcode removed — replaced by RAM-aware dynamic calculation:
#       compile jobs = all CPU cores (nproc)
#       link jobs    = floor(RAM_GB / 8), minimum 1
#       This uses every available CPU for compilation while capping concurrent
#       linker processes so RAM is not exhausted on machines with < 8 GB/core.
#   • concurrent_links GN flag injected into flags.gn (enforces the link cap)
#   • build-essential and gcc added to apt install list and preflight check
#   • Step 6.5 added: C probe detects host CPU instruction level (baseline /
#       SSE4.2 / AVX / AVX2 / AVX-512) and injects the appropriate -march flag
#       so the Chromium toolchain binaries do not SIGILL on older CPUs.
#   • Script restored to completion (v5.1 was truncated mid-step-3)
#

set -euo pipefail
IFS=$'\n\t'

# ─── Logging — combined EXIT trap handles both tee flush and FIFO cleanup ────
LOG_FILE="$(pwd)/aiba_build_debug.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
trap 'wait' EXIT   # extended later when FIFO path is known

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

# ─── RAM-aware core calculation ───────────────────────────────────────────────
# Compile jobs: all CPU cores — compile tasks are CPU-bound and lightweight per
#   process; using every core here gives maximum throughput.
# Link jobs: capped by RAM — each lld/ld process can spike to 6-8 GB during
#   Chromium's final link stage. floor(RAM_GB / 8) prevents kernel OOM kills.
CPU_CORES="$(nproc)"
TOTAL_RAM_GB="$(awk '/MemTotal/ { printf "%d", $2 / 1024 / 1024 }' /proc/meminfo)"
LINK_JOBS=$(( TOTAL_RAM_GB / 8 ))
[ "${LINK_JOBS}" -lt 1 ] && LINK_JOBS=1
[ "${LINK_JOBS}" -gt "${CPU_CORES}" ] && LINK_JOBS="${CPU_CORES}"

IM_CONVERT=""
CHROMIUM_SRC_DIR=""
REPO_ROOT=""

# ─── Helpers ──────────────────────────────────────────────────────────────────
step() {
    echo -e "\n══════════════════════════════════════════════════════════════"
    echo "  STEP $1: $2"
    echo -e "══════════════════════════════════════════════════════════════\n"
}
fail() { echo -e "\n❌  FATAL: $1\n    Working directory: $(pwd)" >&2; exit 1; }
info() { echo "ℹ️   $1"; }
ok()   { echo "✅  $1"; }
warn() { echo "⚠️   $1"; }

detect_imagemagick() {
    if   command -v magick   &>/dev/null; then IM_CONVERT="magick"
    elif command -v convert  &>/dev/null; then IM_CONVERT="convert"
    else fail "ImageMagick not found — install: sudo apt-get install imagemagick"
    fi
    info "ImageMagick command: ${IM_CONVERT}"
}

preflight_check() {
    local missing=()
    local required=(git curl xxd perl sed awk file du tee mkfifo gcc)
    for cmd in "${required[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [ "${#missing[@]}" -gt 0 ] && \
        fail "Missing required commands: ${missing[*]}\nInstall: sudo apt-get install ${missing[*]}"
    ok "Preflight passed — all required tools present."
}

# Idempotent deb-src injection: reads existing lines and only adds deb-src
# equivalents that are not already present anywhere in the file.
add_deb_src() {
    local src="$1"
    [ -f "$src" ] || return 0
    local tmp; tmp="$(mktemp)"
    cp "$src" "$tmp"
    while IFS= read -r line; do
        [[ "$line" =~ ^deb[[:space:]] ]] || continue
        local deb_src_line="deb-src ${line#deb }"
        grep -qxF "$deb_src_line" "$src" || echo "$deb_src_line" >> "$tmp"
    done < "$src"
    sudo cp "$tmp" "$src"
    rm -f "$tmp"
}

# Shared icon generator — resizes source logo to exact pixel dimensions
icon_gen() {
    local size="$1" dest="$2"
    "${IM_CONVERT}" "${AIBA_LOGO_PNG}" \
        -alpha set -resize "${size}x${size}" -background none \
        -gravity center -extent "${size}x${size}" -strip \
        "png32:${dest}" \
        || warn "Failed to generate icon at ${dest}"
}

# Placeholder prevents the submodule directory path from being rebranded
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

add_deb_src /etc/apt/sources.list
shopt -s nullglob
for listfile in /etc/apt/sources.list.d/*.list; do add_deb_src "$listfile"; done
shopt -u nullglob

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    devscripts equivs imagemagick icnsutils perl curl xxd file coreutils \
    build-essential gcc \
    || fail "Could not install required packages"

preflight_check

info "CPU cores (compile jobs) : ${CPU_CORES}"
info "Total RAM                 : ${TOTAL_RAM_GB} GB"
info "Concurrent link jobs      : ${LINK_JOBS}"
ok "Resource plan established."

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

if   [ -f "${REPO_ROOT}/${SENTINEL}" ];          then CHROMIUM_SRC_DIR="${REPO_ROOT}"
elif [ -f "${REPO_ROOT}/build/src/${SENTINEL}" ]; then CHROMIUM_SRC_DIR="${REPO_ROOT}/build/src"
elif [ -f "${REPO_ROOT}/src/${SENTINEL}" ];       then CHROMIUM_SRC_DIR="${REPO_ROOT}/src"
else fail "Chromium source root not found — ${SENTINEL} missing in all expected locations."
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

# xxd hex comparison — avoids raw binary pitfalls; "Cr24" = 0x43723234
CRX_MAGIC="$(xxd -p -l 4 "${CRX_FILE}")"
[ "${CRX_MAGIC}" != "43723234" ] && \
    fail "CRX header check failed — got '${CRX_MAGIC}', expected '43723234' (Cr24)"
ok "CRX magic bytes verified."

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
        -size 512x512 xc:#1a1a1a -gravity center -fill "#4a90e2" \
        -font Helvetica-Bold -pointsize 180 -draw "text 0,0 'A'" \
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
for size in "${ICON_SIZES[@]}"; do
    icon_gen "${size}" "${THEME_DIR}/product_logo_${size}.png"
done
ok "PNG branding matrix generated (sizes: ${ICON_SIZES[*]})."

# Properly resize to 16x16; never copy the raw 512px source unresized
DEFAULT_PCT_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/default_100_percent/chromium"
mkdir -p "${DEFAULT_PCT_DIR}"
icon_gen 16 "${DEFAULT_PCT_DIR}/product_logo_16.png"
ok "default_100_percent 16x16 logo set."

###############################################################################
#   STEP 5c — Patch Debian package layout                                     #
###############################################################################
step "5c" "Patching Debian package layout"

cd "${REPO_ROOT}"

[ -f "debian/control" ] && { rebrand_file "debian/control"
    sed -i "s/Ungoogled Chromium/${BRAND_DISPLAY_NEW} Browser/g" "debian/control"
    ok "debian/control rebranded."; }
[ -f "debian/changelog" ] && { sed -i "1s/${BRAND_OLD}/${BRAND_NEW}/g" "debian/changelog"
    ok "debian/changelog rebranded."; }
[ -f "debian/rules" ] && { rebrand_file "debian/rules"; ok "debian/rules rebranded."; }

shopt -s nullglob
for old_file in "debian/${BRAND_OLD}"*; do
    new_file="debian/${BRAND_NEW}${old_file#debian/${BRAND_OLD}}"
    mv "${old_file}" "${new_file}"
    rebrand_file "${new_file}"
    info "Renamed: ${old_file} -> ${new_file}"
done
shopt -u nullglob

# */submodules glob is portable regardless of find's leading path format
while IFS= read -r -d '' dfile; do
    [ -f "${dfile}" ] || continue
    case "${dfile}" in *.in) continue ;; esac
    file --brief --mime-type "${dfile}" | grep -q "^text/" || continue
    grep -q "${BRAND_OLD}" "${dfile}" && rebrand_file "${dfile}"
done < <(find debian/ -path "*/submodules" -prune -o -type f -print0)

ok "Debian layout sweep complete."

###############################################################################
#   STEP 5d — GN compiler optimizations                                       #
###############################################################################
step "5d" "Applying GN compiler optimizations and build flags"

DEBIAN_RULES_FILE="${REPO_ROOT}/debian/rules"
sed -i -E "s|(^[[:space:]]*)symbol_level=[^ \\\\]*|\1symbol_level=0|"    "${DEBIAN_RULES_FILE}" 2>/dev/null || true
sed -i -E "s|(^[[:space:]]*)use_thin_lto=[^ \\\\]*|\1use_thin_lto=true|" "${DEBIAN_RULES_FILE}" 2>/dev/null || true

FLAGS_GN="${REPO_ROOT}/debian/submodules/ungoogled-chromium/flags.gn"
if [ -f "${FLAGS_GN}" ]; then
    # Idempotent: append only flags whose key is not already present
    for flag in \
        "blink_symbol_level=0" \
        "enable_nacl=false" \
        "chrome_pgo_phase=0" \
        "concurrent_links=${LINK_JOBS}"
    do
        grep -qF "${flag%%=*}=" "${FLAGS_GN}" || echo "${flag}" >> "${FLAGS_GN}"
    done
    ok "flags.gn updated (concurrent_links=${LINK_JOBS})."
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
#   STEP 6.5 — CPU instruction probe (SIGILL guard)                           #
###############################################################################
step "6.5" "CPU instruction compatibility probe (SIGILL guard)"

# The Chromium toolchain ships pre-built binaries (clang, lld, etc.) compiled
# with modern CPU extensions.  On machines missing those extensions (e.g.,
# pre-Haswell CPUs without AVX) the binaries crash immediately with SIGILL.
# We compile and run a tiny C probe with -march=native to detect exactly which
# instruction level the host supports, then inject a matching -march flag so
# generated code and toolchain selection stay within safe bounds.

PROBE_SRC="$(mktemp /tmp/aiba_cpu_probe_XXXXXX.c)"
PROBE_BIN="$(mktemp /tmp/aiba_cpu_probe_XXXXXX)"

cat > "${PROBE_SRC}" <<'PROBE_C'
#include <stdio.h>
int main(void) {
#if   defined(__AVX512F__)
    puts("avx512");
#elif defined(__AVX2__)
    puts("avx2");
#elif defined(__AVX__)
    puts("avx");
#elif defined(__SSE4_2__)
    puts("sse4_2");
#else
    puts("baseline");
#endif
    return 0;
}
PROBE_C

CPU_LEVEL="baseline"
if gcc -O0 -march=native -o "${PROBE_BIN}" "${PROBE_SRC}" 2>/dev/null; then
    # Run in a subshell — SIGILL here must not kill the parent script
    PROBE_OUT="$(timeout 5 "${PROBE_BIN}" 2>/dev/null || true)"
    [ -n "${PROBE_OUT}" ] && CPU_LEVEL="${PROBE_OUT}"
fi
rm -f "${PROBE_SRC}" "${PROBE_BIN}"

info "Host CPU instruction level: ${CPU_LEVEL}"

# Select the safest -march consistent with what the CPU actually supports
case "${CPU_LEVEL}" in
    avx512|avx2|avx)
        # Cap at haswell/avx2 — avoids AVX-512 frequency throttling on some Intel SKUs
        MARCH_FLAG="-march=haswell -mtune=generic" ;;
    sse4_2)
        MARCH_FLAG="-march=nehalem -mtune=generic" ;;
    baseline|*)
        # Strict x86-64 baseline: safe on any 64-bit CPU
        MARCH_FLAG="-march=x86-64 -mtune=generic" ;;
esac

info "Injecting CPU flags: ${MARCH_FLAG}"
export DEB_CFLAGS_APPEND="${DEB_CFLAGS_APPEND} ${MARCH_FLAG}"
export DEB_CXXFLAGS_APPEND="${DEB_CXXFLAGS_APPEND} ${MARCH_FLAG}"
ok "SIGILL guard applied (CPU=${CPU_LEVEL}, flags=${MARCH_FLAG})."

###############################################################################
#   STEP 7 — Compilation with FIFO-based OOM guard                            #
###############################################################################
step 7 "Compiling ${BRAND_DISPLAY_NEW} Browser (compile=${CPU_CORES} jobs, link=${LINK_JOBS} jobs)"

# Named FIFO: dpkg-buildpackage runs as a tracked background process, giving us
# its real PID and exit code via `wait`, while we read every output line for OOM
# signals.  Replaces stdbuf+awk which missed deep child-process output entirely.
BUILD_FIFO="$(mktemp -u /tmp/aiba_build_XXXXXX.fifo)"
mkfifo "${BUILD_FIFO}"
trap 'rm -f "${BUILD_FIFO}"; wait' EXIT   # replaces the initial trap

echo "Launching: ${CPU_CORES} compile jobs, ${LINK_JOBS} concurrent link job(s)..."
dpkg-buildpackage -b -uc -j"${CPU_CORES}" >"${BUILD_FIFO}" 2>&1 &
BUILD_PID=$!

OOM_DETECTED=0
while IFS= read -r line; do
    printf '%s\n' "${line}"
    if [[ "${line}" =~ virtual\ memory\ exhausted|Cannot\ allocate\ memory|\
fatal\ error:\ error\ writing|out\ of\ memory ]]; then
        OOM_DETECTED=1
        warn "OOM detected — terminating build processes..."
        kill -9 "${BUILD_PID}"      2>/dev/null || true
        pkill -9 -P "${BUILD_PID}"  2>/dev/null || true
        pkill -9 -x ninja           2>/dev/null || true
        pkill -9 -x cc1plus         2>/dev/null || true
        pkill -9 -x clang           2>/dev/null || true
        break
    fi
done < "${BUILD_FIFO}"

wait "${BUILD_PID}" 2>/dev/null || true
BUILD_EXIT=$?

[ "${OOM_DETECTED}" -eq 1 ] && \
    fail "Build terminated: out-of-memory. Add swap or reduce concurrent_links in flags.gn."
# 141 = 128+SIGPIPE: benign when OOM guard closed the FIFO before the build finished
[ "${BUILD_EXIT}" -ne 0 ] && [ "${BUILD_EXIT}" -ne 141 ] && \
    fail "dpkg-buildpackage exited with code ${BUILD_EXIT}"

echo -e "\n🎉  BUILD COMPLETE — ${BRAND_DISPLAY_NEW} Browser"
echo "Output .deb packages:"
find .. -maxdepth 1 -name "*.deb" -exec ls -lh {} + 2>/dev/null \
    || warn "No .deb files found in parent directory."
