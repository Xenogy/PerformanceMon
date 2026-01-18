# Metrics Inventory

Current metrics collected by the Proxmox Performance Monitor stack, organized by exporter.

---

## 1. Node Exporter (Host System - `:9100`)

Collects Linux host metrics from the Proxmox server.

### Enabled Collectors

| Collector | Metrics Provided |
|-----------|------------------|
| `cpu` | Per-core CPU time by mode (user, system, idle, iowait, steal, etc.) |
| `cpu.info` | CPU model, cores, threads, frequency |
| `meminfo` | Memory usage (total, free, available, buffers, cached, swap) |
| `meminfo_numa` | Per-NUMA node memory stats |
| `filesystem` | Disk space usage per mount point |
| `diskstats` | Disk I/O (reads/writes, bytes, time, queue depth) |
| `netdev` | Network interface stats (bytes, packets, errors, drops) |
| `loadavg` | System load averages (1m, 5m, 15m) |
| `pressure` | PSI (Pressure Stall Information) for CPU, memory, I/O |
| `vmstat` | Virtual memory stats (page faults, swap activity, OOM kills) |
| `schedstat` | Scheduler statistics (run time, wait time per CPU) |
| `softnet` | Network softirq stats (processed, dropped, time_squeeze) |
| `tcpstat` | TCP connection states |
| `interrupts` | Per-CPU interrupt counts by type |
| `processes` | Process counts by state, thread totals, fork rate |
| `perf` | Hardware performance counters (see below) |

### Hardware Performance Counters (perf)

```
cycles, instructions, cache-references, cache-misses
branch-instructions, branch-misses
L1-dcache-load-misses, L1-dcache-loads, L1-icache-load-misses
LLC-load-misses, LLC-loads, LLC-store-misses, LLC-stores
```

### Key Metrics Currently Used

| Metric | Purpose |
|--------|---------|
| `node_cpu_seconds_total{mode="steal"}` | Detect host overcommitment |
| `node_memory_MemAvailable_bytes` | Available memory |
| `node_memory_SwapFree_bytes` | Swap usage detection |
| `node_disk_read/write_time_seconds_total` | Disk latency calculation |
| `node_network_receive/transmit_drop_total` | Network drops |
| `node_filesystem_avail_bytes` | Disk space alerts |
| `node_pressure_*` | PSI contention metrics |
| `node_schedstat_*` | Scheduler wait time |
| `node_vmstat_pgmajfault` | Major page faults |
| `node_context_switches_total` | Context switch rate |

### NOT Currently Collected (disabled collectors)

| Collector | What It Would Provide |
|-----------|----------------------|
| `hwmon` | Hardware sensors (temps, fans, voltages) - overlaps with GPU exporter |
| `nvme` | NVMe-specific health metrics |
| `rapl` | CPU power consumption (Running Average Power Limit) |
| `thermal_zone` | Thermal zone temperatures |
| `zfs` | ZFS pool/dataset stats (if using ZFS storage) |
| `infiniband` | InfiniBand HCA stats |
| `nfs` | NFS client stats |
| `buddyinfo` | Memory fragmentation |
| `ksmd` | Kernel Same-page Merging stats (KSM deduplication) |
| `cgroups` | Per-cgroup resource usage |

---

## 2. PVE Exporter (Proxmox API - `:9221`)

Collects cluster, node, and VM metadata from Proxmox API.

### Metrics Collected

| Metric | Description |
|--------|-------------|
| `pve_up` | Node/VM/container up status (1=running) |
| `pve_cpu_usage_ratio` | CPU utilization ratio (0-1) |
| `pve_memory_usage_bytes` | Memory used |
| `pve_memory_size_bytes` | Memory allocated |
| `pve_disk_read_bytes` | Cumulative disk reads |
| `pve_disk_write_bytes` | Cumulative disk writes |
| `pve_network_receive_bytes` | Cumulative network RX |
| `pve_network_transmit_bytes` | Cumulative network TX |
| `pve_disk_size_bytes` | VM disk size |
| `pve_guest_info` | VM metadata labels (name, node, template, etc.) |
| `pve_node_info` | Node metadata (kernel version, PVE version) |
| `pve_storage_*` | Storage pool usage |

### Labels Provided

```
id          - Resource identifier (e.g., "qemu/6001", "node/gpu1")
name        - Human-readable name
node        - Proxmox node name
```

### NOT Available from PVE Exporter

| Missing Metric | Alternative |
|----------------|-------------|
| Per-vCPU breakdown | Use windows_exporter inside VM |
| Disk latency | Use windows_exporter inside VM |
| VM process list | Use windows_exporter inside VM |
| vGPU assignment per VM | Not exposed by Proxmox API |

---

## 3. NVIDIA GPU Exporter (Host vGPU - `:9835`)

Collects GPU metrics from host-side `nvidia-smi`.

### Metrics Collected

| Metric | Description |
|--------|-------------|
| `nvidia_gpu_duty_cycle` | GPU utilization % (0-100) |
| `nvidia_gpu_memory_used_bytes` | VRAM used |
| `nvidia_gpu_memory_total_bytes` | VRAM total |
| `nvidia_gpu_temperature_celsius` | GPU temperature |
| `nvidia_gpu_power_usage_watts` | Current power draw |
| `nvidia_gpu_fan_speed_ratio` | Fan speed (0-1) |
| `nvidia_gpu_clock_graphics_hz` | Current graphics clock |
| `nvidia_gpu_clock_memory_hz` | Current memory clock |
| `nvidia_gpu_pcie_throughput_rx_bytes` | PCIe RX bandwidth |
| `nvidia_gpu_pcie_throughput_tx_bytes` | PCIe TX bandwidth |

### Labels Provided

```
gpu         - GPU index (0, 1, 2, 3)
uuid        - GPU UUID
name        - GPU model name
```

### NOT Available (vGPU limitations)

| Missing Metric | Reason |
|----------------|--------|
| Per-VM GPU utilization | vGPU doesn't expose per-VM breakdown from host |
| Per-VM VRAM usage | Same - requires in-guest monitoring |
| GPU encoder/decoder utilization | Not exposed by this exporter |
| vGPU profile info | Would need Proxmox/NVIDIA API integration |

---

## 4. Windows Exporter (VM Guests - `:9182`)

Collects Windows OS metrics from inside VMs.

### Enabled Collectors

| Collector | Metrics Provided |
|-----------|------------------|
| `cpu` | Per-core CPU time by mode (user, privileged, idle, interrupt, dpc) |
| `cs` | Computer system info (physical memory, processors) |
| `logical_disk` | Per-volume I/O, latency, space, queue depth |
| `physical_disk` | Physical disk I/O stats |
| `memory` | Memory usage, page faults, pool allocations |
| `net` | Per-interface network stats |
| `os` | OS info, uptime, paging file, process count |
| `process` | Per-process CPU, memory, handles, threads |
| `system` | Context switches, system calls, threads, processor queue |
| `thermalzone` | Thermal zone temperatures |
| `gpu` | GPU adapter utilization, VRAM usage, engine running time (3D, compute, video encode/decode) |

### Key Metrics Currently Used

| Metric | Purpose |
|--------|---------|
| `windows_cpu_time_total{mode="idle"}` | VM CPU utilization |
| `windows_os_visible_memory_bytes` | Total RAM |
| `windows_os_physical_memory_free_bytes` | Free RAM |
| `windows_logical_disk_read/write_bytes_total` | Disk throughput |
| `windows_logical_disk_read/write_seconds_total` | Disk latency |
| `windows_net_bytes_received/sent_total` | Network throughput |
| `windows_net_packets_*_discarded_total` | Network drops |
| `windows_os_paging_*_bytes` | Paging file usage |
| `windows_gpu_adapter_utilization_percentage` | GPU utilization |
| `windows_gpu_memory_dedicated_bytes` | GPU dedicated VRAM usage |
| `windows_gpu_memory_shared_bytes` | GPU shared memory usage |
| `windows_gpu_engine_running_time_seconds` | GPU engine usage (3D, compute, video) |

### NOT Currently Collected (disabled collectors)

| Collector | What It Would Provide |
|-----------|----------------------|
| `ad` | Active Directory stats (if DC) |
| `adfs` | AD Federation Services |
| `dhcp` | DHCP server stats |
| `dns` | DNS server stats |
| `exchange` | Exchange server stats |
| `hyperv` | Hyper-V stats (nested virtualization) |
| `iis` | IIS web server stats |
| `msmq` | Message queue stats |
| `mssql` | SQL Server stats |
| `netframework` | .NET CLR stats |
| `service` | Windows service states |
| `smtp` | SMTP stats |
| `tcp` | TCP connection states |
| `textfile` | Custom metrics from text files |
| `scheduled_task` | Scheduled task status/last run |
| `vmware` | VMware Tools stats (not relevant for Proxmox) |

---

## 5. Discovery Service (Self-monitoring - `:8000`)

### Metrics Collected

| Metric | Description |
|--------|-------------|
| `discovery_requests_total` | Total target requests |
| `discovery_cache_hits_total` | Cache hit count |
| `discovery_cache_misses_total` | Cache miss count |
| `discovery_errors_total` | Discovery error count |
| `discovery_targets_count` | Current discovered VMs |
| `discovery_cache_age_seconds` | Cache staleness |
| `discovery_last_duration_seconds` | Last discovery run time |

---

## Recording Rules Summary

Pre-aggregated metrics for dashboard performance:

### Host Metrics
- `node:cpu_utilization:avg5m`
- `node:memory_utilization:ratio`
- `node:disk_read/write_bytes:rate5m`
- `node:network_receive/transmit_bytes:rate5m`
- `host:cpu_pressure:some_ratio`
- `host:memory_pressure:some_ratio`, `host:memory_pressure:full_ratio`
- `host:io_pressure:some_ratio`, `host:io_pressure:full_ratio`
- `host:scheduler_wait:ratio`
- `host:context_switches:rate5m`
- `host:page_faults:rate5m`, `host:major_page_faults:rate5m`
- `host:swap_in:rate5m`, `host:swap_out:rate5m`
- `host:oom_kills:total`
- `host:numa_*`
- `host:softnet_*`
- `host:tcp_connections:*`
- `host:processes_*`, `host:threads:total`

### VM Metrics
- `vm:cpu_utilization:avg5m`
- `vm:memory_utilization:ratio`
- `vm:memory_used_gb:current`
- `vm:disk_read/write_bytes:rate5m`
- `vm:disk_read/write_latency:avg5m`
- `vm:network_receive/transmit_bytes:rate5m`
- `vm:gpu_utilization:avg5m`
- `vm:gpu_memory_dedicated:bytes`
- `vm:gpu_memory_shared:bytes`
- `vm:gpu_3d_engine:rate5m`
- `vm:gpu_compute_engine:rate5m`
- `vm:gpu_video_encode:rate5m`
- `vm:gpu_video_decode:rate5m`

### GPU Metrics (Host)
- `gpu:utilization:avg5m`
- `gpu:memory_utilization:ratio`
- `gpu:temperature:current`

### PVE Metrics
- `pve:vm_cpu:avg5m`
- `pve:vm_memory:ratio`
- `pve:running_vms:count`

---

## Latency Metrics Deep Dive

### Currently Collected Latency Metrics

| Layer | Metric | Source | Currently Used |
|-------|--------|--------|----------------|
| **Host Disk** | `node_disk_read_time_seconds_total` | node_exporter | ✅ In alerts |
| **Host Disk** | `node_disk_write_time_seconds_total` | node_exporter | ✅ In alerts |
| **Host Disk** | `node_disk_io_time_seconds_total` | node_exporter | ❌ Available |
| **Host Disk** | `node_disk_io_time_weighted_seconds_total` | node_exporter | ❌ Available |
| **VM Disk** | `windows_logical_disk_read_seconds_total` | windows_exporter | ✅ Recording rule |
| **VM Disk** | `windows_logical_disk_write_seconds_total` | windows_exporter | ✅ Recording rule |
| **VM Disk** | `windows_logical_disk_idle_seconds_total` | windows_exporter | ❌ Available |
| **VM Physical Disk** | `windows_physical_disk_read_latency_seconds_total` | windows_exporter | ❌ Available |
| **VM Physical Disk** | `windows_physical_disk_write_latency_seconds_total` | windows_exporter | ❌ Available |
| **VM Physical Disk** | `windows_physical_disk_read_write_latency_seconds_total` | windows_exporter | ❌ Available |

### Available But Not Collected Latency Metrics

#### Host-Level (Node Exporter)

| Metric | Description | Why Useful |
|--------|-------------|------------|
| `node_disk_io_time_weighted_seconds_total` | Weighted I/O time (accounts for queue depth) | Better saturation indicator than simple latency |
| `node_disk_discard_time_seconds_total` | Time spent on TRIM/discard operations | SSD maintenance overhead |
| `node_disk_flush_requests_time_seconds_total` | Time spent flushing write cache | Write cache pressure |
| `node_schedstat_waiting_seconds_total` | CPU scheduler wait time | ✅ Already collected - CPU latency |
| `node_pressure_*` | PSI metrics | ✅ Already collected - resource stall latency |

#### VM-Level (Windows Exporter)

| Metric | Description | Why Useful |
|--------|-------------|------------|
| `windows_physical_disk_read_latency_seconds_total` | Physical disk read latency | Bypasses filesystem cache effects |
| `windows_physical_disk_write_latency_seconds_total` | Physical disk write latency | More accurate than logical disk |
| `windows_physical_disk_read_write_latency_seconds_total` | Combined transfer latency | Single metric for overall disk health |
| `windows_logical_disk_avg_read_requests_queued` | Average read queue depth | Indicates disk saturation |
| `windows_logical_disk_avg_write_requests_queued` | Average write queue depth | Indicates disk saturation |
| `windows_logical_disk_requests_queued` | Current queue depth | Real-time saturation |

### Latency Metrics NOT Available (Gaps)

| Layer | Missing Metric | Why It Would Help |
|-------|----------------|-------------------|
| **Network** | TCP RTT / latency | No native exporter support; would need blackbox_exporter |
| **Network** | VM-to-host latency | Would need synthetic probes |
| **GPU** | CUDA kernel latency | Not exposed by nvidia-smi |
| **Memory** | NUMA access latency | Hardware counters exist but complex to interpret |
| **Storage** | End-to-end I/O latency (app→storage) | Would need eBPF/bpftrace |
| **API** | Proxmox API response time | Could add to discovery service |

### Recommended Latency Recording Rules to Add

```yaml
# Host weighted I/O time (better saturation metric)
- record: node:disk_io_weighted:rate5m
  expr: rate(node_disk_io_time_weighted_seconds_total[5m])

# VM physical disk latency (more accurate than logical)
- record: vm:physical_disk_read_latency:avg5m
  expr: |
    avg by (vm_id, vm_name, node, instance) (
      rate(windows_physical_disk_read_latency_seconds_total[5m]) /
      rate(windows_physical_disk_reads_total[5m])
    )

- record: vm:physical_disk_write_latency:avg5m
  expr: |
    avg by (vm_id, vm_name, node, instance) (
      rate(windows_physical_disk_write_latency_seconds_total[5m]) /
      rate(windows_physical_disk_writes_total[5m])
    )

# VM disk queue depth (saturation indicator)
- record: vm:disk_queue_depth:avg5m
  expr: |
    avg by (vm_id, vm_name, node, instance) (
      avg_over_time(windows_logical_disk_requests_queued[5m])
    )

# Disk busy percentage (alternative latency view)
- record: vm:disk_busy:ratio
  expr: |
    1 - (
      rate(windows_logical_disk_idle_seconds_total{volume!~"HarddiskVolume.*"}[5m])
    )
```

### Recommended Latency Alerts to Add

```yaml
# Physical disk latency (more sensitive than logical)
- alert: GuestPhysicalDiskLatencyHigh
  expr: vm:physical_disk_read_latency:avg5m > 0.02 or vm:physical_disk_write_latency:avg5m > 0.02
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High physical disk latency on VM {{ $labels.vm_name }}"

# Disk queue saturation
- alert: GuestDiskQueueSaturated
  expr: vm:disk_queue_depth:avg5m > 4
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Disk queue saturated on VM {{ $labels.vm_name }}"

# Host weighted I/O time high (indicates queuing)
- alert: HostDiskSaturated
  expr: node:disk_io_weighted:rate5m > 0.8
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Disk saturation on host {{ $labels.instance }}"
```

---

## Potential Metrics to Add

### High Value (Recommended)

| Metric | Source | Value |
|--------|--------|-------|
| Physical disk latency metrics | Already in windows_exporter | More accurate than logical disk |
| Disk queue depth | Already in windows_exporter | Saturation indicator |
| Weighted I/O time | Already in node_exporter | Better host disk saturation |
| ZFS pool health/fragmentation | `node_exporter --collector.zfs` | Storage health if using ZFS |
| CPU power consumption | `node_exporter --collector.rapl` | Power efficiency tracking |
| Per-VM GPU (in-guest) | NVIDIA exporter inside VM | True per-VM GPU breakdown |
| Windows services state | `windows_exporter --collectors.service` | Service availability monitoring |
| Scheduled tasks | `windows_exporter --collectors.scheduled_task` | Backup job monitoring |
| TCP connections per VM | `windows_exporter --collectors.tcp` | Connection state visibility |

### Medium Value

| Metric | Source | Value |
|--------|--------|-------|
| NVMe health | `node_exporter --collector.nvme` | SSD wear/health |
| KSM stats | `node_exporter --collector.ksmd` | Memory dedup efficiency |
| Memory fragmentation | `node_exporter --collector.buddyinfo` | Large allocation issues |
| .NET CLR stats | `windows_exporter --collectors.netframework` | .NET app monitoring |

### Application-Specific

| Metric | Source | Value |
|--------|--------|-------|
| SQL Server | `windows_exporter --collectors.mssql` | Database performance |
| IIS | `windows_exporter --collectors.iis` | Web server stats |
| Custom app metrics | `windows_exporter --collectors.textfile` | App-specific KPIs |
