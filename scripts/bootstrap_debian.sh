#!/usr/bin/env bash
# One-time setup for Aiba via ungoogled-chromium-debian (.deb build).
set -euo pipefail

AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${AIBA_ROOT}/.venv"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "==> $*"; }

step "Installing Debian build tools (sudo required)"
sudo apt update
sudo apt install -y \
  devscripts equivs git curl unzip patch \
  python3 python3-venv python3-full python3-pip \
  || die "apt install failed"

step "Creating Python venv for branding scripts"
if [[ ! -d "${VENV}" ]]; then
  python3 -m venv "${VENV}" || die "Failed to create .venv"
fi
"${VENV}/bin/pip" install --upgrade pip
"${VENV}/bin/pip" install -r "${AIBA_ROOT}/requirements.txt"

cat > "${AIBA_ROOT}/.aiba_env.sh" <<EOF
# Optional: source ~/Aiba/.aiba_env.sh
export AIBA_PYTHON="${VENV}/bin/python3"
export AIBA_ROOT="${AIBA_ROOT}"
EOF

echo ""
echo "Bootstrap complete."
echo "Next: source ${AIBA_ROOT}/.aiba_env.sh && cd ${AIBA_ROOT} && ./build_aiba_debian.sh"
