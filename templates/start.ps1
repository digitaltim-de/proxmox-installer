# CS2 Worker Launch Script
# This script is pulled from GitHub and executed by the bootstrap script
# Customize this for your specific CS2 automation needs

param(
    [int]$WorkerId = 1,
    [string]$LoadBalancerUrl = "",
    [string]$SteamUsername = "",
    [string]$SteamPassword = "",
    [int]$MaxRetries = 3
)

# Configuration
$CS2AppId = "730"
$SteamPath = "C:\Program Files (x86)\Steam\Steam.exe"
$CS2Path = "C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe"
$LogFile = "C:\CS2Worker\logs\start.log"

# Ensure log directory exists
$logDir = Split-Path $LogFile -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Logging function
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] [Worker-$WorkerId] $Message"
    Write-Host $logEntry
    Add-Content -Path $LogFile -Value $logEntry -Force
}

# Wait for Steam to be ready
function Wait-ForSteam {
    param([int]$TimeoutSeconds = 120)
    
    Write-Log "Waiting for Steam to be ready..."
    $elapsed = 0
    
    while ($elapsed -lt $TimeoutSeconds) {
        if (Get-Process -Name "Steam" -ErrorAction SilentlyContinue) {
            Write-Log "Steam process detected"
            Start-Sleep -Seconds 10  # Give Steam time to fully initialize
            return $true
        }
        
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    
    Write-Log "Timeout waiting for Steam" -Level "ERROR"
    return $false
}

# Launch Steam if not running
function Start-Steam {
    if (Get-Process -Name "Steam" -ErrorAction SilentlyContinue) {
        Write-Log "Steam is already running"
        return $true
    }
    
    Write-Log "Starting Steam..."
    
    if (-not (Test-Path $SteamPath)) {
        Write-Log "Steam not found at $SteamPath" -Level "ERROR"
        return $false
    }
    
    try {
        # Start Steam in background mode
        $steamArgs = @("-silent")
        if ($SteamUsername -and $SteamPassword) {
            $steamArgs += @("-login", $SteamUsername, $SteamPassword)
        }
        
        Start-Process -FilePath $SteamPath -ArgumentList $steamArgs -WindowStyle Hidden
        
        if (Wait-ForSteam) {
            Write-Log "Steam started successfully"
            return $true
        } else {
            Write-Log "Failed to start Steam" -Level "ERROR"
            return $false
        }
    }
    catch {
        Write-Log "Error starting Steam: $_" -Level "ERROR"
        return $false
    }
}

# Check if CS2 is installed
function Test-CS2Installation {
    if (Test-Path $CS2Path) {
        Write-Log "CS2 installation verified"
        return $true
    }
    
    Write-Log "CS2 not found, checking Steam library..." -Level "WARN"
    
    # Check if CS2 is installed via Steam
    $steamApps = "C:\Program Files (x86)\Steam\steamapps"
    $cs2Manifest = "$steamApps\appmanifest_$CS2AppId.acf"
    
    if (Test-Path $cs2Manifest) {
        Write-Log "CS2 is installed in Steam library"
        return $true
    }
    
    Write-Log "CS2 not installed" -Level "ERROR"
    return $false
}

# Launch CS2
function Start-CS2 {
    Write-Log "Launching CS2..."
    
    if (-not (Test-CS2Installation)) {
        Write-Log "CS2 installation check failed" -Level "ERROR"
        return $false
    }
    
    # Kill any existing CS2 processes
    Get-Process -Name "cs2" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 5
    
    try {
        # CS2 launch parameters optimized for worker environment
        $cs2Args = @(
            "-applaunch", $CS2AppId,
            "-novid",                    # Skip intro video
            "-nojoy",                    # Disable joystick
            "-noaafonts",               # Disable anti-aliased fonts
            "-nod3d9ex",                # Disable Direct3D 9Ex
            "-high",                    # High CPU priority
            "-threads", "4",            # Use 4 threads
            "+fps_max", "60",           # Limit FPS to 60
            "+rate", "128000",          # Network rate
            "+cl_updaterate", "128",    # Update rate
            "+cl_cmdrate", "128",       # Command rate
            "+mat_queue_mode", "2",     # Multi-threaded rendering
            "+exec", "autoexec.cfg",    # Execute autoexec config
            "+con_enable", "1",         # Enable console
            "+developer", "1",          # Enable developer mode
            "+sv_lan", "1",             # LAN mode
            "+map", "de_dust2",         # Load specific map
            "-windowed",                # Run in windowed mode
            "-w", "1920",               # Window width
            "-h", "1080"                # Window height
        )
        
        Write-Log "CS2 launch command: $SteamPath $($cs2Args -join ' ')"
        
        # Launch CS2 through Steam
        Start-Process -FilePath $SteamPath -ArgumentList $cs2Args -WindowStyle Minimized
        
        # Wait for CS2 process to start
        $timeout = 60
        $elapsed = 0
        
        while ($elapsed -lt $timeout) {
            if (Get-Process -Name "cs2" -ErrorAction SilentlyContinue) {
                Write-Log "CS2 launched successfully"
                return $true
            }
            
            Start-Sleep -Seconds 2
            $elapsed += 2
        }
        
        Write-Log "CS2 process not detected after launch" -Level "WARN"
        return $false
    }
    catch {
        Write-Log "Error launching CS2: $_" -Level "ERROR"
        return $false
    }
}

# Monitor CS2 process
function Monitor-CS2 {
    Write-Log "Starting CS2 process monitoring..."
    
    while ($true) {
        $cs2Process = Get-Process -Name "cs2" -ErrorAction SilentlyContinue
        
        if ($cs2Process) {
            # Check CPU and memory usage
            $cpuPercent = [math]::Round($cs2Process.CPU, 2)
            $memoryMB = [math]::Round($cs2Process.WorkingSet64 / 1MB, 2)
            
            Write-Log "CS2 running - CPU: $cpuPercent%, Memory: ${memoryMB}MB"
            
            # Report to load balancer if configured
            if ($LoadBalancerUrl) {
                Send-HealthStatus -Status "healthy" -Details @{
                    "cs2_cpu_percent" = $cpuPercent
                    "cs2_memory_mb" = $memoryMB
                    "cs2_pid" = $cs2Process.Id
                }
            }
        }
        else {
            Write-Log "CS2 process not running, attempting restart..." -Level "WARN"
            
            if ($LoadBalancerUrl) {
                Send-HealthStatus -Status "degraded" -Details @{
                    "issue" = "cs2_not_running"
                }
            }
            
            # Attempt to restart CS2
            if (-not (Start-CS2)) {
                Write-Log "Failed to restart CS2" -Level "ERROR"
                Start-Sleep -Seconds 30
            }
        }
        
        Start-Sleep -Seconds 30  # Check every 30 seconds
    }
}

# Send health status to load balancer
function Send-HealthStatus {
    param(
        [string]$Status = "healthy",
        [hashtable]$Details = @{}
    )
    
    if (-not $LoadBalancerUrl) {
        return
    }
    
    $healthData = @{
        worker_id = $WorkerId
        status = $Status
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
        details = $Details
        hostname = $env:COMPUTERNAME
    }
    
    try {
        $json = $healthData | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Uri "$LoadBalancerUrl/health" -Method POST -Body $json -ContentType "application/json" -TimeoutSec 10 | Out-Null
    }
    catch {
        Write-Log "Failed to send health status: $_" -Level "DEBUG"
    }
}

# Main execution
function Main {
    Write-Log "=== CS2 Worker $WorkerId Starting ==="
    
    $attempt = 1
    $success = $false
    
    while ($attempt -le $MaxRetries -and -not $success) {
        Write-Log "Attempt $attempt of $MaxRetries"
        
        # Start Steam
        if (Start-Steam) {
            # Launch CS2
            if (Start-CS2) {
                $success = $true
                Write-Log "CS2 worker started successfully"
                
                # Start monitoring
                Monitor-CS2
            }
        }
        
        if (-not $success) {
            Write-Log "Attempt $attempt failed, retrying in 30 seconds..." -Level "WARN"
            Start-Sleep -Seconds 30
            $attempt++
        }
    }
    
    if (-not $success) {
        Write-Log "Failed to start CS2 worker after $MaxRetries attempts" -Level "ERROR"
        
        if ($LoadBalancerUrl) {
            Send-HealthStatus -Status "failed" -Details @{
                "error" = "startup_failed"
                "attempts" = $MaxRetries
            }
        }
        
        exit 1
    }
}

# Run main function
try {
    Main
}
catch {
    Write-Log "Unhandled error: $_" -Level "ERROR"
    exit 1
}
