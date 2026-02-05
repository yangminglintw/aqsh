#!/bin/bash
# Setup default-dex kubectl context from in-cluster service account token
# Usage: source /path/to/setup-default-dex.sh
# Idempotent - safe to source multiple times

SA_TOKEN_PATH="/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA_PATH="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
SA_NAMESPACE_PATH="/var/run/secrets/kubernetes.io/serviceaccount/namespace"
K8S_HOST="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
CONTEXT_NAME="default-dex"

if ! kubectl config get-contexts "$CONTEXT_NAME" &>/dev/null; then
    echo "[setup] Creating kubectl context: $CONTEXT_NAME"

    SA_TOKEN=$(cat "$SA_TOKEN_PATH")

    kubectl config set-cluster "${CONTEXT_NAME}-cluster" \
        --server="$K8S_HOST" \
        --certificate-authority="$SA_CA_PATH"

    kubectl config set-credentials "${CONTEXT_NAME}-user" \
        --token="$SA_TOKEN"

    kubectl config set-context "$CONTEXT_NAME" \
        --cluster="${CONTEXT_NAME}-cluster" \
        --user="${CONTEXT_NAME}-user" \
        --namespace="$(cat "$SA_NAMESPACE_PATH")"

    kubectl config use-context "$CONTEXT_NAME"
    echo "[setup] Context '$CONTEXT_NAME' created and set as current"
else
    echo "[setup] Context '$CONTEXT_NAME' already exists, skipping"
fi
