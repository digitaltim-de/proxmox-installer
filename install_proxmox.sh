#!/bin/bash

# Proxmox VE Installation and GPU Worker Setup Script
# This script installs Proxmox VE on Debian 12 and configures NVIDIA vGPU support
# for multiple Windows 11 worker VMs running CS2 clients.

set -euo pipefail

# Default configuration
DEFAULT_WORKERS=5
DEFAULT_LOADBALANCER_URL=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/proxmox-install.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
WORKERS=$DEFAULT_WORKERS
LOADBALANCER_URL=$DEFAULT_LOADBALANCER_URL
VERBOSE=false

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message" | tee -a "$LOG_FILE"
            ;;
        "DEBUG")
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} $message" | tee -a "$LOG_FILE"
            fi
            ;;
    esac
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Error handler
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

# Check system requirements
check_requirements() {
    log "INFO" "Checking system requirements..."

    # Check if running on Debian/Ubuntu
    if ! grep -q -E "(debian|ubuntu)" /etc/os-release; then
        log "WARN" "This system doesn't appear to be Debian or Ubuntu"
        log "WARN" "The installation may not work as expected"
    fi

    # Check CPU virtualization support
    if ! grep -q -E "(vmx|svm)" /proc/cpuinfo; then
        error_exit "CPU does not support hardware virtualization"
    fi

    # Check if NVIDIA GPU is present
    if ! lspci | grep -i nvidia > /dev/null; then
        error_exit "No NVIDIA GPU detected"
    fi

    # Check minimum RAM (16GB recommended)
    local ram_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $ram_gb -lt 16 ]]; then
        log "WARN" "Less than 16GB RAM detected ($ram_gb GB). Consider upgrading for better performance."
    fi

    log "INFO" "System requirements check passed"
}

# Configure repository sources
configure_repositories() {
    log "INFO" "Configuring package repositories..."

    # Backup original sources
    cp /etc/apt/sources.list /etc/apt/sources.list.backup

    # Add Proxmox VE repository
    cat > /etc/apt/sources.list.d/pve-install-repo.list << EOF
deb [arch=amd64] http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF

    # Add Proxmox VE repository key
    wget https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg -O /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg

    # Update package lists
    apt update || error_exit "Failed to update package lists"

    log "INFO" "Package repositories configured successfully"
}

# Install Proxmox VE
install_proxmox() {
    log "INFO" "Installing Proxmox VE..."

    # Install required packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        postfix \
        open-iscsi \
        || error_exit "Failed to install prerequisites"

    # Install Proxmox VE kernel and packages
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        proxmox-ve \
        postfix \
        open-iscsi \
        || error_exit "Failed to install Proxmox VE"

    # Remove os-prober (recommended by Proxmox)
    apt-get remove -y os-prober || true

    log "INFO" "Proxmox VE installed successfully"
}

# Install NVIDIA drivers and vGPU unlock
install_nvidia_vgpu() {
    log "INFO" "Installing NVIDIA drivers and vGPU unlock..."

    # Install NVIDIA drivers
    apt-get update
    apt-get install -y \
        linux-headers-$(uname -r) \
        build-essential \
        dkms \
        wget \
        curl \
        git \
        || error_exit "Failed to install build dependencies"

    # Download and install NVIDIA drivers
    cd /tmp

    # Get latest NVIDIA driver version
    NVIDIA_VERSION="535.129.03"  # Update as needed
    NVIDIA_DRIVER="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}.run"

    if [[ ! -f "$NVIDIA_DRIVER" ]]; then
        wget "https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${NVIDIA_DRIVER}" \
            || error_exit "Failed to download NVIDIA driver"
    fi

    # Install NVIDIA driver
    chmod +x "$NVIDIA_DRIVER"
    ./"$NVIDIA_DRIVER" --silent --dkms || error_exit "Failed to install NVIDIA driver"

    # Clone and install vgpu_unlock
    if [[ ! -d "/opt/vgpu_unlock" ]]; then
        git clone https://github.com/DualCoder/vgpu_unlock.git /opt/vgpu_unlock \
            || error_exit "Failed to clone vgpu_unlock repository"
    fi

    cd /opt/vgpu_unlock

    # Apply vGPU unlock patches
    ./vgpu_unlock_patcher.sh || error_exit "Failed to apply vGPU unlock patches"

    # Load vGPU unlock module
    echo "vfio-pci" >> /etc/modules
    echo "mdev" >> /etc/modules

    log "INFO" "NVIDIA drivers and vGPU unlock installed successfully"
}

# Configure vGPU profiles
configure_vgpu_profiles() {
    log "INFO" "Configuring vGPU profiles for $WORKERS workers..."

    # Create vGPU configuration script
    cat > /usr/local/bin/setup-vgpu-profiles.sh << EOF
#!/bin/bash

# vGPU Profile Setup Script
# This script creates vGPU profiles for worker VMs

set -e

WORKERS=$WORKERS
GPU_UUID=\$(nvidia-smi -L | head -1 | grep -o 'GPU-[a-f0-9-]*')

if [[ -z "\$GPU_UUID" ]]; then
    echo "Error: Could not detect NVIDIA GPU UUID"
    exit 1
fi

echo "Setting up \$WORKERS vGPU profiles for GPU: \$GPU_UUID"

# Create vGPU profiles (adjust profile type as needed)
# GRID RTX4090-4Q profile for CS2 workloads
PROFILE_TYPE="nvidia-63"  # RTX 4090 4GB profile

for i in \$(seq 1 \$WORKERS); do
    MDEV_UUID=\$(uuidgen)
    echo "\$MDEV_UUID" > "/sys/bus/pci/devices/\${GPU_UUID}/mdev_supported_types/\${PROFILE_TYPE}/create"
    echo "Created vGPU profile \$i: \$MDEV_UUID"
done

echo "vGPU profiles created successfully"
EOF

    chmod +x /usr/local/bin/setup-vgpu-profiles.sh

    # Create systemd service for vGPU setup
    cat > /etc/systemd/system/vgpu-setup.service << EOF
[Unit]
Description=Setup vGPU profiles for worker VMs
After=nvidia-persistenced.service
Requires=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-vgpu-profiles.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable vgpu-setup.service

    log "INFO" "vGPU profiles configured successfully"
}

# Configure Proxmox VE
configure_proxmox() {
    log "INFO" "Configuring Proxmox VE..."

    # Enable IOMMU
    if ! grep -q "intel_iommu=on" /etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt pcie_acs_override=downstream,multifunction nofb nomodeset video=vesafb:off,efifb:off"/' /etc/default/grub
        update-grub
    fi

    # Configure vfio modules
    cat > /etc/modules-load.d/vfio.conf << EOF
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF

    # Update initramfs
    update-initramfs -u

    # Configure Proxmox storage
    pvesm add dir local-templates --path /var/lib/vz/template --content vztmpl,iso,snippets

    log "INFO" "Proxmox VE configured successfully"
}

# Download Windows 11 ISO and create template
setup_windows_template() {
    log "INFO" "Setting up Windows 11 template..."

    # Create template directory
    mkdir -p /var/lib/vz/template/iso
    mkdir -p /var/lib/vz/template/snippets

    # Note: Windows 11 ISO must be manually downloaded due to licensing
    log "WARN" "Windows 11 ISO must be manually downloaded and placed in /var/lib/vz/template/iso/"
    log "WARN" "Download from: https://www.microsoft.com/software-download/windows11"

    # Create cloud-init snippet for Windows
    cat > /var/lib/vz/template/snippets/windows-cloudinit.yml << EOF
#cloud-config
hostname: win11-template
users:
  - name: worker
    passwd: \$6\$rounds=4096\$salt\$hash  # Change this password hash
    groups: administrators
    shell: cmd
packages:
  - python3
  - git
write_files:
  - path: C:\\Windows\\Temp\\bootstrap_worker.ps1
    content: |
      # Bootstrap script will be injected here during provisioning
    permissions: '0755'
runcmd:
  - powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\bootstrap_worker.ps1
EOF

    log "INFO" "Windows 11 template setup prepared"
}

# Create VM template
create_vm_template() {
    log "INFO" "Creating Windows 11 VM template..."

    # VM configuration
    local VMID=9000
    local VM_NAME="win11-cs2-template"
    local MEMORY=8192
    local CORES=4
    local DISK_SIZE="60G"

    # Check if template already exists
    if qm status $VMID >/dev/null 2>&1; then
        log "WARN" "VM template $VMID already exists, skipping creation"
        return 0
    fi

    # Create VM
    qm create $VMID \
        --name "$VM_NAME" \
        --memory $MEMORY \
        --cores $CORES \
        --net0 "virtio,bridge=vmbr0" \
        --scsihw virtio-scsi-pci \
        --scsi0 "local-lvm:$DISK_SIZE" \
        --ide2 "local:iso/Win11_22H2_English_x64v1.iso,media=cdrom" \
        --boot "order=ide2;scsi0" \
        --ostype win11 \
        --agent 1 \
        --tablet 0 \
        --cpu host \
        --machine q35 \
        --bios ovmf \
        --efidisk0 local-lvm:1,format=qcow2,efitype=4m \
        --tpmstate0 local-lvm:1,version=v2.0 \
        || error_exit "Failed to create VM template"

    log "INFO" "VM template $VMID created successfully"
    log "WARN" "Manual setup required:"
    log "WARN" "1. Start VM $VMID and install Windows 11"
    log "WARN" "2. Install Python, Steam, and CS2"
    log "WARN" "3. Install Proxmox VE guest agent"
    log "WARN" "4. Configure auto-login for worker user"
    log "WARN" "5. Convert to template: qm template $VMID"
}

# Create provisioning script
create_provisioning_script() {
    log "INFO" "Creating worker provisioning script..."

    cat > "$SCRIPT_DIR/provision_workers.sh" << 'EOF'
#!/bin/bash

# Worker VM Provisioning Script
# This script clones the Windows 11 template and provisions worker VMs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/common.sh"

# Configuration
TEMPLATE_VMID=9000
BASE_VMID=1000
WORKERS=${1:-5}
LOADBALANCER_URL=${2:-""}

log "INFO" "Provisioning $WORKERS worker VMs..."

for i in $(seq 1 $WORKERS); do
    VMID=$((BASE_VMID + i))
    VM_NAME="cs2-worker-$i"

    log "INFO" "Creating worker VM $i (VMID: $VMID)..."

    # Clone template
    qm clone $TEMPLATE_VMID $VMID \
        --name "$VM_NAME" \
        --full \
        || { log "ERROR" "Failed to clone template for worker $i"; continue; }

    # Get vGPU UUID for this worker
    VGPU_UUID=$(ls /sys/bus/mdev/devices/ | sed -n "${i}p")

    if [[ -n "$VGPU_UUID" ]]; then
        # Assign vGPU to VM
        qm set $VMID --hostpci0 "$VGPU_UUID,mdev=$VGPU_UUID"
        log "INFO" "Assigned vGPU $VGPU_UUID to worker $i"
    else
        log "WARN" "No vGPU available for worker $i"
    fi

    # Configure VM-specific settings
    qm set $VMID \
        --ciuser worker \
        --sshkeys ~/.ssh/authorized_keys \
        --ipconfig0 "ip=dhcp" \
        --startup "order=$i,up=30,down=30"

    # Start VM
    qm start $VMID
    log "INFO" "Started worker VM $i"
done

log "INFO" "Worker provisioning completed"
EOF

    chmod +x "$SCRIPT_DIR/provision_workers.sh"

    log "INFO" "Provisioning script created successfully"
}

# Create common functions library
create_common_library() {
    log "INFO" "Creating common functions library..."

    mkdir -p "$SCRIPT_DIR/scripts"

    cat > "$SCRIPT_DIR/scripts/common.sh" << 'EOF'
#!/bin/bash

# Common functions for Proxmox CS2 worker management

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        "DEBUG")
            echo -e "${BLUE}[DEBUG]${NC} $message"
            ;;
    esac

    if [[ -w "/var/log/proxmox-workers.log" ]] || [[ -w "$(dirname "/var/log/proxmox-workers.log")" ]]; then
        echo "[$timestamp] [$level] $message" >> "/var/log/proxmox-workers.log"
    fi
}

# Check if VM exists
vm_exists() {
    local vmid="$1"
    qm status "$vmid" >/dev/null 2>&1
}

# Wait for VM to be ready
wait_for_vm() {
    local vmid="$1"
    local timeout="${2:-300}"
    local count=0

    log "INFO" "Waiting for VM $vmid to be ready..."

    while [[ $count -lt $timeout ]]; do
        if qm agent "$vmid" ping >/dev/null 2>&1; then
            log "INFO" "VM $vmid is ready"
            return 0
        fi

        sleep 5
        count=$((count + 5))
    done

    log "ERROR" "VM $vmid did not become ready within ${timeout}s"
    return 1
}

# Get VM IP address
get_vm_ip() {
    local vmid="$1"
    qm agent "$vmid" network-get-interfaces | jq -r '.[] | select(.name=="Ethernet") | .["ip-addresses"][] | select(.["ip-address-type"]=="ipv4") | .["ip-address"]' | head -1
}
EOF

    log "INFO" "Common functions library created successfully"
}

# Display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --workers=N              Number of worker VMs to configure (default: $DEFAULT_WORKERS)
    --loadbalancerurl=URL    Load balancer URL for worker registration
    --verbose               Enable verbose logging
    --help                  Display this help message

Examples:
    $0 --workers=10 --loadbalancerurl=https://lb.example.com/api/register
    $0 --workers=3 --verbose

This script installs Proxmox VE on Debian 12 and configures NVIDIA vGPU support
for multiple Windows 11 worker VMs running CS2 clients.

Requirements:
- Fresh Debian 12 installation
- NVIDIA GPU (RTX series recommended)
- At least 16GB RAM
- Root privileges

EOF
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --workers=*)
                WORKERS="${1#*=}"
                if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [[ "$WORKERS" -lt 1 ]] || [[ "$WORKERS" -gt 20 ]]; then
                    error_exit "Workers must be a number between 1 and 20"
                fi
                ;;
            --loadbalancerurl=*)
                LOADBALANCER_URL="${1#*=}"
                ;;
            --verbose)
                VERBOSE=true
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1. Use --help for usage information."
                ;;
        esac
        shift
    done
}

# Main installation workflow
main() {
    log "INFO" "Starting Proxmox VE installation with GPU worker support..."
    log "INFO" "Configuration: Workers=$WORKERS, LoadBalancer=$LOADBALANCER_URL"

    # Pre-installation checks
    check_root
    check_requirements

    # Installation steps
    configure_repositories
    install_proxmox
    install_nvidia_vgpu
    configure_vgpu_profiles
    configure_proxmox
    setup_windows_template
    create_vm_template
    create_provisioning_script
    create_common_library

    log "INFO" "Installation completed successfully!"
    log "WARN" "IMPORTANT: A reboot is required to activate the new kernel and IOMMU settings"
    log "INFO" "After reboot:"
    log "INFO" "1. Complete Windows 11 template setup manually"
    log "INFO" "2. Run ./provision_workers.sh to create worker VMs"
    log "INFO" "3. Check /var/log/proxmox-install.log for detailed logs"

    # Display next steps
    cat << EOF

=== NEXT STEPS ===

1. Reboot the system:
   sudo reboot

2. After reboot, verify NVIDIA and vGPU setup:
   nvidia-smi
   ls /sys/bus/mdev/devices/

3. Complete Windows 11 template setup:
   - Access Proxmox web interface: https://$(hostname -I | awk '{print $1}'):8006
   - Start VM 9000 and install Windows 11
   - Install required software (Python, Steam, CS2)
   - Convert to template: qm template 9000

4. Provision worker VMs:
   ./provision_workers.sh

For detailed instructions, see README.md

EOF
}

# Initialize logging
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Parse arguments and run main function
parse_arguments "$@"
main

exit 0
