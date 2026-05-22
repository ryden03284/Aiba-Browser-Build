#!/usr/bin/env bash
# ====================================================================
# monitor_backup.sh
# Resilient background daemon for ungoogled-chromium CI builds
# Dual-trigger: uptime cutoff (300 min) + compiler stall/failure
# ====================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------
# CONFIG  (override via env vars before launching)
# --------------------------------------------------------------------
AIBA_ROOT="${AIBA_ROOT:-$(pwd)}"
DEBIAN_DIR="${DEBIAN_DIR:-${AIBA_ROOT}/ungoogled-chromium-debian}"
LOG_FILE="${LOG_FILE:-${AIBA_ROOT}/.aiba_state/build.log}"
TMUX_SESSION="${TMUX_SESSION:-aiba}"

UPTIME_LIMIT_MIN="${UPTIME_LIMIT_MIN:-300}"   # hard cutoff in minutes
POLL_INTERVAL=60                               # seconds between uptime checks
STALL_LIMIT_MIN="${STALL_LIMIT_MIN:-15}"       # minutes of log silence = stall
STALL_LIMIT_SEC=$(( STALL_LIMIT_MIN * 60 ))

FILEBIN_URL="${FILEBIN_URL:-https://filebin.net}"
MAX_UPLOAD_RETRIES=3

DAEMON_LOG="${AIBA_ROOT}/.aiba_state/monitor.log"
mkdir -p "$(dirname "$DAEMON_LOG")"

# Redirect all output to daemon log AND stdout
exec > >(tee -a "$DAEMON_LOG") 2>&1

# --------------------------------------------------------------------
# LOGGING
# --------------------------------------------------------------------
_ts()   { date '+%Y-%m-%d %H:%M:%S'; }
info()  { echo "  [MON $(_ts)] $*"; }
warn()  { echo "  [MON $(_ts)] WARNING: $*" >&2; }
fail()  { echo "  [MON $(_ts)] FATAL: $*" >&2; exit 1; }
sep()   { echo "  [MON] ================================================================"; }

# --------------------------------------------------------------------
# PREFLIGHT — auto-install missing tools
# --------------------------------------------------------------------
ensure_cmd() {
    local cmd="$1"
    local pkg="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        info "Installing missing tool: $pkg"
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" \
            >/dev/null 2>&1 \
            || warn "Could not install $pkg — some features may degrade"
    fi
}

preflight() {
    sep
    info "Running preflight checks"
    ensure_cmd pigz   pigz
    ensure_cmd curl   curl
    ensure_cmd gawk   gawk
    ensure_cmd tmux   tmux
    ensure_cmd du     coreutils
    ensure_cmd df     coreutils
    info "Preflight complete"
    sep
}

# --------------------------------------------------------------------
# UPTIME HELPERS
# --------------------------------------------------------------------
get_uptime_min() {
    awk '{print int($1/60)}' /proc/uptime
}

remaining_min() {
    local run_time
    run_time=$(get_uptime_min)
    echo $(( UPTIME_LIMIT_MIN - run_time ))
}

# --------------------------------------------------------------------
# LOG STALENESS HELPERS
# --------------------------------------------------------------------
log_last_modified_sec() {
    # Returns epoch seconds of last modification, or 0 if file missing
    if [[ -f "$LOG_FILE" ]]; then
        stat -c '%Y' "$LOG_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

log_stalled() {
    local last_mod now elapsed
    last_mod=$(log_last_modified_sec)
    now=$(date +%s)
    elapsed=$(( now - last_mod ))
    (( elapsed >= STALL_LIMIT_SEC ))
}

# Returns human-readable time since last log update
log_age_human() {
    local last_mod now elapsed
    last_mod=$(log_last_modified_sec)
    now=$(date +%s)
    elapsed=$(( now - last_mod ))
    if (( elapsed < 60 )); then
        echo "${elapsed}s ago"
    else
        echo "$(( elapsed / 60 ))m $(( elapsed % 60 ))s ago"
    fi
}

# Detect terminal failure keywords in the tail of the build log
log_has_fatal() {
    [[ -f "$LOG_FILE" ]] || return 1
    tail -n 50 "$LOG_FILE" 2>/dev/null \
        | grep -qiE \
            'dpkg-buildpackage.*error|ninja.*FAILED|error: ld returned|collect2.*error|fatal error:|make\[.*\]: \*\*\*|CalledProcessError|subprocess\.CalledProcessError' \
        2>/dev/null
}

# --------------------------------------------------------------------
# TMUX SIGNAL — double-wave Ctrl+C to all panes
# --------------------------------------------------------------------
signal_tmux_stop() {
    if ! command -v tmux >/dev/null 2>&1; then
        warn "tmux not found — skipping signal"
        return 0
    fi

    if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        warn "tmux session '$TMUX_SESSION' not found — skipping signal"
        return 0
    fi

    info "Sending Ctrl+C wave 1 to all panes in session '$TMUX_SESSION'"
    tmux list-panes -s -t "$TMUX_SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' \
    2>/dev/null | while read -r pane; do
        tmux send-keys -t "$pane" C-c 2>/dev/null || true
    done

    sleep 2

    info "Sending Ctrl+C wave 2 to all panes in session '$TMUX_SESSION'"
    tmux list-panes -s -t "$TMUX_SESSION" -F '#{session_name}:#{window_index}.#{pane_index}' \
    2>/dev/null | while read -r pane; do
        tmux send-keys -t "$pane" C-c 2>/dev/null || true
    done

    info "Signal waves sent — waiting 5s for processes to settle"
    sleep 5
}

# --------------------------------------------------------------------
# SCAN FOR BUILT .DEB FILES
# --------------------------------------------------------------------
find_deb_files() {
    local search_dir
    search_dir="$(dirname "$DEBIAN_DIR")"
    find "$search_dir" \
        -maxdepth 1 -type f \
        -name 'ungoogled-chromium_*.deb' \
        ! -name '*build-deps*' \
        2>/dev/null \
        | LC_ALL=C sort
}

# --------------------------------------------------------------------
# SCAN FOR LARGEST CHROMIUM BUILD OUTPUT DIR (fallback)
# --------------------------------------------------------------------
find_build_output_dir() {
    # Search for 'out' directories containing known Chromium build markers
    local candidate best_dir="" best_size=0

    while IFS= read -r -d '' out_dir; do
        # Must contain at least one recognisable marker
        if find "$out_dir" -maxdepth 2 \
            \( -name 'Default' -o -name 'Release' -o -name 'Debug' -o -name 'args.gn' \) \
            -print -quit 2>/dev/null | grep -q .; then

            local sz
            sz=$(du -sk "$out_dir" 2>/dev/null | awk '{print $1}')
            if (( sz > best_size )); then
                best_size=$sz
                best_dir="$out_dir"
            fi
        fi
    done < <(find "$AIBA_ROOT" -maxdepth 6 -type d -name 'out' -print0 2>/dev/null)

    echo "$best_dir"
}

# --------------------------------------------------------------------
# DISK SPACE GUARD
# --------------------------------------------------------------------
check_disk_space() {
    local target_dir="$1"
    local target_kb free_kb

    target_kb=$(du -sk "$target_dir" 2>/dev/null | awk '{print $1}')
    free_kb=$(df -k "$target_dir" 2>/dev/null | awk 'NR==2{print $4}')

    info "Target size : $(( target_kb / 1024 )) MB"
    info "Free space  : $(( free_kb  / 1024 )) MB"

    if (( target_kb >= free_kb )); then
        warn "Insufficient disk space — target ${target_kb}K >= free ${free_kb}K"
        return 1
    fi
    return 0
}

# --------------------------------------------------------------------
# COMPRESS PROGRESS ARCHIVE
# --------------------------------------------------------------------
compress_output() {
    local target_dir="$1"
    local archive="$2"

    info "Compressing: $target_dir → $archive"
    info "Using pigz -3 (parallel, speed-optimised)"

    tar \
        --use-compress-program='pigz -3' \
        -cf "$archive" \
        -C "$(dirname "$target_dir")" \
        "$(basename "$target_dir")" \
        2>/dev/null

    info "Verifying archive integrity"
    if ! pigz -t "$archive" 2>/dev/null; then
        warn "Archive integrity check failed for $archive"
        return 1
    fi

    local archive_mb
    archive_mb=$(du -m "$archive" 2>/dev/null | awk '{print $1}')
    info "Archive created: $archive (${archive_mb} MB)"
}

# --------------------------------------------------------------------
# UPLOAD TO FILEBIN WITH EXPONENTIAL BACKOFF
# --------------------------------------------------------------------
upload_to_filebin() {
    local filepath="$1"
    local bin_id="$2"
    local filename
    filename="$(basename "$filepath")"

    local attempt=1
    local wait_sec=15
    local http_code

    while (( attempt <= MAX_UPLOAD_RETRIES )); do
        info "Upload attempt $attempt/$MAX_UPLOAD_RETRIES — $filename → filebin/$bin_id"

        local curl_err_file
        curl_err_file=$(mktemp)

        http_code=$(
            curl -s -w '%{http_code}' -o /tmp/filebin_response.txt \
                --max-time 600 \
                --retry 0 \
                -X POST "${FILEBIN_URL}/${bin_id}/${filename}" \
                -H "filename: ${filename}" \
                -H "Content-Type: application/octet-stream" \
                --data-binary "@${filepath}" \
                2>"$curl_err_file"
        ) || true

        local curl_exit=$?

        if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
            info "Upload succeeded (HTTP $http_code)"
            info "Filebin URL: ${FILEBIN_URL}/${bin_id}/${filename}"
            rm -f "$curl_err_file"
            return 0
        fi

        warn "Upload failed — HTTP $http_code (curl exit $curl_exit)"
        if [[ -s "$curl_err_file" ]]; then
            warn "curl stderr: $(cat "$curl_err_file")"
        fi
        if [[ -s /tmp/filebin_response.txt ]]; then
            warn "Server response: $(cat /tmp/filebin_response.txt | head -5)"
        fi

        rm -f "$curl_err_file"

        if (( attempt < MAX_UPLOAD_RETRIES )); then
            info "Waiting ${wait_sec}s before retry"
            sleep "$wait_sec"
            wait_sec=$(( wait_sec * 2 ))
        fi

        (( attempt++ )) || true
    done

    warn "All $MAX_UPLOAD_RETRIES upload attempts failed for $filename"
    return 1
}

# --------------------------------------------------------------------
# BACKUP EVALUATION PHASE
# --------------------------------------------------------------------
run_backup_phase() {
    local trigger_reason="$1"
    sep
    info "BACKUP PHASE TRIGGERED — reason: $trigger_reason"
    sep

    local bin_id
    bin_id="aiba_build_$(date +%s)"
    info "Filebin bin ID: $bin_id"

    # --- Priority 1: upload finished .deb packages ---
    local deb_files=()
    mapfile -t deb_files < <(find_deb_files)

    if (( ${#deb_files[@]} > 0 )); then
        info "Found ${#deb_files[@]} .deb package(s) — uploading directly (skipping source backup)"
        local deb upload_ok=0 upload_fail=0
        for deb in "${deb_files[@]}"; do
            if upload_to_filebin "$deb" "$bin_id"; then
                (( upload_ok++ )) || true
            else
                (( upload_fail++ )) || true
            fi
        done
        sep
        info "Upload summary: ${upload_ok} succeeded, ${upload_fail} failed"
        info "Filebin bin: ${FILEBIN_URL}/${bin_id}"
        sep
        return 0
    fi

    # --- Priority 2: compress + upload build progress ---
    info "No .deb packages found — falling back to progress archive"

    local out_dir
    out_dir="$(find_build_output_dir)"

    if [[ -z "$out_dir" ]]; then
        warn "No Chromium output directory found — nothing to back up"
        return 1
    fi

    info "Selected output directory: $out_dir"

    if ! check_disk_space "$out_dir"; then
        fail "Aborting compression — insufficient disk space"
    fi

    local archive="/tmp/aiba_progress_$(date +%s).tar.gz"

    if ! compress_output "$out_dir" "$archive"; then
        warn "Compression failed — skipping upload"
        return 1
    fi

    if upload_to_filebin "$archive" "$bin_id"; then
        info "Progress archive uploaded successfully"
        info "Filebin bin: ${FILEBIN_URL}/${bin_id}"
    else
        warn "Progress archive upload failed after all retries"
    fi

    rm -f "$archive"
}

# --------------------------------------------------------------------
# MAIN WATCH LOOP
# --------------------------------------------------------------------
main() {
    sep
    info "monitor_backup.sh starting"
    info "Uptime limit  : ${UPTIME_LIMIT_MIN} minutes"
    info "Stall timeout : ${STALL_LIMIT_MIN} minutes of log silence"
    info "Log file      : $LOG_FILE"
    info "DEBIAN_DIR    : $DEBIAN_DIR"
    info "Tmux session  : $TMUX_SESSION"
    sep

    preflight

    local trigger_reason=""

    while true; do
        sleep "$POLL_INTERVAL"

        local run_time remaining log_age_str
        run_time=$(get_uptime_min)
        remaining=$(remaining_min)
        log_age_str=$(log_age_human)

        info "Uptime: ${run_time}m | Remaining: ${remaining}m | Last log change: ${log_age_str}"

        # --- Trigger 1: uptime limit ---
        if (( run_time >= UPTIME_LIMIT_MIN )); then
            trigger_reason="Uptime limit reached (${run_time}m >= ${UPTIME_LIMIT_MIN}m)"
            info "TRIGGER: $trigger_reason"
            break
        fi

        # --- Trigger 2: compiler stall ---
        if log_stalled; then
            trigger_reason="Compiler stall — no log activity for ${STALL_LIMIT_MIN}+ minutes"
            info "TRIGGER: $trigger_reason"
            break
        fi

        # --- Trigger 3: fatal log pattern ---
        if log_has_fatal; then
            trigger_reason="Fatal error pattern detected in build log"
            info "TRIGGER: $trigger_reason"
            break
        fi
    done

    sep
    info "Exiting watch loop — $trigger_reason"
    sep

    signal_tmux_stop
    run_backup_phase "$trigger_reason"

    sep
    info "monitor_backup.sh finished"
    sep
}

main "$@"
