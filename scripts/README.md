# Scripts 📜

Automation scripts for Proxmox VE host management. All require **root privileges** on the PVE host.

---

## Overview

| Script                   | Purpose                                                    |
| ------------------------ | ---------------------------------------------------------- |
| `update_containers.sh`   | Update all running LXCs with ZFS/LVM/pct snapshots         |
| `bootstrap_lxc.sh`       | Golden Image baseline for new containers                   |
| `pve_health.sh`          | Disk SMART status + vzdump backup audit                    |

> **Tip:** All scripts are also accessible via the interactive `setup.sh` installer at the repository root.

---

## `update_containers.sh`

### What It Does

1. Enumerates all running containers (`pct list`)
2. Creates a **storage-aware snapshot** per container
3. Detects the OS inside each container
4. Runs the correct update command

### Snapshot Strategy

The script detects the storage backend via `pvesm status` and picks the best snapshot method:

| Backend          | Method                | Fallback       |
| ---------------- | --------------------- | -------------- |
| ZFS (`zfspool`)  | `zfs snapshot`        | `pct snapshot` |
| LVM / LVM-Thin   | `lvcreate --snapshot` | `pct snapshot` |
| Directory / NFS  | —                     | `pct snapshot` |

Snapshot name: `pre_update_YYYY-MM-DD`

### Supported Distributions

| Distribution     | Detection File         | Package Manager                                                  |
| ---------------- | ---------------------- | ---------------------------------------------------------------- |
| Debian / Ubuntu  | `/etc/debian_version`  | `apt-get update && apt-get dist-upgrade -y && apt-get autoremove -y` |
| Alpine Linux     | `/etc/alpine-release`  | `apk update && apk upgrade`                                     |
| Arch Linux       | `/etc/arch-release`    | `pacman -Syu --noconfirm`                                       |
| Fedora           | `/etc/fedora-release`  | `dnf upgrade -y`                                                |

### Usage

```bash
./update_containers.sh
```

### Rollback

```bash
pct listsnapshot <CTID>
pct rollback <CTID> pre_update_2026-02-24

# For ZFS-backed containers
zfs rollback <pool/dataset>@pre_update_2026-02-24
```

### Cron Schedule

```cron
# Every Sunday at 03:00
0 3 * * 0 /root/scripts/update_containers.sh >> /var/log/lxc_updates.log 2>&1
```

---

## `bootstrap_lxc.sh`

### What It Does

Applies a "Golden Image" baseline to a freshly created LXC container in five phases:

| Phase      | Action                                                               |
| ---------- | -------------------------------------------------------------------- |
| Timezone   | Sets IANA timezone (default: `Europe/Berlin`)                        |
| Packages   | Installs `curl`, `vim`, `htop`, `git`, `ca-certificates`, `openssh` |
| SSH        | Key-only auth · no password login · max 3 tries · no X11            |
| SSH Key    | Injects a public key into `/root/.ssh/authorized_keys`              |
| Locale     | Generates `en_US.UTF-8` (Debian/Ubuntu only)                        |

### Usage

```bash
# Direct — specify CTID
./bootstrap_lxc.sh 105

# With options
./bootstrap_lxc.sh 105 --timezone America/New_York --ssh-key ~/.ssh/id_ed25519.pub

# Interactive — prompts for CTID + SSH key
./bootstrap_lxc.sh
```

### Options

| Flag              | Description                           | Default         |
| ----------------- | ------------------------------------- | --------------- |
| `<CTID>`          | Container ID (prompts if omitted)     | interactive     |
| `--timezone TZ`   | IANA timezone string                  | `Europe/Berlin` |
| `--ssh-key PATH`  | Public key file to inject             | interactive     |
| `-h`, `--help`    | Show help                             | —               |

### After Bootstrap

```bash
# SSH into the freshly configured container
ssh root@<container-ip>
```

---

## `pve_health.sh`

### What It Does

A two-part host health check:

#### ① Disk SMART Status

- Discovers all block devices via `lsblk`
- Runs `smartctl` on each drive
- Reports: **health status**, **temperature**, **model**
- Flags **reallocated**, **pending**, and **offline uncorrectable** sectors
- Colour-coded: 🟢 PASSED · 🔴 FAILED

#### ② Backup Audit

- Scans recent `vzdump` tasks
- Primary: `pvesh` API (requires `jq`)
- Fallback: `/var/log/pve/tasks/` index files
- Colour-coded: 🟢 OK · 🔴 Failed · 🟡 Running

### Usage

```bash
# Default — last 24 hours
./pve_health.sh

# Last 7 days of backups
./pve_health.sh --days 7
```

### Options

| Flag           | Description                       | Default |
| -------------- | --------------------------------- | ------- |
| `--days N`     | Backup lookback period            | `1`     |
| `-h`, `--help` | Show help                         | —       |

### Exit Codes

| Code | Meaning                                       |
| ---- | --------------------------------------------- |
| `0`  | Healthy — no issues                           |
| `N`  | Number of issues detected (SMART + backup)    |

### Cron + Alerting

```cron
# Daily at 07:00 — email on failure
0 7 * * * /root/scripts/pve_health.sh || mail -s "PVE Health ALERT on $(hostname)" admin@example.com < /dev/null
```

### Prerequisites

| Package          | Required? | Install                    |
| ---------------- | --------- | -------------------------- |
| `smartmontools`  | Yes       | `apt install smartmontools` |
| `jq`             | Optional  | `apt install jq`           |

---

> [!WARNING]
> All scripts must be run **on the Proxmox VE host** as `root`. They require `pct`, `pvesm`, `pvesh`, and/or `smartctl` which are only available on the host.
