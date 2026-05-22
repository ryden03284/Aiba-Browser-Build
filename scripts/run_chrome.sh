#!/usr/bin/env bash
# Run the locally built Aiba/Chromium binary from the source tree.
set -euo pipefail

AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${AIBA_ROOT}/ungoogled-chromium/build/src/out/Default"
CHROME="${OUT_DIR}/chrome"

if [[ ! -x "${CHROME}" ]]; then
  echo "ERROR: Binary not found: ${CHROME}" >&2
  echo "Build first: cd ${AIBA_ROOT} && ./build_aiba.sh" >&2
  exit 1
fi

"${AIBA_ROOT}/scripts/apply_source_prefs.sh" "${OUT_DIR}" 2>/dev/null || true
cd "${OUT_DIR}"
exec ./chrome "$@"
