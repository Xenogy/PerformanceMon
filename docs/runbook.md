# Operations Runbook

This runbook provides procedures for investigating and resolving common issues detected by the monitoring platform.

## Alert Response Procedures

### HostCpuStealHigh

**Severity**: Warning  
**Condition**: CPU steal > 5% for 5 minutes

**What it means**: The hypervisor is not giving the host's VMs their fair share of CPU time. This indicates host-level contention.

**Investigation**:

1. Check host CPU utilization:
   ```promql
   node:cpu_utilization:avg5m{instance="<host>"}
   ```

2. Identify VMs consuming the most CPU:
   ```promql
   topk(10, pve_cpu_usage_ratio{node="<node>"})
   ```

3. Check for noisy neighbors - VMs with high CPU not in this alert:
   ```promql
   pve_cpu_usage_ratio{node="<node>"} > 0.8
   ```

**Resolution**:

1. **Immediate**: Identify and throttle/migrate high-CPU VMs
2. **Short-term**: Rebalance VM distribution across hosts
3. **Long-term**: Add host capacity or review VM sizing

---

### HostMemoryLow

**Severity**: Warning  
**Condition**: Memory utilization > 90% for 5 minutes

**What it means**: The Proxmox host is running low on physical memory, which may trigger swapping or OOM kills.

**Investigation**:

1. Check memory breakdown:
   ```promql
   node_memory_MemTotal_bytes{instance="<host>"} - node_memory_MemAvailable_bytes{instance="<host>"}
   ```

2. Check if swap is active:
   ```promql
   node_memory_SwapTotal_bytes{instance="<host>"} - node_memory_SwapFree_bytes{instance="<host>"}
   ```

3. Identify memory-hungry VMs:
   ```promql
   topk(10, pve_memory_usage_bytes{node="<node>"})
   ```

**Resolution**:

1. **Immediate**: Identify VMs using more memory than allocated (ballooning)
2. **Short-term**: Migrate VMs to hosts with more memory
3. **Long-term**: Add host memory or reduce VM allocations

---

### HostSwapActive

**Severity**: Warning  
**Condition**: Any swap usage for 5 minutes

**What it means**: The host is using swap space, which severely impacts performance.

**Investigation**:

1. Check swap usage trend:
   ```promql
   (node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes){instance="<host>"}
   ```

2. Check memory pressure:
   ```promql
   node:memory_utilization:ratio{instance="<host>"}
   ```

**Resolution**:

1. **Immediate**: Identify cause of memory pressure
2. **Short-term**: Migrate VMs or reduce memory allocations
3. **Long-term**: Increase host RAM or implement memory overcommit policies

---

### GuestCpuSaturation

**Severity**: Warning  
**Condition**: VM CPU > 90% for 10 minutes

**What it means**: A VM is consistently using nearly all its allocated CPU.

**Investigation**:

1. Check if this correlates with host steal:
   ```promql
   node:cpu_utilization:avg5m{instance="<host>"}
   ```
   
2. Check per-core usage in the VM:
   ```promql
   100 - (rate(windows_cpu_time_total{vm_name="<vm>", mode="idle"}[5m]) * 100)
   ```

3. Identify top processes:
   - Use Grafana "VM Detail" dashboard → Top Processes panel
   - Or connect to VM and use Task Manager

**Resolution**:

1. **If host is OK**: VM needs more vCPUs or application optimization
2. **If host steal is high**: VM is victim of contention, migrate or rebalance
3. **Application issue**: Investigate runaway process in guest

---

### GuestDiskLatencyHigh

**Severity**: Warning  
**Condition**: Logical disk latency > 50ms for 5 minutes

**What it means**: Storage I/O is slow, impacting VM performance. This measures logical disk latency which includes filesystem cache effects.

**Investigation**:

1. Check if latency is on read, write, or both:
   ```promql
   vm:disk_read_latency:avg5m{vm_name="<vm>"}
   vm:disk_write_latency:avg5m{vm_name="<vm>"}
   ```

2. Compare to physical disk latency (bypasses cache):
   ```promql
   vm:physical_disk_read_latency:avg5m{vm_name="<vm>"}
   vm:physical_disk_write_latency:avg5m{vm_name="<vm>"}
   ```

3. Check disk queue depth:
   ```promql
   vm:disk_queue_depth:avg5m{vm_name="<vm>"}
   ```

4. Compare to host disk latency:
   ```promql
   node:disk_read_latency:avg5m
   node:disk_write_latency:avg5m
   ```

**Resolution**:

1. **If host latency is high**: Storage backend issue (SAN, NFS, local disk)
2. **If only guest is affected**: VM disk configuration (change to virtio, increase cache)
3. **If queue depth > 4**: Disk is saturated, storage can't keep up with I/O
4. **If physical latency OK but logical high**: Filesystem issue (fragmentation, antivirus)

---

### GuestPhysicalDiskLatencyHigh

**Severity**: Warning  
**Condition**: Physical disk latency > 20ms for 5 minutes

**What it means**: True storage latency is high. Physical disk metrics bypass filesystem cache, so this indicates actual storage performance issues.

**Investigation**:

1. Compare physical vs logical disk latency:
   ```promql
   vm:physical_disk_read_latency:avg5m{vm_name="<vm>"}
   vm:disk_read_latency:avg5m{vm_name="<vm>"}  # logical
   ```

2. Check host-level disk metrics:
   ```promql
   node:disk_io_weighted:rate5m{device="<device>"}
   ```

3. Check if multiple VMs on same storage are affected:
   ```promql
   vm:physical_disk_read_latency:avg5m > 0.02
   ```

**Resolution**:

1. **Single VM affected**: VM disk configuration issue
2. **Multiple VMs affected**: Shared storage bottleneck
3. **Host weighted I/O high**: Storage backend saturated

---

### GuestDiskQueueSaturated

**Severity**: Warning  
**Condition**: Disk queue depth > 4 for 5 minutes

**What it means**: More I/O requests are being queued than the disk can handle. Queue depths > 2-4 indicate the storage cannot keep up.

**Investigation**:

1. Check queue depth trend:
   ```promql
   vm:disk_queue_depth:avg5m{vm_name="<vm>"}
   ```

2. Check I/O throughput:
   ```promql
   vm:disk_read_bytes:rate5m{vm_name="<vm>"}
   vm:disk_write_bytes:rate5m{vm_name="<vm>"}
   ```

3. Check if disk is 100% busy:
   ```promql
   vm:disk_busy:ratio{vm_name="<vm>"}
   ```

**Resolution**:

1. **Reduce I/O load**: Identify high-I/O processes, defer batch jobs
2. **Faster storage**: Move VM to faster storage (NVMe, SSD)
3. **More spindles**: If HDD, spread I/O across more disks
4. **Application optimization**: Add caching, reduce write frequency

---

### GuestDiskBusy

**Severity**: Warning  
**Condition**: Disk busy > 95% for 10 minutes

**What it means**: The disk has almost no idle time, indicating maximum utilization.

**Investigation**:

1. Check disk busy percentage:
   ```promql
   vm:disk_busy:ratio{vm_name="<vm>"}
   ```

2. Check queue depth (indicates severity):
   ```promql
   vm:disk_queue_depth:avg5m{vm_name="<vm>"}
   ```

3. Identify I/O pattern:
   ```promql
   vm:disk_read_bytes:rate5m{vm_name="<vm>"}
   vm:disk_write_bytes:rate5m{vm_name="<vm>"}
   ```

**Resolution**:

1. **High reads**: Add RAM to reduce read I/O (more cache)
2. **High writes**: Check for logging, temp files, or write-heavy apps
3. **Move to faster storage**: SSD/NVMe if on HDD

---

### HostDiskSaturated

**Severity**: Warning  
**Condition**: Weighted I/O time > 80% for 5 minutes

**What it means**: Host storage is saturated. Weighted I/O time accounts for queue depth, making it a better saturation indicator than simple latency.

**Investigation**:

1. Check weighted I/O time per device:
   ```promql
   node:disk_io_weighted:rate5m
   ```

2. Check which VMs are causing most I/O:
   ```promql
   topk(5, rate(pve_disk_write_bytes[5m]))
   ```

3. Check host-level latency:
   ```promql
   node:disk_read_latency:avg5m
   node:disk_write_latency:avg5m
   ```

**Resolution**:

1. **Identify I/O hogs**: Throttle or migrate high-I/O VMs
2. **Storage upgrade**: Faster disks or add caching (ZFS L2ARC, bcache)
3. **Spread load**: Distribute VMs across multiple storage pools

---

### GuestNetworkPacketDrops

**Severity**: Warning  
**Condition**: Packet drops > 0 for 5 minutes

**What it means**: The VM is dropping network packets, indicating congestion or misconfiguration.

**Investigation**:

1. Check drop direction (inbound vs outbound):
   ```promql
   rate(windows_net_packets_received_discarded_total{vm_name="<vm>"}[5m])
   rate(windows_net_packets_outbound_discarded_total{vm_name="<vm>"}[5m])
   ```

2. Check network throughput (saturation):
   ```promql
   rate(windows_net_bytes_received_total{vm_name="<vm>"}[5m])
   ```

3. Check host network:
   ```promql
   rate(node_network_receive_drop_total{instance="<host>"}[5m])
   ```

**Resolution**:

1. **If host is dropping**: Network infrastructure issue
2. **If only guest**: NIC driver issue, increase ring buffers, or application not reading fast enough
3. **Saturation**: Need more network bandwidth

---

### VmDown

**Severity**: Critical  
**Condition**: VM not running for 2 minutes

**What it means**: A VM is not running according to Proxmox.

**Investigation**:

1. Check VM status in Proxmox:
   ```bash
   qm status <vmid>
   ```

2. Check Proxmox logs:
   ```bash
   journalctl -u pve-cluster -n 50
   tail -50 /var/log/pve/tasks/active
   ```

3. Check if intentional (maintenance window, user action)

**Resolution**:

1. **If unplanned**: Start the VM via Proxmox UI or `qm start <vmid>`
2. **If host issue**: Check host health and migrate if needed
3. **If recurring**: Investigate cause (OOM, watchdog, storage failure)

---

### GuestGpuUtilizationHigh

**Severity**: Warning  
**Condition**: VM GPU > 95% for 10 minutes

**What it means**: A VM's GPU is consistently near maximum utilization.

**Investigation**:

1. Check VM GPU utilization trend:
   ```promql
   vm:gpu_utilization:avg5m{vm_name="<vm>"}
   ```

2. Check GPU memory usage:
   ```promql
   vm:gpu_memory_dedicated:bytes{vm_name="<vm>"}
   ```

3. Check which GPU engines are busy:
   ```promql
   vm:gpu_3d_engine:rate5m{vm_name="<vm>"}
   vm:gpu_compute_engine:rate5m{vm_name="<vm>"}
   vm:gpu_video_encode:rate5m{vm_name="<vm>"}
   vm:gpu_video_decode:rate5m{vm_name="<vm>"}
   ```

4. Compare to host-side GPU metrics:
   ```promql
   gpu:utilization:avg5m
   ```

**Resolution**:

1. **If expected workload**: GPU is right-sized for the job
2. **If 3D/Compute high**: Check for runaway GPU processes in Task Manager
3. **If Video encode/decode high**: Check for transcoding or streaming apps
4. **If recurring**: Consider assigning more vGPU resources or optimizing workload

---

### GuestGpuMemoryLow

**Severity**: Warning  
**Condition**: VM GPU dedicated memory > 95% for 5 minutes

**What it means**: A VM is running low on dedicated GPU VRAM.

**Investigation**:

1. Check GPU memory usage:
   ```promql
   vm:gpu_memory_dedicated:bytes{vm_name="<vm>"}
   vm:gpu_memory_shared:bytes{vm_name="<vm>"}
   ```

2. Check if shared memory is also increasing (indicates spillover):
   ```promql
   rate(windows_gpu_memory_shared_bytes{vm_name="<vm>"}[5m])
   ```

3. Check GPU utilization (high utilization + high memory = expected):
   ```promql
   vm:gpu_utilization:avg5m{vm_name="<vm>"}
   ```

**Resolution**:

1. **Identify memory-hungry apps**: Use Task Manager → Performance → GPU → Dedicated GPU memory
2. **If gaming/rendering**: Reduce texture quality, resolution, or close background apps
3. **If machine learning**: Reduce batch size or model size
4. **If recurring**: Assign vGPU profile with more VRAM

---

### GuestGpuMemorySpillover

**Severity**: Warning  
**Condition**: VM using > 1GB shared GPU memory for 5 minutes

**What it means**: A VM has exhausted its dedicated vGPU VRAM and is spilling over to system RAM. This significantly impacts GPU performance as data must travel over PCIe instead of staying in fast VRAM.

**Investigation**:

1. Check shared vs dedicated memory:
   ```promql
   vm:gpu_memory_dedicated:bytes{vm_name="<vm>"}
   vm:gpu_memory_shared:bytes{vm_name="<vm>"}
   ```

2. Check spillover trend:
   ```promql
   rate(vm:gpu_memory_shared:bytes{vm_name="<vm>"}[5m])
   ```

3. Check what GPU engines are active:
   ```promql
   vm:gpu_3d_engine:rate5m{vm_name="<vm>"}
   vm:gpu_compute_engine:rate5m{vm_name="<vm>"}
   ```

4. Check system RAM usage (spillover uses RAM):
   ```promql
   vm:memory_utilization:ratio{vm_name="<vm>"}
   ```

**Resolution**:

1. **Identify memory-hungry apps**: Task Manager → Performance → GPU → Shared GPU memory
2. **Reduce VRAM usage**: Lower texture quality, resolution, or close background GPU apps
3. **Assign larger vGPU profile**: If recurring, migrate VM to a profile with more VRAM
4. **Add RAM**: Ensure VM has enough system RAM to absorb spillover without paging

---

### GpuUtilizationHigh

**Severity**: Warning  
**Condition**: GPU > 95% for 10 minutes

**What it means**: GPU is near capacity.

**Investigation**:

1. Check GPU memory as well:
   ```promql
   gpu:memory_utilization:ratio
   ```

2. Check temperature:
   ```promql
   nvidia_gpu_temperature_celsius
   ```

3. If using vGPU, identify which VM is consuming:
   - Use `nvidia-smi` on host to see vGPU processes

**Resolution**:

1. **If expected workload**: GPU is right-sized for the job
2. **If unexpected**: Investigate runaway GPU process
3. **If recurring**: Add GPU capacity or optimize workloads

---

## Common Investigation Workflows

### Slow VM Performance - General

1. **Check host first**:
   - Go to "Host-Guest Correlation" dashboard
   - Compare host CPU/memory/disk to guest metrics
   
2. **If host is OK but guest is slow**:
   - Check guest CPU (is it maxed?)
   - Check guest memory (paging activity?)
   - Check guest disk latency
   
3. **If host shows contention**:
   - Check steal time (CPU)
   - Check host disk latency
   - Consider migrating VM

### Identifying Bottlenecks

Use this decision tree:

```
Is host CPU steal > 5%?
├── YES → Host CPU contention, rebalance VMs
└── NO → Is guest CPU > 90%?
    ├── YES → VM needs more vCPUs or app optimization
    └── NO → Is guest memory > 90%?
        ├── YES → VM needs more RAM or has memory leak
        └── NO → Is disk latency > 50ms?
            ├── YES → Storage bottleneck (check host disk too)
            └── NO → Is network dropping packets?
                ├── YES → Network issue
                └── NO → Check application-level metrics
```

### Comparing VM Configurations

To determine optimal VM sizing:

1. Go to "VM Comparison" dashboard
2. Select VMs with different configurations (e.g., 4 vCPU vs 8 vCPU)
3. Compare CPU utilization over same time period
4. If 8-vCPU VMs show <50% utilization, they may be over-provisioned

### Pre-Deployment Capacity Check

Before adding new VMs:

1. Check current host utilization:
   ```promql
   avg_over_time(node:cpu_utilization:avg5m[7d])
   avg_over_time(node:memory_utilization:ratio[7d])
   ```

2. Calculate headroom:
   - Target: Keep host CPU < 70%, memory < 80%
   - Account for worst-case (all VMs peak simultaneously)

3. Review historical patterns for capacity trends

## Maintenance Procedures

### Rolling Host Maintenance

1. Set maintenance window in monitoring (silence alerts)
2. Live migrate VMs off target host
3. Perform maintenance
4. Migrate VMs back or rebalance
5. End maintenance window

### Adding New Hosts

1. Install node_exporter on new host
2. Add to `prometheus/prometheus.yml`
3. Reload Prometheus: `curl -X POST http://localhost:9090/-/reload`
4. Verify target appears in Prometheus targets page

### Adding New VMs

VMs are auto-discovered. Ensure:

1. QEMU guest agent is installed (for IP discovery)
2. windows_exporter is installed
3. Firewall allows port 9182 from monitoring server

Discovery happens within 60 seconds (cache TTL).

## Escalation Procedures

| Severity | Response Time | Escalation Path |
|----------|---------------|-----------------|
| Critical | 15 minutes | On-call → Team Lead → Manager |
| Warning | 4 hours | Next business day review |
| Info | 24 hours | Weekly review meeting |

## Contact Information

| Role | Contact | Hours |
|------|---------|-------|
| On-Call | [Your pager/phone] | 24/7 |
| Team Lead | [Contact info] | Business hours |
| Storage Team | [Contact info] | Business hours |
| Network Team | [Contact info] | Business hours |
