# Proxmox Screenshot Worker Installer

**Fully automated Proxmox + Windows 11 VM installer with zero user interaction.**

This script automatically installs Proxmox on Ubuntu/Debian and creates multiple Windows 11 VMs that automatically download and execute your project on every boot.

## Features

- ✅ **Zero Interaction**: Completely automated installation
- ✅ **Proxmox Auto-Install**: Installs Proxmox VE if not present
- ✅ **Windows 11 VMs**: Creates multiple VMs with unattended installation
- ✅ **Auto-Start Project**: Downloads and runs your ZIP project on every boot
- ✅ **NAT Network**: Shared IP configuration (no public IP needed)
- ✅ **Memory Ballooning**: Dynamic RAM allocation
- ✅ **TPM 2.0 & Secure Boot**: Full Windows 11 compatibility

## Quick Start

### Option 1: One-Liner (Recommended)

```bash
wget -O /tmp/install.sh https://raw.githubusercontent.com/digitaltim-de/proxmox-installer/refs/heads/main/install-proxmox.sh && chmod +x /tmp/install.sh && /tmp/install.sh \
  --vms=4 \
  --ram=4096 \
  --start-zip="https://example.com/your-project.zip" \
  --start-file="scripts/start.ps1" \
  --key="YOUR-WIN11-KEY-1" \
  --key="YOUR-WIN11-KEY-2" \
  --key="YOUR-WIN11-KEY-3" \
  --key="YOUR-WIN11-KEY-4"
```

### Option 2: Download Script

```bash
sudo ./install-command.sh
```

## Parameters

| Parameter | Description | Example |
|-----------|-------------|---------|
| `--vms` | Number of VMs to create | `--vms=4` |
| `--ram` | RAM per VM in MB | `--ram=8192` |
| `--start-zip` | URL to your project ZIP | `--start-zip="https://github.com/user/project/archive/main.zip"` |
| `--start-file` | File to execute inside ZIP | `--start-file="scripts/start.ps1"` |
| `--key` | Windows 11 product key (one per VM) | `--key="XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"` |

## How It Works

1. **Proxmox Installation**: Automatically installs Proxmox VE on Ubuntu/Debian
2. **ISO Download**: Downloads Windows 11 and VirtIO driver ISOs
3. **VM Creation**: Creates VMs with proper Windows 11 requirements (TPM, Secure Boot, UEFI)
4. **Unattended Install**: Uses `Autounattend.xml` for zero-interaction Windows installation
5. **Auto-Execution**: PowerShell script runs your project on every boot

## Project Structure

Your ZIP file should contain the executable you want to run. For example:

```
project.zip
├── scripts/
│   └── start.ps1          # Your main script
├── data/
│   └── config.json
└── README.md
```

## Requirements

- **Host OS**: Ubuntu 18.04+ or Debian 10+
- **RAM**: Minimum 8GB (recommended 16GB+ for multiple VMs)
- **Storage**: 100GB+ free space
- **Network**: Internet connection for downloads
- **Privileges**: Must run as root (`sudo`)

## Windows VM Specifications

Each VM is configured with:
- **CPU**: 2 cores (host passthrough)
- **RAM**: Configurable (default 4GB) + ballooning
- **Storage**: 64GB virtual disk
- **Network**: VirtIO NAT (shared IP)
- **BIOS**: OVMF (UEFI)
- **TPM**: 2.0 enabled
- **Secure Boot**: Enabled
- **VirtIO**: Latest drivers included

## Troubleshooting

### Common Issues

**"Permission denied"**
```bash
sudo chmod +x install-command.sh
sudo ./install-command.sh
```

**"Proxmox installation failed"**
- Ensure you're running on Ubuntu/Debian
- Check internet connectivity
- Run with `sudo`

**"VM creation failed"**
- Verify sufficient disk space
- Check if VT-x/AMD-V is enabled in BIOS
- Ensure Windows 11 keys are valid

### Logs

Check installation logs:
```bash
tail -f /var/log/proxmox-installer.log
```

View VM console via Proxmox WebUI:
```
https://YOUR-SERVER-IP:8006
```

## Configuration Examples

### Basic Setup (4 VMs)
```bash
./install-proxmox.sh \
  --vms=4 \
  --ram=4096 \
  --start-zip="https://github.com/myuser/myproject/archive/main.zip" \
  --start-file="src/main.ps1" \
  --key="KEY1" --key="KEY2" --key="KEY3" --key="KEY4"
```

### High-Performance Setup (2 VMs with 8GB RAM each)
```bash
./install-proxmox.sh \
  --vms=2 \
  --ram=8192 \
  --start-zip="https://releases.myapp.com/v1.0.zip" \
  --start-file="bin/worker.ps1" \
  --key="PREMIUM-KEY-1" \
  --key="PREMIUM-KEY-2"
```

## Security Notes

- Windows VMs use NAT networking (no direct internet exposure)
- Default administrator password: `Password!` (change after installation)
- Firewall is enabled on VMs
- Auto-logon is enabled for automation purposes

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

MIT License - feel free to use and modify for your projects.

## Support

For issues and questions:
- Open an issue on GitHub
- Check the troubleshooting section above
- Review Proxmox logs for detailed error information

---

**Made for automated Windows 11 VM deployments** 🚀
