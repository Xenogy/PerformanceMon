# Proxmox + VM Performance Monitoring Platform

A comprehensive monitoring solution for Proxmox VE environments running Windows VMs. Captures host and guest telemetry, correlates metrics with VM configuration metadata, and provides interactive dashboards for analysis and troubleshooting.

## Features

- **Host Monitoring**: CPU, memory, disk I/O, network, and GPU metrics from Proxmox hosts
- **Guest Monitoring**: Per-VM metrics from Windows guests via windows_exporter
- **Automatic Discovery**: HTTP service discovery finds VMs automatically from Proxmox API
- **Configuration Correlation**: Compare VMs by vCPU, memory, disk type, and tags
- **Pre-built Dashboards**: Cluster overview, VM comparison, host-guest correlation, and VM detail views
- **Alerting**: Configurable thresholds for CPU, memory, disk latency, and network issues
- **GPU Metrics**: vGPU utilization via host-side nvidia-smi

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Monitoring Server                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌──────────────────┐   │
│  │  Prometheus │  │   Grafana   │  │ Alertmanager│  │ Discovery Service│   │
│  │   :9090     │  │    :3000    │  │    :9093    │  │      :8000       │   │
│  └──────┬──────┘  └─────────────┘  └─────────────┘  └────────┬─────────┘   │
│         │                                                      │            │
│         │  scrapes                                   queries   │            │
│         ▼                                                      ▼            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │                         Proxmox API                                   │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
         │
         │ scrapes
         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Proxmox Host(s)                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                         │
│  │ PVE Exporter│  │node_exporter│  │ nvidia-gpu  │                         │
│  │   :9221     │  │    :9100    │  │   :9835     │                         │
│  └─────────────┘  └─────────────┘  └─────────────┘                         │
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                      │
│  │  Windows VM  │  │  Windows VM  │  │  Windows VM  │                      │
│  │  :9182       │  │  :9182       │  │  :9182       │                      │
│  │ (exporter)   │  │ (exporter)   │  │ (exporter)   │                      │
│  └──────────────┘  └──────────────┘  └──────────────┘                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- Docker and Docker Compose
- Proxmox VE 7.x or 8.x
- Windows VMs with network access from monitoring server
- (Optional) NVIDIA GPU with vGPU for GPU monitoring

### 1. Clone and Configure

```bash
git clone <repository-url>
cd PerformanceMonitor

# Copy example configs
cp .env.example .env
cp pve-exporter/pve.yml.example pve-exporter/pve.yml

# Edit .env with your settings
nano .env

# Edit pve.yml with your Proxmox API credentials
nano pve-exporter/pve.yml
```

### 2. Create Proxmox API Token

1. Go to Datacenter → Permissions → Users → Add
   - User name: `prometheus`
   - Realm: `Proxmox VE authentication server`
2. Go to Datacenter → Permissions → API Tokens → Add
   - User: `prometheus@pve`
   - Token ID: `monitoring`
   - Uncheck "Privilege Separation"
3. Go to Datacenter → Permissions → Add → User Permission
   - Path: `/`
   - User: `prometheus@pve`
   - Role: `PVEAuditor`

### 3. Start the Stack

```bash
docker-compose up -d
```

### 4. Install Windows Agent on VMs

Copy the agent installer to each Windows VM and run as Administrator:

```powershell
.\Install-WindowsExporter.ps1
```

Or with custom options:
```powershell
.\Install-WindowsExporter.ps1 -ListenPort 9182 -Collectors "cpu,memory,logical_disk,net,process"
```

### 5. Access Dashboards

- **Grafana**: http://localhost:3000 (admin/admin by default)
- **Prometheus**: http://localhost:9090
- **Alertmanager**: http://localhost:9093

## Configuration

### Environment Variables (.env)

| Variable | Description | Default |
|----------|-------------|---------|
| `PROXMOX_HOST` | Proxmox VE IP/hostname | - |
| `PROXMOX_USER` | API user | `prometheus@pve` |
| `PROXMOX_TOKEN_NAME` | API token name | `monitoring` |
| `PROXMOX_TOKEN_VALUE` | API token secret | - |
| `PROXMOX_VERIFY_SSL` | Verify SSL certificates | `false` |
| `CACHE_TTL_SECONDS` | Discovery cache TTL | `60` |
| `WINDOWS_EXPORTER_PORT` | Windows exporter port | `9182` |
| `GRAFANA_ADMIN_PASSWORD` | Grafana admin password | `admin` |
| `ALERT_WEBHOOK_URL` | Webhook for alerts | - |
| `ALERT_EMAIL_TO` | Email for alerts | - |

### Adding Proxmox Hosts

Edit `prometheus/prometheus.yml` and add your Proxmox host IPs to the `pve-nodes` job:

```yaml
- job_name: 'pve-nodes'
  static_configs:
    - targets:
        - '192.168.1.100:9100'
        - '192.168.1.101:9100'
```

Then deploy node_exporter on each host:

```bash
apt install prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
```

### GPU Monitoring

For hosts with NVIDIA GPUs (vGPU), the nvidia-gpu-exporter is included. Adjust device mappings in `docker-compose.yml` if needed:

```yaml
nvidia-gpu-exporter:
  devices:
    - /dev/nvidiactl:/dev/nvidiactl
    - /dev/nvidia0:/dev/nvidia0
    - /dev/nvidia1:/dev/nvidia1  # Add additional GPUs
```

## Dashboards

### Cluster Overview
High-level view of all hosts and VMs with status indicators, resource usage summaries, and alert counts.

### VM Comparison
Select multiple VMs and compare CPU, memory, disk, and network metrics side-by-side. Filter by vCPU count, memory size, or tags.

### VM Detail
Deep-dive into a single VM with per-core CPU, memory breakdown, disk I/O per volume, network per interface, and top processes table.

### Host-Guest Correlation
Side-by-side view of host and guest metrics to identify whether bottlenecks are on the hypervisor or within the VM.

## Alerting

Pre-configured alerts include:

| Alert | Condition | Severity |
|-------|-----------|----------|
| HostCpuStealHigh | CPU steal > 5% for 5m | Warning |
| HostMemoryLow | Memory > 90% for 5m | Warning |
| GuestCpuSaturation | VM CPU > 90% for 10m | Warning |
| GuestDiskLatencyHigh | Disk latency > 50ms for 5m | Warning |
| GpuUtilizationHigh | GPU > 95% for 10m | Warning |
| VmDown | VM not running for 2m | Critical |

Configure notification destinations in `alertmanager/alertmanager.yml`.

## Directory Structure

```
PerformanceMonitor/
├── docker-compose.yml          # Service definitions
├── .env.example                # Environment template
├── prometheus/
│   ├── prometheus.yml          # Prometheus config
│   └── rules/
│       ├── recording.yml       # Pre-aggregation rules
│       └── alerts.yml          # Alert rules
├── alertmanager/
│   ├── alertmanager.yml        # Alertmanager config
│   └── templates/              # Notification templates
├── grafana/
│   └── provisioning/
│       ├── datasources/        # Auto-provisioned datasources
│       └── dashboards/         # Auto-provisioned dashboards
├── pve-exporter/
│   └── pve.yml.example         # PVE API credentials
├── discovery-service/
│   ├── main.py                 # VM discovery API
│   ├── Dockerfile
│   └── requirements.txt
├── agents/
│   └── windows/
│       ├── Install-WindowsExporter.ps1
│       ├── Uninstall-WindowsExporter.ps1
│       └── README.md
└── docs/
    ├── architecture.md
    ├── deployment.md
    └── runbook.md
```

## Troubleshooting

### VMs Not Appearing

1. Check discovery service logs: `docker-compose logs discovery-service`
2. Verify Proxmox API credentials in `pve-exporter/pve.yml`
3. Ensure VMs have QEMU guest agent installed for IP discovery
4. Check that windows_exporter is running on the VM

### Metrics Missing

1. Verify exporter is accessible: `curl http://<vm-ip>:9182/metrics`
2. Check Prometheus targets: http://localhost:9090/targets
3. Review Prometheus logs: `docker-compose logs prometheus`

### Alerts Not Firing

1. Check alert rules: http://localhost:9090/alerts
2. Verify Alertmanager is receiving: http://localhost:9093
3. Check webhook/email configuration in `alertmanager/alertmanager.yml`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

## License

MIT License - see [LICENSE](LICENSE) for details.
