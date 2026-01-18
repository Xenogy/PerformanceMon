<#
.SYNOPSIS
    Updates the collectors for an existing windows_exporter installation.

.DESCRIPTION
    This script modifies the windows_exporter service to enable additional collectors
    without requiring a full reinstall. It updates the service's ImagePath in the registry.

.PARAMETER Collectors
    Comma-separated list of collectors to enable.

.PARAMETER AddCollectors
    Comma-separated list of collectors to ADD to existing ones (doesn't replace).

.EXAMPLE
    .\Update-WindowsExporterCollectors.ps1 -AddCollectors "gpu"

.EXAMPLE
    .\Update-WindowsExporterCollectors.ps1 -Collectors "cpu,cs,logical_disk,physical_disk,memory,net,os,process,system,thermalzone,gpu"

.NOTES
    Requires Administrator privileges.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$Collectors = "",

    [Parameter()]
    [string]$AddCollectors = "gpu"
)

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
$ServiceName = "windows_exporter"
$RegistryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\windows_exporter"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# Check if service exists
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Log "windows_exporter service not found. Please install it first." -Level "ERROR"
    exit 1
}

# Get current ImagePath
$currentImagePath = (Get-ItemProperty -Path $RegistryPath -Name ImagePath).ImagePath
Write-Log "Current ImagePath: $currentImagePath"

# Parse current collectors from ImagePath
$currentCollectors = @()
if ($currentImagePath -match '--collectors\.enabled[=\s]+["'']?([^"''\s]+)["'']?') {
    $currentCollectors = $Matches[1] -split ','
    Write-Log "Current collectors: $($currentCollectors -join ', ')"
} elseif ($currentImagePath -match '--collectors\.enabled[=\s]+([^\s]+)') {
    $currentCollectors = $Matches[1] -split ','
    Write-Log "Current collectors: $($currentCollectors -join ', ')"
} else {
    Write-Log "Could not parse current collectors from ImagePath" -Level "WARN"
    # Default collectors if we can't parse
    $currentCollectors = @("cpu","cs","logical_disk","memory","net","os","physical_disk","process","system")
}

# Determine new collectors list
if ($Collectors) {
    # Full replacement
    $newCollectors = $Collectors -split ','
    Write-Log "Replacing collectors with: $Collectors"
} else {
    # Add to existing
    $addList = $AddCollectors -split ','
    $newCollectors = $currentCollectors + $addList | Select-Object -Unique
    Write-Log "Adding collectors: $AddCollectors"
}

$newCollectorsString = ($newCollectors | Sort-Object) -join ','
Write-Log "New collectors: $newCollectorsString"

# Build new ImagePath
# Remove existing --collectors.enabled if present
$newImagePath = $currentImagePath -replace '\s*--collectors\.enabled[=\s]+["'']?[^"''\s]+["'']?\s*', ' '
$newImagePath = $newImagePath -replace '\s*--collectors\.enabled[=\s]+[^\s]+\s*', ' '
$newImagePath = $newImagePath.Trim()

# Add new collectors parameter
$newImagePath = "$newImagePath --collectors.enabled=$newCollectorsString"

Write-Log "New ImagePath: $newImagePath"

# Stop service
Write-Log "Stopping $ServiceName service..."
Stop-Service -Name $ServiceName -Force
Start-Sleep -Seconds 2

# Update registry
Write-Log "Updating service configuration..."
Set-ItemProperty -Path $RegistryPath -Name ImagePath -Value $newImagePath

# Start service
Write-Log "Starting $ServiceName service..."
Start-Service -Name $ServiceName

# Wait for service
$timeout = 30
$elapsed = 0
while ((Get-Service -Name $ServiceName).Status -ne "Running" -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 1
    $elapsed++
}

if ((Get-Service -Name $ServiceName).Status -eq "Running") {
    Write-Log "Service restarted successfully" -Level "SUCCESS"
} else {
    Write-Log "Service failed to start" -Level "ERROR"
    exit 1
}

# Verify collectors
Start-Sleep -Seconds 2
Write-Log "Verifying collectors..."

try {
    $response = Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing -TimeoutSec 10
    $enabledCollectors = ($response.Content -split "`n" | Where-Object { $_ -match 'windows_exporter_collector_success\{collector="([^"]+)"\}' }) | 
        ForEach-Object { if ($_ -match 'collector="([^"]+)"') { $Matches[1] } }
    
    Write-Log "Enabled collectors:" -Level "SUCCESS"
    $enabledCollectors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
    
    if ($enabledCollectors -contains "gpu") {
        Write-Log "GPU collector is now enabled!" -Level "SUCCESS"
    } else {
        Write-Log "GPU collector not found in output - it may not be supported on this system" -Level "WARN"
    }
} catch {
    Write-Log "Could not verify: $_" -Level "WARN"
}

Write-Log "Done!" -Level "SUCCESS"
