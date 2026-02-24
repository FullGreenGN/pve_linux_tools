# pve_linux_tools 🛠️

A collection of utility scripts and Docker configurations designed to streamline management, monitoring, and maintenance for **Proxmox VE (PVE)** environments and Linux containers.

---

## 📁 Repository Structure

```text
.
├── LICENSE                                          # MIT License
├── README.md                                        # ← You are here
├── setup.sh                                         # Master interactive installer
├── scripts/
│   ├── README.md                                    # Script-specific documentation
│   ├── update_containers.sh                         # Multi-OS LXC updater + ZFS/LVM snapshots
│   ├── pve_backup_check.sh                          # Vzdump backup job auditor
│   └── lxc_baseline_setup.sh                        # New container standardization
└── docker_compose/
    └── monitoring/
        ├── .env                                     # Environment variable template
        ├── README.md                                # Stack-specific documentation
        ├── docker-compose.yml                       # Traefik + InfluxDB + Grafana
        ├── traefik/
        │   └── traefik.yml                          # Traefik v2 static configuration
        └── grafana/
            └── provisioning/
                └── datasources/
                    └── datasource.yml               # Auto-provisions InfluxDB datasource
```

---

## 🚀 Quick Start — Interactive Installer

The fastest way to use this toolkit is through the **master installer**:

```bash
chmod +x setup.sh
./setup.sh
```

This presents an interactive menu:

```text
┌──────────────────────────────────────────────┐
│  1)  Update All Containers                   │
│  2)  Install Monitoring Stack                │
│  3)  Setup Backup Monitor                    │
│  4)  LXC Hardening                           │
│  5)  Exit                                    │
└──────────────────────────────────────────────┘
```

**Built-in safety checks:**

- ✅ Verifies you're running as `root`
- ✅ Confirms this is a Proxmox VE host (`/usr/bin/pveversion`)
- ✅ Checks for Docker/Docker Compose before deploying the monitoring stack
- ✅ Offers to install Docker automatically if missing
- ✅ Cleans up temporary files on exit (trap handler)

---

## 📦 Individual Scripts (`scripts/`)

All scripts can also be run standalone. They require **root privileges** on the PVE host.

```bash
scp scripts/*.sh root@<your-pve-ip>:/root/
chmod +x /root/*.sh
```

### `update_containers.sh` — Smart LXC Updater

Updates **all running LXC containers** with automatic OS detection. Creates a **ZFS or LVM snapshot** before each update for instant rollback.

| OS              | Package Manager | Snapshot Method                  |
| --------------- | --------------- | -------------------------------- |
| Debian / Ubuntu | `apt`           | ZFS → LVM → `pct snapshot`      |
| Alpine          | `apk`           | ZFS → LVM → `pct snapshot`      |
| Arch            | `pacman`        | ZFS → LVM → `pct snapshot`      |
| Fedora          | `dnf`           | ZFS → LVM → `pct snapshot`      |

```bash
./update_containers.sh
```

### `pve_backup_check.sh` — Backup Auditor

Parses `/var/log/pve/tasks` for recent `vzdump` results and displays them in colour (**Green** = OK, **Red** = Error, **Yellow** = Running). Falls back to the `pvesh` API when available.

```bash
./pve_backup_check.sh              # last 24 hours
./pve_backup_check.sh --days 7     # last 7 days
```

### `lxc_baseline_setup.sh` — Container Hardening

Applies first-run standardization to a fresh container: installs `curl`, `vim`, `htop`, sets timezone, hardens SSH, and optionally injects an SSH public key.

```bash
./lxc_baseline_setup.sh 105
./lxc_baseline_setup.sh 105 --timezone America/New_York --ssh-key ~/.ssh/id_ed25519.pub
./lxc_baseline_setup.sh            # interactive mode
```

> 📖 See [`scripts/README.md`](./scripts/README.md) for full documentation, cron scheduling, rollback instructions, and examples.

---

## 📊 Monitoring Stack (`docker_compose/monitoring/`)

A production-ready **Traefik + InfluxDB v2 + Grafana** stack optimized for Proxmox VE monitoring.

| Service         | Role                                              | Port(s)       |
| --------------- | ------------------------------------------------- | ------------- |
| **Traefik v2**  | Reverse proxy with automatic Let's Encrypt TLS    | `80` / `443`  |
| **InfluxDB v2** | Time-series database (auto-initialized)            | `8086`        |
| **Grafana**     | Dashboard & visualization (auto-provisioned)       | `3000`        |

```bash
cd docker_compose/monitoring
cp .env .env.local && nano .env.local
docker compose up -d
```

**Proxmox Integration:** Datacenter → Metric Server → Add → InfluxDB → point to port `8086` with org/bucket/token from `.env`.

> 📖 See [`docker_compose/monitoring/README.md`](./docker_compose/monitoring/README.md) for full architecture diagram and deployment guide.

---

## 🛠️ Requirements

| Component                | Version                    |
| ------------------------ | -------------------------- |
| Proxmox VE               | 7.x / 8.x / 9.x          |
| Docker Engine            | ≥ 20.10                   |
| Docker Compose           | v2 (`docker compose` CLI) |
| Root privileges          | Required for all scripts   |
| Public domain (optional) | Required for Let's Encrypt |
| `jq` (optional)          | For `pve_backup_check.sh` API mode |

---

## 📜 License

This project is open-source and available under the [MIT License](./LICENSE).

---
