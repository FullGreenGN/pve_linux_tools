# Scripts 📜

Utility scripts for Proxmox VE host-level automation. All scripts require **root privileges** and are designed to run **directly on the PVE host**.

---

## Overview

| Script                   | Purpose                                                       |
| ------------------------ | ------------------------------------------------------------- |
| `update_containers.sh`   | Update all running LXCs with ZFS/LVM pre-update snapshots     |
| `pve_backup_check.sh`    | Audit recent vzdump jobs — colour-coded pass/fail report      |
| `lxc_baseline_setup.sh`  | First-run hardening: packages, timezone, SSH, firewall        |

> **Tip:** All three scripts are also accessible via the interactive **`setup.sh`** installer at the repository root.

---

## `update_containers.sh`

Automatically updates **all running LXC containers** on a Proxmox VE host. Before touching each container, it creates a snapshot using the best available method for the storage backend.

### Snapshot Strategy

| Storage Type     | Snapshot Method           | Fallback        |
| ---------------- | ------------------------- | --------------- |
| ZFS (`zfspool`)  | `zfs snapshot`            | `pct snapshot`  |
| LVM / LVM-Thin   | `lvcreate --snapshot`     | `pct snapshot`  |
| Directory / NFS  | —                         | `pct snapshot`  |

The snapshot is named `pre_update_YYYY-MM-DD` and includes a description for easy identification.

### Supported Distributions

| Distribution     | Detection File           | Update Command                                                           |
| ---------------- | ------------------------ | ------------------------------------------------------------------------ |
| Debian / Ubuntu  | `/etc/debian_version`    | `apt-get update && apt-get dist-upgrade -y && apt-get autoremove -y`     |
| Alpine Linux     | `/etc/alpine-release`    | `apk update && apk upgrade`                                             |
| Arch Linux       | `/etc/arch-release`      | `pacman -Syu --noconfirm`                                               |
| Fedora           | `/etc/fedora-release`    | `dnf upgrade -y`                                                         |

### Usage

```bash
./update_containers.sh
```

### Rollback a Failed Update

```bash
# List snapshots
pct listsnapshot <CTID>

# Roll back
pct rollback <CTID> pre_update_2026-02-24

# For ZFS snapshots
zfs rollback <dataset>@pre_update_2026-02-24
```

### Scheduling with Cron

```cron
0 3 * * 0 /root/update_containers.sh >> /var/log/lxc_updates.log 2>&1
```

---

## `pve_backup_check.sh`

Scans recent Proxmox VE backup tasks (`vzdump`) and displays a colour-coded report:

| Colour  | Meaning                |
| ------- | ---------------------- |
| 🟢 Green  | Backup completed OK    |
| 🔴 Red    | Backup failed / error  |
| 🟡 Yellow | Still running / unknown |

### How It Works

1. **Primary:** Parses task index files in `/var/log/pve/tasks/` directly.
2. **Alternative:** Queries the `pvesh` REST API (requires `jq`).

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

| Code | Meaning                                 |
| ---- | --------------------------------------- |
| `0`  | All backup tasks completed successfully |
| `1`  | One or more backup tasks failed         |

### Cron + Email Notification

```cron
0 7 * * * /root/pve_backup_check.sh --days 1 || mail -s "PVE Backup FAILURE on $(hostname)" admin@example.com < /dev/null
```

### Prerequisites

- `jq` — optional but recommended (`apt install jq`)

---

## `lxc_baseline_setup.sh`

Applies a **standardized first-run configuration** to a freshly created LXC container.

### What It Configures

| Phase       | Action                                                              |
| ----------- | ------------------------------------------------------------------- |
| Timezone    | Sets the container timezone (default: `Europe/Berlin`)              |
| Packages    | Installs `curl`, `vim`, `htop`, `ca-certificates`, SSH              |
| SSH         | Disables password auth, root key-only, max 3 auth tries            |
| SSH Key     | Optionally injects a public key into `/root/.ssh/authorized_keys`   |
| Locale      | Generates `en_US.UTF-8` (Debian/Ubuntu only)                       |

### Usage

```bash
# Direct invocation with CTID
./lxc_baseline_setup.sh 105

# With all options
./lxc_baseline_setup.sh 105 --timezone America/New_York --ssh-key ~/.ssh/id_ed25519.pub

# Interactive mode (prompts for CTID and SSH key)
./lxc_baseline_setup.sh
```

### Options

| Flag                  | Description                                | Default          |
| --------------------- | ------------------------------------------ | ---------------- |
| `<CTID>`              | Container ID (optional — prompts if omitted) | —              |
| `--timezone TZ`       | IANA timezone string                       | `Europe/Berlin`  |
| `--ssh-key PATH`      | Path to a public SSH key to inject          | —               |
| `--help`, `-h`        | Show help message                          | —                |

---

## `setup.sh` (Master Installer)

The root-level `setup.sh` script provides an **interactive menu** that wraps all three scripts above, plus the monitoring stack deployment:

```text
1)  Update All Containers      → runs update_containers.sh
2)  Install Monitoring Stack   → checks Docker, deploys docker-compose
3)  Setup Backup Monitor       → configures cron for pve_backup_check.sh
4)  LXC Hardening              → runs lxc_baseline_setup.sh interactively
5)  Exit
```

Pre-flight checks: root, PVE host verification, Docker dependency check with auto-install offer.

```bash
./setup.sh
```

---

> [!WARNING]
> All scripts must be run **directly on the Proxmox VE host** as `root`. They will not work inside a container or on a remote machine without `pct` / `pvesh` / `pveversion` access.
