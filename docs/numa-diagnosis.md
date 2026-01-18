# NUMA Remote Access Diagnosis Guide

## Understanding the Issue

Remote NUMA access occurs when a process or VM accesses memory from a different NUMA node than the CPU it's running on. This adds significant latency (2-3x slower than local access).

## Diagnosis Steps

### 1. Confirm the Problem Severity

In Prometheus/Grafana, run:

```promql
# Current remote access percentage
rate(node_memory_numa_other_node[5m]) / 
(rate(node_memory_numa_local_node[5m]) + rate(node_memory_numa_other_node[5m]))
```

**Thresholds:**
- < 5%: Normal
- 5-10%: Monitor
- 10-20%: Investigate
- > 20%: Critical - significant performance impact

### 2. Check NUMA Node Memory Balance

```promql
# Free memory per NUMA node
node_memory_numa_MemFree by (node_id)

# Total memory per NUMA node
node_memory_numa_MemTotal by (node_id)

# Utilization per NUMA node
1 - (node_memory_numa_MemFree / node_memory_numa_MemTotal)
```

**Look for:** One NUMA node heavily utilized while others have free memory.

### 3. Identify VM Distribution

On the Proxmox host, check current VM NUMA pinning:

```bash
# List all running VMs and their NUMA policies
for vmid in $(qm list | grep running | awk '{print $1}'); do
  echo "=== VM $vmid ==="
  qm config $vmid | grep -E "numa|cores|sockets"
done
```

Check process NUMA binding:
```bash
# Show NUMA node CPU usage
numastat

# Show per-process NUMA stats
numastat -p $(pgrep -f "kvm.*vmid")

# Show NUMA node distances (latency)
numactl --hardware
```

### 4. Check for Recent Changes

**Possible causes of sudden NUMA issues:**

1. **VM Migration/Restart**
   - VMs may have been migrated or restarted
   - NUMA policy may have been reset to default
   - Check migration logs: `tail -100 /var/log/pve/tasks/active`

2. **Memory Ballooning**
   - Balloon driver moved memory between NUMA nodes
   - Check: `qm status <vmid> --verbose`

3. **Transparent Huge Pages (THP)**
   - THP defragmentation can cause cross-NUMA movement
   - Check: `cat /sys/kernel/mm/transparent_hugepage/enabled`
   - Check defrag: `cat /sys/kernel/mm/transparent_hugepage/defrag`

4. **Kernel Updates**
   - Scheduler changes may affect NUMA placement
   - Check recent updates: `grep -i numa /var/log/dpkg.log`

5. **VM Configuration Changes**
   - Check if NUMA was explicitly disabled
   - Look for: `numa: 0` in VM config files

### 5. Check Memory Reclaim Activity

High memory pressure causes the kernel to reclaim from any NUMA node:

```promql
# Page reclaim rate
rate(node_vmstat_pgsteal_direct[5m])
rate(node_vmstat_pgsteal_kswapd[5m])

# Compaction events (can trigger cross-NUMA moves)
rate(node_vmstat_compact_migrate_scanned[5m])
```

### 6. Host-Level Investigation

On the Proxmox host:

```bash
# Real-time NUMA stats (update every 2 seconds)
watch -n 2 numastat

# Per-process NUMA memory distribution
for pid in $(pgrep kvm); do
  echo "PID $pid:"
  numastat -p $pid
done

# Check CPU scheduler stats per NUMA node
grep -H . /sys/devices/system/node/node*/numastat

# Check if automatic NUMA balancing is enabled
cat /proc/sys/kernel/numa_balancing

# View NUMA policy for running VMs
ps aux | grep kvm | grep -v grep | while read line; do
  pid=$(echo $line | awk '{print $2}')
  echo "=== PID $pid ==="
  cat /proc/$pid/numa_maps | head -20
done
```

## Common Root Causes & Solutions

### 1. NUMA Node Memory Imbalance

**Symptom:** One NUMA node is out of memory, forcing allocations from remote node.

**Solution:**
```bash
# Rebalance VMs across NUMA nodes
# For each over-committed node, migrate some VMs

# Option 1: Live migrate to redistribute
qm migrate <vmid> <target-node>

# Option 2: Stop and restart with NUMA binding
qm stop <vmid>
# Edit config: add 'numa: 1' to enable NUMA awareness
qm start <vmid>
```

### 2. NUMA Disabled on VMs

**Symptom:** VM config has `numa: 0` or no NUMA setting.

**Solution:**
```bash
# Enable NUMA for VM (requires VM restart)
qm set <vmid> -numa 1

# For multi-socket VMs, ensure sockets match NUMA topology
qm set <vmid> -sockets 2 -cores 44  # Example: 2 sockets for 2 NUMA nodes
```

### 3. Automatic NUMA Balancing Thrashing

**Symptom:** Kernel is constantly moving memory between nodes.

**Check:**
```bash
# If enabled and causing issues, consider disabling
cat /proc/sys/kernel/numa_balancing  # 1 = enabled

# Disable temporarily to test
echo 0 > /proc/sys/kernel/numa_balancing
```

**Note:** Usually automatic NUMA balancing is helpful. Only disable if you see evidence of thrashing.

### 4. THP Defragmentation Causing Cross-NUMA Moves

**Symptom:** High `compact_migrate_scanned` in vmstat.

**Solution:**
```bash
# Check current setting
cat /sys/kernel/mm/transparent_hugepage/defrag

# Set to madvise (less aggressive)
echo madvise > /sys/kernel/mm/transparent_hugepage/defrag
```

### 5. Memory Overcommitment

**Symptom:** Total VM memory > physical memory per NUMA node.

**Solution:**
```bash
# Calculate memory per NUMA node
numactl --hardware | grep "node.*size"

# List VM memory allocations
qm list | awk '{sum+=$4} END {print "Total VM RAM: " sum/1024 " GB"}'

# Reduce overcommit or add RAM
```

## Monitoring & Alerting

### Add Grafana Dashboard Panel

Add this query to a dashboard:

```promql
# NUMA remote access percentage
(
  rate(node_memory_numa_other_node[5m]) / 
  (rate(node_memory_numa_local_node[5m]) + rate(node_memory_numa_other_node[5m]))
) * 100
```

### Add Prometheus Alert

Add to `prometheus/rules/alerts.yml`:

```yaml
- alert: HostNumaRemoteAccessHigh
  expr: |
    (rate(node_memory_numa_other_node[5m]) / 
    (rate(node_memory_numa_local_node[5m]) + rate(node_memory_numa_other_node[5m]))) > 0.15
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "High NUMA remote access on {{ $labels.instance }}"
    description: "{{ $value | humanizePercentage }} of memory access is remote, causing performance degradation."
```

## Prevention

1. **Proper VM Sizing**
   - Keep VM memory <= NUMA node size when possible
   - For large VMs, enable NUMA and use virtual NUMA topology

2. **NUMA-Aware Pinning**
   ```bash
   # Pin VM to specific NUMA node
   qm set <vmid> -numa 1
   qm set <vmid> -cpuunits 1024
   # Then use host's numactl to pin qemu process
   ```

3. **Monitoring**
   - Set up alerts for NUMA remote access > 15%
   - Track trends to catch gradual degradation

4. **Regular Rebalancing**
   - Review VM placement monthly
   - Migrate VMs if NUMA nodes become imbalanced

## Quick Commands Reference

```bash
# Show NUMA topology
numactl --hardware

# Show current NUMA stats
numastat

# Show per-process NUMA allocation
numastat -p <pid>

# Run command on specific NUMA node
numactl --cpunodebind=0 --membind=0 <command>

# Show VM NUMA config
qm config <vmid> | grep numa

# Enable NUMA for VM
qm set <vmid> -numa 1
```

## Additional Resources

- [Proxmox NUMA Documentation](https://pve.proxmox.com/wiki/NUMA)
- [Linux NUMA Documentation](https://www.kernel.org/doc/html/latest/vm/numa.html)
- Node Exporter NUMA metrics: `node_memory_numa_*`
