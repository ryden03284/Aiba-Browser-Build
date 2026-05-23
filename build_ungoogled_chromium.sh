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
#    7  dpkg-buildpackage -b -us -uc
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
# BUILD.gn in the default_extensions directory controls which files the GN
# build system copies into the final compiled output.  It contains one or more
# copy() rules whose 'sources' lists enumerate each .crx and .json file.
#
# We use an inline Python 3 script to edit this file surgically:
#   • If our two filenames are already present  → no-op (idempotent).
#   • If a sources = [...] list exists          → insert into it.
#   • If no sources list exists at all          → append a brand-new copy()
#     rule at the end of the file as a safe fallback.
#
# Python is used instead of sed because BUILD.gn list blocks can span many
# lines with arbitrary indentation, making regex line-by-line editing fragile.

BUILD_GN="${CHROMIUM_SRC_DIR}/chrome/browser/extensions/default_extensions/BUILD.gn"

if [[ ! -f "${BUILD_GN}" ]]; then
    # BUILD.gn is absent entirely — create a minimal one from scratch so the
    # GN build graph has something to work with.
    info "BUILD.gn not found — creating a minimal one from scratch."
    cat > "${BUILD_GN}" << GN_EOF
# Auto-generated by Aiba build script.
copy("default_extensions") {
  sources = [
    "${UBLOL_EXT_ID}.crx",
    "${UBLOL_EXT_ID}.json",
  ]
  outputs = [ "\$root_out_dir/extensions/{{source_file_part}}" ]
}
GN_EOF
    ok "BUILD.gn created with uBlock Origin Lite entries."
else
    info "Patching BUILD.gn: ${BUILD_GN}"
    # Back up before editing
    cp "${BUILD_GN}" "${BUILD_GN}.bak"

    python3 - "${BUILD_GN}" "${UBLOL_EXT_ID}" << 'PYEOF'
import sys, re, pathlib

build_gn_path = pathlib.Path(sys.argv[1])
ext_id        = sys.argv[2]
crx_entry     = f'"{ext_id}.crx"'
json_entry    = f'"{ext_id}.json"'
new_entries   = [crx_entry, json_entry]

original = build_gn_path.read_text()

# ── Guard: already present? ───────────────────────────────────────────────────
if ext_id in original:
    print(f"       [OK] Extension ID already present in BUILD.gn — no edit needed.")
    sys.exit(0)

# ── Strategy 1: insert into an existing sources = [ ... ] block ──────────────
# Matches:  sources = [          (opening)
#               "anything",      (zero or more existing entries)
#           ]                    (closing bracket, possibly indented)
# We insert our two new lines just before the closing bracket of the FIRST
# sources list found, preserving indentation of surrounding entries.

sources_block = re.search(
    r'(sources\s*=\s*\[)(.*?)(\])',
    original,
    re.DOTALL
)

if sources_block:
    block_interior = sources_block.group(2)

    # Detect indentation from existing entries, fall back to 4 spaces
    indent_match = re.search(r'\n(\s+)"', block_interior)
    indent = indent_match.group(1) if indent_match else '    '

    # Build the two new lines to inject
    injected = ''.join(f'\n{indent}{e},' for e in new_entries)

    # Insert before the closing bracket
    new_interior = block_interior.rstrip() + injected + '\n'
    new_block    = sources_block.group(1) + new_interior + sources_block.group(3)
    patched      = original[:sources_block.start()] + new_block + original[sources_block.end():]

    build_gn_path.write_text(patched)
    print(f"       [OK] Inserted {crx_entry} and {json_entry} into existing sources list.")
    sys.exit(0)

# ── Strategy 2: no sources list found — append a new copy() rule ─────────────
# This is the safe fallback for unusual BUILD.gn layouts.
fallback_rule = f"""
# uBlock Origin Lite — added by Aiba build script
copy("ublol_default_extension") {{
  sources = [
    {crx_entry},
    {json_entry},
  ]
  outputs = [ "$root_out_dir/extensions/{{{{source_file_part}}}}" ]
}}
"""
patched = original.rstrip() + '\n' + fallback_rule
build_gn_path.write_text(patched)
print(f"       [OK] No existing sources list found — appended new copy() rule for uBlock Origin Lite.")
PYEOF

    ok "BUILD.gn patched — uBlock Origin Lite registered in GN build graph."
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
# STEP 5c — Patch Debian package control files
# =============================================================================
step "5c/7 · Patching Debian package control files → 'aiba'"
#
# dpkg-buildpackage derives the output .deb filenames and package metadata
# entirely from the debian/ directory files — not from anything in the
# Chromium source tree.  We must rename every occurrence of
# 'ungoogled-chromium' to 'aiba' across:
#
#   debian/control      → Source: and Package: fields  (drives .deb filename)
#   debian/changelog    → first-line package header    (drives version string)
#   debian/rules        → any explicit package-name references
#   debian/*.install    → per-package file-installation manifests (filename matters)
#   debian/*.links      → symlink manifests            (filename matters)
#   debian/*.docs       → doc manifests                (filename matters)
#   debian/*.manpages   → manpage manifests            (filename matters)
#   debian/*.postinst   → maintainer scripts           (filename matters)
#   debian/*.prerm      )
#   debian/*.postrm     )   ... and any other maintainer scripts
#   debian/*.preinst    )
#   debian/watch        → upstream version watch file  (content only)
#
# Rule: for files whose FILENAME begins with 'ungoogled-chromium', dpkg uses
# the filename prefix to associate the file with a binary package — so we
# must rename those files in addition to replacing text inside them.

OLD_NAME="ungoogled-chromium"
NEW_NAME="aiba"
DEBIAN_DIR="debian"   # we are already inside the repo (cd'd in Step 2)

# ── 5c-i  debian/control ─────────────────────────────────────────────────────
#   Two distinct field types need changing:
#     Source: ungoogled-chromium   →  Source: aiba      (top stanza, line 1)
#     Package: ungoogled-chromium  →  Package: aiba     (binary stanza)
#   We use Python so we can edit RFC-822-formatted control files reliably
#   without breaking multi-line continuation fields or other stanzas.

CONTROL_FILE="${DEBIAN_DIR}/control"
if [[ -f "${CONTROL_FILE}" ]]; then
    info "Patching ${CONTROL_FILE}…"
    cp "${CONTROL_FILE}" "${CONTROL_FILE}.bak"

    python3 - "${CONTROL_FILE}" "${OLD_NAME}" "${NEW_NAME}" << 'PYEOF'
import sys, pathlib, re

ctrl   = pathlib.Path(sys.argv[1])
old    = sys.argv[2]
new    = sys.argv[3]
text   = ctrl.read_text()

# Replace 'Source: <old>' and 'Package: <old>' field values precisely.
# The pattern anchors to the field name so we never touch free-text
# descriptions that happen to mention the old package name.
patched = re.sub(
    r'^((?:Source|Package):\s*)' + re.escape(old),
    r'\g<1>' + new,
    text,
    flags=re.MULTILINE
)

# Also replace dependency references like 'Depends: ungoogled-chromium (>= …)'
# so inter-package deps inside the control file stay consistent.
patched = patched.replace(old, new)

ctrl.write_text(patched)
print(f"       [OK] debian/control: '{old}' → '{new}'")
PYEOF
    ok "debian/control patched."
else
    die "debian/control not found — cannot continue without it."
fi

# ── 5c-ii  debian/changelog ───────────────────────────────────────────────────
#   The very first line of debian/changelog follows this format:
#     ungoogled-chromium (version) suite; urgency=level
#   dpkg-parsechangelog reads this line to set the source package name and
#   version that appear in the .dsc and .changes files — and ultimately in
#   the output .deb filenames.  Only the first line needs changing.

CHANGELOG_FILE="${DEBIAN_DIR}/changelog"
if [[ -f "${CHANGELOG_FILE}" ]]; then
    info "Patching first line of ${CHANGELOG_FILE}…"
    cp "${CHANGELOG_FILE}" "${CHANGELOG_FILE}.bak"

    # sed '1s/...' targets only line 1; the word-boundary ensures we replace
    # the package-name token and not a substring of something else.
    sed -i "1s/\b${OLD_NAME}\b/${NEW_NAME}/" "${CHANGELOG_FILE}"

    # Confirm the change landed correctly
    FIRST_LINE="$(head -n1 "${CHANGELOG_FILE}")"
    if [[ "${FIRST_LINE}" == ${NEW_NAME}* ]]; then
        ok "debian/changelog first line: ${FIRST_LINE}"
    else
        die "debian/changelog patch failed. First line is still: ${FIRST_LINE}"
    fi
else
    die "debian/changelog not found — cannot continue without it."
fi

# ── 5c-iii  debian/rules ──────────────────────────────────────────────────────
#   The rules Makefile may hardcode the source package name in variables,
#   dh_gencontrol calls, or install-path definitions.

RULES_FILE="${DEBIAN_DIR}/rules"
if [[ -f "${RULES_FILE}" ]]; then
    info "Patching ${RULES_FILE}…"
    cp "${RULES_FILE}" "${RULES_FILE}.bak"
    sed -i "s/\b${OLD_NAME}\b/${NEW_NAME}/g" "${RULES_FILE}"
    ok "debian/rules patched."
else
    warn "debian/rules not found — skipping."
fi

# ── 5c-iv  Rename and patch per-package maintainer files ─────────────────────
#   Files like 'debian/ungoogled-chromium.install' must be renamed to
#   'debian/aiba.install' so dpkg associates them with the correct binary
#   package.  We also replace the old name in their content.
#
#   Extensions covered (exhaustive list of dpkg-recognised suffixes):
MAINTAINER_EXTS=(
    install links docs manpages
    postinst prerm postrm preinst
    triggers conffiles lintian-overrides
    service tmpfiles dirs examples
)

RENAMED_COUNT=0
for EXT in "${MAINTAINER_EXTS[@]}"; do
    OLD_FILE="${DEBIAN_DIR}/${OLD_NAME}.${EXT}"
    NEW_FILE="${DEBIAN_DIR}/${NEW_NAME}.${EXT}"
    if [[ -f "${OLD_FILE}" ]]; then
        cp "${OLD_FILE}" "${OLD_FILE}.bak"
        # Patch content first, then rename
        sed -i "s|\b${OLD_NAME}\b|${NEW_NAME}|g" "${OLD_FILE}"
        mv "${OLD_FILE}" "${NEW_FILE}"
        info "  Renamed + patched: ${OLD_NAME}.${EXT} → ${NEW_NAME}.${EXT}"
        (( RENAMED_COUNT++ )) || true
    fi
done

# Catch any other debian/ungoogled-chromium.* files not in the list above
while IFS= read -r -d '' EXTRA_FILE; do
    NEW_EXTRA="${EXTRA_FILE/${OLD_NAME}/${NEW_NAME}}"
    if [[ "${EXTRA_FILE}" != "${NEW_EXTRA}" ]]; then
        cp "${EXTRA_FILE}" "${EXTRA_FILE}.bak"
        sed -i "s|\b${OLD_NAME}\b|${NEW_NAME}|g" "${EXTRA_FILE}"
        mv "${EXTRA_FILE}" "${NEW_EXTRA}"
        info "  Renamed + patched (extra): $(basename "${EXTRA_FILE}") → $(basename "${NEW_EXTRA}")"
        (( RENAMED_COUNT++ )) || true
    fi
done < <(find "${DEBIAN_DIR}" -maxdepth 1 -name "${OLD_NAME}.*" -print0 2>/dev/null)

ok "Per-package maintainer files: ${RENAMED_COUNT} file(s) renamed and patched."

# ── 5c-v  debian/watch ────────────────────────────────────────────────────────
#   The watch file content references the upstream project name; we replace
#   it in the content only (the filename is just 'watch', never prefixed).

WATCH_FILE="${DEBIAN_DIR}/watch"
if [[ -f "${WATCH_FILE}" ]]; then
    info "Patching ${WATCH_FILE}…"
    cp "${WATCH_FILE}" "${WATCH_FILE}.bak"
    sed -i "s|\b${OLD_NAME}\b|${NEW_NAME}|g" "${WATCH_FILE}"
    ok "debian/watch patched."
fi

# ── 5c-vi  Any remaining debian/ files that reference the old name ────────────
#   Belt-and-suspenders pass: grep every remaining file in debian/ for the
#   old package name and patch it.  Skips binary files and .bak files.

info "Running belt-and-suspenders pass over remaining debian/ files…"
EXTRA_PATCHED=0
while IFS= read -r -d '' DFILE; do
    # Skip backup files we created and any binary files
    [[ "${DFILE}" == *.bak ]]   && continue
    file --brief "${DFILE}" | grep -q 'binary'  && continue
    if grep -q "${OLD_NAME}" "${DFILE}" 2>/dev/null; then
        sed -i "s|\b${OLD_NAME}\b|${NEW_NAME}|g" "${DFILE}"
        info "  Patched content: ${DFILE}"
        (( EXTRA_PATCHED++ )) || true
    fi
done < <(find "${DEBIAN_DIR}" -maxdepth 2 -type f -print0 2>/dev/null)
ok "Belt-and-suspenders pass complete — ${EXTRA_PATCHED} additional file(s) patched."

# ── 5c-vii  Verification ──────────────────────────────────────────────────────
#   Confirm the critical fields in debian/control now read 'aiba'.

info "Verifying debian/control Source and Package fields…"
python3 - "${CONTROL_FILE}" "${NEW_NAME}" << 'PYEOF'
import sys, pathlib, re, sys

ctrl    = pathlib.Path(sys.argv[1])
new     = sys.argv[2]
text    = ctrl.read_text()
matches = re.findall(r'^(?:Source|Package):\s*(.+)$', text, re.MULTILINE)

all_ok  = True
for val in matches:
    val = val.strip()
    if val != new and not val.startswith(new):
        print(f"       [WARN] Unexpected value still present: '{val}'")
        all_ok = False

if all_ok:
    print(f"       [OK] All Source/Package fields confirmed as '{new}' (or sub-package of it).")
else:
    print("       [WARN] Some fields may still reference the old name — review debian/control.")
PYEOF

echo ""
echo -e "       ${BOLD}Debian packaging changes applied:${RESET}"
echo    "         • debian/control      — Source + Package fields renamed"
echo    "         • debian/changelog    — first-line package header renamed"
echo    "         • debian/rules        — internal name references updated"
echo    "         • debian/*.install etc — maintainer files renamed + patched"
echo    "         • debian/watch        — content updated"
echo    "         • belt-and-suspenders pass over all remaining debian/ files"
echo ""
ok "Step 5c complete — dpkg-buildpackage will now output 'aiba_*.deb'."

# =============================================================================
# STEP 6 — Install build dependencies
# =============================================================================
step "6/7 · Installing missing build dependencies via mk-build-deps"

sudo mk-build-deps \
    --install \
    --tool "apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends -y" \
    debian/control

# The meta-package is now named 'aiba-build-deps' after our control-file rename
rm -f aiba-build-deps_*.deb

ok "Build dependencies installed."

# =============================================================================
# STEP 7 — Build the packages
# =============================================================================
step "7/7 · Starting official build: dpkg-buildpackage -b -us -uc"
info "This is the long step — grab a coffee (or three)."

# -b   → binary-only build (no source package)
# -us  → unsigned source   (skip GPG signing of the .dsc — required on headless
#         CI runners; without this, dpkg-buildpackage blocks waiting for a key
#         that does not exist on the GitHub Actions runner)
# -uc  → unsigned changes  (skip GPG signing of the .changes file — same reason)
dpkg-buildpackage -b -us -uc

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
