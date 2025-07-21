#!/bin/bash

# Proxmox CS2 Worker Status and Health Check Script
# This script provides detailed status information and health checks

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

# System health check
check_system_health() {
    log "INFO" "Performing system health check..."
    
    local issues=()
    local warnings=()
    
    # Check Proxmox services
    if ! systemctl is-active --quiet pve-cluster; then
        issues+=("Proxmox cluster service not running")
    fi
    
    if ! systemctl is-active --quiet pvedaemon; then
        issues+=("Proxmox daemon not running")
    fi
    
    # Check NVIDIA driver
    if ! command_exists nvidia-smi; then
        issues+=("NVIDIA driver not installed or not in PATH")
    elif ! nvidia-smi >/dev/null 2>&1; then
        issues+=("NVIDIA driver not functioning properly")
    fi
    
    # Check vGPU devices
    local vgpu_count=$(ls /sys/bus/mdev/devices/ 2>/dev/null | wc -l)
    if [[ $vgpu_count -eq 0 ]]; then
        warnings+=("No vGPU devices found")
    fi
    
    # Check storage health
    local storage_usage=$(df /var/lib/vz | tail -1 | awk '{print $(NF-1)}' | sed 's/%//')
    if [[ $storage_usage -gt 90 ]]; then
        issues+=("Storage usage critical: ${storage_usage}%")
    elif [[ $storage_usage -gt 80 ]]; then
        warnings+=("Storage usage high: ${storage_usage}%")
    fi
    
    # Check memory usage
    local memory_usage=$(free | grep Mem | awk '{printf "%.0f", $3/$2 * 100.0}')
    if [[ $memory_usage -gt 95 ]]; then
        issues+=("Memory usage critical: ${memory_usage}%")
    elif [[ $memory_usage -gt 85 ]]; then
        warnings+=("Memory usage high: ${memory_usage}%")
    fi
    
    # Report results
    if [[ ${#issues[@]} -gt 0 ]]; then
        log "ERROR" "System health check found ${#issues[@]} critical issues:"
        for issue in "${issues[@]}"; do
            log "ERROR" "  - $issue"
        done
    fi
    
    if [[ ${#warnings[@]} -gt 0 ]]; then
        log "WARN" "System health check found ${#warnings[@]} warnings:"
        for warning in "${warnings[@]}"; do
            log "WARN" "  - $warning"
        done
    fi
    
    if [[ ${#issues[@]} -eq 0 && ${#warnings[@]} -eq 0 ]]; then
        log "SUCCESS" "System health check passed - no issues found"
        return 0
    elif [[ ${#issues[@]} -eq 0 ]]; then
        log "WARN" "System health check completed with warnings"
        return 1
    else
        log "ERROR" "System health check failed with critical issues"
        return 2
    fi
}

# GPU health check
check_gpu_health() {
    log "INFO" "Checking GPU health..."
    
    if ! command_exists nvidia-smi; then
        log "ERROR" "NVIDIA tools not available"
        return 1
    fi
    
    # Get GPU information
    local gpu_info=$(nvidia-smi --query-gpu=name,memory.total,memory.used,temperature.gpu,utilization.gpu,utilization.memory --format=csv,noheader,nounits)
    
    echo "GPU Status:"
    echo "==========="
    
    while IFS=, read -r name memory_total memory_used temp gpu_util mem_util; do
        echo "GPU: $name"
        echo "  Memory: ${memory_used}MB / ${memory_total}MB ($(( memory_used * 100 / memory_total ))%)"
        echo "  Temperature: ${temp}°C"
        echo "  GPU Utilization: ${gpu_util}%"
        echo "  Memory Utilization: ${mem_util}%"
        
        # Check for issues
        if [[ $temp -gt 85 ]]; then
            log "WARN" "GPU temperature high: ${temp}°C"
        fi
        
        if [[ $(( memory_used * 100 / memory_total )) -gt 95 ]]; then
            log "WARN" "GPU memory usage critical: $(( memory_used * 100 / memory_total ))%"
        fi
        
    done <<< "$gpu_info"
    
    # Check vGPU status
    echo
    echo "vGPU Devices:"
    echo "============="
    
    local vgpu_devices=($(ls /sys/bus/mdev/devices/ 2>/dev/null || true))
    
    if [[ ${#vgpu_devices[@]} -eq 0 ]]; then
        echo "No vGPU devices found"
        log "WARN" "No vGPU devices available for workers"
    else
        for device in "${vgpu_devices[@]}"; do
            echo "  Device: $device"
            
            # Check if device is assigned to a VM
            local assigned_vm=""
            for vmid in $(seq ${WORKER_BASE_VMID:-1000} $((${WORKER_BASE_VMID:-1000} + ${MAX_WORKERS:-20}))); do
                if vm_exists "$vmid" && qm config "$vmid" | grep -q "$device"; then
                    assigned_vm="VM $vmid"
                    break
                fi
            done
            
            if [[ -n "$assigned_vm" ]]; then
                echo "    Assigned to: $assigned_vm"
            else
                echo "    Status: Available"
            fi
        done
    fi
}

# Worker VM detailed status
check_worker_status() {
    log "INFO" "Checking worker VM status..."
    
    local total_workers=0
    local running_workers=0
    local healthy_workers=0
    local unhealthy_workers=0
    
    echo
    echo "Worker VM Status:"
    echo "================="
    
    {
        echo -e "VMID\tName\tStatus\tAgent\tIP\tvGPU\tMemory\tCPU\tUptime"
        
        for vmid in $(seq ${WORKER_BASE_VMID:-1000} $((${WORKER_BASE_VMID:-1000} + ${MAX_WORKERS:-20}))); do
            if vm_exists "$vmid"; then
                total_workers=$((total_workers + 1))
                
                local name=$(get_vm_config "$vmid" "name" || echo "VM-$vmid")
                local status=$(get_vm_status "$vmid")
                local agent_status="N/A"
                local ip="N/A"
                local vgpu="N/A"
                local memory="N/A"
                local cpu="N/A"
                local uptime="N/A"
                
                if [[ "$status" == "running" ]]; then
                    running_workers=$((running_workers + 1))
                    
                    # Check agent
                    if is_vm_agent_ready "$vmid"; then
                        agent_status="Ready"
                        
                        # Get IP address
                        ip=$(get_vm_ip "$vmid" 10 || echo "Unknown")
                        
                        # Get resource usage
                        local vm_stats=$(qm monitor "$vmid" --command "info status" 2>/dev/null || echo "")
                        if [[ -n "$vm_stats" ]]; then
                            memory=$(qm config "$vmid" | grep "^memory:" | cut -d':' -f2 | xargs)
                            cpu=$(qm config "$vmid" | grep "^cores:" | cut -d':' -f2 | xargs)
                        fi
                        
                        # Get uptime
                        uptime=$(qm agent "$vmid" exec -- powershell -Command "(Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime | ForEach-Object { '{0:dd}d {0:hh}h {0:mm}m' -f \$_ }" 2>/dev/null || echo "Unknown")
                        
                        healthy_workers=$((healthy_workers + 1))
                    else
                        agent_status="Not Ready"
                        unhealthy_workers=$((unhealthy_workers + 1))
                    fi
                else
                    unhealthy_workers=$((unhealthy_workers + 1))
                fi
                
                # Check vGPU assignment
                if qm config "$vmid" | grep -q "hostpci"; then
                    vgpu="Assigned"
                fi
                
                echo -e "$vmid\t$name\t$status\t$agent_status\t$ip\t$vgpu\t$memory\t$cpu\t$uptime"
            fi
        done
    } | display_table "VMID" "Name" "Status" "Agent" "IP" "vGPU" "Memory" "CPU" "Uptime"
    
    echo
    echo "Worker Summary:"
    echo "==============="
    echo "Total Workers: $total_workers"
    echo "Running: $running_workers"
    echo "Healthy: $healthy_workers"
    echo "Unhealthy: $unhealthy_workers"
    
    return $unhealthy_workers
}

# Network connectivity check
check_network_connectivity() {
    log "INFO" "Checking network connectivity..."
    
    local tests=(
        "google.com:External connectivity"
        "github.com:GitHub access"
    )
    
    if [[ -n "${DEFAULT_LOADBALANCER_URL:-}" ]]; then
        local lb_host=$(echo "$DEFAULT_LOADBALANCER_URL" | cut -d'/' -f3)
        tests+=("$lb_host:Load balancer")
    fi
    
    echo
    echo "Network Connectivity:"
    echo "===================="
    
    local failed_tests=0
    
    for test in "${tests[@]}"; do
        local host=$(echo "$test" | cut -d':' -f1)
        local description=$(echo "$test" | cut -d':' -f2)
        
        echo -n "Testing $description ($host)... "
        
        if test_network_connectivity "$host" 5; then
            echo -e "${GREEN}OK${NC}"
        else
            echo -e "${RED}FAILED${NC}"
            failed_tests=$((failed_tests + 1))
        fi
    done
    
    if [[ $failed_tests -eq 0 ]]; then
        log "SUCCESS" "All network connectivity tests passed"
    else
        log "WARN" "$failed_tests network connectivity tests failed"
    fi
    
    return $failed_tests
}

# Performance metrics
show_performance_metrics() {
    log "INFO" "Gathering performance metrics..."
    
    echo
    echo "System Performance:"
    echo "=================="
    
    # CPU usage
    echo "CPU Usage:"
    mpstat 1 1 | tail -1 | awk '{print "  User: " $3 "%, System: " $5 "%, Idle: " $12 "%"}'
    
    # Memory usage
    echo "Memory Usage:"
    free -h | grep "^Mem:" | awk '{print "  Used: " $3 " / " $2 " (" int($3/$2*100) "%)"}'
    
    # Storage usage
    echo "Storage Usage:"
    df -h /var/lib/vz | tail -1 | awk '{print "  Used: " $3 " / " $2 " (" $5 ")"}'
    
    # Load average
    echo "Load Average:"
    uptime | awk -F'load average:' '{print "  " $2}'
    
    # Network statistics
    echo "Network Statistics:"
    cat /proc/net/dev | grep -E "(eth0|ens|enp)" | head -1 | awk '{
        rx_bytes = $2; tx_bytes = $10
        printf "  RX: %.2f MB, TX: %.2f MB\n", rx_bytes/1024/1024, tx_bytes/1024/1024
    }'
    
    # GPU metrics if available
    if command_exists nvidia-smi; then
        echo "GPU Metrics:"
        nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits | \
        while IFS=, read -r gpu_util mem_util mem_used mem_total temp; do
            echo "  GPU Utilization: ${gpu_util}%, Memory: ${mem_used}MB/${mem_total}MB, Temp: ${temp}°C"
        done
    fi
}

# Generate status report
generate_report() {
    local output_file="${1:-/tmp/proxmox-cs2-status-$(date +%Y%m%d-%H%M%S).txt}"
    
    log "INFO" "Generating status report to $output_file..."
    
    {
        echo "Proxmox CS2 Worker Cluster Status Report"
        echo "========================================"
        echo "Generated: $(date)"
        echo "Host: $(hostname)"
        echo "Uptime: $(uptime -p)"
        echo
        
        echo "=== SYSTEM HEALTH ==="
        check_system_health
        echo
        
        echo "=== GPU HEALTH ==="
        check_gpu_health
        echo
        
        echo "=== WORKER STATUS ==="
        check_worker_status
        echo
        
        echo "=== NETWORK CONNECTIVITY ==="
        check_network_connectivity
        echo
        
        echo "=== PERFORMANCE METRICS ==="
        show_performance_metrics
        echo
        
        echo "=== SYSTEM INFORMATION ==="
        echo "Kernel: $(uname -r)"
        echo "Proxmox VE: $(pveversion | head -1)"
        echo "NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 2>/dev/null || echo 'Not available')"
        echo
        
    } > "$output_file"
    
    log "SUCCESS" "Status report generated: $output_file"
    echo "$output_file"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [command] [options]

Commands:
    health              Perform comprehensive health check
    gpu                 Check GPU and vGPU status
    workers             Check worker VM status
    network             Check network connectivity
    performance         Show performance metrics
    report [file]       Generate comprehensive status report
    monitor             Continuous monitoring mode

Examples:
    $0 health           # Full health check
    $0 gpu              # GPU status only
    $0 workers          # Worker status only
    $0 report           # Generate report to default location
    $0 report /tmp/status.txt  # Generate report to specific file

EOF
}

# Monitor mode
monitor_mode() {
    local refresh_interval=30
    
    log "INFO" "Starting continuous monitoring mode (refresh every ${refresh_interval}s)"
    log "INFO" "Press Ctrl+C to exit"
    
    while true; do
        clear
        echo "Proxmox CS2 Worker Cluster Monitor - $(date)"
        echo "============================================"
        
        check_system_health > /dev/null 2>&1
        local health_status=$?
        
        case $health_status in
            0) echo -e "Overall Health: ${GREEN}GOOD${NC}" ;;
            1) echo -e "Overall Health: ${YELLOW}WARNING${NC}" ;;
            *) echo -e "Overall Health: ${RED}CRITICAL${NC}" ;;
        esac
        
        echo
        check_worker_status
        
        echo
        show_performance_metrics
        
        echo
        echo "Next refresh in ${refresh_interval}s (Ctrl+C to exit)"
        
        sleep $refresh_interval
    done
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
        health)
            check_system_health
            check_gpu_health
            check_worker_status
            check_network_connectivity
            ;;
        gpu)
            check_gpu_health
            ;;
        workers)
            check_worker_status
            ;;
        network)
            check_network_connectivity
            ;;
        performance)
            show_performance_metrics
            ;;
        report)
            generate_report "$@"
            ;;
        monitor)
            monitor_mode
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
