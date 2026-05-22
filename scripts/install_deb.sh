#!/usr/bin/env bash
# Find and install the ungoogled-chromium .deb built by dpkg-buildpackage.
set -euo pipefail

AIBA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBIAN_DIR="${AIBA_ROOT}/ungoogled-chromium-debian"
DEB_PARENT="$(dirname "${DEBIAN_DIR}")"

die() { echo "ERROR: $*" >&2; exit 1; }

# dpkg-buildpackage writes .deb files in the parent of the source tree.
search_dirs=(
  "${DEB_PARENT}"
  "${AIBA_ROOT}"
  "${HOME}"
  "${HOME}/ungoogled-chromium-debian/.."
)

found=()
for dir in "${search_dirs[@]}"; do
  dir="$(cd "${dir}" 2>/dev/null && pwd)" || continue
  while IFS= read -r deb; do
    found+=("${deb}")
  done < <(find "${dir}" -maxdepth 1 -type f -name 'ungoogled-chromium_*.deb' 2>/dev/null | sort)
done

# Deduplicate
if ((${#found[@]} > 0)); then
  mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -u)
fi

if ((${#found[@]} == 0)); then
  cat >&2 <<EOF
ERROR: No ungoogled-chromium_*.deb found.

dpkg-buildpackage places packages in the parent of the source directory, e.g.:
  ${DEB_PARENT}/ungoogled-chromium_<version>_amd64.deb

Common causes:
  1. The build has not finished yet (or dpkg-buildpackage failed).
  2. You cloned/built outside ~/Aiba (search manually):
       find ~ -maxdepth 2 -name 'ungoogled-chromium_*.deb'

Finish the build first:
  cd ${AIBA_ROOT} && ./build_aiba_debian.sh

EOF
  exit 1
fi

echo "Found package(s):"
printf '  %s\n' "${found[@]}"
echo ""

# Prefer the newest main browser package (exclude -build-deps if any slipped in)
MAIN_DEB=""
for deb in "${found[@]}"; do
  [[ "${deb}" == *build-deps* ]] && continue
  MAIN_DEB="${deb}"
done
[[ -n "${MAIN_DEB}" ]] || MAIN_DEB="${found[-1]}"

echo "Installing: ${MAIN_DEB}"
sudo dpkg -i "${MAIN_DEB}" || {
  echo "Fixing dependencies..."
  sudo apt-get install -f -y
}

echo ""
echo "Done. Launch with: chromium"
