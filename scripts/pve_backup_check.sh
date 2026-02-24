#!/bin/bash
# ============================================================
#  pve_backup_check.sh
#  Parses /var/log/pve/tasks for the most recent vzdump
#  backup results and prints them in colour.
#
#    Green  → OK
#    Red    → Error / Failed
#    Yellow → Running / Unknown
#
#  Also supports the pvesh API when jq is available.
#
#  Usage:  ./pve_backup_check.sh [--days N]
# ============================================================

set -euo pipefail

# ---- Colours ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_err()   { printf "${RED}[FAIL]${NC}  %s\n" "$*"; }
separator() { echo "──────────────────────────────────────────────"; }

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
            echo ""
            echo "  --days N   Check backup tasks from the last N days (default: 1)"
            echo "  --help     Show this message"
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

echo ""
echo "==========================================="
echo "  PVE Backup Health Check — ${HOSTNAME}"
echo "  Checking last ${LOOKBACK_DAYS} day(s)"
echo "==========================================="
echo ""

OK_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# ============================================================
#  Method 1 — Parse /var/log/pve/tasks (filesystem)
# ============================================================
check_via_tasklog() {
    local TASK_DIR="/var/log/pve/tasks"
    local INDEX_ACTIVE="${TASK_DIR}/active"
    local INDEX_ARCHIVE

    # Task index files: active and archived (0, 1, 2…)
    # Each line format: UPID:starttime:endtime:status
    # UPID contains the task type, e.g. "vzdump"

    log_info "Scanning task logs in ${TASK_DIR}..."
    echo ""

    # Calculate the cutoff epoch
    local CUTOFF
    CUTOFF=$(date -d "-${LOOKBACK_DAYS} days" +%s 2>/dev/null || date -v-"${LOOKBACK_DAYS}"d +%s 2>/dev/null)

    # Collect all index files (active + archived)
    local INDEX_FILES=()
    [ -f "${INDEX_ACTIVE}" ] && INDEX_FILES+=("${INDEX_ACTIVE}")

    # Use nullglob so the loop is skipped if no index files exist
    local _old_nullglob
    _old_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob
    for f in "${TASK_DIR}"/index*; do
        [ -f "${f}" ] && INDEX_FILES+=("${f}")
    done
    eval "${_old_nullglob}"

    if [ ${#INDEX_FILES[@]} -eq 0 ]; then
        log_warn "No task index files found in ${TASK_DIR}."
        return
    fi

    printf "  ${BOLD}%-22s  %-8s  %-8s  %s${NC}\n" "DATE" "CTID" "STATUS" "UPID (short)"
    separator

    local FOUND=0

    for INDEX in "${INDEX_FILES[@]}"; do
        while IFS=: read -r UPID_FULL _ _ _ _ _ _ STARTTIME _ STATUS REST; do
            # Skip non-vzdump tasks
            case "${UPID_FULL}" in
                *vzdump*) ;;
                *) continue ;;
            esac

            # Skip tasks older than cutoff
            # UPID hex timestamp is in field 5 (0-indexed) after splitting on ':'
            local TASK_START
            TASK_START=$(echo "${UPID_FULL}" | awk -F: '{print $5}')
            # Convert hex to decimal if needed
            if echo "${TASK_START}" | grep -qE '^[0-9A-Fa-f]+$' 2>/dev/null; then
                TASK_START=$((16#${TASK_START})) 2>/dev/null || TASK_START=0
            fi

            if [ "${TASK_START}" -lt "${CUTOFF}" ] 2>/dev/null; then
                continue
            fi

            FOUND=$((FOUND + 1))

            # Extract VMID from UPID if present
            local VMID
            VMID=$(echo "${UPID_FULL}" | awk -F: '{print $7}' | grep -oE '^[0-9]+' || echo "n/a")

            local TASK_DATE
            TASK_DATE=$(date -d "@${TASK_START}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${TASK_START}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")

            # Truncate UPID for display
            local UPID_SHORT
            UPID_SHORT="${UPID_FULL:0:30}…"

            # Colour-code the status
            case "${STATUS}" in
                OK)
                    printf "  ${GREEN}%-22s  %-8s  %-8s${NC}  %s\n" "${TASK_DATE}" "${VMID}" "OK" "${UPID_SHORT}"
                    OK_COUNT=$((OK_COUNT + 1))
                    ;;
                ""|" ")
                    printf "  ${YELLOW}%-22s  %-8s  %-8s${NC}  %s\n" "${TASK_DATE}" "${VMID}" "RUNNING" "${UPID_SHORT}"
                    WARN_COUNT=$((WARN_COUNT + 1))
                    ;;
                *)
                    printf "  ${RED}%-22s  %-8s  %-8s${NC}  %s\n" "${TASK_DATE}" "${VMID}" "${STATUS}" "${UPID_SHORT}"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                    ;;
            esac
        done < "${INDEX}" 2>/dev/null || true
    done

    if [ "${FOUND}" -eq 0 ]; then
        log_warn "No vzdump tasks found in the last ${LOOKBACK_DAYS} day(s)."
    fi
}

# ============================================================
#  Method 2 — pvesh API (richer output, needs jq)
# ============================================================
check_via_pvesh() {
    log_info "Querying task log via pvesh API..."
    echo ""

    local SINCE_EPOCH
    SINCE_EPOCH=$(date -d "-${LOOKBACK_DAYS} days" +%s 2>/dev/null || date -v-"${LOOKBACK_DAYS}"d +%s 2>/dev/null)

    local TASKS
    TASKS=$(pvesh get /nodes/"${HOSTNAME}"/tasks \
        --typefilter vzdump \
        --since "${SINCE_EPOCH}" \
        --output-format json 2>/dev/null) || {
            log_warn "pvesh query failed — falling back to filesystem."
            check_via_tasklog
            return
        }

    if [ -z "${TASKS}" ] || [ "${TASKS}" = "[]" ]; then
        log_warn "No vzdump tasks found in the last ${LOOKBACK_DAYS} day(s)."
        return
    fi

    printf "  ${BOLD}%-22s  %-8s  %-8s  %s${NC}\n" "DATE" "VMID" "STATUS" "DURATION"
    separator

    echo "${TASKS}" | jq -r '.[] | "\(.starttime)|\(.status)|\(.id // "n/a")|\(.endtime // 0)"' | while IFS='|' read -r START STATUS VMID END; do
        local TASK_DATE
        TASK_DATE=$(date -d "@${START}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "${START}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "${START}")

        local DURATION="—"
        if [ "${END}" -gt 0 ] 2>/dev/null; then
            local SECS=$((END - START))
            DURATION="$(( SECS / 60 ))m $(( SECS % 60 ))s"
        fi

        case "${STATUS}" in
            OK)
                printf "  ${GREEN}%-22s  %-8s  %-8s${NC}  %s\n" "${TASK_DATE}" "${VMID}" "OK" "${DURATION}"
                OK_COUNT=$((OK_COUNT + 1))
                ;;
            "")
                printf "  ${YELLOW}%-22s  %-8s  %-8s${NC}  %s\n" "${TASK_DATE}" "${VMID}" "RUNNING" "${DURATION}"
                WARN_COUNT=$((WARN_COUNT + 1))
                ;;
            *)
                printf "  ${RED}%-22s  %-8s  %-8s${NC}  %s\n" "${TASK_DATE}" "${VMID}" "${STATUS}" "${DURATION}"
                FAIL_COUNT=$((FAIL_COUNT + 1))
                ;;
        esac
    done
}

# ============================================================
#  Main — pick the best available method
# ============================================================
if command -v pvesh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    check_via_pvesh
else
    if ! command -v pvesh >/dev/null 2>&1; then
        log_warn "pvesh not found."
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq not installed (apt install jq)."
    fi
    log_info "Using filesystem fallback..."
    check_via_tasklog
fi

# ============================================================
#  Summary
# ============================================================
echo ""
echo "==========================================="
echo "  Summary"
echo "==========================================="
printf "  ${GREEN}OK:${NC}       %d\n" "${OK_COUNT}"
printf "  ${RED}Failed:${NC}   %d\n" "${FAIL_COUNT}"
printf "  ${YELLOW}Warnings:${NC} %d\n" "${WARN_COUNT}"
echo "==========================================="
echo ""

if [ "${FAIL_COUNT}" -gt 0 ]; then
    log_err "One or more backup jobs failed!"
    exit 1
fi

log_ok "All backup jobs completed successfully."
exit 0
