# pve_linux_tools 🛠️

A modular, professional automation toolkit for **Proxmox VE** environments — container updates with ZFS/LVM snapshots, host health monitoring, LXC bootstrapping, and a full observability stack.

---

## 📁 Repository Structure

```text
.
├── .gitignore                                       # Keeps .env + OS files out of Git
├── LICENSE                                          # MIT License
├── README.md                                        # ← You are here
├── setup.sh                                         # Master interactive installer
├── scripts/
│   ├── README.md                                    # Script documentation
│   ├── update_containers.sh                         # Multi-OS LXC updater + snapshots
│   ├── bootstrap_lxc.sh                             # Golden Image container setup
│   └── pve_health.sh                                # SMART disk + backup audit
└── docker_compose/
    ├── homelab/                                     # ⬅ NEW — Full homelab stack
    │   ├── .env.example                             # Environment variable template
    │   ├── README.md                                # Stack documentation
    │   └── docker-compose.yml                       # 15-service all-in-one stack
    └── monitoring/
        ├── .env                                     # Environment variable template
        ├── README.md                                # Stack documentation
        ├── docker-compose.yml                       # Traefik + InfluxDB + Grafana
        ├── traefik/
        │   └── traefik.yml                          # Traefik v2 static config
        └── grafana/
            └── provisioning/
                └── datasources/
                    └── datasource.yml               # Auto-provisions InfluxDB
```

---

## 🚀 Quick Start

```bash
# Clone and run the interactive installer
git clone https://github.com/<you>/pve_linux_tools.git
cd pve_linux_tools
chmod +x setup.sh
./setup.sh
```

The `select`-based menu will present:

```
1) Update All Containers   (snapshot + upgrade)
2) Setup Monitoring Stack  (Traefik / InfluxDB / Grafana)
3) LXC Bootstrapper        (Golden Image setup)
4) Host Health Check       (SMART + backup audit)
5) Exit
```

### Built-in Safety

| Check                  | Detail                                            |
| ---------------------- | ------------------------------------------------- |
| Root verification      | Exits if not `root`                               |
| PVE host detection     | Verifies `/usr/bin/pveversion` exists              |
| Docker dependency      | Checks for `docker` + `docker compose` before deploying; offers auto-install |
| Script presence        | Confirms all sub-scripts exist before presenting menu |
| Cleanup trap           | Removes temp files on `EXIT`, `INT`, `TERM`, `HUP` |

---

## 📦 Scripts

### `update_containers.sh` — Smart LXC Updater

Discovers all running containers via `pct list`, creates a **storage-aware snapshot** (`ZFS → LVM → pct` fallback), then runs the correct package manager.

| OS              | Manager   | Snapshot Strategy             |
| --------------- | --------- | ----------------------------- |
| Debian / Ubuntu | `apt`     | ZFS → LVM → `pct snapshot`   |
| Alpine          | `apk`     | ZFS → LVM → `pct snapshot`   |
| Arch            | `pacman`  | ZFS → LVM → `pct snapshot`   |
| Fedora          | `dnf`     | ZFS → LVM → `pct snapshot`   |

```bash
./scripts/update_containers.sh
```

### `bootstrap_lxc.sh` — Golden Image Bootstrapper

Applies first-run standardization to a fresh container:

- Sets timezone
- Installs `curl`, `vim`, `htop`, `git`, `ca-certificates`, `openssh`
- Hardens SSH (key-only auth, max 3 tries)
- Injects an SSH public key
- Configures locale (Debian/Ubuntu)

```bash
./scripts/bootstrap_lxc.sh 105
./scripts/bootstrap_lxc.sh 105 --timezone America/New_York --ssh-key ~/.ssh/id_ed25519.pub
./scripts/bootstrap_lxc.sh       # interactive mode
```

### `pve_health.sh` — Host Health Check

Two-part health scan:

1. **SMART Disk Status** — scans all block devices via `smartctl`, reports health/temp/model, flags reallocated or pending sectors.
2. **Backup Audit** — checks last N days of `vzdump` tasks (pvesh API or `/var/log/pve/tasks` fallback), colour-coded results.

```bash
./scripts/pve_health.sh            # last 24 hours
./scripts/pve_health.sh --days 7   # last 7 days
```

> 📖 See [`scripts/README.md`](./scripts/README.md) for full options, cron scheduling, and examples.

---

## 🏠 Homelab Stack

A **15-service all-in-one** Docker Compose stack covering reverse proxy, databases, productivity apps, and monitoring dashboards — all configurable via a single `.env` file.

| Category | Services |
|----------|----------|
| **Core** | Nginx Proxy Manager |
| **Databases** | PostgreSQL 16 · Redis 7 · MariaDB 10 |
| **Productivity** | n8n · Docmost · Affine · Vikunja · Homebox · Mealie · Actual Budget |
| **Monitoring** | Glance · Uptime Kuma · MySpeed · Grafana · InfluxDB |

```bash
cd docker_compose/homelab
cp .env.example .env && nano .env
docker compose up -d
```

> 📖 See [`docker_compose/homelab/README.md`](./docker_compose/homelab/README.md) for full setup guide, DB init, and security tips.

---

## 📊 Monitoring Stack

A **Traefik v2 + InfluxDB v2 + Grafana** Docker Compose stack with automatic TLS and datasource provisioning.

| Service         | Role                                          | Port(s)       |
| --------------- | --------------------------------------------- | ------------- |
| **Traefik v2**  | Reverse proxy · Let's Encrypt TLS · Dashboard | `80` / `443`  |
| **InfluxDB v2** | Time-series DB · auto-init org/bucket/token   | `8086`        |
| **Grafana**     | Dashboards · auto-provisioned datasource      | `3000`        |

```bash
cd docker_compose/monitoring
cp .env .env.local && nano .env.local
docker compose up -d
```

**Proxmox integration:** Datacenter → Metric Server → Add → InfluxDB → `http://<docker-host>:8086` with org/bucket/token from `.env`.

> 📖 See [`docker_compose/monitoring/README.md`](./docker_compose/monitoring/README.md) for architecture diagram and full setup guide.

---

## 🛠️ Requirements

| Component                 | Version / Note                |
| ------------------------- | ----------------------------- |
| Proxmox VE                | 7.x / 8.x / 9.x             |
| Docker Engine             | ≥ 20.10                      |
| Docker Compose            | v2 (`docker compose` plugin) |
| Root privileges           | Required for all scripts      |
| `smartmontools` (optional)| For disk health checks        |
| `jq` (optional)           | For pvesh API backup audit    |
| Public domain (optional)  | For Let's Encrypt TLS         |

---

## 📜 License

This project is open-source and available under the [MIT License](./LICENSE).

---
