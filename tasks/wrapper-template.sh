#!/bin/bash
# Wrapper Script Template for aqsh
# This script handles environment setup and executes another script
#
# Path resolution:
#   K8s container — auto-resolves from BASH_SOURCE (default, no config needed)
#   Local dev     — override via env vars: PROJECT_ROOT, SCRIPT_DIR, ENV_SOURCE_SCRIPT, etc.

# === Resolve project root ===
# K8s container: /app exists → use it
# Local dev: auto-resolve from script location
if [ -d "/app" ]; then
    PROJECT_ROOT="/app"
else
    WRAPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "${WRAPPER_DIR}/.." && pwd)"
fi

# === Configuration (overridable via environment) ===
ENV_SOURCE_SCRIPT="${ENV_SOURCE_SCRIPT:-${PROJECT_ROOT}/scripts/env-setup.sh}"
PRE_SCRIPT="${PRE_SCRIPT:-${PROJECT_ROOT}/scripts/pre-script.sh}"
SCRIPT_DIR="${SCRIPT_DIR:-${PROJECT_ROOT}/scripts}"
SCRIPT_NAME="${SCRIPT_NAME:-your-script.sh}"
ACL_FILE="${ACL_FILE:-${PROJECT_ROOT}/config/acl.yaml}"

# === Main Execution ===
echo "=== Wrapper Script Started ==="
echo "Task ID: $AQSH_TASK_ID"
echo "Parameters: PARAM1=$PARAM1, PARAM2=$PARAM2, PARAM3=$PARAM3"

# --- Step 1: Source Environment Script ---
if [ -n "$ENV_SOURCE_SCRIPT" ]; then
    echo "--- Environment Setup ---"
    if [ -f "$ENV_SOURCE_SCRIPT" ]; then
        echo "Sourcing: $ENV_SOURCE_SCRIPT"
        source "$ENV_SOURCE_SCRIPT"
    else
        echo "ERROR: Source script not found: $ENV_SOURCE_SCRIPT"
        exit 1
    fi
fi

# --- Step 2: Pre-execution Script (optional) ---
if [ -n "$PRE_SCRIPT" ]; then
    echo "--- Running Pre-script ---"
    if [ -f "$PRE_SCRIPT" ]; then
        echo "Executing: $PRE_SCRIPT"
        "$PRE_SCRIPT"
        PRE_EXIT=$?
        if [ $PRE_EXIT -ne 0 ]; then
            echo "ERROR: Pre-script failed with exit code: $PRE_EXIT"
            exit $PRE_EXIT
        fi
    else
        echo "ERROR: Pre-script not found: $PRE_SCRIPT"
        exit 1
    fi
fi

# --- Step 3: ACL Check ---
# AQSH_GROUPS = source app namespace (from kube-auth-proxy via X-Forwarded-Groups)
# NAMESPACE   = target DB namespace (task input parameter)
if [ -f "$ACL_FILE" ] && [ -n "$NAMESPACE" ]; then
    echo "--- ACL Check ---"
    if ! command -v yq &>/dev/null; then
        echo "ERROR: 'yq' is required for ACL check but not installed." >&2
        exit 1
    fi
    ACL_PASS=false
    IFS=',' read -ra GROUPS <<< "$AQSH_GROUPS"
    for GROUP in "${GROUPS[@]}"; do
        GROUP=$(echo "$GROUP" | xargs)
        if yq -e ".acl.\"${GROUP}\"[] | select(. == \"${NAMESPACE}\")" "$ACL_FILE" &>/dev/null; then
            echo "ACL: group '${GROUP}' is allowed to operate on namespace '${NAMESPACE}'"
            ACL_PASS=true
            break
        fi
    done
    if [ "$ACL_PASS" = false ]; then
        echo "ERROR: ACL denied — groups '${AQSH_GROUPS}' not allowed to operate on namespace '${NAMESPACE}'"
        exit 1
    fi
fi

# --- Step 4: Main Script Execution (needs cd for legacy scripts) ---
echo "--- Main Script Execution ---"
cd "$SCRIPT_DIR" || { echo "ERROR: Cannot cd to $SCRIPT_DIR"; exit 1; }
echo "Changed to script directory: $(pwd)"
echo "Executing: $SCRIPT_NAME"

set +e
./"$SCRIPT_NAME" "$PARAM1" "$PARAM2" "$PARAM3"
EXIT_CODE=$?
set -e

echo "=== Script finished with exit code: $EXIT_CODE ==="

# --- Write Result ---
if [ $EXIT_CODE -eq 0 ]; then
    RESULT_STATUS="success"
else
    RESULT_STATUS="failed"
fi

cat > "$AQSH_RESULT_FILE" << EOF
{
  "status": "$RESULT_STATUS",
  "script": "$SCRIPT_DIR/$SCRIPT_NAME",
  "exit_code": $EXIT_CODE,
  "timestamp": "$(date -Iseconds)"
}
EOF

exit $EXIT_CODE
