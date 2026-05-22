#!/usr/bin/env bash
# Copy Aiba master_preferences next to the built chrome binary (Linux reads DIR_EXE).
set -euo pipefail

AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-${AIBA_ROOT}/ungoogled-chromium/build/src/out/Default}"
PREFS_SRC="${AIBA_ROOT}/config/master_preferences.json"

[[ -f "${PREFS_SRC}" ]] || { echo "ERROR: ${PREFS_SRC} not found" >&2; exit 1; }
mkdir -p "${OUT_DIR}"
cp "${PREFS_SRC}" "${OUT_DIR}/master_preferences"
echo "Installed ${OUT_DIR}/master_preferences"
