# Scripts 📜

Utility scripts for Proxmox VE host-level automation. All scripts require **root privileges** and are designed to run **directly on the PVE host**.

---

## Overview

| Script                   | Purpose                                              |
| ------------------------ | ---------------------------------------------------- |
| `update_containers.sh`   | Update all running LXCs with pre-update snapshots    |
| `pve_backup_check.sh`    | Audit recent vzdump jobs and report failures         |
| `lxc_baseline_setup.sh`  | Apply a standard baseline config to a new container  |

---

## `update_containers.sh`

Automatically updates **all running LXC containers** on a Proxmox VE host. Before touching each container, it creates a **snapshot** (`pre_update_YYYY-MM-DD`) so you can roll back instantly if an update breaks something.

### Features

- **Root check** — exits immediately if not run as `root`.
- **Auto-discovery** — uses `pct list` to enumerate all running containers.
- **Pre-update snapshots** — `pct snapshot <ID> pre_update_$(date +%F)` before every update.
- **OS detection** — probes release files inside each container to identify the distribution.
- **Multi-distro support** — handles four major package managers.
- **Summary report** — prints success/fail/skip counts at the end.

### Supported Distributions

| Distribution     | Detection File           | Package Manager Command                                                          |
| ---------------- | ------------------------ | -------------------------------------------------------------------------------- |
| Debian / Ubuntu  | `/etc/debian_version`    | `apt-get update && apt-get dist-upgrade -y && apt-get autoremove -y`             |
| Alpine Linux     | `/etc/alpine-release`    | `apk update && apk upgrade`                                                     |
| Arch Linux       | `/etc/arch-release`      | `pacman -Syu --noconfirm`                                                        |
| Fedora           | `/etc/fedora-release`    | `dnf upgrade -y`                                                                 |

### Usage

```bash
# Copy to PVE host
scp scripts/update_containers.sh root@<pve-ip>:/root/

# Run
chmod +x /root/update_containers.sh
./update_containers.sh
```

### Rollback a Failed Update

```bash
# List snapshots for a container
pct listsnapshot <CTID>

# Rollback to the pre-update snapshot
pct rollback <CTID> pre_update_2026-02-24
```

### Scheduling with Cron

Run every Sunday at 03:00 AM:

```bash
crontab -e
```

```cron
0 3 * * 0 /root/update_containers.sh >> /var/log/lxc_updates.log 2>&1
```

---

## `pve_backup_check.sh`

Scans recent Proxmox VE backup tasks (`vzdump`) and reports their status. Ideal for daily health-check cron jobs or integration with notification systems (email, Telegram, etc.).

### How It Works

1. **Primary method** — queries the PVE task log via `pvesh` API (requires `jq`).
2. **Fallback method** — scans `/var/log/pve/tasks/` on the filesystem if `pvesh` or `jq` is unavailable.

### Usage

```bash
# Check the last 24 hours (default)
./pve_backup_check.sh

# Check the last 7 days
./pve_backup_check.sh --days 7
```

### Options

| Flag             | Description                                    | Default |
| ---------------- | ---------------------------------------------- | ------- |
| `--days N`, `-d` | Look back N days for backup tasks              | `1`     |
| `--help`, `-h`   | Show help message                              | —       |

### Exit Codes

| Code | Meaning                                |
| ---- | -------------------------------------- |
| `0`  | All backup tasks completed successfully |
| `1`  | One or more backup tasks failed        |

### Scheduling with Cron

Run daily at 07:00 AM and email failures:

```cron
0 7 * * * /root/pve_backup_check.sh --days 1 || mail -s "PVE Backup FAILURE on $(hostname)" admin@example.com < /dev/null
```

### Prerequisites

- `pvesh` (included with Proxmox VE)
- `jq` (install with `apt install jq` — optional; filesystem fallback is used without it)

---

## `lxc_baseline_setup.sh`

Applies a **standardized baseline configuration** to a freshly created LXC container. Gets a new container from "empty" to "production-ready" in seconds.

### What It Configures

| Phase       | Action                                                           |
| ----------- | ---------------------------------------------------------------- |
| Timezone    | Sets the container timezone (default: `Europe/Berlin`)           |
| Packages    | Installs `curl`, `wget`, `nano`, `htop`, `git`, `ca-certificates`, SSH |
| SSH         | Disables password auth, root key-only, max 3 auth tries         |
| Firewall    | Denies all incoming except SSH, allows all outgoing              |
| Locale      | Generates `en_US.UTF-8` (Debian/Ubuntu only)                    |

### Usage

```bash
# Basic — apply baseline to container 105
./lxc_baseline_setup.sh 105

# Custom timezone
./lxc_baseline_setup.sh 105 --timezone America/New_York
```

### Options

| Flag                  | Description                                | Default          |
| --------------------- | ------------------------------------------ | ---------------- |
| `<CTID>` (required)   | Container ID to configure                  | —                |
| `--timezone TZ`       | IANA timezone string                       | `Europe/Berlin`  |
| `--help`, `-h`        | Show help message                          | —                |

### Post-Setup — Add Your SSH Key

The script disables password authentication. To access the container afterwards:

```bash
pct exec <CTID> -- mkdir -p /root/.ssh
pct push <CTID> ~/.ssh/id_rsa.pub /root/.ssh/authorized_keys
```

---

> [!WARNING]
> All scripts must be run **directly on the Proxmox VE host** as `root`. They will not work inside a container or on a remote machine without `pct` / `pvesh` access.
