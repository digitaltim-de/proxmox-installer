# CS2 Worker Bootstrap Script
# This script runs on Windows 11 VMs to setup and launch CS2 client
# It configures the worker environment and registers with the load balancer

param(
    [string]$ConfigFile = "C:\Windows\Temp\worker_config.json",
    [string]$LogFile = "C:\Windows\Temp\bootstrap.log",
    [switch]$Verbose
)

# Global configuration
$ErrorActionPreference = "Continue"
$VerbosePreference = if ($Verbose) { "Continue" } else { "SilentlyContinue" }

# Worker configuration (loaded from config file)
$WorkerConfig = @{
    WorkerId = 1
    LoadBalancerUrl = ""
    CS2RepoUrl = "https://github.com/your-org/cs2-worker-scripts.git"
    StartupDelay = 0
    CS2InstallPath = "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"
    WorkerDataPath = "C:\CS2Worker"
    MaxRetries = 3
    HealthCheckInterval = 30
}

# Logging function
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console with colors
    switch ($Level) {
        "INFO"  { Write-Host $logEntry -ForegroundColor Green }
        "WARN"  { Write-Host $logEntry -ForegroundColor Yellow }
        "ERROR" { Write-Host $logEntry -ForegroundColor Red }
        "DEBUG" { if ($Verbose) { Write-Host $logEntry -ForegroundColor Blue } }
    }
    
    # Write to log file
    try {
        Add-Content -Path $LogFile -Value $logEntry -Force
    }
    catch {
        Write-Host "Failed to write to log file: $_" -ForegroundColor Red
    }
}

# Error handling
function Handle-Error {
    param(
        [string]$ErrorMessage,
        [bool]$Fatal = $false
    )
    
    Write-Log -Message $ErrorMessage -Level "ERROR"
    
    if ($Fatal) {
        Write-Log -Message "Fatal error encountered. Exiting." -Level "ERROR"
        exit 1
    }
}

# Load worker configuration
function Load-WorkerConfig {
    Write-Log -Message "Loading worker configuration from $ConfigFile" -Level "DEBUG"
    
    if (Test-Path $ConfigFile) {
        try {
            $config = Get-Content $ConfigFile | ConvertFrom-Json
            
            $script:WorkerConfig.WorkerId = $config.worker_id
            $script:WorkerConfig.LoadBalancerUrl = $config.loadbalancer_url
            $script:WorkerConfig.CS2RepoUrl = $config.cs2_repo
            $script:WorkerConfig.StartupDelay = $config.startup_delay
            
            Write-Log -Message "Configuration loaded: Worker ID $($WorkerConfig.WorkerId)"
        }
        catch {
            Handle-Error -ErrorMessage "Failed to load configuration: $_" -Fatal $false
        }
    }
    else {
        Write-Log -Message "Configuration file not found, using defaults" -Level "WARN"
    }
}

# Check prerequisites
function Test-Prerequisites {
    Write-Log -Message "Checking prerequisites..."
    
    $checks = @(
        @{ Name = "Python"; Command = "python --version" },
        @{ Name = "Git"; Command = "git --version" },
        @{ Name = "Steam"; Path = "C:\Program Files (x86)\Steam\Steam.exe" }
    )
    
    $allPassed = $true
    
    foreach ($check in $checks) {
        if ($check.Command) {
            try {
                $null = Invoke-Expression $check.Command
                Write-Log -Message "$($check.Name) is available"
            }
            catch {
                Write-Log -Message "$($check.Name) is not available or not in PATH" -Level "WARN"
                $allPassed = $false
            }
        }
        elseif ($check.Path) {
            if (Test-Path $check.Path) {
                Write-Log -Message "$($check.Name) is installed"
            }
            else {
                Write-Log -Message "$($check.Name) is not installed at expected location" -Level "WARN"
                $allPassed = $false
            }
        }
    }
    
    return $allPassed
}

# Install missing dependencies
function Install-Dependencies {
    Write-Log -Message "Installing missing dependencies..."
    
    # Install Chocolatey if not present
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Write-Log -Message "Installing Chocolatey package manager..."
        try {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))
        }
        catch {
            Handle-Error -ErrorMessage "Failed to install Chocolatey: $_"
            return $false
        }
    }
    
    # Install required packages
    $packages = @("python", "git")
    
    foreach ($package in $packages) {
        try {
            Write-Log -Message "Installing $package..."
            & choco install $package -y --force
        }
        catch {
            Handle-Error -ErrorMessage "Failed to install $package: $_"
        }
    }
    
    # Refresh environment variables
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    return $true
}

# Setup worker directory structure
function Initialize-WorkerEnvironment {
    Write-Log -Message "Initializing worker environment..."
    
    # Create worker data directory
    if (-not (Test-Path $WorkerConfig.WorkerDataPath)) {
        New-Item -ItemType Directory -Path $WorkerConfig.WorkerDataPath -Force | Out-Null
    }
    
    # Create subdirectories
    $subdirs = @("logs", "config", "scripts", "temp")
    foreach ($dir in $subdirs) {
        $path = Join-Path $WorkerConfig.WorkerDataPath $dir
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
    
    Write-Log -Message "Worker environment initialized at $($WorkerConfig.WorkerDataPath)"
}

# Clone or update CS2 repository
function Update-CS2Repository {
    Write-Log -Message "Updating CS2 repository..."
    
    $repoPath = Join-Path $WorkerConfig.WorkerDataPath "cs2-scripts"
    
    if (Test-Path $repoPath) {
        Write-Log -Message "Repository exists, pulling updates..."
        try {
            Set-Location $repoPath
            & git pull origin main
        }
        catch {
            Handle-Error -ErrorMessage "Failed to update repository: $_"
            return $false
        }
    }
    else {
        Write-Log -Message "Cloning repository from $($WorkerConfig.CS2RepoUrl)..."
        try {
            Set-Location $WorkerConfig.WorkerDataPath
            & git clone $WorkerConfig.CS2RepoUrl cs2-scripts
        }
        catch {
            Handle-Error -ErrorMessage "Failed to clone repository: $_"
            return $false
        }
    }
    
    return $true
}

# Configure CS2 launch parameters
function Configure-CS2Launch {
    Write-Log -Message "Configuring CS2 launch parameters..."
    
    $launchScript = Join-Path $WorkerConfig.WorkerDataPath "cs2-scripts\start.ps1"
    
    if (-not (Test-Path $launchScript)) {
        Write-Log -Message "Creating default CS2 launch script..." -Level "WARN"
        
        $defaultScript = @"
# CS2 Launch Script - Worker $($WorkerConfig.WorkerId)
# This script launches Counter-Strike 2 with appropriate parameters

`$steamPath = "C:\Program Files (x86)\Steam\Steam.exe"
`$cs2AppId = "730"

# CS2 launch parameters for automated gameplay
`$launchParams = @(
    "-applaunch `$cs2AppId",
    "-novid",                # Skip intro video
    "-nojoy",                # Disable joystick
    "-noaafonts",            # Disable anti-aliased fonts
    "-nod3d9ex",             # Disable Direct3D 9Ex
    "-high",                 # High CPU priority
    "-threads 4",            # Use 4 threads
    "+fps_max 60",           # Limit FPS
    "+rate 128000",          # Network rate
    "+cl_updaterate 128",    # Update rate
    "+cl_cmdrate 128",       # Command rate
    "+mat_queue_mode 2",     # Multi-threaded rendering
    "+exec autoexec.cfg"     # Execute autoexec config
)

Write-Host "Launching CS2 for Worker $($WorkerConfig.WorkerId)..."
Start-Process -FilePath `$steamPath -ArgumentList (`$launchParams -join " ") -NoNewWindow
"@
        
        Set-Content -Path $launchScript -Value $defaultScript -Force
    }
    
    # Create autoexec.cfg if it doesn't exist
    $autoexecPath = Join-Path $WorkerConfig.CS2InstallPath "game\csgo\cfg\autoexec.cfg"
    
    if (-not (Test-Path $autoexecPath)) {
        Write-Log -Message "Creating autoexec.cfg..." -Level "DEBUG"
        
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

// Auto-execute
echo "CS2 Worker autoexec loaded"
"@
        
        $configDir = Split-Path $autoexecPath -Parent
        if (-not (Test-Path $configDir)) {
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }
        
        Set-Content -Path $autoexecPath -Value $autoexecContent -Force
    }
}

# Register with load balancer
function Register-WithLoadBalancer {
    Write-Log -Message "Registering with load balancer..."
    
    if ([string]::IsNullOrEmpty($WorkerConfig.LoadBalancerUrl)) {
        Write-Log -Message "No load balancer URL configured, skipping registration" -Level "WARN"
        return $true
    }
    
    $registrationData = @{
        worker_id = $WorkerConfig.WorkerId
        hostname = $env:COMPUTERNAME
        ip_address = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne "127.0.0.1" }).IPAddress | Select-Object -First 1
        status = "starting"
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        capabilities = @("cs2", "gpu")
    } | ConvertTo-Json
    
    try {
        $response = Invoke-RestMethod -Uri "$($WorkerConfig.LoadBalancerUrl)/register" -Method POST -Body $registrationData -ContentType "application/json"
        Write-Log -Message "Successfully registered with load balancer: $response"
        return $true
    }
    catch {
        Handle-Error -ErrorMessage "Failed to register with load balancer: $_"
        return $false
    }
}

# Send health check
function Send-HealthCheck {
    param([string]$Status = "healthy")
    
    if ([string]::IsNullOrEmpty($WorkerConfig.LoadBalancerUrl)) {
        return $true
    }
    
    $healthData = @{
        worker_id = $WorkerConfig.WorkerId
        status = $Status
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        uptime = (Get-Uptime).TotalSeconds
    } | ConvertTo-Json
    
    try {
        Invoke-RestMethod -Uri "$($WorkerConfig.LoadBalancerUrl)/health" -Method POST -Body $healthData -ContentType "application/json" | Out-Null
        return $true
    }
    catch {
        Write-Log -Message "Health check failed: $_" -Level "DEBUG"
        return $false
    }
}

# Launch CS2 client
function Start-CS2Client {
    Write-Log -Message "Starting CS2 client..."
    
    $launchScript = Join-Path $WorkerConfig.WorkerDataPath "cs2-scripts\start.ps1"
    
    if (Test-Path $launchScript) {
        try {
            & PowerShell -ExecutionPolicy Bypass -File $launchScript
            Write-Log -Message "CS2 client launch script executed"
            return $true
        }
        catch {
            Handle-Error -ErrorMessage "Failed to execute CS2 launch script: $_"
            return $false
        }
    }
    else {
        Handle-Error -ErrorMessage "CS2 launch script not found at $launchScript"
        return $false
    }
}

# Create Windows service for worker management
function Install-WorkerService {
    Write-Log -Message "Installing CS2 worker service..."
    
    $serviceName = "CS2Worker"
    $serviceDisplayName = "CS2 Worker Service"
    $serviceDescription = "Manages CS2 worker client and health reporting"
    
    # Check if service already exists
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Write-Log -Message "Service $serviceName already exists" -Level "WARN"
        return $true
    }
    
    # Create service wrapper script
    $serviceScript = Join-Path $WorkerConfig.WorkerDataPath "scripts\service-wrapper.ps1"
    
    $serviceContent = @"
# CS2 Worker Service Wrapper
# This script runs as a Windows service to manage the CS2 worker

`$WorkerConfig = @{
    WorkerId = $($WorkerConfig.WorkerId)
    LoadBalancerUrl = "$($WorkerConfig.LoadBalancerUrl)"
    WorkerDataPath = "$($WorkerConfig.WorkerDataPath)"
    HealthCheckInterval = $($WorkerConfig.HealthCheckInterval)
}

# Import bootstrap functions
. "$PSScriptRoot\..\bootstrap_worker.ps1"

# Service main loop
while (`$true) {
    try {
        # Send health check
        Send-HealthCheck -Status "healthy"
        
        # Check if CS2 is running
        `$cs2Process = Get-Process -Name "cs2" -ErrorAction SilentlyContinue
        
        if (-not `$cs2Process) {
            Write-Log -Message "CS2 not running, attempting restart..." -Level "WARN"
            Start-CS2Client
        }
        
        Start-Sleep -Seconds `$WorkerConfig.HealthCheckInterval
    }
    catch {
        Write-Log -Message "Service error: `$_" -Level "ERROR"
        Start-Sleep -Seconds 60
    }
}
"@
    
    Set-Content -Path $serviceScript -Value $serviceContent -Force
    
    try {
        # Install service using NSSM (Non-Sucking Service Manager)
        # First, download and install NSSM if not present
        $nssmPath = "C:\Windows\System32\nssm.exe"
        
        if (-not (Test-Path $nssmPath)) {
            Write-Log -Message "Downloading NSSM..." -Level "DEBUG"
            $nssmZip = "C:\Windows\Temp\nssm.zip"
            Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip
            Expand-Archive -Path $nssmZip -DestinationPath "C:\Windows\Temp\nssm" -Force
            Copy-Item -Path "C:\Windows\Temp\nssm\nssm-2.24\win64\nssm.exe" -Destination $nssmPath -Force
        }
        
        # Install the service
        & $nssmPath install $serviceName "PowerShell.exe" "-ExecutionPolicy Bypass -File `"$serviceScript`""
        & $nssmPath set $serviceName DisplayName $serviceDisplayName
        & $nssmPath set $serviceName Description $serviceDescription
        & $nssmPath set $serviceName Start SERVICE_AUTO_START
        
        Write-Log -Message "CS2 worker service installed successfully"
        return $true
    }
    catch {
        Handle-Error -ErrorMessage "Failed to install worker service: $_"
        return $false
    }
}

# Main bootstrap function
function Invoke-WorkerBootstrap {
    Write-Log -Message "Starting CS2 Worker Bootstrap (Worker ID: $($WorkerConfig.WorkerId))"
    
    # Apply startup delay if configured
    if ($WorkerConfig.StartupDelay -gt 0) {
        Write-Log -Message "Applying startup delay of $($WorkerConfig.StartupDelay) seconds..."
        Start-Sleep -Seconds $WorkerConfig.StartupDelay
    }
    
    # Initialize environment
    Initialize-WorkerEnvironment
    
    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        Write-Log -Message "Prerequisites check failed, attempting to install dependencies..." -Level "WARN"
        Install-Dependencies
    }
    
    # Update CS2 repository
    if (-not (Update-CS2Repository)) {
        Handle-Error -ErrorMessage "Failed to update CS2 repository" -Fatal $false
    }
    
    # Configure CS2 launch
    Configure-CS2Launch
    
    # Register with load balancer
    Register-WithLoadBalancer
    
    # Install worker service
    Install-WorkerService
    
    # Launch CS2 client
    Start-CS2Client
    
    # Send initial health check
    Send-HealthCheck -Status "ready"
    
    Write-Log -Message "CS2 Worker bootstrap completed successfully"
    
    # Start continuous health monitoring
    while ($true) {
        try {
            Send-HealthCheck -Status "healthy"
            Start-Sleep -Seconds $WorkerConfig.HealthCheckInterval
        }
        catch {
            Write-Log -Message "Health monitoring error: $_" -Level "ERROR"
            Start-Sleep -Seconds 60
        }
    }
}

# Script entry point
try {
    # Ensure log directory exists
    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Write-Log -Message "CS2 Worker Bootstrap Script Starting..."
    
    # Load configuration
    Load-WorkerConfig
    
    # Run bootstrap
    Invoke-WorkerBootstrap
}
catch {
    Handle-Error -ErrorMessage "Bootstrap failed: $_" -Fatal $true
}
finally {
    Write-Log -Message "Bootstrap script completed"
}
