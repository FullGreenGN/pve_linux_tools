#!/bin/bash
# ============================================================
#  update_containers.sh
#  Automatically update all running LXC containers on a
#  Proxmox VE host. Creates a ZFS/LVM snapshot before each
#  update for instant rollback.
#
#  Snapshot strategy:
#    - ZFS-backed containers  → zfs snapshot
#    - LVM-backed containers  → lvcreate --snapshot
#    - All containers         → pct snapshot (fallback / always)
#
#  Supported OS: Debian/Ubuntu, Alpine, Arch, Fedora
#  Usage:        ./update_containers.sh
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

# ---- Pre-flight: root check ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

DATESTAMP=$(date +%F)
SNAP_NAME="pre_update_${DATESTAMP}"
SUCCESS=0
FAILED=0
SKIPPED=0

echo ""
echo "==========================================="
echo "  Smart LXC Updater — ${DATESTAMP}"
echo "==========================================="
echo ""

# ============================================================
#  Snapshot helper — tries ZFS, then LVM, then pct fallback
# ============================================================
create_snapshot() {
    local CTID="$1"
    local SNAP="$2"

    # Determine the storage backend from the rootfs config
    local ROOTFS
    ROOTFS=$(pct config "${CTID}" | awk -F'[ ,:]' '/^rootfs:/ {print $2}')
    local STORAGE
    STORAGE=$(echo "${ROOTFS}" | cut -d: -f1)

    # Detect storage type via pvesm
    local STORAGE_TYPE=""
    if command -v pvesm >/dev/null 2>&1; then
        STORAGE_TYPE=$(pvesm status | awk -v s="${STORAGE}" '$1==s {print $2}')
    fi

    case "${STORAGE_TYPE}" in
        zfspool|zfs)
            # ---- ZFS snapshot ----
            local ZFS_DATASET
            ZFS_DATASET=$(pvesm path "${ROOTFS}" 2>/dev/null | sed 's|^/||' | head -1)

            if [ -n "${ZFS_DATASET}" ] && zfs list "${ZFS_DATASET}" >/dev/null 2>&1; then
                log_info "  Storage: ZFS (${STORAGE})"
                if zfs snapshot "${ZFS_DATASET}@${SNAP}" 2>/dev/null; then
                    log_ok "  ZFS snapshot created: ${ZFS_DATASET}@${SNAP}"
                    return 0
                else
                    log_warn "  ZFS snapshot failed — falling back to pct snapshot."
                fi
            fi
            ;;
        lvm|lvmthin)
            # ---- LVM snapshot ----
            local LV_PATH
            LV_PATH=$(pvesm path "${ROOTFS}" 2>/dev/null | head -1)

            if [ -n "${LV_PATH}" ] && lvdisplay "${LV_PATH}" >/dev/null 2>&1; then
                log_info "  Storage: LVM (${STORAGE})"
                if lvcreate --snapshot -n "${SNAP}" -L 1G "${LV_PATH}" 2>/dev/null; then
                    log_ok "  LVM snapshot created: ${SNAP}"
                    return 0
                else
                    log_warn "  LVM snapshot failed — falling back to pct snapshot."
                fi
            fi
            ;;
    esac

    # ---- pct snapshot (universal fallback) ----
    log_info "  Storage: ${STORAGE_TYPE:-unknown} → using pct snapshot"
    if pct snapshot "${CTID}" "${SNAP}" --description "Auto-snapshot before update on ${DATESTAMP}" 2>/dev/null; then
        log_ok "  pct snapshot '${SNAP}' created."
    else
        log_warn "  Snapshot failed or already exists — continuing without snapshot."
    fi
}

# ============================================================
#  Main loop
# ============================================================
CONTAINERS=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

if [ -z "${CONTAINERS}" ]; then
    log_warn "No running containers found. Nothing to do."
    exit 0
fi

for CTID in ${CONTAINERS}; do
    NAME=$(pct config "${CTID}" | awk '/^hostname:/ {print $2}')
    log_info "Processing CT ${CTID} (${NAME})..."

    # ---- 1. Create snapshot (ZFS > LVM > pct) ----
    create_snapshot "${CTID}" "${SNAP_NAME}"

    # ---- 2. Detect OS ----
    if pct exec "${CTID}" -- test -f /etc/debian_version 2>/dev/null; then
        OS="debian"
    elif pct exec "${CTID}" -- test -f /etc/alpine-release 2>/dev/null; then
        OS="alpine"
    elif pct exec "${CTID}" -- test -f /etc/arch-release 2>/dev/null; then
        OS="arch"
    elif pct exec "${CTID}" -- test -f /etc/fedora-release 2>/dev/null; then
        OS="fedora"
    else
        OS="unknown"
    fi

    # ---- 3. Run the appropriate update command ----
    UPDATE_OK=true
    case ${OS} in
        debian)
            log_info "  Detected: Debian/Ubuntu (apt)"
            if ! pct exec "${CTID}" -- bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update -qq && apt-get dist-upgrade -y -qq && apt-get autoremove -y -qq"; then
                UPDATE_OK=false
            fi
            ;;
        alpine)
            log_info "  Detected: Alpine (apk)"
            if ! pct exec "${CTID}" -- ash -c "apk update && apk upgrade"; then
                UPDATE_OK=false
            fi
            ;;
        arch)
            log_info "  Detected: Arch (pacman)"
            if ! pct exec "${CTID}" -- bash -c "pacman -Syu --noconfirm"; then
                UPDATE_OK=false
            fi
            ;;
        fedora)
            log_info "  Detected: Fedora (dnf)"
            if ! pct exec "${CTID}" -- bash -c "dnf upgrade -y --quiet"; then
                UPDATE_OK=false
            fi
            ;;
        *)
            log_warn "  Could not detect OS for CT ${CTID}. Skipping."
            SKIPPED=$((SKIPPED + 1))
            echo "--------------------------------------"
            continue
            ;;
    esac

    if [ "${UPDATE_OK}" = true ]; then
        log_ok "  Successfully updated ${NAME} (CT ${CTID})."
        SUCCESS=$((SUCCESS + 1))
    else
        log_err "  Error updating ${NAME} (CT ${CTID})."
        FAILED=$((FAILED + 1))
    fi
    echo "--------------------------------------"
done

echo ""
echo "==========================================="
echo "  Summary"
echo "==========================================="
printf "  ${GREEN}Success:${NC} %d\n" "${SUCCESS}"
printf "  ${RED}Failed:${NC}  %d\n" "${FAILED}"
printf "  ${YELLOW}Skipped:${NC} %d\n" "${SKIPPED}"
echo "==========================================="
echo ""
