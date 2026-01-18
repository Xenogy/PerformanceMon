"""
Proxmox VM Discovery Service for Prometheus HTTP Service Discovery

This service queries the Proxmox API and returns VM targets in Prometheus HTTP SD format.
It caches results to reduce API load during frequent Prometheus refreshes.
"""

import os
import time
import logging
from typing import Any
from functools import lru_cache
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from proxmoxer import ProxmoxAPI
import uvicorn

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration from environment variables
PROXMOX_HOST = os.environ.get('PROXMOX_HOST', 'localhost')
PROXMOX_USER = os.environ.get('PROXMOX_USER', 'root@pam')
PROXMOX_TOKEN_NAME = os.environ.get('PROXMOX_TOKEN_NAME', '')
PROXMOX_TOKEN_VALUE = os.environ.get('PROXMOX_TOKEN_VALUE', '')
PROXMOX_VERIFY_SSL = os.environ.get('PROXMOX_VERIFY_SSL', 'false').lower() == 'true'
CACHE_TTL_SECONDS = int(os.environ.get('CACHE_TTL_SECONDS', '60'))
WINDOWS_EXPORTER_PORT = int(os.environ.get('WINDOWS_EXPORTER_PORT', '9182'))
# Filter to specific node(s) - comma-separated list, empty means all nodes
TARGET_NODES = [n.strip() for n in os.environ.get('TARGET_NODES', '').split(',') if n.strip()]

# Cache storage
_cache: dict[str, Any] = {
    'targets': [],
    'last_updated': 0,
    'error': None
}

# Metrics counters
_metrics = {
    'requests_total': 0,
    'cache_hits': 0,
    'cache_misses': 0,
    'errors_total': 0,
    'last_discovery_duration_seconds': 0,
}


def get_proxmox_client() -> ProxmoxAPI:
    """Create a Proxmox API client using token authentication."""
    return ProxmoxAPI(
        PROXMOX_HOST,
        user=PROXMOX_USER,
        token_name=PROXMOX_TOKEN_NAME,
        token_value=PROXMOX_TOKEN_VALUE,
        verify_ssl=PROXMOX_VERIFY_SSL,
        timeout=30
    )


def fetch_vm_targets() -> list[dict]:
    """
    Query Proxmox API and return targets in Prometheus HTTP SD format.
    
    Returns a list of target groups, each containing:
    - targets: List of host:port strings
    - labels: Metadata labels for the targets
    """
    start_time = time.time()
    targets = []
    
    try:
        proxmox = get_proxmox_client()
        
        # Get all cluster resources (VMs and containers)
        resources = proxmox.cluster.resources.get(type='vm')
        
        for resource in resources:
            # Skip non-QEMU VMs (e.g., LXC containers)
            if resource.get('type') != 'qemu':
                continue
            
            # Skip VMs not on target nodes (if filtering is enabled)
            node = resource.get('node')
            if TARGET_NODES and node not in TARGET_NODES:
                continue
            
            # Skip stopped VMs
            if resource.get('status') != 'running':
                continue
            
            vmid = resource.get('vmid')
            name = resource.get('name', f'vm-{vmid}')
            
            # Get detailed VM configuration
            try:
                vm_config = proxmox.nodes(node).qemu(vmid).config.get()
            except Exception as e:
                logger.warning(f"Failed to get config for VM {vmid}: {e}")
                vm_config = {}
            
            # Extract VM IP address
            # First try to get it from QEMU guest agent
            vm_ip = None
            try:
                agent_info = proxmox.nodes(node).qemu(vmid).agent('network-get-interfaces').get()
                for iface in agent_info.get('result', []):
                    if iface.get('name') == 'lo':
                        continue
                    for ip_addr in iface.get('ip-addresses', []):
                        if ip_addr.get('ip-address-type') == 'ipv4':
                            vm_ip = ip_addr.get('ip-address')
                            break
                    if vm_ip:
                        break
            except Exception:
                # Guest agent not available or not responding
                pass
            
            # If no IP from agent, try to parse from network config
            if not vm_ip:
                for key, value in vm_config.items():
                    if key.startswith('ipconfig') and isinstance(value, str):
                        # Parse ipconfig0=ip=192.168.1.100/24,gw=192.168.1.1
                        for part in value.split(','):
                            if part.startswith('ip='):
                                ip_with_mask = part[3:]
                                vm_ip = ip_with_mask.split('/')[0]
                                break
                    if vm_ip:
                        break
            
            # Skip VMs without discoverable IP
            if not vm_ip:
                logger.debug(f"Skipping VM {name} ({vmid}): no IP address found")
                continue
            
            # Extract configuration metadata
            cores = int(vm_config.get('cores', 1))
            sockets = int(vm_config.get('sockets', 1))
            vcpus = cores * sockets
            memory_mb = int(vm_config.get('memory', 0))
            memory_gb = round(memory_mb / 1024, 1) if memory_mb else 0
            
            # Determine disk type (virtio, scsi, ide, sata)
            disk_type = 'unknown'
            for key in vm_config:
                if key.startswith(('virtio', 'scsi', 'ide', 'sata')) and key[-1].isdigit():
                    disk_type = key.rstrip('0123456789')
                    break
            
            # Get tags (comma-separated in Proxmox)
            tags = resource.get('tags', '')
            
            # Build target entry in Prometheus HTTP SD format
            target = {
                'targets': [f'{vm_ip}:{WINDOWS_EXPORTER_PORT}'],
                'labels': {
                    '__meta_vm_id': str(vmid),
                    '__meta_vm_name': name,
                    '__meta_node': node,
                    '__meta_vcpus': str(vcpus),
                    '__meta_memory_gb': str(memory_gb),
                    '__meta_disk_type': disk_type,
                    '__meta_tags': tags,
                }
            }
            targets.append(target)
            
        logger.info(f"Discovered {len(targets)} Windows VMs")
        
    except Exception as e:
        logger.error(f"Failed to discover VMs: {e}")
        _metrics['errors_total'] += 1
        raise
    
    finally:
        _metrics['last_discovery_duration_seconds'] = time.time() - start_time
    
    return targets


def get_cached_targets() -> list[dict]:
    """Return cached targets, refreshing if TTL has expired."""
    current_time = time.time()
    _metrics['requests_total'] += 1
    
    if current_time - _cache['last_updated'] < CACHE_TTL_SECONDS:
        _metrics['cache_hits'] += 1
        if _cache['error']:
            raise HTTPException(status_code=503, detail=str(_cache['error']))
        return _cache['targets']
    
    _metrics['cache_misses'] += 1
    
    try:
        targets = fetch_vm_targets()
        _cache['targets'] = targets
        _cache['last_updated'] = current_time
        _cache['error'] = None
        return targets
    except Exception as e:
        _cache['error'] = e
        _cache['last_updated'] = current_time
        # Return stale data if available
        if _cache['targets']:
            logger.warning(f"Returning stale cache due to error: {e}")
            return _cache['targets']
        raise HTTPException(status_code=503, detail=str(e))


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize cache on startup."""
    logger.info(f"Starting discovery service for Proxmox host: {PROXMOX_HOST}")
    logger.info(f"Cache TTL: {CACHE_TTL_SECONDS}s, Windows exporter port: {WINDOWS_EXPORTER_PORT}")
    
    # Pre-warm cache
    try:
        fetch_vm_targets()
        _cache['targets'] = fetch_vm_targets()
        _cache['last_updated'] = time.time()
        logger.info("Cache pre-warmed successfully")
    except Exception as e:
        logger.warning(f"Failed to pre-warm cache: {e}")
    
    yield
    
    logger.info("Shutting down discovery service")


app = FastAPI(
    title="Proxmox VM Discovery Service",
    description="HTTP Service Discovery endpoint for Prometheus",
    version="1.0.0",
    lifespan=lifespan
)


@app.get("/targets")
async def get_targets():
    """
    Return VM targets in Prometheus HTTP Service Discovery format.
    
    This endpoint is called by Prometheus to discover Windows VM targets.
    Results are cached to reduce load on the Proxmox API.
    """
    targets = get_cached_targets()
    return JSONResponse(content=targets)


@app.get("/health")
async def health_check():
    """Health check endpoint for Docker/Kubernetes probes."""
    return {
        "status": "healthy",
        "proxmox_host": PROXMOX_HOST,
        "cache_age_seconds": int(time.time() - _cache['last_updated']) if _cache['last_updated'] else None,
        "cached_targets": len(_cache['targets']),
    }


@app.get("/metrics")
async def metrics():
    """Prometheus metrics endpoint for self-monitoring."""
    lines = [
        "# HELP discovery_requests_total Total number of target requests",
        "# TYPE discovery_requests_total counter",
        f"discovery_requests_total {_metrics['requests_total']}",
        "",
        "# HELP discovery_cache_hits_total Number of cache hits",
        "# TYPE discovery_cache_hits_total counter", 
        f"discovery_cache_hits_total {_metrics['cache_hits']}",
        "",
        "# HELP discovery_cache_misses_total Number of cache misses",
        "# TYPE discovery_cache_misses_total counter",
        f"discovery_cache_misses_total {_metrics['cache_misses']}",
        "",
        "# HELP discovery_errors_total Number of discovery errors",
        "# TYPE discovery_errors_total counter",
        f"discovery_errors_total {_metrics['errors_total']}",
        "",
        "# HELP discovery_targets_count Current number of discovered targets",
        "# TYPE discovery_targets_count gauge",
        f"discovery_targets_count {len(_cache['targets'])}",
        "",
        "# HELP discovery_cache_age_seconds Age of the cache in seconds",
        "# TYPE discovery_cache_age_seconds gauge",
        f"discovery_cache_age_seconds {int(time.time() - _cache['last_updated']) if _cache['last_updated'] else 0}",
        "",
        "# HELP discovery_last_duration_seconds Duration of last discovery run",
        "# TYPE discovery_last_duration_seconds gauge",
        f"discovery_last_duration_seconds {_metrics['last_discovery_duration_seconds']:.3f}",
    ]
    return "\n".join(lines) + "\n"


@app.get("/")
async def root():
    """Root endpoint with service information."""
    return {
        "service": "Proxmox VM Discovery Service",
        "version": "1.0.0",
        "endpoints": {
            "/targets": "Prometheus HTTP SD targets",
            "/health": "Health check",
            "/metrics": "Prometheus metrics",
        }
    }


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        log_level="info",
        access_log=True
    )
