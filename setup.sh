#!/usr/bin/env bash
set -euo pipefail

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  Usage:                                                                  ║
# ║    ./setup.sh install   — install/update the daily cron job              ║
# ║    ./setup.sh uninstall — remove the cron job                            ║
# ║    ./setup.sh run       — run scrapers now (also called by cron)         ║
# ║    ./setup.sh           — same as "run"                                  ║
# ╠════════════════════════════════════════════════════════════════════════════╣
# ║  CONFIGURATION                                                           ║
# ╠════════════════════════════════════════════════════════════════════════════╣
# ║  Each entry: "script.py:output_pattern"                                  ║
# ║    script.py      — the Python script to run (in this folder)            ║
# ║    output_pattern — expected output file (use {DATE} for YYYY-MM-DD)     ║
# ║                     set to "none" if the script has no expected file      ║
# ╚════════════════════════════════════════════════════════════════════════════╝

# Runs every hour; the already-ran-today guard ensures it only executes once per day
CRON_SCHEDULE="0 * * * *"

SCRIPTS=(
    "apartment.py:apartments_{DATE}.xlsx"
    # "other_scraper.py:none"
)

PYTHON="/usr/bin/python3"
TIMEOUT_SECONDS=3000   # 50 minutes per attempt
MAX_RETRIES=5
RETRY_DELAY=30         # seconds between retries

# ── END CONFIGURATION ────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_TAG="# apartment-scraper"
COMMAND="${1:-run}"

# ── install ──────────────────────────────────────────────────────────────────
do_install() {
    chmod +x "${SCRIPT_DIR}/setup.sh"
    CRON_LINE="${CRON_SCHEDULE} /bin/bash \"${SCRIPT_DIR}/setup.sh\" run ${CRON_TAG}"
    ( crontab -l 2>/dev/null | grep -v "${CRON_TAG}" || true; echo "${CRON_LINE}" ) | crontab -
    echo "Cron job installed: ${CRON_LINE}"
    echo ""
    echo "Useful commands:"
    echo "  Check crontab : crontab -l"
    echo "  Run now       : ./setup.sh run"
    echo "  Uninstall     : ./setup.sh uninstall"
    echo "  Change schedule: edit CRON_SCHEDULE in setup.sh, then re-run ./setup.sh install"
}

# ── uninstall ────────────────────────────────────────────────────────────────
do_uninstall() {
    ( crontab -l 2>/dev/null | grep -v "${CRON_TAG}" || true ) | crontab -
    echo "Cron job removed."
}

# ── run ──────────────────────────────────────────────────────────────────────
do_run() {
    LOG_DIR="${SCRIPT_DIR}/logs"
    TODAY=$(date +"%Y-%m-%d")
    LOG_FILE="${LOG_DIR}/run_${TODAY}.log"

    mkdir -p "${LOG_DIR}"

    log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }
    notify() { osascript -e "display notification \"$1\" with title \"Scrapers\"" 2>/dev/null || true; }

    log "=== Daily scraper run started ==="
    cd "${SCRIPT_DIR}"

    TOTAL=0
    PASSED=0
    FAILED_NAMES=()

    for entry in "${SCRIPTS[@]}"; do
        [[ "$entry" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$entry" ]] && continue

        IFS=':' read -r script output_pattern <<< "$entry"
        TOTAL=$((TOTAL + 1))

        SCRIPT_PATH="${SCRIPT_DIR}/${script}"

        # Already-ran-today guard
        STAMP_FILE="${LOG_DIR}/.last_run_${script}"
        if [ -f "${STAMP_FILE}" ] && [ "$(cat "${STAMP_FILE}")" = "${TODAY}" ]; then
            log "[${script}] Already ran today. Skipping."
            PASSED=$((PASSED + 1))
            continue
        fi

        if [ ! -f "${SCRIPT_PATH}" ]; then
            log "[${script}] ERROR: script not found at ${SCRIPT_PATH}"
            FAILED_NAMES+=("${script}")
            continue
        fi

        EXPECTED_FILE=""
        if [ "$output_pattern" != "none" ]; then
            EXPECTED_FILE="${SCRIPT_DIR}/${output_pattern//\{DATE\}/${TODAY}}"
        fi

        SUCCESS=false
        ATTEMPT=0

        while [ $ATTEMPT -lt $MAX_RETRIES ]; do
            ATTEMPT=$((ATTEMPT + 1))
            log "[${script}] Attempt ${ATTEMPT}/${MAX_RETRIES}..."

            EXIT_CODE=0
            perl -e 'alarm shift; exec @ARGV' -- "${TIMEOUT_SECONDS}" \
                "${PYTHON}" "${SCRIPT_PATH}" >> "${LOG_FILE}" 2>&1 || EXIT_CODE=$?

            if [ -n "$EXPECTED_FILE" ] && [ -f "$EXPECTED_FILE" ]; then
                log "[${script}] Success on attempt ${ATTEMPT}."
                SUCCESS=true
                break
            elif [ -z "$EXPECTED_FILE" ] && [ $EXIT_CODE -eq 0 ]; then
                log "[${script}] Success on attempt ${ATTEMPT}."
                SUCCESS=true
                break
            elif [ $EXIT_CODE -eq 142 ]; then
                log "[${script}] Timed out after $((TIMEOUT_SECONDS/60))m."
            else
                log "[${script}] Failed (exit ${EXIT_CODE})."
            fi

            if [ $ATTEMPT -lt $MAX_RETRIES ]; then
                log "[${script}] Retrying in ${RETRY_DELAY}s..."
                sleep "${RETRY_DELAY}"
            fi
        done

        if $SUCCESS; then
            echo "${TODAY}" > "${STAMP_FILE}"
            PASSED=$((PASSED + 1))
        else
            log "[${script}] GAVE UP after ${MAX_RETRIES} attempts."
            FAILED_NAMES+=("${script}")
        fi
    done

    # Rotate: keep last 30 daily logs
    ls -t "${LOG_DIR}"/run_*.log 2>/dev/null | tail -n +31 | xargs rm -f 2>/dev/null || true

    log "=== Daily run complete: ${PASSED}/${TOTAL} succeeded ==="

    if [ ${#FAILED_NAMES[@]} -gt 0 ]; then
        FAIL_LIST=$(IFS=', '; echo "${FAILED_NAMES[*]}")
        log "FAILED: ${FAIL_LIST}"
        notify "Scraper failures: ${FAIL_LIST}"
        exit 1
    fi

    notify "All ${TOTAL} scrapers completed successfully."
    exit 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "${COMMAND}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    run)       do_run ;;
    *)         echo "Usage: ./setup.sh [install|uninstall|run]"; exit 1 ;;
esac
