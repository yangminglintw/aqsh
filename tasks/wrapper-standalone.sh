#!/bin/bash
# Standalone Wrapper Script Template
# Generic 3-step wrapper: env setup → pre-script → main script
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

# === Main Execution ===
echo "=== Wrapper Script Started ==="
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

# --- Step 3: Main Script Execution ---
echo "--- Main Script Execution ---"
cd "$SCRIPT_DIR" || { echo "ERROR: Cannot cd to $SCRIPT_DIR"; exit 1; }
echo "Changed to script directory: $(pwd)"
echo "Executing: $SCRIPT_NAME"

set +e
./"$SCRIPT_NAME" "$PARAM1" "$PARAM2" "$PARAM3"
EXIT_CODE=$?
set -e

echo "=== Script finished with exit code: $EXIT_CODE ==="
exit $EXIT_CODE
