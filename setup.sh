#!/bin/bash
# ============================================================
#  setup.sh — Master Installer for pve_linux_tools
# ============================================================
#  Interactive menu to manage Proxmox VE containers, deploy
#  the monitoring stack, configure backup monitoring, and
#  harden LXC containers.
#
#  Usage:  ./setup.sh
#  Requires: root on a Proxmox VE host
# ============================================================

set -euo pipefail

# ---- Paths (relative to this script) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
COMPOSE_DIR="${SCRIPT_DIR}/docker_compose/monitoring"
TMPDIR_SETUP=""

# ---- Colours ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Helpers ----
log_info()    { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
log_ok()      { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
log_err()     { printf "${RED}[FAIL]${NC}  %s\n" "$*"; }
separator()   { echo "──────────────────────────────────────────────"; }

# ============================================================
#  Cleanup trap — runs on EXIT, INT, TERM
# ============================================================
cleanup() {
    if [ -n "${TMPDIR_SETUP}" ] && [ -d "${TMPDIR_SETUP}" ]; then
        rm -rf "${TMPDIR_SETUP}"
    fi
    echo ""
    log_info "Goodbye."
}
trap cleanup EXIT INT TERM

# ============================================================
#  Pre-flight checks
# ============================================================
preflight() {
    # 1. Root check
    if [ "$(id -u)" -ne 0 ]; then
        log_err "This installer must be run as root."
        exit 1
    fi

    # 2. Proxmox VE host check
    if [ ! -x /usr/bin/pveversion ]; then
        log_err "This does not appear to be a Proxmox VE host."
        log_err "/usr/bin/pveversion not found. Aborting."
        exit 1
    fi

    # 3. Create a temporary working directory
    TMPDIR_SETUP=$(mktemp -d /tmp/pve_linux_tools.XXXXXX)

    # 4. Verify sub-scripts exist
    for script in update_containers.sh pve_backup_check.sh lxc_baseline_setup.sh; do
        if [ ! -f "${SCRIPTS_DIR}/${script}" ]; then
            log_err "Missing required script: scripts/${script}"
            exit 1
        fi
    done

    log_ok "Proxmox VE $(pveversion --verbose 2>/dev/null | head -1 | awk '{print $NF}') detected."
}

# ============================================================
#  Option 1 — Update All Containers
# ============================================================
do_update_containers() {
    separator
    log_info "Launching Smart LXC Updater..."
    separator
    echo ""
    bash "${SCRIPTS_DIR}/update_containers.sh"
}

# ============================================================
#  Option 2 — Install / Launch Monitoring Stack
# ============================================================
check_docker() {
    local missing=()

    if ! command -v docker >/dev/null 2>&1; then
        missing+=("docker")
    fi

    # docker compose v2 (plugin) or docker-compose v1
    if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
        missing+=("docker-compose")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        return 1
    fi
    return 0
}

install_docker() {
    log_info "Installing Docker Engine via the official convenience script..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
    log_ok "Docker installed and started."
}

do_monitoring_stack() {
    separator
    log_info "Monitoring Stack Deployment"
    separator
    echo ""

    # ---- Dependency check ----
    if ! check_docker; then
        log_warn "Docker and/or Docker Compose are not installed."
        echo ""
        read -rp "$(printf "${YELLOW}Would you like to install Docker now? [y/N]:${NC} ")" INSTALL_DOCKER
        case "${INSTALL_DOCKER}" in
            [yY]|[yY][eE][sS])
                install_docker
                ;;
            *)
                log_err "Cannot deploy the monitoring stack without Docker. Returning to menu."
                return
                ;;
        esac
    fi

    log_ok "Docker is available: $(docker --version)"

    # ---- Check for .env ----
    if [ ! -f "${COMPOSE_DIR}/.env" ]; then
        log_err "Environment file not found: ${COMPOSE_DIR}/.env"
        log_err "Copy the template and fill in your values first."
        return
    fi

    # ---- Offer to review .env ----
    echo ""
    read -rp "$(printf "${CYAN}Review .env before deploying? [y/N]:${NC} ")" REVIEW_ENV
    if [[ "${REVIEW_ENV}" =~ ^[yY] ]]; then
        echo ""
        separator
        cat "${COMPOSE_DIR}/.env"
        separator
        echo ""
        read -rp "$(printf "${CYAN}Continue with deployment? [y/N]:${NC} ")" CONTINUE
        if [[ ! "${CONTINUE}" =~ ^[yY] ]]; then
            log_info "Deployment cancelled."
            return
        fi
    fi

    # ---- Deploy ----
    log_info "Starting stack in ${COMPOSE_DIR}..."
    echo ""

    if docker compose version >/dev/null 2>&1; then
        docker compose -f "${COMPOSE_DIR}/docker-compose.yml" --env-file "${COMPOSE_DIR}/.env" up -d
    else
        docker-compose -f "${COMPOSE_DIR}/docker-compose.yml" --env-file "${COMPOSE_DIR}/.env" up -d
    fi

    echo ""
    log_ok "Monitoring stack is running."
    log_info "Grafana  → http://$(hostname -I | awk '{print $1}'):3000"
    log_info "InfluxDB → http://$(hostname -I | awk '{print $1}'):8086"
}

# ============================================================
#  Option 3 — Setup Backup Monitor Cron
# ============================================================
do_backup_monitor() {
    separator
    log_info "Backup Monitor — Cron Setup"
    separator
    echo ""

    local SCRIPT_PATH="${SCRIPTS_DIR}/pve_backup_check.sh"
    local LOG_PATH="/var/log/pve_backup_check.log"

    # Show current crontab entries for this script
    if crontab -l 2>/dev/null | grep -q "pve_backup_check.sh"; then
        log_warn "An existing cron entry was found:"
        crontab -l 2>/dev/null | grep "pve_backup_check.sh"
        echo ""
        read -rp "$(printf "${YELLOW}Replace the existing entry? [y/N]:${NC} ")" REPLACE
        if [[ ! "${REPLACE}" =~ ^[yY] ]]; then
            log_info "Keeping existing cron job. Returning to menu."
            return
        fi
        # Remove old entry
        crontab -l 2>/dev/null | grep -v "pve_backup_check.sh" | crontab -
        log_ok "Old cron entry removed."
    fi

    echo ""
    echo "  When should the backup check run?"
    echo ""
    echo "    1) Daily at 07:00 AM"
    echo "    2) Daily at 09:00 AM"
    echo "    3) Every 6 hours"
    echo "    4) Custom (enter your own cron expression)"
    echo ""
    read -rp "  Select [1-4]: " CRON_CHOICE

    case "${CRON_CHOICE}" in
        1) CRON_EXPR="0 7 * * *"   ;;
        2) CRON_EXPR="0 9 * * *"   ;;
        3) CRON_EXPR="0 */6 * * *" ;;
        4)
            read -rp "  Enter cron expression (e.g. '30 6 * * 1-5'): " CRON_EXPR
            ;;
        *)
            log_err "Invalid selection."
            return
            ;;
    esac

    # How many days to look back
    read -rp "  Days to look back [default: 1]: " LOOKBACK
    LOOKBACK="${LOOKBACK:-1}"

    # Build the cron line
    CRON_LINE="${CRON_EXPR} ${SCRIPT_PATH} --days ${LOOKBACK} >> ${LOG_PATH} 2>&1"

    # Install
    (crontab -l 2>/dev/null; echo "${CRON_LINE}") | crontab -

    echo ""
    log_ok "Cron job installed:"
    echo "  ${CRON_LINE}"
    log_info "Logs will be written to ${LOG_PATH}"
}

# ============================================================
#  Option 4 — LXC Hardening / Baseline Setup
# ============================================================
do_lxc_hardening() {
    separator
    log_info "LXC Baseline Hardening"
    separator
    echo ""

    # List running containers for reference
    log_info "Currently running containers:"
    echo ""
    printf "  ${BOLD}%-8s %-12s %s${NC}\n" "CTID" "STATUS" "HOSTNAME"
    separator
    pct list | awk 'NR>1 {printf "  %-8s %-12s %s\n", $1, $2, $3}'
    echo ""

    read -rp "  Enter the Container ID (CTID) to harden: " TARGET_CTID

    # Validate input
    if ! [[ "${TARGET_CTID}" =~ ^[0-9]+$ ]]; then
        log_err "Invalid CTID: '${TARGET_CTID}'. Must be a number."
        return
    fi

    # Check container exists
    if ! pct status "${TARGET_CTID}" >/dev/null 2>&1; then
        log_err "Container ${TARGET_CTID} does not exist."
        return
    fi

    # Optional timezone override
    read -rp "  Timezone [default: Europe/Berlin]: " TZ_INPUT
    TZ_INPUT="${TZ_INPUT:-Europe/Berlin}"

    echo ""
    log_info "Running baseline setup on CT ${TARGET_CTID}..."
    echo ""
    bash "${SCRIPTS_DIR}/lxc_baseline_setup.sh" "${TARGET_CTID}" --timezone "${TZ_INPUT}"
}

# ============================================================
#  Main Menu
# ============================================================
show_banner() {
    clear
    echo ""
    printf "${GREEN}"
    cat << 'BANNER'
   ___  _   _____   _    _                 _____          _
  | _ \| | / / __| | |  (_)_ _ _  ___ __  |_   _|___ ___ | |___
  |  _/| |/ /| _|  | |__| | ' \ || \ \ /   | | / _ \/ _ \| (_-<
  |_|   \__/ |___| |____|_|_||_\_,_/_\_\   |_| \___/\___/|_/__/

BANNER
    printf "${NC}"
    echo "  Proxmox VE — Automation Toolkit Installer"
    echo "  $(pveversion 2>/dev/null || echo 'PVE Host')"
    separator
    echo ""
}

main_menu() {
    while true; do
        show_banner

        echo "  ${BOLD}What would you like to do?${NC}"
        echo ""
        echo "    ${GREEN}1)${NC}  Update All Containers       (snapshot + update)"
        echo "    ${GREEN}2)${NC}  Install Monitoring Stack    (Traefik + InfluxDB + Grafana)"
        echo "    ${GREEN}3)${NC}  Setup Backup Monitor        (cron job for vzdump checks)"
        echo "    ${GREEN}4)${NC}  LXC Hardening               (baseline setup on a container)"
        echo ""
        echo "    ${RED}5)${NC}  Exit"
        echo ""

        read -rp "  Select an option [1-5]: " CHOICE
        echo ""

        case "${CHOICE}" in
            1) do_update_containers   ;;
            2) do_monitoring_stack    ;;
            3) do_backup_monitor      ;;
            4) do_lxc_hardening       ;;
            5) exit 0                 ;;
            *)
                log_err "Invalid option: '${CHOICE}'"
                ;;
        esac

        echo ""
        read -rp "$(printf "${CYAN}Press Enter to return to the main menu...${NC}")"
    done
}

# ============================================================
#  Entry point
# ============================================================
preflight
main_menu
