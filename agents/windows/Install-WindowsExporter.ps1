<#
.SYNOPSIS
    Installs and configures windows_exporter for Prometheus monitoring.

.DESCRIPTION
    This script downloads the latest windows_exporter MSI, installs it with
    the specified collectors enabled, configures Windows Firewall, and starts
    the service.

.PARAMETER ExporterVersion
    Version of windows_exporter to install. Default: latest.

.PARAMETER ListenPort
    Port for the exporter to listen on. Default: 9182.

.PARAMETER Collectors
    Comma-separated list of collectors to enable.
    Default: cpu,cs,logical_disk,physical_disk,memory,net,os,process,system

.PARAMETER InstallPath
    Installation directory. Default: C:\Program Files\windows_exporter

.EXAMPLE
    .\Install-WindowsExporter.ps1

.EXAMPLE
    .\Install-WindowsExporter.ps1 -ListenPort 9183 -Collectors "cpu,memory,disk"

.NOTES
    Requires Administrator privileges.
    Author: Performance Monitor Team
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ExporterVersion = "0.31.3",

    [Parameter()]
    [int]$ListenPort = 9182,

    [Parameter()]
    [string]$Collectors = "cpu,logical_disk,physical_disk,memory,net,os,process,system,thermalzone,gpu",

    [Parameter()]
    [string]$InstallPath = "C:\Program Files\windows_exporter"
)

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

# Configuration
$ServiceName = "windows_exporter"
$FirewallRuleName = "Windows Exporter (Prometheus)"
$DownloadUrl = "https://github.com/prometheus-community/windows_exporter/releases/download/v${ExporterVersion}/windows_exporter-${ExporterVersion}-amd64.msi"
$MsiPath = Join-Path $env:TEMP "windows_exporter-${ExporterVersion}-amd64.msi"

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

function Test-ServiceExists {
    param([string]$Name)
    return $null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)
}

function Stop-ExistingService {
    if (Test-ServiceExists -Name $ServiceName) {
        Write-Log "Stopping existing $ServiceName service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

function Download-Installer {
    Write-Log "Downloading windows_exporter v${ExporterVersion}..."
    
    # Use TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($DownloadUrl, $MsiPath)
        Write-Log "Downloaded to: $MsiPath" -Level "SUCCESS"
    }
    catch {
        Write-Log "Failed to download: $_" -Level "ERROR"
        throw
    }
}

function Install-Exporter {
    Write-Log "Installing windows_exporter..."
    
    # Build MSI arguments
    $msiArgs = @(
        "/i", $MsiPath,
        "/qn",  # Quiet, no UI
        "/norestart",
        "ENABLED_COLLECTORS=$Collectors",
        "LISTEN_PORT=$ListenPort",
        "EXTRA_FLAGS=--log.level=info"
    )
    
    Write-Log "Collectors: $Collectors"
    Write-Log "Listen port: $ListenPort"
    
    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    
    if ($process.ExitCode -ne 0) {
        Write-Log "MSI installation failed with exit code: $($process.ExitCode)" -Level "ERROR"
        throw "Installation failed"
    }
    
    Write-Log "Installation completed successfully" -Level "SUCCESS"
}

function Configure-Firewall {
    Write-Log "Configuring Windows Firewall..."
    
    # Remove existing rule if present
    $existingRule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName
        Write-Log "Removed existing firewall rule"
    }
    
    # Create new inbound rule
    New-NetFirewallRule `
        -DisplayName $FirewallRuleName `
        -Description "Allow Prometheus to scrape windows_exporter metrics" `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $ListenPort `
        -Action Allow `
        -Profile Any `
        -Enabled True | Out-Null
    
    Write-Log "Firewall rule created for port $ListenPort" -Level "SUCCESS"
}

function Start-ExporterService {
    Write-Log "Starting $ServiceName service..."
    
    # Ensure service is set to automatic start
    Set-Service -Name $ServiceName -StartupType Automatic
    
    # Start the service
    Start-Service -Name $ServiceName
    
    # Wait for service to be running
    $timeout = 30
    $elapsed = 0
    while ((Get-Service -Name $ServiceName).Status -ne "Running" -and $elapsed -lt $timeout) {
        Start-Sleep -Seconds 1
        $elapsed++
    }
    
    if ((Get-Service -Name $ServiceName).Status -eq "Running") {
        Write-Log "Service started successfully" -Level "SUCCESS"
    }
    else {
        Write-Log "Service failed to start within $timeout seconds" -Level "ERROR"
        throw "Service start failed"
    }
}

function Test-Installation {
    Write-Log "Verifying installation..."
    
    $testUrl = "http://localhost:$ListenPort/metrics"
    
    try {
        $response = Invoke-WebRequest -Uri $testUrl -UseBasicParsing -TimeoutSec 10
        if ($response.StatusCode -eq 200) {
            Write-Log "Exporter is responding at $testUrl" -Level "SUCCESS"
            
            # Show sample metrics
            $lines = $response.Content -split "`n" | Select-Object -First 20
            Write-Log "Sample metrics:"
            $lines | ForEach-Object { Write-Host "  $_" }
        }
    }
    catch {
        Write-Log "Failed to verify exporter: $_" -Level "WARN"
    }
}

function Cleanup {
    if (Test-Path $MsiPath) {
        Remove-Item $MsiPath -Force
        Write-Log "Cleaned up installer"
    }
}

# Main execution
try {
    Write-Log "=========================================="
    Write-Log "Windows Exporter Installation Script"
    Write-Log "=========================================="
    Write-Log "Version: $ExporterVersion"
    Write-Log "Port: $ListenPort"
    Write-Log "Collectors: $Collectors"
    Write-Log "=========================================="
    
    Stop-ExistingService
    Download-Installer
    Install-Exporter
    Configure-Firewall
    Start-ExporterService
    Test-Installation
    
    Write-Log "=========================================="
    Write-Log "Installation completed successfully!" -Level "SUCCESS"
    Write-Log "Metrics available at: http://$(hostname):$ListenPort/metrics"
    Write-Log "=========================================="
}
catch {
    Write-Log "Installation failed: $_" -Level "ERROR"
    exit 1
}
finally {
    Cleanup
}
