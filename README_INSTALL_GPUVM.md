# Backend.AI GPU VM Auto-Installer

This script automates the complete installation of Backend.AI on a fresh Ubuntu 22.04/24.04 GPU VM with NVIDIA drivers.

## Target Configuration

- **OS**: Ubuntu 22.04 / 24.04
- **GPU**: NVIDIA GPU with driver pre-installed (or auto-installed by script)
- **Deployment**: Production-ready All-in-one (main) or Worker-only (worker)
- **Infrastructure**: Full halfstack via Docker Compose (main node)

## Prerequisites

### Hardware Requirements
- NVIDIA GPU (for GPU workloads)
- Minimum 8GB RAM (16GB+ recommended)
- 50GB+ available disk space

### Software Requirements
- Fresh Ubuntu 22.04 or 24.04 installation
- Root or sudo access
- Network connectivity for package downloads
- NVIDIA driver pre-installed (optional - script can auto-install)

## Quick Start

### Single Node Installation (All-in-one)

```bash
# Clone the repository
git clone https://github.com/lablup/backend.ai.git
cd backend.ai

# Run the installer
sudo ./scripts/install-gpu-vm.sh --mode main
```

### Multi-Node Cluster Setup

**On the main node:**
```bash
sudo ./scripts/install-gpu-vm.sh --mode main
```

**On each worker node:**
```bash
sudo ./scripts/install-gpu-vm.sh --mode worker --main-node-ip <MAIN_NODE_IP>
```

### With Tailscale VPN (Recommended for Multi-Node)

**Main node:**
```bash
sudo ./scripts/install-gpu-vm.sh --mode main --tailscale-auth-key tskey-auth-xxxxx
```

**Worker nodes:**
```bash
sudo ./scripts/install-gpu-vm.sh --mode worker \
    --main-node-ip <TAILSCALE_IP_OF_MAIN> \
    --tailscale-auth-key tskey-auth-xxxxx
```

### With NFS Shared Storage

**Main node (NFS server):**
```bash
sudo ./scripts/install-gpu-vm.sh --mode main --enable-nfs
```

**Worker nodes (NFS clients):**
```bash
sudo ./scripts/install-gpu-vm.sh --mode worker \
    --main-node-ip <MAIN_NODE_IP> \
    --enable-nfs
```

## Installation Modes

### Main Node (`--mode main`)

Installs the complete Backend.AI stack:
- PostgreSQL, Redis/Valkey, etcd, MinIO (via Docker Compose)
- Manager API server
- Storage Proxy
- Webserver
- App Proxy (Coordinator + Worker)
- Agent (optional, can be skipped with `--skip-agent`)

### Worker Node (`--mode worker`)

Installs only the Backend.AI Agent:
- Connects to main node's etcd for cluster coordination
- Registers GPUs and resources with the manager
- Runs compute containers
- Requires `--main-node-ip` to specify the main node

## Command-Line Options

### Multi-Node Options

| Option | Description |
|--------|-------------|
| `--mode MODE` | Installation mode: `main` or `worker` (default: main) |
| `--main-node-ip IP` | IP address of main node (required for worker mode) |
| `--skip-agent` | Skip agent installation on main node |
| `--tailscale-auth-key KEY` | Tailscale auth key for VPN mesh networking |

### NFS Storage Options

| Option | Description |
|--------|-------------|
| `--enable-nfs` | Enable NFS shared storage for vfolders |
| `--nfs-server HOST` | Use external NFS server instead of main node |
| `--nfs-export-path PATH` | NFS export/mount path |
| `--nfs-mount-options OPTS` | NFS client mount options (default: `rw,hard,intr`) |

### Port Options

| Option | Default | Description |
|--------|---------|-------------|
| `--manager-port` | 8091 | Manager API port |
| `--webserver-port` | 8090 | Webserver port |
| `--postgres-port` | 8100 | PostgreSQL port |
| `--redis-port` | 8111 | Redis/Valkey port |
| `--etcd-port` | 8120 | etcd port |

### Other Options

| Option | Description |
|--------|-------------|
| `--install-path PATH` | Installation directory (default: `/opt/backend.ai`) |
| `--skip-gpu-setup` | Skip CUDA toolkit and nvidia-container-toolkit installation |
| `--skip-systemd` | Skip systemd service registration |
| `--skip-image-pull` | Skip pulling container images |
| `--use-system-redis` | Install system Valkey/Redis instead of Docker |
| `--branch BRANCH` | Git branch to checkout (default: main) |
| `-h, --help` | Show help message |

## Architecture

### Single Node Deployment

```
┌─────────────────────────────────────┐
│           Main Node                 │
├─────────────────────────────────────┤
│ Infrastructure (Docker Compose):    │
│   - PostgreSQL (:8100)              │
│   - Redis/Valkey (:8111)            │
│   - etcd (:8120)                    │
│   - MinIO (:9000)                   │
│   - Grafana (:3000)                 │
├─────────────────────────────────────┤
│ Backend.AI Services:                │
│   - Manager (:8091)                 │
│   - Storage-Proxy (:6021/:6022)     │
│   - Webserver (:8090)               │
│   - App-Proxy (:10200/:10201)       │
│   - Agent (:6001)                   │
└─────────────────────────────────────┘
```

### Multi-Node Deployment

```
Main Node (--mode main)              Worker Nodes (--mode worker)
┌─────────────────────────┐          ┌─────────────────────────┐
│ PostgreSQL (:8100)      │          │                         │
│ Redis (:8111)           │◄─────────│ Agent (:6001)           │
│ etcd (:8120)            │          │ └── Connects to etcd    │
│ MinIO (:9000)           │          │                         │
│ Manager (:8091)         │          │ Containers (:30000+)    │
│ Storage-Proxy (:6021)   │          │                         │
│ Webserver (:8090)       │          └─────────────────────────┘
│ App-Proxy (:10200)      │
│ (Optional) Agent        │          ┌─────────────────────────┐
└─────────────────────────┘          │ Worker Node 2           │
                                     │   ...                   │
                                     └─────────────────────────┘
```

### With Tailscale VPN

```
Main Node                            Worker Nodes
┌─────────────────────────┐          ┌─────────────────────────┐
│ Tailscale: 100.64.x.x   │◄────────►│ Tailscale: 100.64.x.x   │
│                         │          │                         │
│ Encrypted VPN mesh      │          │ NAT traversal           │
│ Firewall: 100.64.0.0/10 │          │ Firewall: 100.64.0.0/10 │
└─────────────────────────┘          └─────────────────────────┘
```

## Network Configuration

### Required Ports (Main Node - Inbound)

| Port | Service | Access |
|------|---------|--------|
| 8091 | Manager API | Workers, Clients |
| 8090 | Webserver | Clients |
| 8120 | etcd | Workers |
| 8111 | Redis/Valkey | Workers (optional) |
| 6021 | Storage-Proxy Client | Workers |
| 6022 | Storage-Proxy Manager | Workers |
| 9000 | MinIO | Internal |
| 3000 | Grafana | Monitoring |

### Required Ports (Worker Node - Inbound)

| Port | Service | Access |
|------|---------|--------|
| 6001 | Agent RPC | Manager |
| 6009 | Agent Watcher | Internal |
| 30000-32000 | Container Ports | Clients |

### Tailscale Firewall

When using Tailscale, the script automatically configures UFW firewall:
- Allows Backend.AI ports from Tailscale network (100.64.0.0/10)
- Blocks these ports from other networks
- Always allows SSH

## Post-Installation

### Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| Admin Account | admin@lablup.com | wJalrXUt |
| Grafana | backend | develove |
| MinIO | See docker-compose.halfstack.current.yml |

### Service Management

```bash
# Check service status
sudo systemctl status backendai-manager
sudo systemctl status backendai-agent
sudo systemctl status backendai-storage-proxy
sudo systemctl status backendai-webserver

# Restart services
sudo systemctl restart backendai-manager

# View logs
journalctl -u backendai-manager -f
journalctl -u 'backendai-*' -f  # All services
```

### Testing the Installation

```bash
cd /opt/backend.ai/backend.ai

# Set up environment
source env-local-admin-api.sh

# Run a test container
./backend.ai run python -c "print('Hello from Backend.AI!')"

# Verify GPU access
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

### Verify Worker Registration (from Main Node)

```bash
cd /opt/backend.ai/backend.ai
./backend.ai mgr etcd ls /nodes/agents
```

## Troubleshooting

### NVIDIA Driver Issues

If `nvidia-smi` fails after installation:
```bash
# Check if driver is loaded
lsmod | grep nvidia

# Try loading manually
sudo modprobe nvidia

# If module load fails, reboot may be required
sudo reboot
```

### Agent Not Registering (Worker Node)

1. Check etcd connectivity:
   ```bash
   nc -zv <MAIN_NODE_IP> 8120
   ```

2. Check agent logs:
   ```bash
   journalctl -u backendai-agent -f
   ```

3. Verify firewall rules:
   ```bash
   sudo ufw status
   ```

### NFS Mount Issues

1. Check NFS server exports:
   ```bash
   showmount -e <NFS_SERVER_IP>
   ```

2. Verify mount:
   ```bash
   mount | grep nfs
   ```

### Docker GPU Access Issues

```bash
# Verify nvidia-container-toolkit
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi

# If it fails, reconfigure and restart Docker
sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
sudo systemctl restart docker
```

## Directory Structure

After installation:
```
/opt/backend.ai/
├── backend.ai/              # Backend.AI source repository
│   ├── manager.toml         # Manager configuration
│   ├── agent.toml           # Agent configuration
│   ├── storage-proxy.toml   # Storage proxy configuration
│   ├── webserver.conf       # Webserver configuration
│   ├── docker-compose.halfstack.current.yml
│   ├── env-local-admin-api.sh
│   ├── env-local-user-api.sh
│   └── vfroot/local/        # Virtual folder storage
├── .venv/                   # Python virtual environment
└── var/lib/backend.ai/      # Runtime data
```

## Systemd Services

### Main Node Services
- `backendai-manager`
- `backendai-storage-proxy`
- `backendai-webserver`
- `backendai-appproxy-coordinator`
- `backendai-appproxy-worker`
- `backendai-agent` (if not skipped)

### Worker Node Services
- `backendai-agent`

## Security Notes

For production deployments:
- Change default passwords and API keys
- Set up SSL/TLS certificates
- Configure proper firewall rules
- Use Tailscale or VPN for inter-node communication
- Restrict access to management ports

## License

See the main Backend.AI repository for license information.
