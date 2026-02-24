#!/bin/bash
# ============================================================
#  update_containers.sh
#  Automatically update all running LXC containers on a
#  Proxmox VE host. Creates a snapshot before each update
#  for easy rollback.
#
#  Supported: Debian/Ubuntu, Alpine, Arch, Fedora
#  Usage:     ./update_containers.sh
# ============================================================

set -euo pipefail

# ---- Colours for terminal output ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

# ---- Helpers ----
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

# ---- Gather running containers ----
CONTAINERS=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

if [ -z "${CONTAINERS}" ]; then
    log_warn "No running containers found. Nothing to do."
    exit 0
fi

for CTID in ${CONTAINERS}; do
    NAME=$(pct config "${CTID}" | awk '/^hostname:/ {print $2}')
    log_info "Processing CT ${CTID} (${NAME})..."

    # ---- 1. Create a pre-update snapshot ----
    log_info "  Creating snapshot '${SNAP_NAME}'..."
    if pct snapshot "${CTID}" "${SNAP_NAME}" --description "Auto-snapshot before update on ${DATESTAMP}" 2>/dev/null; then
        log_ok "  Snapshot created."
    else
        log_warn "  Snapshot failed or already exists — continuing without snapshot."
    fi

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
    case ${OS} in
        debian)
            log_info "  Detected: Debian/Ubuntu (apt)"
            pct exec "${CTID}" -- bash -c "apt-get update -qq && apt-get dist-upgrade -y -qq && apt-get autoremove -y -qq"
            ;;
        alpine)
            log_info "  Detected: Alpine (apk)"
            pct exec "${CTID}" -- ash -c "apk update && apk upgrade"
            ;;
        arch)
            log_info "  Detected: Arch (pacman)"
            pct exec "${CTID}" -- bash -c "pacman -Syu --noconfirm"
            ;;
        fedora)
            log_info "  Detected: Fedora (dnf)"
            pct exec "${CTID}" -- bash -c "dnf upgrade -y --quiet"
            ;;
        *)
            log_warn "  Could not detect OS for CT ${CTID}. Skipping."
            SKIPPED=$((SKIPPED + 1))
            echo "--------------------------------------"
            continue
            ;;
    esac

    if [ $? -eq 0 ]; then
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
