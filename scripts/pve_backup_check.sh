#!/bin/bash
# ============================================================
#  pve_backup_check.sh
#  Scans recent Proxmox VE backup tasks (vzdump) and reports
#  their status. Useful for daily health-check cron jobs or
#  integration with notification systems.
#
#  Methods:
#    1. pvesh API (preferred) — queries the task log via REST
#    2. Filesystem fallback  — scans /var/log/pve/tasks/
#
#  Usage:  ./pve_backup_check.sh [--days N]
# ============================================================

set -euo pipefail

# ---- Colours ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_err()   { printf "${RED}[FAIL]${NC}  %s\n" "$*"; }

# ---- Defaults ----
LOOKBACK_DAYS=1

# ---- Parse arguments ----
while [ $# -gt 0 ]; do
    case "$1" in
        --days|-d)
            LOOKBACK_DAYS="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--days N]"
            echo "  --days N   Check backup tasks from the last N days (default: 1)"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ---- Pre-flight: root check ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

HOSTNAME=$(hostname)
SINCE_EPOCH=$(date -d "-${LOOKBACK_DAYS} days" +%s 2>/dev/null || date -v-${LOOKBACK_DAYS}d +%s 2>/dev/null)

echo ""
echo "==========================================="
echo "  PVE Backup Health Check — ${HOSTNAME}"
echo "  Checking last ${LOOKBACK_DAYS} day(s)"
echo "==========================================="
echo ""

TOTAL=0
OK_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ---- Method 1: pvesh API ----
check_via_pvesh() {
    log_info "Querying task log via pvesh API..."

    # Fetch recent vzdump tasks as JSON
    TASKS=$(pvesh get /nodes/"${HOSTNAME}"/tasks \
        --typefilter vzdump \
        --since "${SINCE_EPOCH}" \
        --output-format json 2>/dev/null) || return 1

    if [ -z "${TASKS}" ] || [ "${TASKS}" = "[]" ]; then
        log_warn "No vzdump tasks found in the last ${LOOKBACK_DAYS} day(s)."
        return 0
    fi

    # Parse each task — requires jq
    echo "${TASKS}" | jq -r '.[] | "\(.upid)|\(.status)|\(.starttime)|\(.type)"' | while IFS='|' read -r UPID STATUS STARTTIME TYPE; do
        # Convert epoch to human-readable
        TASK_DATE=$(date -d "@${STARTTIME}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${STARTTIME}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${STARTTIME}")

        TOTAL=$((TOTAL + 1))

        case "${STATUS}" in
            OK)
                log_ok "[${TASK_DATE}] vzdump — ${STATUS}"
                OK_COUNT=$((OK_COUNT + 1))
                ;;
            "")
                log_warn "[${TASK_DATE}] vzdump — still running or status unavailable"
                WARN_COUNT=$((WARN_COUNT + 1))
                ;;
            *)
                log_err "[${TASK_DATE}] vzdump — ${STATUS}"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                ;;
        esac
    done

    return 0
}

# ---- Method 2: Filesystem fallback ----
check_via_filesystem() {
    local TASK_DIR="/var/log/pve/tasks"

    if [ ! -d "${TASK_DIR}" ]; then
        log_err "Task log directory ${TASK_DIR} does not exist."
        return 1
    fi

    log_info "Scanning task logs in ${TASK_DIR}..."

    # vzdump task files are named with the UPID; grep for vzdump entries
    find "${TASK_DIR}" -type f -newer <(date -d "-${LOOKBACK_DAYS} days" '+%Y%m%d' 2>/dev/null && touch -d "-${LOOKBACK_DAYS} days" /tmp/.pve_check_ref || touch -t "$(date -v-${LOOKBACK_DAYS}d '+%Y%m%d%H%M.%S')" /tmp/.pve_check_ref) -name '*vzdump*' 2>/dev/null | while read -r TASKFILE; do
        STATUS=$(tail -1 "${TASKFILE}" 2>/dev/null)
        FILENAME=$(basename "${TASKFILE}")

        TOTAL=$((TOTAL + 1))

        if echo "${STATUS}" | grep -qi "^OK"; then
            log_ok "${FILENAME} — OK"
            OK_COUNT=$((OK_COUNT + 1))
        else
            log_err "${FILENAME} — ${STATUS}"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done

    # Also check active (index) log for recent vzdump references
    local ACTIVE_LOG="/var/log/pve/tasks/active"
    if [ -f "${ACTIVE_LOG}" ]; then
        RUNNING=$(grep -c "vzdump" "${ACTIVE_LOG}" 2>/dev/null || true)
        if [ "${RUNNING}" -gt 0 ]; then
            log_warn "${RUNNING} vzdump task(s) currently active/running."
        fi
    fi

    rm -f /tmp/.pve_check_ref
    return 0
}

# ---- Main logic ----
if command -v pvesh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    check_via_pvesh
else
    if ! command -v pvesh >/dev/null 2>&1; then
        log_warn "pvesh not found — falling back to filesystem scan."
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq not installed — falling back to filesystem scan."
    fi
    check_via_filesystem
fi

echo ""
echo "==========================================="
echo "  Summary"
echo "==========================================="
printf "  ${GREEN}OK:${NC}      %d\n" "${OK_COUNT}"
printf "  ${RED}Failed:${NC}  %d\n" "${FAIL_COUNT}"
printf "  ${YELLOW}Warnings:${NC} %d\n" "${WARN_COUNT}"
echo "==========================================="

# Exit with non-zero if any failures were detected
if [ "${FAIL_COUNT}" -gt 0 ]; then
    exit 1
fi

exit 0
