#!/usr/bin/env bash
set -euo pipefail

# =====================================
# Fully Automated Proxmox + Windows 11 VM Installer (with NAT + Auto-Start-ZIP)
# =====================================

# Paths and URLs
WINDOWS_ISO_PATH="/var/lib/vz/template/iso/Win11.iso"
VIRTIO_ISO_PATH="/var/lib/vz/template/iso/virtio-win.iso"
VIRTIO_ISO_URL="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"

# Variables
VMS=0
RAM=4096
START_ZIP=""
START_FILE=""
declare -a KEYS

LOG_FILE="/var/log/proxmox-installer.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
error() { echo "ERROR: $1" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $0 --vms=N --key=KEY [...] --start-zip=URL --start-file=PATH [--ram=MB]

Example:
  sudo $0 --vms=2 \\
    --key=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE \\
    --key=FFFFF-GGGGG-HHHHH-IIIII-JJJJJ \\
    --start-zip=https://example.com/setup.zip \\
    --start-file=myproject/scripts/start.ps1 \\
    --ram=8192
EOF
  exit 1
}

# Argument Parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vms=*) VMS="${1#*=}" ;;
    --ram=*) RAM="${1#*=}" ;;
    --key=*) KEYS+=("${1#*=}") ;;
    --start-zip=*) START_ZIP="${1#*=}" ;;
    --start-file=*) START_FILE="${1#*=}" ;;
    -h|--help) usage ;;
    *) error "Unknown option: $1" ;;
  esac
  shift
done

# Validation
[[ $EUID -eq 0 ]] || error "This script must be run as root"
((VMS > 0)) || error "--vms must be > 0"
[[ ${#KEYS[@]} -eq $VMS ]] || error "Number of keys (${#KEYS[@]}) must equal number of VMs ($VMS)"
[[ -n "$START_ZIP" ]] || error "--start-zip required"
[[ -n "$START_FILE" ]] || error "--start-file required"

# Ensure Proxmox repository always uses 'bookworm' for compatibility
DEBIAN_CODENAME="bookworm"

# Step 1: Install Proxmox on Ubuntu
# =====================================
if ! command -v pvesh >/dev/null; then
  log "Installing Proxmox on Ubuntu..."

  # Update system and install dependencies
  apt update
  apt install -y wget gnupg2 curl lsb-release software-properties-common genisoimage jq

  # Add Proxmox repository (always bookworm, never jammy/noble)
  wget -qO- "https://enterprise.proxmox.com/debian/proxmox-release-${DEBIAN_CODENAME}.gpg" \
    | gpg --dearmor > /etc/apt/trusted.gpg.d/proxmox-release.gpg
  echo "deb http://download.proxmox.com/debian/pve ${DEBIAN_CODENAME} pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-install.list

  # Update and upgrade without replacing the kernel
  apt update
  DEBIAN_FRONTEND=noninteractive apt full-upgrade -y --allow-downgrades || true

  # Install Proxmox VE without kernel replacement
  DEBIAN_FRONTEND=noninteractive apt install -y proxmox-ve postfix open-iscsi --no-install-recommends || true

  # Remove enterprise repository (no subscription)
  rm -f /etc/apt/sources.list.d/pve-enterprise.list || true

  # Start Proxmox services
  systemctl enable --now pvedaemon pveproxy pvestatd

  log "Proxmox installation completed on Ubuntu."
else
  log "Proxmox already installed, skipping..."
  # Ensure required tools are available
  command -v genisoimage >/dev/null || apt install -y genisoimage
  command -v jq >/dev/null || apt install -y jq
fi

# Step 2: Handle Windows ISO
# =====================================
log "Handling Windows ISO..."
mkdir -p "$(dirname "$WINDOWS_ISO_PATH")"
if [[ ! -f "$WINDOWS_ISO_PATH" ]]; then
  error "Windows 11 ISO not found at $WINDOWS_ISO_PATH. Please download it manually from https://www.microsoft.com/de-de/software-download/windows11 and place it there."
fi

# Step 3: Download VirtIO ISO
# =====================================
log "Downloading VirtIO ISO..."
[[ -f "$VIRTIO_ISO_PATH" ]] || wget -O "$VIRTIO_ISO_PATH" "$VIRTIO_ISO_URL"

# =====================================
# Function: Build Autounattend ISO
# =====================================
build_unattend_iso() {
  local vmid="$1" key="$2" vm_name="$3_tracking"
  local tmp="/tmp/autounattend-$vmid"
  mkdir -p "$tmp"

  # Generate Autounattend.xml
  cat > "$tmp/Autounattend.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <ProductKey><Key>$key</Key><WillShowUI>Never</WillShowUI></ProductKey>
        <AcceptEula>true</AcceptEula>
      </UserData>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 11 Pro</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>2</PartitionID></InstallTo>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><SkipUserOOBE>true</SkipUserOOBE></OOBE>
      <AutoLogon><Enabled>true</Enabled><LogonCount>9999</LogonCount><Username>Administrator</Username>
        <Password><Value>UABhAHMAcwB3ADAAcgBkACEA</Value><PlainText>false</PlainText></Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Download & Run Start ZIP</Description>
          <CommandLine>powershell.exe -ExecutionPolicy Bypass -Command "while (\$true) { try { Invoke-WebRequest '$START_ZIP' -OutFile 'C:\\\\setup.zip'; Expand-Archive 'C:\\\\setup.zip' -DestinationPath 'C:\\\\setup' -Force; & 'C:\\\\setup\\\\$START_FILE'; Start-Sleep 300 } catch { Start-Sleep 60 } }"</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF

  genisoimage -o "/var/lib/vz/template/iso/autounattend-$vmid.iso" -J -R -V "Autounattend" "$tmp"
  rm -rf "$tmp"
}

# =====================================
# Step 4: Create VMs
# =====================================
STORAGE="local-lvm"
if ! pvesm status --storage local-lvm &>/dev/null; then STORAGE="local"; fi

for i in $(seq 1 "$VMS"); do
  key="${KEYS[$((i-1))]}"
  vmid=$(pvesh get /cluster/nextid)
  name="win11-vm$i"
  log "Creating VM $i/$VMS ($name, VMID $vmid)"

  build_unattend_iso "$vmid" "$key" "$name"

  qm create "$vmid" --name "$name" --memory "$RAM" --cores 2 --sockets 1 --cpu host \
    --net0 virtio,bridge=vmbr0,firewall=1 --scsihw virtio-scsi-pci \
    --scsi0 "${STORAGE}:64" --boot order=scsi0 --ostype win11 \
    --agent enabled=1 --bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,format=raw" \
    --machine q35 --tpmstate0 "${STORAGE}:1,version=v2.0" \
    --balloon "$((RAM/2))" --audio0 device=ich9-intel-hda

  qm set "$vmid" --ide0 "local:iso/$(basename "$WINDOWS_ISO_PATH"),media=cdrom"
  qm set "$vmid" --ide1 "local:iso/autounattend-$vmid.iso,media=cdrom"
  qm set "$vmid" --ide2 "local:iso/$(basename "$VIRTIO_ISO_PATH"),media=cdrom"
done

# =====================================
# Step 5: Start all VMs
# =====================================
for i in $(seq 1 "$VMS"); do
  vmid=$(pvesh get /nodes/localhost/qemu --output-format json | jq -r ".[] | select(.name==\"win11-vm$i\") | .vmid")
  [[ -n "$vmid" ]] && { log "Starting VM win11-vm$i (ID: $vmid)"; qm start "$vmid"; sleep 5; }
done

log "Setup complete! Proxmox WebUI: https://$(hostname -I | awk '{print $1}'):8006"