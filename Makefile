# Makefile for Proxmox CS2 Worker Cluster Management

.PHONY: help setup install provision status clean

# Default target
help:
	@echo "Proxmox CS2 Worker Cluster Management"
	@echo "====================================="
	@echo ""
	@echo "Available targets:"
	@echo "  setup      - Setup repository and check prerequisites"
	@echo "  install    - Install Proxmox VE with GPU support (requires sudo)"
	@echo "  provision  - Provision worker VMs (default: 5 workers)"
	@echo "  status     - Show cluster status and health"
	@echo "  monitor    - Start real-time monitoring"
	@echo "  scale      - Scale workers (use: make scale WORKERS=10)"
	@echo "  clean      - Clean up worker VMs"
	@echo "  logs       - View recent logs"
	@echo "  help       - Show this help message"
	@echo ""
	@echo "Configuration:"
	@echo "  WORKERS    - Number of workers (default: 5)"
	@echo "  CONFIG     - Configuration file (default: configs/local.conf)"
	@echo "  LB_URL     - Load balancer URL"
	@echo ""
	@echo "Examples:"
	@echo "  make setup"
	@echo "  make install WORKERS=10 LB_URL=https://lb.example.com/api"
	@echo "  make provision WORKERS=8"
	@echo "  make scale WORKERS=12"

# Configuration variables
WORKERS ?= 5
CONFIG ?= configs/local.conf
LB_URL ?= 
VERBOSE ?= 

# Setup repository and environment
setup:
	@echo "Setting up Proxmox CS2 Worker repository..."
	./setup.sh

# Install Proxmox VE with GPU support
install:
	@echo "Installing Proxmox VE with $(WORKERS) workers..."
	@if [ "$(LB_URL)" ]; then \
		sudo ./install_proxmox.sh --workers=$(WORKERS) --loadbalancerurl=$(LB_URL) $(if $(VERBOSE),--verbose); \
	else \
		sudo ./install_proxmox.sh --workers=$(WORKERS) $(if $(VERBOSE),--verbose); \
	fi

# Provision worker VMs
provision:
	@echo "Provisioning $(WORKERS) worker VMs..."
	@if [ "$(LB_URL)" ]; then \
		CONFIG_FILE=$(CONFIG) ./provision_workers.sh --workers=$(WORKERS) --loadbalancerurl=$(LB_URL); \
	else \
		CONFIG_FILE=$(CONFIG) ./provision_workers.sh --workers=$(WORKERS); \
	fi

# Show cluster status
status:
	@CONFIG_FILE=$(CONFIG) ./scripts/status.sh health

# Start real-time monitoring
monitor:
	@CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh monitor

# Scale workers
scale:
	@echo "Scaling to $(WORKERS) workers..."
	@CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh scale $(WORKERS)

# List workers
list:
	@CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh list

# Clean up all workers
clean:
	@echo "WARNING: This will destroy all worker VMs!"
	@read -p "Are you sure? (y/N): " confirm && [ "$$confirm" = "y" ] || exit 1
	@CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh cleanup --force

# View recent logs
logs:
	@echo "=== Installation Logs ==="
	@tail -n 50 /var/log/proxmox-install.log 2>/dev/null || echo "No installation logs found"
	@echo ""
	@echo "=== Worker Logs ==="
	@tail -n 50 /var/log/proxmox-workers.log 2>/dev/null || echo "No worker logs found"

# Generate status report
report:
	@CONFIG_FILE=$(CONFIG) ./scripts/status.sh report

# Restart all workers
restart-all:
	@echo "Restarting all worker VMs..."
	@CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh stop
	@sleep 10
	@CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh start

# Health check
health:
	@CONFIG_FILE=$(CONFIG) ./scripts/status.sh health

# Check GPU status
gpu:
	@CONFIG_FILE=$(CONFIG) ./scripts/status.sh gpu

# Check worker status
workers:
	@CONFIG_FILE=$(CONFIG) ./scripts/status.sh workers

# Development targets
dev-setup: setup
	@echo "Setting up development environment..."
	@if [ ! -f configs/dev.conf ]; then \
		cp configs/default.conf configs/dev.conf; \
		echo "Created configs/dev.conf for development"; \
	fi

# Test configuration
test-config:
	@echo "Testing configuration..."
	@if [ -f $(CONFIG) ]; then \
		echo "Configuration file $(CONFIG) exists"; \
		bash -n $(CONFIG) && echo "Configuration syntax OK" || echo "Configuration syntax ERROR"; \
	else \
		echo "Configuration file $(CONFIG) not found"; \
		exit 1; \
	fi

# Backup workers
backup:
	@echo "Creating backup of all worker VMs..."
	@for vmid in $$(seq 1001 1020); do \
		if qm status $$vmid >/dev/null 2>&1; then \
			echo "Backing up VM $$vmid..."; \
			CONFIG_FILE=$(CONFIG) ./scripts/manage_workers.sh backup $$vmid "Makefile backup $$(date +%Y%m%d-%H%M%S)"; \
		fi; \
	done

# Update repository
update:
	@echo "Updating repository..."
	@git pull origin main || echo "Not a git repository or no updates available"

# Show system information
info:
	@echo "System Information:"
	@echo "=================="
	@echo "Hostname: $$(hostname)"
	@echo "Uptime: $$(uptime -p 2>/dev/null || uptime)"
	@echo "Kernel: $$(uname -r)"
	@echo "Memory: $$(free -h | grep '^Mem:' | awk '{print $$3 "/" $$2}')"
	@echo "Storage: $$(df -h /var/lib/vz 2>/dev/null | tail -1 | awk '{print $$3 "/" $$2 " (" $$5 ")"}' || echo "N/A")"
	@if command -v nvidia-smi >/dev/null 2>&1; then \
		echo "GPU: $$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"; \
	else \
		echo "GPU: Not available"; \
	fi
	@if command -v pveversion >/dev/null 2>&1; then \
		echo "Proxmox: $$(pveversion | head -1)"; \
	else \
		echo "Proxmox: Not installed"; \
	fi
