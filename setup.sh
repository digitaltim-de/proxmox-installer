#!/bin/bash

# Setup script for Proxmox CS2 Worker repository
# This script makes all scripts executable and sets up the environment

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Setting up Proxmox CS2 Worker repository..."

# Make scripts executable
echo "Making scripts executable..."
chmod +x "$REPO_DIR/install_proxmox.sh"
chmod +x "$REPO_DIR/provision_workers.sh"
chmod +x "$REPO_DIR/scripts/common.sh"
chmod +x "$REPO_DIR/scripts/manage_workers.sh"
chmod +x "$REPO_DIR/scripts/status.sh"
chmod +x "$REPO_DIR/scripts/env.sh"

# Create log directory
echo "Creating log directories..."
sudo mkdir -p /var/log
sudo touch /var/log/proxmox-install.log
sudo touch /var/log/proxmox-workers.log
sudo chmod 644 /var/log/proxmox-*.log

# Create backup directories
echo "Creating backup directories..."
sudo mkdir -p /var/backups/vm-configs
sudo chmod 755 /var/backups/vm-configs

# Check system prerequisites
echo "Checking system prerequisites..."

# Check if running on Debian/Ubuntu
if ! grep -q -E "(debian|ubuntu)" /etc/os-release; then
    echo "Warning: This system doesn't appear to be Debian or Ubuntu"
    echo "The installation script is designed for Debian 12"
fi

# Check if running as root or with sudo access
if [[ $EUID -eq 0 ]]; then
    echo "Running as root - OK"
elif sudo -n true 2>/dev/null; then
    echo "Sudo access available - OK"
else
    echo "Warning: No root access or sudo privileges detected"
    echo "You may need root access to run the installation script"
fi

# Check for required commands
echo "Checking for required commands..."
missing_commands=()

required_commands=(
    "curl"
    "wget" 
    "git"
    "jq"
    "free"
    "df"
    "lspci"
)

for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        missing_commands+=("$cmd")
    fi
done

if [[ ${#missing_commands[@]} -gt 0 ]]; then
    echo "Warning: Missing required commands: ${missing_commands[*]}"
    echo "Install them with: sudo apt update && sudo apt install -y ${missing_commands[*]}"
fi

# Check hardware requirements
echo "Checking hardware requirements..."

# Check CPU virtualization
if grep -q -E "(vmx|svm)" /proc/cpuinfo; then
    echo "CPU virtualization support: OK"
else
    echo "Warning: CPU virtualization support not detected"
    echo "Enable VT-x/AMD-V in BIOS settings"
fi

# Check memory
total_memory_gb=$(free -g | awk '/^Mem:/{print $2}')
if [[ $total_memory_gb -ge 16 ]]; then
    echo "Memory: ${total_memory_gb}GB - OK"
elif [[ $total_memory_gb -ge 8 ]]; then
    echo "Memory: ${total_memory_gb}GB - Minimum (consider upgrading)"
else
    echo "Warning: Only ${total_memory_gb}GB memory detected"
    echo "Minimum 8GB required, 16GB+ recommended"
fi

# Check storage
available_space_gb=$(df / | tail -1 | awk '{print int($4/1024/1024)}')
if [[ $available_space_gb -ge 500 ]]; then
    echo "Storage: ${available_space_gb}GB available - OK"
elif [[ $available_space_gb -ge 200 ]]; then
    echo "Storage: ${available_space_gb}GB available - Minimum"
else
    echo "Warning: Only ${available_space_gb}GB storage available"
    echo "Minimum 200GB required, 500GB+ recommended"
fi

# Check for NVIDIA GPU
if lspci | grep -i nvidia >/dev/null; then
    echo "NVIDIA GPU detected - OK"
    lspci | grep -i nvidia | head -1
else
    echo "Warning: No NVIDIA GPU detected"
    echo "NVIDIA GPU required for vGPU functionality"
fi

# Create example configuration
echo "Creating example configuration..."
if [[ ! -f "$REPO_DIR/configs/local.conf" ]]; then
    cp "$REPO_DIR/configs/default.conf" "$REPO_DIR/configs/local.conf"
    echo "Created local.conf from default configuration"
    echo "Edit configs/local.conf to customize your setup"
fi

# Setup environment file
echo "Setting up environment..."
cat > "$REPO_DIR/.env" << EOF
# Proxmox CS2 Worker Environment
# Source this file to load environment variables

export PROXMOX_CS2_HOME="$REPO_DIR"
export CONFIG_FILE="\$PROXMOX_CS2_HOME/configs/local.conf"
export PATH="\$PROXMOX_CS2_HOME/scripts:\$PATH"

# To load this environment, run:
# source $REPO_DIR/.env
EOF

echo
echo "============================================"
echo "Proxmox CS2 Worker Setup Complete!"
echo "============================================"
echo
echo "Next steps:"
echo "1. Review and edit configs/local.conf for your environment"
echo "2. Load the environment: source .env"
echo "3. Run the installation: sudo ./install_proxmox.sh --workers=5"
echo
echo "For detailed setup instructions, see README.md"
echo
echo "Quick commands:"
echo "  Setup environment:     source .env"
echo "  Install Proxmox:       sudo ./install_proxmox.sh --workers=5"
echo "  Provision workers:     ./provision_workers.sh --workers=5"
echo "  Check status:          ./scripts/status.sh health"
echo "  Manage workers:        ./scripts/manage_workers.sh list"
echo
echo "Configuration files:"
echo "  Main config:           configs/local.conf"
echo "  Environment:           .env"
echo "  Documentation:         docs/"
echo
echo "Log files (after installation):"
echo "  Installation:          /var/log/proxmox-install.log"
echo "  Workers:               /var/log/proxmox-workers.log"

# Check if this is a fresh git clone and suggest next steps
if [[ -d "$REPO_DIR/.git" ]]; then
    echo
    echo "Git repository detected. Consider:"
    echo "  - Forking this repository for your customizations"
    echo "  - Creating feature branches for modifications"
    echo "  - Keeping your local.conf in .gitignore"
fi

echo
echo "Repository structure:"
tree "$REPO_DIR" -L 2 2>/dev/null || find "$REPO_DIR" -maxdepth 2 -type d | sort

echo
echo "Setup completed successfully!"
