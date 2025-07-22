#!/bin/bash
# Ultra-kurzer Proxmox Installer - einfach anpassen und copy-pasten!

wget -O /tmp/install.sh https://github.com/digitaltim-de/proxmox-installer/main/install-proxmox.sh && chmod +x /tmp/install.sh && /tmp/install.sh \
  --vms=4 \
  --ram=4096 \
  --start-zip="https://example.com/your-project.zip" \
  --start-file="scripts/start.ps1" \
  --key="1233-2131-131-31231" \
  --key="1231-312-31312-31231" \
  --key="31231-2313-2131-31231" \
  --key="3123-2133-2233-2133"