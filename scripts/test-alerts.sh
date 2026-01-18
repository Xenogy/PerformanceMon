#!/bin/bash
#
# test-alerts.sh - Test alerting pipeline by inducing load conditions
#
# This script generates synthetic load to trigger alerts and verify
# that the entire alerting pipeline works correctly.
#
# Usage:
#   ./test-alerts.sh [cpu|memory|disk|all]
#
# Requirements:
#   - stress-ng (apt install stress-ng)
#   - fio (apt install fio)
#   - curl
#   - jq
#
# Run on the monitoring server or a test VM.

set -euo pipefail

# Configuration
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://localhost:9093}"
TEST_DURATION="${TEST_DURATION:-120}"  # seconds
WEBHOOK_TEST_URL="${WEBHOOK_TEST_URL:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_dependencies() {
    local missing=()
    
    for cmd in stress-ng fio curl jq; do
        if ! command -v $cmd &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        log_info "Install with: apt install stress-ng fio curl jq"
        exit 1
    fi
}

check_prometheus() {
    log_info "Checking Prometheus connectivity..."
    if ! curl -sf "${PROMETHEUS_URL}/api/v1/status/config" > /dev/null; then
        log_error "Cannot connect to Prometheus at ${PROMETHEUS_URL}"
        exit 1
    fi
    log_info "Prometheus is reachable"
}

check_alertmanager() {
    log_info "Checking Alertmanager connectivity..."
    if ! curl -sf "${ALERTMANAGER_URL}/api/v2/status" > /dev/null; then
        log_error "Cannot connect to Alertmanager at ${ALERTMANAGER_URL}"
        exit 1
    fi
    log_info "Alertmanager is reachable"
}

get_firing_alerts() {
    curl -sf "${PROMETHEUS_URL}/api/v1/alerts" | jq -r '.data.alerts[] | select(.state == "firing") | .labels.alertname' 2>/dev/null || echo ""
}

get_alertmanager_alerts() {
    curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" | jq -r '.[].labels.alertname' 2>/dev/null || echo ""
}

wait_for_alert() {
    local alert_name=$1
    local timeout=${2:-180}
    local start_time=$(date +%s)
    
    log_info "Waiting for alert '${alert_name}' to fire (timeout: ${timeout}s)..."
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $timeout ]; then
            log_error "Timeout waiting for alert '${alert_name}'"
            return 1
        fi
        
        local firing=$(get_firing_alerts)
        if echo "$firing" | grep -q "$alert_name"; then
            log_info "Alert '${alert_name}' is now firing!"
            return 0
        fi
        
        echo -n "."
        sleep 5
    done
}

verify_alertmanager_received() {
    local alert_name=$1
    
    log_info "Verifying Alertmanager received '${alert_name}'..."
    
    local am_alerts=$(get_alertmanager_alerts)
    if echo "$am_alerts" | grep -q "$alert_name"; then
        log_info "Alertmanager received '${alert_name}' successfully"
        return 0
    else
        log_error "Alertmanager did not receive '${alert_name}'"
        return 1
    fi
}

test_cpu_alert() {
    log_info "=========================================="
    log_info "Testing CPU Saturation Alert"
    log_info "=========================================="
    
    local cores=$(nproc)
    log_info "System has ${cores} CPU cores"
    log_info "Inducing 95% CPU load for ${TEST_DURATION} seconds..."
    
    # Start stress in background
    stress-ng --cpu $cores --cpu-load 95 --timeout ${TEST_DURATION}s &
    local stress_pid=$!
    
    # Wait for alert
    if wait_for_alert "HostCpuHigh" 180; then
        verify_alertmanager_received "HostCpuHigh"
    fi
    
    # Cleanup
    kill $stress_pid 2>/dev/null || true
    wait $stress_pid 2>/dev/null || true
    
    log_info "CPU test complete"
}

test_memory_alert() {
    log_info "=========================================="
    log_info "Testing Memory Pressure Alert"
    log_info "=========================================="
    
    # Get available memory in MB
    local avail_mb=$(free -m | awk '/^Mem:/ {print $7}')
    local target_mb=$((avail_mb * 90 / 100))  # Use 90% of available
    
    log_info "Available memory: ${avail_mb}MB"
    log_info "Allocating ${target_mb}MB for ${TEST_DURATION} seconds..."
    
    # Start memory stress in background
    stress-ng --vm 1 --vm-bytes ${target_mb}M --vm-keep --timeout ${TEST_DURATION}s &
    local stress_pid=$!
    
    # Wait for alert
    if wait_for_alert "HostMemoryLow" 180; then
        verify_alertmanager_received "HostMemoryLow"
    fi
    
    # Cleanup
    kill $stress_pid 2>/dev/null || true
    wait $stress_pid 2>/dev/null || true
    
    log_info "Memory test complete"
}

test_disk_alert() {
    log_info "=========================================="
    log_info "Testing Disk Latency Alert"  
    log_info "=========================================="
    
    local test_dir="${TEST_DIR:-/tmp/fio-test}"
    mkdir -p "$test_dir"
    
    log_info "Running disk stress test in ${test_dir}..."
    
    # Create fio job that induces high latency through sync writes
    cat > "${test_dir}/latency.fio" << EOF
[global]
directory=${test_dir}
ioengine=sync
direct=1
size=1G
runtime=${TEST_DURATION}
time_based

[random-write-sync]
rw=randwrite
bs=4k
numjobs=4
fsync=1
fdatasync=1
EOF
    
    # Run fio in background
    fio "${test_dir}/latency.fio" &
    local fio_pid=$!
    
    # Wait for alert (disk alerts have longer thresholds)
    if wait_for_alert "GuestDiskLatencyHigh" 300; then
        verify_alertmanager_received "GuestDiskLatencyHigh"
    else
        log_warn "Disk latency alert may not fire if storage is fast enough"
    fi
    
    # Cleanup
    kill $fio_pid 2>/dev/null || true
    wait $fio_pid 2>/dev/null || true
    rm -rf "$test_dir"
    
    log_info "Disk test complete"
}

test_webhook() {
    log_info "=========================================="
    log_info "Testing Webhook Delivery"
    log_info "=========================================="
    
    if [ -z "$WEBHOOK_TEST_URL" ]; then
        log_warn "WEBHOOK_TEST_URL not set, skipping webhook test"
        log_info "Set WEBHOOK_TEST_URL to a RequestBin or similar endpoint to test"
        return 0
    fi
    
    log_info "Sending test alert to Alertmanager..."
    
    # Send a test alert directly to Alertmanager
    curl -sf -X POST "${ALERTMANAGER_URL}/api/v2/alerts" \
        -H "Content-Type: application/json" \
        -d '[{
            "labels": {
                "alertname": "TestAlert",
                "severity": "warning",
                "instance": "test-instance",
                "job": "test-job"
            },
            "annotations": {
                "summary": "This is a test alert",
                "description": "Testing the alerting pipeline"
            },
            "generatorURL": "http://localhost:9090/graph"
        }]'
    
    log_info "Test alert sent. Check your webhook endpoint at: ${WEBHOOK_TEST_URL}"
    log_info "Alert will auto-resolve in 5 minutes if not manually resolved"
}

print_current_alerts() {
    log_info "=========================================="
    log_info "Current Alert Status"
    log_info "=========================================="
    
    echo ""
    echo "Prometheus Firing Alerts:"
    echo "-------------------------"
    curl -sf "${PROMETHEUS_URL}/api/v1/alerts" | jq -r '
        .data.alerts[] | 
        select(.state == "firing") | 
        "  - \(.labels.alertname) [\(.labels.severity // "unknown")] on \(.labels.instance // "unknown")"
    ' 2>/dev/null || echo "  (none or error fetching)"
    
    echo ""
    echo "Alertmanager Active Alerts:"
    echo "---------------------------"
    curl -sf "${ALERTMANAGER_URL}/api/v2/alerts" | jq -r '
        .[] | 
        "  - \(.labels.alertname) [\(.labels.severity // "unknown")] on \(.labels.instance // "unknown")"
    ' 2>/dev/null || echo "  (none or error fetching)"
    
    echo ""
}

show_usage() {
    cat << EOF
Usage: $0 [command]

Commands:
    cpu       Test CPU saturation alert
    memory    Test memory pressure alert
    disk      Test disk latency alert
    webhook   Test webhook delivery (requires WEBHOOK_TEST_URL)
    status    Show current alert status
    all       Run all tests

Environment Variables:
    PROMETHEUS_URL    Prometheus URL (default: http://localhost:9090)
    ALERTMANAGER_URL  Alertmanager URL (default: http://localhost:9093)
    TEST_DURATION     Duration of stress tests in seconds (default: 120)
    WEBHOOK_TEST_URL  URL for webhook testing (e.g., RequestBin)
    TEST_DIR          Directory for disk tests (default: /tmp/fio-test)

Examples:
    $0 cpu
    $0 all
    TEST_DURATION=60 $0 memory
    WEBHOOK_TEST_URL=https://webhook.site/xxx $0 webhook
EOF
}

main() {
    local command="${1:-status}"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║        Alert Testing Script for Performance Monitor         ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    check_dependencies
    check_prometheus
    check_alertmanager
    
    case "$command" in
        cpu)
            test_cpu_alert
            ;;
        memory)
            test_memory_alert
            ;;
        disk)
            test_disk_alert
            ;;
        webhook)
            test_webhook
            ;;
        status)
            print_current_alerts
            ;;
        all)
            test_cpu_alert
            echo ""
            test_memory_alert
            echo ""
            test_disk_alert
            echo ""
            test_webhook
            echo ""
            print_current_alerts
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
    
    log_info "Done!"
}

main "$@"
