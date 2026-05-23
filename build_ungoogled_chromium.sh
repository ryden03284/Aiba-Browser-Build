#!/usr/bin/env bash
# =============================================================================
#  build_ungoogled_chromium.sh
#  Builds ungoogled-chromium-debian ("Aiba") with injected progress saves,
#  uBlock Origin Lite pre-bundled, and custom Aiba branding.
#
#  Designed for: GitHub Actions Ubuntu runner (or any Debian-based system)
#  Usage:        bash build_ungoogled_chromium.sh
#
#  Step order:
#    1  Install initial packages (devscripts, equivs)
#    2  Clone ungoogled-chromium-debian repo
#    3  Init submodules
#    4  debian/rules setup  (official source prep + tarball download)
#    5  Inject progress save archive
#    5a Bundle uBlock Origin Lite extension
#    5b Inject Aiba branding (name + logo)
#    6  Install build dependencies  (mk-build-deps)
#    7  dpkg-buildpackage -b -uc
# =============================================================================

set -euo pipefail          # Exit on error, unset var, or pipe failure
IFS=$'\n\t'                # Safer word splitting

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

step()  { echo -e "\n${CYAN}${BOLD}[STEP]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
info()  { echo -e "       $*"; }
die()   { echo -e "${RED}[FATAL]${RESET} $*" >&2; exit 1; }

# ── Configuration ─────────────────────────────────────────────────────────────
REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-debian.git"
REPO_DIR="ungoogled-chromium-debian"
PROGRESS_URL="https://filebin.net/aiba_build_1779451948/chromium_progress.tar.gz"
PROGRESS_ARCHIVE="progress.tar.gz"

# ── Branding configuration ────────────────────────────────────────────────────
#   AIBA_LOGO_PNG  →  path to YOUR PNG logo file (1024×1024 recommended).
#                     The script will convert it to all required ICO/ICNS sizes.
#                     ► Set this to wherever you store the asset in your repo or
#                       CI environment, e.g. "${GITHUB_WORKSPACE}/branding/aiba_logo.png"
AIBA_LOGO_PNG="${GITHUB_WORKSPACE:-$(pwd)}/aiba_logo.png"

# ── Extension configuration ───────────────────────────────────────────────────
UBLOL_EXT_ID="ddkjiahejlhfcafbddmgiahcphecmpfh"    # uBlock Origin Lite
# Chrome Web Store CRX download URL — prodversion just needs to be a plausible
# Chromium version so the store returns a CRX3 package.
UBLOL_CRX_URL="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=124.0.0.0&acceptformat=crx3&x=id%3D${UBLOL_EXT_ID}%26installsource%3Dondemand%26uc"

# ── Prerequisite: must be run from a writable working directory ───────────────
[[ -w "." ]] || die "Current directory is not writable: $(pwd)"

# =============================================================================
# STEP 1 — Install initial packages
# =============================================================================
step "1/7 · Installing initial packages: devscripts, equivs, imagemagick"

sudo apt-get update -qq
# imagemagick is added here so we can convert your PNG logo to all required
# icon formats (ICO, ICNS, various PNGs) during the branding step later.
sudo apt-get install -y devscripts equivs imagemagick

ok "Initial packages installed."

# =============================================================================
# STEP 2 — Clone repository (skip if already present)
# =============================================================================
step "2/7 · Cloning ungoogled-chromium-debian repository"

if [[ -d "${REPO_DIR}/.git" ]]; then
    warn "Repository directory '${REPO_DIR}' already exists — skipping clone."
    warn "To start fresh, delete the directory and re-run."
else
    git clone "${REPO_URL}" "${REPO_DIR}"
    ok "Repository cloned into '${REPO_DIR}'."
fi

cd "${REPO_DIR}"
ok "Working directory: $(pwd)"

# =============================================================================
# STEP 3 — Initialise submodules
# =============================================================================
step "3/7 · Initialising git submodules"

git submodule update --init --recursive

ok "Submodules initialised."

# =============================================================================
# STEP 4 — Official source preparation
# =============================================================================
step "4/7 · Running debian/rules setup (official source prep)"
info "This downloads the Chromium source tarball — may take a while."

debian/rules setup

ok "Source preparation complete."

# ── Locate the unpacked Chromium source tree ──────────────────────────────────
#   After 'debian/rules setup', ungoogled-chromium-debian unpacks the tarball
#   into a sibling directory named  chromium-<version>/  one level above us.
#   We detect it dynamically so the script survives version bumps.
CHROMIUM_SRC_DIR="$(find .. -maxdepth 1 -type d -name 'chromium-*' | sort | tail -n1)"
if [[ -z "${CHROMIUM_SRC_DIR}" ]]; then
    die "Could not find the unpacked Chromium source directory (chromium-*) in $(realpath ..). \
Did 'debian/rules setup' complete successfully?"
fi
ok "Chromium source tree found at: $(realpath "${CHROMIUM_SRC_DIR}")"

# =============================================================================
# STEP 5 — Inject progress/save archive
# =============================================================================
step "5/7 · Injecting build progress archive"
info "Downloading: ${PROGRESS_URL}"

curl \
    --location \
    --retry 5 \
    --retry-delay 10 \
    --retry-max-time 120 \
    --connect-timeout 30 \
    --progress-bar \
    --output "${PROGRESS_ARCHIVE}" \
    "${PROGRESS_URL}" \
  || die "Download failed. Check the Filebin URL and your network connection."

if ! tar -tzf "${PROGRESS_ARCHIVE}" &>/dev/null; then
    rm -f "${PROGRESS_ARCHIVE}"
    die "Downloaded file is not a valid gzip-compressed tar archive. Aborting."
fi

info "Extracting archive one level up (into workspace root) to avoid nesting…"
# Archive was packed from the workspace root and contains the
# 'ungoogled-chromium-debian/' path prefix, so -C .. lands it correctly.
tar -xf "${PROGRESS_ARCHIVE}" -C ..

rm -f "${PROGRESS_ARCHIVE}"
ok "Progress archive injected and cleaned up."

# =============================================================================
# STEP 5a — Bundle uBlock Origin Lite
# =============================================================================
step "5a/7 · Bundling uBlock Origin Lite (${UBLOL_EXT_ID})"
#
# Chromium supports a 'default_extensions' directory.  Any .crx placed here
# alongside a matching <id>.json external-extension manifest will be silently
# installed for every new profile — exactly what pre-bundled extensions do in
# Brave, Vivaldi, etc.
#
# Layout we are creating inside the Chromium source tree:
#   <chromium-src>/chrome/browser/extensions/default_extensions/
#       ddkjiahejlhfcafbddmgiahcphecmpfh.crx   ← the extension package
#       ddkjiahejlhfcafbddmgiahcphecmpfh.json  ← external-extension manifest
#
# References:
#   https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/
#       extensions/default_extensions/
#   https://developer.chrome.com/docs/extensions/mv3/external_extensions/

DEFAULT_EXT_DIR="${CHROMIUM_SRC_DIR}/chrome/browser/extensions/default_extensions"
mkdir -p "${DEFAULT_EXT_DIR}"

# ── 5a-i  Download the CRX ───────────────────────────────────────────────────
info "Downloading uBlock Origin Lite CRX from Chrome Web Store…"
curl \
    --location \
    --retry 5 \
    --retry-delay 5 \
    --retry-max-time 60 \
    --connect-timeout 20 \
    --progress-bar \
    --output "${DEFAULT_EXT_DIR}/${UBLOL_EXT_ID}.crx" \
    "${UBLOL_CRX_URL}" \
  || die "Failed to download uBlock Origin Lite CRX."

# Basic sanity check — CRX3 files start with the magic bytes 'Cr24'
if ! head -c4 "${DEFAULT_EXT_DIR}/${UBLOL_EXT_ID}.crx" | grep -q 'Cr24'; then
    die "Downloaded file does not look like a valid CRX3 package (missing 'Cr24' header). \
The Chrome Web Store URL may have changed — check UBLOL_CRX_URL."
fi

# ── 5a-ii  Write the external-extension manifest ─────────────────────────────
# This JSON tells Chromium to install the CRX for every new profile.
# 'external_crx' points to the .crx we just downloaded (relative to the
# default_extensions directory at runtime — use an absolute path here so it
# resolves correctly during the build).
cat > "${DEFAULT_EXT_DIR}/${UBLOL_EXT_ID}.json" << JSON_EOF
{
  "external_crx": "${DEFAULT_EXT_DIR}/${UBLOL_EXT_ID}.crx",
  "external_version": "0.0.0.0"
}
JSON_EOF
# NOTE: "external_version": "0.0.0.0" is a sentinel that tells Chromium to
# always accept whatever version is inside the .crx without a version check.

ok "uBlock Origin Lite CRX and manifest written to default_extensions/."

# ── 5a-iii  Register the extension in the Chromium build system ──────────────
#
# The default_extensions directory must be listed in the GN build graph so
# the .crx files are copied into the final output.  The relevant GYP/GN file
# is:  chrome/browser/extensions/default_extensions/BUILD.gn
#
# If that file already has a 'copy' rule for .crx files, your new file will
# be picked up automatically.  If not, append a rule here.
#
BUILD_GN="${CHROMIUM_SRC_DIR}/chrome/browser/extensions/default_extensions/BUILD.gn"
if [[ -f "${BUILD_GN}" ]]; then
    if ! grep -q "${UBLOL_EXT_ID}" "${BUILD_GN}"; then
        warn "Extension ID not found in BUILD.gn — you may need to add it manually."
        warn "File: ${BUILD_GN}"
        warn "Add '\"${UBLOL_EXT_ID}.crx\"' and '\"${UBLOL_EXT_ID}.json\"' to the"
        warn "appropriate copy() rule in that file."
    else
        ok "Extension ID already referenced in BUILD.gn — no edit needed."
    fi
else
    warn "BUILD.gn not found at expected path. Chromium version may differ."
    warn "Verify that the default_extensions directory is included in the GN build."
fi

# =============================================================================
# STEP 5b — Inject Aiba branding
# =============================================================================
step "5b/7 · Injecting Aiba branding (name + logo)"
#
# Chromium keeps its user-visible brand strings in two GRD (XML) files:
#   1. chrome/app/chromium_strings.grd          ← most UI strings ("Chromium")
#   2. components/strings/components_chromium_strings.grd  ← component strings
#
# We rename "Chromium" → "Aiba" throughout both.  We deliberately leave
# internal code symbols, URLs, and file paths alone (only replacing the
# display-facing product name).
#
# Icon assets live in:
#   chrome/app/theme/chromium/          ← all sizes of the app icon (PNG + ICO)
#   chrome/app/theme/chromium/BRANDING  ← plaintext branding metadata file
#
# We replace those icons with resized versions of your AIBA_LOGO_PNG.

# ── 5b-i  Verify the logo source file exists ─────────────────────────────────
info "Logo source file: ${AIBA_LOGO_PNG}"
if [[ ! -f "${AIBA_LOGO_PNG}" ]]; then
    # ▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼▼
    # PLACEHOLDER — supply the logo before running the script.
    # Set AIBA_LOGO_PNG (at the top of this script) to the absolute path of
    # your aiba_logo.png file.  In GitHub Actions you can do this via:
    #
    #   cp path/to/aiba_logo.png "${GITHUB_WORKSPACE}/aiba_logo.png"
    #
    # The script will then pick it up automatically.
    # ▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲▲
    die "Aiba logo not found at: ${AIBA_LOGO_PNG}
Set AIBA_LOGO_PNG at the top of this script to the correct path."
fi

# ── 5b-ii  Rename "Chromium" → "Aiba" in brand string files ─────────────────
CHROMIUM_STRINGS_GRD="${CHROMIUM_SRC_DIR}/chrome/app/chromium_strings.grd"
COMPONENTS_STRINGS_GRD="${CHROMIUM_SRC_DIR}/components/strings/components_chromium_strings.grd"

for GRD_FILE in "${CHROMIUM_STRINGS_GRD}" "${COMPONENTS_STRINGS_GRD}"; do
    if [[ -f "${GRD_FILE}" ]]; then
        info "Patching: ${GRD_FILE}"
        # Back up the original before modifying
        cp "${GRD_FILE}" "${GRD_FILE}.bak"
        # Replace display-name references only:
        #   "Chromium"        → "Aiba"          (display name)
        #   "chromium"        → "aiba"           (lowercase variant in URLs/IDs
        #                                         is intentionally left alone;
        #                                         only in <message> text nodes)
        # We use a word-boundary (\b) approach via perl for accuracy.
        perl -i -pe '
            # Only replace inside XML message content, not tag attributes or
            # internal identifiers.  This regex replaces the word "Chromium"
            # when it appears as a standalone word in text content.
            s/\bChromium\b/Aiba/g;
        ' "${GRD_FILE}"
        ok "Patched: $(basename "${GRD_FILE}")"
    else
        warn "GRD file not found (version mismatch?): ${GRD_FILE}"
        warn "You may need to patch branding strings manually for this Chromium version."
    fi
done

# ── 5b-iii  Patch the BRANDING metadata file ─────────────────────────────────
#   This plaintext file defines SHORT_NAME, PRODUCT_NAME, etc. used by the
#   build system itself (e.g. for .desktop file generation on Linux).
BRANDING_FILE="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium/BRANDING"
if [[ -f "${BRANDING_FILE}" ]]; then
    info "Patching BRANDING file: ${BRANDING_FILE}"
    cp "${BRANDING_FILE}" "${BRANDING_FILE}.bak"
    sed -i \
        -e 's/\bCHROMIUM\b/AIBA/g' \
        -e 's/\bChromium\b/Aiba/g' \
        "${BRANDING_FILE}"
    ok "BRANDING file patched."
else
    warn "BRANDING file not found: ${BRANDING_FILE}"
fi

# ── 5b-iv  Generate icon assets from your PNG logo ───────────────────────────
#   Chromium needs icons in these exact sizes (all square PNGs), plus an ICO
#   for Windows and an ICNS for macOS.  We generate them all from AIBA_LOGO_PNG
#   using ImageMagick (installed in Step 1).
#
ICON_DIR="${CHROMIUM_SRC_DIR}/chrome/app/theme/chromium"
mkdir -p "${ICON_DIR}"

info "Generating icon assets from ${AIBA_LOGO_PNG}…"

# PNG sizes required by the Chromium build for Linux/Windows
declare -a PNG_SIZES=(16 24 32 48 64 128 256)
for SIZE in "${PNG_SIZES[@]}"; do
    OUT="${ICON_DIR}/product_logo_${SIZE}.png"
    convert "${AIBA_LOGO_PNG}" \
        -resize "${SIZE}x${SIZE}" \
        -background none \
        -gravity center \
        -extent "${SIZE}x${SIZE}" \
        "${OUT}"
    info "  → product_logo_${SIZE}.png"
done

# Windows ICO (multi-size bundle: 16, 32, 48, 256)
convert "${AIBA_LOGO_PNG}" \
    \( -clone 0 -resize 16x16   \) \
    \( -clone 0 -resize 32x32   \) \
    \( -clone 0 -resize 48x48   \) \
    \( -clone 0 -resize 256x256 \) \
    -delete 0 \
    "${ICON_DIR}/chromium.ico"      # keep filename; build system references it by name
info "  → chromium.ico (16/32/48/256 multi-size)"

# macOS ICNS — ImageMagick can produce a basic ICNS; for a production build
# you may want to use 'iconutil' on a Mac for the best result.
convert "${AIBA_LOGO_PNG}" \
    -resize 1024x1024 \
    "${ICON_DIR}/app.icns" 2>/dev/null \
  || warn "ICNS generation skipped (ImageMagick on this host may not support ICNS). \
           Provide a hand-crafted app.icns for macOS builds."
info "  → app.icns"

ok "All icon assets generated in ${ICON_DIR}."

# ── 5b-v  Patch the .desktop template (Linux app menu entry) ─────────────────
#   The .desktop file determines what label appears in the application launcher.
DESKTOP_TEMPLATE="${CHROMIUM_SRC_DIR}/chrome/installer/linux/common/desktop.template"
if [[ -f "${DESKTOP_TEMPLATE}" ]]; then
    info "Patching .desktop template…"
    cp "${DESKTOP_TEMPLATE}" "${DESKTOP_TEMPLATE}.bak"
    sed -i \
        -e 's/\bChromium\b/Aiba/g' \
        -e 's/\bCHROMIUM\b/AIBA/g' \
        "${DESKTOP_TEMPLATE}"
    ok ".desktop template patched."
else
    warn ".desktop template not found: ${DESKTOP_TEMPLATE}"
    warn "The Linux app-menu entry may still read 'Chromium'."
fi

# ── 5b-vi  Summary of what was changed ───────────────────────────────────────
echo ""
echo -e "       ${BOLD}Branding changes applied:${RESET}"
echo    "         • 'Chromium' → 'Aiba' in chromium_strings.grd"
echo    "         • 'Chromium' → 'Aiba' in components_chromium_strings.grd"
echo    "         • BRANDING metadata file updated"
echo    "         • Icon PNGs regenerated (16–256 px)"
echo    "         • chromium.ico regenerated (16/32/48/256)"
echo    "         • app.icns regenerated"
echo    "         • .desktop template updated"
echo ""
ok "Aiba branding injection complete."

# =============================================================================
# STEP 6 — Install build dependencies
# =============================================================================
step "6/7 · Installing missing build dependencies via mk-build-deps"

sudo mk-build-deps \
    --install \
    --tool "apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y" \
    debian/control

# Clean up the generated meta-package .deb (glob is safe: -f won't fail on no match)
rm -f ungoogled-chromium-build-deps_*.deb

ok "Build dependencies installed."

# =============================================================================
# STEP 7 — Build the packages
# =============================================================================
step "7/7 · Starting official build: dpkg-buildpackage -b -uc"
info "This is the long step — grab a coffee (or three)."

dpkg-buildpackage -b -uc

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Build complete!${RESET}"
echo -e "${GREEN}${BOLD}  Output .deb packages are in the parent directory:${RESET}"
ls -lh ../*.deb 2>/dev/null \
  || echo "  (no .deb files found in parent dir — check for build errors above)"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${RESET}"
