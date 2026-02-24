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
│   └── update_containers.sh                         # Automated LXC update script
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

### 1. Smart LXC Updater (`scripts/`)

The `update_containers.sh` script automates the update process for **all running LXC containers** on your Proxmox host. It performs OS detection to apply the correct package manager commands automatically.

**Supported Distributions:**

| Distribution     | Package Manager | Detection File         |
| ---------------- | --------------- | ---------------------- |
| Debian / Ubuntu  | `apt`           | `/etc/debian_version`  |
| Alpine Linux     | `apk`           | `/etc/alpine-release`  |
| Arch Linux       | `pacman`        | `/etc/arch-release`    |
| Fedora           | `dnf`           | `/etc/fedora-release`  |

**Quick Start:**

```bash
# Copy to your Proxmox host
scp scripts/update_containers.sh root@<your-pve-ip>:/root/

# Make executable and run
chmod +x /root/update_containers.sh
./update_containers.sh
```

> 📖 See [`scripts/README.md`](./scripts/README.md) for cron scheduling, example output, and detailed usage.

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
- 📊 **Auto-provisioned datasource** — Grafana connects to InfluxDB automatically on first boot via provisioning files.
- 🔧 **Environment-driven config** — All secrets and settings live in `.env`, never hardcoded.

**Proxmox Integration:**

1. Navigate to **Datacenter → Metric Server → Add → InfluxDB** in the Proxmox GUI.
2. Point it to your Docker host on port `8086` using the org, bucket, and token from your `.env` file.
3. Metrics will begin flowing within seconds.

> 📖 See [`docker_compose/monitoring/README.md`](./docker_compose/monitoring/README.md) for the full architecture diagram, all configuration options, and detailed deployment steps.

---

## 🛠️ Requirements

| Component              | Version                    |
| ---------------------- | -------------------------- |
| Proxmox VE             | 7.x / 8.x / 9.x          |
| Docker Engine          | ≥ 20.10                   |
| Docker Compose         | v2 (`docker compose` CLI) |
| Root privileges        | Required for LXC script   |
| Public domain (optional) | Required for Let's Encrypt |

---

## 📜 License

This project is open-source and available under the [MIT License](./LICENSE).

---
