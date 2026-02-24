#!/bin/bash
# ============================================================
#  setup.sh — pve_linux_tools Master Installer
# ============================================================
#  Central entry point for all Proxmox VE automation tasks.
#  Presents a select-based menu for:
#    1. Updating all LXC containers (with ZFS/LVM snapshots)
#    2. Deploying the monitoring stack (Traefik + InfluxDB + Grafana)
#    3. Bootstrapping a new LXC ("Golden Image" baseline)
#    4. Running a host health check (SMART + backup audit)
#    5. Exiting
#
#  Requirements: root privileges on a Proxmox VE host.
# ============================================================

set -euo pipefail

# ---- Resolve paths relative to this script ----
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
readonly COMPOSE_DIR="${SCRIPT_DIR}/docker_compose/monitoring"
TMPDIR_SETUP=""

# ---- Colours & formatting ----
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly NC='\033[0m'

log_info()  { printf "${CYAN}  ℹ${NC}  %s\n" "$*"; }
log_ok()    { printf "${GREEN}  ✔${NC}  %s\n" "$*"; }
log_warn()  { printf "${YELLOW}  ⚠${NC}  %s\n" "$*"; }
log_err()   { printf "${RED}  ✖${NC}  %s\n" "$*"; }
hr()        { printf "${DIM}  %s${NC}\n" "─────────────────────────────────────────────────"; }

# ============================================================
#  Cleanup — runs on any exit
# ============================================================
cleanup() {
    [ -n "${TMPDIR_SETUP}" ] && [ -d "${TMPDIR_SETUP}" ] && rm -rf "${TMPDIR_SETUP}"
}
trap cleanup EXIT INT TERM HUP

# ============================================================
#  Pre-flight checks
# ============================================================
preflight() {
    if [ "$(id -u)" -ne 0 ]; then
        log_err "This installer must be run as root."
        exit 1
    fi

    if [ ! -x /usr/bin/pveversion ]; then
        log_err "Not a Proxmox VE host (/usr/bin/pveversion missing). Aborting."
        exit 1
    fi

    for f in update_containers.sh bootstrap_lxc.sh pve_health.sh; do
        if [ ! -f "${SCRIPTS_DIR}/${f}" ]; then
            log_err "Missing required script: scripts/${f}"
            exit 1
        fi
    done

    TMPDIR_SETUP=$(mktemp -d /tmp/pve_tools.XXXXXX)
    chmod +x "${SCRIPTS_DIR}"/*.sh
}

# ============================================================
#  Banner
# ============================================================
show_banner() {
    clear
    printf "${GREEN}"
    cat << 'EOF'

    ╔═══════════════════════════════════════════════╗
    ║       ___  _   _____   _____           _      ║
    ║      | _ \| | / / __| |_   _|___  ___ | |___  ║
    ║      |  _/| |/ /| _|    | | / _ \/ _ \| (_-<  ║
    ║      |_|   \__/ |___|   |_| \___/\___/|_/__/  ║
    ║                                               ║
    ╚═══════════════════════════════════════════════╝
EOF
    printf "${NC}\n"
    printf "  ${DIM}%s${NC}\n" "$(pveversion 2>/dev/null || echo 'Proxmox VE')"
    hr
    echo ""
}

# ============================================================
#  Menu Option 1 — Update All Containers
# ============================================================
do_update_containers() {
    hr
    log_info "Launching Smart LXC Updater..."
    hr
    echo ""
    bash "${SCRIPTS_DIR}/update_containers.sh"
}

# ============================================================
#  Menu Option 2 — Deploy Monitoring Stack
# ============================================================
ensure_docker() {
    # Returns 0 if docker + compose are available
    command -v docker >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1 || return 1
    return 0
}

offer_docker_install() {
    echo ""
    log_warn "Docker and/or Docker Compose not found."
    echo ""
    read -rp "$(printf "  ${YELLOW}Install Docker now via get.docker.com? [y/N]:${NC} ")" ans
    case "${ans}" in
        [yY]|[yY][eE][sS])
            log_info "Downloading and running the official Docker install script..."
            curl -fsSL https://get.docker.com | bash
            systemctl enable --now docker
            log_ok "Docker installed successfully."
            ;;
        *)
            log_err "Cannot deploy the monitoring stack without Docker."
            return 1
            ;;
    esac
}

do_monitoring_stack() {
    hr
    log_info "Monitoring Stack Deployment"
    hr
    echo ""

    if ! ensure_docker; then
        offer_docker_install || return
    fi
    log_ok "Docker $(docker --version | awk '{print $3}' | tr -d ',')"

    if [ ! -f "${COMPOSE_DIR}/.env" ]; then
        log_err "Missing .env template at: ${COMPOSE_DIR}/.env"
        log_info "Copy the template and fill in your values first."
        return
    fi

    echo ""
    read -rp "$(printf "  ${CYAN}Review .env before deploying? [y/N]:${NC} ")" review
    if [[ "${review}" =~ ^[yY] ]]; then
        echo ""
        hr
        cat "${COMPOSE_DIR}/.env"
        hr
        echo ""
        read -rp "$(printf "  ${CYAN}Proceed with deployment? [y/N]:${NC} ")" proceed
        [[ "${proceed}" =~ ^[yY] ]] || { log_info "Cancelled."; return; }
    fi

    log_info "Starting stack..."
    echo ""
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "${COMPOSE_DIR}/docker-compose.yml" \
                        --env-file "${COMPOSE_DIR}/.env" up -d
    else
        docker-compose -f "${COMPOSE_DIR}/docker-compose.yml" \
                        --env-file "${COMPOSE_DIR}/.env" up -d
    fi

    local HOST_IP
    HOST_IP=$(hostname -I | awk '{print $1}')
    echo ""
    log_ok "Monitoring stack is running."
    log_info "Grafana  → http://${HOST_IP}:3000"
    log_info "InfluxDB → http://${HOST_IP}:8086"
    log_info "Traefik  → http://${HOST_IP}:8080/dashboard/"
}

# ============================================================
#  Menu Option 3 — Bootstrap LXC ("Golden Image")
# ============================================================
do_bootstrap_lxc() {
    hr
    log_info "LXC Golden-Image Bootstrapper"
    hr
    echo ""

    log_info "Running containers:"
    echo ""
    printf "  ${BOLD}%-8s %-12s %s${NC}\n" "CTID" "STATUS" "HOSTNAME"
    hr
    pct list | awk 'NR>1 {printf "  %-8s %-12s %s\n", $1, $2, $3}'
    echo ""

    read -rp "  Enter the Container ID (CTID) to bootstrap: " ctid
    if ! [[ "${ctid}" =~ ^[0-9]+$ ]]; then
        log_err "Invalid CTID '${ctid}'. Must be numeric."
        return
    fi
    if ! pct status "${ctid}" >/dev/null 2>&1; then
        log_err "Container ${ctid} does not exist."
        return
    fi

    read -rp "  Timezone [Europe/Berlin]: " tz
    tz="${tz:-Europe/Berlin}"

    echo ""
    bash "${SCRIPTS_DIR}/bootstrap_lxc.sh" "${ctid}" --timezone "${tz}"
}

# ============================================================
#  Menu Option 4 — Host Health Check
# ============================================================
do_health_check() {
    hr
    log_info "Host Health Check"
    hr
    echo ""
    bash "${SCRIPTS_DIR}/pve_health.sh"
}

# ============================================================
#  Main Menu (select loop)
# ============================================================
main() {
    preflight

    while true; do
        show_banner

        PS3=$'\n  Select an option: '
        select opt in \
            "Update All Containers   (snapshot + upgrade)" \
            "Setup Monitoring Stack  (Traefik / InfluxDB / Grafana)" \
            "LXC Bootstrapper        (Golden Image setup)" \
            "Host Health Check       (SMART + backup audit)" \
            "Exit"; do

            case "${REPLY}" in
                1) do_update_containers  ; break ;;
                2) do_monitoring_stack   ; break ;;
                3) do_bootstrap_lxc      ; break ;;
                4) do_health_check       ; break ;;
                5) echo ""; log_ok "Goodbye."; exit 0 ;;
                *) log_err "Invalid option '${REPLY}'" ; break ;;
            esac
        done

        echo ""
        read -rp "$(printf "  ${DIM}Press Enter to return to the menu...${NC}")"
    done
}

main "$@"
