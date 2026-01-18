# Windows Exporter Agent

This directory contains scripts for installing and managing the `windows_exporter` Prometheus exporter on Windows VMs.

## Overview

The [windows_exporter](https://github.com/prometheus-community/windows_exporter) is the official Prometheus exporter for Windows systems. It collects system metrics and exposes them via HTTP for Prometheus to scrape.

## Quick Start

### Installation

1. Open PowerShell as Administrator
2. Navigate to this directory or download the script
3. Run the installer:

```powershell
.\Install-WindowsExporter.ps1
```

### Verify Installation

After installation, verify the exporter is running:

```powershell
# Check service status
Get-Service windows_exporter

# Test metrics endpoint
Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing | Select-Object -First 10
```

You should see HTTP 200 and Prometheus metrics output.

## Configuration Options

The installation script accepts several parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ExporterVersion` | `0.25.1` | Version of windows_exporter to install |
| `-ListenPort` | `9182` | HTTP port for metrics endpoint |
| `-Collectors` | `cpu,cs,logical_disk,...` | Comma-separated list of collectors |
| `-InstallPath` | `C:\Program Files\windows_exporter` | Installation directory |

### Custom Installation Examples

```powershell
# Install with custom port
.\Install-WindowsExporter.ps1 -ListenPort 9183

# Install with specific collectors only
.\Install-WindowsExporter.ps1 -Collectors "cpu,memory,logical_disk,net"

# Install specific version
.\Install-WindowsExporter.ps1 -ExporterVersion "0.24.0"
```

## Enabled Collectors

By default, the following collectors are enabled:

| Collector | Description |
|-----------|-------------|
| `cpu` | CPU usage per core |
| `cs` | Computer system info (hostname, domain) |
| `logical_disk` | Disk space, I/O, latency per volume |
| `physical_disk` | Physical disk I/O statistics |
| `memory` | Memory usage, page faults, cache |
| `net` | Network interface statistics |
| `os` | OS info, processes, threads |
| `process` | Per-process CPU and memory |
| `system` | Context switches, system calls |
| `thermalzone` | CPU temperature (if available) |

### Additional Collectors

You can enable additional collectors if needed:

| Collector | Description |
|-----------|-------------|
| `gpu` | NVIDIA GPU metrics (requires driver) |
| `iis` | IIS web server metrics |
| `mssql` | SQL Server metrics |
| `service` | Windows service states |
| `tcp` | TCP connection statistics |
| `scheduled_task` | Scheduled task status |

## Firewall Configuration

The installer automatically creates a firewall rule named "Windows Exporter (Prometheus)" to allow inbound TCP traffic on the configured port.

To manually configure the firewall:

```powershell
New-NetFirewallRule -DisplayName "Windows Exporter (Prometheus)" `
    -Direction Inbound -Protocol TCP -LocalPort 9182 -Action Allow
```

## Uninstallation

To remove windows_exporter:

```powershell
.\Uninstall-WindowsExporter.ps1
```

This will:
1. Stop the windows_exporter service
2. Uninstall via MSI
3. Remove the firewall rule
4. Clean up the installation directory

## Troubleshooting

### Service Won't Start

Check the Windows Event Log:
```powershell
Get-EventLog -LogName Application -Source "windows_exporter" -Newest 10
```

### Port Already in Use

Check what's using the port:
```powershell
netstat -ano | findstr :9182
```

### Metrics Not Being Collected

1. Verify the service is running:
   ```powershell
   Get-Service windows_exporter
   ```

2. Check the metrics endpoint manually:
   ```powershell
   curl http://localhost:9182/metrics
   ```

3. Ensure Prometheus can reach the VM (check network/firewall)

### High CPU Usage

If the exporter uses too much CPU, reduce collectors or increase scrape interval:
```powershell
# Reinstall with fewer collectors
.\Uninstall-WindowsExporter.ps1
.\Install-WindowsExporter.ps1 -Collectors "cpu,memory,logical_disk,net"
```

## Security Considerations

1. **Firewall**: The default configuration allows connections from any IP. For production, restrict to your Prometheus server IP:
   ```powershell
   Set-NetFirewallRule -DisplayName "Windows Exporter (Prometheus)" `
       -RemoteAddress "192.168.1.10"
   ```

2. **TLS**: For secure environments, configure TLS using the exporter's web config. See the [windows_exporter documentation](https://github.com/prometheus-community/windows_exporter#tls-and-basic-authentication).

3. **Process Metrics**: The `process` collector exposes all running process names. Consider disabling if this is sensitive.

## Integration with Prometheus

Once installed, the VM will be automatically discovered by the Prometheus discovery service. Metrics will appear under the job `windows-vms` with labels for VM identification.

Example queries:
```promql
# CPU usage per VM
100 - avg by (vm_name) (rate(windows_cpu_time_total{mode="idle"}[5m])) * 100

# Memory usage per VM
windows_os_physical_memory_free_bytes / windows_os_visible_memory_bytes

# Disk latency
rate(windows_logical_disk_read_seconds_total[5m]) / rate(windows_logical_disk_reads_total[5m])
```
