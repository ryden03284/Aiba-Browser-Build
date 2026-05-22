#!/usr/bin/env bash
# One-time setup for Aiba source build (ninja + depot_tools + .venv).
set -euo pipefail

AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${AIBA_ROOT}/.venv"
DEPOT_TOOLS="${AIBA_ROOT}/depot_tools"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "==> $*"; }

step "Installing system packages (sudo required)"
sudo apt update
sudo apt install -y \
  git python3 python3-venv python3-full \
  patch curl unzip \
  build-essential pkg-config \
  ninja-build \
  || die "apt install failed"

step "Creating Python virtual environment at .venv"
if [[ ! -d "${VENV}" ]]; then
  python3 -m venv "${VENV}" || die "Failed to create venv"
fi
"${VENV}/bin/pip" install --upgrade pip
"${VENV}/bin/pip" install -r "${AIBA_ROOT}/requirements.txt"
echo "Pillow installed in ${VENV}"

step "Fetching depot_tools (provides gn)"
if [[ ! -d "${DEPOT_TOOLS}/.git" ]]; then
  git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "${DEPOT_TOOLS}" \
    || die "Failed to clone depot_tools"
else
  echo "depot_tools already present: ${DEPOT_TOOLS}"
fi

cat > "${AIBA_ROOT}/.aiba_env.sh" <<EOF
# Source before source builds:  source ~/Aiba/.aiba_env.sh
export PATH="${DEPOT_TOOLS}:\${PATH}"
export AIBA_PYTHON="${VENV}/bin/python3"
export AIBA_ROOT="${AIBA_ROOT}"
EOF

step "Verifying tools"
# shellcheck disable=SC1091
source "${AIBA_ROOT}/.aiba_env.sh"

"${VENV}/bin/python3" -c "import PIL; print('Pillow OK')"
command -v ninja >/dev/null || die "ninja not found (ninja-build package)"
command -v gn >/dev/null || die "gn not found after adding depot_tools to PATH"

echo ""
echo "Bootstrap complete."
echo ""
echo "Build (creates .venv automatically if you skip this bootstrap):"
echo "  cd ${AIBA_ROOT} && ./build_aiba.sh"
echo ""
echo "Optional — add gn to PATH for other terminals:"
echo "  source ${AIBA_ROOT}/.aiba_env.sh"
