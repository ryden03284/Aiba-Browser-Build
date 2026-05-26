# Spec: Resume Ungoogled Chromium Build from Save

## Problem Statement

A partial Chromium build (~20,000 files already compiled) is stored as a `.tar.gz` archive at `filebin.net/aiba_browser_build_2026`. The goal is to download and restore that save, install build dependencies, and resume compilation using `ninja -j 4 -C out/Release chrome`. No packaging or branding steps are needed — only the `chrome` binary needs to be produced.

---

## Requirements

1. **Download** the archive from `filebin.net/aiba_browser_build_2026` into `/workspaces/Aiba-Browser-Build`.
2. **Extract** the `.tar.gz` in place. The archive contains a folder named `ungoogled-chromium-debian` which itself contains the actual build tree (also named `ungoogled-chromium-debian` internally, per the user's description). After extraction the build root must be accessible at:
   ```
   /workspaces/Aiba-Browser-Build/ungoogled-chromium-debian/
   ```
3. **Install build dependencies** using `mk-build-deps` against the `debian/control` file found inside the extracted tree:
   ```
   sudo mk-build-deps --install --remove \
     --tool 'apt-get -y --no-install-recommends' \
     ungoogled-chromium-debian/debian/control
   ```
4. **Fix any pre-ninja errors** that can be resolved automatically (e.g. missing packages surfaced by `mk-build-deps`, broken symlinks, missing `out/Release/args.gn`). Stop and report clearly on errors that cannot be auto-resolved.
5. **Run ninja** with exactly this command from inside the build tree:
   ```
   ninja -j 4 -C out/Release chrome
   ```
6. **Stop after ninja** — no packaging, branding, or installation steps.

---

## Acceptance Criteria

- Archive is downloaded and extracted without errors.
- `ungoogled-chromium-debian/` exists at `/workspaces/Aiba-Browser-Build/ungoogled-chromium-debian/`.
- `mk-build-deps` completes without unresolved dependency errors.
- `ninja -j 4 -C out/Release chrome` runs and produces `out/Release/chrome`.
- Any auto-fixable errors (missing deps, broken symlinks) are resolved before ninja is invoked.
- Non-auto-fixable errors are reported clearly and execution stops.

---

## Implementation Steps

1. **Download archive**
   - Use `curl` or `wget` to fetch the `.tar.gz` from `filebin.net/aiba_browser_build_2026` into `/workspaces/Aiba-Browser-Build/`.
   - Verify the download completed (non-zero file size).

2. **Extract archive**
   - Run `tar -xzf <archive> -C /workspaces/Aiba-Browser-Build/`.
   - Confirm `ungoogled-chromium-debian/` directory exists after extraction.

3. **Install build dependencies**
   - `cd` into `ungoogled-chromium-debian/`.
   - Run `sudo mk-build-deps --install --remove --tool 'apt-get -y --no-install-recommends' debian/control`.
   - On failure, capture the error, attempt `sudo apt-get install -f -y` to resolve broken deps, then retry once.

4. **Pre-ninja checks / auto-fixes**
   - Verify `out/Release/` directory exists (it should, from the save).
   - Verify `out/Release/args.gn` or `out/Release/build.ninja` is present.
   - If `out/Release/build.ninja` is missing, report and abort — the save may be incomplete.
   - Fix any obviously broken symlinks under `out/Release/`.

5. **Run ninja**
   - Execute: `ninja -j 4 -C out/Release chrome`
   - Stream output to terminal.
   - On non-zero exit, display the last 50 lines of output and stop.
