#!/bin/bash

# Check if the user is root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

echo "--- Starting Smart LXC Updates ---"

# Get IDs of running containers
CONTAINERS=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

for CTID in $CONTAINERS; do
    NAME=$(pct config $CTID | grep "hostname" | awk '{print $2}')
    echo "Processing $CTID ($NAME)..."

    # 1. Detect OS by checking for specific files inside the container
    if pct exec $CTID -- test -f /etc/debian_version; then
        OS="debian"
    elif pct exec $CTID -- test -f /etc/alpine-release; then
        OS="alpine"
    elif pct exec $CTID -- test -f /etc/arch-release; then
        OS="arch"
    elif pct exec $CTID -- test -f /etc/fedora-release; then
        OS="fedora"
    else
        OS="unknown"
    fi

    # 2. Run the appropriate update command based on OS
    case $OS in
        debian)
            echo "  Detected: Debian/Ubuntu (apt)"
            pct exec $CTID -- bash -c "apt-get update && apt-get dist-upgrade -y && apt-get autoremove -y"
            ;;
        alpine)
            echo "  Detected: Alpine (apk)"
            pct exec $CTID -- ash -c "apk update && apk upgrade"
            ;;
        arch)
            echo "  Detected: Arch (pacman)"
            pct exec $CTID -- bash -c "pacman -Syu --noconfirm"
            ;;
        fedora)
            echo "  Detected: Fedora (dnf)"
            pct exec $CTID -- bash -c "dnf upgrade -y"
            ;;
        *)
            echo "  [!] Warning: Could not detect OS or OS not supported. Skipping."
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo "Successfully updated $NAME."
    else
        echo "Error updating $NAME."
    fi
    echo "--------------------------------------"
done

echo "--- All running containers have been processed ---"
