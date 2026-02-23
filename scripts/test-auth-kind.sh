#!/bin/bash
# Run authorization tests in a Kind cluster
#
# Usage: ./scripts/test-auth-kind.sh
#
# Creates a Kind cluster, deploys aqsh with kube-auth-proxy sidecar,
# creates test ServiceAccounts in separate namespaces, and runs auth tests.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="aqsh-auth-test"
NAMESPACE="aqsh"
PROXY_IMAGE="ghcr.io/rophy/kube-auth-proxy:latest"
PF_PID=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${YELLOW}==>${NC} $1"; }
success() { echo -e "${GREEN}==>${NC} $1"; }
error() { echo -e "${RED}==>${NC} $1"; }

cleanup() {
    info "Cleaning up..."
    if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
        kill "$PF_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_CLUSTER:-}" != "true" ]; then
        kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    else
        info "Keeping cluster $CLUSTER_NAME (KEEP_CLUSTER=true)"
    fi
}
trap cleanup EXIT

cd "$PROJECT_DIR"

# Step 1: Create Kind cluster
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    info "Reusing existing Kind cluster: $CLUSTER_NAME"
else
    info "Creating Kind cluster: $CLUSTER_NAME"
    kind create cluster --name "$CLUSTER_NAME" --wait 60s
fi

# Step 2: Build aqsh image and load into Kind
info "Building aqsh image..."
docker build -t aqsh:latest -f Dockerfile .

info "Loading aqsh image into Kind..."
kind load docker-image aqsh:latest --name "$CLUSTER_NAME"

# Step 3: Pull and load kube-auth-proxy image
info "Pulling kube-auth-proxy image..."
docker pull "$PROXY_IMAGE" || true

info "Loading kube-auth-proxy image into Kind..."
kind load docker-image "$PROXY_IMAGE" --name "$CLUSTER_NAME"

# Step 4: Deploy aqsh
info "Deploying aqsh..."
kubectl --context "kind-${CLUSTER_NAME}" apply -f k8s/namespace.yaml
kubectl --context "kind-${CLUSTER_NAME}" apply -f k8s/auth.yaml
kubectl --context "kind-${CLUSTER_NAME}" apply -f k8s/redis.yaml
kubectl --context "kind-${CLUSTER_NAME}" apply -f k8s/aqsh.yaml

info "Waiting for deployment..."
kubectl --context "kind-${CLUSTER_NAME}" wait \
    --for=condition=available deployment/aqsh \
    -n "$NAMESPACE" --timeout=120s

# Step 5: Create test namespaces and ServiceAccounts
info "Creating test namespaces and ServiceAccounts..."

for ns in deploy ops viewer; do
    kubectl --context "kind-${CLUSTER_NAME}" create namespace "$ns" 2>/dev/null || true
    kubectl --context "kind-${CLUSTER_NAME}" create serviceaccount "test-sa" -n "$ns" 2>/dev/null || true
done

# Step 6: Generate tokens
info "Generating ServiceAccount tokens..."
TOKEN_AQSH=$(kubectl --context "kind-${CLUSTER_NAME}" create token default -n "$NAMESPACE")
TOKEN_DEPLOY=$(kubectl --context "kind-${CLUSTER_NAME}" create token test-sa -n deploy)
TOKEN_OPS=$(kubectl --context "kind-${CLUSTER_NAME}" create token test-sa -n ops)

# Step 7: Port-forward
info "Setting up port-forward..."
kubectl --context "kind-${CLUSTER_NAME}" port-forward -n "$NAMESPACE" svc/aqsh 18080:8080 &
PF_PID=$!
sleep 3

# Step 8: Run auth tests
info "Running authorization tests..."
TEST_EXIT=0
AQSH_URL="http://localhost:18080" \
    TOKEN_AQSH="$TOKEN_AQSH" \
    TOKEN_DEPLOY="$TOKEN_DEPLOY" \
    TOKEN_OPS="$TOKEN_OPS" \
    bash "$PROJECT_DIR/test/auth_test.sh" || TEST_EXIT=$?

# Report
echo ""
if [ $TEST_EXIT -eq 0 ]; then
    success "All authorization tests passed!"
else
    error "Authorization tests failed (exit code: $TEST_EXIT)"
fi

exit $TEST_EXIT
