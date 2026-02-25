# 🏠 Homelab Stack

A self-hosted productivity and monitoring stack deployed via a single Docker Compose file. All services share a `homelab` bridge network and store persistent data under a configurable root directory.

---

## 📋 Services Overview

### Core & Networking

| Service | Image | Port(s) | Description |
|---------|-------|---------|-------------|
| **Nginx Proxy Manager** | `jc21/nginx-proxy-manager` | `80` `81` `443` | Reverse proxy with GUI & Let's Encrypt |

### Shared Databases

| Service | Image | Description |
|---------|-------|-------------|
| **PostgreSQL 16** | `postgres:16-alpine` | Primary DB for Docmost, Affine |
| **Redis 7** | `redis:7-alpine` | Shared in-memory cache |
| **MariaDB 10** | `mariadb:10` | DB for Vikunja |

### Productivity Apps

| Service | Image | Port | Description |
|---------|-------|------|-------------|
| **n8n** | `n8nio/n8n` | `5678` | Workflow automation |
| **Docmost** | `docmost/docmost` | `3005` | Collaborative wiki / docs |
| **Affine** | `toeverything/affine` | `3010` | Notion alternative (whiteboard + docs) |
| **Vikunja** | `vikunja/vikunja` | `3456` | Task / project management |
| **Homebox** | `sysadminsmedia/homebox` | `7745` | Home inventory management |
| **Mealie** | `hkotel/mealie` | `9925` | Recipe manager |
| **Actual Budget** | `actualbudget/actual-server` | `5006` | Personal finance / budgeting |

### Monitoring & Dashboards

| Service | Image | Port | Description |
|---------|-------|------|-------------|
| **Glance** | `glanceapp/glance` | `8080` | Minimal dashboard |
| **Uptime Kuma** | `louislam/uptime-kuma` | `3001` | Service uptime monitor |
| **MySpeed** | `germannewsmaker/myspeed` | `5216` | Internet speed tracker |
| **Grafana** | `grafana/grafana-enterprise` | `3000` | Metrics visualization |
| **InfluxDB** | `influxdb:latest` | `8086` | Time-series database |

---

## 🚀 Quick Start

```bash
# 1. Navigate to the homelab directory
cd docker_compose/homelab

# 2. Create your .env from the template
cp .env.example .env

# 3. Edit with your real values (passwords, IPs, domain names)
nano .env

# 4. Launch the stack
docker compose up -d

# 5. Check status
docker compose ps
```

---

## ⚙️ Configuration

All configuration is managed through the **`.env`** file. Copy `.env.example` and update the values:

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Europe/Paris` | Timezone for containers |
| `HOST_IP` | `192.168.1.153` | LAN IP of the Docker host |
| `DOCKER_DATA_DIR` | `/docker` | Root directory for all persistent volumes |
| `POSTGRES_PASSWORD` | — | PostgreSQL superuser password |
| `MYSQL_ROOT_PASSWORD` | — | MariaDB root password |
| `DOCMOST_APP_SECRET` | — | Random secret for Docmost sessions |
| `DOCMOST_PORT` | `3005` | Docmost host port |
| `AFFINE_ADMIN_EMAIL` | — | Affine admin login email |
| `AFFINE_ADMIN_PASSWORD` | — | Affine admin login password |
| `N8N_HOST` | `n8n.local` | n8n hostname |
| `N8N_PORT` | `5678` | n8n host port |
| `VIKUNJA_PORT` | `3456` | Vikunja host port |
| `MEALIE_PORT` | `9925` | Mealie host port |
| `MEALIE_BASE_URL` | `http://mealie.local` | Mealie public URL |
| `INFLUXDB_INIT_USERNAME` | `admin` | InfluxDB admin user |
| `INFLUXDB_INIT_PASSWORD` | — | InfluxDB admin password |
| `INFLUXDB_INIT_ORG` | `homelab` | InfluxDB organization |
| `INFLUXDB_INIT_BUCKET` | `default` | InfluxDB default bucket |

> ⚠️ **Security:** The `.env` file is **git-ignored** by default. Never commit real credentials. Only `.env.example` with placeholder values is tracked.

---

## 📁 Directory Structure

```text
homelab/
├── .env.example          # Template — safe to commit
├── .env                  # Your real config — git-ignored
├── docker-compose.yml    # Stack definition
└── README.md             # ← You are here
```

### Persistent Data Layout

All container data is stored under `${DOCKER_DATA_DIR}` (default: `/docker`):

```text
/docker/
├── npm/                  # Nginx Proxy Manager
├── postgres/             # PostgreSQL data
├── redis/                # Redis data
├── mariadb/              # MariaDB data
├── n8n/                  # n8n workflows
├── affine/               # Affine config + storage
├── vikunja/              # Vikunja files
├── homebox/              # Homebox data
├── mealie/               # Mealie recipes
├── actualbudget/         # Actual Budget data
├── glance/               # Glance config (glance.yml)
├── uptime-kuma/          # Uptime Kuma data
├── myspeed/              # MySpeed data
├── grafana/              # Grafana dashboards + config
└── influxdb/             # InfluxDB data + config
```

---

## 🗄️ Database Initialization

### PostgreSQL

Databases for Docmost and Affine must be created before first run:

```bash
# After Postgres is healthy:
docker exec -it postgres psql -U postgres -c "CREATE DATABASE docmost;"
docker exec -it postgres psql -U postgres -c "CREATE DATABASE affine;"
```

### MariaDB

The Vikunja database must be created before first run:

```bash
docker exec -it mariadb mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE vikunja;"
```

---

## 🔧 Common Commands

```bash
# Start all services
docker compose up -d

# Stop all services
docker compose down

# View logs for a specific service
docker compose logs -f docmost

# Restart a single service
docker compose restart n8n

# Pull latest images and recreate
docker compose pull && docker compose up -d

# Check resource usage
docker stats --no-stream
```

---

## 🔒 Security Recommendations

1. **Change all default passwords** in `.env` before first deployment
2. **Use Nginx Proxy Manager** (port `81`) to set up SSL for all services
3. **Restrict port exposure** — consider removing direct port mappings once NPM is configured
4. **Regular backups** — snapshot `${DOCKER_DATA_DIR}` or use ZFS/LVM snapshots
5. **Keep images updated** — run `docker compose pull` regularly

---

## 📜 License

Part of [pve_linux_tools](../../README.md) — MIT License.
