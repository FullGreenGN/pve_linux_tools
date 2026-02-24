#!/bin/bash
# ============================================================
#  pve_health.sh
#  Host health check for Proxmox VE:
#    1. SMART disk status  — scans all drives via smartctl
#    2. Backup audit       — checks last 24h of vzdump tasks
#
#  Usage:  ./pve_health.sh [--days N]
# ============================================================

set -euo pipefail

# ---- Colours ----
readonly RED='\033[0;31m'  GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'  CYAN='\033[0;36m'
readonly BOLD='\033[1m'  DIM='\033[2m'  NC='\033[0m'

log_info()  { printf "${CYAN}  ℹ${NC}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}  ✔${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}  ⚠${NC}  %s\n" "$*"; }
log_err()   { printf "${RED}  ✖${NC}  %s\n" "$*"; }
hr()        { printf "${DIM}  %s${NC}\n" "─────────────────────────────────────────────────"; }

# ---- Defaults ----
LOOKBACK_DAYS=1

# ---- Parse args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --days|-d)  LOOKBACK_DAYS="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--days N]"
            echo "  --days N   Backup lookback period (default: 1)"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ---- Root check ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

ISSUES=0

echo ""
printf "  ${BOLD}PVE Host Health Check — %s${NC}\n" "$(hostname)"
printf "  ${DIM}%s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')"
hr

# ============================================================
#  Section 1 — SMART Disk Status
# ============================================================
echo ""
printf "  ${BOLD}① Disk SMART Status${NC}\n"
hr
echo ""

if ! command -v smartctl >/dev/null 2>&1; then
    log_warn "smartctl not found. Install smartmontools:"
    log_info "  apt install smartmontools"
    ISSUES=$((ISSUES + 1))
else
    # Discover all block devices (sd*, nvme*, hd*)
    DISKS=$(lsblk -dnpo NAME,TYPE | awk '$2=="disk" {print $1}')

    if [ -z "${DISKS}" ]; then
        log_warn "No disks detected."
    else
        printf "  ${BOLD}%-18s %-10s %-8s %s${NC}\n" "DEVICE" "HEALTH" "TEMP" "MODEL"
        hr

        for disk in ${DISKS}; do
            # Try to get SMART info (may fail for hardware RAID, USB, etc.)
            SMART_OUT=$(smartctl -iHA "${disk}" 2>/dev/null) || {
                printf "  ${YELLOW}%-18s %-10s${NC}\n" "${disk}" "N/A (no SMART)"
                continue
            }

            # Overall health
            HEALTH=$(echo "${SMART_OUT}" | grep -i "SMART overall-health" | awk -F': *' '{print $2}' | xargs)
            [ -z "${HEALTH}" ] && HEALTH=$(echo "${SMART_OUT}" | grep -i "SMART Health Status" | awk -F': *' '{print $2}' | xargs)
            [ -z "${HEALTH}" ] && HEALTH="UNKNOWN"

            # Temperature
            TEMP=$(echo "${SMART_OUT}" | grep -iE "^194|Temperature_Celsius|Temperature:" | awk '{for(i=1;i<=NF;i++) if($i+0==$i && $i>0 && $i<120){print $i"°C"; exit}}')
            [ -z "${TEMP}" ] && TEMP="—"

            # Model
            MODEL=$(echo "${SMART_OUT}" | grep -iE "^Device Model|^Model Number|^Product:" | head -1 | awk -F': *' '{print $2}' | xargs)
            [ -z "${MODEL}" ] && MODEL="—"

            # Colour-code health
            case "${HEALTH}" in
                PASSED|OK)
                    printf "  ${GREEN}%-18s %-10s${NC} %-8s %s\n" "${disk}" "${HEALTH}" "${TEMP}" "${MODEL}"
                    ;;
                *)
                    printf "  ${RED}%-18s %-10s${NC} %-8s %s\n" "${disk}" "${HEALTH}" "${TEMP}" "${MODEL}"
                    ISSUES=$((ISSUES + 1))
                    ;;
            esac
        done
    fi

    # Check for reallocated / pending / offline sectors on SATA drives
    echo ""
    PROBLEM_ATTRS=$(smartctl --scan | awk '{print $1}' | while read -r d; do
        smartctl -A "${d}" 2>/dev/null | awk '
            /Reallocated_Sector_Ct/  && $10+0 > 0 { printf "  ⚠  %s — Reallocated sectors: %s\n", "'"${d}"'", $10 }
            /Current_Pending_Sector/ && $10+0 > 0 { printf "  ⚠  %s — Pending sectors: %s\n",     "'"${d}"'", $10 }
            /Offline_Uncorrectable/  && $10+0 > 0 { printf "  ⚠  %s — Offline uncorrectable: %s\n","'"${d}"'", $10 }
        '
    done)

    if [ -n "${PROBLEM_ATTRS}" ]; then
        log_warn "SMART attribute warnings:"
        echo "${PROBLEM_ATTRS}"
        ISSUES=$((ISSUES + 1))
    else
        log_ok "No critical SMART attribute warnings."
    fi
fi

# ============================================================
#  Section 2 — Vzdump Backup Audit
# ============================================================
echo ""
printf "  ${BOLD}② Backup Audit (last %s day%s)${NC}\n" "${LOOKBACK_DAYS}" "$([ "${LOOKBACK_DAYS}" -gt 1 ] && echo 's')"
hr
echo ""

OK_COUNT=0; FAIL_COUNT=0; WARN_COUNT=0

# Calculate cutoff epoch (GNU or BSD date)
CUTOFF=$(date -d "-${LOOKBACK_DAYS} days" +%s 2>/dev/null || date -v-"${LOOKBACK_DAYS}"d +%s 2>/dev/null)

if command -v pvesh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # ---- pvesh API method ----
    log_info "Querying via pvesh API..."
    NODE=$(hostname)

    TASKS=$(pvesh get "/nodes/${NODE}/tasks" \
        --typefilter vzdump \
        --since "${CUTOFF}" \
        --output-format json 2>/dev/null) || TASKS="[]"

    if [ "${TASKS}" = "[]" ] || [ -z "${TASKS}" ]; then
        log_warn "No vzdump tasks found."
    else
        printf "  ${BOLD}%-22s  %-8s  %-10s  %s${NC}\n" "DATE" "VMID" "STATUS" "DURATION"
        hr

        echo "${TASKS}" | jq -r '.[] | "\(.starttime)|\(.status)|\(.id // "—")|\(.endtime // 0)"' \
        | while IFS='|' read -r start status vmid endts; do
            task_date=$(date -d "@${start}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "${start}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "${start}")

            duration="—"
            if [ "${endts}" -gt 0 ] 2>/dev/null; then
                secs=$((endts - start))
                duration="$(( secs / 60 ))m $(( secs % 60 ))s"
            fi

            case "${status}" in
                OK)
                    printf "  ${GREEN}%-22s  %-8s  %-10s${NC}  %s\n" "${task_date}" "${vmid}" "OK" "${duration}"
                    OK_COUNT=$((OK_COUNT + 1))
                    ;;
                "")
                    printf "  ${YELLOW}%-22s  %-8s  %-10s${NC}  %s\n" "${task_date}" "${vmid}" "RUNNING" "${duration}"
                    WARN_COUNT=$((WARN_COUNT + 1))
                    ;;
                *)
                    printf "  ${RED}%-22s  %-8s  %-10s${NC}  %s\n" "${task_date}" "${vmid}" "${status}" "${duration}"
                    FAIL_COUNT=$((FAIL_COUNT + 1))
                    ;;
            esac
        done
    fi
else
    # ---- Filesystem fallback ----
    TASK_DIR="/var/log/pve/tasks"
    if [ -d "${TASK_DIR}" ]; then
        log_info "Scanning ${TASK_DIR}..."

        # Collect index files
        INDEX_FILES=()
        [ -f "${TASK_DIR}/active" ] && INDEX_FILES+=("${TASK_DIR}/active")

        _old_ng=$(shopt -p nullglob || true)
        shopt -s nullglob
        for f in "${TASK_DIR}"/index*; do
            [ -f "${f}" ] && INDEX_FILES+=("${f}")
        done
        eval "${_old_ng}"

        if [ ${#INDEX_FILES[@]} -eq 0 ]; then
            log_warn "No task index files found."
        else
            printf "  ${BOLD}%-22s  %-8s  %s${NC}\n" "DATE" "STATUS" "UPID (short)"
            hr

            for idx in "${INDEX_FILES[@]}"; do
                while IFS=' ' read -r upid rest; do
                    case "${upid}" in *vzdump*) ;; *) continue ;; esac

                    # Extract the hex start-time from the UPID (field 5, colon-separated)
                    hex_ts=$(echo "${upid}" | awk -F: '{print $5}')
                    ts_dec=0
                    if [[ "${hex_ts}" =~ ^[0-9A-Fa-f]+$ ]]; then
                        ts_dec=$((16#${hex_ts})) 2>/dev/null || ts_dec=0
                    fi
                    [ "${ts_dec}" -lt "${CUTOFF}" ] 2>/dev/null && continue

                    task_date=$(date -d "@${ts_dec}" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "${ts_dec}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

                    # Status is the last field after the UPID line in the index
                    status=$(echo "${rest}" | awk '{print $NF}')

                    upid_short="${upid:0:35}…"

                    case "${status}" in
                        OK)
                            printf "  ${GREEN}%-22s  %-8s${NC}  %s\n" "${task_date}" "OK" "${upid_short}"
                            OK_COUNT=$((OK_COUNT + 1)) ;;
                        ""|" ")
                            printf "  ${YELLOW}%-22s  %-8s${NC}  %s\n" "${task_date}" "RUNNING" "${upid_short}"
                            WARN_COUNT=$((WARN_COUNT + 1)) ;;
                        *)
                            printf "  ${RED}%-22s  %-8s${NC}  %s\n" "${task_date}" "${status}" "${upid_short}"
                            FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
                    esac
                done < "${idx}" 2>/dev/null || true
            done
        fi
    else
        log_warn "${TASK_DIR} not found."
        if ! command -v pvesh >/dev/null 2>&1; then
            log_warn "pvesh not available either."
        fi
        if ! command -v jq >/dev/null 2>&1; then
            log_warn "Install jq for API mode: apt install jq"
        fi
    fi
fi

echo ""
printf "  ${BOLD}Backup Summary${NC}\n"
hr
printf "  ${GREEN}OK:${NC}       %d\n" "${OK_COUNT}"
printf "  ${RED}Failed:${NC}   %d\n"  "${FAIL_COUNT}"
printf "  ${YELLOW}Running:${NC}  %d\n" "${WARN_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
    ISSUES=$((ISSUES + 1))
fi

# ============================================================
#  Overall Verdict
# ============================================================
echo ""
hr
if [ "${ISSUES}" -eq 0 ]; then
    printf "  ${GREEN}${BOLD}✔ Host is healthy — no issues detected.${NC}\n"
else
    printf "  ${RED}${BOLD}✖ %d issue(s) detected — review the output above.${NC}\n" "${ISSUES}"
fi
hr
echo ""

exit "${ISSUES}"
