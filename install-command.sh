#!/bin/bash
# Ultra-short Proxmox Installer - just adjust and copy-paste!

curl -s https://raw.githubusercontent.com/digitaltim-de/proxmox-installer/refs/heads/main/install-proxmox.sh | sudo bash -s -- \
  --vms=1 \
  --ram=4096 \
  --start-zip="https://yourzipfile.zip" \
  --start-file="start.ps1" \
  --key="1233-2131-131-31231"