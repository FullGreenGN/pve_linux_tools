#!/bin/bash
# ============================================================
#  lxc_baseline_setup.sh
#  "First-run" hardening and standardization for a fresh
#  LXC container. Installs essential packages, sets timezone,
#  configures SSH, and injects an authorized SSH key.
#
#  Supports: Debian/Ubuntu, Alpine, Arch, Fedora
#  Usage:    ./lxc_baseline_setup.sh [CTID] [OPTIONS]
#            (if CTID is omitted, the script will prompt)
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
TIMEZONE="Europe/Berlin"
SSH_KEY_PATH=""
CTID=""

# ---- Usage ----
usage() {
    echo "Usage: $0 [CTID] [OPTIONS]"
    echo ""
    echo "If CTID is omitted, the script will display running"
    echo "containers and prompt you interactively."
    echo ""
    echo "Options:"
    echo "  --timezone TZ       Set timezone (default: ${TIMEZONE})"
    echo "  --ssh-key PATH      Path to a public SSH key to inject"
    echo "  --help, -h          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 105"
    echo "  $0 105 --timezone America/New_York --ssh-key ~/.ssh/id_ed25519.pub"
    echo "  $0                  (interactive mode)"
    exit 0
}

# ---- Parse arguments ----
while [ $# -gt 0 ]; do
    case "$1" in
        --timezone|-tz)
            TIMEZONE="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            # Treat bare numeric args as CTID
            if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "${CTID}" ]; then
                CTID="$1"
                shift
            else
                log_err "Unknown argument: $1"
                exit 1
            fi
            ;;
    esac
done

# ---- Pre-flight: root check ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

# ---- Interactive CTID prompt if not supplied ----
if [ -z "${CTID}" ]; then
    echo ""
    log_info "Available containers:"
    echo ""
    printf "  ${BOLD}%-8s %-12s %s${NC}\n" "CTID" "STATUS" "HOSTNAME"
    separator
    pct list | awk 'NR>1 {printf "  %-8s %-12s %s\n", $1, $2, $3}'
    echo ""
    read -rp "  Enter the Container ID (CTID) to set up: " CTID

    if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then
        log_err "Invalid CTID: '${CTID}'. Must be a number."
        exit 1
    fi
fi

# ---- Verify the container exists ----
CT_STATUS=$(pct status "${CTID}" 2>/dev/null | awk '{print $2}') || true
if [ -z "${CT_STATUS}" ]; then
    log_err "Container ${CTID} does not exist."
    exit 1
fi

if [ "${CT_STATUS}" != "running" ]; then
    log_warn "Container ${CTID} is not running (status: ${CT_STATUS}). Starting it now..."
    pct start "${CTID}"
    sleep 3
fi

NAME=$(pct config "${CTID}" | awk '/^hostname:/ {print $2}')

echo ""
echo "==========================================="
echo "  LXC Baseline Setup — CT ${CTID} (${NAME})"
echo "==========================================="
echo ""

# ---- Detect OS ----
if pct exec "${CTID}" -- test -f /etc/debian_version 2>/dev/null; then
    OS="debian"
elif pct exec "${CTID}" -- test -f /etc/alpine-release 2>/dev/null; then
    OS="alpine"
elif pct exec "${CTID}" -- test -f /etc/arch-release 2>/dev/null; then
    OS="arch"
elif pct exec "${CTID}" -- test -f /etc/fedora-release 2>/dev/null; then
    OS="fedora"
else
    log_err "Unsupported or undetectable OS in container ${CTID}."
    exit 1
fi

log_info "Detected OS: ${OS}"

# ============================================================
#  Phase 1 — Set Timezone
# ============================================================
log_info "Setting timezone to ${TIMEZONE}..."

case ${OS} in
    debian|fedora)
        pct exec "${CTID}" -- bash -c "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && echo '${TIMEZONE}' > /etc/timezone"
        ;;
    alpine)
        pct exec "${CTID}" -- ash -c "apk add --no-cache tzdata >/dev/null 2>&1; cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && echo '${TIMEZONE}' > /etc/timezone"
        ;;
    arch)
        pct exec "${CTID}" -- bash -c "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && hwclock --systohc 2>/dev/null || true"
        ;;
esac
log_ok "Timezone set."

# ============================================================
#  Phase 2 — Install Essential Packages (curl, vim, htop)
# ============================================================
log_info "Installing essential packages (curl, vim, htop)..."

case ${OS} in
    debian)
        pct exec "${CTID}" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq curl vim htop ca-certificates gnupg openssh-server
        "
        ;;
    alpine)
        pct exec "${CTID}" -- ash -c "
            apk update >/dev/null
            apk add --no-cache curl vim htop ca-certificates openssh
        "
        ;;
    arch)
        pct exec "${CTID}" -- bash -c "
            pacman -Sy --noconfirm >/dev/null 2>&1
            pacman -S --noconfirm --needed curl vim htop ca-certificates openssh
        "
        ;;
    fedora)
        pct exec "${CTID}" -- bash -c "
            dnf install -y --quiet curl vim-enhanced htop ca-certificates openssh-server
        "
        ;;
esac
log_ok "Essential packages installed."

# ============================================================
#  Phase 3 — SSH Hardening
# ============================================================
log_info "Hardening SSH configuration..."

pct exec "${CTID}" -- sh -c "
    CONF='/etc/ssh/sshd_config'
    if [ -f \"\${CONF}\" ]; then
        sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \"\${CONF}\"
        sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/'   \"\${CONF}\"
        sed -i 's/^#\\?X11Forwarding.*/X11Forwarding no/'                     \"\${CONF}\"
        sed -i 's/^#\\?MaxAuthTries.*/MaxAuthTries 3/'                         \"\${CONF}\"
    fi
"

case ${OS} in
    debian|arch|fedora)
        pct exec "${CTID}" -- bash -c "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true"
        ;;
    alpine)
        pct exec "${CTID}" -- ash -c "rc-service sshd restart 2>/dev/null || true"
        ;;
esac
log_ok "SSH hardened (key-only auth, max 3 tries)."

# ============================================================
#  Phase 4 — Inject SSH Key
# ============================================================
if [ -n "${SSH_KEY_PATH}" ]; then
    if [ -f "${SSH_KEY_PATH}" ]; then
        log_info "Injecting SSH public key from ${SSH_KEY_PATH}..."
        pct exec "${CTID}" -- mkdir -p /root/.ssh
        pct exec "${CTID}" -- chmod 700 /root/.ssh
        pct push "${CTID}" "${SSH_KEY_PATH}" /root/.ssh/authorized_keys
        pct exec "${CTID}" -- chmod 600 /root/.ssh/authorized_keys
        log_ok "SSH key installed."
    else
        log_warn "SSH key file not found: ${SSH_KEY_PATH} — skipping."
    fi
else
    # Interactive: ask the user
    echo ""
    read -rp "$(printf "${CYAN}Add an SSH public key now? [y/N]:${NC} ")" ADD_KEY
    if [[ "${ADD_KEY}" =~ ^[yY] ]]; then
        read -rp "  Path to public key [~/.ssh/id_rsa.pub]: " KEY_INPUT
        KEY_INPUT="${KEY_INPUT:-$HOME/.ssh/id_rsa.pub}"
        KEY_INPUT="${KEY_INPUT/#\~/$HOME}"

        if [ -f "${KEY_INPUT}" ]; then
            pct exec "${CTID}" -- mkdir -p /root/.ssh
            pct exec "${CTID}" -- chmod 700 /root/.ssh
            pct push "${CTID}" "${KEY_INPUT}" /root/.ssh/authorized_keys
            pct exec "${CTID}" -- chmod 600 /root/.ssh/authorized_keys
            log_ok "SSH key installed from ${KEY_INPUT}."
        else
            log_warn "File not found: ${KEY_INPUT} — skipping SSH key injection."
        fi
    fi
fi

# ============================================================
#  Phase 5 — Locale (Debian/Ubuntu only)
# ============================================================
if [ "${OS}" = "debian" ]; then
    log_info "Generating locale en_US.UTF-8..."
    pct exec "${CTID}" -- bash -c "
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
        locale-gen 2>/dev/null || true
        update-locale LANG=en_US.UTF-8 2>/dev/null || true
    "
    log_ok "Locale set."
fi

# ============================================================
#  Done
# ============================================================
echo ""
echo "==========================================="
echo "  Baseline setup complete for CT ${CTID}"
echo "==========================================="
echo ""
log_info "Summary:"
echo "  • OS:        ${OS}"
echo "  • Timezone:  ${TIMEZONE}"
echo "  • Packages:  curl, vim, htop, ca-certificates, ssh"
echo "  • SSH:       Root → key-only, password auth disabled, max 3 tries"
if [ "${OS}" = "debian" ]; then
    echo "  • Locale:    en_US.UTF-8"
fi
echo ""
