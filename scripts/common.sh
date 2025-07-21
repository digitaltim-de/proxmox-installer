#!/bin/bash

# Common functions for Proxmox CS2 worker management
# This library provides shared functionality across all scripts

# Color codes for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global configuration
COMMON_LOG_FILE="/var/log/proxmox-workers.log"
VERBOSE=${VERBOSE:-false}

# Ensure log directory exists
mkdir -p "$(dirname "$COMMON_LOG_FILE")"

# Enhanced logging function with levels and timestamps
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local caller="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"
    
    # Format log entry
    local log_entry="[$timestamp] [$level] [$caller] $message"
    
    # Console output with colors
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
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} $message"
            fi
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        "FAIL")
            echo -e "${RED}[FAIL]${NC} $message"
            ;;
    esac
    
    # Write to log file if writable
    if [[ -w "$COMMON_LOG_FILE" ]] || [[ -w "$(dirname "$COMMON_LOG_FILE")" ]]; then
        echo "$log_entry" >> "$COMMON_LOG_FILE"
    fi
}

# Progress indicator for long-running operations
show_progress() {
    local duration="$1"
    local message="$2"
    local interval=1
    local elapsed=0
    
    echo -n "$message"
    
    while [[ $elapsed -lt $duration ]]; do
        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo " done"
}

# Spinner for indefinite operations
show_spinner() {
    local pid=$1
    local message="$2"
    local spin='-\|/'
    local i=0
    
    echo -n "$message "
    
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r$message ${spin:$i:1}"
        sleep 0.1
    done
    
    printf "\r$message done\n"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if we're running on Proxmox VE
is_proxmox() {
    [[ -f /etc/pve/local/pve-ssl.pem ]] && command_exists qm
}

# Check if VM exists
vm_exists() {
    local vmid="$1"
    qm status "$vmid" >/dev/null 2>&1
}

# Get VM status
get_vm_status() {
    local vmid="$1"
    
    if ! vm_exists "$vmid"; then
        echo "not-found"
        return 1
    fi
    
    qm status "$vmid" | awk '{print $2}'
}

# Check if VM is running
is_vm_running() {
    local vmid="$1"
    [[ "$(get_vm_status "$vmid")" == "running" ]]
}

# Check if VM has qemu agent responding
is_vm_agent_ready() {
    local vmid="$1"
    qm agent "$vmid" ping >/dev/null 2>&1
}

# Wait for VM to reach specific status
wait_for_vm_status() {
    local vmid="$1"
    local expected_status="$2"
    local timeout="${3:-300}"
    local check_interval="${4:-5}"
    local elapsed=0
    
    log "INFO" "Waiting for VM $vmid to reach status '$expected_status' (timeout: ${timeout}s)..."
    
    while [[ $elapsed -lt $timeout ]]; do
        local current_status=$(get_vm_status "$vmid")
        
        if [[ "$current_status" == "$expected_status" ]]; then
            log "SUCCESS" "VM $vmid reached status '$expected_status'"
            return 0
        fi
        
        if [[ "$current_status" == "not-found" ]]; then
            log "ERROR" "VM $vmid does not exist"
            return 1
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        if [[ $((elapsed % 30)) -eq 0 ]]; then
            log "DEBUG" "VM $vmid status: $current_status (waiting for $expected_status)"
        fi
    done
    
    log "ERROR" "Timeout waiting for VM $vmid to reach status '$expected_status'"
    return 1
}

# Wait for VM qemu agent to be ready
wait_for_vm_agent() {
    local vmid="$1"
    local timeout="${2:-300}"
    local check_interval="${3:-10}"
    local elapsed=0
    
    log "INFO" "Waiting for VM $vmid qemu agent to be ready (timeout: ${timeout}s)..."
    
    # First wait for VM to be running
    if ! wait_for_vm_status "$vmid" "running" 60; then
        log "ERROR" "VM $vmid is not running, cannot check agent"
        return 1
    fi
    
    while [[ $elapsed -lt $timeout ]]; do
        if is_vm_agent_ready "$vmid"; then
            log "SUCCESS" "VM $vmid qemu agent is ready"
            return 0
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        if [[ $((elapsed % 60)) -eq 0 ]]; then
            log "DEBUG" "Still waiting for VM $vmid qemu agent..."
        fi
    done
    
    log "ERROR" "Timeout waiting for VM $vmid qemu agent"
    return 1
}

# Get VM IP address
get_vm_ip() {
    local vmid="$1"
    local timeout="${2:-60}"
    local elapsed=0
    
    if ! is_vm_agent_ready "$vmid"; then
        log "DEBUG" "VM $vmid agent not ready, cannot get IP"
        return 1
    fi
    
    while [[ $elapsed -lt $timeout ]]; do
        local ip=$(qm agent "$vmid" network-get-interfaces 2>/dev/null | \
                  jq -r '.[] | select(.name=="Ethernet" or .name=="eth0") | .["ip-addresses"][]? | select(.["ip-address-type"]=="ipv4" and (.["ip-address"] | test("^192\\.|^10\\.|^172\\."))) | .["ip-address"]' 2>/dev/null | \
                  head -1)
        
        if [[ -n "$ip" && "$ip" != "null" ]]; then
            echo "$ip"
            return 0
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
    done
    
    log "DEBUG" "Could not determine IP for VM $vmid"
    return 1
}

# Get VM configuration value
get_vm_config() {
    local vmid="$1"
    local key="$2"
    
    if ! vm_exists "$vmid"; then
        return 1
    fi
    
    qm config "$vmid" | grep "^${key}:" | cut -d':' -f2- | sed 's/^ *//'
}

# Check if VM is a template
is_vm_template() {
    local vmid="$1"
    [[ "$(get_vm_config "$vmid" "template")" == "1" ]]
}

# Get available storage pools
get_storage_pools() {
    pvesm status | tail -n +2 | awk '{print $1}' | sort
}

# Check if storage pool exists
storage_exists() {
    local storage="$1"
    pvesm status | grep -q "^${storage} "
}

# Get available VM IDs in range
get_available_vmids() {
    local start_range="${1:-100}"
    local end_range="${2:-999}"
    local count="${3:-10}"
    
    local available_ids=()
    
    for vmid in $(seq $start_range $end_range); do
        if ! vm_exists "$vmid"; then
            available_ids+=("$vmid")
            
            if [[ ${#available_ids[@]} -ge $count ]]; then
                break
            fi
        fi
    done
    
    echo "${available_ids[@]}"
}

# Validate VM configuration parameters
validate_vm_config() {
    local memory="$1"
    local cores="$2"
    local storage="$3"
    
    # Validate memory (must be numeric and reasonable)
    if ! [[ "$memory" =~ ^[0-9]+$ ]] || [[ $memory -lt 512 ]] || [[ $memory -gt 131072 ]]; then
        log "ERROR" "Invalid memory value: $memory (must be 512-131072 MB)"
        return 1
    fi
    
    # Validate cores (must be numeric and reasonable)
    if ! [[ "$cores" =~ ^[0-9]+$ ]] || [[ $cores -lt 1 ]] || [[ $cores -gt 64 ]]; then
        log "ERROR" "Invalid cores value: $cores (must be 1-64)"
        return 1
    fi
    
    # Validate storage exists
    if ! storage_exists "$storage"; then
        log "ERROR" "Storage pool '$storage' does not exist"
        return 1
    fi
    
    return 0
}

# Generate random password
generate_password() {
    local length="${1:-16}"
    tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c "$length"
}

# Create cloud-init user data
create_cloudinit_userdata() {
    local output_file="$1"
    local hostname="$2"
    local username="${3:-worker}"
    local ssh_keys="$4"
    
    cat > "$output_file" << EOF
#cloud-config
hostname: $hostname
manage_etc_hosts: true
users:
  - name: $username
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
$(if [[ -n "$ssh_keys" ]]; then
    echo "    ssh_authorized_keys:"
    echo "$ssh_keys" | while read -r key; do
        echo "      - $key"
    done
fi)

package_update: true
package_upgrade: false

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent

final_message: "Cloud-init setup completed"
EOF
}

# Network connectivity test
test_network_connectivity() {
    local host="${1:-google.com}"
    local timeout="${2:-5}"
    
    if command_exists ping; then
        ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1
    elif command_exists curl; then
        curl -s --max-time "$timeout" "http://$host" >/dev/null 2>&1
    elif command_exists wget; then
        wget -q --timeout="$timeout" --spider "http://$host" >/dev/null 2>&1
    else
        log "WARN" "No network testing tools available"
        return 1
    fi
}

# System resource check
check_system_resources() {
    local min_memory_gb="${1:-8}"
    local min_disk_gb="${2:-50}"
    
    local errors=()
    
    # Check available memory
    local total_memory_gb=$(free -g | awk '/^Mem:/{print $2}')
    if [[ $total_memory_gb -lt $min_memory_gb ]]; then
        errors+=("Insufficient memory: ${total_memory_gb}GB available, ${min_memory_gb}GB required")
    fi
    
    # Check available disk space for VM storage
    local available_space_gb=$(df /var/lib/vz 2>/dev/null | tail -1 | awk '{print int($4/1024/1024)}')
    if [[ -n "$available_space_gb" && $available_space_gb -lt $min_disk_gb ]]; then
        errors+=("Insufficient disk space: ${available_space_gb}GB available, ${min_disk_gb}GB required")
    fi
    
    # Check CPU virtualization support
    if ! grep -q -E "(vmx|svm)" /proc/cpuinfo; then
        errors+=("CPU does not support hardware virtualization")
    fi
    
    if [[ ${#errors[@]} -gt 0 ]]; then
        log "ERROR" "System resource check failed:"
        for error in "${errors[@]}"; do
            log "ERROR" "  - $error"
        done
        return 1
    fi
    
    log "SUCCESS" "System resource check passed"
    return 0
}

# Cleanup function for interrupted operations
cleanup_on_interrupt() {
    local cleanup_function="$1"
    
    trap "$cleanup_function" INT TERM EXIT
}

# Parse configuration file
parse_config_file() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        log "ERROR" "Configuration file not found: $config_file"
        return 1
    fi
    
    # Source the configuration file safely
    if bash -n "$config_file" 2>/dev/null; then
        source "$config_file"
        log "DEBUG" "Configuration loaded from $config_file"
    else
        log "ERROR" "Invalid configuration file syntax: $config_file"
        return 1
    fi
}

# Create backup of VM configuration
backup_vm_config() {
    local vmid="$1"
    local backup_dir="${2:-/var/backups/vm-configs}"
    
    if ! vm_exists "$vmid"; then
        log "ERROR" "VM $vmid does not exist"
        return 1
    fi
    
    mkdir -p "$backup_dir"
    
    local backup_file="$backup_dir/vm-${vmid}-$(date +%Y%m%d-%H%M%S).conf"
    
    qm config "$vmid" > "$backup_file"
    
    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "VM $vmid configuration backed up to $backup_file"
        echo "$backup_file"
    else
        log "ERROR" "Failed to backup VM $vmid configuration"
        return 1
    fi
}

# Retry function for unreliable operations
retry() {
    local max_attempts="$1"
    local delay="$2"
    shift 2
    local command=("$@")
    
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        log "DEBUG" "Attempt $attempt/$max_attempts: ${command[*]}"
        
        if "${command[@]}"; then
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            log "WARN" "Command failed, retrying in ${delay}s..."
            sleep "$delay"
        fi
        
        attempt=$((attempt + 1))
    done
    
    log "ERROR" "Command failed after $max_attempts attempts: ${command[*]}"
    return 1
}

# Display formatted table
display_table() {
    local headers=("$@")
    local data_file="/tmp/table_data_$$"
    
    # Read data from stdin
    cat > "$data_file"
    
    # Calculate column widths
    local col_widths=()
    local num_cols=${#headers[@]}
    
    # Initialize with header lengths
    for ((i=0; i<num_cols; i++)); do
        col_widths[i]=${#headers[i]}
    done
    
    # Check data for wider columns
    while IFS=$'\t' read -r -a row; do
        for ((i=0; i<num_cols && i<${#row[@]}; i++)); do
            if [[ ${#row[i]} -gt ${col_widths[i]} ]]; then
                col_widths[i]=${#row[i]}
            fi
        done
    done < "$data_file"
    
    # Print header
    printf "+"
    for width in "${col_widths[@]}"; do
        printf "%*s+" $((width + 2)) "" | tr ' ' '-'
    done
    echo
    
    printf "|"
    for ((i=0; i<num_cols; i++)); do
        printf " %-*s |" "${col_widths[i]}" "${headers[i]}"
    done
    echo
    
    printf "+"
    for width in "${col_widths[@]}"; do
        printf "%*s+" $((width + 2)) "" | tr ' ' '-'
    done
    echo
    
    # Print data
    while IFS=$'\t' read -r -a row; do
        printf "|"
        for ((i=0; i<num_cols; i++)); do
            local value="${row[i]:-}"
            printf " %-*s |" "${col_widths[i]}" "$value"
        done
        echo
    done < "$data_file"
    
    printf "+"
    for width in "${col_widths[@]}"; do
        printf "%*s+" $((width + 2)) "" | tr ' ' '-'
    done
    echo
    
    rm -f "$data_file"
}

# Export functions for use in other scripts
export -f log show_progress show_spinner command_exists is_proxmox
export -f vm_exists get_vm_status is_vm_running is_vm_agent_ready
export -f wait_for_vm_status wait_for_vm_agent get_vm_ip get_vm_config
export -f is_vm_template get_storage_pools storage_exists get_available_vmids
export -f validate_vm_config generate_password create_cloudinit_userdata
export -f test_network_connectivity check_system_resources cleanup_on_interrupt
export -f parse_config_file backup_vm_config retry display_table
