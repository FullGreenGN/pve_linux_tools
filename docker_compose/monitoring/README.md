# Monitoring Stack 📊

A production-ready **Traefik + InfluxDB v2 + Grafana** stack deployed via Docker Compose.
Designed to collect, store, and visualize time-series metrics from a Proxmox VE environment.

---

## Architecture

```text
┌──────────────┐      HTTPS       ┌──────────────┐
│   Internet   │ ───────────────▸ │   Traefik    │
└──────────────┘                  │  (Reverse    │
                                  │   Proxy)     │
                                  └──┬───────┬───┘
                                     │       │
                            ┌────────▾─┐  ┌──▾──────────┐
                            │ Grafana  │  │  InfluxDB   │
                            │ :3000    │  │  :8086      │
                            └──────────┘  └─────────────┘
```

| Service     | Description                                             | Default Port |
| ----------- | ------------------------------------------------------- | ------------ |
| **Traefik** | Reverse proxy with automatic Let's Encrypt TLS certs    | `443` / `80` |
| **InfluxDB v2** | High-performance time-series database               | `8086`       |
| **Grafana** | Dashboard & visualization UI                            | `3000`       |

---

## Directory Layout

```text
monitoring/
├── .env                        # Environment variable template
├── README.md                   # ← You are here
├── docker-compose.yml          # Full stack definition
├── traefik/
│   └── traefik.yml             # Traefik static configuration
└── grafana/
    └── provisioning/
        └── datasources/
            └── datasource.yml  # Auto-provisions InfluxDB in Grafana
```

---

## Prerequisites

- **Docker Engine** ≥ 20.10
- **Docker Compose** v2 (the `docker compose` plugin)
- A **domain name** pointing to your server (for Let's Encrypt)
- Ports **80** and **443** open on your firewall

---

## Quick Start

### 1. Configure Environment Variables

```bash
cp .env .env.local   # work from a local copy
nano .env.local      # fill in your real values
```

Key variables to change:

| Variable | Purpose |
| -------- | ------- |
| `DOMAIN` | Your FQDN, e.g. `monitor.homelab.dev` |
| `ACME_EMAIL` | Email for Let's Encrypt certificate notifications |
| `DOCKER_INFLUXDB_INIT_PASSWORD` | InfluxDB admin password |
| `DOCKER_INFLUXDB_INIT_ADMIN_TOKEN` | API token used by Grafana + Proxmox |
| `GF_SECURITY_ADMIN_PASSWORD` | Grafana admin password |

### 2. Deploy the Stack

```bash
docker compose up -d
```

### 3. Verify Services

```bash
docker compose ps
docker compose logs -f traefik   # watch certificate issuance
```

- **Grafana**: `https://<DOMAIN>` (or `http://localhost:3000` without Traefik)
- **InfluxDB**: `https://influxdb.<DOMAIN>` (or `http://localhost:8086`)

---

## Connecting Proxmox to InfluxDB

1. In the Proxmox GUI go to **Datacenter → Metric Server → Add → InfluxDB**.
2. Fill in the fields:

   | Field          | Value                                   |
   | -------------- | --------------------------------------- |
   | **Server**     | IP/hostname of your Docker host         |
   | **Port**       | `8086`                                  |
   | **Protocol**   | HTTP (or HTTPS if behind Traefik)       |
   | **Organization** | `homelab` (matches `DOCKER_INFLUXDB_INIT_ORG`) |
   | **Bucket**     | `proxmox` (matches `DOCKER_INFLUXDB_INIT_BUCKET`) |
   | **Token**      | Value of `DOCKER_INFLUXDB_INIT_ADMIN_TOKEN` |

3. Click **Create** — metrics will begin flowing within seconds.

---

## Grafana Datasource Provisioning

The `grafana/provisioning/datasources/datasource.yml` file **automatically** registers InfluxDB as a datasource when the Grafana container starts. No manual configuration needed — just deploy and start building dashboards.

---

## Useful Commands

```bash
# Stop the stack
docker compose down

# Stop and remove all volumes (⚠️ destroys data)
docker compose down -v

# View live logs
docker compose logs -f

# Restart a single service
docker compose restart grafana
```

---

> [!TIP]
> For local / homelab setups without a public domain, you can remove the Traefik labels from `docker-compose.yml` and access services directly on their mapped ports.
