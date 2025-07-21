# Proxmox CS2 Worker Environment Variables
# Source this file to set up environment for worker management

# Base configuration
export PROXMOX_CS2_HOME="$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")"
export PATH="$PROXMOX_CS2_HOME/scripts:$PATH"

# Default configuration file
export CONFIG_FILE="${CONFIG_FILE:-$PROXMOX_CS2_HOME/configs/default.conf}"

# Logging configuration
export LOG_LEVEL="${LOG_LEVEL:-INFO}"
export VERBOSE="${VERBOSE:-false}"

# Worker configuration
export WORKER_BASE_VMID="${WORKER_BASE_VMID:-1000}"
export MAX_WORKERS="${MAX_WORKERS:-20}"
export DEFAULT_WORKERS="${DEFAULT_WORKERS:-5}"

# Storage and network defaults
export DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"
export DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# Helper functions
cs2_status() {
    "$PROXMOX_CS2_HOME/scripts/status.sh" "$@"
}

cs2_manage() {
    "$PROXMOX_CS2_HOME/scripts/manage_workers.sh" "$@"
}

cs2_provision() {
    "$PROXMOX_CS2_HOME/provision_workers.sh" "$@"
}

# Aliases for common operations
alias cs2-list='cs2_manage list'
alias cs2-monitor='cs2_manage monitor'
alias cs2-health='cs2_status health'
alias cs2-scale='cs2_manage scale'

echo "Proxmox CS2 Worker environment loaded"
echo "Available commands: cs2_status, cs2_manage, cs2_provision"
echo "Available aliases: cs2-list, cs2-monitor, cs2-health, cs2-scale"
