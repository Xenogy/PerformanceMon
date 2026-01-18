# Deployment Guide

This guide covers deploying the monitoring platform for production use.

## Prerequisites

### Monitoring Server

- Linux server (Ubuntu 20.04+ or Debian 11+ recommended)
- Docker Engine 20.10+
- Docker Compose 2.0+
- 4+ CPU cores, 8GB+ RAM, 100GB+ disk (for 30-day retention)
- Network access to Proxmox hosts and VMs

### Proxmox Hosts

- Proxmox VE 7.x or 8.x
- Network access from monitoring server
- API access enabled (default port 8006)

### Windows VMs

- Windows 10/11 or Windows Server 2016+
- PowerShell 5.1+
- QEMU guest agent installed (for IP discovery)
- Network access from monitoring server on port 9182

## Installation Steps

### Step 1: Prepare the Server

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Install Docker Compose
sudo apt install docker-compose-plugin

# Clone the repository
git clone <repository-url> /opt/PerformanceMonitor
cd /opt/PerformanceMonitor
```

### Step 2: Configure Environment

```bash
# Copy example configuration
cp .env.example .env
cp pve-exporter/pve.yml.example pve-exporter/pve.yml

# Edit environment variables
nano .env
```

Required settings in `.env`:

```bash
# Proxmox API (required)
PROXMOX_HOST=192.168.1.100
PROXMOX_USER=prometheus@pve
PROXMOX_TOKEN_NAME=monitoring
PROXMOX_TOKEN_VALUE=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Grafana (change password!)
GRAFANA_ADMIN_PASSWORD=your-secure-password

# Alerting (optional)
ALERT_WEBHOOK_URL=https://your-webhook.example.com/alerts
ALERT_EMAIL_TO=admin@example.com
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_FROM=alerts@example.com
```

Edit `pve-exporter/pve.yml`:

```yaml
default:
  user: prometheus@pve
  token_name: monitoring
  token_value: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  verify_ssl: false  # Set true if using valid SSL
```

### Step 3: Create Proxmox API Token

On your Proxmox server:

```bash
# Create user
pveum user add prometheus@pve

# Create API token
pveum user token add prometheus@pve monitoring --privsep=0

# Grant read-only access
pveum acl modify / -user prometheus@pve -role PVEAuditor
```

Copy the displayed token value to your configuration.

### Step 4: Configure Proxmox Hosts

Edit `prometheus/prometheus.yml` to add your Proxmox host IPs:

```yaml
- job_name: 'pve-nodes'
  static_configs:
    - targets:
        - '192.168.1.100:9100'  # pve-node-1
        - '192.168.1.101:9100'  # pve-node-2
        - '192.168.1.102:9100'  # pve-node-3
```

On each Proxmox host, install node_exporter:

```bash
apt update
apt install prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
```

### Step 5: Deploy the Stack

```bash
# Start all services
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f
```

### Step 6: Install Windows Agent

For each Windows VM, copy the agent scripts and run:

```powershell
# Download from monitoring server or copy manually
# Then run as Administrator:
.\Install-WindowsExporter.ps1
```

Verify installation:
```powershell
# Check service
Get-Service windows_exporter

# Test metrics
Invoke-WebRequest http://localhost:9182/metrics -UseBasicParsing | Select-Object -First 5
```

### Step 7: Verify Deployment

1. **Prometheus Targets**: http://monitoring-server:9090/targets
   - All targets should show "UP"
   
2. **Discovery Service**: http://monitoring-server:8000/targets
   - Should list all Windows VMs with labels

3. **Grafana Dashboards**: http://monitoring-server:3000
   - Login with admin credentials
   - Check "Cluster Overview" dashboard

## Production Hardening

### Enable TLS

1. Generate certificates or use Let's Encrypt
2. Configure Grafana with TLS:

```yaml
# docker-compose.yml
grafana:
  environment:
    - GF_SERVER_PROTOCOL=https
    - GF_SERVER_CERT_FILE=/etc/grafana/ssl/cert.pem
    - GF_SERVER_CERT_KEY=/etc/grafana/ssl/key.pem
  volumes:
    - ./ssl:/etc/grafana/ssl:ro
```

3. Configure reverse proxy (nginx/traefik) for all services

### Secure Network Access

```bash
# On monitoring server - allow only necessary ports
ufw allow from 192.168.1.0/24 to any port 3000  # Grafana
ufw allow from 192.168.1.0/24 to any port 9090  # Prometheus (optional)
ufw allow from 192.168.1.0/24 to any port 9093  # Alertmanager (optional)
ufw enable
```

On Windows VMs - restrict exporter access:
```powershell
Set-NetFirewallRule -DisplayName "Windows Exporter (Prometheus)" `
    -RemoteAddress 192.168.1.50  # Monitoring server IP
```

### Resource Limits

Add resource limits in `docker-compose.yml`:

```yaml
prometheus:
  deploy:
    resources:
      limits:
        cpus: '2'
        memory: 4G
      reservations:
        cpus: '1'
        memory: 2G
```

### Log Management

Configure log rotation:

```yaml
# docker-compose.yml (add to each service)
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

## Upgrades

### Upgrading Components

```bash
# Pull latest images
docker-compose pull

# Recreate containers
docker-compose up -d

# Check status
docker-compose ps
```

### Upgrading Dashboards

Dashboard changes in `grafana/provisioning/dashboards/json/` are automatically reloaded.

### Database Migrations

Prometheus and Grafana handle schema migrations automatically on startup.

## Backup Procedures

### Automated Backup Script

```bash
#!/bin/bash
# backup.sh

BACKUP_DIR=/backup/monitoring
DATE=$(date +%Y%m%d_%H%M%S)

# Stop services briefly for consistent backup
docker-compose stop prometheus

# Backup volumes
docker run --rm \
    -v prometheus_data:/data \
    -v $BACKUP_DIR:/backup \
    alpine tar czf /backup/prometheus_$DATE.tar.gz /data

# Restart
docker-compose start prometheus

# Backup configs
tar czf $BACKUP_DIR/config_$DATE.tar.gz \
    docker-compose.yml \
    .env \
    prometheus/ \
    alertmanager/ \
    grafana/

# Cleanup old backups (keep 7 days)
find $BACKUP_DIR -mtime +7 -delete
```

Add to cron:
```bash
0 2 * * * /opt/PerformanceMonitor/backup.sh
```

### Restore Procedure

```bash
# Stop services
docker-compose down

# Restore volumes
docker run --rm \
    -v prometheus_data:/data \
    -v /backup/monitoring:/backup \
    alpine tar xzf /backup/prometheus_20241229_020000.tar.gz -C /

# Restore configs
tar xzf /backup/monitoring/config_20241229_020000.tar.gz

# Start services
docker-compose up -d
```

## Troubleshooting

### Discovery Service Issues

```bash
# Check logs
docker-compose logs discovery-service

# Test Proxmox API manually
curl -k -H "Authorization: PVEAPIToken=prometheus@pve!monitoring=TOKEN" \
    https://proxmox:8006/api2/json/cluster/resources
```

### Prometheus Scrape Failures

```bash
# Check targets page
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health != "up")'

# Test exporter directly
curl http://vm-ip:9182/metrics | head
```

### Grafana Dashboard Errors

```bash
# Check provisioning logs
docker-compose logs grafana | grep -i error

# Validate JSON syntax
jq . grafana/provisioning/dashboards/json/*.json
```

## Monitoring the Monitor

The stack includes self-monitoring:

1. **Prometheus**: `/metrics` endpoint scraped by itself
2. **Discovery Service**: `/metrics` endpoint with cache stats
3. **Grafana**: Built-in metrics at `/metrics`

Alert on monitoring failures:
- `up{job="prometheus"} == 0`
- `up{job="discovery-service"} == 0`
- `prometheus_tsdb_storage_blocks_bytes` trending toward limit
