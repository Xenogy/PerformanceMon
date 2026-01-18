# Copilot Instructions for Proxmox Performance Monitor

## Project Overview

A Docker Compose-based monitoring stack for Proxmox VE environments with Windows VMs. Uses Prometheus for metrics collection, Grafana for visualization, and Alertmanager for notifications.

## Architecture

```
Prometheus → scrapes → PVE Exporter (Proxmox API) + Node Exporter (host) + Windows Exporter (VMs)
                   ↓
          Discovery Service (FastAPI) → queries Proxmox API for VM targets
                   ↓
              Grafana dashboards + Alertmanager notifications
```

**Key services** (ports): Prometheus `:9090`, Grafana `:3000`, Alertmanager `:9093`, Discovery Service `:8000`, PVE Exporter `:9221`, Windows Exporter `:9182`

## Essential Files

| Purpose | Location |
|---------|----------|
| Stack orchestration | [docker-compose.yml](../docker-compose.yml) |
| Prometheus scrape config | [prometheus/prometheus.yml](../prometheus/prometheus.yml) |
| Alert definitions | [prometheus/rules/alerts.yml](../prometheus/rules/alerts.yml) |
| Recording rules (pre-aggregation) | [prometheus/rules/recording.yml](../prometheus/rules/recording.yml) |
| VM discovery service | [discovery-service/main.py](../discovery-service/main.py) |
| Dashboard JSON | [grafana/provisioning/dashboards/json/](../grafana/provisioning/dashboards/json/) |
| Windows agent installer | [agents/windows/Install-WindowsExporter.ps1](../agents/windows/Install-WindowsExporter.ps1) |

## Development Workflows

### Start/Stop Stack
```bash
docker-compose up -d          # Start all services
docker-compose logs -f        # Stream logs
docker-compose down           # Stop services
```

### Reload Configuration (no restart)
```bash
curl -X POST http://localhost:9090/-/reload    # Prometheus
curl -X POST http://localhost:9093/-/reload    # Alertmanager
```

### Test Alerts
```bash
./scripts/test-alerts.sh [cpu|memory|disk|all]  # Requires stress-ng, fio
```

## Conventions & Patterns

### Prometheus Labels
VM metadata flows from Discovery Service → Prometheus relabeling. Standard labels:
- `vm_id`, `vm_name`, `node` - VM identification
- `vcpus`, `memory_gb`, `tags`, `disk_type` - configuration metadata

### Recording Rules Naming
Follow pattern: `<scope>:<metric>:<aggregation>` (e.g., `vm:cpu_utilization:avg5m`, `node:memory_utilization:ratio`)

### Alert Naming
- Host alerts: `Host<Metric><Condition>` (e.g., `HostCpuStealHigh`)
- VM alerts: `Guest<Metric><Condition>` (e.g., `GuestCpuSaturation`)

### Grafana Dashboards
- Stored as provisioned JSON in `grafana/provisioning/dashboards/json/`
- Use variables `$node`, `$vm_name`, `$vm_id` for filtering
- Reference recording rules for performance (not raw metrics)

## Critical Integration Points

### Discovery Service → Prometheus
- Endpoint: `GET /targets` returns Prometheus HTTP SD format
- Labels prefixed with `__meta_` get relabeled in `prometheus.yml` under `windows-vms` job
- 60-second cache (configurable via `CACHE_TTL_SECONDS`)

### PVE Exporter Filtering
VM filtering by node/VMID happens in `prometheus.yml` via `metric_relabel_configs`:
```yaml
- source_labels: [id]
  regex: '^(node/gpu1|qemu/(600[12]|70[0-9]{2}))$'
  action: keep
```

### Alert Inhibition
Host-level alerts (`HostDown`) suppress child VM alerts via `inhibit_rules` in `alertmanager.yml`

## Adding New Components

### New Alert
1. Add rule to [prometheus/rules/alerts.yml](../prometheus/rules/alerts.yml) under appropriate group
2. Follow naming convention and include `severity` label (`warning`/`critical`)
3. Add runbook entry in [docs/runbook.md](../docs/runbook.md)

### New Recording Rule
1. Add to [prometheus/rules/recording.yml](../prometheus/rules/recording.yml)
2. Pre-aggregate expensive queries used in dashboards
3. Follow `<scope>:<metric>:<aggregation>` naming

### New Grafana Dashboard
1. Export JSON from Grafana UI
2. Save to `grafana/provisioning/dashboards/json/<name>.json`
3. Dashboards auto-load on container restart

## vGPU Monitoring

All deployments use NVIDIA vGPU. The `nvidia-gpu-exporter` runs on the Proxmox host and requires:
- Host access to `/usr/bin/nvidia-smi` and `/dev/nvidia*` devices
- `libnvidia-ml.so` library mounted into the container

GPU metrics are collected from the **host perspective** (not inside VMs). Key metrics:
- `nvidia_gpu_duty_cycle` - GPU utilization %
- `nvidia_gpu_memory_used_bytes` / `nvidia_gpu_memory_total_bytes` - VRAM
- `nvidia_gpu_temperature_celsius` - Temperature

Recording rules aggregate these as `gpu:utilization:avg5m`, `gpu:memory_utilization:ratio`, `gpu:temperature:current`.

## Environment Configuration

Required in `.env` or `pve-exporter/pve.yml`:
- Proxmox API credentials (`PROXMOX_HOST`, `PROXMOX_USER`, `PROXMOX_TOKEN_*`)
- Target node filtering (`TARGET_NODES`)
- Grafana admin credentials (`GRAFANA_ADMIN_USER/PASSWORD`)
