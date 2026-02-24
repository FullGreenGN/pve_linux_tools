#!/bin/bash
# ============================================================
#  lxc_baseline_setup.sh
#  Standardizes a freshly created LXC container with a
#  consistent baseline: timezone, locale, common packages,
#  SSH hardening, and basic firewall rules.
#
#  Supports: Debian/Ubuntu, Alpine, Arch, Fedora
#  Usage:    ./lxc_baseline_setup.sh <CTID> [--timezone TZ]
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
TIMEZONE="Europe/Berlin"

# ---- Usage ----
usage() {
    echo "Usage: $0 <CTID> [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --timezone TZ    Set timezone (default: ${TIMEZONE})"
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 105 --timezone America/New_York"
    exit 0
}

# ---- Parse arguments ----
if [ $# -lt 1 ]; then
    usage
fi

CTID="$1"
shift

while [ $# -gt 0 ]; do
    case "$1" in
        --timezone|-tz)
            TIMEZONE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_err "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ---- Pre-flight checks ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

# Verify the container exists and is running
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
    log_err "Unsupported or undetectable OS in container ${CTID}. Aborting."
    exit 1
fi

log_info "Detected OS: ${OS}"

# ============================================================
#  Phase 1 — Set Timezone
# ============================================================
log_info "Setting timezone to ${TIMEZONE}..."

case ${OS} in
    debian|fedora)
        pct exec "${CTID}" -- bash -c "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime"
        pct exec "${CTID}" -- bash -c "echo '${TIMEZONE}' > /etc/timezone"
        ;;
    alpine)
        pct exec "${CTID}" -- ash -c "apk add --no-cache tzdata && cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && echo '${TIMEZONE}' > /etc/timezone"
        ;;
    arch)
        pct exec "${CTID}" -- bash -c "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && hwclock --systohc"
        ;;
esac
log_ok "Timezone set."

# ============================================================
#  Phase 2 — Install Common Packages
# ============================================================
log_info "Installing baseline packages..."

case ${OS} in
    debian)
        pct exec "${CTID}" -- bash -c "
            apt-get update -qq
            apt-get install -y -qq \
                curl wget nano htop git \
                ca-certificates gnupg \
                unattended-upgrades apt-listchanges \
                ufw openssh-server
        "
        ;;
    alpine)
        pct exec "${CTID}" -- ash -c "
            apk update
            apk add --no-cache \
                curl wget nano htop git \
                ca-certificates openssh \
                ufw
        "
        ;;
    arch)
        pct exec "${CTID}" -- bash -c "
            pacman -Syu --noconfirm
            pacman -S --noconfirm --needed \
                curl wget nano htop git \
                ca-certificates openssh \
                ufw
        "
        ;;
    fedora)
        pct exec "${CTID}" -- bash -c "
            dnf upgrade -y --quiet
            dnf install -y --quiet \
                curl wget nano htop git \
                ca-certificates openssh-server \
                firewalld
        "
        ;;
esac
log_ok "Baseline packages installed."

# ============================================================
#  Phase 3 — SSH Hardening
# ============================================================
log_info "Applying SSH hardening..."

# Common sshd_config hardening (works on all distros)
pct exec "${CTID}" -- sh -c "
    SSHD_CONF='/etc/ssh/sshd_config'
    if [ -f \"\${SSHD_CONF}\" ]; then
        sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \"\${SSHD_CONF}\"
        sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' \"\${SSHD_CONF}\"
        sed -i 's/^#\\?X11Forwarding.*/X11Forwarding no/' \"\${SSHD_CONF}\"
        sed -i 's/^#\\?MaxAuthTries.*/MaxAuthTries 3/' \"\${SSHD_CONF}\"
    fi
"

# Restart SSH
case ${OS} in
    debian|arch|fedora)
        pct exec "${CTID}" -- bash -c "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true"
        ;;
    alpine)
        pct exec "${CTID}" -- ash -c "rc-service sshd restart 2>/dev/null || true"
        ;;
esac
log_ok "SSH hardened."

# ============================================================
#  Phase 4 — Basic Firewall
# ============================================================
log_info "Configuring firewall..."

case ${OS} in
    debian|alpine|arch)
        pct exec "${CTID}" -- sh -c "
            ufw default deny incoming 2>/dev/null || true
            ufw default allow outgoing 2>/dev/null || true
            ufw allow ssh 2>/dev/null || true
            yes | ufw enable 2>/dev/null || true
        "
        ;;
    fedora)
        pct exec "${CTID}" -- bash -c "
            systemctl enable --now firewalld 2>/dev/null || true
            firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
        "
        ;;
esac
log_ok "Firewall configured (SSH allowed)."

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
log_info "Summary of changes applied:"
echo "  • Timezone:  ${TIMEZONE}"
echo "  • Packages:  curl, wget, nano, htop, git, ca-certificates, ssh"
echo "  • SSH:       Root → key-only, password auth disabled, max 3 tries"
echo "  • Firewall:  Deny incoming (except SSH), allow outgoing"
if [ "${OS}" = "debian" ]; then
    echo "  • Locale:    en_US.UTF-8"
fi
echo ""
log_warn "Remember to add your SSH public key to the container!"
echo "  pct exec ${CTID} -- mkdir -p /root/.ssh"
echo "  pct push ${CTID} ~/.ssh/id_rsa.pub /root/.ssh/authorized_keys"
echo ""
