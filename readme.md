# Proxmox CS2 Worker Cluster

A production-ready, fully automated Proxmox VE deployment solution for hosting multiple Windows 11 GPU-enabled worker VMs running Counter-Strike 2 clients. This repository provides complete automation for setting up a Proxmox host with NVIDIA vGPU support and provisioning scalable CS2 worker instances.

## Features

- **Automated Proxmox VE Installation**: Complete setup on fresh Debian 12 servers
- **NVIDIA GPU support** with `vgpu_unlock` for virtual GPU sharing.
- **Windows 11 VM template builder** (with Python and CS2 pre-installed).
- **Automatic provisioning of N worker VMs** via Proxmox API/CLI.
- **NVIDIA vGPU Support**: Multi-instance GPU sharing using vgpu_unlock
- **Windows 11 Worker VMs**: Automated provisioning and configuration
- **CS2 Client Management**: Automated game client deployment and startup
- **Load Balancer Integration**: Health monitoring and registration
- **Production Ready**: Comprehensive error handling, logging, and monitoring
- **Scalable Architecture**: Dynamic worker scaling based on demand

## Quick Start

### Prerequisites

- Fresh Debian 12 server
- NVIDIA GPU (RTX 4090 recommended)
- Minimum 16GB RAM (64GB recommended for production)
- 500GB+ available storage
- Root access to the server

### Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/your-org/proxmox-cs2-workers.git
   cd proxmox-cs2-workers
   ```

2. **Run the installation script**:
   ```bash
   sudo ./install_proxmox.sh --workers=5 --loadbalancerurl=https://your-lb.com/api
   ```

3. **Reboot the system**:
   ```bash
   sudo reboot
   ```

4. **Complete Windows 11 template setup** (see detailed instructions below)

5. **Provision worker VMs**:
   ```bash
   ./provision_workers.sh --workers=5
   ```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Proxmox VE Host                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐ │
│  │   NVIDIA GPU    │  │   vGPU Unlock   │  │  Management  │ │
│  │   (RTX 4090)    │  │   Kernel Mod    │  │  Interface   │ │
│  └─────────────────┘  └─────────────────┘  └──────────────┘ │
│                                                             │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                 Virtual Machines                        │ │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐       │ │
│  │  │   Worker 1  │ │   Worker 2  │ │   Worker N  │  ...  │ │
│  │  │ Windows 11  │ │ Windows 11  │ │ Windows 11  │       │ │
│  │  │   + CS2     │ │   + CS2     │ │   + CS2     │       │ │
│  │  │   + vGPU    │ │   + vGPU    │ │   + vGPU    │       │ │
│  │  └─────────────┘ └─────────────┘ └─────────────┘       │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌─────────────────────┐
                    │   Load Balancer     │
                    │   Health Monitoring │
                    │   Worker Registry   │
                    └─────────────────────┘
```

## Repository Structure

```
proxmox-screenshot-worker-installer/
├── install_proxmox.sh              # Main installation script
├── provision_workers.sh            # Worker VM provisioning script
├── scripts/
│   ├── common.sh                   # Shared functions library
│   └── manage_workers.sh           # Worker management utilities
├── templates/
│   └── bootstrap_worker.ps1        # Windows VM bootstrap script
├── configs/
│   ├── default.conf               # Default configuration
│   └── production.conf            # Production configuration template
├── docs/
│   └── (additional documentation)
└── README.md                      # This file
```

## Detailed Setup Instructions

### 1. Server Preparation

#### Hardware Requirements

**Minimum Requirements:**
- CPU: Intel/AMD with virtualization support (VT-x/AMD-V)
- RAM: 16GB (4GB host + 8GB per worker)
- Storage: 500GB SSD
- GPU: NVIDIA RTX series with vGPU support
- Network: 1Gbps connection

**Recommended for Production:**
- CPU: Intel Xeon or AMD EPYC (16+ cores)
- RAM: 64GB+ (allows 6-8 workers with 8GB each)
- Storage: 2TB+ NVMe SSD
- GPU: NVIDIA RTX 4090 or Tesla series
- Network: 10Gbps connection

#### Debian 12 Installation

1. Download Debian 12 (bookworm) netinstall ISO
2. Install with minimal packages (no GUI)
3. Configure static IP address
4. Enable SSH access
5. Update system packages:
   ```bash
   apt update && apt upgrade -y
   ```

### 2. Proxmox VE Installation

#### Automatic Installation

```bash
# Basic installation with 5 workers
sudo ./install_proxmox.sh --workers=5

# Production installation with load balancer
sudo ./install_proxmox.sh \
    --workers=10 \
    --loadbalancerurl=https://cs2-lb.production.com/api \
    --verbose
```

#### Manual Steps After Installation

The installation script will prompt you to complete these steps manually:

1. **Reboot the system** to activate the new kernel and IOMMU settings
2. **Access Proxmox web interface** at `https://YOUR_SERVER_IP:8006`
3. **Complete Windows 11 template setup** (detailed below)

### 3. Windows 11 Template Creation

#### Template Setup Process

1. **Access Proxmox Web Interface**:
   ```
   URL: https://YOUR_SERVER_IP:8006
   Username: root
   Password: (your root password)
   ```

2. **Download Windows 11 ISO**:
   - Download from [Microsoft](https://www.microsoft.com/software-download/windows11)
   - Upload to `/var/lib/vz/template/iso/` or use Proxmox web interface

3. **Start Template VM**:
   ```bash
   qm start 9000
   ```

4. **Install Windows 11**:
   - Connect to VM console via Proxmox web interface
   - Follow Windows 11 installation wizard
   - Create user account: `worker` (password will be configured later)
   - Skip Microsoft account creation
   - Disable all privacy options

5. **Install Required Software**:

   **Python Installation**:
   ```powershell
   # Download and install Python 3.11
   Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.11.0/python-3.11.0-amd64.exe" -OutFile "python-installer.exe"
   .\python-installer.exe /quiet InstallAllUsers=1 PrependPath=1
   ```

   **Steam Installation**:
   ```powershell
   # Download and install Steam
   Invoke-WebRequest -Uri "https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe" -OutFile "SteamSetup.exe"
   .\SteamSetup.exe /S
   ```

   **CS2 Installation**:
   - Launch Steam and log in with dedicated account
   - Install Counter-Strike 2 (App ID: 730)
   - Configure Steam to start automatically
   - Set Steam to offline mode for workers

6. **Install Proxmox Guest Agent**:
   ```powershell
   # Download from Proxmox VE ISO or use chocolatey
   choco install qemu-guest-agent -y
   ```

7. **Configure Auto-Login**:
   ```powershell
   # Enable automatic login for worker user
   reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f
   reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d worker /f
   reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d YOUR_PASSWORD /f
   ```

8. **Shutdown and Convert to Template**:
   ```bash
   qm shutdown 9000
   # Wait for shutdown to complete
   qm template 9000
   ```

### 4. Worker Provisioning

#### Basic Provisioning

```bash
# Provision 5 workers
./provision_workers.sh --workers=5

# Provision with custom configuration
./provision_workers.sh \
    --workers=10 \
    --memory=16384 \
    --cores=6 \
    --storage=fast-ssd \
    --loadbalancerurl=https://your-lb.com/api
```

## Management and Operations

### Worker Management

The `manage_workers.sh` script provides comprehensive worker management:

```bash
# List all workers with status
./scripts/manage_workers.sh list

# Monitor workers in real-time
./scripts/manage_workers.sh monitor

# View logs for specific worker
./scripts/manage_workers.sh logs 1001

# Restart a worker
./scripts/manage_workers.sh restart 1001

# Scale workers up or down
./scripts/manage_workers.sh scale 10

# Health check all workers
./scripts/manage_workers.sh health

# Backup a worker
./scripts/manage_workers.sh backup 1001 "Before maintenance"
```

## Configuration

### Configuration Files

The system uses hierarchical configuration:

1. **Default configuration**: `configs/default.conf`
2. **Environment-specific**: `configs/production.conf`
3. **Command-line overrides**: Script parameters

### Key Configuration Options

```bash
# Worker VM settings
WORKER_MEMORY=8192          # Memory per worker (MB)
WORKER_CORES=4              # CPU cores per worker
WORKER_STORAGE="local-lvm"  # Storage pool

# GPU settings
VGPU_PROFILE_TYPE="nvidia-63"  # vGPU profile type
MAX_VGPU_INSTANCES=8           # Max vGPU instances

# CS2 settings
CS2_REPO_URL="https://github.com/your-org/cs2-scripts.git"
CS2_LAUNCH_PARAMS="-novid -nojoy -high +fps_max 60"

# Load balancer settings
DEFAULT_LOADBALANCER_URL="https://your-lb.com/api"
HEALTH_CHECK_INTERVAL=30
```

## Load Balancer Integration

### API Endpoints

The worker bootstrap script expects these endpoints:

```bash
# Worker registration
POST /api/register
{
  "worker_id": 1,
  "hostname": "cs2-worker-1",
  "ip_address": "192.168.1.100",
  "status": "starting",
  "capabilities": ["cs2", "gpu"]
}

# Health check
POST /api/health
{
  "worker_id": 1,
  "status": "healthy",
  "timestamp": "2023-12-01T10:00:00Z",
  "uptime": 3600
}
```

## Troubleshooting

### Common Issues

**Issue: vGPU not working after reboot**
```bash
# Restart vGPU setup service
systemctl restart vgpu-setup.service

# Check vGPU devices
ls /sys/bus/mdev/devices/
```

**Issue: Worker VM not starting**
```bash
# Check VM configuration
qm config 1001

# Check available resources
free -h
df -h
```

**Issue: CS2 not launching in worker**
```bash
# Check logs
./scripts/manage_workers.sh logs 1001

# Restart the worker
./scripts/manage_workers.sh restart 1001
```

### Log Files

- **Installation logs**: `/var/log/proxmox-install.log`
- **Worker logs**: `/var/log/proxmox-workers.log`
- **Proxmox logs**: `/var/log/pve/`

## Important Notes

⚠️ **License Compliance**: Ensure proper licensing for Windows 11, Steam, and CS2
⚠️ **Security**: Configure firewall and network security appropriately
⚠️ **Performance**: Monitor resource usage and scale appropriately
⚠️ **Maintenance**: Keep templates and workers updated regularly

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes with comprehensive testing
4. Submit a pull request with detailed description

## License

This project is licensed under the MIT License. See the LICENSE file for details.

**Note**: This software is provided as-is for educational and development purposes. Ensure compliance with all applicable software licenses and terms of service.

