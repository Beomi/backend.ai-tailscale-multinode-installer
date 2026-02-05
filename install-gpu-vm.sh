#!/bin/bash
#
# Backend.AI GPU VM Auto-Installer (Multi-Node Support)
#
# This script automates the complete installation of Backend.AI on a fresh
# Ubuntu 22.04/24.04 GPU VM with NVIDIA drivers pre-installed.
#
# Target Configuration:
# - Deployment: Production All-in-one (main) or Worker-only (worker)
# - OS: Ubuntu 22.04/24.04
# - GPU: NVIDIA driver pre-installed, script installs CUDA toolkit + nvidia-container-toolkit
# - Infrastructure: Full halfstack via Docker Compose (main node only)
#
# Usage:
#   ./scripts/install-gpu-vm.sh [OPTIONS]
#
# For full options list, run:
#   ./scripts/install-gpu-vm.sh --help
#

set -e

# Set "echo -e" as default
shopt -s xpg_echo

#######################################
# Color definitions
#######################################
RED="\033[0;91m"
GREEN="\033[0;92m"
YELLOW="\033[0;93m"
BLUE="\033[0;94m"
CYAN="\033[0;96m"
WHITE="\033[0;97m"
LRED="\033[1;31m"
LGREEN="\033[1;32m"
LYELLOW="\033[1;33m"
LBLUE="\033[1;34m"
LCYAN="\033[1;36m"
LWHITE="\033[1;37m"
BOLD="\033[1m"
NC="\033[0m"

#######################################
# Global variables
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"

# Default configuration
INSTALL_PATH="/opt/backend.ai"
MANAGER_PORT="8091"
WEBSERVER_PORT="8090"
POSTGRES_PORT="8100"
REDIS_PORT="8111"
ETCD_PORT="8120"
AGENT_RPC_PORT="6001"
AGENT_WATCHER_PORT="6009"
STORAGE_PROXY_CLIENT_PORT="6021"
STORAGE_PROXY_MANAGER_PORT="6022"
APPPROXY_COORDINATOR_PORT="10200"
APPPROXY_WORKER_PORT="10201"
IPC_BASE_PATH="/tmp/backend.ai/ipc"
VAR_BASE_PATH="${INSTALL_PATH}/var/lib/backend.ai"
VFOLDER_REL_PATH="vfroot/local"
LOCAL_STORAGE_PROXY="local"
LOCAL_STORAGE_VOLUME="volume1"
GIT_BRANCH="main"
GIT_REPO="https://github.com/lablup/backend.ai.git"
SKIP_GPU_SETUP=0
SKIP_SYSTEMD=0
SKIP_IMAGE_PULL=0
USE_SYSTEM_REDIS=0            # Use system Valkey/Redis instead of Docker

# Multi-node configuration
INSTALL_MODE="main"           # 'main' or 'worker'
MAIN_NODE_IP=""               # Required for worker mode
SKIP_AGENT=0                  # For main node without local agent

# Tailscale configuration
TAILSCALE_AUTH_KEY=""         # Auth key for Tailscale
TAILSCALE_IP=""               # Will be populated after Tailscale connects

# NFS configuration
NFS_ENABLED=0                 # Enable NFS for vfolder sharing
NFS_SERVER=""                 # External NFS server (if using existing NFS)
NFS_EXPORT_PATH=""            # NFS export path
NFS_MOUNT_OPTIONS="rw,hard,intr"  # NFS client mount options
NFS_EXPORT_OPTIONS="rw,sync,no_subtree_check,no_root_squash"  # NFS server export options

# Runtime variables
PYTHON_VERSION=""
UBUNTU_VERSION=""
ARCH=""
INSTALL_USER=""
INSTALL_GROUP=""
LOCAL_IP=""

#######################################
# Helper functions
#######################################

show_error() {
    echo "${RED}[ERROR]${NC} ${LRED}$1${NC}" >&2
}

show_warning() {
    echo "${YELLOW}[WARN]${NC} ${LYELLOW}$1${NC}"
}

show_info() {
    echo "${BLUE}[INFO]${NC} ${GREEN}$1${NC}"
}

show_note() {
    echo "${BLUE}[NOTE]${NC} $1"
}

show_step() {
    echo ""
    echo "${LCYAN}========================================${NC}"
    echo "${LCYAN}  $1${NC}"
    echo "${LCYAN}========================================${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        show_error "This script must be run as root or with sudo"
        exit 1
    fi
}

get_local_ip() {
    # Prefer Tailscale IP if available
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo "$TAILSCALE_IP"
        return
    fi

    # Fall back to primary network IP
    local ip
    ip=$(hostname -I | awk '{print $1}')
    if [[ -z "$ip" ]]; then
        ip=$(ip route get 1 | awk '{print $7;exit}')
    fi
    echo "$ip"
}

usage() {
    echo "${GREEN}Backend.AI GPU VM Auto-Installer (Multi-Node Support)${NC}"
    echo ""
    echo "Automates the complete installation of Backend.AI on a fresh Ubuntu 22.04/24.04"
    echo "GPU VM with NVIDIA drivers pre-installed."
    echo ""
    echo "${LWHITE}USAGE${NC}"
    echo "  $SCRIPT_NAME [OPTIONS]"
    echo ""
    echo "${LWHITE}MULTI-NODE OPTIONS${NC}"
    echo "  ${LWHITE}--mode MODE${NC}"
    echo "    Installation mode: 'main' or 'worker' (default: main)"
    echo "    - main: Full installation with manager, halfstack, webserver, storage-proxy"
    echo "    - worker: Agent-only installation, connects to main node"
    echo ""
    echo "  ${LWHITE}--main-node-ip IP${NC}"
    echo "    IP address of the main node (required for worker mode)"
    echo ""
    echo "  ${LWHITE}--skip-agent${NC}"
    echo "    Skip agent installation on main node (main mode only)"
    echo ""
    echo "  ${LWHITE}--tailscale-auth-key KEY${NC}"
    echo "    Tailscale auth key for automatic VPN mesh networking"
    echo "    Nodes will use Tailscale IPs for all communication"
    echo ""
    echo "${LWHITE}NFS SHARED STORAGE OPTIONS${NC}"
    echo "  ${LWHITE}--enable-nfs${NC}"
    echo "    Enable NFS shared storage for vfolders"
    echo ""
    echo "  ${LWHITE}--nfs-server HOST${NC}"
    echo "    Use external NFS server instead of main node"
    echo ""
    echo "  ${LWHITE}--nfs-export-path PATH${NC}"
    echo "    NFS export/mount path (default: vfroot/local)"
    echo ""
    echo "  ${LWHITE}--nfs-mount-options OPTS${NC}"
    echo "    NFS client mount options (default: rw,hard,intr)"
    echo ""
    echo "${LWHITE}PORT OPTIONS${NC}"
    echo "  ${LWHITE}--manager-port PORT${NC}"
    echo "    Manager API port (default: 8091)"
    echo ""
    echo "  ${LWHITE}--webserver-port PORT${NC}"
    echo "    Webserver port (default: 8090)"
    echo ""
    echo "  ${LWHITE}--postgres-port PORT${NC}"
    echo "    PostgreSQL port (default: 8100)"
    echo ""
    echo "  ${LWHITE}--redis-port PORT${NC}"
    echo "    Redis/Valkey port (default: 8111)"
    echo ""
    echo "  ${LWHITE}--etcd-port PORT${NC}"
    echo "    etcd port (default: 8120)"
    echo ""
    echo "${LWHITE}OTHER OPTIONS${NC}"
    echo "  ${LWHITE}-h, --help${NC}"
    echo "    Show this help message and exit"
    echo ""
    echo "  ${LWHITE}--install-path PATH${NC}"
    echo "    Installation directory (default: /opt/backend.ai)"
    echo ""
    echo "  ${LWHITE}--skip-gpu-setup${NC}"
    echo "    Skip CUDA toolkit and nvidia-container-toolkit installation"
    echo "    (CUDA toolkit version is auto-selected based on driver version)"
    echo ""
    echo "  ${LWHITE}--skip-systemd${NC}"
    echo "    Skip systemd service registration"
    echo ""
    echo "  ${LWHITE}--skip-image-pull${NC}"
    echo "    Skip pulling container images"
    echo ""
    echo "  ${LWHITE}--use-system-redis${NC}"
    echo "    Install system Valkey/Redis instead of using Docker Redis"
    echo "    (Useful for production or when Docker Redis is unreliable)"
    echo ""
    echo "  ${LWHITE}--branch BRANCH${NC}"
    echo "    Git branch to checkout (default: main)"
    echo ""
    echo "${LWHITE}EXAMPLES${NC}"
    echo "  # Install main node (single node or main in multi-node setup)"
    echo "  sudo $SCRIPT_NAME --mode main"
    echo ""
    echo "  # Install worker node connecting to main at 192.168.1.100"
    echo "  sudo $SCRIPT_NAME --mode worker --main-node-ip 192.168.1.100"
    echo ""
    echo "  # Install main node without local agent"
    echo "  sudo $SCRIPT_NAME --mode main --skip-agent"
    echo ""
    echo "  # Install main node with Tailscale VPN mesh"
    echo "  sudo $SCRIPT_NAME --mode main --tailscale-auth-key tskey-auth-xxxxx"
    echo ""
    echo "  # Install worker node with Tailscale (use main node's Tailscale IP)"
    echo "  sudo $SCRIPT_NAME --mode worker --main-node-ip 100.64.0.1 --tailscale-auth-key tskey-auth-xxxxx"
    echo ""
    echo "  # Install to custom path with custom ports"
    echo "  sudo $SCRIPT_NAME --install-path /home/bai/backend.ai --manager-port 9091"
    echo ""
    echo "  # Main node with NFS shared storage"
    echo "  sudo $SCRIPT_NAME --mode main --enable-nfs"
    echo ""
    echo "  # Worker with NFS (mounts from main node)"
    echo "  sudo $SCRIPT_NAME --mode worker --main-node-ip 192.168.1.100 --enable-nfs"
    echo ""
    echo "  # With Tailscale + NFS (recommended for multi-node)"
    echo "  sudo $SCRIPT_NAME --mode main --tailscale-auth-key tskey-auth-xxxxx --enable-nfs"
    echo ""
    echo "  # Worker with Tailscale + NFS"
    echo "  sudo $SCRIPT_NAME --mode worker --main-node-ip 100.64.0.1 --tailscale-auth-key tskey-auth-xxxxx --enable-nfs"
    echo ""
    echo "  # Worker with external NFS server"
    echo "  sudo $SCRIPT_NAME --mode worker --main-node-ip 192.168.1.100 --nfs-server 192.168.1.50 --nfs-export-path /exports/backendai"
    echo ""
    echo "${LWHITE}ARCHITECTURE${NC}"
    echo ""
    echo "  Main Node (--mode main):           Worker Node (--mode worker):"
    echo "  ┌─────────────────────────┐        ┌─────────────────────────┐"
    echo "  │ PostgreSQL (:8100)      │        │                         │"
    echo "  │ Redis (:8111)           │◄───────│ Agent (:6001)           │"
    echo "  │ etcd (:8120)            │        │ └── Connects to etcd    │"
    echo "  │ MinIO (:9000)           │        │                         │"
    echo "  │ Manager (:8091)         │        │ Containers (:30000+)    │"
    echo "  │ Storage-Proxy (:6021)   │        │                         │"
    echo "  │ Webserver (:8090)       │        └─────────────────────────┘"
    echo "  │ App-Proxy (:10200)      │"
    echo "  │ (Optional) Agent        │"
    echo "  └─────────────────────────┘"
    echo ""
    echo "  With Tailscale (--tailscale-auth-key):"
    echo "  ┌─────────────────────────┐        ┌─────────────────────────┐"
    echo "  │ Main Node               │        │ Worker Node             │"
    echo "  │ Tailscale: 100.64.x.x   │◄──────►│ Tailscale: 100.64.x.x   │"
    echo "  │                         │        │                         │"
    echo "  │ Encrypted VPN mesh      │        │ NAT traversal           │"
    echo "  └─────────────────────────┘        └─────────────────────────┘"
    echo ""
}

#######################################
# Parse command line arguments
#######################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            --mode)
                INSTALL_MODE="$2"
                shift 2
                ;;
            --mode=*)
                INSTALL_MODE="${1#*=}"
                shift
                ;;
            --main-node-ip)
                MAIN_NODE_IP="$2"
                shift 2
                ;;
            --main-node-ip=*)
                MAIN_NODE_IP="${1#*=}"
                shift
                ;;
            --skip-agent)
                SKIP_AGENT=1
                shift
                ;;
            --install-path)
                INSTALL_PATH="$2"
                shift 2
                ;;
            --install-path=*)
                INSTALL_PATH="${1#*=}"
                shift
                ;;
            --manager-port)
                MANAGER_PORT="$2"
                shift 2
                ;;
            --manager-port=*)
                MANAGER_PORT="${1#*=}"
                shift
                ;;
            --webserver-port)
                WEBSERVER_PORT="$2"
                shift 2
                ;;
            --webserver-port=*)
                WEBSERVER_PORT="${1#*=}"
                shift
                ;;
            --postgres-port)
                POSTGRES_PORT="$2"
                shift 2
                ;;
            --postgres-port=*)
                POSTGRES_PORT="${1#*=}"
                shift
                ;;
            --redis-port)
                REDIS_PORT="$2"
                shift 2
                ;;
            --redis-port=*)
                REDIS_PORT="${1#*=}"
                shift
                ;;
            --etcd-port)
                ETCD_PORT="$2"
                shift 2
                ;;
            --etcd-port=*)
                ETCD_PORT="${1#*=}"
                shift
                ;;
            --skip-gpu-setup)
                SKIP_GPU_SETUP=1
                shift
                ;;
            --skip-systemd)
                SKIP_SYSTEMD=1
                shift
                ;;
            --skip-image-pull)
                SKIP_IMAGE_PULL=1
                shift
                ;;
            --use-system-redis)
                USE_SYSTEM_REDIS=1
                shift
                ;;
            --branch)
                GIT_BRANCH="$2"
                shift 2
                ;;
            --branch=*)
                GIT_BRANCH="${1#*=}"
                shift
                ;;
            --tailscale-auth-key)
                TAILSCALE_AUTH_KEY="$2"
                shift 2
                ;;
            --tailscale-auth-key=*)
                TAILSCALE_AUTH_KEY="${1#*=}"
                shift
                ;;
            --enable-nfs)
                NFS_ENABLED=1
                shift
                ;;
            --nfs-server)
                NFS_SERVER="$2"
                NFS_ENABLED=1
                shift 2
                ;;
            --nfs-server=*)
                NFS_SERVER="${1#*=}"
                NFS_ENABLED=1
                shift
                ;;
            --nfs-export-path)
                NFS_EXPORT_PATH="$2"
                shift 2
                ;;
            --nfs-export-path=*)
                NFS_EXPORT_PATH="${1#*=}"
                shift
                ;;
            --nfs-mount-options)
                NFS_MOUNT_OPTIONS="$2"
                shift 2
                ;;
            --nfs-mount-options=*)
                NFS_MOUNT_OPTIONS="${1#*=}"
                shift
                ;;
            *)
                show_error "Unknown option: $1"
                echo "Run '$SCRIPT_NAME --help' for usage."
                exit 1
                ;;
        esac
    done

    # Update derived paths
    VAR_BASE_PATH="${INSTALL_PATH}/var/lib/backend.ai"
    IPC_BASE_PATH="/tmp/backend.ai/ipc"
}

#######################################
# Validate installation mode
#######################################

validate_mode() {
    # Validate mode value
    case "$INSTALL_MODE" in
        main|worker)
            show_info "Installation mode: $INSTALL_MODE"
            ;;
        *)
            show_error "Invalid mode: $INSTALL_MODE. Must be 'main' or 'worker'"
            exit 1
            ;;
    esac

    # Worker mode validation
    if [[ "$INSTALL_MODE" == "worker" ]]; then
        if [[ -z "$MAIN_NODE_IP" ]]; then
            show_error "--main-node-ip is required for worker mode"
            exit 1
        fi

        show_info "Main node IP: $MAIN_NODE_IP"

        # Check etcd connectivity (non-fatal warning)
        if command -v nc &> /dev/null; then
            if ! nc -z -w 5 "$MAIN_NODE_IP" "$ETCD_PORT" 2>/dev/null; then
                show_warning "Cannot reach etcd at $MAIN_NODE_IP:$ETCD_PORT"
                show_warning "Make sure the main node is running and ports are accessible"
            else
                show_info "etcd connectivity check passed"
            fi
        fi
    fi

    # Main mode with --skip-agent validation
    if [[ "$INSTALL_MODE" == "main" ]] && [[ $SKIP_AGENT -eq 1 ]]; then
        show_info "Main node will be installed without local agent"
    fi

    # Get local IP (Tailscale IP will be set later if auth key provided)
    LOCAL_IP=$(get_local_ip)
    show_info "Local IP address: $LOCAL_IP"
}

# Called after Tailscale is installed to update LOCAL_IP
update_local_ip_for_tailscale() {
    if [[ -n "$TAILSCALE_IP" ]]; then
        LOCAL_IP="$TAILSCALE_IP"
        show_info "Using Tailscale IP for services: $LOCAL_IP"
    fi
}

#######################################
# Phase 1: System Prerequisites
#######################################

check_ubuntu_version() {
    show_info "Checking Ubuntu version..."

    if [[ ! -f /etc/os-release ]]; then
        show_error "Cannot detect OS version. This script requires Ubuntu 22.04 or 24.04."
        exit 1
    fi

    source /etc/os-release

    if [[ "$ID" != "ubuntu" ]]; then
        show_error "This script requires Ubuntu. Detected: $ID"
        exit 1
    fi

    UBUNTU_VERSION="$VERSION_ID"
    case "$UBUNTU_VERSION" in
        22.04|24.04)
            show_info "Ubuntu $UBUNTU_VERSION detected - OK"
            ;;
        *)
            show_error "Unsupported Ubuntu version: $UBUNTU_VERSION"
            show_error "This script supports Ubuntu 22.04 and 24.04"
            exit 1
            ;;
    esac
}

install_nvidia_driver() {
    show_info "Installing NVIDIA driver..."

    # Install ubuntu-drivers utility if not present
    apt-get update
    apt-get install -y ubuntu-drivers-common

    # Auto-detect and show available drivers
    show_info "Detecting available NVIDIA drivers..."
    ubuntu-drivers devices

    # Install the recommended driver
    # Note: --gpgpu flag uses different (often older) selection logic for server drivers,
    # so we use standard install which respects the "recommended" flag from ubuntu-drivers devices
    show_info "Installing recommended NVIDIA driver..."
    if ! ubuntu-drivers install; then
        show_warning "Standard driver installation failed, trying GPGPU install..."
        ubuntu-drivers install --gpgpu
    fi

    # Try to load the nvidia kernel modules dynamically
    show_info "Loading NVIDIA kernel modules..."

    # Remove any conflicting modules first
    modprobe -r nouveau 2>/dev/null || true

    # Load NVIDIA modules
    if modprobe nvidia; then
        modprobe nvidia_uvm 2>/dev/null || true
        modprobe nvidia_drm 2>/dev/null || true
        show_info "NVIDIA kernel modules loaded successfully"
    else
        show_warning "Failed to load NVIDIA modules dynamically"
        show_warning "A system reboot may be required"
        show_note "After reboot, re-run this script to continue installation"
        exit 1
    fi
}

check_nvidia_driver() {
    show_info "Checking NVIDIA driver..."

    if ! command -v nvidia-smi &> /dev/null; then
        show_warning "nvidia-smi not found. Installing NVIDIA driver..."
        install_nvidia_driver
    fi

    if ! nvidia-smi &> /dev/null; then
        show_error "nvidia-smi failed. NVIDIA driver may not be properly loaded."
        show_note "Try rebooting the system and re-running this script."
        exit 1
    fi

    local driver_version
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    show_info "NVIDIA driver version: $driver_version - OK"
}

detect_architecture() {
    show_info "Detecting system architecture..."

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)
            show_info "Architecture: x86_64 - OK"
            ;;
        aarch64)
            show_info "Architecture: aarch64 (ARM64) - OK"
            ;;
        *)
            show_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

install_system_packages() {
    show_info "Installing system packages..."

    apt-get update
    apt-get install -y \
        git \
        git-lfs \
        jq \
        curl \
        wget \
        build-essential \
        libssl-dev \
        libffi-dev \
        pkg-config \
        ca-certificates \
        gnupg \
        lsb-release \
        software-properties-common \
        netcat-openbsd

    # Initialize git-lfs
    git lfs install
}

install_rover() {
    show_info "Installing Rover (Apollo GraphQL CLI)..."

    if command -v rover &> /dev/null; then
        show_info "Rover already installed: $(rover --version)"
        return 0
    fi

    # Install rover using the official installer
    # The installer puts it in ~/.rover/bin by default
    curl -sSL https://rover.apollo.dev/nix/latest | sh || true

    # Create symlink to make it available system-wide
    # Check both $HOME and /root since script runs as root
    local rover_path=""
    if [[ -f "$HOME/.rover/bin/rover" ]]; then
        rover_path="$HOME/.rover/bin/rover"
    elif [[ -f "/root/.rover/bin/rover" ]]; then
        rover_path="/root/.rover/bin/rover"
    fi

    if [[ -n "$rover_path" ]]; then
        ln -sf "$rover_path" /usr/local/bin/rover
        show_info "Rover installed successfully: $(rover --version 2>/dev/null || echo 'installed')"
    else
        show_warning "Rover installation may have failed, GraphQL supergraph generation will be skipped"
    fi
}

install_valkey() {
    show_info "Installing Valkey (Redis-compatible server)..."

    # Check if Valkey or Redis is already installed
    if command -v valkey-server &> /dev/null; then
        show_info "Valkey already installed: $(valkey-server --version)"
        return 0
    fi

    if command -v redis-server &> /dev/null; then
        show_info "Redis already installed: $(redis-server --version)"
        show_info "Using existing Redis installation"
        return 0
    fi

    # Try to install Valkey first (preferred)
    show_info "Adding Valkey repository..."
    if curl -fsSL https://packages.valkey.io/gpg 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/valkey-archive-keyring.gpg 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/valkey-archive-keyring.gpg] https://packages.valkey.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/valkey.list > /dev/null
        apt-get update

        if apt-get install -y valkey 2>/dev/null; then
            show_info "Valkey installed successfully"
            configure_valkey_port "valkey"
            return 0
        fi
    fi

    # Fallback to Redis if Valkey installation fails
    show_warning "Valkey installation failed, falling back to Redis..."
    apt-get update
    apt-get install -y redis-server

    if command -v redis-server &> /dev/null; then
        show_info "Redis installed successfully"
        configure_valkey_port "redis"
        return 0
    fi

    show_error "Failed to install Valkey or Redis"
    exit 1
}

configure_valkey_port() {
    local service_type="$1"  # "valkey" or "redis"
    local config_file
    local service_name

    if [[ "$service_type" == "valkey" ]]; then
        config_file="/etc/valkey/valkey.conf"
        service_name="valkey"
    else
        config_file="/etc/redis/redis.conf"
        service_name="redis-server"
    fi

    show_info "Configuring $service_type to use port ${REDIS_PORT}..."

    if [[ -f "$config_file" ]]; then
        # Update port configuration (handles both "port 6379" and "# port 6379")
        # First uncomment if commented, then change value
        sed -i "s/^#\s*port\s.*/port ${REDIS_PORT}/" "$config_file"
        sed -i "s/^port\s.*/port ${REDIS_PORT}/" "$config_file"

        # Update bind to allow connections from all interfaces (for multi-node support)
        # Redis 7+ uses "bind 127.0.0.1 -::1" format
        sed -i "s/^#\s*bind\s.*/bind 0.0.0.0/" "$config_file"
        sed -i "s/^bind\s.*/bind 0.0.0.0/" "$config_file"

        # Disable protected mode for local development (halfstack)
        sed -i "s/^#\s*protected-mode\s.*/protected-mode no/" "$config_file"
        sed -i "s/^protected-mode\s.*/protected-mode no/" "$config_file"

        # Ensure daemonize is set correctly for systemd
        sed -i "s/^daemonize\s.*/daemonize no/" "$config_file"
    fi

    # Stop the service first to release the port
    systemctl stop "$service_name" 2>/dev/null || true

    # Enable and start the service
    systemctl enable "$service_name"
    if ! systemctl start "$service_name"; then
        show_warning "$service_type failed to start, checking logs..."
        journalctl -u "$service_name" --no-pager -n 20
        return 1
    fi

    # Verify it's running on the correct port
    sleep 2
    if ss -tlnp | grep -q ":${REDIS_PORT}"; then
        show_info "$service_type is running on port ${REDIS_PORT}"
    else
        show_warning "$service_type may not be running on the expected port"
        ss -tlnp | grep -i redis || true
    fi
}

configure_system_limits() {
    show_info "Configuring system limits..."

    # Configure ulimits
    cat > /etc/security/limits.d/99-backendai.conf << 'EOF'
root hard nofile 512000
root soft nofile 512000
root hard nproc 65536
root soft nproc 65536
* hard nofile 512000
* soft nofile 512000
* hard nproc 65536
* soft nproc 65536
EOF

    # Configure sysctl
    cat > /etc/sysctl.d/99-backendai.conf << 'EOF'
fs.file-max=2048000
net.core.somaxconn=1024
net.ipv4.tcp_max_syn_backlog=1024
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_early_retrans=1
net.ipv4.ip_local_port_range=10000 65000
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 12582912 16777216
net.ipv4.tcp_wmem=4096 12582912 16777216
vm.overcommit_memory=1
EOF

    # Apply sysctl changes
    sysctl -p /etc/sysctl.d/99-backendai.conf || true

    show_info "System limits configured"
}

#######################################
# Phase 2: Docker Setup
#######################################

install_docker() {
    show_info "Checking Docker installation..."

    if command -v docker &> /dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null || echo "unknown")
        show_info "Docker already installed: $docker_version"
    else
        show_info "Installing Docker Engine..."

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Add the repository to Apt sources
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    # Enable and start Docker
    systemctl enable docker
    systemctl start docker

    # Verify Docker Compose v2
    if ! docker compose version &> /dev/null; then
        show_error "Docker Compose v2 not found. Please install docker-compose-plugin."
        exit 1
    fi

    show_info "Docker Compose $(docker compose version --short) - OK"
}

add_user_to_docker_group() {
    local target_user="${SUDO_USER:-$USER}"
    if [[ -n "$target_user" ]] && [[ "$target_user" != "root" ]]; then
        if ! groups "$target_user" | grep -q docker; then
            show_info "Adding $target_user to docker group..."
            usermod -aG docker "$target_user"
            show_note "User $target_user added to docker group. Please re-login to apply."
        fi
    fi
}

#######################################
# Phase 2.5: Tailscale Setup (Optional)
#######################################

install_tailscale() {
    if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
        show_info "Skipping Tailscale installation (no auth key provided)"
        return 0
    fi

    show_info "Installing Tailscale..."

    # Check if already installed and connected
    if command -v tailscale &> /dev/null; then
        if tailscale status &> /dev/null; then
            show_info "Tailscale already installed and connected"
            TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
            show_info "Tailscale IP: $TAILSCALE_IP"
            return 0
        fi
    fi

    # Install Tailscale
    curl -fsSL https://tailscale.com/install.sh | sh

    # Connect with auth key
    show_info "Connecting to Tailscale network..."
    tailscale up --auth-key="$TAILSCALE_AUTH_KEY"

    # Wait for connection and get IP
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
        if [[ -n "$TAILSCALE_IP" ]]; then
            break
        fi
        attempt=$((attempt + 1))
        echo "Waiting for Tailscale connection... ($attempt/$max_attempts)"
        sleep 2
    done

    if [[ -z "$TAILSCALE_IP" ]]; then
        show_error "Failed to get Tailscale IP"
        exit 1
    fi

    show_info "Tailscale connected: $TAILSCALE_IP"
}

#######################################
# Firewall Configuration for Tailscale
#######################################

configure_tailscale_firewall() {
    # Only configure if Tailscale is being used
    if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
        return 0
    fi

    # Check if UFW is available
    if ! command -v ufw &> /dev/null; then
        show_info "UFW not installed, skipping firewall configuration"
        return 0
    fi

    # Enable UFW if not active
    if ! ufw status | grep -q "Status: active"; then
        show_info "Enabling UFW firewall..."
        ufw --force enable
    fi

    show_info "Configuring firewall rules for Tailscale network (100.64.0.0/10)..."

    local tailscale_network="100.64.0.0/10"

    if [[ "$INSTALL_MODE" == "main" ]]; then
        # Main node: Allow Tailscale network to access Backend.AI services
        ufw allow from "$tailscale_network" to any port "${ETCD_PORT}" comment "Backend.AI etcd"
        ufw allow from "$tailscale_network" to any port "${REDIS_PORT}" comment "Backend.AI Redis"
        ufw allow from "$tailscale_network" to any port "${MANAGER_PORT}" comment "Backend.AI Manager"
        ufw allow from "$tailscale_network" to any port "${WEBSERVER_PORT}" comment "Backend.AI Webserver"
        ufw allow from "$tailscale_network" to any port "${STORAGE_PROXY_CLIENT_PORT}" comment "Backend.AI Storage-Proxy Client"
        ufw allow from "$tailscale_network" to any port "${STORAGE_PROXY_MANAGER_PORT}" comment "Backend.AI Storage-Proxy Manager"
        ufw allow from "$tailscale_network" to any port "${APPPROXY_COORDINATOR_PORT}" comment "Backend.AI App-Proxy Coordinator"
        ufw allow from "$tailscale_network" to any port "${APPPROXY_WORKER_PORT}" comment "Backend.AI App-Proxy Worker"
        ufw allow from "$tailscale_network" to any port 9000 comment "Backend.AI MinIO"

        # Allow Docker networks to access Manager (for Apollo Router GraphQL)
        # Docker uses 172.16.0.0/12 range for bridge networks (172.17.x default, 172.18.x+ for compose)
        ufw allow from 172.16.0.0/12 to any port "${MANAGER_PORT}" comment "Backend.AI Manager from Docker"

        # Block these ports from non-Tailscale networks (deny from anywhere else)
        # Note: UFW processes rules in order, so allow rules above take precedence
        show_info "Blocking Backend.AI service ports from non-Tailscale networks..."
        ufw deny from any to any port "${ETCD_PORT}" comment "Block etcd from non-Tailscale"
        ufw deny from any to any port "${REDIS_PORT}" comment "Block Redis from non-Tailscale"
    fi

    if [[ "$INSTALL_MODE" == "worker" ]]; then
        # Worker node: Allow Tailscale network to access agent ports
        ufw allow from "$tailscale_network" to any port "${AGENT_RPC_PORT}" comment "Backend.AI Agent RPC"
        ufw allow from "$tailscale_network" to any port "${AGENT_WATCHER_PORT}" comment "Backend.AI Agent Watcher"
        ufw allow from "$tailscale_network" to any port 6003 comment "Backend.AI Agent Service"
        # Container port range
        ufw allow from "$tailscale_network" to any port 30000:31000 proto tcp comment "Backend.AI Containers"
    fi

    # Always allow SSH
    ufw allow ssh comment "SSH"

    show_info "Firewall configured for Tailscale network"
    ufw status verbose | head -20
}

#######################################
# Phase 6.5: NFS Server Setup (Main Node)
#######################################

setup_nfs_server() {
    if [[ $NFS_ENABLED -eq 0 ]]; then
        show_info "NFS not enabled, skipping NFS server setup"
        return 0
    fi

    # Skip if using external NFS server
    if [[ -n "$NFS_SERVER" ]]; then
        show_info "Using external NFS server: $NFS_SERVER"
        return 0
    fi

    show_info "Setting up NFS server on main node..."

    # Install NFS server packages
    apt-get update
    apt-get install -y nfs-kernel-server nfs-common

    # Set default export path
    if [[ -z "$NFS_EXPORT_PATH" ]]; then
        NFS_EXPORT_PATH="${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"
    fi

    mkdir -p "$NFS_EXPORT_PATH"

    # Write version file
    if [[ ! -f "${NFS_EXPORT_PATH}/version.txt" ]]; then
        echo "3" > "${NFS_EXPORT_PATH}/version.txt"
    fi

    # Determine allowed network (Tailscale or local subnet)
    local allowed_network
    if [[ -n "$TAILSCALE_IP" ]]; then
        allowed_network="100.64.0.0/10"
    else
        local primary_ip
        primary_ip=$(get_local_ip)
        allowed_network="${primary_ip%.*}.0/24"
    fi

    # Configure NFS exports
    local export_opts="${NFS_EXPORT_OPTIONS}"

    # Remove existing entry if present
    sed -i "\|^${NFS_EXPORT_PATH}|d" /etc/exports 2>/dev/null || true

    echo "${NFS_EXPORT_PATH} ${allowed_network}(${export_opts})" >> /etc/exports

    # Export and start
    exportfs -ra
    systemctl enable nfs-kernel-server
    systemctl restart nfs-kernel-server

    # Configure firewall if UFW active
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow from "$allowed_network" to any port 2049 comment "NFS"
        ufw allow from "$allowed_network" to any port 111 comment "NFS portmapper"
    fi

    show_info "NFS server setup complete: ${LOCAL_IP}:${NFS_EXPORT_PATH}"
}

#######################################
# Phase 6.1: NFS Client Setup (Worker Node)
#######################################

setup_nfs_client() {
    if [[ $NFS_ENABLED -eq 0 ]]; then
        return 0
    fi

    show_info "Installing NFS client packages..."
    apt-get update
    apt-get install -y nfs-common
}

mount_nfs_storage() {
    if [[ $NFS_ENABLED -eq 0 ]]; then
        return 0
    fi

    show_info "Mounting NFS shared storage..."

    local nfs_server="${NFS_SERVER:-$MAIN_NODE_IP}"
    local nfs_export="${NFS_EXPORT_PATH:-${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}}"
    local mount_point="${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"

    mkdir -p "$mount_point"

    # Check if already mounted
    if mountpoint -q "$mount_point" 2>/dev/null; then
        show_info "NFS already mounted at $mount_point"
        return 0
    fi

    # Wait for NFS server with retry
    local max_attempts=10
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if showmount -e "$nfs_server" &>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        show_warning "Waiting for NFS server... ($attempt/$max_attempts)"
        sleep 5
    done

    if [[ $attempt -eq $max_attempts ]]; then
        show_error "Cannot reach NFS server at $nfs_server"
        exit 1
    fi

    # Mount NFS
    mount -t nfs -o "${NFS_MOUNT_OPTIONS}" "${nfs_server}:${nfs_export}" "$mount_point"

    if ! mountpoint -q "$mount_point"; then
        show_error "Failed to mount NFS storage"
        exit 1
    fi

    # Add to fstab for persistence
    local fstab_entry="${nfs_server}:${nfs_export} ${mount_point} nfs ${NFS_MOUNT_OPTIONS} 0 0"
    sed -i "\|${mount_point}|d" /etc/fstab 2>/dev/null || true
    echo "$fstab_entry" >> /etc/fstab

    show_info "NFS storage mounted successfully"
}

#######################################
# Phase 3: GPU Runtime Setup
#######################################

# CUDA Toolkit version mapping based on driver version
# Reference: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/index.html
# Format: "min_driver_version:cuda_toolkit_package"
# Order matters: check from newest to oldest
CUDA_DRIVER_MAP=(
    "590.48:cuda-toolkit-13-1"
    "590.44:cuda-toolkit-13-1"
    "580.65:cuda-toolkit-13-0"
    "575.51:cuda-toolkit-12-9"
    "570.26:cuda-toolkit-12-8"
    "560.28:cuda-toolkit-12-6"
    "555.42:cuda-toolkit-12-5"
    "550.54:cuda-toolkit-12-4"
    "545.23:cuda-toolkit-12-3"
    "535.54:cuda-toolkit-12-2"
    "530.30:cuda-toolkit-12-1"
    "525.60:cuda-toolkit-12-0"
    "520.61:cuda-toolkit-11-8"
    "515.43:cuda-toolkit-11-7"
    "510.39:cuda-toolkit-11-6"
    "495.29:cuda-toolkit-11-5"
    "470.42:cuda-toolkit-11-4"
    "465.19:cuda-toolkit-11-3"
    "460.27:cuda-toolkit-11-2"
    "455.23:cuda-toolkit-11-1"
    "450.51:cuda-toolkit-11-0"
    "440.33:cuda-toolkit-10-2"
    "418.39:cuda-toolkit-10-1"
    "410.48:cuda-toolkit-10-0"
)

# Compare version strings (returns 0 if v1 >= v2)
version_ge() {
    local v1="$1"
    local v2="$2"
    # Use sort -V for version comparison
    [ "$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}

# Get the appropriate CUDA toolkit package for the installed driver
get_cuda_toolkit_for_driver() {
    local driver_version="$1"

    # Extract major.minor from driver version (e.g., 590.48 from 590.48.01)
    local driver_major_minor
    driver_major_minor=$(echo "$driver_version" | cut -d'.' -f1,2)

    for entry in "${CUDA_DRIVER_MAP[@]}"; do
        local min_driver="${entry%%:*}"
        local cuda_pkg="${entry##*:}"

        if version_ge "$driver_major_minor" "$min_driver"; then
            echo "$cuda_pkg"
            return 0
        fi
    done

    # Fallback to oldest supported toolkit
    echo "cuda-toolkit-10-0"
    return 1
}

install_cuda_toolkit() {
    if [[ $SKIP_GPU_SETUP -eq 1 ]]; then
        show_info "Skipping CUDA toolkit installation (--skip-gpu-setup)"
        return 0
    fi

    show_info "Installing CUDA toolkit..."

    # Check if CUDA runtime library is already available
    if ldconfig -p | grep -q libcudart; then
        local existing_version
        existing_version=$(ldconfig -p | grep libcudart | head -1 | sed 's/.*libcudart\.so\.\([0-9]*\).*/\1/')
        show_info "CUDA runtime library already installed (version $existing_version)"
        return 0
    fi

    # Get NVIDIA driver version
    if ! command -v nvidia-smi &> /dev/null; then
        show_error "nvidia-smi not found. Cannot determine driver version."
        return 1
    fi

    local driver_version
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    show_info "Detected NVIDIA driver version: $driver_version"

    # Determine the appropriate CUDA toolkit
    local cuda_package
    cuda_package=$(get_cuda_toolkit_for_driver "$driver_version")
    show_info "Selected CUDA toolkit package: $cuda_package"

    # Add NVIDIA CUDA repository if not already added
    if [[ ! -f /etc/apt/sources.list.d/cuda-*.list ]] && [[ ! -f /usr/share/keyrings/cuda-archive-keyring.gpg ]]; then
        show_info "Adding NVIDIA CUDA repository..."

        # Determine Ubuntu codename for repository
        local ubuntu_version
        ubuntu_version=$(lsb_release -rs)
        local repo_version
        case "$ubuntu_version" in
            22.04) repo_version="ubuntu2204" ;;
            24.04) repo_version="ubuntu2404" ;;
            *)
                show_warning "Ubuntu $ubuntu_version may not have official CUDA repository, trying ubuntu2204"
                repo_version="ubuntu2204"
                ;;
        esac

        # Download and install the CUDA keyring package
        local keyring_url="https://developer.download.nvidia.com/compute/cuda/repos/${repo_version}/x86_64/cuda-keyring_1.1-1_all.deb"
        local keyring_deb="/tmp/cuda-keyring.deb"

        if wget -q -O "$keyring_deb" "$keyring_url"; then
            dpkg -i "$keyring_deb"
            rm -f "$keyring_deb"
        else
            show_error "Failed to download CUDA keyring package"
            return 1
        fi

        apt-get update
    fi

    # Install the CUDA toolkit
    show_info "Installing $cuda_package (this may take a while)..."
    if ! apt-get install -y "$cuda_package"; then
        show_error "Failed to install $cuda_package"
        return 1
    fi

    # Configure library paths
    show_info "Configuring CUDA library paths..."

    # Add CUDA library path to ldconfig
    if [[ ! -f /etc/ld.so.conf.d/cuda.conf ]]; then
        cat > /etc/ld.so.conf.d/cuda.conf << 'EOF'
/usr/local/cuda/lib64
/usr/local/cuda/extras/CUPTI/lib64
EOF
    fi

    # Update library cache
    ldconfig

    # Add CUDA to PATH for current session
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"

    # Create profile.d script for persistence
    cat > /etc/profile.d/cuda.sh << 'EOF'
export PATH="/usr/local/cuda/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
EOF

    # Verify installation
    if ldconfig -p | grep -q libcudart; then
        local installed_version
        installed_version=$(ldconfig -p | grep libcudart | head -1)
        show_info "CUDA toolkit installed successfully: $installed_version"
    else
        show_warning "CUDA toolkit installed but libcudart not found in ldconfig"
        show_warning "You may need to reboot or manually run 'sudo ldconfig'"
    fi

    # Show nvcc version if available
    if command -v nvcc &> /dev/null; then
        show_info "NVCC version: $(nvcc --version | grep release | awk '{print $6}' | cut -d',' -f1)"
    fi
}

install_nvidia_container_toolkit() {
    if [[ $SKIP_GPU_SETUP -eq 1 ]]; then
        show_info "Skipping nvidia-container-toolkit installation (--skip-gpu-setup)"
        return 0
    fi

    show_info "Installing nvidia-container-toolkit..."

    # Check if already installed
    if command -v nvidia-container-toolkit &> /dev/null; then
        show_info "nvidia-container-toolkit already installed"
    else
        # Add NVIDIA Container Toolkit repository
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

        apt-get update
        apt-get install -y nvidia-container-toolkit
    fi

    # Configure Docker to use NVIDIA runtime
    nvidia-ctk runtime configure --runtime=docker --set-as-default

    # Restart Docker to apply changes
    systemctl restart docker

    show_info "nvidia-container-toolkit configured"
}

verify_gpu_docker() {
    show_info "Verifying GPU access in Docker..."

    if docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
        show_info "GPU access in Docker verified - OK"
    else
        show_warning "GPU access verification failed. You may need to restart and re-run verification."
    fi
}

#######################################
# Phase 4: Python Environment
#######################################

install_uv() {
    show_info "Installing uv package manager..."

    if command -v uv &> /dev/null; then
        show_info "uv already installed: $(uv --version)"
    else
        curl -LsSf https://astral.sh/uv/install.sh | sh

        # Source the environment
        if [[ -f "$HOME/.local/bin/env" ]]; then
            source "$HOME/.local/bin/env"
        fi

        # Add to PATH for current session
        export PATH="$HOME/.local/bin:$PATH"
    fi
}

install_pyenv() {
    show_info "Installing pyenv for Python version management..."

    # Set up pyenv environment variables first
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"

    # Check if pyenv is already installed (either in PATH or in ~/.pyenv)
    if command -v pyenv &> /dev/null; then
        show_info "pyenv already installed: $(pyenv --version)"
    elif [[ -d "$HOME/.pyenv" ]] && [[ -x "$HOME/.pyenv/bin/pyenv" ]]; then
        # pyenv directory exists but not in PATH - just initialize it
        show_info "Found existing pyenv installation at $HOME/.pyenv"
        eval "$(pyenv init -)"
        show_info "pyenv initialized: $(pyenv --version)"
    else
        # Fresh installation needed
        # Install pyenv dependencies
        apt-get update
        apt-get install -y \
            build-essential \
            libssl-dev \
            zlib1g-dev \
            libbz2-dev \
            libreadline-dev \
            libsqlite3-dev \
            libncursesw5-dev \
            xz-utils \
            tk-dev \
            libxml2-dev \
            libxmlsec1-dev \
            libffi-dev \
            liblzma-dev

        # Install pyenv
        curl https://pyenv.run | bash

        # Initialize pyenv
        eval "$(pyenv init -)"
    fi

    # Add to shell profile for persistence (idempotent)
    cat > /etc/profile.d/pyenv.sh << 'EOF'
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF

    # Final verification
    if ! command -v pyenv &> /dev/null; then
        show_error "pyenv installation failed - command not found"
        exit 1
    fi

    show_info "pyenv setup complete: $(pyenv --version)"
}

install_required_python() {
    show_info "Installing required Python version via pyenv..."

    cd "$INSTALL_PATH/backend.ai"

    # Get the Python version from pants.toml
    # Use sed instead of grep -oP for portability (grep -P requires PCRE which isn't always available)
    PYTHON_VERSION=$(grep 'CPython==' pants.toml 2>/dev/null | head -1 | sed 's/.*CPython==\([0-9.]*\).*/\1/')

    # If extraction failed or is empty, try alternative method
    if [[ -z "$PYTHON_VERSION" ]]; then
        PYTHON_VERSION=$(./scripts/pyscript.sh scripts/tomltool.py -f pants.toml get 'python.interpreter_constraints[0]' 2>/dev/null | sed 's/.*==\([0-9.]*\).*/\1/' || echo "")
    fi

    # Default to 3.12.0 if still empty
    if [[ -z "$PYTHON_VERSION" ]]; then
        PYTHON_VERSION="3.12.0"
        show_warning "Could not detect Python version from pants.toml, defaulting to $PYTHON_VERSION"
    fi

    show_info "Required Python version: $PYTHON_VERSION"

    # Check if already installed via pyenv
    if pyenv versions --bare | grep -q "^${PYTHON_VERSION}$"; then
        show_info "Python $PYTHON_VERSION already installed via pyenv"
    else
        show_info "Installing Python $PYTHON_VERSION via pyenv (this may take a while)..."
        pyenv install "$PYTHON_VERSION"
    fi

    # Set as global default so pants can find it
    pyenv global "$PYTHON_VERSION"

    # Rehash to update shims
    pyenv rehash

    # Verify installation
    local installed_version
    installed_version=$("$PYENV_ROOT/shims/python" --version 2>&1 | awk '{print $2}')
    show_info "Active Python version: $installed_version"
}

setup_python() {
    show_info "Setting up Python environment..."

    # Create installation directory first
    mkdir -p "$INSTALL_PATH"

    # Install pyenv for Python version management
    install_pyenv

    show_info "Python environment will be finalized after cloning the repository"
}

#######################################
# Phase 5: Backend.AI Installation
#######################################

clone_repository() {
    show_info "Cloning Backend.AI repository..."

    cd "$INSTALL_PATH"

    if [[ -d "$INSTALL_PATH/backend.ai" ]]; then
        show_info "Repository already exists, updating..."
        cd "$INSTALL_PATH/backend.ai"
        git fetch origin
        git checkout "$GIT_BRANCH"
        git pull origin "$GIT_BRANCH"
    else
        git clone --branch "$GIT_BRANCH" "$GIT_REPO" "$INSTALL_PATH/backend.ai"
        cd "$INSTALL_PATH/backend.ai"
    fi

    # Pull LFS files
    git lfs pull

    # Create NVIDIA NGC (nvcr.io) container registry fixture
    show_info "Creating NVIDIA NGC registry fixture..."
    cat > "${INSTALL_PATH}/backend.ai/fixtures/manager/example-container-registries-nvcr.json" << 'NVCR_EOF'
{
    "container_registries": [
        {
            "id": "a1b2c3d4-5678-90ab-cdef-1234567890ab",
            "registry_name": "nvcr.io",
            "url": "https://nvcr.io",
            "type": "docker",
            "project": "nvidia"
        }
    ]
}
NVCR_EOF

    show_info "Repository ready at $INSTALL_PATH/backend.ai"
}

install_pants() {
    show_info "Installing Pants build system..."

    cd "$INSTALL_PATH/backend.ai"

    if command -v pants &> /dev/null; then
        show_info "Pants already installed"
    else
        curl --proto '=https' --tlsv1.2 -fsSL https://static.pantsbuild.org/setup/get-pants.sh | bash

        # Add to PATH
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Verify pants works
    pants version
    show_info "Pants installed: $(pants version)"
}

export_python_dependencies() {
    show_info "Exporting Python dependencies via Pants..."

    cd "$INSTALL_PATH/backend.ai"

    # Install required Python version via pyenv
    install_required_python

    # PYTHON_VERSION is now set by install_required_python
    show_info "Target Python version: $PYTHON_VERSION"

    # Configure pants local execution root
    local pants_local_exec_root="/tmp/pants-cache"
    mkdir -p "$pants_local_exec_root"
    if [[ -f .pants.rc ]]; then
        ./scripts/pyscript.sh scripts/tomltool.py -f .pants.rc set 'GLOBAL.local_execution_root_dir' "$pants_local_exec_root" 2>/dev/null || true
    fi

    # Export the main resolve - this creates the virtualenv
    show_info "Running pants export (this may download and compile packages)..."
    pants export --resolve=python-default

    # The exported virtualenv is in dist/export/python/virtualenvs/python-default/<version>/
    # We need to find the actual virtualenv directory (contains bin/activate)
    local venv_base="$INSTALL_PATH/backend.ai/dist/export/python/virtualenvs/python-default"
    local venv_path=""

    # Look for the versioned subdirectory containing bin/activate
    # Depth: python-default(0) / 3.13.7(1) / bin(2) / activate(3) - need maxdepth 3
    if [[ -d "$venv_base" ]]; then
        # Find the virtualenv with bin/activate (usually python-default/<version>/)
        venv_path=$(find "$venv_base" -maxdepth 3 -name "activate" -path "*/bin/activate" 2>/dev/null | head -1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)
    fi

    # If not found, try looking for any virtualenv with bin/activate under virtualenvs/
    if [[ -z "$venv_path" ]] || [[ ! -d "$venv_path" ]]; then
        venv_path=$(find "$INSTALL_PATH/backend.ai/dist/export/python/virtualenvs" -maxdepth 4 -name "activate" -path "*/bin/activate" 2>/dev/null | head -1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)
    fi

    if [[ -n "$venv_path" ]] && [[ -d "$venv_path" ]]; then
        show_info "Virtual environment exported to $venv_path"
        # Create a symlink for easier access
        # Use -n to not follow existing symlink, -f to force overwrite
        rm -f "$INSTALL_PATH/.venv" 2>/dev/null || true
        ln -sfn "$venv_path" "$INSTALL_PATH/.venv"
    else
        show_error "Could not find exported virtualenv with bin/activate"
        show_error "Expected structure: dist/export/python/virtualenvs/python-default/<version>/bin/activate"
        exit 1
    fi

    # Verify the symlink works
    if [[ ! -f "$INSTALL_PATH/.venv/bin/activate" ]]; then
        show_error "Virtualenv symlink created but bin/activate not found"
        exit 1
    fi

    show_info "Python dependencies exported"
}

#######################################
# Phase 6: Halfstack Services (Main Node Only)
#######################################

setup_halfstack() {
    show_info "Setting up halfstack services..."

    cd "$INSTALL_PATH/backend.ai"

    # Create volume directories
    mkdir -p volumes/postgres-data
    mkdir -p volumes/redis-data
    mkdir -p volumes/etcd-data

    # Copy and customize docker-compose file
    cp docker-compose.halfstack-main.yml docker-compose.halfstack.current.yml

    # Copy supporting files
    cp configs/prometheus/prometheus.yaml prometheus.yaml
    cp -r configs/grafana/dashboards grafana-dashboards
    cp -r configs/grafana/provisioning grafana-provisioning
    cp configs/otel/otel-collector-config.yaml otel-collector-config.yaml
    cp configs/loki/loki-config.yaml loki-config.yaml
    cp configs/tempo/tempo-config.yaml tempo-config.yaml

    # Generate GraphQL schema if script exists
    # APOLLO_ELV2_LICENSE=accept is required for non-interactive rover supergraph compose
    if [[ -x scripts/generate-graphql-schema.sh ]]; then
        APOLLO_ELV2_LICENSE=accept ./scripts/generate-graphql-schema.sh || true
    fi
    cp configs/graphql/gateway.config.ts gateway.config.ts 2>/dev/null || true
    cp docs/manager/graphql-reference/supergraph.graphql supergraph.graphql 2>/dev/null || true

    # Update ports in compose file
    sed -i "s/8100:5432/${POSTGRES_PORT}:5432/" docker-compose.halfstack.current.yml
    sed -i "s/8110:6379/${REDIS_PORT}:6379/" docker-compose.halfstack.current.yml
    sed -i "s/8120:2379/${ETCD_PORT}:2379/" docker-compose.halfstack.current.yml

    # If using system Redis, disable Docker Redis to avoid port conflict
    if [[ $USE_SYSTEM_REDIS -eq 1 ]]; then
        show_info "Disabling Docker Redis (using system Valkey/Redis instead)..."
        # Comment out the redis service and redis-exporter (depends on redis)
        sed -i '/^\s*backendai-half-redis:/,/^\s*[a-z].*:$/{ /^\s*[a-z].*:$/!s/^/#/ }' docker-compose.halfstack.current.yml
        sed -i '/^\s*redis-exporter:/,/^\s*[a-z].*:$/{ /^\s*[a-z].*:$/!s/^/#/ }' docker-compose.halfstack.current.yml
        # Also update redis-exporter command to use localhost
        sed -i "s|redis://backendai-half-redis:6379|redis://localhost:${REDIS_PORT}|g" docker-compose.halfstack.current.yml
    fi

    # Pull halfstack images
    show_info "Pulling halfstack Docker images..."
    docker compose -f docker-compose.halfstack.current.yml pull

    show_info "Halfstack setup complete"
}

start_halfstack() {
    show_info "Starting halfstack services..."

    cd "$INSTALL_PATH/backend.ai"

    docker compose -f docker-compose.halfstack.current.yml up -d --wait

    # Verify services are running
    docker compose -f docker-compose.halfstack.current.yml ps

    show_info "Halfstack services started"
}

configure_minio() {
    show_info "Configuring MinIO..."

    cd "$INSTALL_PATH/backend.ai"

    # Source the MinIO configuration script
    if [[ -f scripts/configure-minio.sh ]]; then
        source scripts/configure-minio.sh
        configure_minio "docker-compose.halfstack.current.yml" || true
    else
        # Fallback to default credentials
        export MINIO_ACCESS_KEY="minioadmin"
        export MINIO_SECRET_KEY="minioadmin"
    fi

    show_info "MinIO configured"
}

#######################################
# Phase 7: Service Configuration
#######################################

generate_secrets() {
    # Generate random secrets for various services
    MANAGER_AUTH_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    STORAGE_PROXY_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    APPPROXY_API_SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    APPPROXY_JWT_SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
    APPPROXY_PERMIT_HASH_SECRET=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')
}

configure_manager() {
    show_info "Generating manager configuration..."

    cd "$INSTALL_PATH/backend.ai"

    # Copy halfstack config as base
    cp configs/manager/halfstack.toml manager.toml

    # Update configuration
    sed -i "s/num-proc = .*/num-proc = $(nproc)/" manager.toml
    sed -i "s/port = 8120/port = ${ETCD_PORT}/" manager.toml
    sed -i "s/port = 8100/port = ${POSTGRES_PORT}/" manager.toml
    sed -i "s/port = 8081/port = ${MANAGER_PORT}/" manager.toml
    sed -i "s@# ipc-base-path = .*@ipc-base-path = \"${IPC_BASE_PATH}\"@" manager.toml

    # Bind to 0.0.0.0 for external access (multi-node support)
    # The service-addr should already be 0.0.0.0 in halfstack.toml, but ensure it
    sed -i 's/service-addr = { host = "127.0.0.1"/service-addr = { host = "0.0.0.0"/' manager.toml

    # Copy alembic config
    cp configs/manager/halfstack.alembic.ini alembic.ini
    sed -i "s/localhost:8100/localhost:${POSTGRES_PORT}/" alembic.ini

    show_info "Manager configuration generated"
}

configure_agent() {
    show_info "Generating agent configuration..."

    cd "$INSTALL_PATH/backend.ai"

    # Copy halfstack config as base
    cp configs/agent/halfstack.toml agent.toml

    # Update configuration for GPU support
    sed -i "s/port = 8120/port = ${ETCD_PORT}/" agent.toml
    sed -i "s/port = 6001/port = ${AGENT_RPC_PORT}/" agent.toml
    sed -i "s/port = 6009/port = ${AGENT_WATCHER_PORT}/" agent.toml
    sed -i "s@# ipc-base-path = .*@ipc-base-path = \"${IPC_BASE_PATH}\"@" agent.toml
    sed -i "s@var-base-path = .*@var-base-path = \"${VAR_BASE_PATH}\"@" agent.toml
    sed -i "s@mount-path = .*@mount-path = \"${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}\"@" agent.toml

    # Enable CUDA plugin
    sed -i 's/# allow-compute-plugins =.*/allow-compute-plugins = ["ai.backend.accelerator.cuda_open"]/' agent.toml

    # Update container binding to allow external access
    sed -i 's/bind-host = "127.0.0.1"/bind-host = "0.0.0.0"/' agent.toml

    # For main node, bind RPC to 0.0.0.0 for external access if needed
    sed -i 's/rpc-listen-addr = { host = "127.0.0.1"/rpc-listen-addr = { host = "0.0.0.0"/' agent.toml

    # Set advertised-rpc-addr for main node (manager is local, use 127.0.0.1)
    if ! grep -q "^advertised-rpc-addr" agent.toml; then
        sed -i "/rpc-listen-addr = /a advertised-rpc-addr = { host = \"127.0.0.1\", port = ${AGENT_RPC_PORT} }" agent.toml
    else
        sed -i "s/.*advertised-rpc-addr = .*/advertised-rpc-addr = { host = \"127.0.0.1\", port = ${AGENT_RPC_PORT} }/" agent.toml
    fi

    # Create necessary directories
    mkdir -p "$VAR_BASE_PATH"
    mkdir -p "${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"
    mkdir -p "${INSTALL_PATH}/backend.ai/scratches"

    show_info "Agent configuration generated"
}

configure_worker_agent() {
    show_info "Configuring agent for worker node..."

    cd "$INSTALL_PATH/backend.ai"

    # Copy halfstack config as base
    cp configs/agent/halfstack.toml agent.toml

    # Point to main node's etcd
    sed -i "s/host = \"127.0.0.1\", port = 8120/host = \"${MAIN_NODE_IP}\", port = ${ETCD_PORT}/" agent.toml

    # Configure agent RPC to listen on all interfaces
    sed -i "s/rpc-listen-addr = { host = \"127.0.0.1\", port = 6001 }/rpc-listen-addr = { host = \"0.0.0.0\", port = ${AGENT_RPC_PORT} }/" agent.toml

    # Set advertised-rpc-addr for worker node (use LOCAL_IP which is Tailscale IP if enabled)
    if ! grep -q "^advertised-rpc-addr" agent.toml; then
        sed -i "/rpc-listen-addr = /a advertised-rpc-addr = { host = \"${LOCAL_IP}\", port = ${AGENT_RPC_PORT} }" agent.toml
    else
        sed -i "s/.*advertised-rpc-addr = .*/advertised-rpc-addr = { host = \"${LOCAL_IP}\", port = ${AGENT_RPC_PORT} }/" agent.toml
    fi

    # Configure service-addr to listen on all interfaces
    sed -i "s/service-addr = { host = \"0.0.0.0\", port = 6003 }/service-addr = { host = \"0.0.0.0\", port = 6003 }/" agent.toml

    # Add announce-internal-addr for this node's IP (containers need to reach agent)
    # Check if announce-internal-addr exists, if not add it after service-addr
    if ! grep -q "announce-internal-addr" agent.toml; then
        sed -i "/service-addr = /a announce-internal-addr = { host = \"${LOCAL_IP}\", port = 6003 }" agent.toml
    else
        sed -i "s/announce-internal-addr = .*/announce-internal-addr = { host = \"${LOCAL_IP}\", port = 6003 }/" agent.toml
    fi

    # Update paths
    sed -i "s@# ipc-base-path = .*@ipc-base-path = \"${IPC_BASE_PATH}\"@" agent.toml
    sed -i "s@var-base-path = .*@var-base-path = \"${VAR_BASE_PATH}\"@" agent.toml
    sed -i "s@mount-path = .*@mount-path = \"${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}\"@" agent.toml

    # Enable CUDA plugin
    sed -i 's/# allow-compute-plugins =.*/allow-compute-plugins = ["ai.backend.accelerator.cuda_open"]/' agent.toml

    # Update container binding to allow external access
    sed -i 's/bind-host = "127.0.0.1"/bind-host = "0.0.0.0"/' agent.toml

    # Set cohabiting-storage-proxy to false (storage proxy is on main node)
    sed -i 's/cohabiting-storage-proxy = true/cohabiting-storage-proxy = false/' agent.toml

    # Point OpenTelemetry and Pyroscope to main node (collectors run there)
    sed -i "s|endpoint = \"http://127.0.0.1:4317\"|endpoint = \"http://${MAIN_NODE_IP}:4317\"|" agent.toml
    sed -i "s|server-addr = \"http://localhost:4040\"|server-addr = \"http://${MAIN_NODE_IP}:4040\"|" agent.toml

    # Create necessary directories
    mkdir -p "$VAR_BASE_PATH"
    mkdir -p "${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"
    mkdir -p "${INSTALL_PATH}/backend.ai/scratches"
    mkdir -p "${IPC_BASE_PATH}"

    show_info "Worker agent configuration generated"
    show_info "Agent will connect to etcd at ${MAIN_NODE_IP}:${ETCD_PORT}"
    show_info "Agent will announce internal address as ${LOCAL_IP}:6003"
}

configure_storage_proxy() {
    show_info "Generating storage-proxy configuration..."

    cd "$INSTALL_PATH/backend.ai"

    # Copy halfstack config as base
    cp configs/storage-proxy/halfstack.toml storage-proxy.toml

    # Update configuration
    sed -i "s/port = 2379/port = ${ETCD_PORT}/" storage-proxy.toml
    sed -i "s/secret = \"some-secret-private-for-storage-proxy\"/secret = \"${STORAGE_PROXY_SECRET}\"/" storage-proxy.toml
    sed -i "s/secret = \"some-secret-shared-with-manager\"/secret = \"${MANAGER_AUTH_KEY}\"/" storage-proxy.toml
    sed -i "s@# ipc-base-path = .*@ipc-base-path = \"${IPC_BASE_PATH}\"@" storage-proxy.toml

    # Bind to 0.0.0.0 for external access (multi-node support)
    # Client API is already 0.0.0.0 in halfstack, but ensure it
    sed -i 's/service-addr = { host = "127.0.0.1"/service-addr = { host = "0.0.0.0"/' storage-proxy.toml

    # Comment out sample volumes and add our volume
    sed -i 's/^\[volume\./# [volume./' storage-proxy.toml
    sed -i 's/^backend =/# backend =/' storage-proxy.toml
    sed -i 's/^path =/# path =/' storage-proxy.toml

    # Add VFS volume configuration
    cat >> storage-proxy.toml << EOF

[volume.${LOCAL_STORAGE_VOLUME}]
backend = "vfs"
path = "${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"
EOF

    # Configure MinIO if credentials are available
    if [[ -n "$MINIO_ACCESS_KEY" ]] && [[ -n "$MINIO_SECRET_KEY" ]]; then
        sed -i "s/buckets = \[\"enter_bucket_name\"\]/buckets = [\"backendai-storage\"]/" storage-proxy.toml
        sed -i 's#endpoint = "http://minio.example.com:9000"#endpoint = "http://127.0.0.1:9000"#' storage-proxy.toml
        sed -i "s/access-key = \"<minio-access-key>\"/access-key = \"${MINIO_ACCESS_KEY}\"/" storage-proxy.toml
        sed -i "s/secret-key = \"<minio-secret-key>\"/secret-key = \"${MINIO_SECRET_KEY}\"/" storage-proxy.toml
    fi

    show_info "Storage-proxy configuration generated"
}

configure_webserver() {
    show_info "Generating webserver configuration..."

    cd "$INSTALL_PATH/backend.ai"

    # Copy sample config as base
    cp configs/webserver/halfstack.conf webserver.conf

    # Update configuration
    sed -i "s@endpoint = \"https://api.backend.ai\"@endpoint = \"http://127.0.0.1:${MANAGER_PORT}\"@" webserver.conf
    # Update Redis address in [session.redis] section (halfstack.conf uses 'addr = "localhost:8111"')
    sed -i "s/addr = \"localhost:8111\"/addr = \"localhost:${REDIS_PORT}\"/" webserver.conf
    sed -i "s/port = 8080/port = ${WEBSERVER_PORT}/" webserver.conf

    show_info "Webserver configuration generated"
}

configure_appproxy() {
    show_info "Generating app-proxy configurations..."

    cd "$INSTALL_PATH/backend.ai"

    # Coordinator config
    cp configs/app-proxy-coordinator/halfstack.toml app-proxy-coordinator.toml
    sed -i "s/port = 8100/port = ${POSTGRES_PORT}/" app-proxy-coordinator.toml
    sed -i "s/port = 8110/port = ${REDIS_PORT}/" app-proxy-coordinator.toml
    sed -i "s/port = 10200/port = ${APPPROXY_COORDINATOR_PORT}/" app-proxy-coordinator.toml
    sed -i "s/api_secret = \"some_api_secret\"/api_secret = \"${APPPROXY_API_SECRET}\"/" app-proxy-coordinator.toml
    sed -i "s/jwt_secret = \"some_jwt_secret\"/jwt_secret = \"${APPPROXY_JWT_SECRET}\"/" app-proxy-coordinator.toml
    sed -i "s/secret = \"some_permit_hash_secret\"/secret = \"${APPPROXY_PERMIT_HASH_SECRET}\"/" app-proxy-coordinator.toml

    # Copy alembic config for app-proxy
    cp configs/app-proxy-coordinator/halfstack.alembic.ini alembic-appproxy.ini
    sed -i "s/localhost:8100/localhost:${POSTGRES_PORT}/" alembic-appproxy.ini

    # Worker config
    cp configs/app-proxy-worker/halfstack.toml app-proxy-worker.toml
    sed -i "s/port = 8110/port = ${REDIS_PORT}/" app-proxy-worker.toml
    sed -i "s/port = 10201/port = ${APPPROXY_WORKER_PORT}/" app-proxy-worker.toml
    sed -i "s/api_secret = \"some_api_secret\"/api_secret = \"${APPPROXY_API_SECRET}\"/" app-proxy-worker.toml
    sed -i "s/jwt_secret = \"some_jwt_secret\"/jwt_secret = \"${APPPROXY_JWT_SECRET}\"/" app-proxy-worker.toml
    sed -i "s/secret = \"some_permit_hash_secret\"/secret = \"${APPPROXY_PERMIT_HASH_SECRET}\"/" app-proxy-worker.toml

    show_info "App-proxy configurations generated"
}

#######################################
# Phase 8: Database Initialization
#######################################

initialize_database() {
    show_info "Initializing database..."

    cd "$INSTALL_PATH/backend.ai"

    # Ensure we're using the correct Python environment
    export PATH="$INSTALL_PATH/.venv/bin:$PATH"

    # Wait for PostgreSQL to be fully ready
    show_info "Waiting for PostgreSQL to be ready..."
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if docker compose -f docker-compose.halfstack.current.yml exec -T backendai-half-db pg_isready -U postgres &> /dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        echo "Waiting for PostgreSQL... ($attempt/$max_attempts)"
        sleep 2
    done

    if [[ $attempt -eq $max_attempts ]]; then
        show_error "PostgreSQL did not become ready"
        exit 1
    fi

    # Configure Redis in etcd (use LOCAL_IP so workers can reach it)
    show_info "Configuring etcd..."
    ./backend.ai mgr etcd put config/redis/addr "${LOCAL_IP}:${REDIS_PORT}"
    ./backend.ai mgr etcd put-json config/redis/redis_helper_config ./configs/manager/sample.etcd.redis-helper.json

    # Run database migrations
    show_info "Running database migrations..."
    ./backend.ai mgr schema oneshot

    # Populate fixtures
    show_info "Populating database fixtures..."
    ./backend.ai mgr fixture populate fixtures/manager/example-container-registries-harbor.json || show_warning "Container registries fixture may already exist"
    ./backend.ai mgr fixture populate fixtures/manager/example-container-registries-nvcr.json || show_warning "NVIDIA NGC registry fixture may already exist"
    ./backend.ai mgr fixture populate fixtures/manager/example-users.json || show_warning "Users fixture may already exist"
    ./backend.ai mgr fixture populate fixtures/manager/example-keypairs.json || show_warning "Keypairs fixture may already exist"
    ./backend.ai mgr fixture populate fixtures/manager/example-set-user-main-access-keys.json || show_warning "Access keys fixture may already exist"
    ./backend.ai mgr fixture populate fixtures/manager/example-resource-presets.json || show_warning "Resource presets fixture may already exist"
    ./backend.ai mgr fixture populate fixtures/manager/example-roles.json || show_warning "Roles fixture may already exist"

    # Configure volume settings (use LOCAL_IP so workers can reach storage-proxy)
    show_info "Configuring storage volumes..."
    cp configs/manager/sample.etcd.volumes.json dev.etcd.volumes.json
    sed -i "s/\"secret\": \"some-secret-shared-with-storage-proxy\"/\"secret\": \"${MANAGER_AUTH_KEY}\"/" dev.etcd.volumes.json
    sed -i "s/\"default_host\": .*$/\"default_host\": \"${LOCAL_STORAGE_PROXY}:${LOCAL_STORAGE_VOLUME}\",/" dev.etcd.volumes.json
    sed -i "s|http://127.0.0.1:6021|http://${LOCAL_IP}:${STORAGE_PROXY_CLIENT_PORT}|" dev.etcd.volumes.json
    sed -i "s|https://127.0.0.1:6022|https://${LOCAL_IP}:${STORAGE_PROXY_MANAGER_PORT}|" dev.etcd.volumes.json
    ./backend.ai mgr etcd put-json volumes dev.etcd.volumes.json

    show_info "Database initialized"
}

initialize_appproxy_database() {
    show_info "Initializing app-proxy database..."

    cd "$INSTALL_PATH/backend.ai"

    # Get PostgreSQL container name/ID - handle different naming conventions
    local POSTGRES_CONTAINER
    POSTGRES_CONTAINER=$(docker compose -f docker-compose.halfstack.current.yml ps --format '{{.Name}}' 2>/dev/null | grep -E "(db|postgres)" | head -1)
    if [[ -z "$POSTGRES_CONTAINER" ]]; then
        POSTGRES_CONTAINER=$(docker compose -f docker-compose.halfstack.current.yml ps -q 2>/dev/null | head -1)
    fi

    if [[ -z "$POSTGRES_CONTAINER" ]]; then
        show_error "Could not find PostgreSQL container"
        exit 1
    fi

    show_info "Using PostgreSQL container: $POSTGRES_CONTAINER"

    # Create appproxy role and database
    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -d backend -q -c "
        DO \$\$
        BEGIN
           IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'appproxy') THEN
              CREATE ROLE appproxy WITH LOGIN PASSWORD 'develove';
           ELSE
              ALTER ROLE appproxy WITH LOGIN PASSWORD 'develove';
           END IF;
        END
        \$\$;"

    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'appproxy'" | grep -q 1 || \
        docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -c "CREATE DATABASE appproxy"

    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE appproxy TO appproxy;"
    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -d appproxy -c "GRANT ALL ON SCHEMA public TO appproxy;"

    # Run app-proxy migrations
    export PATH="$INSTALL_PATH/.venv/bin:$PATH"
    ./py -m alembic -c alembic-appproxy.ini upgrade head

    # Update scaling group with app-proxy settings
    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -d backend -c "
        UPDATE scaling_groups SET
        wsproxy_api_token = '${APPPROXY_API_SECRET}',
        wsproxy_addr = 'http://localhost:${APPPROXY_COORDINATOR_PORT}'
        WHERE name = 'default';"

    show_info "App-proxy database initialized"
}

setup_vfolders() {
    show_info "Setting up virtual folders..."

    cd "$INSTALL_PATH/backend.ai"

    # Create vfolder directory
    mkdir -p "${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"

    # Write version file
    echo "3" > "${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}/version.txt"

    # Get PostgreSQL container name/ID
    local POSTGRES_CONTAINER
    POSTGRES_CONTAINER=$(docker compose -f docker-compose.halfstack.current.yml ps --format '{{.Name}}' 2>/dev/null | grep -E "(db|postgres)" | head -1)
    if [[ -z "$POSTGRES_CONTAINER" ]]; then
        POSTGRES_CONTAINER=$(docker compose -f docker-compose.halfstack.current.yml ps -q 2>/dev/null | head -1)
    fi

    # Update vfolder hosts
    ALL_VFOLDER_HOST_PERM='["create-vfolder","modify-vfolder","delete-vfolder","mount-in-session","upload-file","download-file","invite-others","set-user-specific-permission"]'
    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -d backend -c \
        "UPDATE domains SET allowed_vfolder_hosts = '{\"${LOCAL_STORAGE_PROXY}:${LOCAL_STORAGE_VOLUME}\": ${ALL_VFOLDER_HOST_PERM}}';"
    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -d backend -c \
        "UPDATE groups SET allowed_vfolder_hosts = '{\"${LOCAL_STORAGE_PROXY}:${LOCAL_STORAGE_VOLUME}\": ${ALL_VFOLDER_HOST_PERM}}';"
    docker exec -e PGPASSWORD=develove "$POSTGRES_CONTAINER" psql -U postgres -d backend -c \
        "UPDATE keypair_resource_policies SET allowed_vfolder_hosts = '{\"${LOCAL_STORAGE_PROXY}:${LOCAL_STORAGE_VOLUME}\": ${ALL_VFOLDER_HOST_PERM}}';"

    show_info "Virtual folders configured"
}

scan_image_registry() {
    show_info "Scanning container image registry..."

    cd "$INSTALL_PATH/backend.ai"
    source "$INSTALL_PATH/.venv/bin/activate"

    ./backend.ai mgr image rescan cr.backend.ai

    # Rescan NVIDIA NGC registry for PyTorch image
    ./backend.ai mgr image rescan nvcr.io -t nvidia/pytorch:25.05-py3 || show_warning "NGC image rescan failed (registry may not be accessible)"

    # Set up default image alias based on architecture
    if [[ "$ARCH" == "aarch64" ]]; then
        ./backend.ai mgr image alias python "cr.backend.ai/multiarch/python:3.9-ubuntu20.04" aarch64
    else
        ./backend.ai mgr image alias python "cr.backend.ai/stable/python:3.9-ubuntu20.04" x86_64
    fi

    show_info "Image registry scanned"
}

#######################################
# Phase 9: CUDA Plugin Setup
#######################################

setup_cuda_plugin() {
    if [[ $SKIP_GPU_SETUP -eq 1 ]]; then
        show_info "Skipping CUDA plugin setup (--skip-gpu-setup)"
        return 0
    fi

    show_info "Setting up CUDA accelerator plugin..."

    cd "$INSTALL_PATH/backend.ai"
    source "$INSTALL_PATH/.venv/bin/activate"

    # The cuda_open plugin should be available in the main package
    # Verify GPU detection
    show_info "Verifying GPU detection..."
    nvidia-smi

    show_info "CUDA plugin configured"
}

#######################################
# Phase 10: Systemd Services
#######################################

create_systemd_services() {
    if [[ $SKIP_SYSTEMD -eq 1 ]]; then
        show_info "Skipping systemd service creation (--skip-systemd)"
        return 0
    fi

    show_info "Creating systemd service files..."

    # Run services as root since venv and install path are owned by root
    local target_user="root"
    local python_path="$INSTALL_PATH/.venv/bin/python"
    local backend_ai_path="$INSTALL_PATH/backend.ai"

    local venv_path="${INSTALL_PATH}/.venv"
    local src_path="${backend_ai_path}/src"

    if [[ "$INSTALL_MODE" == "main" ]]; then
        # Manager service
        cat > /etc/systemd/system/backendai-manager.service << EOF
[Unit]
Description=Backend.AI Manager
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.cli mgr start-server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF

        # Storage Proxy service
        cat > /etc/systemd/system/backendai-storage-proxy.service << EOF
[Unit]
Description=Backend.AI Storage Proxy
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.storage.server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF

        # Webserver service
        cat > /etc/systemd/system/backendai-webserver.service << EOF
[Unit]
Description=Backend.AI Webserver
After=network.target docker.service backendai-manager.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.web.server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF

        # App Proxy Coordinator service
        cat > /etc/systemd/system/backendai-appproxy-coordinator.service << EOF
[Unit]
Description=Backend.AI App Proxy Coordinator
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.cli app-proxy-coordinator start-server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF

        # App Proxy Worker service
        cat > /etc/systemd/system/backendai-appproxy-worker.service << EOF
[Unit]
Description=Backend.AI App Proxy Worker
After=network.target docker.service backendai-appproxy-coordinator.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.cli app-proxy-worker start-server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF

        # Agent service (if not skipped)
        if [[ $SKIP_AGENT -eq 0 ]]; then
            cat > /etc/systemd/system/backendai-agent.service << EOF
[Unit]
Description=Backend.AI Agent
After=network.target docker.service backendai-manager.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.cli ag start-server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF
        fi

        show_info "Main node systemd services created"
    else
        # Worker mode: only agent service
        cat > /etc/systemd/system/backendai-agent.service << EOF
[Unit]
Description=Backend.AI Agent (Worker Node)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
User=${target_user}
WorkingDirectory=${backend_ai_path}
ExecStart=${venv_path}/bin/python -m ai.backend.cli ag start-server
Restart=on-failure
RestartSec=10
Environment=VIRTUAL_ENV=${venv_path}
Environment=PATH=${venv_path}/bin:/usr/local/bin:/usr/bin:/bin
Environment=PYTHONPATH=${src_path}

[Install]
WantedBy=multi-user.target
EOF

        show_info "Worker node systemd services created"
    fi

    # Reload systemd
    systemctl daemon-reload

    # Auto-enable and start services
    show_info "Enabling and starting Backend.AI services..."

    if [[ "$INSTALL_MODE" == "main" ]]; then
        systemctl enable --now backendai-manager
        systemctl enable --now backendai-storage-proxy
        systemctl enable --now backendai-webserver
        systemctl enable --now backendai-appproxy-coordinator
        systemctl enable --now backendai-appproxy-worker
        if [[ $SKIP_AGENT -eq 0 ]]; then
            systemctl enable --now backendai-agent
        fi
        show_info "Main node services enabled and started"
    else
        systemctl enable --now backendai-agent
        show_info "Worker agent service enabled and started"
    fi
}

#######################################
# Phase 11: Final Setup
#######################################

create_client_env_scripts() {
    show_info "Creating client environment scripts..."

    cd "$INSTALL_PATH/backend.ai"

    # Admin API access
    cat > env-local-admin-api.sh << EOF
# Directly access to the manager using API keypair (admin)
export BACKEND_ENDPOINT=http://127.0.0.1:${MANAGER_PORT}/
export BACKEND_ACCESS_KEY=$(jq -r '.keypairs[] | select(.user_id=="admin@lablup.com") | .access_key' fixtures/manager/example-keypairs.json)
export BACKEND_SECRET_KEY=$(jq -r '.keypairs[] | select(.user_id=="admin@lablup.com") | .secret_key' fixtures/manager/example-keypairs.json)
export BACKEND_ENDPOINT_TYPE=api
EOF
    chmod +x env-local-admin-api.sh

    # Admin session access
    cat > env-local-admin-session.sh << EOF
# Indirectly access to the manager via the web server using a cookie-based login session (admin)
export BACKEND_ENDPOINT=http://127.0.0.1:${WEBSERVER_PORT}
unset BACKEND_ACCESS_KEY
unset BACKEND_SECRET_KEY
export BACKEND_ENDPOINT_TYPE=session
echo 'Run backend.ai login to make an active session.'
echo 'Username: $(jq -r '.users[] | select(.username=="admin") | .email' fixtures/manager/example-users.json)'
echo 'Password: $(jq -r '.users[] | select(.username=="admin") | .password' fixtures/manager/example-users.json)'
EOF
    chmod +x env-local-admin-session.sh

    # User API access
    cat > env-local-user-api.sh << EOF
# Directly access to the manager using API keypair (user)
export BACKEND_ENDPOINT=http://127.0.0.1:${MANAGER_PORT}/
export BACKEND_ACCESS_KEY=$(jq -r '.keypairs[] | select(.user_id=="user@lablup.com") | .access_key' fixtures/manager/example-keypairs.json)
export BACKEND_SECRET_KEY=$(jq -r '.keypairs[] | select(.user_id=="user@lablup.com") | .secret_key' fixtures/manager/example-keypairs.json)
export BACKEND_ENDPOINT_TYPE=api
EOF
    chmod +x env-local-user-api.sh

    show_info "Client environment scripts created"
}

pull_kernel_images() {
    if [[ $SKIP_IMAGE_PULL -eq 1 ]]; then
        show_info "Skipping kernel image pull (--skip-image-pull)"
        return 0
    fi

    show_info "Pulling default kernel images..."

    if [[ "$ARCH" == "aarch64" ]]; then
        # docker pull "cr.backend.ai/multiarch/python:3.9-ubuntu20.04" || true
        docker pull "nvcr.io/nvidia/pytorch:25.05-py3" || true
    else
        # docker pull "cr.backend.ai/stable/python:3.9-ubuntu20.04" || true
        # Pull a GPU-enabled image for testing
        # docker pull "cr.backend.ai/stable/python-pytorch:2.0-py311-cuda12.1" || true
        docker pull "nvcr.io/nvidia/pytorch:25.05-py3" || true
    fi

    show_info "Kernel images pulled"
}

show_summary_main() {
    local display_ip
    if [[ -n "$TAILSCALE_IP" ]]; then
        # When Tailscale is enabled, firewall blocks non-Tailscale traffic
        display_ip="$TAILSCALE_IP"
    else
        # Without Tailscale, show public IP for external access
        display_ip=$(curl -s ifconfig.me 2>/dev/null || echo "$LOCAL_IP")
    fi

    echo ""
    echo "${LGREEN}========================================${NC}"
    echo "${LGREEN}  Backend.AI Main Node Installation Complete!${NC}"
    echo "${LGREEN}========================================${NC}"
    echo ""
    echo "${LWHITE}Installation Path:${NC} $INSTALL_PATH/backend.ai"
    echo "${LWHITE}Installation Mode:${NC} Main Node"
    echo "${LWHITE}Local IP:${NC} $LOCAL_IP"
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo ""
        echo "${LWHITE}Tailscale:${NC}"
        echo "  Tailscale IP: $TAILSCALE_IP"
        echo "  Firewall: Only Tailscale network (100.64.0.0/10) allowed"
        echo "  Status: tailscale status"
    fi
    if [[ $NFS_ENABLED -eq 1 ]] && [[ -z "$NFS_SERVER" ]]; then
        local nfs_path="${NFS_EXPORT_PATH:-${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}}"
        echo ""
        echo "${LWHITE}NFS Shared Storage:${NC}"
        echo "  Export: ${LOCAL_IP}:${nfs_path}"
        echo "  Workers use: --enable-nfs"
    fi
    echo ""
    echo "${LWHITE}Service URLs (access via ${display_ip}):${NC}"
    echo "  Manager API:    http://${display_ip}:${MANAGER_PORT}/"
    echo "  Webserver:      http://${display_ip}:${WEBSERVER_PORT}/"
    echo "  PostgreSQL:     localhost:${POSTGRES_PORT}"
    echo "  Redis:          localhost:${REDIS_PORT}"
    echo "  etcd:           localhost:${ETCD_PORT}"
    echo "  Storage-Proxy:  localhost:${STORAGE_PROXY_CLIENT_PORT}"
    echo "  Grafana:        http://${display_ip}:3000/ (backend/develove)"
    echo "  MinIO Console:  http://${display_ip}:9001/"
    echo ""
    echo "${LWHITE}Default Credentials:${NC}"
    echo "  Admin Email:    admin@lablup.com"
    echo "  Admin Password: wJalrXUt"
    echo ""
    echo "${LWHITE}Services Status:${NC}"
    echo "  All Backend.AI services have been automatically enabled and started."
    echo ""
    echo "${LWHITE}View Logs:${NC}"
    echo "  # Follow all Backend.AI logs:"
    echo "  journalctl -u 'backendai-*' -f"
    echo ""
    echo "  # Follow specific service logs:"
    echo "  journalctl -u backendai-manager -f"
    if [[ $SKIP_AGENT -eq 0 ]]; then
        echo "  journalctl -u backendai-agent -f"
    fi
    echo "  journalctl -u backendai-storage-proxy -f"
    echo "  journalctl -u backendai-webserver -f"
    echo ""
    echo "${LWHITE}Service Management:${NC}"
    echo "  # Check status:"
    echo "  sudo systemctl status backendai-manager"
    echo ""
    echo "  # Restart a service:"
    echo "  sudo systemctl restart backendai-manager"
    echo ""
    echo "${LWHITE}Test your installation:${NC}"
    echo "  cd $INSTALL_PATH/backend.ai"
    echo "  source env-local-admin-api.sh"
    echo "  ./backend.ai run python -c \"print('Hello from Backend.AI!')\""
    echo ""
    echo "${LWHITE}Verify GPU access:${NC}"
    echo "  docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi"
    echo ""

    if [[ $SKIP_SYSTEMD -eq 0 ]]; then
        echo "${LWHITE}Systemd Services (auto-enabled):${NC}"
        echo "  backendai-manager"
        if [[ $SKIP_AGENT -eq 0 ]]; then
            echo "  backendai-agent"
        fi
        echo "  backendai-storage-proxy"
        echo "  backendai-webserver"
        echo "  backendai-appproxy-coordinator"
        echo "  backendai-appproxy-worker"
        echo ""
    fi

    echo "${LCYAN}========================================${NC}"
    echo "${LCYAN}  Worker Node Setup Instructions${NC}"
    echo "${LCYAN}========================================${NC}"
    echo ""
    echo "To add worker nodes to this cluster, run on each worker:"
    echo ""
    if [[ -n "$TAILSCALE_IP" ]] && [[ $NFS_ENABLED -eq 1 ]]; then
        echo "  # With Tailscale + NFS (recommended):"
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker \\"
        echo "      --main-node-ip ${TAILSCALE_IP} \\"
        echo "      --tailscale-auth-key <your-auth-key> \\"
        echo "      --enable-nfs"
        echo ""
        echo "  # Without Tailscale but with NFS:"
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker --main-node-ip ${LOCAL_IP} --enable-nfs"
        echo ""
    elif [[ -n "$TAILSCALE_IP" ]]; then
        echo "  # With Tailscale (recommended - uses encrypted VPN mesh):"
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker \\"
        echo "      --main-node-ip ${TAILSCALE_IP} \\"
        echo "      --tailscale-auth-key <your-auth-key>"
        echo ""
        echo "  # Without Tailscale (requires firewall configuration):"
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker --main-node-ip ${LOCAL_IP}"
        echo ""
    elif [[ $NFS_ENABLED -eq 1 ]]; then
        echo "  # With NFS shared storage (recommended for multi-node):"
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker --main-node-ip ${LOCAL_IP} --enable-nfs"
        echo ""
        echo "  # Without NFS (each node has local vfolders only):"
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker --main-node-ip ${LOCAL_IP}"
        echo ""
    else
        echo "  sudo ./scripts/install-gpu-vm.sh --mode worker --main-node-ip ${LOCAL_IP}"
        echo ""
    fi
    echo "${LWHITE}Required Firewall Ports (Inbound on Main Node):${NC}"
    echo "  8091  - Manager API (for workers and clients)"
    echo "  8120  - etcd (for workers)"
    echo "  8111  - Redis/Valkey (for workers, optional)"
    echo "  6021  - Storage-Proxy Client (for workers)"
    echo "  8090  - Webserver (for clients)"
    if [[ $NFS_ENABLED -eq 1 ]]; then
        echo "  2049  - NFS (for workers)"
        echo "  111   - NFS portmapper (for workers)"
    fi
    echo ""

    echo "${LYELLOW}Important Notes:${NC}"
    echo "  - For production, change default passwords and API keys"
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo "  - Tailscale provides encrypted communication between nodes"
        echo "  - Firewall configured to allow only Tailscale network (100.64.0.0/10)"
        echo "  - Check Tailscale status: tailscale status"
        echo "  - Check firewall status: sudo ufw status"
    else
        echo "  - Configure firewall rules for exposed ports"
    fi
    echo "  - Set up SSL/TLS for production deployments"
    echo ""
}

show_summary_worker() {
    echo ""
    echo "${LGREEN}========================================${NC}"
    echo "${LGREEN}  Backend.AI Worker Node Installation Complete!${NC}"
    echo "${LGREEN}========================================${NC}"
    echo ""
    echo "${LWHITE}Installation Path:${NC} $INSTALL_PATH/backend.ai"
    echo "${LWHITE}Installation Mode:${NC} Worker Node"
    echo "${LWHITE}Local IP:${NC} $LOCAL_IP"
    echo "${LWHITE}Main Node IP:${NC} $MAIN_NODE_IP"
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo ""
        echo "${LWHITE}Tailscale:${NC}"
        echo "  Tailscale IP: $TAILSCALE_IP"
        echo "  Firewall: Only Tailscale network (100.64.0.0/10) allowed"
        echo "  Status: tailscale status"
    fi
    if [[ $NFS_ENABLED -eq 1 ]]; then
        local nfs_server="${NFS_SERVER:-$MAIN_NODE_IP}"
        local mount_point="${INSTALL_PATH}/backend.ai/${VFOLDER_REL_PATH}"
        echo ""
        echo "${LWHITE}NFS Shared Storage:${NC}"
        echo "  Server: ${nfs_server}"
        echo "  Mount:  ${mount_point}"
    fi
    echo ""
    echo "${LWHITE}Connection:${NC}"
    echo "  etcd:           ${MAIN_NODE_IP}:${ETCD_PORT}"
    echo "  Agent RPC:      ${LOCAL_IP}:${AGENT_RPC_PORT} (advertised to manager)"
    echo "  Agent Internal: ${LOCAL_IP}:6003"
    echo ""
    echo "${LWHITE}Services Status:${NC}"
    echo "  The Backend.AI agent has been automatically enabled and started."
    echo ""
    echo "${LWHITE}View Logs:${NC}"
    echo "  journalctl -u backendai-agent -f"
    echo ""
    echo "${LWHITE}Service Management:${NC}"
    echo "  sudo systemctl status backendai-agent"
    echo "  sudo systemctl restart backendai-agent"
    echo ""
    echo "${LWHITE}Verify GPU access:${NC}"
    echo "  docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi"
    echo ""
    echo "${LWHITE}Check agent registration (from main node):${NC}"
    echo "  cd $INSTALL_PATH/backend.ai"
    echo "  ./backend.ai mgr etcd ls /nodes/agents"
    echo ""

    if [[ $SKIP_SYSTEMD -eq 0 ]]; then
        echo "${LWHITE}Systemd Service (auto-enabled):${NC}"
        echo "  backendai-agent"
        echo ""
    fi

    echo "${LWHITE}Required Firewall Ports (Inbound on Worker Node):${NC}"
    echo "  6001        - Agent RPC (for manager)"
    echo "  6003        - Agent Internal (for containers)"
    echo "  30000-32000 - Container Ports (for clients)"
    echo ""

    echo "${LYELLOW}Important Notes:${NC}"
    echo "  - Ensure main node services are running before starting agent"
    echo "  - Agent will auto-register with the manager via etcd"
    if [[ -n "$TAILSCALE_IP" ]]; then
        echo "  - Firewall configured to allow only Tailscale network (100.64.0.0/10)"
        echo "  - Verify Tailscale connectivity: ping $MAIN_NODE_IP"
        echo "  - Check Tailscale/firewall status: tailscale status && sudo ufw status"
    fi
    echo "  - Check agent logs if registration fails:"
    echo "    journalctl -u backendai-agent -f"
    echo ""
}

show_summary() {
    if [[ "$INSTALL_MODE" == "main" ]]; then
        show_summary_main
    else
        show_summary_worker
    fi
}

#######################################
# Main installation flow
#######################################

main() {
    echo ""
    echo "${LGREEN}Backend.AI GPU VM Auto-Installer (Multi-Node Support)${NC}"
    echo "${CYAN}Version: 2.0.0${NC}"
    echo ""

    parse_args "$@"

    # Check if running as root
    check_root

    # Tailscale Setup (if auth key provided) - install early so etcd check can use Tailscale network
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        show_step "Phase 0: Tailscale Setup"
        install_tailscale
        # Update LOCAL_IP to use Tailscale IP for subsequent configurations
        update_local_ip_for_tailscale
    fi

    # Validate installation mode (includes etcd connectivity check for workers)
    validate_mode

    # Phase 1: System Prerequisites
    show_step "Phase 1: System Prerequisites"
    check_ubuntu_version
    check_nvidia_driver
    detect_architecture
    install_system_packages
    configure_system_limits

    # Install Rover for GraphQL schema generation (main node only)
    if [[ "$INSTALL_MODE" == "main" ]]; then
        install_rover
    fi

    # Install system Valkey/Redis if requested (alternative to Docker Redis)
    if [[ "$INSTALL_MODE" == "main" ]] && [[ $USE_SYSTEM_REDIS -eq 1 ]]; then
        install_valkey
    fi

    # Phase 2: Docker Setup
    show_step "Phase 2: Docker Setup"
    install_docker
    add_user_to_docker_group

    # Phase 3: GPU Runtime Setup
    show_step "Phase 3: GPU Runtime Setup"
    install_nvidia_container_toolkit
    install_cuda_toolkit
    verify_gpu_docker

    # Phase 4: Python Environment
    show_step "Phase 4: Python Environment"
    install_uv
    setup_python

    # Phase 5: Backend.AI Installation
    show_step "Phase 5: Backend.AI Installation"
    clone_repository
    install_pants
    export_python_dependencies

    if [[ "$INSTALL_MODE" == "main" ]]; then
        # Main Node Only: Halfstack Services
        show_step "Phase 6: Halfstack Services"
        setup_halfstack
        start_halfstack
        configure_minio

        # Phase 6.5: NFS Server Setup (if enabled)
        if [[ $NFS_ENABLED -eq 1 ]]; then
            show_step "Phase 6.5: NFS Server Setup"
            setup_nfs_server
        fi

        # Generate secrets for all services
        generate_secrets

        # Phase 7: Service Configuration
        show_step "Phase 7: Service Configuration"
        configure_manager
        configure_storage_proxy
        configure_webserver
        configure_appproxy

        # Configure agent if not skipped
        if [[ $SKIP_AGENT -eq 0 ]]; then
            configure_agent
        fi

        # Phase 8: Database Initialization
        show_step "Phase 8: Database Initialization"
        initialize_database
        initialize_appproxy_database
        setup_vfolders
        scan_image_registry

        # Phase 9: CUDA Plugin Setup
        show_step "Phase 9: CUDA Plugin Setup"
        setup_cuda_plugin

        # Phase 10: Systemd Services
        show_step "Phase 10: Systemd Services"
        create_systemd_services

        # Phase 11: Final Setup
        show_step "Phase 11: Final Setup"
        create_client_env_scripts
        pull_kernel_images
    else
        # Worker Node Only: NFS Shared Storage (if enabled)
        if [[ $NFS_ENABLED -eq 1 ]]; then
            show_step "Phase 6: NFS Shared Storage"
            setup_nfs_client
            mount_nfs_storage
        fi

        # Worker Node Only: Agent Configuration
        show_step "Phase 6.1: Worker Agent Configuration"
        configure_worker_agent

        # Phase 7: CUDA Plugin Setup
        show_step "Phase 7: CUDA Plugin Setup"
        setup_cuda_plugin

        # Phase 8: Systemd Services
        show_step "Phase 8: Systemd Services"
        create_systemd_services

        # Phase 9: Pull Kernel Images
        show_step "Phase 9: Kernel Images"
        pull_kernel_images
    fi

    # Configure firewall for Tailscale (if enabled)
    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        show_step "Firewall Configuration"
        configure_tailscale_firewall
    fi

    # Show summary
    show_summary
}

# Run main function
main "$@"
