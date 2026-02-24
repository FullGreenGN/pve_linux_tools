#!/bin/bash
# ============================================================
#  update_containers.sh
#  Detects every running LXC on the Proxmox host, creates a
#  storage-aware snapshot (ZFS → LVM → pct fallback), then
#  runs the appropriate OS update.
#
#  Supported: Debian/Ubuntu · Alpine · Arch · Fedora
#  Usage:     ./update_containers.sh
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

# ---- Root check ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

readonly DATESTAMP=$(date +%F)
readonly SNAP_NAME="pre_update_${DATESTAMP}"

SUCCESS=0; FAILED=0; SKIPPED=0

echo ""
printf "  ${BOLD}Smart LXC Updater — %s${NC}\n" "${DATESTAMP}"
hr
echo ""

# ============================================================
#  create_snapshot <CTID> <SNAP_NAME>
#  Tries ZFS → LVM → pct snapshot as a universal fallback.
# ============================================================
create_snapshot() {
    local ctid="$1" snap="$2"

    # Determine storage type from rootfs config line
    local rootfs storage stype=""
    rootfs=$(pct config "${ctid}" | awk -F'[ ,:]' '/^rootfs:/ {print $2}')
    storage=$(echo "${rootfs}" | cut -d: -f1)

    if command -v pvesm >/dev/null 2>&1; then
        stype=$(pvesm status | awk -v s="${storage}" '$1==s {print $2}')
    fi

    case "${stype}" in
        zfspool|zfs)
            local dataset
            dataset=$(pvesm path "${rootfs}" 2>/dev/null | sed 's|^/||' | head -1)
            if [ -n "${dataset}" ] && zfs list "${dataset}" >/dev/null 2>&1; then
                log_info "  Storage: ZFS → zfs snapshot"
                if zfs snapshot "${dataset}@${snap}" 2>/dev/null; then
                    log_ok "  Snapshot: ${dataset}@${snap}"
                    return 0
                fi
                log_warn "  ZFS snapshot failed — falling back to pct."
            fi
            ;;
        lvm|lvmthin)
            local lvpath
            lvpath=$(pvesm path "${rootfs}" 2>/dev/null | head -1)
            if [ -n "${lvpath}" ] && lvdisplay "${lvpath}" >/dev/null 2>&1; then
                log_info "  Storage: LVM → lvcreate --snapshot"
                if lvcreate --snapshot -n "${snap}" -L 1G "${lvpath}" 2>/dev/null; then
                    log_ok "  Snapshot: ${snap}"
                    return 0
                fi
                log_warn "  LVM snapshot failed — falling back to pct."
            fi
            ;;
    esac

    # Universal fallback
    if pct snapshot "${ctid}" "${snap}" \
        --description "Auto pre-update snapshot ${DATESTAMP}" 2>/dev/null; then
        log_ok "  Snapshot: pct snapshot '${snap}'"
    else
        log_warn "  Snapshot skipped (already exists or unsupported)."
    fi
}

# ============================================================
#  detect_os <CTID>  →  prints: debian | alpine | arch | fedora | unknown
# ============================================================
detect_os() {
    local ctid="$1"
    if   pct exec "${ctid}" -- test -f /etc/debian_version  2>/dev/null; then echo "debian"
    elif pct exec "${ctid}" -- test -f /etc/alpine-release  2>/dev/null; then echo "alpine"
    elif pct exec "${ctid}" -- test -f /etc/arch-release    2>/dev/null; then echo "arch"
    elif pct exec "${ctid}" -- test -f /etc/fedora-release  2>/dev/null; then echo "fedora"
    else echo "unknown"
    fi
}

# ============================================================
#  run_update <CTID> <OS>  →  returns 0 on success
# ============================================================
run_update() {
    local ctid="$1" os="$2"
    case "${os}" in
        debian)
            log_info "  Detected: Debian/Ubuntu → apt"
            pct exec "${ctid}" -- bash -c \
                "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get dist-upgrade -y -qq && apt-get autoremove -y -qq"
            ;;
        alpine)
            log_info "  Detected: Alpine → apk"
            pct exec "${ctid}" -- ash -c "apk update && apk upgrade"
            ;;
        arch)
            log_info "  Detected: Arch → pacman"
            pct exec "${ctid}" -- bash -c "pacman -Syu --noconfirm"
            ;;
        fedora)
            log_info "  Detected: Fedora → dnf"
            pct exec "${ctid}" -- bash -c "dnf upgrade -y --quiet"
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
#  Main loop
# ============================================================
CONTAINERS=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

if [ -z "${CONTAINERS}" ]; then
    log_warn "No running containers found."
    exit 0
fi

for CTID in ${CONTAINERS}; do
    NAME=$(pct config "${CTID}" | awk '/^hostname:/ {print $2}')
    log_info "CT ${CTID} (${NAME})"

    create_snapshot "${CTID}" "${SNAP_NAME}"

    OS=$(detect_os "${CTID}")

    if [ "${OS}" = "unknown" ]; then
        log_warn "  OS not recognised — skipping."
        SKIPPED=$((SKIPPED + 1))
        hr
        continue
    fi

    if run_update "${CTID}" "${OS}"; then
        log_ok "  Updated successfully."
        SUCCESS=$((SUCCESS + 1))
    else
        log_err "  Update failed."
        FAILED=$((FAILED + 1))
    fi
    hr
done

echo ""
printf "  ${BOLD}Summary${NC}\n"
hr
printf "  ${GREEN}Success:${NC}  %d\n" "${SUCCESS}"
printf "  ${RED}Failed:${NC}   %d\n"  "${FAILED}"
printf "  ${YELLOW}Skipped:${NC}  %d\n" "${SKIPPED}"
hr
echo ""
