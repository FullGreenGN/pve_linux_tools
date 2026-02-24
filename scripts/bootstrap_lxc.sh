#!/bin/bash
# ============================================================
#  bootstrap_lxc.sh
#  Applies a "Golden Image" baseline to a fresh LXC container.
#
#  What it does:
#    1. Sets the timezone
#    2. Installs core tools (curl, vim, htop, git, ca-certs)
#    3. Hardens SSH (key-only, no passwords, max 3 tries)
#    4. Injects an SSH public key
#    5. Configures locale (Debian/Ubuntu)
#
#  Supports: Debian/Ubuntu · Alpine · Arch · Fedora
#  Usage:    ./bootstrap_lxc.sh [CTID] [OPTIONS]
#            (interactive if CTID is omitted)
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
TIMEZONE="Europe/Berlin"
SSH_KEY=""
CTID=""

# ---- Usage ----
usage() {
    cat <<EOF
Usage: $(basename "$0") [CTID] [OPTIONS]

Options:
  --timezone TZ     IANA timezone         (default: Europe/Berlin)
  --ssh-key PATH    Public key to inject  (default: interactive prompt)
  -h, --help        Show this help

Examples:
  $(basename "$0") 105
  $(basename "$0") 105 --timezone America/New_York --ssh-key ~/.ssh/id_ed25519.pub
  $(basename "$0")        # interactive
EOF
    exit 0
}

# ---- Parse args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --timezone|-tz) TIMEZONE="$2"; shift 2 ;;
        --ssh-key)      SSH_KEY="$2";  shift 2 ;;
        -h|--help)      usage ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "${CTID}" ]; then
                CTID="$1"; shift
            else
                log_err "Unknown argument: $1"; exit 1
            fi
            ;;
    esac
done

# ---- Root check ----
if [ "$(id -u)" -ne 0 ]; then
    log_err "This script must be run as root."
    exit 1
fi

# ---- Interactive CTID selection ----
if [ -z "${CTID}" ]; then
    echo ""
    log_info "Available containers:"
    echo ""
    printf "  ${BOLD}%-8s %-12s %s${NC}\n" "CTID" "STATUS" "HOSTNAME"
    hr
    pct list | awk 'NR>1 {printf "  %-8s %-12s %s\n", $1, $2, $3}'
    echo ""
    read -rp "  Enter CTID: " CTID
    [[ "${CTID}" =~ ^[0-9]+$ ]] || { log_err "Invalid CTID."; exit 1; }
fi

# ---- Validate container ----
CT_STATUS=$(pct status "${CTID}" 2>/dev/null | awk '{print $2}') || true
if [ -z "${CT_STATUS}" ]; then
    log_err "Container ${CTID} does not exist."
    exit 1
fi
if [ "${CT_STATUS}" != "running" ]; then
    log_warn "Container ${CTID} is ${CT_STATUS}. Starting..."
    pct start "${CTID}"
    sleep 3
fi

NAME=$(pct config "${CTID}" | awk '/^hostname:/ {print $2}')

echo ""
printf "  ${BOLD}Golden-Image Bootstrap — CT %s (%s)${NC}\n" "${CTID}" "${NAME}"
hr
echo ""

# ---- Detect OS ----
if   pct exec "${CTID}" -- test -f /etc/debian_version  2>/dev/null; then OS="debian"
elif pct exec "${CTID}" -- test -f /etc/alpine-release  2>/dev/null; then OS="alpine"
elif pct exec "${CTID}" -- test -f /etc/arch-release    2>/dev/null; then OS="arch"
elif pct exec "${CTID}" -- test -f /etc/fedora-release  2>/dev/null; then OS="fedora"
else log_err "Unsupported OS."; exit 1
fi
log_info "OS detected: ${OS}"

# ============================================================
#  Phase 1 — Timezone
# ============================================================
log_info "Setting timezone → ${TIMEZONE}"

case ${OS} in
    debian|fedora)
        pct exec "${CTID}" -- bash -c \
            "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && echo '${TIMEZONE}' > /etc/timezone" ;;
    alpine)
        pct exec "${CTID}" -- ash -c \
            "apk add --no-cache tzdata >/dev/null 2>&1; cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime; echo '${TIMEZONE}' > /etc/timezone" ;;
    arch)
        pct exec "${CTID}" -- bash -c \
            "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime; hwclock --systohc 2>/dev/null || true" ;;
esac
log_ok "Timezone set."

# ============================================================
#  Phase 2 — Core tools (curl, vim, htop, git, ca-certificates)
# ============================================================
log_info "Installing core tools..."

case ${OS} in
    debian)
        pct exec "${CTID}" -- bash -c "
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq curl vim htop git ca-certificates gnupg openssh-server
        " ;;
    alpine)
        pct exec "${CTID}" -- ash -c "
            apk update >/dev/null
            apk add --no-cache curl vim htop git ca-certificates openssh
        " ;;
    arch)
        pct exec "${CTID}" -- bash -c "
            pacman -Sy --noconfirm >/dev/null 2>&1
            pacman -S --noconfirm --needed curl vim htop git ca-certificates openssh
        " ;;
    fedora)
        pct exec "${CTID}" -- bash -c "
            dnf install -y --quiet curl vim-enhanced htop git ca-certificates openssh-server
        " ;;
esac
log_ok "Core tools installed."

# ============================================================
#  Phase 3 — SSH hardening
# ============================================================
log_info "Hardening SSH..."

pct exec "${CTID}" -- sh -c '
    CONF="/etc/ssh/sshd_config"
    [ -f "${CONF}" ] || exit 0
    sed -i "s/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/"  "${CONF}"
    sed -i "s/^#\?PasswordAuthentication.*/PasswordAuthentication no/"    "${CONF}"
    sed -i "s/^#\?X11Forwarding.*/X11Forwarding no/"                      "${CONF}"
    sed -i "s/^#\?MaxAuthTries.*/MaxAuthTries 3/"                          "${CONF}"
'

case ${OS} in
    debian|arch|fedora)
        pct exec "${CTID}" -- bash -c "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true" ;;
    alpine)
        pct exec "${CTID}" -- ash -c "rc-service sshd restart 2>/dev/null || true" ;;
esac
log_ok "SSH hardened (key-only, max 3 tries)."

# ============================================================
#  Phase 4 — SSH key injection
# ============================================================
inject_key() {
    local keyfile="$1"
    pct exec "${CTID}" -- mkdir -p /root/.ssh
    pct exec "${CTID}" -- chmod 700 /root/.ssh
    pct push "${CTID}" "${keyfile}" /root/.ssh/authorized_keys
    pct exec "${CTID}" -- chmod 600 /root/.ssh/authorized_keys
    log_ok "SSH key injected."
}

if [ -n "${SSH_KEY}" ]; then
    if [ -f "${SSH_KEY}" ]; then
        inject_key "${SSH_KEY}"
    else
        log_warn "Key file '${SSH_KEY}' not found — skipping."
    fi
else
    echo ""
    read -rp "$(printf "  ${CYAN}Inject an SSH public key? [y/N]:${NC} ")" ans
    if [[ "${ans}" =~ ^[yY] ]]; then
        read -rp "  Path to public key [~/.ssh/id_rsa.pub]: " keypath
        keypath="${keypath:-${HOME}/.ssh/id_rsa.pub}"
        keypath="${keypath/#\~/$HOME}"
        if [ -f "${keypath}" ]; then
            inject_key "${keypath}"
        else
            log_warn "File not found: ${keypath}"
        fi
    fi
fi

# ============================================================
#  Phase 5 — Locale (Debian only)
# ============================================================
if [ "${OS}" = "debian" ]; then
    log_info "Setting locale → en_US.UTF-8"
    pct exec "${CTID}" -- bash -c "
        sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen 2>/dev/null || true
        locale-gen 2>/dev/null || true
        update-locale LANG=en_US.UTF-8 2>/dev/null || true
    "
    log_ok "Locale configured."
fi

# ============================================================
#  Summary
# ============================================================
echo ""
printf "  ${BOLD}Bootstrap complete for CT %s (%s)${NC}\n" "${CTID}" "${NAME}"
hr
echo "  • OS:        ${OS}"
echo "  • Timezone:  ${TIMEZONE}"
echo "  • Packages:  curl, vim, htop, git, ca-certificates, openssh"
echo "  • SSH:       key-only auth · no passwords · max 3 tries"
[ "${OS}" = "debian" ] && echo "  • Locale:    en_US.UTF-8"
hr
echo ""
