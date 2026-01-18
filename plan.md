## Plan: Proxmox + VM Performance Monitoring Platform

Build a pull-based monitoring stack using Prometheus, Grafana, and native exporters. Host-side `nvidia-smi` captures vGPU metrics; a cached HTTP service discovery endpoint dynamically provides VM targets; Prometheus handles 30-day retention; Grafana's built-in auth manages access.

### Steps

1. **Scaffold project structure and Docker Compose** — Create directories (prometheus/, grafana/, alertmanager/, agents/windows/, discovery-service/, docs/) and docker-compose.yml with services: Prometheus (`--storage.tsdb.retention.time=30d`), Grafana, Alertmanager, pve-exporter, nvidia-gpu-exporter, and discovery-service; define shared `monitoring` network.

2. **Configure Proxmox host collectors** — Deploy `node_exporter` on each PVE node via systemd; configure `prometheus-pve-exporter` with read-only API token in pve-exporter/pve.yml; run `nvidia_gpu_exporter` container with host access to nvidia-smi and `/dev/nvidia*`; add scrape jobs in prometheus/prometheus.yml for each exporter.

3. **Build HTTP service discovery endpoint** — Create discovery-service/ as a FastAPI app with `GET /targets` returning Prometheus HTTP SD format; query Proxmox API via `proxmoxer` with 60-second in-memory cache (TTL); return targets with labels (`__address__`, `vm_id`, `vm_name`, `vcpus`, `memory_gb`, `node`, `tags`); include discovery-service/Dockerfile, discovery-service/requirements.txt, and `/health` endpoint; configure Prometheus `http_sd_configs` with 30s refresh interval.

4. **Create Windows agent installer** — Write agents/windows/Install-WindowsExporter.ps1 that downloads latest `windows_exporter` MSI, installs with collectors `cpu,cs,logical_disk,physical_disk,memory,net,os,process,system`, configures firewall rule for port 9182, starts service; include agents/windows/Uninstall-WindowsExporter.ps1 and agents/windows/README.md.

5. **Define recording and alerting rules** — Create prometheus/rules/recording.yml with pre-aggregated metrics for dashboard performance; create prometheus/rules/alerts.yml with thresholds: `HostCpuStealHigh` (>5%, 5m), `GuestCpuSaturation` (>90%, 10m), `DiskLatencyHigh` (>50ms, 5m), `MemorySwapActive` (swap >0, 5m), `NetworkPacketDrops` (rate >0), `GpuUtilizationHigh` (>95%, 10m).

6. **Configure Alertmanager** — Set up alertmanager/alertmanager.yml with webhook receiver (primary) and email (fallback); route tree grouping by `severity` and `node`; inhibition rule suppressing VM alerts when parent host is down.

7. **Build Grafana dashboards** — Provision datasource via grafana/provisioning/datasources/prometheus.yml; create dashboards in grafana/provisioning/dashboards/: (a) **Cluster Overview** — host/VM status grid, (b) **Host Detail** — CPU/mem/disk/net/GPU with per-VM breakdown, (c) **VM Comparison** — multi-select filtered by `vcpus`/`memory_gb`/`tags`, side-by-side panels, config table, (d) **VM Detail** — single-VM drill-down with process list; enable CSV export.

8. **Write documentation and validation scripts** — Create README.md with quickstart; docs/architecture.md with component diagram; docs/deployment.md with install steps; docs/runbook.md with bottleneck procedures; scripts/test-alerts.sh using `stress-ng`/`fio` to trigger alerts and verify webhook delivery.