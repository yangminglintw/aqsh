#!/bin/bash
# E2E test: Prometheus → Alertmanager → aqsh webhook → task execution
#
# Validates the full alerting pipeline:
#   1. Prometheus scrapes aqsh and evaluates alert rules
#   2. Alert fires and is sent to Alertmanager
#   3. Alertmanager sends webhook to aqsh
#   4. aqsh creates and executes the alert-handler task
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

# ============================================
# Start
# ============================================
echo "========================================"
echo "Alertmanager Integration E2E Test"
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
# Step 3: Wait for Prometheus alert to fire
# ============================================
step "3/6" "Waiting for Prometheus alert to fire..."
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

# ============================================
# Step 4: Wait for Alertmanager to receive alert
# ============================================
step "4/6" "Waiting for Alertmanager to receive alert..."
if wait_for "Alertmanager alert" "http://localhost:9093/api/v2/alerts" \
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

# ============================================
# Step 5: Wait for aqsh to process webhook task
# ============================================
step "5/6" "Waiting for webhook task execution (group_wait=10s + processing)..."

# Check aqsh container logs for alert-handler output
# The alert-handler.sh prints "Alert: HighMemory (firing)" when executed
TASK_FOUND=false
elapsed=0
while [ $elapsed -lt 45 ]; do
    LOGS=$($COMPOSE logs aqsh 2>&1)
    if echo "$LOGS" | grep -q "Alert: HighMemory (firing)"; then
        TASK_FOUND=true
        break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    printf "."
done
echo ""

if [ "$TASK_FOUND" = true ]; then
    pass "aqsh executed alert-handler task"
else
    fail "alert-handler task execution" "Alert: HighMemory (firing) in logs" "not found after 45s"
    echo "--- aqsh logs ---"
    $COMPOSE logs aqsh 2>&1 | tail -30
fi

# ============================================
# Step 6: Verify task output details
# ============================================
step "6/6" "Verifying task output..."

LOGS=$($COMPOSE logs aqsh 2>&1)

# Check alert-handler.sh output lines
if echo "$LOGS" | grep -q "Severity: critical"; then
    pass "Task received ALERT_SEVERITY=critical"
else
    fail "ALERT_SEVERITY env var" "Severity: critical" "not found in logs"
fi

if echo "$LOGS" | grep -q "Processing remediation for HighMemory"; then
    pass "Task ran remediation logic"
else
    fail "Remediation logic" "Processing remediation for HighMemory" "not found in logs"
fi

if echo "$LOGS" | grep -q "Remediation complete"; then
    pass "Task completed remediation"
else
    fail "Remediation complete" "Remediation complete" "not found in logs"
fi

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
