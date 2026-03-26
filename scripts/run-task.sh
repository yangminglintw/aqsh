#!/bin/bash
# Usage:
#   In K8s pod (auto-reads /var/run/secrets/kubernetes.io/serviceaccount/token):
#     NAMESPACE=my-ns TASK_NAME=check-ns ./scripts/run-task.sh
#
#   Local dev (no token file, skip auth):
#     NAMESPACE=my-ns TASK_NAME=check-ns ./scripts/run-task.sh
#
#   Explicit token:
#     TOKEN=my-token NAMESPACE=my-ns TASK_NAME=check-ns ./scripts/run-task.sh
#
#   Custom server:
#     NAMESPACE=prod-ns TASK_NAME=my-task BASE_URL=http://my-server:8080 ./scripts/run-task.sh
#
# See: https://github.com/rophy/aqsh
set -euo pipefail

# =============================================================================
# Configurable variables (override via environment)
# =============================================================================
BASE_URL="${BASE_URL:-http://localhost:8080}"
TASK_NAME="${TASK_NAME:-my-task}"
NAMESPACE="${NAMESPACE:-}"
TOKEN_PATH="${TOKEN_PATH:-/var/run/secrets/kubernetes.io/serviceaccount/token}"
TOKEN="${TOKEN:-}"
AUTH_USER="${AUTH_USER:-}"
AUTH_GROUPS="${AUTH_GROUPS:-}"

# =============================================================================
# Preflight checks
# =============================================================================
for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed." >&2
    exit 1
  fi
done

if [[ -z "$NAMESPACE" ]]; then
  echo "ERROR: NAMESPACE is required." >&2
  echo "Usage: NAMESPACE=<ns> TASK_NAME=<task> BASE_URL=<url> $0" >&2
  exit 1
fi

AUTH_HEADERS=()
if [[ -z "$TOKEN" && -f "$TOKEN_PATH" ]]; then
  TOKEN=$(cat "$TOKEN_PATH")
fi
if [[ -n "$TOKEN" ]]; then
  AUTH_HEADERS+=(-H "Authorization: Bearer ${TOKEN}")
fi
if [[ -n "$AUTH_USER" ]]; then
  AUTH_HEADERS+=(-H "X-Forwarded-User: ${AUTH_USER}")
fi
if [[ -n "$AUTH_GROUPS" ]]; then
  AUTH_HEADERS+=(-H "X-Forwarded-Groups: ${AUTH_GROUPS}")
fi

echo "==> Submitting task '${TASK_NAME}' with namespace '${NAMESPACE}'"
echo "    Server: ${BASE_URL}"
[[ -n "$AUTH_USER" ]] && echo "    User: ${AUTH_USER}"
[[ -n "$AUTH_GROUPS" ]] && echo "    Groups: ${AUTH_GROUPS}"
echo

# =============================================================================
# 1. Submit task
# =============================================================================
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" \
  -d "{\"namespace\": \"${NAMESPACE}\"}" \
  "${BASE_URL}/tasks/${TASK_NAME}")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "202" ]]; then
  echo "ERROR: Failed to submit task (HTTP ${HTTP_CODE})" >&2
  echo "$BODY" | jq . 2>/dev/null || echo "$BODY" >&2
  exit 1
fi

TASK_ID=$(echo "$BODY" | jq -r '.id')
echo "==> Task submitted: ${TASK_ID}"
echo

# =============================================================================
# 2. Stream logs
# =============================================================================
echo "==> Streaming logs..."
echo "---"
curl -s -N "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" "${BASE_URL}/tasks/${TASK_ID}/logs" | while IFS= read -r line; do
  if [[ "$line" == "event: eof" ]]; then
    break
  fi
  if [[ "$line" == data:* ]]; then
    echo "${line#data: }"
  fi
done
echo "---"
echo

# =============================================================================
# 3. Get final result (retry-aware)
# =============================================================================
while true; do
  RESULT=$(curl -s "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" "${BASE_URL}/tasks/${TASK_ID}")
  STATUS=$(echo "$RESULT" | jq -r '.status')

  if [[ "$STATUS" == "retrying" ]]; then
    RETRIED=$(echo "$RESULT" | jq -r '.retried')
    echo "==> Task retrying (attempt ${RETRIED}), monitoring..."
    echo "---"
    curl -s -N "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" "${BASE_URL}/tasks/${TASK_ID}/logs" | while IFS= read -r line; do
      if [[ "$line" == "event: eof" ]]; then
        break
      fi
      if [[ "$line" == data:* ]]; then
        echo "${line#data: }"
      fi
    done
    echo "---"
    echo
    continue
  fi

  echo "==> Task result (${STATUS}):"
  echo "$RESULT" | jq .
  break
done
