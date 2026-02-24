# Scripts 📜

Utility scripts for Proxmox VE host-level automation.

---

## `update_containers.sh`

A fully automated bash script that updates **all running LXC containers** on a Proxmox VE host. It detects the operating system inside each container and runs the appropriate package manager commands.

### Features

- **Root check** — exits immediately if not run as `root`.
- **Auto-discovery** — uses `pct list` to find all running containers.
- **OS detection** — probes release files inside each container to identify the distribution.
- **Multi-distro support** — handles four major package managers out of the box.

### Supported Distributions

| Distribution     | Detection File           | Package Manager Command                                        |
| ---------------- | ------------------------ | -------------------------------------------------------------- |
| Debian / Ubuntu  | `/etc/debian_version`    | `apt-get update && apt-get dist-upgrade -y && apt-get autoremove -y` |
| Alpine Linux     | `/etc/alpine-release`    | `apk update && apk upgrade`                                   |
| Arch Linux       | `/etc/arch-release`      | `pacman -Syu --noconfirm`                                     |
| Fedora           | `/etc/fedora-release`    | `dnf upgrade -y`                                               |

### Usage

1. **Copy the script to your Proxmox host:**

   ```bash
   scp scripts/update_containers.sh root@<your-pve-ip>:/root/
   ```

2. **Make it executable and run:**

   ```bash
   chmod +x /root/update_containers.sh
   ./update_containers.sh
   ```

### Scheduling with Cron

To run the script automatically every Sunday at 03:00 AM:

```bash
crontab -e
```

Add the following line:

```cron
0 3 * * 0 /root/update_containers.sh >> /var/log/lxc_updates.log 2>&1
```

### Example Output

```text
--- Starting Smart LXC Updates ---
Processing 100 (nginx-proxy)...
  Detected: Debian/Ubuntu (apt)
Successfully updated nginx-proxy.
--------------------------------------
Processing 101 (alpine-dns)...
  Detected: Alpine (apk)
Successfully updated alpine-dns.
--------------------------------------
--- All running containers have been processed ---
```

---

> [!WARNING]
> This script must be run **directly on the Proxmox VE host** as `root`. It will not work inside a container or on a remote machine without `pct` access.
