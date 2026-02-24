# pve_linux_tools 🛠️

A collection of utility scripts and Docker configurations designed to streamline management, monitoring, and maintenance for **Proxmox VE (PVE)** environments and Linux containers.

## 📁 Repository Structure

```text
.
├── docker_compose
│   └── monitoring
│       └── docker-compose.yml   # Grafana & InfluxDB stack
└── scripts
    └── update_containers.sh     # Automated LXC update script

```

---

## 🚀 Getting Started

### 1. Smart LXC Updater

The `update_containers.sh` script automates the update process for all **running** LXC containers on your Proxmox host. It features **OS detection** to handle different package managers automatically.

**Supported Distributions:**

* **Debian / Ubuntu** (`apt`)
* **Alpine Linux** (`apk`)
* **Arch Linux** (`pacman`)
* **Fedora** (`dnf`)

**Usage:**

1. Move the script to your PVE host:
```bash
scp scripts/update_containers.sh root@<your-pve-ip>:/root/

```


2. Make it executable and run:
```bash
chmod +x update_containers.sh
./update_containers.sh

```



---

### 2. Monitoring Stack (TIG/Stack Lite)

Located in `docker_compose/monitoring/`, this setup deploys a time-series database and visualization dashboard, ideal for tracking Proxmox metrics via the InfluxDB backend.

**Services Included:**

* **Grafana:** Dashboard visualization (Default port: `3000`)
* **InfluxDB v2:** High-performance data logging (Default port: `8086`)

**Deployment:**

```bash
cd docker_compose/monitoring
docker-compose up -d

```

> [!TIP]
> To integrate this with Proxmox, go to **Datacenter > Metric Server** in the PVE GUI and add an InfluxDB entry pointing to this container's IP.

---

## 🛠️ Requirements

* **Proxmox VE 7.x / 8.x / 9.x**
* **Docker & Docker Compose** (for the monitoring stack)
* **Root Privileges** (for the update script)

## 📜 License

This project is open-source and available under the [MIT License](./LICENSE).

---

