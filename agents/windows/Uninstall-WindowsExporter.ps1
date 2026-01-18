<#
.SYNOPSIS
    Uninstalls windows_exporter from the system.

.DESCRIPTION
    This script stops the windows_exporter service, removes it via MSI uninstall,
    and cleans up the firewall rule.

.EXAMPLE
    .\Uninstall-WindowsExporter.ps1

.NOTES
    Requires Administrator privileges.
#>

[CmdletBinding()]
param()

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$ServiceName = "windows_exporter"
$FirewallRuleName = "Windows Exporter (Prometheus)"
$ProductName = "windows_exporter"

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

function Stop-ExporterService {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-Log "Stopping $ServiceName service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Log "Service stopped" -Level "SUCCESS"
    }
    else {
        Write-Log "Service not found, skipping..." -Level "WARN"
    }
}

function Uninstall-Exporter {
    Write-Log "Looking for windows_exporter installation..."
    
    # Find the product in registry
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    $product = Get-ItemProperty $uninstallPaths -ErrorAction SilentlyContinue | 
               Where-Object { $_.DisplayName -like "*windows_exporter*" }
    
    if ($product) {
        $productCode = $product.PSChildName
        Write-Log "Found product: $($product.DisplayName) ($productCode)"
        
        $msiArgs = @("/x", $productCode, "/qn", "/norestart")
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0) {
            Write-Log "Uninstallation completed" -Level "SUCCESS"
        }
        else {
            Write-Log "MSI uninstall returned exit code: $($process.ExitCode)" -Level "WARN"
        }
    }
    else {
        Write-Log "No MSI installation found" -Level "WARN"
    }
}

function Remove-FirewallRule {
    Write-Log "Removing firewall rule..."
    
    $rule = Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue
    if ($rule) {
        Remove-NetFirewallRule -DisplayName $FirewallRuleName
        Write-Log "Firewall rule removed" -Level "SUCCESS"
    }
    else {
        Write-Log "Firewall rule not found, skipping..." -Level "WARN"
    }
}

function Remove-InstallDirectory {
    $installPath = "C:\Program Files\windows_exporter"
    if (Test-Path $installPath) {
        Write-Log "Removing installation directory..."
        Remove-Item -Path $installPath -Recurse -Force
        Write-Log "Directory removed" -Level "SUCCESS"
    }
}

# Main execution
try {
    Write-Log "=========================================="
    Write-Log "Windows Exporter Uninstallation Script"
    Write-Log "=========================================="
    
    Stop-ExporterService
    Uninstall-Exporter
    Remove-FirewallRule
    Remove-InstallDirectory
    
    Write-Log "=========================================="
    Write-Log "Uninstallation completed!" -Level "SUCCESS"
    Write-Log "=========================================="
}
catch {
    Write-Log "Uninstallation failed: $_" -Level "ERROR"
    exit 1
}
