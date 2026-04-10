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
trap 'echo "ERROR: Script exited unexpectedly at line $LINENO (exit code: $?)" >&2' ERR

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
MONITOR_TIMEOUT="${MONITOR_TIMEOUT:-600}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-30}"

# =============================================================================
# Preflight checks
# =============================================================================
if ! command -v curl &>/dev/null; then
  echo "ERROR: 'curl' is required but not installed." >&2
  exit 1
fi

HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
else
  echo "WARNING: 'jq' not found, JSON output will not be formatted." >&2
fi

# JSON helpers — auto fallback when jq is not available
json_field() {
  local field="$1"
  if $HAS_JQ; then
    jq -r ".$field"
  else
    grep -o "\"$field\":[[:space:]]*\"[^\"]*\"" | sed "s/\"$field\":[[:space:]]*\"//;s/\"$//" | head -1
  fi
}

json_field_num() {
  local field="$1"
  if $HAS_JQ; then
    jq -r ".$field"
  else
    grep -o "\"$field\":[[:space:]]*[0-9]*" | sed "s/\"$field\":[[:space:]]*//" | head -1
  fi
}

json_pretty() {
  if $HAS_JQ; then
    jq .
  else
    cat
  fi
}

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
RESPONSE=$(curl -s -w "\n%{http_code}" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
  -X POST \
  -H "Content-Type: application/json" \
  "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" \
  -d "{\"namespace\": \"${NAMESPACE}\"}" \
  "${BASE_URL}/tasks/${TASK_NAME}")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" != "202" ]]; then
  echo "ERROR: Failed to submit task (HTTP ${HTTP_CODE})"
  echo "$BODY" | json_pretty
  exit 1
fi

TASK_ID=$(echo "$BODY" | json_field id)
echo "==> Task submitted: ${TASK_ID}"
echo

# =============================================================================
# 2. Monitor task (pending → running → retrying → completed/failed)
# =============================================================================
LAST_EVENT_ID=""
POLL_INTERVAL=3

stream_logs() {
  local id_header=()
  if [[ -n "$LAST_EVENT_ID" ]]; then
    id_header=(-H "Last-Event-ID: ${LAST_EVENT_ID}")
  fi
  echo "---"
  local log_output
  log_output=$(curl -s -w "\n__HTTP_%{http_code}__" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    -N "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" \
    "${id_header[@]+"${id_header[@]}"}" \
    "${BASE_URL}/tasks/${TASK_ID}/logs?follow=false")
  local log_http
  log_http=$(echo "$log_output" | grep -o '__HTTP_[0-9]*__' | grep -o '[0-9]*')
  if [[ "$log_http" != "200" && -n "$log_http" ]]; then
    echo "(logs unavailable — HTTP ${log_http})"
    echo "---"
    return
  fi
  echo "$log_output" | grep -v '__HTTP_' | while IFS= read -r line; do
    if [[ "$line" == "event: eof" ]]; then
      break
    fi
    if [[ "$line" == id:* ]]; then
      # Write last event ID to temp file (subshell can't update parent var)
      echo "${line#id: }" > "/tmp/aqsh_last_id_$$"
    fi
    if [[ "$line" == data:* ]]; then
      echo "${line#data: }"
    fi
  done
  echo "---"
  # Read back last event ID from temp file
  if [[ -f "/tmp/aqsh_last_id_$$" ]]; then
    LAST_EVENT_ID=$(cat "/tmp/aqsh_last_id_$$")
    rm -f "/tmp/aqsh_last_id_$$"
  fi
}

START_TIME=$(date +%s)
STUCK_COUNT=0
MAX_STUCK_COUNT=10

while true; do
  # Check overall timeout
  ELAPSED=$(( $(date +%s) - START_TIME ))
  if [[ "$ELAPSED" -ge "$MONITOR_TIMEOUT" ]]; then
    echo "ERROR: Monitor timeout after ${MONITOR_TIMEOUT}s. Task ${TASK_ID} may still be running." >&2
    exit 1
  fi

  RESULT=$(curl -s -w "\n%{http_code}" --connect-timeout "$CURL_CONNECT_TIMEOUT" --max-time "$CURL_MAX_TIME" \
    "${AUTH_HEADERS[@]+"${AUTH_HEADERS[@]}"}" "${BASE_URL}/tasks/${TASK_ID}")
  POLL_HTTP=$(echo "$RESULT" | tail -1)
  RESULT=$(echo "$RESULT" | sed '$d')
  if [[ "$POLL_HTTP" != "200" ]]; then
    echo "ERROR: Failed to get task status (HTTP ${POLL_HTTP})"
    echo "$RESULT" | json_pretty
    exit 1
  fi
  STATUS=$(echo "$RESULT" | json_field status)

  case "$STATUS" in
    pending|scheduled)
      echo "==> Task ${STATUS}, waiting..."
      sleep "$POLL_INTERVAL"
      ;;
    running)
      STUCK_COUNT=0
      echo "==> Streaming logs..."
      stream_logs
      echo
      ;;
    retrying)
      RETRIED=$(echo "$RESULT" | json_field_num retried)
      MAX_RETRY=$(echo "$RESULT" | json_field_num max_retry)
      echo "==> Task retrying (${RETRIED}/${MAX_RETRY}), fetching logs..."
      stream_logs
      echo
      STUCK_COUNT=$((STUCK_COUNT + 1))
      if [[ "$RETRIED" -ge "$MAX_RETRY" ]]; then
        echo "WARNING: All retries exhausted, task should transition to failed soon..." >&2
      fi
      if [[ "$STUCK_COUNT" -ge "$MAX_STUCK_COUNT" ]]; then
        echo "ERROR: Task appears stuck in retrying state after ${STUCK_COUNT} polls. Giving up." >&2
        echo "$RESULT" | json_pretty
        exit 1
      fi
      echo "==> Waiting for next attempt..."
      sleep "$POLL_INTERVAL"
      ;;
    completed|failed)
      echo "==> Fetching logs..."
      stream_logs
      echo
      echo "==> Task result (${STATUS}):"
      echo "$RESULT" | json_pretty
      break
      ;;
    *)
      echo "==> Unknown status: ${STATUS}"
      echo "$RESULT" | json_pretty
      break
      ;;
  esac
done

rm -f "/tmp/aqsh_last_id_$$"
