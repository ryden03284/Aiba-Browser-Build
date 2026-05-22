#!/usr/bin/env bash
# Aiba — build via official ungoogled-chromium-debian packaging (.deb)
set -euo pipefail

AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEBIAN_REPO_URL="https://github.com/ungoogled-software/ungoogled-chromium-debian.git"
DEBIAN_DIR="${AIBA_ROOT}/ungoogled-chromium-debian"
VENV="${AIBA_ROOT}/.venv"
BRANDING_DIR="${AIBA_ROOT}/branding"
PATCHES_DIR="${BRANDING_DIR}/patches"
UC_UTILS="${DEBIAN_DIR}/debian/submodules/ungoogled-chromium/utils"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "==> $*"; }

ensure_venv() {
  if [[ ! -d "${VENV}/bin" ]]; then
    step "Creating Python .venv (PEP 668 safe; no system pip)"
    python3 -m venv "${VENV}" 2>/dev/null \
      || die "Could not create .venv — install: sudo apt install python3-venv python3-full"
  fi
  if ! "${VENV}/bin/python3" -c "import PIL" 2>/dev/null; then
    step "Installing Pillow into .venv"
    "${VENV}/bin/pip" install --upgrade pip
    "${VENV}/bin/pip" install -r "${AIBA_ROOT}/requirements.txt" \
      || die "Failed to install Pillow into .venv"
  fi
  cat > "${AIBA_ROOT}/.aiba_env.sh" <<EOF
export AIBA_PYTHON="${VENV}/bin/python3"
export AIBA_ROOT="${AIBA_ROOT}"
EOF
}

# --- prerequisites ---
step "Checking prerequisites"
ensure_venv
PYTHON="${VENV}/bin/python3"

for cmd in git python3 patch curl unzip dpkg-buildpackage mk-build-deps; do
  command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd} — run: sudo apt install devscripts equivs git curl unzip patch"
done

# --- clone debian packaging repo ---
step "Ensuring ungoogled-chromium-debian repository"
if [[ ! -d "${DEBIAN_DIR}/.git" ]]; then
  git clone "${DEBIAN_REPO_URL}" "${DEBIAN_DIR}" || die "Failed to clone ${DEBIAN_REPO_URL}"
else
  echo "Repository already present: ${DEBIAN_DIR}"
fi

cd "${DEBIAN_DIR}"
[[ -f debian/rules ]] || die "debian/rules missing — clone/submodule failure?"

#step "Updating git submodules"
#git submodule update --init --recursive || die "git submodule update failed"

# --- official source preparation ---
if [[ -f "debian/stamp/setup" || -d "src" ]]; then
  step "Source files already prepared! Skipping unpack and clean..."
else
  step "Preparing local Chromium source (debian/rules setup)"
  debian/rules setup || die "debian/rules setup failed"
fi

# Chromium tree root = packaging repo root after setup
export AIBA_CHROMIUM_SRC="${DEBIAN_DIR}"

# --- Aiba branding (after unpack, before package build) ---
if [[ -f "debian/stamp/setup" || -d "src" ]]; then
  step "Source already branded. Skipping patch injection..."
else
  step "Injecting Aiba product logos"
  "${PYTHON}" "${BRANDING_DIR}/inject_logo.py" || die "inject_logo.py failed"                                            

  step "Applying Aiba BRANDING patch"
  [[ -f "${UC_UTILS}/patches.py" ]] || die "ungoogled-chromium utils not found — submodules incomplete?"
  python3 "${UC_UTILS}/patches.py" apply "${DEBIAN_DIR}" "${PATCHES_DIR}" \
    || die "Failed to apply Aiba branding patches"
fi

step "Patching UI strings (Chromium -> Aiba)"
AIBA_SKIP_LOGO=1 "${PYTHON}" "${BRANDING_DIR}/setup_aiba.py" || die "setup_aiba.py failed"

step "Installing uBlock Origin as default app"
"${AIBA_ROOT}/scripts/install_ublock_default_app.sh" "${DEBIAN_DIR}" "${PYTHON}" \
  || die "uBlock default app install failed"

step "Merging Aiba preferences into debian/initial_preferences"
"${PYTHON}" "${AIBA_ROOT}/scripts/apply_debian_prefs.py" "${DEBIAN_DIR}" \
  || die "apply_debian_prefs.py failed"

# --- install build-deps & compile .deb ---
step "Installing missing build dependencies (# mk-build-deps)"
#sudo  mk-build-deps -i debian/control -y || die "# mk-build-deps failed"
rm -f ../ungoogled-chromium-build-deps_* 2>/dev/null || true

step "Building Debian package (dpkg-buildpackage -b -uc)"
# Use low priority and limit parallelism for ~10GB RAM if not set in DEB_BUILD_OPTIONS
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-} parallel=4"
nice -n 19 dpkg-buildpackage -b -uc || die "dpkg-buildpackage failed"

step "Build complete"
DEB_OUT_DIR="$(dirname "${DEBIAN_DIR}")"
mapfile -t BUILT_DEBS < <(find "${DEB_OUT_DIR}" -maxdepth 1 -type f -name 'ungoogled-chromium_*.deb' ! -name '*build-deps*' 2>/dev/null | sort)

echo ""
if ((${#BUILT_DEBS[@]} == 0)); then
  echo "WARNING: No .deb found in ${DEB_OUT_DIR}"
  echo "  The build step may have failed — scroll up for errors."
  echo "  If you built elsewhere, run: find ~ -maxdepth 2 -name 'ungoogled-chromium_*.deb'"
else
  echo "Generated package(s) in ${DEB_OUT_DIR}:"
  printf '  %s\n' "${BUILT_DEBS[@]}"
  echo ""
  echo "Install (do NOT use a literal asterisk — use this script):"
  echo "  ${AIBA_ROOT}/scripts/install_deb.sh"
  echo ""
  echo "Or install the exact file:"
  echo "  sudo dpkg -i ${BUILT_DEBS[0]}"
fi
echo ""
echo "Binary after install: /usr/lib/chromium/chrome"
echo "Preferences: /usr/lib/chromium/initial_preferences"
