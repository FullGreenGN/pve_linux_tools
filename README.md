# pve_linux_tools 🛠️

A collection of utility scripts and Docker configurations designed to streamline management, monitoring, and maintenance for **Proxmox VE (PVE)** environments and Linux containers.

---

## 📁 Repository Structure

```text
.
├── LICENSE                                          # MIT License
├── README.md                                        # ← You are here
├── scripts/
│   ├── README.md                                    # Script-specific documentation
│   ├── update_containers.sh                         # Multi-OS LXC updater + snapshots
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

## 🚀 Getting Started

### 1. Scripts (`scripts/`)

All scripts require **root privileges** and are designed to run **directly on the Proxmox VE host**.

```bash
# Copy all scripts to your PVE host
scp scripts/*.sh root@<your-pve-ip>:/root/

# Make them executable
chmod +x /root/*.sh
```

#### `update_containers.sh` — Smart LXC Updater

Automatically updates **all running LXC containers**. Creates a **pre-update snapshot** for each container so you can roll back instantly if something breaks.

**Supported OS:** Debian/Ubuntu (`apt`), Alpine (`apk`), Arch (`pacman`), Fedora (`dnf`)

```bash
./update_containers.sh
```

#### `pve_backup_check.sh` — Backup Auditor

Scans recent `vzdump` backup tasks and reports successes and failures. Uses the `pvesh` API when available, falls back to filesystem logs otherwise.

```bash
# Check last 24 hours
./pve_backup_check.sh

# Check last 7 days
./pve_backup_check.sh --days 7
```

#### `lxc_baseline_setup.sh` — Container Baseline

Applies a standard configuration to a freshly created container: timezone, common packages, SSH hardening, and firewall rules.

```bash
./lxc_baseline_setup.sh 105 --timezone Europe/Berlin
```

> 📖 See [`scripts/README.md`](./scripts/README.md) for full documentation, cron scheduling, rollback instructions, and examples.

---

### 2. Monitoring Stack (`docker_compose/monitoring/`)

A production-ready **Traefik + InfluxDB v2 + Grafana** stack optimized for Proxmox VE monitoring.

**Services:**

| Service         | Role                                              | Port(s)       |
| --------------- | ------------------------------------------------- | ------------- |
| **Traefik v2**  | Reverse proxy with automatic Let's Encrypt TLS    | `80` / `443`  |
| **InfluxDB v2** | Time-series database (auto-initialized)            | `8086`        |
| **Grafana**     | Dashboard & visualization (auto-provisioned)       | `3000`        |

**Quick Start:**

```bash
cd docker_compose/monitoring

# 1. Configure your environment
cp .env .env.local
nano .env.local          # Set DOMAIN, ACME_EMAIL, passwords, tokens

# 2. Deploy
docker compose up -d

# 3. Verify
docker compose ps
```

**Key Features:**

- 🔒 **Automatic HTTPS** — Traefik handles TLS certificates via Let's Encrypt (TLS-ALPN-01 challenge).
- 📊 **Auto-provisioned datasource** — Grafana connects to InfluxDB automatically on first boot.
- 🔧 **Environment-driven config** — All secrets and settings live in `.env`, never hardcoded.

**Proxmox Integration:**

1. Navigate to **Datacenter → Metric Server → Add → InfluxDB** in the Proxmox GUI.
2. Point it to your Docker host on port `8086` using the org, bucket, and token from your `.env` file.
3. Metrics will begin flowing within seconds.

> 📖 See [`docker_compose/monitoring/README.md`](./docker_compose/monitoring/README.md) for full architecture diagram, all config options, and detailed deployment steps.

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
