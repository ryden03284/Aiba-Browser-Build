#!/usr/bin/env bash
# Bundle uBlock Origin into chrome/browser/resources/default_apps/
set -euo pipefail

CHROMIUM_SRC="${1:?Usage: install_ublock_default_app.sh CHROMIUM_SRC}"
PYTHON="${2:-python3}"
UBLOCK_EXT_ID="cjpalhdlnbpafiamejdnhcphjbkeiagm"

DEFAULT_APPS="${CHROMIUM_SRC}/chrome/browser/resources/default_apps"
mkdir -p "${DEFAULT_APPS}"

UBLOCK_ZIP="$(mktemp -t ublock.XXXXXX.zip)"
UBLOCK_STAGING="$(mktemp -d -t ublock_unpack.XXXXXX)"
trap 'rm -rf "${UBLOCK_STAGING}" "${UBLOCK_ZIP}"' EXIT

UBLOCK_ASSET_URL="$(
  curl -fsSL "https://api.github.com/repos/gorhill/uBlock/releases/latest" \
    | "${PYTHON}" -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    n = a.get('name', '')
    if 'chromium' in n.lower() and n.endswith('.zip'):
        print(a['browser_download_url'])
        break
" || true
)"
[[ -n "${UBLOCK_ASSET_URL}" ]] || { echo "ERROR: uBlock chromium zip URL not found" >&2; exit 1; }

curl -fL "${UBLOCK_ASSET_URL}" -o "${UBLOCK_ZIP}"
unzip -q "${UBLOCK_ZIP}" -d "${UBLOCK_STAGING}"

UBLOCK_DIR="$(find "${UBLOCK_STAGING}" -maxdepth 2 -name manifest.json -printf '%h\n' -quit)"
[[ -n "${UBLOCK_DIR}" ]] || { echo "ERROR: manifest.json not found in uBlock zip" >&2; exit 1; }

UBLOCK_VERSION="$("${PYTHON}" -c "import json; print(json.load(open('${UBLOCK_DIR}/manifest.json'))['version'])")"
UBLOCK_CRX="${DEFAULT_APPS}/uBlock0.crx"

PACK_PY="${CHROMIUM_SRC}/chrome/tools/extensions/pack.py"
if [[ -f "${PACK_PY}" ]]; then
  python3 "${PACK_PY}" "${UBLOCK_DIR}" "${DEFAULT_APPS}/uBlock0" 2>/dev/null \
    && mv -f "${DEFAULT_APPS}/uBlock0.crx" "${UBLOCK_CRX}" 2>/dev/null || true
fi

if [[ ! -f "${UBLOCK_CRX}" ]]; then
  CRX_URL="https://clients2.google.com/service/update2/crx?response=redirect&prodversion=133.0&acceptformat=crx2,crx3&x=id%3D${UBLOCK_EXT_ID}%26uc"
  curl -fL "${CRX_URL}" -o "${UBLOCK_CRX}"
fi

cat > "${DEFAULT_APPS}/external_extensions.json" <<EOF
{
  "${UBLOCK_EXT_ID}": {
    "external_crx": "uBlock0.crx",
    "external_version": "${UBLOCK_VERSION}"
  }
}
EOF

echo "uBlock Origin ${UBLOCK_VERSION} installed under ${DEFAULT_APPS}"
