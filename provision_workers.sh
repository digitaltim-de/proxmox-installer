#!/bin/bash

# Proxmox Worker VM Provisioning Script
# This script provisions multiple Windows 11 worker VMs from a template
# Each VM gets assigned a vGPU and is configured for CS2 client workloads

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions if available
if [[ -f "$SCRIPT_DIR/scripts/common.sh" ]]; then
    source "$SCRIPT_DIR/scripts/common.sh"
else
    # Fallback logging function
    log() {
        local level="$1"
        shift
        local message="$*"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
    }
fi

# Configuration
TEMPLATE_VMID=9000
BASE_VMID=1000
DEFAULT_WORKERS=5
DEFAULT_LOADBALANCER_URL=""
LOG_FILE="/var/log/proxmox-workers.log"

# Global variables
WORKERS=$DEFAULT_WORKERS
LOADBALANCER_URL=$DEFAULT_LOADBALANCER_URL
BRIDGE="vmbr0"
STORAGE="local-lvm"
MEMORY=8192
CORES=4
DRY_RUN=false
FORCE=false

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")"

# Error handling
error_exit() {
    log "ERROR" "$1"
    exit 1
}

# Check if running on Proxmox
check_proxmox() {
    if ! command -v qm >/dev/null 2>&1; then
        error_exit "Proxmox VE is not installed or qm command not found"
    fi
    
    if ! systemctl is-active --quiet pve-cluster; then
        error_exit "Proxmox VE cluster service is not running"
    fi
}

# Check if template exists
check_template() {
    if ! qm status $TEMPLATE_VMID >/dev/null 2>&1; then
        error_exit "Template VM $TEMPLATE_VMID does not exist. Please create it first."
    fi
    
    # Check if it's actually a template
    if ! qm config $TEMPLATE_VMID | grep -q "template: 1"; then
        error_exit "VM $TEMPLATE_VMID exists but is not a template. Convert it with: qm template $TEMPLATE_VMID"
    fi
    
    log "INFO" "Template VM $TEMPLATE_VMID found and verified"
}

# Get available vGPU devices
get_vgpu_devices() {
    local vgpu_devices=()
    
    # Find available mdev devices
    if [[ -d "/sys/bus/mdev/devices" ]]; then
        for device in /sys/bus/mdev/devices/*; do
            if [[ -d "$device" ]]; then
                vgpu_devices+=($(basename "$device"))
            fi
        done
    fi
    
    if [[ ${#vgpu_devices[@]} -eq 0 ]]; then
        log "WARN" "No vGPU devices found. Workers will be created without GPU acceleration."
        log "WARN" "Make sure vGPU setup was completed and the system was rebooted."
    else
        log "INFO" "Found ${#vgpu_devices[@]} vGPU devices: ${vgpu_devices[*]}"
    fi
    
    echo "${vgpu_devices[@]}"
}

# Generate cloud-init configuration
generate_cloudinit_config() {
    local vmid="$1"
    local worker_id="$2"
    local config_file="/var/lib/vz/snippets/worker-${vmid}-cloudinit.yml"
    
    cat > "$config_file" << EOF
#cloud-config
hostname: cs2-worker-${worker_id}
timezone: UTC
users:
  - name: worker
    groups: administrators
    shell: cmd
    lock_passwd: false
    passwd: \$6\$rounds=4096\$salt\$hash  # Set proper password hash
write_files:
  - path: C:\\Windows\\Temp\\worker_config.json
    content: |
      {
        "worker_id": ${worker_id},
        "loadbalancer_url": "${LOADBALANCER_URL}",
        "cs2_repo": "https://github.com/your-org/cs2-worker-scripts.git",
        "startup_delay": $((worker_id * 30))
      }
    permissions: '0644'
  - path: C:\\Windows\\Temp\\bootstrap_worker.ps1
    content: |
$(cat "$SCRIPT_DIR/templates/bootstrap_worker.ps1" | sed 's/^/      /')
    permissions: '0755'
runcmd:
  - powershell.exe -ExecutionPolicy Bypass -File C:\\Windows\\Temp\\bootstrap_worker.ps1
  - sc.exe config "CS2Worker" start= auto
final_message: "CS2 Worker ${worker_id} cloud-init setup completed"
EOF
    
    echo "$config_file"
}

# Clone and configure worker VM
create_worker_vm() {
    local worker_id="$1"
    local vgpu_device="$2"
    local vmid=$((BASE_VMID + worker_id))
    local vm_name="cs2-worker-${worker_id}"
    
    log "INFO" "Creating worker VM $worker_id (VMID: $vmid, Name: $vm_name)..."
    
    # Check if VM already exists
    if qm status $vmid >/dev/null 2>&1; then
        if [[ "$FORCE" == "true" ]]; then
            log "WARN" "VM $vmid already exists, destroying and recreating..."
            qm stop $vmid || true
            sleep 5
            qm destroy $vmid || error_exit "Failed to destroy existing VM $vmid"
        else
            log "WARN" "VM $vmid already exists, skipping (use --force to recreate)"
            return 0
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "INFO" "DRY RUN: Would create VM $vmid with vGPU $vgpu_device"
        return 0
    fi
    
    # Clone template
    log "INFO" "Cloning template $TEMPLATE_VMID to VM $vmid..."
    qm clone $TEMPLATE_VMID $vmid \
        --name "$vm_name" \
        --full \
        --storage "$STORAGE" \
        || error_exit "Failed to clone template for worker $worker_id"
    
    # Configure VM settings
    log "INFO" "Configuring VM $vmid settings..."
    
    # Basic configuration
    qm set $vmid \
        --memory $MEMORY \
        --cores $CORES \
        --startup "order=$worker_id,up=60,down=30" \
        --description "CS2 Worker $worker_id - Auto-provisioned $(date)" \
        --tags "cs2,worker,auto-provisioned" \
        || error_exit "Failed to configure basic settings for VM $vmid"
    
    # Network configuration
    qm set $vmid \
        --ipconfig0 "ip=dhcp" \
        || log "WARN" "Failed to set network configuration for VM $vmid"
    
    # Assign vGPU if available
    if [[ -n "$vgpu_device" ]]; then
        log "INFO" "Assigning vGPU $vgpu_device to VM $vmid..."
        
        # Get the GPU PCI address
        local gpu_pci=$(lspci | grep -i nvidia | head -1 | cut -d' ' -f1)
        
        if [[ -n "$gpu_pci" ]]; then
            qm set $vmid --hostpci0 "${gpu_pci},mdev=${vgpu_device}" \
                || log "WARN" "Failed to assign vGPU $vgpu_device to VM $vmid"
        else
            log "WARN" "Could not determine GPU PCI address for vGPU assignment"
        fi
    else
        log "WARN" "No vGPU device available for worker $worker_id"
    fi
    
    # Generate and apply cloud-init configuration
    local cloudinit_config=$(generate_cloudinit_config "$vmid" "$worker_id")
    qm set $vmid --cicustom "user=local:snippets/$(basename "$cloudinit_config")" \
        || log "WARN" "Failed to set cloud-init configuration for VM $vmid"
    
    # Set boot order and enable qemu agent
    qm set $vmid \
        --boot "order=scsi0" \
        --agent enabled=1,fstrim_cloned_disks=1 \
        || log "WARN" "Failed to set boot configuration for VM $vmid"
    
    log "INFO" "Worker VM $worker_id created successfully (VMID: $vmid)"
}

# Start worker VMs with staggered startup
start_worker_vms() {
    local start_delay=30
    
    log "INFO" "Starting worker VMs with ${start_delay}s intervals..."
    
    for i in $(seq 1 $WORKERS); do
        local vmid=$((BASE_VMID + i))
        
        if ! qm status $vmid >/dev/null 2>&1; then
            log "WARN" "VM $vmid does not exist, skipping startup"
            continue
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "DRY RUN: Would start VM $vmid"
            continue
        fi
        
        log "INFO" "Starting worker VM $i (VMID: $vmid)..."
        
        qm start $vmid || {
            log "ERROR" "Failed to start VM $vmid"
            continue
        }
        
        # Wait between starts to avoid resource contention
        if [[ $i -lt $WORKERS ]]; then
            log "INFO" "Waiting ${start_delay}s before starting next VM..."
            sleep $start_delay
        fi
    done
    
    log "INFO" "All worker VMs start commands issued"
}

# Monitor worker VM status
monitor_workers() {
    local timeout=600  # 10 minutes
    local check_interval=30
    local elapsed=0
    
    log "INFO" "Monitoring worker VMs for ${timeout}s..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local running_count=0
        local ready_count=0
        
        for i in $(seq 1 $WORKERS); do
            local vmid=$((BASE_VMID + i))
            
            if ! qm status $vmid >/dev/null 2>&1; then
                continue
            fi
            
            local status=$(qm status $vmid | awk '{print $2}')
            
            if [[ "$status" == "running" ]]; then
                running_count=$((running_count + 1))
                
                # Check if qemu agent is responding
                if qm agent $vmid ping >/dev/null 2>&1; then
                    ready_count=$((ready_count + 1))
                fi
            fi
        done
        
        log "INFO" "Status: $running_count/$WORKERS running, $ready_count/$WORKERS ready"
        
        if [[ $ready_count -eq $WORKERS ]]; then
            log "INFO" "All worker VMs are running and ready!"
            return 0
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done
    
    log "WARN" "Timeout reached. Not all worker VMs are ready yet."
    return 1
}

# Cleanup function for interrupted provisioning
cleanup_workers() {
    log "INFO" "Cleaning up worker VMs..."
    
    for i in $(seq 1 $WORKERS); do
        local vmid=$((BASE_VMID + i))
        
        if qm status $vmid >/dev/null 2>&1; then
            log "INFO" "Stopping and removing VM $vmid..."
            qm stop $vmid || true
            sleep 5
            qm destroy $vmid || log "WARN" "Failed to destroy VM $vmid"
        fi
    done
    
    log "INFO" "Cleanup completed"
}

# Display worker status
show_status() {
    log "INFO" "Worker VM Status:"
    echo "----------------------------------------"
    printf "%-8s %-20s %-10s %-15s %-20s\n" "VMID" "Name" "Status" "IP Address" "vGPU"
    echo "----------------------------------------"
    
    for i in $(seq 1 $WORKERS); do
        local vmid=$((BASE_VMID + i))
        local name="cs2-worker-$i"
        local status="not-found"
        local ip="N/A"
        local vgpu="N/A"
        
        if qm status $vmid >/dev/null 2>&1; then
            status=$(qm status $vmid | awk '{print $2}')
            
            if [[ "$status" == "running" ]] && qm agent $vmid ping >/dev/null 2>&1; then
                ip=$(get_vm_ip $vmid 2>/dev/null || echo "pending")
            fi
            
            # Check for vGPU assignment
            if qm config $vmid | grep -q "hostpci"; then
                vgpu="assigned"
            fi
        fi
        
        printf "%-8s %-20s %-10s %-15s %-20s\n" "$vmid" "$name" "$status" "$ip" "$vgpu"
    done
    
    echo "----------------------------------------"
}

# Display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

Commands:
    provision               Provision worker VMs (default)
    start                   Start existing worker VMs
    stop                    Stop worker VMs
    status                  Show worker VM status
    cleanup                 Remove all worker VMs
    monitor                 Monitor worker VM startup

Options:
    --workers=N             Number of worker VMs (default: $DEFAULT_WORKERS)
    --loadbalancerurl=URL   Load balancer URL for worker registration
    --memory=MB             Memory per VM in MB (default: $MEMORY)
    --cores=N               CPU cores per VM (default: $CORES)
    --storage=STORAGE       Storage location (default: $STORAGE)
    --bridge=BRIDGE         Network bridge (default: $BRIDGE)
    --dry-run               Show what would be done without executing
    --force                 Force recreation of existing VMs
    --help                  Show this help message

Examples:
    $0 --workers=10 --loadbalancerurl=https://lb.example.com/api/register
    $0 --workers=5 --memory=16384 --cores=6
    $0 status
    $0 cleanup --force

EOF
}

# Parse command line arguments
parse_arguments() {
    local command="provision"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            provision|start|stop|status|cleanup|monitor)
                command="$1"
                ;;
            --workers=*)
                WORKERS="${1#*=}"
                if ! [[ "$WORKERS" =~ ^[0-9]+$ ]] || [[ "$WORKERS" -lt 1 ]] || [[ "$WORKERS" -gt 50 ]]; then
                    error_exit "Workers must be a number between 1 and 50"
                fi
                ;;
            --loadbalancerurl=*)
                LOADBALANCER_URL="${1#*=}"
                ;;
            --memory=*)
                MEMORY="${1#*=}"
                if ! [[ "$MEMORY" =~ ^[0-9]+$ ]]; then
                    error_exit "Memory must be a number (MB)"
                fi
                ;;
            --cores=*)
                CORES="${1#*=}"
                if ! [[ "$CORES" =~ ^[0-9]+$ ]]; then
                    error_exit "Cores must be a number"
                fi
                ;;
            --storage=*)
                STORAGE="${1#*=}"
                ;;
            --bridge=*)
                BRIDGE="${1#*=}"
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --force)
                FORCE=true
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
    
    echo "$command"
}

# Command implementations
cmd_provision() {
    log "INFO" "Starting worker VM provisioning..."
    log "INFO" "Configuration: Workers=$WORKERS, Memory=${MEMORY}MB, Cores=$CORES"
    
    # Pre-provisioning checks
    check_proxmox
    check_template
    
    # Get available vGPU devices
    local vgpu_devices=($(get_vgpu_devices))
    
    # Provision worker VMs
    for i in $(seq 1 $WORKERS); do
        local vgpu_device=""
        
        # Assign vGPU if available
        if [[ $i -le ${#vgpu_devices[@]} ]]; then
            vgpu_device="${vgpu_devices[$((i-1))]}"
        fi
        
        create_worker_vm "$i" "$vgpu_device"
    done
    
    # Start VMs if not dry run
    if [[ "$DRY_RUN" == "false" ]]; then
        start_worker_vms
        monitor_workers
        show_status
    fi
    
    log "INFO" "Worker VM provisioning completed!"
}

cmd_start() {
    log "INFO" "Starting worker VMs..."
    start_worker_vms
    monitor_workers
    show_status
}

cmd_stop() {
    log "INFO" "Stopping worker VMs..."
    
    for i in $(seq 1 $WORKERS); do
        local vmid=$((BASE_VMID + i))
        
        if qm status $vmid >/dev/null 2>&1; then
            local status=$(qm status $vmid | awk '{print $2}')
            
            if [[ "$status" == "running" ]]; then
                log "INFO" "Stopping VM $vmid..."
                qm stop $vmid || log "WARN" "Failed to stop VM $vmid"
            fi
        fi
    done
    
    log "INFO" "Stop commands issued for all worker VMs"
}

cmd_status() {
    show_status
}

cmd_cleanup() {
    if [[ "$FORCE" != "true" ]]; then
        echo -n "This will destroy all worker VMs. Are you sure? (y/N): "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log "INFO" "Cleanup cancelled"
            exit 0
        fi
    fi
    
    cleanup_workers
}

cmd_monitor() {
    monitor_workers
    show_status
}

# Main function
main() {
    local command=$(parse_arguments "$@")
    
    case "$command" in
        provision)
            cmd_provision
            ;;
        start)
            cmd_start
            ;;
        stop)
            cmd_stop
            ;;
        status)
            cmd_status
            ;;
        cleanup)
            cmd_cleanup
            ;;
        monitor)
            cmd_monitor
            ;;
        *)
            error_exit "Unknown command: $command"
            ;;
    esac
}

# Trap cleanup on exit
trap 'log "INFO" "Script interrupted"' INT TERM

# Run main function
main "$@"

exit 0
