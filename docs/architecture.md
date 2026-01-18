# Architecture

## Overview

The Proxmox + VM Performance Monitoring Platform is a pull-based monitoring system using Prometheus for metrics collection, Grafana for visualization, and Alertmanager for notifications. It collects metrics from both Proxmox hypervisor hosts and Windows guest VMs.

## Components

### Prometheus (Metrics Collection & Storage)

- **Role**: Central time-series database and scraping engine
- **Port**: 9090
- **Retention**: 30 days (configurable via `--storage.tsdb.retention.time`)
- **Configuration**: `prometheus/prometheus.yml`

Key features:
- Scrapes metrics from all exporters every 15 seconds
- Evaluates recording rules for pre-aggregation
- Evaluates alerting rules and sends to Alertmanager
- HTTP SD integration for dynamic VM discovery

### Grafana (Visualization)

- **Role**: Dashboard and visualization platform
- **Port**: 3000
- **Configuration**: `grafana/provisioning/`

Provisioned resources:
- Prometheus and Alertmanager datasources
- Four pre-built dashboards:
  - Cluster Overview
  - VM Comparison
  - VM Detail
  - Host-Guest Correlation

### Alertmanager (Notifications)

- **Role**: Alert routing, grouping, and delivery
- **Port**: 9093
- **Configuration**: `alertmanager/alertmanager.yml`

Features:
- Groups alerts by alertname, severity, and node
- Routes critical alerts to multiple channels
- Inhibition rules to suppress cascading alerts
- Webhook and email notification support

### Discovery Service (VM Discovery)

- **Role**: HTTP service discovery endpoint for Prometheus
- **Port**: 8000
- **Technology**: Python FastAPI

The discovery service:
1. Queries Proxmox API for running VMs
2. Extracts VM configuration metadata (vCPU, RAM, disk type, tags)
3. Retrieves VM IP addresses via QEMU guest agent
4. Returns targets in Prometheus HTTP SD format
5. Caches results for 60 seconds to reduce API load

### PVE Exporter

- **Role**: Proxmox VE cluster metrics
- **Port**: 9221
- **Source**: prometheus-pve-exporter

Metrics provided:
- `pve_up`: Node/VM/container status
- `pve_cpu_usage_ratio`: CPU utilization
- `pve_memory_usage_bytes`: Memory usage
- `pve_guest_info`: VM metadata labels

### Node Exporter

- **Role**: Linux host system metrics
- **Port**: 9100
- **Deployment**: Installed on each Proxmox host

Metrics provided:
- CPU per-core utilization and steal time
- Memory usage, buffers, cache, swap
- Disk I/O throughput and latency
- Network interface statistics
- Filesystem usage

### NVIDIA GPU Exporter

- **Role**: GPU metrics for vGPU monitoring
- **Port**: 9835
- **Source**: nvidia_gpu_exporter

Metrics provided:
- `nvidia_gpu_duty_cycle`: GPU utilization %
- `nvidia_gpu_memory_used_bytes`: VRAM usage
- `nvidia_gpu_temperature_celsius`: Temperature
- `nvidia_gpu_power_usage_watts`: Power draw

### Windows Exporter (VM Agent)

- **Role**: Windows guest metrics
- **Port**: 9182
- **Deployment**: Installed on each Windows VM

Collectors enabled:
- `cpu`: Per-core CPU time
- `memory`: Physical and virtual memory
- `logical_disk`: Per-volume I/O and space
- `physical_disk`: Physical disk I/O
- `net`: Per-interface network stats
- `process`: Per-process CPU and memory
- `system`: Context switches, threads
- `os`: Uptime, processes, paging

## Data Flow

```
┌────────────────────────────────────────────────────────────────────────────┐
│                                Data Flow                                    │
└────────────────────────────────────────────────────────────────────────────┘

1. Discovery
   ┌──────────────┐     HTTP GET     ┌──────────────────┐
   │  Prometheus  │ ───────────────► │ Discovery Service │
   │              │ ◄─────────────── │                   │
   │              │   JSON targets   │                   │
   └──────────────┘                  └────────┬─────────┘
                                              │
                                              │ API Query
                                              ▼
                                     ┌──────────────────┐
                                     │   Proxmox API    │
                                     │   (port 8006)    │
                                     └──────────────────┘

2. Metrics Scraping
   ┌──────────────┐
   │  Prometheus  │
   │              │
   └──────┬───────┘
          │
          ├──► node_exporter (:9100) ──► Host system metrics
          │
          ├──► pve-exporter (:9221) ──► Proxmox cluster metrics
          │
          ├──► nvidia-gpu (:9835) ──► GPU metrics
          │
          └──► windows_exporter (:9182) ──► VM guest metrics (per VM)

3. Alerting
   ┌──────────────┐     firing      ┌──────────────────┐
   │  Prometheus  │ ───────────────►│   Alertmanager   │
   │  (evaluates  │                 │   (routes)       │
   │   rules)     │                 └────────┬─────────┘
   └──────────────┘                          │
                                             ├──► Webhook
                                             └──► Email

4. Visualization
   ┌──────────────┐    PromQL       ┌──────────────────┐
   │   Grafana    │ ───────────────►│    Prometheus    │
   │  (dashboards)│ ◄───────────────│                  │
   │              │   time series   │                  │
   └──────────────┘                 └──────────────────┘
```

## Metrics Schema

### Label Strategy

All VM metrics include consistent labels for correlation:

| Label | Source | Description |
|-------|--------|-------------|
| `vm_id` | Discovery | Proxmox VMID (e.g., "100") |
| `vm_name` | Discovery | Human-readable name |
| `node` | Discovery | Proxmox host node name |
| `vcpus` | Discovery | Number of virtual CPUs |
| `memory_gb` | Discovery | RAM allocation in GB |
| `disk_type` | Discovery | virtio, scsi, ide, sata |
| `tags` | Discovery | Proxmox VM tags |
| `instance` | Prometheus | Target address (IP:port) |

### Recording Rules

Pre-aggregated metrics for dashboard performance:

```
node:cpu_utilization:avg5m      - Host CPU % averaged over 5m
node:memory_utilization:ratio   - Host memory % 
vm:cpu_utilization:avg5m        - VM CPU % averaged over 5m
vm:memory_utilization:ratio     - VM memory %
vm:disk_read_latency:avg5m      - VM disk read latency
gpu:utilization:avg5m           - GPU utilization %
```

## Security

### Network Security

- All exporter ports should be firewalled to allow only Prometheus server
- Use TLS for production deployments (configure in exporter web configs)
- Proxmox API uses token authentication (no password stored)

### Credentials

| Credential | Storage | Purpose |
|------------|---------|---------|
| Proxmox API token | `pve-exporter/pve.yml` | Read-only cluster access |
| Grafana admin | `.env` | Dashboard administration |
| SMTP credentials | `.env` | Email alerts |
| Webhook URL | `.env` / `alertmanager.yml` | Alert delivery |

### Principle of Least Privilege

- Proxmox user has `PVEAuditor` role only (read-only)
- Discovery service is read-only (no VM control)
- Windows exporter runs as LocalSystem (required for metrics)

## Scalability

### Current Design

- Single Prometheus instance with 30-day retention
- Suitable for: ~100 VMs, 3-5 hosts

### Scaling Options

For larger deployments:

1. **Federation**: Multiple Prometheus instances per cluster, federated to central
2. **Remote Write**: Stream to Thanos, Mimir, or VictoriaMetrics for long-term storage
3. **Sharding**: Split scrape targets across multiple Prometheus instances
4. **Recording Rules**: Pre-aggregate heavily to reduce query load

## High Availability

For production HA:

1. **Prometheus**: Run 2 replicas with identical config (both scrape, dedupe at query)
2. **Alertmanager**: Cluster mode with gossip protocol
3. **Grafana**: Stateless with shared PostgreSQL/MySQL backend
4. **Discovery Service**: Multiple replicas behind load balancer

## Backup & Recovery

### What to Back Up

| Component | Data Location | Backup Method |
|-----------|---------------|---------------|
| Prometheus data | Docker volume `prometheus_data` | Volume snapshot |
| Grafana config | Docker volume `grafana_data` | Volume snapshot |
| Dashboards | `grafana/provisioning/dashboards/json/` | Git |
| Configuration | `.env`, `*.yml` | Git (secrets excluded) |
| Alert history | Alertmanager volume | Volume snapshot |

### Recovery

1. Restore Docker volumes from snapshots
2. Redeploy with `docker-compose up -d`
3. Verify data with Prometheus query: `prometheus_tsdb_head_samples_appended_total`
