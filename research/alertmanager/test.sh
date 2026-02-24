#!/bin/bash
# E2E test: Prometheus → Alertmanager → aqsh webhook → task execution
#
# Validates the full alerting pipeline with multi-alert routing:
#   1. Prometheus scrapes aqsh and evaluates alert rules
#   2. Alerts fire and are sent to Alertmanager
#   3. Alertmanager sends webhooks to aqsh (one per alert group)
#   4. aqsh routes each alert to the correct task script
#
# Alert routing under test:
#   HighMemory  (aqsh_task=alert-handler)   → alert-handler.sh
#   HighLatency (aqsh_task=latency-handler)  → latency-handler.sh
#
# Usage: ./research/alertmanager/test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yaml"
TIMEOUT=90  # max seconds to wait for entire flow

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
PASS=0
FAIL=0

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    echo "  Expected: $2"
    echo "  Got: $3"
    FAIL=$((FAIL + 1))
}

info() {
    echo -e "${YELLOW}→${NC} $1"
}

step() {
    echo -e "\n${CYAN}[$1]${NC} $2"
}

# Cleanup on exit
cleanup() {
    step "CLEANUP" "Stopping stack..."
    $COMPOSE down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# Poll a URL until jq filter matches, with timeout
# Usage: wait_for <description> <url> <jq_filter> <timeout_seconds>
wait_for() {
    local desc="$1" url="$2" filter="$3" timeout="$4"
    local elapsed=0

    info "Waiting for $desc (timeout: ${timeout}s)..."
    while [ $elapsed -lt "$timeout" ]; do
        RESP=$(curl -sf "$url" 2>/dev/null || echo "")
        if [ -n "$RESP" ]; then
            MATCH=$(echo "$RESP" | jq -r "$filter" 2>/dev/null || echo "")
            if [ "$MATCH" = "true" ]; then
                return 0
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "."
    done
    echo ""
    return 1
}

# Poll aqsh container logs for a task enqueue log line, extract task ID
# Usage: wait_for_enqueue <task_name> <timeout_seconds>
# Sets: ENQUEUE_TASK_ID on success
wait_for_enqueue() {
    local task_name="$1" timeout="$2"
    local elapsed=0
    ENQUEUE_TASK_ID=""

    info "Waiting for $task_name to be enqueued (timeout: ${timeout}s)..."
    while [ $elapsed -lt "$timeout" ]; do
        LOGS=$($COMPOSE logs aqsh 2>&1)
        MATCH=$(echo "$LOGS" | grep "enqueued task \"$task_name\"" || true)
        if [ -n "$MATCH" ]; then
            ENQUEUE_TASK_ID=$(echo "$MATCH" | head -1 | sed 's/.*id=\([^)]*\).*/\1/')
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "."
    done
    echo ""
    return 1
}

# Wait for a task to reach a terminal status (completed/failed)
# Usage: wait_for_task_done <task_id> <timeout_seconds>
# Sets: TASK_STATUS on success
wait_for_task_done() {
    local task_id="$1" timeout="$2"
    local elapsed=0
    TASK_STATUS=""

    info "Waiting for task $task_id to complete (timeout: ${timeout}s)..."
    while [ $elapsed -lt "$timeout" ]; do
        TASK_STATUS=$(curl -sf "http://localhost:8080/tasks/$task_id" 2>/dev/null | jq -r '.status' 2>/dev/null || echo "")
        if [ "$TASK_STATUS" = "completed" ] || [ "$TASK_STATUS" = "failed" ]; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "."
    done
    echo ""
    return 1
}

# Verify a task's log output contains expected strings
# Usage: verify_task_logs <task_id> <task_label> <expected_line> ...
verify_task_logs() {
    local task_id="$1" label="$2"
    shift 2

    local logs
    logs=$(curl -sf "http://localhost:8080/tasks/$task_id/logs?follow=false" 2>/dev/null || echo "")

    info "GET /tasks/$task_id/logs ($label):"
    echo "$logs" | grep '^data: ' | sed 's/^data: //' || true
    echo "---"

    for expected in "$@"; do
        if echo "$logs" | grep -q "$expected"; then
            pass "$label output: $expected"
        else
            fail "$label output" "$expected" "not found in task logs"
        fi
    done
}

# ============================================
# Start
# ============================================
echo "========================================"
echo "Alertmanager Integration E2E Test"
echo "  Routes: HighMemory→alert-handler, HighLatency→latency-handler"
echo "========================================"

# ============================================
# Step 1: Start the stack
# ============================================
step "1/6" "Starting docker compose stack..."
$COMPOSE up --build -d 2>&1 | tail -5

# ============================================
# Step 2: Wait for aqsh health
# ============================================
step "2/6" "Waiting for aqsh to be ready..."
if wait_for "aqsh health" "http://localhost:8080/health" \
    '.status == "healthy" and .redis == "connected"' 30; then
    echo ""
    pass "aqsh is healthy and redis connected"
else
    echo ""
    fail "aqsh health check" "healthy + redis connected" "timeout after 30s"
    echo "--- aqsh logs ---"
    $COMPOSE logs aqsh 2>&1 | tail -20
    exit 1
fi

# ============================================
# Step 3: Wait for both Prometheus alerts to fire
# ============================================
step "3/6" "Waiting for Prometheus alerts to fire (HighMemory + HighLatency)..."

if wait_for "Prometheus HighMemory alert" "http://localhost:9090/api/v1/alerts" \
    '[.data.alerts[] | select(.labels.alertname == "HighMemory" and .state == "firing")] | length > 0' 45; then
    echo ""
    pass "Prometheus alert HighMemory is firing"
else
    echo ""
    fail "Prometheus alert firing" "HighMemory firing" "timeout after 45s"
    echo "--- Prometheus alerts ---"
    curl -sf "http://localhost:9090/api/v1/alerts" 2>/dev/null | jq . || echo "(no response)"
    exit 1
fi

if wait_for "Prometheus HighLatency alert" "http://localhost:9090/api/v1/alerts" \
    '[.data.alerts[] | select(.labels.alertname == "HighLatency" and .state == "firing")] | length > 0' 15; then
    echo ""
    pass "Prometheus alert HighLatency is firing"
else
    echo ""
    fail "Prometheus alert firing" "HighLatency firing" "timeout after 15s"
    echo "--- Prometheus alerts ---"
    curl -sf "http://localhost:9090/api/v1/alerts" 2>/dev/null | jq . || echo "(no response)"
    exit 1
fi

# ============================================
# Step 4: Wait for Alertmanager to receive both alerts
# ============================================
step "4/6" "Waiting for Alertmanager to receive both alerts..."

if wait_for "Alertmanager HighMemory" "http://localhost:9093/api/v2/alerts" \
    '[.[] | select(.labels.alertname == "HighMemory")] | length > 0' 30; then
    echo ""
    pass "Alertmanager received HighMemory alert"
else
    echo ""
    fail "Alertmanager alert" "HighMemory in alerts" "timeout after 30s"
    echo "--- Alertmanager alerts ---"
    curl -sf "http://localhost:9093/api/v2/alerts" 2>/dev/null | jq . || echo "(no response)"
    exit 1
fi

if wait_for "Alertmanager HighLatency" "http://localhost:9093/api/v2/alerts" \
    '[.[] | select(.labels.alertname == "HighLatency")] | length > 0' 15; then
    echo ""
    pass "Alertmanager received HighLatency alert"
else
    echo ""
    fail "Alertmanager alert" "HighLatency in alerts" "timeout after 15s"
    echo "--- Alertmanager alerts ---"
    curl -sf "http://localhost:9093/api/v2/alerts" 2>/dev/null | jq . || echo "(no response)"
    exit 1
fi

# ============================================
# Step 5: Wait for both tasks to be enqueued and completed
# ============================================
step "5/6" "Waiting for webhook tasks to be enqueued (group_wait=10s + processing)..."
info "Current aqsh logs:"
$COMPOSE logs aqsh 2>&1 | tail -20

# Wait for alert-handler task
if wait_for_enqueue "alert-handler" 45; then
    echo ""
    ALERT_TASK_ID="$ENQUEUE_TASK_ID"
    pass "alert-handler task enqueued (id=$ALERT_TASK_ID)"
else
    fail "alert-handler enqueue" "enqueued task log line" "not found after 45s"
    echo "--- aqsh logs ---"
    $COMPOSE logs aqsh 2>&1 | tail -30
    exit 1
fi

# Wait for latency-handler task
if wait_for_enqueue "latency-handler" 30; then
    echo ""
    LATENCY_TASK_ID="$ENQUEUE_TASK_ID"
    pass "latency-handler task enqueued (id=$LATENCY_TASK_ID)"
else
    fail "latency-handler enqueue" "enqueued task log line" "not found after 30s"
    echo "--- aqsh logs ---"
    $COMPOSE logs aqsh 2>&1 | tail -30
    exit 1
fi

# Wait for both tasks to complete
if wait_for_task_done "$ALERT_TASK_ID" 30; then
    echo ""
    pass "alert-handler task $ALERT_TASK_ID finished with status: $TASK_STATUS"
else
    fail "alert-handler completion" "completed or failed" "status=$TASK_STATUS after 30s"
fi

if wait_for_task_done "$LATENCY_TASK_ID" 30; then
    echo ""
    pass "latency-handler task $LATENCY_TASK_ID finished with status: $TASK_STATUS"
else
    fail "latency-handler completion" "completed or failed" "status=$TASK_STATUS after 30s"
fi

# ============================================
# Step 6: Verify task outputs via log stream API
# ============================================
step "6/6" "Verifying task outputs via API..."

verify_task_logs "$ALERT_TASK_ID" "alert-handler" \
    "Alert: HighMemory (firing)" \
    "Severity: critical" \
    "Remediation complete"

verify_task_logs "$LATENCY_TASK_ID" "latency-handler" \
    "Latency Alert: HighLatency (firing)" \
    "Severity: warning" \
    "Latency remediation complete"

# ============================================
# Results
# ============================================
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [ $FAIL -gt 0 ]; then
    echo ""
    echo "--- Full aqsh logs ---"
    $COMPOSE logs aqsh 2>&1 | tail -40
    exit 1
fi
