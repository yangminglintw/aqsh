#!/bin/bash
# Authorization integration tests for aqsh with kube-auth-proxy
#
# Usage: ./test/auth_test.sh
#
# Environment variables:
#   AQSH_URL        - Base URL of aqsh service (default: http://localhost:8080)
#   TOKEN_AQSH      - Token from aqsh namespace SA (open tasks only)
#   TOKEN_DEPLOY    - Token from deploy namespace SA (deploy task access)
#   TOKEN_OPS       - Token from ops namespace SA (cleanup task access)

set -e

BASE_URL="${AQSH_URL:-http://localhost:8080}"
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1" >&2
    PASS=$((PASS + 1))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1" >&2
    echo "  Expected: $2" >&2
    echo "  Got: $3" >&2
    FAIL=$((FAIL + 1))
}

info() {
    echo -e "${YELLOW}→${NC} $1" >&2
}

wait_for_server() {
    info "Waiting for server at $BASE_URL (with auth)..."
    if [ -z "$TOKEN_AQSH" ]; then
        echo "ERROR: TOKEN_AQSH not set" >&2
        exit 1
    fi
    for i in {1..30}; do
        if curl -s -H "Authorization: Bearer $TOKEN_AQSH" "$BASE_URL/health" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "Server not ready after 30 seconds" >&2
    exit 1
}

# Test: Unauthenticated request should be rejected
test_unauthenticated_rejected() {
    info "Testing unauthenticated request → rejected"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health")

    if [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
        pass "Unauthenticated request rejected (HTTP $HTTP_CODE)"
    else
        fail "Unauthenticated request rejected" "401 or 403" "$HTTP_CODE"
    fi
}

# Test: Authenticated request to open task (hello) should succeed
test_open_task_accessible() {
    info "Testing authenticated request to open task (hello)"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $TOKEN_AQSH" \
        "$BASE_URL/tasks")

    if [ "$HTTP_CODE" = "200" ]; then
        pass "Authenticated request to /tasks returns 200"
    else
        fail "Authenticated request to /tasks returns 200" "200" "$HTTP_CODE"
    fi

    # Submit hello task (open to all authenticated users)
    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $TOKEN_AQSH" \
        -H "Content-Type: application/json" \
        -d '{"name":"AuthTest"}' \
        "$BASE_URL/tasks/hello")
    HTTP_CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')

    if [ "$HTTP_CODE" = "200" ]; then
        pass "SA from aqsh namespace can submit hello task"
    else
        fail "SA from aqsh namespace can submit hello task" "200" "$HTTP_CODE (body: $BODY)"
    fi
}

# Test: Authorized group can access restricted task (deploy)
test_authorized_deploy() {
    info "Testing deploy SA can access deploy task"
    if [ -z "$TOKEN_DEPLOY" ]; then
        fail "Deploy token available" "TOKEN_DEPLOY set" "not set"
        return
    fi

    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $TOKEN_DEPLOY" \
        -H "Content-Type: application/json" \
        -d '{"version":"1.0.0","environment":"dev"}' \
        "$BASE_URL/tasks/deploy")
    HTTP_CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')

    if [ "$HTTP_CODE" = "200" ]; then
        pass "SA from deploy namespace can submit deploy task"
    else
        fail "SA from deploy namespace can submit deploy task" "200" "$HTTP_CODE (body: $BODY)"
    fi
}

# Test: Unauthorized group cannot access restricted task (deploy)
test_unauthorized_deploy() {
    info "Testing aqsh SA cannot access deploy task (wrong group)"
    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $TOKEN_AQSH" \
        -H "Content-Type: application/json" \
        -d '{"version":"1.0.0","environment":"dev"}' \
        "$BASE_URL/tasks/deploy")
    HTTP_CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')

    if [ "$HTTP_CODE" = "403" ]; then
        pass "SA from aqsh namespace gets 403 for deploy task"
    else
        fail "SA from aqsh namespace gets 403 for deploy task" "403" "$HTTP_CODE (body: $BODY)"
    fi
}

# Test: Authorized group can access cleanup task
test_authorized_cleanup() {
    info "Testing ops SA can access cleanup task"
    if [ -z "$TOKEN_OPS" ]; then
        fail "Ops token available" "TOKEN_OPS set" "not set"
        return
    fi

    RESP=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $TOKEN_OPS" \
        -H "Content-Type: application/json" \
        -d '{"older_than_days":30}' \
        "$BASE_URL/tasks/cleanup")
    HTTP_CODE=$(echo "$RESP" | tail -1)
    BODY=$(echo "$RESP" | sed '$d')

    if [ "$HTTP_CODE" = "200" ]; then
        pass "SA from ops namespace can submit cleanup task"
    else
        fail "SA from ops namespace can submit cleanup task" "200" "$HTTP_CODE (body: $BODY)"
    fi
}

# Test: Identity recorded in task response
test_identity_recorded() {
    info "Testing identity is recorded in task response"
    RESP=$(curl -s -X POST \
        -H "Authorization: Bearer $TOKEN_AQSH" \
        -H "Content-Type: application/json" \
        -d '{"name":"IdentityTest"}' \
        "$BASE_URL/tasks/hello")

    TASK_ID=$(echo "$RESP" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    if [ -z "$TASK_ID" ]; then
        fail "Submit task for identity check" "task ID" "$RESP"
        return
    fi

    # Wait for task to complete
    sleep 3

    TASK_RESP=$(curl -s \
        -H "Authorization: Bearer $TOKEN_AQSH" \
        "$BASE_URL/tasks/$TASK_ID")

    if echo "$TASK_RESP" | grep -q '"submitted_by"'; then
        pass "Task response contains submitted_by field"
    else
        fail "Task response contains submitted_by field" '"submitted_by":"..."' "$TASK_RESP"
    fi
}

# Main
echo "========================================" >&2
echo "aqsh Authorization Tests" >&2
echo "========================================" >&2
echo "" >&2

wait_for_server

echo "" >&2
echo "--- Authentication Tests ---" >&2
test_unauthenticated_rejected
test_open_task_accessible

echo "" >&2
echo "--- Authorization Tests ---" >&2
test_authorized_deploy
test_unauthorized_deploy
test_authorized_cleanup

echo "" >&2
echo "--- Identity Tests ---" >&2
test_identity_recorded

echo "" >&2
echo "========================================" >&2
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}" >&2
echo "========================================" >&2

if [ $FAIL -gt 0 ]; then
    exit 1
fi
