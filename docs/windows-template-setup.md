# Windows 11 CS2 Worker Template Setup Guide

This guide provides detailed instructions for manually setting up the Windows 11 template VM that will be used for worker provisioning.

## Prerequisites

- Proxmox VE installed and running
- Windows 11 ISO uploaded to Proxmox storage
- Template VM created (VMID 9000) but not yet configured

## Step-by-Step Setup

### 1. Initial Windows 11 Installation

1. **Start the template VM**:
   ```bash
   qm start 9000
   ```

2. **Connect to VM console** via Proxmox web interface

3. **Install Windows 11**:
   - Follow the installation wizard
   - Choose "I don't have internet" when prompted for Microsoft account
   - Create local user account: `worker`
   - Set a secure password (you'll change this later)
   - Disable all privacy options and telemetry

### 2. Windows Configuration

#### 2.1 Disable Windows Updates
```powershell
# Open PowerShell as Administrator
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /t REG_DWORD /d 1 /f
```

#### 2.2 Configure Auto-Login
```powershell
# Enable automatic login
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d worker /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d YourSecurePassword /f
```

#### 2.3 Disable Sleep and Power Management
```powershell
# Disable sleep mode
powercfg -change -standby-timeout-ac 0
powercfg -change -standby-timeout-dc 0
powercfg -change -hibernate-timeout-ac 0
powercfg -change -hibernate-timeout-dc 0

# Set high performance power plan
powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
```

### 3. Software Installation

#### 3.1 Install Chocolatey Package Manager
```powershell
# Install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
```

#### 3.2 Install Required Software
```powershell
# Refresh environment
refreshenv

# Install essential tools
choco install -y python3 git 7zip curl wget

# Install C++ redistributables
choco install -y vcredist-all

# Install .NET Framework
choco install -y dotnet-runtime dotnet-sdk
```

#### 3.3 Install Steam
```powershell
# Download and install Steam
$steamUrl = "https://steamcdn-a.akamaihd.net/client/installer/SteamSetup.exe"
$steamInstaller = "$env:TEMP\SteamSetup.exe"

Invoke-WebRequest -Uri $steamUrl -OutFile $steamInstaller
Start-Process -FilePath $steamInstaller -ArgumentList "/S" -Wait

# Create Steam shortcut for easy access
$steamPath = "${env:ProgramFiles(x86)}\Steam\Steam.exe"
$desktopPath = [Environment]::GetFolderPath("Desktop")
$shortcut = (New-Object -comObject WScript.Shell).CreateShortcut("$desktopPath\Steam.lnk")
$shortcut.TargetPath = $steamPath
$shortcut.Save()
```

### 4. Steam Configuration

#### 4.1 Initial Steam Setup
1. Launch Steam from desktop shortcut
2. Create or log in with a dedicated Steam account for workers
3. Go to Steam Settings:
   - Interface: Disable "Run Steam when my computer starts"
   - Downloads: Set download region to closest location
   - In-Game: Disable Steam Overlay

#### 4.2 Install Counter-Strike 2
1. In Steam Library, search for "Counter-Strike 2"
2. Install the game (this will take a while depending on connection)
3. Once installed, launch CS2 once to complete initial setup
4. Close CS2 and Steam

#### 4.3 Configure Steam for Automation
```powershell
# Create Steam configuration for automated startup
$steamConfig = @"
"Steam"
{
    "AutoLaunchGameListOnStart"    "0"
    "BigPictureInForeground"       "0"
    "StartupMode"                  "0"
    "SkinV5"                       "1"
}
"@

$steamConfigPath = "${env:ProgramFiles(x86)}\Steam\config\config.vdf"
$steamConfig | Out-File -FilePath $steamConfigPath -Encoding UTF8
```

### 5. CS2 Configuration

#### 5.1 Create Autoexec Configuration
```powershell
# Create CS2 config directory
$cs2ConfigPath = "${env:ProgramFiles(x86)}\Steam\steamapps\common\Counter-Strike Global Offensive\game\csgo\cfg"
New-Item -ItemType Directory -Path $cs2ConfigPath -Force

# Create autoexec.cfg
$autoexecContent = @"
// CS2 Worker Autoexec Configuration
// Optimized for automated gameplay and performance

// Network settings
rate "128000"
cl_updaterate "128"
cl_cmdrate "128"
cl_interp "0"
cl_interp_ratio "1"

// Performance settings
fps_max "60"
mat_queue_mode "2"
r_dynamic "0"
r_drawtracers_firstperson "0"

// Audio settings
volume "0.1"
voice_enable "0"
windows_speaker_config "1"

// Video settings
mat_monitorgamma "1.6"
mat_monitorgamma_tv_enabled "0"

// Disable unnecessary features
cl_disablehtmlmotd "1"
cl_autohelp "0"
cl_showhelp "0"
gameinstructor_enable "0"

// Console and debugging
con_enable "1"
developer "1"
net_graph "1"

echo "CS2 Worker autoexec loaded successfully"
"@

$autoexecPath = "$cs2ConfigPath\autoexec.cfg"
$autoexecContent | Out-File -FilePath $autoexecPath -Encoding UTF8
```

### 6. Install Proxmox Guest Agent

#### 6.1 Download and Install QEMU Guest Agent
```powershell
# Download QEMU Guest Agent
$qemuAgentUrl = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
$qemuAgentPath = "$env:TEMP\qemu-ga-x86_64.msi"

# Note: In practice, download from Proxmox VE ISO or use chocolatey
choco install -y qemu-guest-agent

# Enable and start the service
Set-Service -Name "QEMU-GA" -StartupType Automatic
Start-Service -Name "QEMU-GA"
```

### 7. Worker Environment Setup

#### 7.1 Create Worker Directory Structure
```powershell
# Create worker directories
$workerPaths = @(
    "C:\CS2Worker",
    "C:\CS2Worker\logs",
    "C:\CS2Worker\config",
    "C:\CS2Worker\scripts",
    "C:\CS2Worker\temp"
)

foreach ($path in $workerPaths) {
    New-Item -ItemType Directory -Path $path -Force
}
```

#### 7.2 Configure Windows Services
```powershell
# Disable unnecessary services
$servicesToDisable = @(
    "WSearch",      # Windows Search
    "SysMain",      # Superfetch
    "Themes",       # Themes service
    "Spooler",      # Print Spooler
    "Fax"           # Fax service
)

foreach ($service in $servicesToDisable) {
    Set-Service -Name $service -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
}
```

### 8. Network and Security Configuration

#### 8.1 Configure Windows Firewall
```powershell
# Enable firewall but allow Steam and CS2
New-NetFirewallRule -DisplayName "Steam" -Direction Inbound -Program "${env:ProgramFiles(x86)}\Steam\Steam.exe" -Action Allow
New-NetFirewallRule -DisplayName "CS2" -Direction Inbound -Program "${env:ProgramFiles(x86)}\Steam\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe" -Action Allow

# Allow common ports
New-NetFirewallRule -DisplayName "Steam Ports" -Direction Inbound -Protocol TCP -LocalPort 27015,27036 -Action Allow
New-NetFirewallRule -DisplayName "Steam Ports UDP" -Direction Inbound -Protocol UDP -LocalPort 27015,27031-27036 -Action Allow
```

#### 8.2 Configure Windows Defender
```powershell
# Add exclusions for Steam and CS2
Add-MpPreference -ExclusionPath "${env:ProgramFiles(x86)}\Steam"
Add-MpPreference -ExclusionPath "C:\CS2Worker"

# Disable real-time protection (optional, for performance)
# Set-MpPreference -DisableRealtimeMonitoring $true
```

### 9. Performance Optimization

#### 9.1 Disable Visual Effects
```powershell
# Disable visual effects for performance
reg add "HKCU\Control Panel\Desktop" /v UserPreferencesMask /t REG_BINARY /d 9012038010000000 /f
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f
```

#### 9.2 Configure Virtual Memory
```powershell
# Set virtual memory to system managed
$cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges
$cs.AutomaticManagedPagefile = $true
$cs.Put()
```

### 10. Final Template Preparation

#### 10.1 Create Startup Script Location
```powershell
# Create directory for bootstrap script
New-Item -ItemType Directory -Path "C:\Windows\Temp" -Force

# Set permissions for worker scripts
icacls "C:\CS2Worker" /grant "worker:(OI)(CI)F" /T
icacls "C:\Windows\Temp" /grant "worker:(OI)(CI)F" /T
```

#### 10.2 Clean Up Installation
```powershell
# Clear temporary files
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear Windows Update cache
Remove-Item -Path "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue

# Clear event logs
wevtutil el | ForEach-Object { wevtutil cl $_ }

# Run disk cleanup
cleanmgr /sagerun:1
```

### 11. Convert to Template

#### 11.1 Final Shutdown
1. Ensure all software is properly installed and configured
2. Run Windows Update one final time (if desired)
3. Shut down the VM gracefully:
   ```powershell
   shutdown /s /t 0
   ```

#### 11.2 Convert to Template
```bash
# Wait for VM to be fully stopped
qm status 9000

# Convert to template
qm template 9000
```

## Verification Checklist

Before converting to template, verify:

- [ ] Windows 11 is fully installed and updated
- [ ] Auto-login is configured for 'worker' user
- [ ] Python 3.x is installed and in PATH
- [ ] Git is installed and functional
- [ ] Steam is installed and configured
- [ ] CS2 is installed and launches successfully
- [ ] QEMU Guest Agent is installed and running
- [ ] Windows Firewall is configured for Steam/CS2
- [ ] Power management is disabled
- [ ] Automatic Windows Updates are disabled
- [ ] All temporary files are cleaned up
- [ ] VM shuts down cleanly

## Troubleshooting

**Steam won't start automatically**:
- Check auto-login configuration
- Verify Steam shortcut in startup folder
- Check Windows services dependencies

**CS2 fails to launch**:
- Verify Steam is logged in
- Check CS2 installation integrity in Steam
- Review autoexec.cfg syntax
- Check available disk space

**QEMU Guest Agent not responding**:
- Verify service is running: `Get-Service QEMU-GA`
- Check Windows Firewall settings
- Restart the service: `Restart-Service QEMU-GA`

**Template conversion fails**:
- Ensure VM is completely stopped
- Check Proxmox storage availability
- Verify VM configuration is valid

## Notes

- Keep this template updated regularly with Windows updates and software updates
- Consider creating multiple template versions for different worker configurations
- Document any customizations made for your specific use case
- Test the template thoroughly before mass deployment
