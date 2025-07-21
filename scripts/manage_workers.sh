#!/bin/bash

# CS2 Worker Management Script
# This script provides various management operations for CS2 worker VMs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Configuration
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/../configs/default.conf"
CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"

# Load configuration
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Command functions
cmd_list() {
    log "INFO" "Listing CS2 worker VMs..."
    
    local workers_found=false
    
    echo -e "VMID\tName\tStatus\tMemory\tCores\tIP Address\tvGPU" | display_table "VMID" "Name" "Status" "Memory" "Cores" "IP Address" "vGPU"
    
    for vmid in $(seq ${WORKER_BASE_VMID:-1000} $((${WORKER_BASE_VMID:-1000} + ${MAX_WORKERS:-20}))); do
        if vm_exists "$vmid"; then
            workers_found=true
            local name=$(get_vm_config "$vmid" "name" || echo "unknown")
            local status=$(get_vm_status "$vmid")
            local memory=$(get_vm_config "$vmid" "memory" || echo "unknown")
            local cores=$(get_vm_config "$vmid" "cores" || echo "unknown")
            local ip="N/A"
            local vgpu="N/A"
            
            # Get IP if VM is running and agent is ready
            if [[ "$status" == "running" ]] && is_vm_agent_ready "$vmid"; then
                ip=$(get_vm_ip "$vmid" 10 || echo "pending")
            fi
            
            # Check for vGPU assignment
            if qm config "$vmid" | grep -q "hostpci"; then
                vgpu="assigned"
            fi
            
            echo -e "$vmid\t$name\t$status\t${memory}MB\t$cores\t$ip\t$vgpu"
        fi
    done | display_table "VMID" "Name" "Status" "Memory" "Cores" "IP Address" "vGPU"
    
    if [[ "$workers_found" == "false" ]]; then
        log "WARN" "No worker VMs found"
    fi
}

cmd_monitor() {
    local refresh_interval="${1:-10}"
    
    log "INFO" "Starting real-time monitoring (refresh every ${refresh_interval}s, press Ctrl+C to exit)..."
    
    while true; do
        clear
        echo "CS2 Worker Monitor - $(date)"
        echo "=================================="
        
        cmd_list
        
        echo
        echo "System Resources:"
        echo "-----------------"
        echo "Memory: $(free -h | grep '^Mem:' | awk '{print $3"/"$2}')"
        echo "CPU Load: $(uptime | awk -F'load average:' '{print $2}')"
        echo "Disk: $(df -h /var/lib/vz | tail -1 | awk '{print $3"/"$2" ("$5" used)"}')"
        
        echo
        echo "GPU Status:"
        echo "-----------"
        if command_exists nvidia-smi; then
            nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits | \
            while IFS=, read -r name memory_used memory_total gpu_util; do
                echo "GPU: $name - Memory: ${memory_used}MB/${memory_total}MB - Utilization: ${gpu_util}%"
            done
        else
            echo "NVIDIA drivers not available"
        fi
        
        echo
        echo "Press Ctrl+C to exit..."
        sleep "$refresh_interval"
    done
}

cmd_logs() {
    local vmid="$1"
    local lines="${2:-50}"
    
    if [[ -z "$vmid" ]]; then
        log "ERROR" "VM ID required for log viewing"
        return 1
    fi
    
    if ! vm_exists "$vmid"; then
        log "ERROR" "VM $vmid does not exist"
        return 1
    fi
    
    log "INFO" "Showing last $lines lines of logs for VM $vmid..."
    
    # Try to get logs from VM if agent is available
    if is_vm_agent_ready "$vmid"; then
        log "INFO" "Fetching logs from VM $vmid..."
        
        # Get Windows event logs related to our worker
        qm agent "$vmid" exec -- powershell -Command "Get-EventLog -LogName Application -Source 'CS2Worker' -Newest $lines | Format-Table -AutoSize" || \
        log "WARN" "Could not fetch application logs from VM $vmid"
        
        # Get bootstrap log if available
        qm agent "$vmid" exec -- powershell -Command "if (Test-Path 'C:\\Windows\\Temp\\bootstrap.log') { Get-Content 'C:\\Windows\\Temp\\bootstrap.log' -Tail $lines }" || \
        log "WARN" "Could not fetch bootstrap log from VM $vmid"
    else
        log "WARN" "VM $vmid agent not ready, showing host-side logs only"
    fi
    
    # Show host-side logs
    if [[ -f "/var/log/proxmox-workers.log" ]]; then
        log "INFO" "Host-side logs for VM $vmid:"
        grep "VM $vmid" /var/log/proxmox-workers.log | tail -"$lines" || true
    fi
}

cmd_restart() {
    local vmid="$1"
    local force="${2:-false}"
    
    if [[ -z "$vmid" ]]; then
        log "ERROR" "VM ID required for restart"
        return 1
    fi
    
    if ! vm_exists "$vmid"; then
        log "ERROR" "VM $vmid does not exist"
        return 1
    fi
    
    log "INFO" "Restarting VM $vmid..."
    
    local current_status=$(get_vm_status "$vmid")
    
    if [[ "$current_status" == "running" ]]; then
        if [[ "$force" == "true" ]]; then
            log "WARN" "Force stopping VM $vmid..."
            qm stop "$vmid" || log "ERROR" "Failed to stop VM $vmid"
        else
            log "INFO" "Gracefully shutting down VM $vmid..."
            qm shutdown "$vmid" || {
                log "WARN" "Graceful shutdown failed, force stopping..."
                qm stop "$vmid"
            }
        fi
        
        # Wait for VM to stop
        wait_for_vm_status "$vmid" "stopped" 60
    fi
    
    log "INFO" "Starting VM $vmid..."
    qm start "$vmid" || {
        log "ERROR" "Failed to start VM $vmid"
        return 1
    }
    
    wait_for_vm_agent "$vmid" 300
    log "SUCCESS" "VM $vmid restarted successfully"
}

cmd_scale() {
    local target_count="$1"
    
    if [[ -z "$target_count" ]]; then
        log "ERROR" "Target worker count required"
        return 1
    fi
    
    if ! [[ "$target_count" =~ ^[0-9]+$ ]] || [[ $target_count -lt 0 ]] || [[ $target_count -gt ${MAX_WORKERS:-20} ]]; then
        log "ERROR" "Invalid target count: $target_count (must be 0-${MAX_WORKERS:-20})"
        return 1
    fi
    
    # Count current workers
    local current_count=0
    for vmid in $(seq ${WORKER_BASE_VMID:-1000} $((${WORKER_BASE_VMID:-1000} + ${MAX_WORKERS:-20}))); do
        if vm_exists "$vmid"; then
            current_count=$((current_count + 1))
        fi
    done
    
    log "INFO" "Scaling workers from $current_count to $target_count..."
    
    if [[ $target_count -gt $current_count ]]; then
        # Scale up
        local workers_to_add=$((target_count - current_count))
        log "INFO" "Scaling up: adding $workers_to_add workers..."
        
        "$SCRIPT_DIR/../provision_workers.sh" --workers="$workers_to_add"
        
    elif [[ $target_count -lt $current_count ]]; then
        # Scale down
        local workers_to_remove=$((current_count - target_count))
        log "INFO" "Scaling down: removing $workers_to_remove workers..."
        
        # Remove workers from the end
        local removed=0
        for vmid in $(seq $((${WORKER_BASE_VMID:-1000} + ${MAX_WORKERS:-20})) -1 ${WORKER_BASE_VMID:-1000}); do
            if vm_exists "$vmid" && [[ $removed -lt $workers_to_remove ]]; then
                log "INFO" "Removing worker VM $vmid..."
                
                # Stop VM gracefully
                if [[ "$(get_vm_status "$vmid")" == "running" ]]; then
                    qm shutdown "$vmid" || qm stop "$vmid"
                    wait_for_vm_status "$vmid" "stopped" 60
                fi
                
                # Destroy VM
                qm destroy "$vmid" || log "ERROR" "Failed to destroy VM $vmid"
                
                removed=$((removed + 1))
            fi
        done
        
    else
        log "INFO" "Already at target count of $target_count workers"
    fi
    
    log "SUCCESS" "Scaling operation completed"
}

cmd_health() {
    log "INFO" "Performing health check on all worker VMs..."
    
    local healthy_count=0
    local unhealthy_count=0
    local total_count=0
    
    for vmid in $(seq ${WORKER_BASE_VMID:-1000} $((${WORKER_BASE_VMID:-1000} + ${MAX_WORKERS:-20}))); do
        if vm_exists "$vmid"; then
            total_count=$((total_count + 1))
            
            local status=$(get_vm_status "$vmid")
            local name=$(get_vm_config "$vmid" "name" || echo "VM-$vmid")
            
            echo -n "Checking $name (VM $vmid)... "
            
            if [[ "$status" == "running" ]]; then
                if is_vm_agent_ready "$vmid"; then
                    # Check if CS2 process is running
                    local cs2_running=$(qm agent "$vmid" exec -- powershell -Command "Get-Process -Name 'cs2' -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count" 2>/dev/null || echo "0")
                    
                    if [[ "$cs2_running" -gt 0 ]]; then
                        echo -e "${GREEN}HEALTHY${NC} (CS2 running)"
                        healthy_count=$((healthy_count + 1))
                    else
                        echo -e "${YELLOW}DEGRADED${NC} (CS2 not running)"
                        unhealthy_count=$((unhealthy_count + 1))
                    fi
                else
                    echo -e "${RED}UNHEALTHY${NC} (agent not responding)"
                    unhealthy_count=$((unhealthy_count + 1))
                fi
            else
                echo -e "${RED}UNHEALTHY${NC} (VM not running)"
                unhealthy_count=$((unhealthy_count + 1))
            fi
        fi
    done
    
    echo
    echo "Health Check Summary:"
    echo "===================="
    echo "Total Workers: $total_count"
    echo "Healthy: $healthy_count"
    echo "Unhealthy: $unhealthy_count"
    
    if [[ $unhealthy_count -eq 0 ]]; then
        log "SUCCESS" "All workers are healthy"
        return 0
    else
        log "WARN" "$unhealthy_count workers are unhealthy"
        return 1
    fi
}

cmd_backup() {
    local vmid="$1"
    local backup_note="${2:-Manual backup}"
    
    if [[ -z "$vmid" ]]; then
        log "ERROR" "VM ID required for backup"
        return 1
    fi
    
    if ! vm_exists "$vmid"; then
        log "ERROR" "VM $vmid does not exist"
        return 1
    fi
    
    log "INFO" "Creating backup of VM $vmid..."
    
    # Create backup
    local backup_job_id=$(vzdump "$vmid" --mode snapshot --compress gzip --notes "$backup_note" 2>&1 | grep -o 'INFO: Starting Backup of VM [0-9]*' | grep -o '[0-9]*' || echo "")
    
    if [[ -n "$backup_job_id" ]]; then
        log "SUCCESS" "Backup of VM $vmid completed"
    else
        log "ERROR" "Backup of VM $vmid failed"
        return 1
    fi
}

# Usage information
usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    list                    List all worker VMs with status
    monitor [interval]      Real-time monitoring (default: 10s refresh)
    logs <vmid> [lines]     Show logs for specific VM (default: 50 lines)
    restart <vmid> [force]  Restart specific VM (force=true for hard restart)
    scale <count>           Scale workers to specific count
    health                  Perform health check on all workers
    backup <vmid> [note]    Create backup of specific VM

Examples:
    $0 list
    $0 monitor 5
    $0 logs 1001 100
    $0 restart 1001 force
    $0 scale 10
    $0 health
    $0 backup 1001 "Before update"

Configuration:
    Use CONFIG_FILE environment variable to specify custom config file
    Default: $DEFAULT_CONFIG_FILE

EOF
}

# Main function
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi
    
    local command="$1"
    shift
    
    case "$command" in
        list)
            cmd_list "$@"
            ;;
        monitor)
            cmd_monitor "$@"
            ;;
        logs)
            cmd_logs "$@"
            ;;
        restart)
            cmd_restart "$@"
            ;;
        scale)
            cmd_scale "$@"
            ;;
        health)
            cmd_health "$@"
            ;;
        backup)
            cmd_backup "$@"
            ;;
        help|--help)
            usage
            ;;
        *)
            log "ERROR" "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Check if running on Proxmox
if ! is_proxmox; then
    log "ERROR" "This script must be run on a Proxmox VE host"
    exit 1
fi

# Run main function
main "$@"
